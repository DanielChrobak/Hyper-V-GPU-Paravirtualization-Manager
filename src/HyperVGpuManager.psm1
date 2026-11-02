$script:HyperVGpuProjectRoot=Split-Path -Parent $PSScriptRoot
$files=@(
    'Core/Config.Helpers.ps1','Core/Gpu/Gpu.Helpers.ps1','Core/Vhd.Operations.ps1','Core/Vm.Helpers.ps1','Core/AutoInstallIso.ps1',
    'Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/Host.ps1','Platform/Driver.Metadata.ps1','Platform/Gpu.ps1','Platform/InstallationMedia.ps1',
    'Application/Configuration.ps1','Application/Driver.Deployment.ps1','Application/Workflows.ps1',
    'Api/Manager.Api.ps1','Application/Commands.ps1','Cli/Interactive.Menu.ps1','Cli/Console.Actions.ps1','Cli/Command.Dispatcher.ps1'
)
foreach ($file in $files) {. (Join-Path $PSScriptRoot $file)}
InitializeHyperVGpuVmProfiles $script:HyperVGpuProjectRoot
Export-ModuleMember -Function Invoke-HgmCommand,Start-HyperVGpuInteractiveMenu,Invoke-HyperVGpuCliCommand,Invoke-HyperVGpuApi*,Get-HyperVGpuVmSummary,Get-HyperVGpuHostGpuSummary
