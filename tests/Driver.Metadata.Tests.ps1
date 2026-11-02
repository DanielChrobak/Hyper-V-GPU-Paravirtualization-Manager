$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/Driver.Metadata.ps1')) {. (Join-Path $project "src/$file")}
$script:checks=0
function Assert($Value,$Message) {if (!$Value) {throw "Assertion failed: $Message"};$script:checks++}
function MustFail([scriptblock]$Action,$Message) {$failed=$false;try {& $Action | Out-Null} catch {$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hgm-metadata-'+[guid]::NewGuid().ToString('N'))
$package=Join-Path $fixture 'active.inf_amd64_hash'
New-Item -Path $package -ItemType Directory -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $package 'nvcuda_loader64.dll'),'loader64')
    [IO.File]::WriteAllText((Join-Path $package 'mfx_loader_dll_hw32.dll'),'loader32')
    $rule=ConvertTo-HgmPromotion $package CopyToVmWhenNewer @('nvcuda_loader64.dll','nvcuda.dll')
    Assert ($rule.D -eq '\Windows\System32\nvcuda.dll' -and $rule.Policy -eq 'WhenNewer') 'driver-declared rename and policy'
    $intel=ConvertTo-HgmPromotion $package CopyToVmOverwriteWow64 @('libmfxhw32.dll')
    Assert ($intel.S -like '*mfx_loader_dll_hw32.dll') 'Intel package-scoped media SDK alias'
    Assert ($intel.D -eq '\Windows\SysWOW64\libmfxhw32.dll') 'Wow64 mapping preserves requested guest filename'
    MustFail {ConvertTo-HgmPromotion $package CopyToVmOverwrite @('..\other.dll','other.dll')} 'promotion source cannot escape active package'
    MustFail {ConvertTo-HgmPromotion $package CopyToVmOverwrite @('nvcuda_loader64.dll','..\escape.dll')} 'destination cannot be a path'
    MustFail {ConvertTo-HgmPromotion $package CopyToVmOverwrite @('nvcuda_loader64.dll','cmd.exe')} 'promotion cannot overwrite shell'
    MustFail {ConvertTo-HgmPromotion $package CopyToVmOverwrite @('missing.dll')} 'missing required mapping source diagnosed'
    MustFail {ConvertTo-HgmPromotion $package CopyToVmOverwrite @('one','two','three')} 'malformed registry multi-string rejected'
    $source=Join-Path $package 'nvcuda_loader64.dll';$destination=Join-Path $fixture 'nvcuda.dll'
    Assert (Test-HgmSourceNewer $source $destination) 'new destination needs promotion'
    [IO.File]::WriteAllText($destination,'newer guest')
    (Get-Item -LiteralPath $destination).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(1)
    Assert (!(Test-HgmSourceNewer $source $destination)) 'WhenNewer preserves newer destination'
    (Get-Item -LiteralPath $destination).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1)
    Assert (Test-HgmSourceNewer $source $destination) 'WhenNewer updates older destination'
    . (Join-Path $project 'src/Core/Gpu/Gpu.Helpers.ps1')
    . (Join-Path $project 'src/Platform/Gpu.ps1')
    $script:hostDevices=@([pscustomobject]@{Name='PCI\VEN_10DE&DEV_1234\ONE'})
    function GetPartitionableGPUs {return $script:hostDevices}
    Assert ((Resolve-HgmAssignedPath ([pscustomobject]@{})) -eq 'PCI\VEN_10DE&DEV_1234\ONE') 'legacy adapter resolves only with a single host device'
    $script:hostDevices+=@([pscustomobject]@{Name='PCI\VEN_10DE&DEV_1234\TWO'})
    MustFail {Resolve-HgmAssignedPath ([pscustomobject]@{})} 'legacy adapter with multiple devices is not guessed'
    Write-Host "PASS: $script:checks driver promotion, aliases, scoping and replacement policy assertions"
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-metadata-[0-9a-f]{32}$') {throw 'Unsafe metadata fixture cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
