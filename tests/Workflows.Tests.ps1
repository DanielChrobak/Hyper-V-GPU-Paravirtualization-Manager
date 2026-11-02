$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
foreach ($file in @('Core/Config.Helpers.ps1','Domain/Validation.ps1','Infrastructure/Diagnostics.ps1','Application/Workflows.ps1')) {. (Join-Path $project "src/$file")}
$script:checks=0
function Assert($Value,$Message) {if (!$Value) {throw "Assertion failed: $Message"};$script:checks++}
function MustFail([scriptblock]$Action,$Message) {$failed=$false;try {& $Action | Out-Null} catch {$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hgm-workflows-'+[guid]::NewGuid().ToString('N'))
New-Item -Path $fixture -ItemType Directory | Out-Null
Initialize-HgmDiagnostics (Join-Path $fixture 'logs')
$script:Paths=@{ISO=(Join-Path $fixture 'iso')}
$script:vm=$null;$script:removed=0;$script:configured=$false;$script:failConfig=$false;$script:free=[long]1TB
# Every host boundary is a local stub. These tests cannot operate a real VM.
function Get-VM {param($Name,$EA) if ($script:vm -and (!$Name -or $script:vm.Name -eq $Name)) {return $script:vm}}
function Get-HgmExactVm {param($Name) if (!$script:vm -or $script:vm.Name -ne $Name) {throw 'VM missing'};return $script:vm}
function Get-HgmVmDisks {param($Name) return @()}
function GetFreeBytesForPath {param($Path) return $script:free}
function Get-VHD {param($Path,$EA) [pscustomobject]@{Attached=$false}}
function TestHyperVCmdletParameter {param($CmdletName,$ParameterName) return $true}
function Test-HgmCancellation {}
function Resolve-HgmAssignedPath {param($Adapter) return $Adapter.InstancePath}
function ResolveVHDChain {param($Path) @{Paths=@($Path)}}
function New-VM {
    param($Name,$MemoryStartupBytes,$Generation,$NewVHDPath,$NewVHDSizeBytes,$EA)
    [IO.File]::WriteAllText($NewVHDPath,'new-vhd')
    $script:vm=[pscustomobject]@{Name=$Name;MemoryStartup=$MemoryStartupBytes;Generation=$Generation;ProcessorCount=1;State='Off';Id=[guid]::NewGuid();GuestControlledCacheTypes=$false;LowMemoryMappedIoSpace=[UInt64]2GB;HighMemoryMappedIoSpace=[UInt64]64GB}
    return $script:vm
}
function Set-VMProcessor {param($VM,$Count,$EA) if ($script:failConfig) {throw 'Injected CPU configuration failure'};$VM.ProcessorCount=$Count}
function Set-VMMemory {param($VM,$DynamicMemoryEnabled,$EA)}
function Set-VM {param($VM,$CheckpointType,$AutomaticStopAction,$AutomaticStartAction,$AutomaticCheckpointsEnabled,$EnhancedSessionTransportType,$GuestControlledCacheTypes,$LowMemoryMappedIoSpace,$HighMemoryMappedIoSpace,$EA) $script:configured=$true}
function Set-VMFirmware {param($VM,$EnableSecureBoot,$BootOrder,$EA)}
function Set-VMKeyProtector {param($VM,[switch]$NewLocalKeyProtector,$EA)}
function Enable-VMTPM {param($VM,$EA)}
function Remove-VM {param($VM,$Name,[switch]$Force,$EA) $script:vm=$null;$script:removed++}
function Get-VMDvdDrive {param($VMName,$EA) return @()}
try {
    $config=[pscustomobject]@{Name='Fixture';CPU=4;RAM=8;Storage=64;Path=$fixture;ISO=$null}
    $vhd=Join-Path $fixture 'Fixture.vhdx'
    [IO.File]::WriteAllText($vhd,'existing-vhd')
    $script:free=0
    MustFail {New-HgmVirtualMachine $config -OverwriteVhd} 'free-space failure surfaces before overwrite'
    Assert ([IO.File]::ReadAllText($vhd) -eq 'existing-vhd') 'low space preserves previous VHD'
    $script:free=1TB;$script:failConfig=$true
    MustFail {New-HgmVirtualMachine $config -OverwriteVhd} 'configuration failure reaches caller'
    Assert ([IO.File]::ReadAllText($vhd) -eq 'existing-vhd') 'failed create restores previous VHD'
    Assert (!$script:vm -and $script:removed -eq 1) 'partial VM removed on failure'
    $script:failConfig=$false
    $created=New-HgmVirtualMachine $config -OverwriteVhd
    Assert ($created.VmName -eq 'Fixture') 'successful create returns target'
    Assert ([IO.File]::ReadAllText($created.PreviousVhd) -eq 'existing-vhd') 'successful overwrite retains old disk backup'
    Assert ($script:vm.ProcessorCount -eq 4 -and $script:configured) 'CPU and policies configured'
    MustFail {New-HgmVirtualMachine $config -OverwriteVhd} 'duplicate VM rejected'
    MustFail {Remove-HgmVirtualMachine Fixture} 'deletion requires force'
    # Bind a host boundary that only accepts an already-off simulated VM.
    function Assert-HgmVmOffline {param($Name,[switch]$Shutdown) if ($script:vm.State -ne 'Off') {throw 'VM must be off'};return $script:vm}
    $result=Remove-HgmVirtualMachine Fixture -Force
    Assert (!$script:vm) 'VM registration deleted'
    Assert (Test-Path -LiteralPath $vhd) 'disk retained unless DeleteFiles requested'

    $script:vm=[pscustomobject]@{Name='Fixture';Id=[guid]::NewGuid();State='Off';GuestControlledCacheTypes=$false;LowMemoryMappedIoSpace=[UInt64]2GB;HighMemoryMappedIoSpace=[UInt64]64GB}
    $script:gpu=[pscustomobject]@{TotalVRAM=1000;MinPartitionVRAM=1;MaxPartitionVRAM=1000;TotalEncode=1000;TotalDecode=1000;TotalCompute=1000}
    $script:adapters=@();$script:gpuSettings=@{};$script:failGpu=$false;$script:mmio=@{}
    function GetPartitionableGpuByPath {param($Path) return $script:gpu}
    function GetPartitionableGPUs {return @($script:gpu)}
    function Get-HgmVmStatePath {param($Vm) Join-Path $fixture 'vm-state.json'}
    function Get-VMGpuPartitionAdapter {param($VMName,$EA) return $script:adapters}
    function Add-VMGpuPartitionAdapter {
        param($VMName,$InstancePath,[switch]$Passthru,$EA)
        $adapter=[pscustomobject]@{InstancePath=$InstancePath;AdapterId='fixture-adapter'}
        $script:adapters=@($adapter);return $adapter
    }
    function Remove-VMGpuPartitionAdapter {param($VMGpuPartitionAdapter,$EA) $script:adapters=@()}
    function Set-VMGpuPartitionAdapter {
        param($VMGpuPartitionAdapter,$MinPartitionVRAM,$MaxPartitionVRAM,$OptimalPartitionVRAM,$MinPartitionEncode,$MaxPartitionEncode,$OptimalPartitionEncode,$MinPartitionDecode,$MaxPartitionDecode,$OptimalPartitionDecode,$MinPartitionCompute,$MaxPartitionCompute,$OptimalPartitionCompute,$EA)
        if ($script:failGpu) {throw 'Injected GPU settings failure'}
        foreach ($key in $PSBoundParameters.Keys) {if ($key -match 'Partition') {$VMGpuPartitionAdapter | Add-Member NoteProperty $key $PSBoundParameters[$key] -Force}}
    }
    function Set-VM {param($VM,$GuestControlledCacheTypes,$LowMemoryMappedIoSpace,$HighMemoryMappedIoSpace,$EA) $script:mmio=@{Low=$LowMemoryMappedIoSpace;High=$HighMemoryMappedIoSpace;Cache=$GuestControlledCacheTypes}}
    $configured=Set-HgmGpu Fixture 'PCI\VEN_10DE&DEV_1234\ONE' 50
    Assert ($configured.Resources.MaxPartitionVRAM -eq 500) 'GPU allocation uses hardware total'
    Assert ($script:mmio.Low -eq 2GB -and $script:mmio.High -eq 64GB) 'custom larger MMIO retained'
    $again=Set-HgmGpu Fixture 'PCI\VEN_10DE&DEV_1234\ONE' 25
    Assert ($script:adapters.Count -eq 1 -and $again.Resources.MaxPartitionVRAM -eq 250) 'repeat assignment updates one adapter'
    $removed=Remove-HgmGpu Fixture 'PCI\VEN_10DE&DEV_1234\ONE'
    Assert ($removed.Removed -eq 1 -and !$script:adapters.Count) 'selected adapter removed and verified'
    Assert ($script:mmio.Cache -eq $false -and $script:mmio.High -eq 64GB) 'last removal restores original MMIO snapshot'
    $script:failGpu=$true
    MustFail {Set-HgmGpu Fixture 'PCI\VEN_10DE&DEV_1234\TWO' 50} 'GPU configuration failure surfaces'
    Assert (!$script:adapters.Count) 'new GPU adapter removed on configuration failure'
    Assert ($script:mmio.Cache -eq $false) 'failure restores original cache setting'
    Write-Host "PASS: $script:checks VM lifecycle, rollback, GPU allocation and MMIO assertions"
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')+'\'
    if (!$safe.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^hgm-workflows-[0-9a-f]{32}$') {throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
