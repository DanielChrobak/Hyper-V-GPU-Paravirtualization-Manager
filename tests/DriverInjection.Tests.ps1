# Hardware-free regression checks. Run with Windows PowerShell 5.1 or PowerShell 7:
# powershell -NoProfile -File .\tests\DriverInjection.Tests.ps1
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'src\Core\Config.Helpers.ps1')
. (Join-Path $projectRoot 'src\Core\Gpu\Gpu.Helpers.ps1')
. (Join-Path $projectRoot 'src\Core\Main.Actions.ps1')

$script:assertions = 0
function Assert($Condition, $Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
    $script:assertions++
}
function Box {}
function Spin {}
function Log($Message, $Level) { $script:messages.Add("${Level}: $Message") }

# Replace only hardware/OS discovery and disk mounting. Package discovery, copying,
# hash comparison, destination mapping, and manifest serialization run for real.
function Get-CimInstance {
    param($ClassName, $Filter, $EA)
    foreach ($path in $script:associatedFiles) {
        [PSCustomObject]@{ Dependent = 'CIM_DataFile.Name="' + $path.Replace('\', '\\') + '"' }
    }
}
function GetCompatManagementInstances { return @() }
function ResolveInfPathForGpu { return $script:infPath }
function Get-VMGpuPartitionAdapter {
    param($VMName, $EA)
    [PSCustomObject]@{ InstancePath = $script:gpu.DeviceID }
}
function GetGpuDisplayEntries { [PSCustomObject]@{ Label = 'Fixture GPU' } }
function ResolvePartitionableDevice { [PSCustomObject]@{ Class = 'Display' } }
function FindGPU { return $script:gpu }
function EnsureOff { return $true }
function Test-HgmAdministrator { return $true }
function Get-VM { param($Name,$EA) [pscustomobject]@{Name='Fixture';State='Off'} }
function Get-WindowsDriver { param([switch]$Online,$Driver,$EA) [pscustomobject]@{OriginalFileName=(Join-Path (Split-Path -Parent $script:mainFile) 'display.inf')} }
function Get-VMHardDiskDrive {
    param($VMName, $EA)
    [PSCustomObject]@{ Path = 'fixture.vhdx' }
}
function MountVHD { return @{ Path = $script:guestRoot } }
function UnmountVHD { $script:unmountCount++ }

function NewFixtureFile($RelativePath, $Content = 'fixture driver bytes') {
    $path = Join-Path $script:fixtureRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Content)
    return $path
}

$originalWindir = $env:windir
$script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('gpu-driver-tests-' + [guid]::NewGuid())
$script:guestRoot = Join-Path $script:fixtureRoot 'Guest'
$script:messages = New-Object 'System.Collections.Generic.List[string]'
$script:unmountCount = 0
$script:infPath = $null
$script:gpu = [PSCustomObject]@{
    DeviceID = 'PCI\VEN_1002&DEV_7550\FIXTURE'
    DeviceName = 'AMD fixture GPU'
    DeviceClass = 'DISPLAY'
    DriverProviderName = 'Advanced Micro Devices, Inc.'
    DriverVersion = '1.0'
}

try {
    $env:windir = Join-Path $script:fixtureRoot 'Host\Windows'
    $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $mainFile = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\display.inf_amd64_main\display.sys'
    $oglOld = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdogl.inf_amd64_old\atioglxx.dll'
    $oglNew = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdogl.inf_amd64_new\atioglxx.dll'
    $vulkan = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdvlk.inf_amd64_current\amdvlk64.dll'
    $nested = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdvlk.inf_amd64_current\data\settings.json'
    $hidden = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdvlk.inf_amd64_current\hidden.bin'
    (Get-Item -LiteralPath $hidden).Attributes = [IO.FileAttributes]::Hidden
    $null = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\amdogl.inf_x86_ignore\atioglxx.dll'
    $null = NewFixtureFile 'Host\Windows\System32\DriverStore\FileRepository\unrelated.inf_amd64_ignore\other.dll'
    # Deliberately misleading timestamps must not exclude an exact hashed path.
    (Get-Item (Split-Path -Parent $oglOld)).LastWriteTime = (Get-Date).AddDays(1)
    $script:associatedFiles = @($mainFile)
    $script:HasGetCimInstance = $true

    $driver = GetDrivers $script:gpu
    Assert ($driver.Folders.Count -eq 4) "WMI-only display package plus all three unreferenced AMD companion folders. Found: $($driver.Folders -join ', '); logs: $($script:messages -join '; ')"
    Assert ($driver.Strategy -match 'AmdCompanionPackages') 'manifest resolver identifies companion discovery'
    Assert ($driver.Folders -contains (Split-Path -Parent $oglOld)) 'retain older exact hashed package path'
    Assert ($driver.Folders -contains (Split-Path -Parent $oglNew)) 'retain newer package alongside older package'
    Assert ((GetDriverStoreFolderRoot $mainFile) -eq (Split-Path -Parent $mainFile)) 'use the actual Windows directory'
    Assert ($null -eq (GetDriverStoreFolderRoot "$repo-unrelated\file.dll")) 'reject paths outside FileRepository'
    $script:associatedFiles = @()
    Assert (@((GetDrivers $script:gpu).Folders).Count -eq 3) 'companion discovery also works with no WMI associations or INF'
    $script:associatedFiles = @($mainFile)
    Write-Host 'PASS: AMD companion discovery without WMI/INF companion references'

    foreach ($vendor in @('10DE', '8086')) {
        $script:gpu.DeviceID = "PCI\VEN_$vendor&DEV_1234\FIXTURE"
        Assert (@(GetGpuCompanionDriverFolders $script:gpu).Count -eq 0) "no AMD packages for PCI vendor $vendor, even with misleading provider text"
        Assert (@((GetDrivers $script:gpu).Folders).Count -eq 1) "preserve primary package for PCI vendor $vendor"
    }
    $script:gpu.DeviceID = 'PCI\VEN_1002&DEV_7550\FIXTURE'
    $script:gpu.DeviceClass = 'MEDIA'
    Assert (@(GetGpuCompanionDriverFolders $script:gpu).Count -eq 0) 'do not add graphics packages for a non-display AMD device'
    $script:gpu.DeviceClass = 'DISPLAY'
    $script:gpu.DeviceID = $null
    Assert (@(GetGpuCompanionDriverFolders $script:gpu).Count -eq 3) 'provider fallback when PCI metadata is absent'
    $script:gpu.DeviceID = 'PCI\VEN_1002&DEV_7550\FIXTURE'
    Write-Host 'PASS: NVIDIA/Intel exclusion, device class guard, and AMD provider fallback'

    # Exercise the normal installer and its repeat-install paths against a plain
    # temporary directory standing in for a mounted guest VHD.
    Assert (InstallDrivers -VMName Fixture -NonInteractive) 'first install succeeds'
    $guestRepo = Join-Path $script:guestRoot 'Windows\System32\HostDriverStore\FileRepository'
    $guestOgl = Join-Path $guestRepo 'amdogl.inf_amd64_new\atioglxx.dll'
    $guestVulkan = Join-Path $guestRepo 'amdvlk.inf_amd64_current\amdvlk64.dll'
    Assert (TestFileContentEqual $oglNew $guestOgl) 'OpenGL DLL at exact guest package path'
    Assert (TestFileContentEqual $vulkan $guestVulkan) 'Vulkan DLL at exact guest package path'
    Assert (Test-Path (Join-Path $guestRepo 'amdvlk.inf_amd64_current\data\settings.json')) 'nested package contents copied'
    Assert (Test-Path (Join-Path $guestRepo 'amdvlk.inf_amd64_current\hidden.bin')) 'hidden package contents copied'
    $manifest = @(ReadDriverManifest $script:guestRoot)
    Assert ($manifest.Count -eq 1 -and $manifest[0].Folders.Count -eq 4) 'manifest tracks all four packages for cleanup'

    [IO.File]::WriteAllText($oglNew, 'updated host OpenGL bytes')
    Assert (InstallDrivers -VMName Fixture -NonInteractive) 'repeat install without SkipExisting succeeds'
    Assert (TestFileContentEqual $oglNew $guestOgl) 'repeat install updates existing package in place'
    Assert (!(Test-Path (Join-Path $guestRepo 'amdogl.inf_amd64_new\amdogl.inf_amd64_new'))) 'repeat install never nests a package'
    $unchangedTime = (Get-Item $guestOgl).LastWriteTimeUtc
    Assert (InstallDrivers -VMName Fixture -NonInteractive -SkipExisting) 'unchanged skip install succeeds'
    Assert ((Get-Item $guestOgl).LastWriteTimeUtc -eq $unchangedTime) 'unchanged files are not rewritten'
    [IO.File]::WriteAllText($guestOgl, 'corrupt guest bytes')
    Assert (InstallDrivers -VMName Fixture -NonInteractive -SkipExisting) 'skip mode repairs changed files'
    Assert (TestFileContentEqual $oglNew $guestOgl) 'hash comparison repairs corrupt DLL'
    Write-Host 'PASS: real copy, exact guest paths, repeat install, hash skip/repair, and manifest'

    $manifestPath = GetDriverManifestFilePath $script:guestRoot
    $priorManifest = [IO.File]::ReadAllText($manifestPath)
    foreach ($skip in @($false, $true)) {
        $script:messages.Clear()
        $unmountBefore = $script:unmountCount
        $lockedFile = [IO.File]::Open($guestOgl, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert (!(InstallDrivers -VMName Fixture -NonInteractive -SkipExisting:$skip)) "copy failure returns false (SkipExisting=$skip)"
        } finally { $lockedFile.Dispose() }
        Assert ($script:unmountCount -eq ($unmountBefore + 1)) 'failed install still unmounts guest'
        Assert ([IO.File]::ReadAllText($manifestPath) -eq $priorManifest) 'failure does not record a successful manifest'
        Assert (@($script:messages | Where-Object { $_ -like 'SUCCESS: Copied*' }).Count -eq 0) 'failure never logs injection success'
    }
    Write-Host 'PASS: locked package DLL fails both copy modes and still unmounts guest'

    # System file copy failures must also fail the entire injection.
    $systemFile = NewFixtureFile 'Host\Windows\System32\amd-runtime.dll'
    $script:associatedFiles = @($mainFile, $systemFile)
    $systemDriver = GetDrivers $script:gpu
    $systemDestination = "$($script:guestRoot)$($systemDriver.Files[0].D)"
    New-Item -ItemType Directory -Path (Split-Path -Parent $systemDestination) -Force | Out-Null
    [IO.File]::WriteAllText($systemDestination, 'guest runtime')
    $lockedFile = [IO.File]::Open($systemDestination, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert (!(InstallDrivers -VMName Fixture -NonInteractive)) 'system file failure returns false'
    } finally { $lockedFile.Dispose() }
    Assert ([IO.File]::ReadAllText($manifestPath) -eq $priorManifest) 'system copy failure leaves prior manifest intact'
    Write-Host 'PASS: system file copy failure is not reported as success'

    $emptyPackage = Join-Path $repo 'amdogl.inf_amd64_empty'
    New-Item -ItemType Directory -Path $emptyPackage | Out-Null
    Assert (!(InstallDrivers -VMName Fixture -NonInteractive -SkipExisting)) 'empty package fails instead of reporting successful copy'
    Assert ([IO.File]::ReadAllText($manifestPath) -eq $priorManifest) 'empty package failure leaves prior manifest intact'
    Write-Host 'PASS: empty package cannot be reported as successfully installed'

    # Older monolithic packages must still work when separate packages do not exist.
    # Rename inside the fixture instead of removing anything from a real store.
    foreach ($folder in @(GetGpuCompanionDriverFolders $script:gpu)) {
        Rename-Item -LiteralPath $folder -NewName ('disabled-' + (Split-Path -Leaf $folder))
    }
    $script:associatedFiles = @($mainFile)
    Assert (@(GetGpuCompanionDriverFolders $script:gpu).Count -eq 0) 'absent companion packages are handled'
    Assert (@((GetDrivers $script:gpu).Folders).Count -eq 1) 'legacy display package is retained'
    $script:associatedFiles = @()
    $script:infPath = NewFixtureFile 'Host\Windows\INF\oem-fixture.inf' "[CopyFiles]`r`ndisplay.sys"
    Assert ((GetDrivers $script:gpu).Folders -contains (Split-Path -Parent $mainFile)) 'INF fallback still resolves package from the actual Windows directory'
    Write-Host 'PASS: legacy package layout and INF fallback'
    Write-Host "PASS: $script:assertions driver discovery and injection regression assertions across 7 groups"
} finally {
    $env:windir = $originalWindir
    $resolvedFixture = [IO.Path]::GetFullPath($script:fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        !(Split-Path -Leaf $resolvedFixture).StartsWith('gpu-driver-tests-')) {
        throw "Refusing to clean unexpected fixture path: $resolvedFixture"
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
