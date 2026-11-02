# Compatibility shim. Core module moved to src/Core/Gpu.
. (Join-Path $PSScriptRoot "Core\Gpu\Gpu.Helpers.ps1")
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/Driver.Metadata.ps1','Platform/Gpu.ps1')) { . (Join-Path $PSScriptRoot $file) }
