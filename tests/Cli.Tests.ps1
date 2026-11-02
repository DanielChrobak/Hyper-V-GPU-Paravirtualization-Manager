$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $project 'HyperV-GPU-Virtualization-Manager.ps1'
$engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$help=(& $engine -NoProfile -ExecutionPolicy Bypass -File $entry -Command help -Json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or !$help.Success -or $help.SchemaVersion -ne 2) {throw 'Headless help/JSON contract failed.'}
$bad=(& $engine -NoProfile -ExecutionPolicy Bypass -File $entry -Command unknown-fixture-command -Json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $bad.Success -or !$bad.ErrorCode) {throw 'Failed command must emit one JSON envelope and exit 1.'}
Import-Module (Join-Path $project 'src\HyperVGpuManager.psd1') -Force -DisableNameChecking
$api=Invoke-HyperVGpuApiPreflight
if ($api.Operation -ne 'preflight' -or !$api.OperationId) {throw 'Public API result contract failed.'}
if ($help.Data.Commands -notcontains 'recover-drivers') {throw 'Recovery command missing from discoverable commands.'}
Write-Host 'PASS: 5 CLI process, JSON, exit status, API and command-discovery assertions'
