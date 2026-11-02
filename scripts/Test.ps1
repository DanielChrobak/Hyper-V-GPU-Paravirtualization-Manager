[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$parseErrors=@()
foreach ($file in Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notmatch '[\\/](graphify-out|artifacts|\.codex)[\\/]'}) {
    $tokens=$null;$issues=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$issues)
    $parseErrors+=@($issues | ForEach-Object {"$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)"})
}
if ($parseErrors.Count) {throw ($parseErrors -join [Environment]::NewLine)}
Test-ModuleManifest (Join-Path $project 'src\HyperVGpuManager.psd1') -EA Stop | Out-Null
[xml](Get-Content -LiteralPath (Join-Path $project 'src\Desktop\Window.xaml') -Raw) | Out-Null
$engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($test in @('Transactions.Tests.ps1','Driver.Metadata.Tests.ps1','Configuration.Tests.ps1','Workflows.Tests.ps1','DriverInjection.Tests.ps1','Cli.Tests.ps1')) {
    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project "tests\$test")
    if ($LASTEXITCODE -ne 0) {throw "Failed: $test"}
}
$pester=Get-Module -ListAvailable Pester | Where-Object {$_.Version.Major -in @(3,4)} | Sort-Object Version -Descending | Select-Object -First 1
if (!$pester) {throw 'Install Pester 4.10.1 (development only) to run the legacy disk regression suite.'}
Import-Module $pester.Path -Force
$result=Invoke-Pester -Script (Join-Path $project 'tests\Vhd.Operations.Tests.ps1') -PassThru
if ($result.FailedCount) {throw 'Disk regression tests failed.'}
Write-Host 'All syntax, manifest, XML, workflow, file transaction, CLI and disk checks passed.'
