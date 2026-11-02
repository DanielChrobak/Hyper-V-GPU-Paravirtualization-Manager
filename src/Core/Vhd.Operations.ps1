#region VHD Operations
function SecureDir($P) {
    if (!(Test-Path -LiteralPath $P)) { New-Item $P -ItemType Directory -Force -EA Stop | Out-Null }
    if ((Get-Item -LiteralPath $P -Force -EA Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Managed directory cannot be a reparse point: $P" }
    $acl = Get-Acl $P
    $acl.SetAccessRuleProtection($true, $false)
    @("S-1-5-18", "S-1-5-32-544") | ForEach-Object {
        $sid = [System.Security.Principal.SecurityIdentifier]$_
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    }
    Set-Acl $P $acl
}

function ResolveVHDChain([string]$VHD) {
    if ([string]::IsNullOrWhiteSpace($VHD)) { throw "Virtual disk path is required" }

    $leafPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VHD))
    $currentPath = $leafPath
    $seen = @{} # PowerShell string keys are case-insensitive, like Windows paths.
    $chain = @()
    while ($currentPath) {
        if ($seen.ContainsKey($currentPath)) { throw "Cycle detected in virtual disk parent chain at '$currentPath'" }
        $seen[$currentPath] = $true
        if (!(Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw "Virtual disk or parent not found: '$currentPath'" }

        try {
            $info = Get-VHD -Path $currentPath -EA Stop
        } catch {
            throw "Could not read virtual disk '$currentPath': $($_.Exception.Message)"
        }
        if (!$info) { throw "No virtual disk metadata returned for '$currentPath'" }
        $chain += $currentPath
        $parentPath = [string]$info.ParentPath
        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            if ($info.VhdType -eq 'Differencing') { throw "Differencing disk '$currentPath' has no parent path" }
            break
        }

        if (![System.IO.Path]::IsPathRooted($parentPath)) {
            $parentPath = Join-Path (Split-Path -Parent $currentPath) $parentPath
        }
        $currentPath = [System.IO.Path]::GetFullPath($parentPath)
    }

    return @{LeafPath=$leafPath; Paths=$chain}
}

function MountVHD($VHD) {
    # Validate every ancestor before mounting; writes must target the active leaf.
    $chain = ResolveVHDChain $VHD
    $VHD = $chain.LeafPath
    if ((Get-VHD -Path $VHD -EA Stop).Attached) { throw 'Virtual disk is already mounted. It will not be detached or modified by this operation.' }
    SecureDir $script:Paths.Mount
    $mp = Join-Path $script:Paths.Mount ("VMMount_" + [Guid]::NewGuid().ToString("N"))
    $disk = $null; $part = $null; $attachedPartitionNumber = $null
    try {
        SecureDir $mp; Spin "Mounting virtual disk..." 2
        $disk = Mount-VHD $VHD -NoDriveLetter -PassThru -EA Stop

        $partitions = @()
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Update-Disk $disk.DiskNumber -EA SilentlyContinue
            $partitions = @(Get-Partition -DiskNumber $disk.DiskNumber -EA SilentlyContinue | Sort-Object Size -Descending)
            if ($partitions.Count -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($partitions.Count -eq 0) { throw "No partitions found on mounted disk" }

        $candidates = @($partitions | Where-Object { $_.Size -gt 5GB } | Sort-Object Size -Descending)
        if ($candidates.Count -eq 0) { $candidates = $partitions }

        Spin "Mounting partition..." 1
        foreach ($candidate in $candidates) {
            try {
                Add-PartitionAccessPath -DiskNumber $disk.DiskNumber -PartitionNumber $candidate.PartitionNumber -AccessPath $mp -EA Stop
                $attachedPartitionNumber = $candidate.PartitionNumber
                if (Test-Path "$mp\Windows\System32") {
                    $part = $candidate
                    break
                }
            } catch {}

            if ($attachedPartitionNumber) {
                Remove-PartitionAccessPath -DiskNumber $disk.DiskNumber -PartitionNumber $attachedPartitionNumber -AccessPath $mp -EA SilentlyContinue
                $attachedPartitionNumber = $null
            }
        }

        if (!$part) { throw "Windows folder not found - is Windows installed?" }
        return @{Disk=$disk; Part=$part; Path=$mp; VHD=$VHD}
    } catch {
        $failedMount = @{Disk=$disk; Part=@{PartitionNumber=$attachedPartitionNumber}; Path=$mp; VHD=$null}
        if ($disk) { $failedMount.VHD = $VHD }
        UnmountVHD $failedMount
        throw
    }
}

function UnmountVHD($M, $VHD, [switch]$Strict) {
    $cleanupErrors = @()
    if ($M -and $M.Disk -and $M.Part -and $M.Part.PartitionNumber -and $M.Path) {
        try {
            Remove-PartitionAccessPath -DiskNumber $M.Disk.DiskNumber -PartitionNumber $M.Part.PartitionNumber -AccessPath $M.Path -EA Stop
        } catch { $cleanupErrors += $_.Exception.Message; Write-Warning "Could not remove partition access path '$($M.Path)': $($_.Exception.Message)" }
    }
    $dismounted = @{}
    $paths = @($VHD)
    if ($M -and $M.VHD) { $paths = @($M.VHD) + $paths }
    foreach ($path in $paths) {
        if (!$path) { continue }
        $fullPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path))
        if ($dismounted.ContainsKey($fullPath)) { continue }
        $dismounted[$fullPath] = $true
        try {
            Dismount-VHD -Path $fullPath -EA Stop
        } catch { $cleanupErrors += $_.Exception.Message; Write-Warning "Could not dismount virtual disk '$fullPath': $($_.Exception.Message)" }
    }
    if ($M -and $M.Path) {
        # Never recurse into a mount point if detaching the guest volume failed.
        try { [System.IO.Directory]::Delete($M.Path) } catch {}
    }
    if ($Strict -and $cleanupErrors.Count) { throw "Offline disk cleanup failed. Keep the VM off and detach the managed disk in Hyper-V/Disk Management before retrying: $($cleanupErrors -join '; ')" }
}
#endregion
