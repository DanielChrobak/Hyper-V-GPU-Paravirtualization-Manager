$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Platform/Driver.Metadata.ps1','Application/Driver.Deployment.ps1')) {. (Join-Path $root "src/$file")}
$script:checks=0
function Assert($Value,[string]$Message) {if (!$Value) {throw "Assertion failed: $Message"};$script:checks++}
function MustFail([scriptblock]$Action,[string]$Message) {$failed=$false;try {& $Action | Out-Null} catch {$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hgm-transactions-'+[guid]::NewGuid().ToString('N'))
$guest=Join-Path $fixture 'guest';$hostFiles=Join-Path $fixture 'host'
New-Item -Path $guest,$hostFiles -ItemType Directory -Force | Out-Null
Initialize-HgmDiagnostics (Join-Path $fixture 'logs')
function NewPlan([string]$Id='GPU-A',[string[]]$Names=@('a.dll','b.dll')) {
    $files=@()
    foreach ($name in $Names) {
        $source=Join-Path $hostFiles $name
        if (!(Test-Path -LiteralPath $source)) {[IO.File]::WriteAllText($source,"host bytes $name")}
        $files+=[pscustomobject]@{Source=$source;RelativePath="Windows\System32\HostDriverStore\FileRepository\fixture.inf_amd64_hash\$name";Hash=(Get-FileHash -LiteralPath $source).Hash;Length=(Get-Item -LiteralPath $source).Length;Version='1.0'}
    }
    [pscustomobject]@{Files=$files;Entries=@([pscustomobject]@{GpuDeviceId=$Id;GpuName=$Id;DriverVersion='1.0';Paths=@($files | ForEach-Object RelativePath);Folders=@()})}
}
try {
    Assert ((Get-HgmDeviceKey '\\?\PCI#VEN_10DE&DEV_1234#INSTANCE_A#{064092b3-625e-43bf-9eb5-dc845897dd59}\GPUPARAV') -eq 'PCI\VEN_10DE&DEV_1234\INSTANCE_A') 'normalize full device interface path'
    Assert ((Get-HgmDeviceKey 'PCI\VEN_10DE&DEV_1234\A') -ne (Get-HgmDeviceKey 'PCI\VEN_10DE&DEV_1234\B')) 'identical physical models remain distinct'
    foreach ($name in @('../escape','bad*name','CON','name.')) {MustFail {Assert-HgmVmName $name} 'reject unsafe VM names'}
    foreach ($path in @('..\guest-other\a','C:\outside','Windows\..\a','a:stream')) {MustFail {Resolve-HgmContainedPath $guest $path} 'reject traversal, siblings, absolute and alternate streams'}
    MustFail {Assert-HgmDriverDestination '\Windows\System32\cmd.exe'} 'reject shell overwrite'
    $gpu=[pscustomobject]@{TotalVRAM=[UInt64]1000;MinPartitionVRAM=1;MaxPartitionVRAM=700;TotalEncode=[UInt64]::MaxValue;MinPartitionEncode=0;MaxPartitionEncode=[UInt64]::MaxValue;TotalDecode=0;TotalCompute=200;MinPartitionCompute=10;MaxPartitionCompute=200}
    $allocation=Get-HgmResourceSettings $gpu 50
    Assert ($allocation.MaxPartitionVRAM -eq 500) 'percentage uses reported capacity'
    Assert ($allocation.MaxPartitionEncode -eq [UInt64]::MaxValue) 'unmetered engine sentinel preserved'
    Assert ($allocation.MaxPartitionDecode -eq 0) 'unsupported engine stays zero'
    MustFail {Get-HgmResourceSettings ([pscustomobject]@{}) 50} 'unknown capacities never invented'
    MustFail {Get-HgmResourceSettings $gpu 1} 'reject allocation below hardware minimum'

    $plan=NewPlan
    $target=Resolve-HgmContainedPath $guest $plan.Files[0].RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    [IO.File]::WriteAllText($target,'original guest bytes')
    $result=Invoke-HgmDriverTransaction $guest $plan
    Assert ($result.Copied -eq 2) 'first deployment copies both files'
    Assert ((Get-FileHash -LiteralPath $target).Hash -eq $plan.Files[0].Hash) 'destination verified'
    $manifest=@(Get-HgmManifest $guest)
    Assert ($manifest.Count -eq 1 -and $manifest[0].Records.Count -eq 2) 'per-file ownership persisted'
    Assert ($manifest[0].Records[0].OriginalPath) 'pre-existing file has original backup'
    $result=Invoke-HgmDriverTransaction $guest (NewPlan) -SkipExisting
    Assert ($result.Skipped -eq 2 -and $result.Copied -eq 0) 'repeat deployment skips identical hashes'
    [IO.File]::WriteAllText($target,'guest corruption')
    $result=Invoke-HgmDriverTransaction $guest (NewPlan) -SkipExisting
    Assert ($result.Copied -eq 1) 'skip mode repairs drift'
    Assert (@(Test-HgmDriverDrift $guest | Where-Object Status -ne Current).Count -eq 0) 'audit reports current files'

    # Same file is shared by a second GPU; removing one owner preserves it.
    $null=Invoke-HgmDriverTransaction $guest (NewPlan 'GPU-B') -SkipExisting
    $null=Invoke-HgmDriverTransaction $guest $null -RemoveGpuIds @('GPU-A')
    Assert (Test-Path -LiteralPath $target) 'shared file survives first owner cleanup'
    $null=Invoke-HgmDriverTransaction $guest $null -RemoveGpuIds @('GPU-B')
    Assert ([IO.File]::ReadAllText($target) -eq 'original guest bytes') 'last owner cleanup restores original guest bytes'
    Assert (!(Test-Path -LiteralPath (Resolve-HgmContainedPath $guest $plan.Files[1].RelativePath))) 'new file removed with last owner'

    $null=Invoke-HgmDriverTransaction $guest (NewPlan)
    $before=[IO.File]::ReadAllText($target)
    $manifestPath=Resolve-HgmContainedPath $guest 'Windows\System32\HostDriverStore\gpu-driver-manifest.json'
    $beforeManifest=[IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText((Join-Path $hostFiles 'a.dll'),'host updated')
    $script:failOnce=$true
    function Copy-Item {
        [CmdletBinding()]param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($script:failOnce -and $LiteralPath -match '\\stage\\' -and $Destination -match 'b\.dll$') {$script:failOnce=$false;throw 'Injected write failure after another file was applied'}
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -EA Stop
    }
    MustFail {Invoke-HgmDriverTransaction $guest (NewPlan)} 'injected mid-apply failure reaches caller'
    Remove-Item Function:\Copy-Item
    Assert ([IO.File]::ReadAllText($target) -eq $before) 'rollback restores earlier applied bytes'
    Assert ([IO.File]::ReadAllText($manifestPath) -eq $beforeManifest) 'rollback preserves previous manifest'
    Assert ((Repair-HgmDriverTransactions $guest) -eq 0) 'rolled-back journal needs no recovery'

    $script:cancelCalls=0
    $originalCancellation=(Get-Item Function:\Test-HgmCancellation).ScriptBlock
    function Test-HgmCancellation {$script:cancelCalls++;if ($script:cancelCalls -eq 4) {throw (New-Object OperationCanceledException('Injected safe-boundary cancellation'))}}
    MustFail {Invoke-HgmDriverTransaction $guest (NewPlan)} 'cancellation during apply reaches caller'
    Set-Item Function:\Test-HgmCancellation $originalCancellation
    Assert ([IO.File]::ReadAllText($target) -eq $before) 'cancellation rolls back an earlier applied file'
    Assert ([IO.File]::ReadAllText($manifestPath) -eq $beforeManifest) 'cancellation preserves prior manifest'

    [IO.File]::WriteAllText($target,'user-edited file')
    MustFail {Invoke-HgmDriverTransaction $guest $null -RemoveGpuIds @('GPU-A')} 'cleanup refuses guest-modified files'
    Assert ([IO.File]::ReadAllText($target) -eq 'user-edited file') 'guest modification preserved'
    Assert ([IO.File]::ReadAllText($manifestPath) -eq $beforeManifest) 'cleanup conflict retains ownership record'
    $null=Invoke-HgmDriverTransaction $guest (NewPlan)
    # Simulate a process dying after it wrote a destination but before commit.
    $tx='Windows\System32\HostDriverStore\.manager\transactions\crash-fixture'
    $backup=Resolve-HgmContainedPath $guest "$tx\original.bin"
    New-Item -Path (Split-Path -Parent $backup) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($backup,'recovery-original')
    [IO.File]::WriteAllText($target,'interrupted-copy')
    $journal=[pscustomobject]@{State='Applying';Items=@([pscustomobject]@{RelativePath=$plan.Files[0].RelativePath;RollbackPath="$tx\original.bin";PreviousHash=(Get-FileHash -LiteralPath $backup).Hash;Existed=$true;Applied=$true})}
    Write-HgmAtomicJson (Resolve-HgmContainedPath $guest "$tx\journal.json") $journal
    Assert ((Repair-HgmDriverTransactions $guest) -eq 1) 'interrupted transaction recovered'
    Assert ([IO.File]::ReadAllText($target) -eq 'recovery-original') 'recovery restores verified original bytes'
    Assert ((Repair-HgmDriverTransactions $guest) -eq 0) 'recovery is idempotent'
    [IO.File]::WriteAllText($manifestPath,'invalid-json')
    MustFail {Get-HgmManifest $guest} 'corrupt manifest is never discarded'

    $policyGuest=Join-Path $fixture 'policy-guest';New-Item -Path $policyGuest -ItemType Directory | Out-Null
    $promotionPlan=NewPlan 'GPU-Policy' @('a.dll')
    $promotionPlan.Files[0] | Add-Member NoteProperty Policy 'WhenNewer'
    $policyTarget=Resolve-HgmContainedPath $policyGuest $promotionPlan.Files[0].RelativePath
    New-Item -Path (Split-Path -Parent $policyTarget) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($policyTarget,'newer guest runtime')
    (Get-Item -LiteralPath $policyTarget).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(1)
    $policyResult=Invoke-HgmDriverTransaction $policyGuest $promotionPlan
    Assert ($policyResult.Skipped -eq 1) 'WhenNewer is honored during deployment'
    Assert ([IO.File]::ReadAllText($policyTarget) -eq 'newer guest runtime') 'newer guest runtime survives deployment'
    $null=Invoke-HgmDriverTransaction $policyGuest $null -RemoveGpuIds @('GPU-Policy')
    Assert ([IO.File]::ReadAllText($policyTarget) -eq 'newer guest runtime') 'skipped unowned runtime survives cleanup'

    $script:HgmCancellation=New-Object Threading.CancellationTokenSource
    $script:HgmCancellation.Cancel()
    MustFail {Test-HgmCancellation} 'cancellation token observed'
    $script:HgmCancellation.Dispose();$script:HgmCancellation=$null
    Write-Host "PASS: $script:checks domain, ownership, deployment, rollback and recovery assertions"
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-transactions-[0-9a-f]{32}$') {throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
