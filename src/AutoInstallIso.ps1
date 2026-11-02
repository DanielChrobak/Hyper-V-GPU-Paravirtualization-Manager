# Compatibility shim. Core module moved to src/Core.
. (Join-Path $PSScriptRoot "Core\AutoInstallIso.ps1")
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/InstallationMedia.ps1')) { . (Join-Path $PSScriptRoot $file) }
