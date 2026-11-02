function Test-HgmAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HgmHostCapabilities {
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $add = { param($Name,$Status,$Detail) $checks.Add([pscustomobject]@{Name=$Name;Status=$Status;Detail=$Detail}) }
    & $add 'Elevation' $(if (Test-HgmAdministrator) {'Pass'} else {'Blocked'}) 'Use an elevated Windows PowerShell session for Hyper-V operations.'
    $os = Get-CimInstance Win32_OperatingSystem -EA Stop
    $server = [int]$os.ProductType -ne 1
    $support = if ($server) {'Windows Server host'} else {'Windows client GPU-PV'}
    & $add 'Platform' 'Info' "$($os.Caption) build $($os.BuildNumber); $support"
    & $add 'Architecture' $(if ([Environment]::Is64BitProcess) {'Pass'} else {'Blocked'}) 'A 64-bit process is required.'
    $missing = @('Get-VM','New-VM','Set-VM','Get-VMGpuPartitionAdapter','Add-VMGpuPartitionAdapter','Set-VMGpuPartitionAdapter','Remove-VMGpuPartitionAdapter','Mount-VHD','Dismount-VHD' | Where-Object { !(Get-Command $_ -EA SilentlyContinue) })
    & $add 'Hyper-V commands' $(if ($missing.Count) {'Blocked'} else {'Pass'}) $(if ($missing.Count) {"Missing: $($missing -join ', '). Enable the Hyper-V role and management tools, then restart if Windows requires it."} else {'Native Hyper-V management interfaces available.'})
    $service = Get-Service vmms -EA SilentlyContinue
    & $add 'VMMS' $(if ($service -and $service.Status -eq 'Running') {'Pass'} else {'Blocked'}) 'Hyper-V Virtual Machine Management must be running.'
    $partitionable = @()
    if (!$missing.Count -and (Test-HgmAdministrator)) {
        try {
            $partitionable = @(GetPartitionableGPUs)
            & $add 'Partitionable devices' $(if ($partitionable.Count) {'Pass'} else {'Warning'}) "$($partitionable.Count) reported by Hyper-V. Enumeration does not establish vendor/guest support."
        } catch { & $add 'Partitionable devices' 'Warning' $_.Exception.Message }
    }
    & $add 'Driver synchronization' 'Info' 'Uses the installed host driver packages and GPU-PV runtime copy rules. Synchronize again after host GPU driver updates. Windows guests only.'
    return [pscustomobject]@{
        OperatingSystem=$os.Caption; Build=$os.BuildNumber; Support=$support
        Checks=@($checks.ToArray()); PartitionableCount=$partitionable.Count
        Ready=(@($checks | Where-Object Status -eq 'Blocked').Count -eq 0)
    }
}

function Get-HgmExactVm([string]$Name) {
    Assert-HgmVmName $Name
    $vms = @(Get-VM -Name $Name -EA Stop | Where-Object Name -eq $Name)
    if ($vms.Count -ne 1) { throw "VM '$Name' was not found unambiguously." }
    return $vms[0]
}

function Assert-HgmVmOffline([string]$Name, [switch]$Shutdown) {
    $vm = Get-HgmExactVm $Name
    if ($vm.State -eq 'Off') { return $vm }
    if (!$Shutdown) { throw "VM '$Name' is $($vm.State). Shut it down first or explicitly request graceful shutdown (-Shutdown)." }
    if ($vm.State -ne 'Running') { throw "VM '$Name' is $($vm.State). Resolve its state in Hyper-V Manager before continuing." }
    Write-HgmEvent 'VmShutdown' "Requesting graceful shutdown of '$Name'."
    Stop-VM -VM $vm -EA Stop
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 60) {
        Test-HgmCancellation
        $vm = Get-HgmExactVm $Name
        if ($vm.State -eq 'Off') { return $vm }
        Start-Sleep -Milliseconds 250
    }
    throw "Graceful shutdown of '$Name' timed out. The VM was not forcibly powered off. Shut it down inside the guest and retry."
}

function Get-HgmVmDisks([string]$Name) {
    return @(Get-VMHardDiskDrive -VMName $Name -EA Stop | Where-Object Path | Sort-Object ControllerType,ControllerNumber,ControllerLocation)
}

function Open-HgmWindowsDisk([string]$Name, [string]$DiskPath) {
    $disks = @(Get-HgmVmDisks $Name)
    if (!$disks.Count) { throw 'The VM has no file-backed virtual disks.' }
    if ($DiskPath) {
        $full = [IO.Path]::GetFullPath($DiskPath)
        $disks = @($disks | Where-Object { [IO.Path]::GetFullPath($_.Path) -eq $full })
        if ($disks.Count -ne 1) { throw 'The selected system disk is not attached to this VM.' }
    }
    $found = $null
    try {
        foreach ($disk in $disks) {
            Test-HgmCancellation
            $mount = $null
            try { $mount = MountVHD $disk.Path }
            catch { Write-HgmEvent 'DiskProbe' "Cannot use '$($disk.Path)': $($_.Exception.Message)" 'Warning'; continue }
            if ($found) { UnmountVHD $mount $disk.Path; throw 'Multiple Windows installations found. Select an attached disk explicitly with -SystemDiskPath.' }
            $found = $mount
        }
        if (!$found) { throw 'No accessible Windows system volume found. Install Windows first, unlock BitLocker if applicable, and select the correct attached disk.' }
        return $found
    } catch { if ($found) { UnmountVHD $found $found.VHD }; throw }
}
