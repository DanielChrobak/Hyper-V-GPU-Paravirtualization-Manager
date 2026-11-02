function Invoke-HgmCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command, [hashtable]$Parameters=@{}, $ProgressQueue, $Cancellation)
    $script:HgmProgressQueue=$ProgressQueue; $script:HgmCancellation=$Cancellation
    $script:HgmSignedDrivers=$null
    $script:HgmDeepDriverDiscovery=[bool]$Parameters.DeepDriverDiscovery
    Initialize-HgmDiagnostics
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $cmd=$Command.ToLowerInvariant(); $data=$null; $success=$false; $message=$null; $errorCode=$null
    $previousPreference=$ErrorActionPreference
    $ErrorActionPreference='Stop'
    try {
        if ($cmd -notin @('help','preflight','list-profiles','save-profile','delete-profile','default-profile','backup-config','restore-config')) {
            if (!(Test-HgmAdministrator)) { throw 'Administrator privileges are required. Open the desktop as Administrator or use an elevated Windows PowerShell session.' }
        }
        $action={
            switch ($cmd) {
                'help' {return [pscustomobject]@{Version='2.0.0';Commands=@('desktop','interactive','preflight','create-vm','set-gpu','remove-gpu','install-drivers','plan-drivers','audit-drivers','recover-drivers','delete-vm','list-vms','list-gpus','list-profiles','save-profile','delete-profile','default-profile','backup-config','restore-config');Documentation='README.md'}}
                'preflight' {return Get-HgmHostCapabilities}
                'list-vms' {return @(Get-HyperVGpuVmSummary)}
                'list-gpus' {return @(Get-HgmGpuInventory)}
                'list-images' {return @(GetWindowsInstallImageOptions $Parameters.IsoPath)}
                'create-vm' {
                    $p=$Parameters
                    if ($p.ProfileName) {
                        $profile=GetHyperVGpuVmProfile $p.ProfileName $script:HyperVGpuProjectRoot
                        if (!$profile) {throw 'The requested VM profile does not exist.'}
                        $cfg=[pscustomobject]@{Name=$profile.VmName;CPU=$profile.Cpu;RAM=$profile.RamGB;Storage=$profile.StorageGB;Path=$profile.VhdPath;ISO=$profile.IsoPath}
                        foreach ($pair in @(@('VMName','Name'),@('Cpu','CPU'),@('RamGB','RAM'),@('StorageGB','Storage'),@('VhdPath','Path'),@('IsoPath','ISO'))) {if ($p.ContainsKey($pair[0])) {$cfg.($pair[1])=$p[$pair[0]]}}
                        $auto=if ($p.ContainsKey('EnableAutoInstall')) {[bool]$p.EnableAutoInstall} else {$profile.EnableAutoInstall}
                        $index=if ($p.ContainsKey('InstallImageIndex')) {$p.InstallImageIndex} else {$profile.InstallImageIndex}
                        $account=[pscustomobject]@{Username=$profile.UnattendUsername;Password=$profile.UnattendPassword}
                        $overwrite=[bool]$p.OverwriteVhd -or $profile.OverwriteVhd
                    } else {
                        $preset=if ($p.Preset) {GetHyperVGpuPresetDefinition $p.Preset} else {GetHyperVGpuPresetDefinition 'development'}
                        if ($p.Preset -and $p.Preset -ne 'custom' -and !$preset) {throw 'Unknown preset. Use gaming, development, ml-training or custom.'}
                        $cfg=[pscustomobject]@{Name=if ($p.VMName) {$p.VMName} else {$preset.Name};CPU=if ($p.Cpu) {$p.Cpu} else {$preset.Cpu};RAM=if ($p.RamGB) {$p.RamGB} else {$preset.Ram};Storage=if ($p.StorageGB) {$p.StorageGB} else {$preset.Storage};Path=if ($p.VhdPath) {$p.VhdPath} else {$script:Paths.VHD};ISO=$p.IsoPath}
                        $auto=[bool]$p.EnableAutoInstall; $index=$p.InstallImageIndex; $account=$null; $overwrite=[bool]$p.OverwriteVhd
                    }
                    if (!$account -and ($p.ContainsKey('UnattendUsername') -or $p.ContainsKey('UnattendPassword'))) {$account=[pscustomobject]@{Username=$null;Password=$null}}
                    if ($p.ContainsKey('UnattendUsername')) {$account.Username=$p.UnattendUsername}
                    if ($p.ContainsKey('UnattendPassword')) {$account.Password=$p.UnattendPassword}
                    if ($account -and !$account.Username -and !$account.Password) {$account=$null}
                    $image=if ($index -gt 0) {[pscustomobject]@{Index=$index}} else {$null}
                    return New-HgmVirtualMachine $cfg -EnableAutoInstall:$auto -ImageSelection $image -LocalAccountConfig $account -OverwriteVhd:$overwrite
                }
                'set-gpu' {return Set-HgmGpu $Parameters.VMName $Parameters.GpuPath $Parameters.GpuPercent -Shutdown:([bool]$Parameters.Shutdown)}
                'remove-gpu' {return Remove-HgmGpu $Parameters.VMName $Parameters.GpuPath -CleanDrivers:([bool]$Parameters.CleanDrivers) -SystemDiskPath $Parameters.SystemDiskPath -Shutdown:([bool]$Parameters.Shutdown)}
                {$_ -in @('install-drivers','plan-drivers','audit-drivers','recover-drivers')} {return Invoke-HgmDriverWorkflow $Parameters.VMName $Parameters.GpuPath $Parameters.SystemDiskPath -Mode $cmd -SkipExisting:([bool]$Parameters.SkipExisting) -Shutdown:([bool]$Parameters.Shutdown)}
                'delete-vm' {return Remove-HgmVirtualMachine $Parameters.VMName -DeleteFiles:([bool]$Parameters.DeleteFiles) -Force:([bool]$Parameters.Force) -Shutdown:([bool]$Parameters.Shutdown)}
                'list-profiles' {return @(GetHyperVGpuVmProfileInventory $script:HyperVGpuProjectRoot | Select-Object Name,IsDefault,VmName,Cpu,RamGB,StorageGB,VhdPath,IsoPath,EnableAutoInstall,InstallImageIndex,UnattendUsername,OverwriteVhd)}
                'save-profile' {
                    Assert-HgmVmName $Parameters.VMName
                    if (!$Parameters.ContainsKey('UnattendPassword')) {
                        $existingProfile=GetHyperVGpuVmProfile $Parameters.ProfileName $script:HyperVGpuProjectRoot
                        if ($existingProfile) {$Parameters.UnattendPassword=$existingProfile.UnattendPassword}
                    }
                    $saved=SaveHyperVGpuVmProfile -Name $Parameters.ProfileName -ProjectRoot $script:HyperVGpuProjectRoot -VmName $Parameters.VMName -Cpu $Parameters.Cpu -RamGB $Parameters.RamGB -StorageGB $Parameters.StorageGB -VhdPath $Parameters.VhdPath -IsoPath $Parameters.IsoPath -EnableAutoInstall:([bool]$Parameters.EnableAutoInstall) -InstallImageIndex $Parameters.InstallImageIndex -UnattendUsername $Parameters.UnattendUsername -UnattendPassword $Parameters.UnattendPassword -OverwriteVhd:([bool]$Parameters.OverwriteVhd) -SetDefault:([bool]$Parameters.SetDefault)
                    if (!$saved) {throw 'Profile could not be saved.'}; return ($saved | Select-Object Name,VmName,IsDefault,StorePath)
                }
                'delete-profile' {if (!(RemoveHyperVGpuVmProfile $Parameters.ProfileName $script:HyperVGpuProjectRoot)) {throw 'Profile could not be deleted.'};return $null}
                'default-profile' {if (!(SetHyperVGpuVmProfileDefault $Parameters.ProfileName $script:HyperVGpuProjectRoot)) {throw 'Default profile could not be set.'};return $null}
                'backup-config' {return Export-HgmConfiguration $Parameters.ConfigurationPath}
                'restore-config' {return Import-HgmConfiguration $Parameters.ConfigurationPath}
                default {throw "Unknown command: $cmd"}
            }
        }
        $lockKey=if ($Parameters.VMName) {"VM:$($Parameters.VMName)"} elseif ($cmd -match 'profile|config') {"Configuration:$script:HyperVGpuProjectRoot"} else {$null}
        Write-HgmEvent 'OperationStarted' "Starting $cmd."
        $data=if ($lockKey) {Invoke-HgmExclusive $lockKey $action} else {& $action}
        $success=$true; $message="$cmd completed."
        if ($cmd -eq 'preflight' -and !$data.Ready) {$success=$false; $message='Resolve the blocked preflight checks before changing Hyper-V resources.'; $errorCode='PreflightBlocked'}
        Write-HgmEvent 'OperationCompleted' $message
    } catch [OperationCanceledException] {
        $message='Cancelled at a safe boundary; any in-progress driver transaction was rolled back.'; $errorCode='Cancelled'
        Write-HgmEvent 'Cancelled' $message 'Warning'
    } catch {
        # Never record parameter values, credentials, answer-file contents or a
        # serialized error invocation (which can contain secrets).
        $message=$_.Exception.Message; $errorCode='OperationFailed'
        foreach ($secret in @($Parameters.UnattendPassword)) {if ($secret) {$message=$message.Replace($secret,'[redacted]')}}
        Write-HgmEvent 'OperationFailed' $message 'Error'
    } finally {$ErrorActionPreference=$previousPreference; $script:HgmProgressQueue=$null; $script:HgmCancellation=$null}
    return [pscustomobject]@{Operation=$cmd;Success=$success;Data=$data;Message=$message;TimestampUtc=[DateTime]::UtcNow.ToString('o');SchemaVersion=2;OperationId=$script:HgmOperationId;ErrorCode=$errorCode;DurationMs=$clock.ElapsedMilliseconds;Diagnostics=@($script:HgmEvents.ToArray())}
}
