$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Core/Config.Helpers.ps1','Core/AutoInstallIso.ps1','Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Application/Configuration.ps1')) {. (Join-Path $project "src/$file")}
$script:count=0
function Assert($Value,$Message) {if (!$Value) {throw "Assertion failed: $Message"};$script:count++}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hgm-config-'+[guid]::NewGuid().ToString('N'))
New-Item -Path $fixture -ItemType Directory | Out-Null
$script:HyperVGpuProjectRoot=$fixture
Initialize-HgmDiagnostics (Join-Path $fixture 'logs')
try {
    InitializeHyperVGpuVmProfiles $fixture
    $password='fixture-secret-<>&"'
    $saved=SaveHyperVGpuVmProfile -Name 'Test profile' -ProjectRoot $fixture -VmName 'Test-VM' -Cpu 4 -RamGB 8 -StorageGB 128 -IsoPath 'C:\ISOs\Windows.iso' -EnableAutoInstall -InstallImageIndex 2 -UnattendUsername 'test' -UnattendPassword $password -SetDefault
    Assert ($null -ne $saved) 'profile saved'
    $store=GetHyperVGpuVmProfileStorePath $fixture
    $raw=[IO.File]::ReadAllText($store)
    Assert (!$raw.Contains($password) -and $raw.Contains('ProtectedPassword')) 'password encrypted at rest'
    InitializeHyperVGpuVmProfiles $fixture
    $loaded=GetHyperVGpuVmProfile 'TEST PROFILE' $fixture
    Assert ($loaded.UnattendPassword -eq $password) 'password decrypts after reload'
    Assert ($loaded.InstallImageIndex -eq 2 -and $loaded.IsoPath -eq 'C:\ISOs\Windows.iso') 'media settings survive roundtrip'
    Assert (@(GetHyperVGpuVmProfileInventory $fixture)[0].IsDefault) 'default survives roundtrip'
    $backup=Join-Path $fixture 'backup.json'
    $null=Export-HgmConfiguration $backup
    Assert (![IO.File]::ReadAllText($backup).Contains($password)) 'configuration backup encrypted'
    $null=RemoveHyperVGpuVmProfile 'Test profile' $fixture
    Assert (@(GetHyperVGpuVmProfileInventory $fixture).Count -eq 0) 'profile deleted'
    $null=Import-HgmConfiguration $backup
    Assert ((GetHyperVGpuVmProfile 'Test profile' $fixture).UnattendPassword -eq $password) 'configuration restore preserves settings and secret'
    Assert (Test-Path -LiteralPath "$store.bak") 'atomic save retains previous store'

    $legacy=[pscustomobject]@{SchemaVersion=1;DefaultProfile='Legacy';Profiles=@([pscustomobject]@{Name='Legacy';VmName='Legacy-VM';Cpu=2;RamGB=4;StorageGB=64;UnattendPassword='legacy-fixture-secret';EnableAutoInstall=$true})}
    Write-HgmAtomicJson $store $legacy
    InitializeHyperVGpuVmProfiles $fixture
    Assert ((GetHyperVGpuVmProfile 'Legacy' $fixture).UnattendPassword -eq 'legacy-fixture-secret') 'schema 1 compatibility'
    $null=ExportHyperVGpuVmProfileStore $script:VmProfileStores.project
    Assert (![IO.File]::ReadAllText($store).Contains('legacy-fixture-secret')) 'next save migrates legacy password to encryption'
    # XML parser verifies escaping, locale, setup edition and architecture.
    $locale=[pscustomobject]@{InputLocale='pl-PL';SystemLocale='pl-PL';UILanguage='pl-PL';UserLocale='pl-PL';TimeZone='Central European Standard Time'}
    $xml=[xml](BuildAutoUnattendXml $locale ([pscustomobject]@{Index=2}) ([pscustomobject]@{Username='A&B';Password=$password}))
    Assert ($xml.OuterXml.Contains('pl-PL')) 'locale retained'
    Assert ($xml.SelectSingleNode("//*[local-name()='LocalAccount']/*[local-name()='Name']").InnerText -eq 'A&B') 'username XML escaped'
    Assert ($xml.SelectSingleNode("//*[local-name()='LocalAccount']/*[local-name()='Password']/*[local-name()='Value']").InnerText -eq $password) 'password XML escaped'
    Assert ($xml.SelectSingleNode("//*[local-name()='MetaData']/*[local-name()='Value']").InnerText -eq '2') 'install image index emitted'
    $foreign=[pscustomobject]@{SchemaVersion=2;DefaultProfile='Foreign';Profiles=@([pscustomobject]@{Name='Foreign';VmName='Foreign-VM';Cpu=2;RamGB=4;StorageGB=64;ProtectedPassword='unreadable-fixture-ciphertext';UnattendUsername='test'})}
    Write-HgmAtomicJson $store $foreign
    InitializeHyperVGpuVmProfiles $fixture
    Assert ((GetHyperVGpuVmProfile 'Foreign' $fixture).CredentialUnavailable) 'undecryptable profile does not prevent startup'
    $null=Export-HgmConfiguration $backup
    Assert ([IO.File]::ReadAllText($backup).Contains('unreadable-fixture-ciphertext')) 'foreign encrypted value preserved in backup'
    $null=Import-HgmConfiguration $backup
    Assert ((GetHyperVGpuVmProfile 'Foreign' $fixture).CredentialUnavailable) 'foreign profile restores without discarding its secret'
    $failed=$false;try {SaveHyperVGpuVmProfile -Name Foreign -ProjectRoot $fixture -VmName Foreign-VM -Cpu 2 -RamGB 4 -StorageGB 64 | Out-Null} catch {$failed=$true}
    Assert $failed 'editing an unreadable secret requires replacement'
    [IO.File]::WriteAllText($store,'broken-json')
    $failed=$false;try {ImportHyperVGpuVmProfileStore $fixture | Out-Null} catch {$failed=$true}
    Assert $failed 'invalid store cannot be silently replaced'
    Write-Host "PASS: $script:count profile migration, encryption, backup/restore and unattended XML assertions"
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-config-[0-9a-f]{32}$') {throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
