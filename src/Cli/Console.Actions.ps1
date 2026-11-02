function Invoke-HgmConsoleResult([string]$Command,[hashtable]$Parameters) {
    $result=Invoke-HgmCommand $Command $Parameters
    Write-HyperVGpuCliResult $result
    return $result.Success
}
function NewVM($Config=$null,[switch]$NonInteractive,[switch]$EnableAutoInstall,$ImageSelection=$null,$LocalAccountConfig=$null,[switch]$OverwriteVhd) {
    if (!$Config) {
        if ($NonInteractive) {return $false}
        $profiles=@(GetHyperVGpuVmProfileInventory $script:HyperVGpuProjectRoot | Sort-Object @{Expression={if ($_.IsDefault) {0} else {1}}},Name)
        $items=@($script:Presets | ForEach-Object {"Preset: $($_.L)"})+@($profiles | ForEach-Object {"Profile: $($_.Name)"})+@('Custom')
        $choice=Menu $items 'CREATE VIRTUAL MACHINE';if ($null -eq $choice) {return $null}
        if ($choice -lt $script:Presets.Count) {
            $p=$script:Presets[$choice]
            $Config=[pscustomobject]@{Name=Input 'VM name' {param($v) ![string]::IsNullOrWhiteSpace($v)} $p.N;CPU=$p.C;RAM=$p.R;Storage=$p.S;Path=$script:Paths.VHD;ISO=Read-Host '  Installation ISO (optional)'}
        } elseif ($choice -lt ($script:Presets.Count+$profiles.Count)) {
            $profile=$profiles[$choice-$script:Presets.Count]
            return Invoke-HgmConsoleResult create-vm @{ProfileName=$profile.Name}
        } else {
            $form=Read-HyperVGpuVmProfileInput
            if (!$form) {return $null}
            $Config=[pscustomobject]@{Name=$form.VmName;CPU=$form.Cpu;RAM=$form.RamGB;Storage=$form.StorageGB;Path=$form.VhdPath;ISO=$form.IsoPath}
            $EnableAutoInstall=[bool]$form.EnableAutoInstall
            $ImageSelection=[pscustomobject]@{Index=$form.InstallImageIndex}
            $LocalAccountConfig=[pscustomobject]@{Username=$form.UnattendUsername;Password=$form.UnattendPassword}
        }
        if ($Config.ISO -and !$EnableAutoInstall -and (Confirm 'Create unattended installation media?')) {
            $EnableAutoInstall=$true
            $ImageSelection=PromptWindowsInstallImageSelection @(GetWindowsInstallImageOptions $Config.ISO)
            if (Confirm 'Create a local account during Windows setup?') {
                $username=Read-Host '  Local username'
                $password=Read-Host '  Local password' -AsSecureString
                $LocalAccountConfig=[pscustomobject]@{Username=$username;Password=(New-Object Management.Automation.PSCredential('setup',$password)).GetNetworkCredential().Password}
            }
        }
        $vhd=Join-Path $Config.Path "$($Config.Name).vhdx"
        if ((Test-Path -LiteralPath $vhd) -and !(Confirm 'Preserve the existing VHD as a backup and create a replacement?')) {return $null}
        $OverwriteVhd=$true
    }
    $p=@{VMName=$Config.Name;Cpu=$Config.CPU;RamGB=$Config.RAM;StorageGB=$Config.Storage;VhdPath=$Config.Path;IsoPath=$Config.ISO;EnableAutoInstall=[bool]$EnableAutoInstall;InstallImageIndex=$ImageSelection.Index;OverwriteVhd=[bool]$OverwriteVhd}
    if ($LocalAccountConfig) {$p.UnattendUsername=$LocalAccountConfig.Username;$p.UnattendPassword=$LocalAccountConfig.Password}
    $result=Invoke-HgmCommand create-vm $p;Write-HyperVGpuCliResult $result
    if ($result.Success) {return $result.Data.VmName};return $false
}
function Get-HgmConsoleTarget([string]$VMName,[string]$Title,[switch]$NonInteractive) {
    if ($VMName) {return $VMName};if ($NonInteractive) {return $null}
    $vm=SelectVM $Title;if ($vm) {return $vm.Name};return $null
}
function Get-HgmConsoleShutdown([string]$Name,[switch]$NonInteractive) {
    if ((Get-HgmExactVm $Name).State -eq 'Off') {return $false}
    if ($NonInteractive) {return $false}
    return Confirm "Request graceful shutdown of '$Name'? (No force power-off)"
}
function SetGPU($VMName=$null,$Pct=0,$GPUPath=$null,$GPUName=$null,[switch]$NonInteractive) {
    $VMName=Get-HgmConsoleTarget $VMName 'GPU PARTITION' -NonInteractive:$NonInteractive;if (!$VMName) {return $null}
    if (!$GPUPath -and !$NonInteractive) {$gpu=SelectGPU -Partition;if (!$gpu) {return $null};$GPUPath=$gpu.P}
    if (!$Pct -and !$NonInteractive) {$Pct=[int](Input 'GPU percentage (1-100)' {param($v) $n=0;[int]::TryParse($v,[ref]$n) -and $n -ge 1 -and $n -le 100})}
    Invoke-HgmConsoleResult set-gpu @{VMName=$VMName;GpuPath=$GPUPath;GpuPercent=$Pct;Shutdown=Get-HgmConsoleShutdown $VMName -NonInteractive:$NonInteractive}
}
function Select-HgmConsoleAssignedPath([string]$Name,[string]$Title) {
    $adapters=@(Get-HgmSelectedAdapters $Name)
    $choice=Menu (@($adapters | ForEach-Object {"$($_.InstancePath) | $($_.AdapterId)"})+@('All assigned GPUs','< Cancel >')) $Title
    if ($null -eq $choice -or $choice -eq $adapters.Count+1) {return [pscustomobject]@{Cancelled=$true}}
    return [pscustomobject]@{Cancelled=$false;Path=if ($choice -lt $adapters.Count) {$adapters[$choice].InstancePath} else {$null}}
}
function InstallDrivers($VMName=$null,$GPUPath=$null,[switch]$All,[switch]$SkipExisting,[switch]$NonInteractive) {
    $VMName=Get-HgmConsoleTarget $VMName 'INSTALL DRIVERS' -NonInteractive:$NonInteractive;if (!$VMName) {return $null}
    $disk=$null
    if (!$NonInteractive) {
        $selection=Select-HgmConsoleAssignedPath $VMName 'DRIVER TARGET';if ($selection.Cancelled) {return $null};$GPUPath=$selection.Path
        $SkipExisting=Confirm 'Skip files with matching SHA-256 hashes?'
        $disk=Select-VMSystemDisk $VMName;if (!$disk) {return $null}
    }
    Invoke-HgmConsoleResult install-drivers @{VMName=$VMName;GpuPath=$GPUPath;SkipExisting=[bool]$SkipExisting;SystemDiskPath=$disk;Shutdown=Get-HgmConsoleShutdown $VMName -NonInteractive:$NonInteractive}
}
function RemoveGPU($VMName=$null,$GPUPath=$null,[switch]$All,[switch]$CleanDrivers,[switch]$NonInteractive) {
    $VMName=Get-HgmConsoleTarget $VMName 'REMOVE GPU' -NonInteractive:$NonInteractive;if (!$VMName) {return $null}
    $disk=$null
    if (!$NonInteractive) {
        $selection=Select-HgmConsoleAssignedPath $VMName 'REMOVE TARGET';if ($selection.Cancelled) {return $null};$GPUPath=$selection.Path
        if (!(Confirm "Remove the selected GPU assignments from '$VMName'?")) {return $null}
        $CleanDrivers=Confirm 'Also clean tracked driver files and restore original files?'
        if ($CleanDrivers) {$disk=Select-VMSystemDisk $VMName;if (!$disk) {return $null}}
    }
    Invoke-HgmConsoleResult remove-gpu @{VMName=$VMName;GpuPath=$GPUPath;CleanDrivers=[bool]$CleanDrivers;SystemDiskPath=$disk;Shutdown=Get-HgmConsoleShutdown $VMName -NonInteractive:$NonInteractive}
}
function DeleteVM($VMName=$null,[switch]$DeleteFiles,[switch]$Force,[switch]$NonInteractive) {
    $VMName=Get-HgmConsoleTarget $VMName 'DELETE VM' -NonInteractive:$NonInteractive;if (!$VMName) {return $null}
    if (!$NonInteractive) {
        if (!(Confirm "Permanently delete VM '$VMName'?")) {return $null};$Force=$true
        $DeleteFiles=Confirm 'Also delete its attached disk files and generated installation ISO?'
    }
    Invoke-HgmConsoleResult delete-vm @{VMName=$VMName;DeleteFiles=[bool]$DeleteFiles;Force=[bool]$Force;Shutdown=Get-HgmConsoleShutdown $VMName -NonInteractive:$NonInteractive}
}
function ShowVMs {$null=Invoke-HgmConsoleResult list-vms @{};Pause}
function ShowGPUs {$null=Invoke-HgmConsoleResult list-gpus @{};Pause}
