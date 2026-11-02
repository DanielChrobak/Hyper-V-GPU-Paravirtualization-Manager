# Compatibility shim. Core module moved to src/Core.
. (Join-Path $PSScriptRoot "Core\Config.Helpers.ps1")
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Application/Configuration.ps1')) { . (Join-Path $PSScriptRoot $file) }
