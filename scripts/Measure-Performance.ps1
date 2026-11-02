[CmdletBinding()]
param([string]$BaselineCommit='5bfbca4',[string]$WorkerRoot,[string]$Fixture,[string]$Mode)
$ErrorActionPreference='Stop'
if ($WorkerRoot) {
    $InformationPreference='SilentlyContinue'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if ($Mode -eq 'Baseline') {
        foreach ($file in @('Core/Config.Helpers.ps1','Core/Gpu/Gpu.Helpers.ps1','Core/Vhd.Operations.ps1','Core/Vm.Helpers.ps1','Core/AutoInstallIso.ps1','Core/Main.Actions.ps1','Api/Manager.Api.ps1','Cli/Interactive.Menu.ps1','Cli/Command.Dispatcher.ps1')) {. (Join-Path $WorkerRoot "src/$file")}
    } else {
        . (Join-Path $WorkerRoot 'src/Core/Config.Helpers.ps1')
        . (Join-Path $WorkerRoot 'src/Core/Gpu/Gpu.Helpers.ps1')
        . (Join-Path $WorkerRoot 'src/Core/Main.Actions.ps1')
    }
    $load=$watch.Elapsed.TotalMilliseconds
    $script:HyperVGpuProjectRoot=$Fixture
    $guest=Join-Path $Fixture "guest-$Mode";New-Item -Path $guest -ItemType Directory | Out-Null
    $package=Join-Path $Fixture 'fixture.inf_amd64_hash'
    $gpu=[pscustomobject]@{DeviceID='PCI\VEN_10DE&DEV_1234\Fixture';DeviceName='Fixture';DriverVersion='1.0'}
    function Box {};function Spin {};function Log {}
    function Get-VM {param($Name,$EA) [pscustomobject]@{Name='Fixture';State='Off'}}
    function Test-HgmAdministrator {return $true}
    function Get-VMGpuPartitionAdapter {param($VMName,$EA) [pscustomobject]@{InstancePath=$gpu.DeviceID}}
    function GetGpuDisplayEntries {param($Adapters) [pscustomobject]@{Label='Fixture'}}
    function ResolvePartitionableDevice {param($Path) [pscustomobject]@{Class='Display'}}
    function FindGPU {param($Path,$PreferredClass) return $gpu}
    function EnsureOff {return $true}
    function Get-VMHardDiskDrive {param($VMName,$EA) [pscustomobject]@{Path='fixture.vhdx'}}
    function MountVHD {param($VHD) @{Path=$guest;VHD='fixture.vhdx'}}
    function UnmountVHD {}
    function GetDrivers {param($GPU) @{Folders=@($package);Files=@();Missing=@();InfPath=$null;Strategy='Fixture'}}
    if ($Mode -eq 'Replacement') {Initialize-HgmDiagnostics (Join-Path $Fixture 'logs')}
    $watch.Restart();$ok=InstallDrivers -VMName Fixture -NonInteractive;$first=$watch.Elapsed.TotalMilliseconds
    if (!$ok) {throw 'Fixture deployment failed.'}
    $watch.Restart();$ok=InstallDrivers -VMName Fixture -NonInteractive -SkipExisting;$repeat=$watch.Elapsed.TotalMilliseconds
    if (!$ok) {throw 'Fixture repeat deployment failed.'}
    [pscustomobject]@{Mode=$Mode;LoadMs=[math]::Round($load,1);InitialFixtureMs=[math]::Round($first,1);RepeatFixtureMs=[math]::Round($repeat,1)} | ConvertTo-Json -Compress
    exit
}
$project=Split-Path -Parent $PSScriptRoot
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('hgm-performance-'+[guid]::NewGuid().ToString('N'))
New-Item -Path $temporary -ItemType Directory | Out-Null
try {
    $archive=Join-Path $temporary 'baseline.zip'
    git -C $project archive --format=zip "--output=$archive" $BaselineCommit
    if ($LASTEXITCODE -ne 0) {throw 'Could not export the baseline commit.'}
    $baseline=Join-Path $temporary 'baseline';Expand-Archive -LiteralPath $archive -DestinationPath $baseline
    $package=Join-Path $temporary 'fixture.inf_amd64_hash';New-Item -Path $package -ItemType Directory | Out-Null
    $bytes=New-Object byte[] (16KB)
    (New-Object Random(42)).NextBytes($bytes)
    for ($i=0;$i -lt 100;$i++) {[IO.File]::WriteAllBytes((Join-Path $package "file-$i.dll"),$bytes)}
    $engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($variant in @('Baseline','Replacement')) {
        $worker=if ($variant -eq 'Baseline') {$baseline} else {$project}
        $output=& $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WorkerRoot $worker -Fixture $temporary -Mode $variant
        if ($LASTEXITCODE -ne 0) {throw 'Performance worker failed.'}
        $json=$output | Where-Object {$_ -match '^\{"Mode"'} | Select-Object -Last 1
        $json | ConvertFrom-Json
    }
    Write-Host 'Fixture: 100 x 16 KiB files, local filesystem, no real guest/GPU calls. Single run per variant; timings are indicative.'
} finally {
    $safe=[IO.Path]::GetFullPath($temporary);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-performance-[0-9a-f]{32}$') {throw 'Unsafe benchmark cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
