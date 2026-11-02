# Pure rules shared by console, desktop and automation.
function Get-HgmDeviceKey([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $key = $Path.Trim().ToUpperInvariant() -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', ''
    $key = $key -replace '#\{[0-9A-F-]+\}(?:\\.*)?$', ''
    return ($key.Replace('#', '\').TrimEnd([char]'\'))
}

function Assert-HgmVmName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 100 -or
        $Name -match '[<>:"/\\|?*\x00-\x1f]' -or $Name -match '[. ]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $Name -in @('.', '..')) {
        throw 'Use a VM name of 1-100 characters without path separators, wildcards, reserved device names or trailing dots/spaces.'
    }
}

function Resolve-HgmContainedPath([string]$Root, [string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[:\x00]' -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe relative path: $RelativePath" }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath.TrimStart([char[]]'\/')))
    if (!$path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes target directory: $RelativePath" }
    # Reject junctions/symlinks below the trusted root. The root itself may be
    # the volume access path owned by MountVHD. Use native attributes here;
    # provider enumeration on every ancestor dominates large package deployment.
    $cursor = $path
    while ($cursor.Length -gt $base.TrimEnd([char[]]'\/').Length) {
        try {
            if (([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) -and ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Reparse point is not permitted in a managed path: $cursor"
            }
        } catch [IO.FileNotFoundException] {} catch [IO.DirectoryNotFoundException] {}
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if (!$parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $path
}

function Get-HgmResourceSettings($Gpu, [ValidateRange(1,100)][int]$Percent) {
    $settings = @{}
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        $totalValue = $Gpu."Total$resource"
        if ($null -eq $totalValue) { throw "Host does not report Total$resource. Cannot calculate a percentage safely." }
        $total = [UInt64]$totalValue
        $minimum = [UInt64]$Gpu."MinPartition$resource"
        $maximum = [UInt64]$Gpu."MaxPartition$resource"
        if ($total -eq [UInt64]::MaxValue) {
            # Driver uses the all-bits-set sentinel for an unmetered engine.
            $amount = $total
        } elseif ($total -eq 0) {
            $amount = [UInt64]0
        } else {
            $amount = [UInt64][Math]::Max([decimal]1, [Math]::Floor(([decimal]$total * $Percent) / 100))
            if ($maximum -gt 0 -and $amount -gt $maximum) { $amount = $maximum }
            if ($minimum -gt $amount) { throw "$Percent% of $resource is below the host minimum $minimum. Choose a larger allocation." }
        }
        $settings["MinPartition$resource"] = [UInt64][Math]::Min([decimal]$minimum, [decimal]$amount)
        $settings["MaxPartition$resource"] = $amount
        $settings["OptimalPartition$resource"] = $amount
    }
    return $settings
}

function Assert-HgmDriverDestination([string]$Path) {
    $relative = $Path.TrimStart([char[]]'\/')
    if ($relative -notmatch '^(?i:Windows[\\/](System32|SysWOW64)[\\/])' -or
        $relative -match '(?i)[\\/](cmd|powershell|pwsh|reg|bcdedit|winload|winlogon|lsass|services)\.exe$' -or
        $relative -match '(?i)^Windows[\\/]System32[\\/]DriverStore[\\/]') {
        throw "Refusing unmanaged driver destination: $Path"
    }
    return $relative
}
