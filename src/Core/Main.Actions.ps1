# Compatibility dot-source entry; the module loads these in dependency order.
$sourceRoot=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/Host.ps1','Platform/Driver.Metadata.ps1','Platform/Gpu.ps1','Platform/InstallationMedia.ps1','Application/Configuration.ps1','Application/Driver.Deployment.ps1','Application/Workflows.ps1','Api/Manager.Api.ps1','Application/Commands.ps1','Cli/Command.Dispatcher.ps1','Cli/Console.Actions.ps1')) {
    . (Join-Path $sourceRoot $file)
}
if (!$script:HyperVGpuProjectRoot) {$script:HyperVGpuProjectRoot=Split-Path -Parent $sourceRoot}
