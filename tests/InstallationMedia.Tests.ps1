# Real temporary-file publication/cleanup; no ADK process, ISO mount or VM changes.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/InstallationMedia.ps1','Application/Workflows.ps1')) {. (Join-Path $project "src/$file")}
$script:checks=0
function Assert($Value,$Message) {if (!$Value) {throw "Assertion failed: $Message"};$script:checks++}
function MustFail([scriptblock]$Action,$Message) {$failed=$false;try {& $Action | Out-Null} catch {$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hgm-media-'+[guid]::NewGuid().ToString('N'))
$script:Paths=@{ISO=(Join-Path $fixture 'generated')}
New-Item -ItemType Directory -Path $script:Paths.ISO -Force | Out-Null
Initialize-HgmDiagnostics (Join-Path $fixture 'logs')
function NewStage([string]$Contents) {
    $path=Join-Path $fixture ([guid]::NewGuid().ToString('N')+'.iso')
    [IO.File]::WriteAllText($path,$Contents)
    return $path
}
try {
    $first=Publish-HgmAutoIso (NewStage 'first configuration') Fixture
    Assert ((Split-Path -Leaf $first) -eq 'Fixture-AutoInstall.iso') 'first publication keeps the established filename'
    Assert (Test-HgmGeneratedIso $first Fixture) 'original filename remains recognized'
    $firstMarker=[IO.File]::ReadAllText("$first.manager.json")
    $second=Publish-HgmAutoIso (NewStage 'second configuration') Fixture
    Assert ($second -ne $first) 'existing generated ISO no longer blocks a retry'
    Assert ((Split-Path -Leaf $second) -match '^Fixture-AutoInstall-[0-9a-f]{32}\.iso$') 'collision uses a unique generated filename'
    Assert ([IO.File]::ReadAllText($first) -eq 'first configuration') 'old media is preserved byte for byte'
    Assert ([IO.File]::ReadAllText("$first.manager.json") -eq $firstMarker) 'old ownership metadata is preserved'
    Assert ([IO.File]::ReadAllText($second) -eq 'second configuration') 'new settings receive freshly built media'
    Assert (Test-HgmGeneratedIso $second Fixture) 'uniquely named owned media recognized for cleanup'
    Assert (!(Test-HgmGeneratedIso $second OtherVM)) 'another VM cannot claim the media'
    $third=Publish-HgmAutoIso (NewStage 'third configuration') Fixture
    Assert ($third -ne $first -and $third -ne $second) 'repeated retries do not reuse stale media'

    $unowned=Join-Path $script:Paths.ISO ('Fixture-AutoInstall-'+[guid]::NewGuid().ToString('N')+'.iso')
    [IO.File]::WriteAllText($unowned,'unowned media')
    Assert (!(Test-HgmGeneratedIso $unowned Fixture)) 'similar filenames without ownership metadata are preserved'
    Write-HgmAtomicJson "$unowned.manager.json" ([pscustomobject]@{Kind='GeneratedInstallationMedia';VmName='OtherVM'})
    Assert (!(Test-HgmGeneratedIso $unowned Fixture)) 'mismatched ownership metadata is rejected'
    $external=NewStage 'external installation media'
    Assert (!(Test-HgmGeneratedIso $external Fixture)) 'external ISO cannot be claimed for cleanup'
    $originalWriter=(Get-Item Function:\Write-HgmAtomicJson).ScriptBlock
    function Write-HgmAtomicJson {param($Path,$Value) throw 'Injected ownership-file write failure'}
    $before=@(Get-ChildItem -LiteralPath $script:Paths.ISO -File -Filter *.iso).Count
    MustFail {Publish-HgmAutoIso (NewStage 'failed publication') Fixture} 'publication failure reaches the caller'
    Set-Item Function:\Write-HgmAtomicJson $originalWriter
    Assert (@(Get-ChildItem -LiteralPath $script:Paths.ISO -File -Filter *.iso).Count -eq $before) 'failed publication removes only its fresh output'
    Assert ([IO.File]::ReadAllText($first) -eq 'first configuration') 'failed publication never changes previous media'

    # Exercise the actual VM-deletion workflow against local host stubs. It must
    # remove the attached owned suffix file and preserve earlier/unowned media.
    $script:registered=$true
    function Assert-HgmVmOffline {param($Name,[switch]$Shutdown) [pscustomobject]@{Name=$Name;State='Off'}}
    function Get-HgmVmDisks {param($Name) return @()}
    function Get-VMDvdDrive {param($VMName,$EA) [pscustomobject]@{Path=$second}}
    function Get-VM {param($Name,$EA) return @()}
    function Remove-VM {param($VM,[switch]$Force,$EA) $script:registered=$false}
    $result=Remove-HgmVirtualMachine Fixture -Force -DeleteFiles
    Assert (!$script:registered) 'isolated VM registration removed'
    Assert (!(Test-Path -LiteralPath $second) -and !(Test-Path -LiteralPath "$second.manager.json")) 'attached unique ISO and its marker cleaned up'
    Assert ($result.DeletedFiles -contains $second) 'deletion result reports the unique generated ISO'
    Assert ((Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $third) -and (Test-Path -LiteralPath $unowned) -and (Test-Path -LiteralPath $external)) 'previous, unattached and external media are preserved'
    Write-Host "PASS: $script:checks installation-media collision, ownership, publication and cleanup assertions"
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-media-[0-9a-f]{32}$') {throw 'Unsafe media fixture cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
