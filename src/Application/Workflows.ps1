function New-HgmVirtualMachine($Config, [switch]$EnableAutoInstall, $ImageSelection, $LocalAccountConfig, [switch]$OverwriteVhd) {
    Assert-HgmVmName $Config.Name
    if ([int]$Config.CPU -lt 1 -or [int]$Config.CPU -gt 2048 -or [int]$Config.RAM -lt 1 -or [int]$Config.RAM -gt 1048576 -or [int]$Config.Storage -lt 1 -or [int]$Config.Storage -gt 65536) { throw 'CPU, RAM and storage must be positive and within Hyper-V configuration limits.' }
    if (@(Get-VM -Name $Config.Name -EA SilentlyContinue | Where-Object Name -eq $Config.Name).Count) { throw 'A VM with that name already exists.' }
    $directory = [IO.Path]::GetFullPath($Config.Path)
    $vhd = Resolve-HgmContainedPath $directory "$($Config.Name).vhdx"
    if ($Config.ISO -and !(Test-Path -LiteralPath $Config.ISO -PathType Leaf)) { throw 'The installation ISO does not exist.' }
    if ($EnableAutoInstall -and !$Config.ISO) { throw 'Unattended installation requires a Windows installation ISO.' }
    if ((Test-Path -LiteralPath $vhd) -and !$OverwriteVhd) { throw 'VHD already exists. Choose another name/path or explicitly enable overwrite.' }
    if (Test-Path -LiteralPath $vhd) {
        foreach ($vm in @(Get-VM -EA Stop)) {
            foreach ($disk in @(Get-HgmVmDisks $vm.Name)) {
                $chain = ResolveVHDChain $disk.Path
                if ($vhd -in $chain.Paths) { throw 'The existing VHD is attached to another VM or is a checkpoint ancestor. It cannot be overwritten.' }
            }
        }
        if ((Get-VHD -Path $vhd -EA Stop).Attached) { throw 'The existing VHD is mounted. Dismount it before overwriting.' }
    }
    $free = GetFreeBytesForPath $vhd
    if ($null -eq $free) { throw 'Cannot verify free space on the VHD target. Use an accessible local volume.' }
    if ($free -lt ([long]$Config.Storage * 1GB + 2GB)) { throw 'Insufficient free space for the requested disk plus 2 GiB working space. Existing files were preserved.' }
    Test-HgmCancellation
    $iso = $Config.ISO
    if ($EnableAutoInstall) {
        $built = NewAutoISO $iso $Config.Name $ImageSelection $LocalAccountConfig
        if ($built) { $iso = $built }
        elseif (!$script:LastAutoUnattendFallbackPath) { throw 'Unattended media creation failed. The VM was not created.' }
        else { Write-HgmEvent 'AnswerFileFallback' "ADK unavailable; use the exported answer file at '$script:LastAutoUnattendFallbackPath' with the original installation media." 'Warning' }
    }
    $backup = $null; $created = $false; $diskCreated = $false
    try {
        Test-HgmCancellation
        if (!(Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force -EA Stop | Out-Null }
        if (Test-Path -LiteralPath $vhd) {
            $backup = "$vhd.previous-$([guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $vhd -Destination $backup -EA Stop
        }
        Write-HgmEvent 'VmCreate' "Creating Generation 2 VM '$($Config.Name)'."
        $diskCreated = $true
        $vm = New-VM -Name $Config.Name -MemoryStartupBytes ([long]$Config.RAM * 1GB) -Generation 2 -NewVHDPath $vhd -NewVHDSizeBytes ([long]$Config.Storage * 1GB) -EA Stop
        $created = $true
        Set-VMProcessor -VM $vm -Count $Config.CPU -EA Stop
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -EA Stop
        $settings = @{VM=$vm;CheckpointType='Disabled';AutomaticStopAction='ShutDown';AutomaticStartAction='Nothing';AutomaticCheckpointsEnabled=$false;ErrorAction='Stop'}
        if (TestHyperVCmdletParameter 'Set-VM' 'EnhancedSessionTransportType') { $settings.EnhancedSessionTransportType='VMBus' }
        Set-VM @settings
        Set-VMFirmware -VM $vm -EnableSecureBoot On -EA Stop
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector -EA Stop
        Enable-VMTPM -VM $vm -EA Stop
        if ($iso) {
            $dvd = Add-VMDvdDrive -VM $vm -Path $iso -Passthru -EA Stop
            $hdd = @(Get-VMHardDiskDrive -VM $vm -EA Stop)
            Set-VMFirmware -VM $vm -BootOrder (@($dvd)+$hdd) -EA Stop
        }
        $actual = Get-HgmExactVm $Config.Name
        if ($actual.Generation -ne 2 -or $actual.ProcessorCount -ne $Config.CPU -or $actual.MemoryStartup -ne ([long]$Config.RAM * 1GB)) { throw 'VM configuration verification failed.' }
        if ($backup) { Write-HgmEvent 'VhdBackup' "Previous VHD retained at '$backup'. Remove it after verifying the new VM." 'Warning' }
        return [pscustomobject]@{VmName=$actual.Name;VhdPath=$vhd;PreviousVhd=$backup;IsoPath=$iso;State="$($actual.State)";AnswerFile=$script:LastAutoUnattendFallbackPath}
    } catch {
        $failure = $_
        # New-VM can fail after partially registering the VM.
        $partial = @(Get-VM -Name $Config.Name -EA SilentlyContinue | Where-Object Name -eq $Config.Name)
        if ($created -or $partial.Count) { Remove-VM -Name $Config.Name -Force -EA Stop }
        if ($diskCreated -and (Test-Path -LiteralPath $vhd)) { Remove-Item -LiteralPath $vhd -Force -EA Stop }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $vhd -EA Stop }
        throw $failure
    }
}

function Get-HgmVmStatePath($Vm) {
    $root = Join-Path $env:ProgramData 'HyperV-Gpu-Manager\State'
    SecureDir $root
    Resolve-HgmContainedPath $root "$($Vm.Id).json"
}

function Set-HgmGpu([string]$VMName, [string]$GpuPath, [int]$Percent, [switch]$Shutdown) {
    if ($Percent -lt 1 -or $Percent -gt 100) { throw 'GPU percent must be 1-100.' }
    $gpu = GetPartitionableGpuByPath $GpuPath
    $settings = Get-HgmResourceSettings $gpu $Percent
    $vm = Assert-HgmVmOffline $VMName -Shutdown:$Shutdown
    $existing = @(Get-VMGpuPartitionAdapter -VMName $VMName -EA Stop)
    $key = Get-HgmDeviceKey $GpuPath
    $target = @($existing | Where-Object {(Get-HgmDeviceKey (Resolve-HgmAssignedPath $_)) -eq $key})
    if ($target.Count -gt 1) { throw 'Duplicate adapter assignments exist for this physical device. Remove the duplicates in Hyper-V Manager first.' }
    $canTarget = TestHyperVCmdletParameter 'Add-VMGpuPartitionAdapter' 'InstancePath'
    if (!$canTarget -and @((GetPartitionableGPUs)).Count -ne 1) { throw 'This host cannot target a specific GPU. Multiple host GPUs are present; upgrade the host management interface.' }
    $statePath = Get-HgmVmStatePath $vm
    $original = [pscustomobject]@{GuestControlledCacheTypes=$vm.GuestControlledCacheTypes;LowMemoryMappedIoSpace=$vm.LowMemoryMappedIoSpace;HighMemoryMappedIoSpace=$vm.HighMemoryMappedIoSpace}
    if (!(Test-Path -LiteralPath $statePath)) { Write-HgmAtomicJson $statePath $original }
    $added = $false; $oldResources = @{}
    try {
        Test-HgmCancellation
        if ($target.Count) {
            $target = $target[0]
            foreach ($name in $settings.Keys) { $oldResources[$name] = $target.$name }
        } else {
            $args = @{VMName=$VMName;Passthru=$true;ErrorAction='Stop'}
            if ($canTarget) { $args.InstancePath=$GpuPath }
            $target = Add-VMGpuPartitionAdapter @args; $added = $true
        }
        if (!$target) { throw 'Hyper-V did not return the GPU partition adapter.' }
        Set-VMGpuPartitionAdapter -VMGpuPartitionAdapter $target @settings -EA Stop
        # Preserve larger custom MMIO reservations.
        Set-VM -VM $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace ([UInt64][Math]::Max([decimal]$vm.LowMemoryMappedIoSpace,1GB)) -HighMemoryMappedIoSpace ([UInt64][Math]::Max([decimal]$vm.HighMemoryMappedIoSpace,32GB)) -EA Stop
        $applied = @(Get-VMGpuPartitionAdapter -VMName $VMName -EA Stop | Where-Object AdapterId -eq $target.AdapterId)
        if ($applied.Count -ne 1) { throw 'GPU assignment could not be verified.' }
        foreach ($name in $settings.Keys) { if ([UInt64]$applied[0].$name -ne [UInt64]$settings[$name]) { throw "Hyper-V did not apply $name as requested." } }
        return [pscustomobject]@{VmName=$VMName;Percent=$Percent;GpuPath=$GpuPath;AdapterId=$target.AdapterId;Resources=$settings}
    } catch {
        $failure=$_
        if ($added -and $target) { Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $target -EA Stop }
        elseif ($oldResources.Count) { Set-VMGpuPartitionAdapter -VMGpuPartitionAdapter $target @oldResources -EA Stop }
        Set-VM -VM $vm -GuestControlledCacheTypes $original.GuestControlledCacheTypes -LowMemoryMappedIoSpace $original.LowMemoryMappedIoSpace -HighMemoryMappedIoSpace $original.HighMemoryMappedIoSpace -EA Stop
        throw $failure
    }
}

function Get-HgmSelectedAdapters([string]$VMName, [string]$GpuPath) {
    $adapters = @(Get-VMGpuPartitionAdapter -VMName $VMName -EA Stop)
    if ($GpuPath) { $key=Get-HgmDeviceKey $GpuPath; $adapters=@($adapters | Where-Object {(Get-HgmDeviceKey (Resolve-HgmAssignedPath $_)) -eq $key}) }
    if (!$adapters.Count) { throw 'No assigned GPU partition matches this selection.' }
    return $adapters
}

function Get-HgmSelectedDrivers([string]$VMName, [string]$GpuPath) {
    $gpus = @{}
    foreach ($adapter in @(Get-HgmSelectedAdapters $VMName $GpuPath)) {
        $gpu = FindGPU (Resolve-HgmAssignedPath $adapter)
        if (!$gpu) { throw "Cannot resolve the exact installed driver for '$($adapter.InstancePath)'. No guest files were changed." }
        $gpus[$gpu.DeviceID]=$gpu
    }
    return @($gpus.Values)
}

function Invoke-HgmDriverWorkflow([string]$VMName, [string]$GpuPath, [string]$SystemDiskPath, [string]$Mode='install-drivers', [switch]$SkipExisting, [switch]$Shutdown) {
    $plan=$null
    if ($Mode -in @('install-drivers','plan-drivers')) { $plan=Get-HgmDriverPlan (Get-HgmSelectedDrivers $VMName $GpuPath) }
    if ($Mode -eq 'plan-drivers') { return $plan }
    $null=Assert-HgmVmOffline $VMName -Shutdown:$Shutdown
    $mount = Open-HgmWindowsDisk $VMName $SystemDiskPath
    try {
        switch ($Mode) {
            'install-drivers' { Invoke-HgmDriverTransaction $mount.Path $plan -SkipExisting:$SkipExisting }
            'audit-drivers' { @(Test-HgmDriverDrift $mount.Path) }
            'recover-drivers' { [pscustomobject]@{Recovered=(Repair-HgmDriverTransactions $mount.Path)} }
        }
    } finally { UnmountVHD $mount $mount.VHD -Strict }
}

function Remove-HgmGpu([string]$VMName, [string]$GpuPath, [switch]$CleanDrivers, [string]$SystemDiskPath, [switch]$Shutdown) {
    $vm=Assert-HgmVmOffline $VMName -Shutdown:$Shutdown
    $selected=@(Get-HgmSelectedAdapters $VMName $GpuPath)
    $ids=@($selected | ForEach-Object {Get-HgmDeviceKey (Resolve-HgmAssignedPath $_)})
    $mount=$null
    try {
        # Access and ownership are validated before removing adapters.
        if ($CleanDrivers) { $mount=Open-HgmWindowsDisk $VMName $SystemDiskPath; $null=Get-HgmManifest $mount.Path }
        foreach ($adapter in $selected) { Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $adapter -EA Stop }
        $remaining=@(Get-VMGpuPartitionAdapter -VMName $VMName -EA Stop)
        if (@($remaining | Where-Object {(Get-HgmDeviceKey (Resolve-HgmAssignedPath $_)) -in $ids}).Count) { throw 'Hyper-V still reports one of the selected GPU adapters.' }
        if ($CleanDrivers) {
            # Match manifest IDs canonically, including when host driver metadata
            # has disappeared following a device removal or driver update.
            $manifestIds=@(Get-HgmManifest $mount.Path | Where-Object {(Get-HgmDeviceKey $_.GpuDeviceId) -in $ids} | ForEach-Object GpuDeviceId)
            $null=Invoke-HgmDriverTransaction $mount.Path $null -RemoveGpuIds $manifestIds
        }
        if (!$remaining.Count) {
            $path=Get-HgmVmStatePath $vm
            if (Test-Path -LiteralPath $path) {
                $original=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -EA Stop
                Set-VM -VM $vm -GuestControlledCacheTypes $original.GuestControlledCacheTypes -LowMemoryMappedIoSpace $original.LowMemoryMappedIoSpace -HighMemoryMappedIoSpace $original.HighMemoryMappedIoSpace -EA Stop
                Remove-Item -LiteralPath $path -Force -EA Stop
            } else { Write-HgmEvent 'MmioPreserved' 'No original MMIO snapshot exists for this legacy assignment. Existing VM settings were preserved.' 'Warning' }
        }
        return [pscustomobject]@{VmName=$VMName;Removed=$selected.Count;Remaining=$remaining.Count;CleanDrivers=[bool]$CleanDrivers}
    } catch { throw "GPU removal/cleanup did not complete: $($_.Exception.Message) Check assigned adapters and run audit-drivers before retrying." }
    finally { if ($mount) {UnmountVHD $mount $mount.VHD -Strict} }
}

function Remove-HgmVirtualMachine([string]$VMName, [switch]$DeleteFiles, [switch]$Force, [switch]$Shutdown) {
    if (!$Force) { throw 'VM deletion requires -Force after reviewing the target and file policy.' }
    $vm=Assert-HgmVmOffline $VMName -Shutdown:$Shutdown
    $disks=@(Get-HgmVmDisks $VMName)
    $paths=@($disks | ForEach-Object Path | Sort-Object -Unique)
    $generated=@()
    foreach ($dvd in @(Get-VMDvdDrive -VMName $VMName -EA Stop)) {
        if (!$dvd.Path) {continue}
        $base=[IO.Path]::GetFullPath($script:Paths.ISO).TrimEnd([char]'\')+'\'
        $iso=[IO.Path]::GetFullPath($dvd.Path)
        if ($iso.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $iso) -eq "$VMName-AutoInstall.iso") {$generated+=$iso}
    }
    if ($DeleteFiles) {
        $all=@(Get-VM -EA Stop | Where-Object Name -ne $VMName)
        foreach ($other in $all) {
            foreach ($disk in @(Get-HgmVmDisks $other.Name)) {
                $chain=ResolveVHDChain $disk.Path
                if (@($chain.Paths | Where-Object {$_ -in $paths}).Count) {throw "A selected disk is shared with or is an ancestor of '$($other.Name)'. Remove the VM without -DeleteFiles."}
            }
        }
        foreach ($path in $paths) {
            if ((Get-VHD -Path $path -EA Stop).Attached) {throw 'An associated disk is mounted. Dismount it before deleting files.'}
        }
    }
    Test-HgmCancellation
    Remove-VM -VM $vm -Force -EA Stop
    if (@(Get-VM -Name $VMName -EA SilentlyContinue | Where-Object Name -eq $VMName).Count) {throw 'VM deletion could not be verified.'}
    if ($DeleteFiles) {
        foreach ($path in @($paths+$generated)) {if (Test-Path -LiteralPath $path -PathType Leaf) {Remove-Item -LiteralPath $path -Force -EA Stop}}
        foreach ($iso in $generated) {if (Test-Path -LiteralPath "$iso.manager.json") {Remove-Item -LiteralPath "$iso.manager.json" -Force -EA Stop}}
    }
    return [pscustomobject]@{VmName=$VMName;DeletedFiles=if ($DeleteFiles) {@($paths+$generated)} else {@()};PreservedFiles=if ($DeleteFiles) {@()} else {@($paths+$generated)}}
}
