function Show-HyperVGpuCliHelp {
    Write-Host @'
Hyper-V GPU Paravirtualization Manager 2

Launch: -Command desktop | interactive
Inspect: preflight | list-vms | list-gpus | list-profiles
VMs: create-vm | delete-vm
GPU: set-gpu | remove-gpu
Drivers: plan-drivers | install-drivers | audit-drivers | recover-drivers
Profiles: save-profile | delete-profile | default-profile
Configuration: backup-config | restore-config -ConfigurationPath <file>

Use -Json for one structured result and exit code 0 (success), 1 (failure).
Mutations require an off VM; -Shutdown requests a graceful shutdown.
Deletion also requires -Force. -DeleteFiles separately opts into file deletion.
Use -SystemDiskPath to disambiguate multiple Windows installations.
See README.md and docs/USAGE.md for parameters and examples.
'@
}
function Write-HyperVGpuCliResult($Result,[switch]$Json) {
    if ($Json) {ConvertTo-Json -InputObject $Result -Depth 30;return}
    Write-Host $Result.Message -ForegroundColor $(if ($Result.Success) {'Green'} else {'Red'})
    if ($null -ne $Result.Data) {$Result.Data | Format-List | Out-Host}
    if (!$Result.Success) {Write-Host "Operation: $($Result.OperationId). Logs: $env:LOCALAPPDATA\HyperV-Gpu-Manager\Logs" -ForegroundColor DarkGray}
}
function Invoke-HyperVGpuCliCommand {
    param([string]$Command='interactive',[string]$VMName,[string]$GpuPath,[string]$GpuName,[int]$GpuPercent,
        [string]$Preset,[int]$Cpu,[int]$RamGB,[int]$StorageGB,[string]$VhdPath,[string]$IsoPath,
        [switch]$EnableAutoInstall,[int]$InstallImageIndex,[string]$UnattendUsername,[string]$UnattendPassword,
        [switch]$OverwriteVhd,[switch]$All,[switch]$CleanDrivers,[switch]$SkipExisting,[switch]$DeleteFiles,[switch]$Force,[switch]$Json,
        [switch]$Shutdown,[string]$SystemDiskPath,[string]$ProfileName,[switch]$SetDefault,[string]$ConfigurationPath,[switch]$DeepDriverDiscovery)
    if ($Command -eq 'interactive') {return Start-HyperVGpuInteractiveMenu}
    if ($Command -eq 'help' -and !$Json) {Show-HyperVGpuCliHelp;return $true}
    $p=@{}+$PSBoundParameters;[void]$p.Remove('Command');[void]$p.Remove('Json')
    $result=Invoke-HgmCommand $Command $p
    Write-HyperVGpuCliResult $result -Json:$Json
    return $result.Success
}
