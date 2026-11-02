# Run with Invoke-Pester .\tests\Vhd.Operations.Tests.ps1 (Pester 3/4).
# Stub all host disk commands so these tests never attach or detach real disks.
function Get-VHD { [CmdletBinding()] param($Path) throw 'Get-VHD must be mocked' }
function Mount-VHD { [CmdletBinding()] param($Path, [switch]$NoDriveLetter, [switch]$PassThru) throw 'Mount-VHD must be mocked' }
function Dismount-VHD { [CmdletBinding()] param($Path) throw 'Dismount-VHD must be mocked' }
function Update-Disk { [CmdletBinding()] param($Number) }
function Get-Partition { [CmdletBinding()] param($DiskNumber) }
function Add-PartitionAccessPath { [CmdletBinding()] param($DiskNumber, $PartitionNumber, $AccessPath) }
function Remove-PartitionAccessPath { [CmdletBinding()] param($DiskNumber, $PartitionNumber, $AccessPath) }
function Spin { param($Message, $Seconds) }

. (Join-Path $PSScriptRoot '..\src\Core\Vhd.Operations.ps1')

Describe 'Offline virtual disk parent chains and cleanup' {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:fixture -ItemType Directory | Out-Null
        $script:leaf = Join-Path $script:fixture 'active[1].avhdx'
        $script:parent = Join-Path $script:fixture 'checkpoint.avhdx'
        $script:base = Join-Path $script:fixture 'base.vhdx'
        @($script:leaf, $script:parent, $script:base) | ForEach-Object {
            New-Item -Path $_ -ItemType File | Out-Null
        }
        $script:metadata = @{}
        $script:metadata[$script:leaf] = @{VhdType='Differencing'; ParentPath=$script:parent}
        $script:metadata[$script:parent] = @{VhdType='Differencing'; ParentPath=$script:base}
        $script:metadata[$script:base] = @{VhdType='Dynamic'; ParentPath=$null}
        $script:Paths = @{Mount=(Join-Path $script:fixture 'mounts')}
        Mock Get-VHD { return $script:metadata[$Path] }
        Mock SecureDir { New-Item -Path $P -ItemType Directory -Force | Out-Null }
        Mock Mount-VHD { return @{DiskNumber=7} }
        Mock Dismount-VHD {}
        Mock Get-Partition { return @{PartitionNumber=2; Size=20GB} }
        Mock Add-PartitionAccessPath {}
        Mock Remove-PartitionAccessPath {}
        Mock Test-Path { return $true } -ParameterFilter { $Path -like '*\Windows\System32' }
    }

    It 'accepts a standalone VHDX' {
        $chain = ResolveVHDChain $script:base
        $chain.LeafPath | Should Be $script:base
        $chain.Paths.Count | Should Be 1
        Assert-MockCalled Get-VHD -Scope It -Times 1 -Exactly
    }

    It 'traverses multiple AVHDX checkpoints to the base VHDX' {
        $chain = ResolveVHDChain $script:leaf
        $chain.LeafPath | Should Be $script:leaf
        ($chain.Paths -join '|') | Should Be (@($script:leaf, $script:parent, $script:base) -join '|')
        Assert-MockCalled Get-VHD -Scope It -Times 3 -Exactly
    }

    It 'resolves relative parents against the child directory' {
        $script:metadata[$script:leaf].ParentPath = '.\checkpoint.avhdx'
        $script:metadata[$script:parent].ParentPath = '.\base.vhdx'
        (ResolveVHDChain $script:leaf).Paths[-1] | Should Be $script:base
    }

    It 'normalizes a relative leaf using the PowerShell working directory' {
        Push-Location $script:fixture
        try {
            (ResolveVHDChain '.\active[1].avhdx').LeafPath | Should Be $script:leaf
        } finally { Pop-Location }
    }

    It 'rejects a missing leaf before reading metadata' {
        { ResolveVHDChain (Join-Path $script:fixture 'missing.avhdx') } | Should Throw 'not found'
        Assert-MockCalled Get-VHD -Scope It -Times 0 -Exactly
    }

    It 'rejects a missing ancestor before mounting' {
        $script:metadata[$script:parent].ParentPath = Join-Path $script:fixture 'missing.vhdx'
        { MountVHD $script:leaf } | Should Throw 'not found'
        Assert-MockCalled Mount-VHD -Scope It -Times 0 -Exactly
        Assert-MockCalled Dismount-VHD -Scope It -Times 0 -Exactly
    }

    It 'rejects a differencing disk without a parent' {
        $script:metadata[$script:leaf].ParentPath = ' '
        { ResolveVHDChain $script:leaf } | Should Throw 'has no parent path'
    }

    It 'rejects a cycle through multiple checkpoints' {
        $script:metadata[$script:parent].ParentPath = $script:leaf
        { MountVHD $script:leaf } | Should Throw 'Cycle detected'
        Assert-MockCalled Get-VHD -Scope It -Times 2 -Exactly
        Assert-MockCalled Mount-VHD -Scope It -Times 0 -Exactly
    }

    It 'rejects self cycles with case and dot-segment differences' {
        $script:metadata[$script:leaf].ParentPath = Join-Path $script:fixture '.\ACTIVE[1].AVHDX'
        { ResolveVHDChain $script:leaf } | Should Throw 'Cycle detected'
        Assert-MockCalled Get-VHD -Scope It -Times 1 -Exactly
    }

    It 'preserves the failing path and metadata error' {
        Mock Get-VHD { throw 'Invalid disk header' }
        { MountVHD $script:leaf } | Should Throw 'Invalid disk header'
        Assert-MockCalled Mount-VHD -Scope It -Times 0 -Exactly
    }

    It 'rejects missing metadata before mounting' {
        Mock Get-VHD { return $null }
        { MountVHD $script:leaf } | Should Throw 'No virtual disk metadata'
        Assert-MockCalled Mount-VHD -Scope It -Times 0 -Exactly
    }

    It 'mounts only the active leaf and dismounts it once' {
        $mount = MountVHD $script:leaf
        $mount.VHD | Should Be $script:leaf
        Assert-MockCalled Mount-VHD -Scope It -Times 1 -Exactly -ParameterFilter { $Path -eq $script:leaf -and $NoDriveLetter -and $PassThru }
        UnmountVHD $mount (Join-Path $script:fixture '.\ACTIVE[1].AVHDX')
        Assert-MockCalled Remove-PartitionAccessPath -Scope It -Times 1 -Exactly -ParameterFilter { $DiskNumber -eq 7 -and $PartitionNumber -eq 2 }
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly -ParameterFilter { $Path -eq $script:leaf }
        Test-Path -LiteralPath $mount.Path | Should Be $false
    }

    It 'cleans up a failed Windows partition search once' {
        Mock Test-Path { return $false } -ParameterFilter { $Path -like '*\Windows\System32' }
        { MountVHD $script:leaf } | Should Throw 'Windows folder not found'
        Assert-MockCalled Remove-PartitionAccessPath -Scope It -Times 1 -Exactly
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly -ParameterFilter { $Path -eq $script:leaf }
        @(Get-ChildItem -LiteralPath $script:Paths.Mount).Count | Should Be 0
    }

    It 'does not dismount a disk when Mount-VHD failed' {
        Mock Mount-VHD { throw 'Disk already attached' }
        { MountVHD $script:leaf } | Should Throw 'Disk already attached'
        Assert-MockCalled Dismount-VHD -Scope It -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $script:Paths.Mount).Count | Should Be 0
    }

    It 'supports cleanup with only the fallback disk path' {
        UnmountVHD $null $script:leaf
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly -ParameterFilter { $Path -eq $script:leaf }
    }

    It 'continues cleanup after terminating access-path and dismount errors' {
        $mount = MountVHD $script:leaf
        Mock Remove-PartitionAccessPath { throw 'Access path is busy' }
        Mock Dismount-VHD { throw 'Disk is busy' }
        UnmountVHD $mount $script:leaf
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly
        Test-Path -LiteralPath $mount.Path | Should Be $false
    }

    It 'preserves the original mount error when dismounting also fails' {
        Mock Test-Path { return $false } -ParameterFilter { $Path -like '*\Windows\System32' }
        Mock Dismount-VHD { throw 'Disk is busy' }
        { MountVHD $script:leaf } | Should Throw 'Windows folder not found'
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly
    }

    It 'never recursively deletes guest files when detaching fails' {
        $mount = MountVHD $script:leaf
        $sentinel = Join-Path $mount.Path 'guest-data.txt'
        Set-Content -LiteralPath $sentinel -Value 'Preserve guest data'
        Mock Remove-PartitionAccessPath { Write-Error 'Access path is busy' }
        Mock Dismount-VHD { Write-Error 'Disk is busy' }
        UnmountVHD $mount $script:leaf
        Get-Content -LiteralPath $sentinel | Should Be 'Preserve guest data'
        Assert-MockCalled Dismount-VHD -Scope It -Times 1 -Exactly
    }
}
