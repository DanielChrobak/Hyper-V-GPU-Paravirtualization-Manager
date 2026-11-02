# Compatibility helpers retained after source verification. Platform/Gpu.ps1 owns discovery.
$script:HyperVCapabilityCache=@{}
function GetPartitionablePath($GpuObject) {
    if ($null -eq $GpuObject) { return $null }
    if ($GpuObject.PSObject.Properties["Name"] -and $GpuObject.Name) { return "$($GpuObject.Name)" }
    if ($GpuObject.PSObject.Properties["Id"] -and $GpuObject.Id) { return "$($GpuObject.Id)" }
    return "$GpuObject"
}

function GetPciIdsFromPath($Path) {
    if ($Path) {
        $idMatch = [regex]::Match($Path, 'VEN_([0-9A-Fa-f]{4}).*DEV_([0-9A-Fa-f]{4})')
        if ($idMatch.Success) {
            return [PSCustomObject]@{VEN=$idMatch.Groups[1].Value.ToUpperInvariant(); DEV=$idMatch.Groups[2].Value.ToUpperInvariant()}
        }
    }
    return $null
}

function TestHyperVCmdletParameter($CmdletName, $ParameterName) {
    if ([string]::IsNullOrWhiteSpace($CmdletName) -or [string]::IsNullOrWhiteSpace($ParameterName)) { return $false }

    $key = "$CmdletName|$ParameterName"
    if ($script:HyperVCapabilityCache.ContainsKey($key)) {
        return [bool]$script:HyperVCapabilityCache[$key]
    }

    $cmd = Get-Command $CmdletName -EA SilentlyContinue
    $supported = [bool]($cmd -and $cmd.Parameters.ContainsKey($ParameterName))
    $script:HyperVCapabilityCache[$key] = $supported
    return $supported
}

function GPUName($Path) {
    $meta = ResolvePartitionableDevice $Path
    if ($meta -and $meta.Name) { return $meta.Name }
    return $null
}

function GetGpuDisplayEntries($Adapters) {
    $ga = @($Adapters)
    if (!$ga) { return @() }

    $entries = @()
    foreach ($a in $ga) {
        $meta = ResolvePartitionableDevice $a.InstancePath
        $name = if ($meta -and $meta.Name) { $meta.Name } elseif ($meta -and $meta.VEN -and $meta.DEV) { "VEN_$($meta.VEN)/DEV_$($meta.DEV)" } else { $null }
        if (!$name) { $name = "GPU" }

        $pct = "?"
        try {
            if ($a.MaxPartitionVRAM -gt 0) {
                $capacity = [UInt64]1000000000
                $partitionable = GetPartitionableGpuByPath $a.InstancePath
                if ($partitionable) {
                    $capacity = GetGpuPartitionResourceCapacity -PartitionableGpu $partitionable -ResourceName "VRAM" -Fallback 1000000000
                }

                if ($capacity -gt 0) {
                    $pctValue = [Math]::Round(([decimal]$a.MaxPartitionVRAM / [decimal]$capacity) * 100)
                    $pctValue = [Math]::Max(1, [Math]::Min(100, [int]$pctValue))
                    $pct = "$pctValue%"
                }
            }
        } catch {}

        $entries += [PSCustomObject]@{
            Name = $name
            Pct = $pct
            Label = "$name ($pct)"
        }
    }

    return $entries
}

function GpuSummary($VMName=$null, $Adapters=$null) {
    $ga = if ($Adapters) { @($Adapters) } elseif ($VMName) { @(Get-VMGpuPartitionAdapter $VMName -EA SilentlyContinue) } else { @() }
    if (!$ga) { return "None" }

    $entries = @(GetGpuDisplayEntries -Adapters $ga)
    if (!$entries) { return "None" }
    return (($entries | ForEach-Object { $_.Label }) -join ", ")
}

function SelectGPU($Title="SELECT GPU", [switch]$Partition) {
    if ($Partition) {
        $gpus = GetPartitionableGPUs
        if (!$gpus) { Box $Title; Log "No partitionable devices found" "ERROR"; Write-Host ""; return $null }
        $list = @(); $i = 0
        foreach ($g in $gpus) {
            $p = GetPartitionablePath $g
            $meta = ResolvePartitionableDevice $p
            $driver = $null
            if (!$meta -or !$meta.Name -or !$meta.Class) {
                $driver = if ($meta -and $meta.Class) { FindGPU $p $meta.Class } else { FindGPU $p }
            }

            if ($meta -and $meta.Name) { $n = $meta.Name }
            elseif ($driver -and $driver.DeviceName) { $n = $driver.DeviceName }
            elseif ($meta -and $meta.VEN -and $meta.DEV) { $n = "Unknown Device (VEN_$($meta.VEN) DEV_$($meta.DEV))" }
            else { $n = "Unknown Partitionable Adapter #$($i + 1)" }

            $label = $n
            $className = if ($meta -and $meta.Class) { $meta.Class } elseif ($driver -and $driver.DeviceClass) { $driver.DeviceClass } else { $null }
            if ($className -and $className -ne "Display") { $label = "$label [$className]" }

            $list += [PSCustomObject]@{
                I = $i
                P = $p
                N = $n
                L = $label
                C = if ($meta -and $meta.Class) { $meta.Class } elseif ($driver -and $driver.DeviceClass) { $driver.DeviceClass } else { "Unknown" }
                V = if ($meta -and $meta.Vendor) { $meta.Vendor } elseif ($driver) { $driver.DriverProviderName } else { $null }
                VEN = if ($meta) { $meta.VEN } else { $null }
                DEV = if ($meta) { $meta.DEV } else { $null }
            }
            $i++
        }

        $items = @($list | ForEach-Object { $_.L }) + "< Cancel >"
        $sel = Menu -Items $items -Title $Title
        if ($null -eq $sel -or $sel -eq ($items.Count - 1)) { return $null }

        $pick = $list[$sel]
        Log "Selected: $($pick.N)" "SUCCESS"
        if ((!$pick.N -or $pick.N -like "Unknown*") -and $pick.VEN -and $pick.DEV) {
            Write-Host "  IDs: VEN_$($pick.VEN) DEV_$($pick.DEV)" -ForegroundColor DarkGray
            Write-Host "  Adapter path: $($pick.P)" -ForegroundColor DarkGray
        }
        Write-Host ""
        return $pick
    } else {
        $list = @(GetCompatManagementInstances "Win32_PnPSignedDriver" "DeviceClass='Display'")
        if (!$list) { Box $Title; Log "No GPUs found" "ERROR"; return $null }

        $items = @($list | ForEach-Object {
            $provider = if ($_.DriverProviderName) { $_.DriverProviderName } else { "Unknown Provider" }
            "$($_.DeviceName) | $provider"
        }) + "< Cancel >"

        $sel = Menu -Items $items -Title $Title
        if ($null -eq $sel -or $sel -eq ($items.Count - 1)) { return $null }
        return $list[$sel]
    }
}

function NormalizeDriverPath($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"')
    if ($p -match '^\\\\\?\?\\') { $p = $p.Substring(4) }
    elseif ($p -match '^\\\\\?\\') { $p = $p.Substring(4) }

    if ($p -match "^%SystemRoot%\\") { return (Join-Path $env:windir $p.Substring(12)) }
    if ($p -match "^\\SystemRoot\\") { return (Join-Path $env:windir $p.Substring(12)) }
    if ($p -match "^System32\\") { return (Join-Path (Join-Path $env:windir "System32") $p.Substring(9)) }
    return $p
}

function GetDriverStoreFolderRoot($Path) {
    $norm = NormalizeDriverPath $Path
    if (!$norm) { return $null }
    $clean = $norm.Replace('/', '\')
    foreach ($storeRoot in @('DriverStore', 'HostDriverStore')) {
        $base = Join-Path $env:windir "System32\$storeRoot\FileRepository"
        $prefix = "$base\"
        if ($clean.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $folder = $clean.Substring($prefix.Length).Split([char]'\')[0]
            if ($folder) { return (Join-Path $base $folder) }
        }
    }
    return $null
}

function GetGpuCompanionDriverFolders($GPU) {
    if (!$GPU) { return @() }
    if ($GPU.DeviceClass -and $GPU.DeviceClass -ne 'Display') { return @() }

    # PCI identity is authoritative; provider text is only a fallback for metadata
    # without a PCI ID. Never add AMD packages to an NVIDIA/Intel adapter.
    $ids = GetPciIdsFromPath $GPU.DeviceID
    $isAmd = if ($ids) { $ids.VEN -eq '1002' } else {
        "$($GPU.DriverProviderName)" -match '(?i)\b(AMD|ATI|Advanced Micro Devices)\b'
    }
    if (!$isAmd) { return @() }

    # Modern AMD drivers stage OpenGL/Vulkan as separate packages. They need not
    # occur in the display device's WMI associations or main INF references.
    $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $folders = @()
    foreach ($pattern in @('amdogl.inf_amd64_*', 'amdvlk.inf_amd64_*')) {
        $packages = @(Get-ChildItem -LiteralPath $repo -Directory -Filter $pattern -EA Stop)
        # Keep every staged version: consumers can reference an exact hashed path,
        # and LastWriteTime does not establish which package is currently in use.
        foreach ($package in $packages) { $folders += $package.FullName }
        if ($packages.Count -eq 0) {
            Log "No separate AMD companion package matching $pattern on the host (older drivers may bundle it in the display package)" "WARN"
        }
    }
    return @($folders | Sort-Object -Unique)
}

function GetInfReferences($InfPath) {
    if (!(Test-Path $InfPath)) { return @() }
    $lines = @(Get-Content $InfPath -EA SilentlyContinue)
    if (!$lines -or $lines.Count -eq 0) { return @() }

    $pattern = '[\w\-\.]+\.(?:sys|dll|exe|cat|inf|bin|vp|cpa|dat|cfg|json|ini|mui|pnf)'
    $refs = @{}
    $currentSection = $null

    foreach ($rawLine in $lines) {
        $line = "$rawLine"
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $commentIndex = $line.IndexOf(';')
        if ($commentIndex -ge 0) {
            $line = $line.Substring(0, $commentIndex)
        }

        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $sectionMatch = [regex]::Match($line, '^\[(.+)\]$')
        if ($sectionMatch.Success) {
            $currentSection = $sectionMatch.Groups[1].Value.Trim()
            continue
        }

        # Registry lines and IncludedSubPackages metadata frequently contain non-file tokens.
        if ($line -match '^(?i)(HKR|HKLM|HKCR|HKCU|HKU)\s*,') { continue }
        if ($currentSection -and $currentSection -match '^(?i)IncludedSubPackages(?:__\d+)?$') { continue }

        foreach ($m in [regex]::Matches($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $name = "$($m.Value)"
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $refs[$name.ToLowerInvariant()] = $name
        }
    }

    return @($refs.Values | Sort-Object -Unique)
}