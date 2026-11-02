function GetCompatManagementInstances($ClassName,$Filter=$null) {
    $parameters=@{ClassName=$ClassName;ErrorAction='Stop'}
    if ($Filter) {$parameters.Filter=$Filter}
    return @(Get-CimInstance @parameters)
}

function Get-HgmSignedDrivers {
    if ($null -eq $script:HgmSignedDrivers) {$script:HgmSignedDrivers=@(GetCompatManagementInstances 'Win32_PnPSignedDriver')}
    return $script:HgmSignedDrivers
}

function GetPartitionableGPUs {
    if ($null -ne $script:HgmPartitionableDevices) {return @($script:HgmPartitionableDevices)}
    foreach ($name in @('Get-VMHostPartitionableGpu','Get-VMPartitionableGpu')) {
        if (Get-Command $name -EA SilentlyContinue) {
            # Do not turn access-denied/provider failures into an empty inventory.
            $script:HgmPartitionableDevices=@(& $name -EA Stop)
            return @($script:HgmPartitionableDevices)
        }
    }
    throw 'No Hyper-V partitionable GPU enumeration cmdlet is installed.'
}

function Resolve-HgmAssignedPath($Adapter) {
    if ($Adapter.InstancePath) {return $Adapter.InstancePath}
    $devices=@(GetPartitionableGPUs)
    if ($devices.Count -eq 1) {return GetPartitionablePath $devices[0]}
    throw 'This Windows build does not report the physical GPU for this assignment. Multiple partitionable devices exist, so automatic matching would be ambiguous.'
}

function GetGpuIdentityKey($Path) { Get-HgmDeviceKey $Path }

function GetPartitionableGpuByPath($Path) {
    $key = Get-HgmDeviceKey $Path
    $matches = @(GetPartitionableGPUs | Where-Object { (Get-HgmDeviceKey (GetPartitionablePath $_)) -eq $key })
    if ($matches.Count -ne 1) { throw 'Select an exact, currently enumerated partitionable device path.' }
    return $matches[0]
}

function FindGPU($Path, $PreferredClass=$null) {
    $key = Get-HgmDeviceKey $Path
    $drivers = @(Get-HgmSignedDrivers | Where-Object { (Get-HgmDeviceKey $_.DeviceID) -eq $key })
    if ($PreferredClass) { $drivers = @($drivers | Where-Object DeviceClass -eq $PreferredClass) }
    if ($drivers.Count -eq 1) { return $drivers[0] }
    if ($drivers.Count -gt 1) { throw 'Multiple signed drivers match this device. Repair host device metadata before deploying drivers.' }
    return $null
}

function ResolvePartitionableDevice($Path) {
    $driver = FindGPU $Path
    $ids = GetPciIdsFromPath $Path
    return [pscustomobject]@{
        Name = if ($driver) {$driver.DeviceName} else {$Path}
        Class = if ($driver) {$driver.DeviceClass} else {'Unknown'}
        Vendor = if ($driver) {$driver.DriverProviderName} else {$null}
        DeviceId = if ($driver) {$driver.DeviceID} else {$null}
        VEN = if ($ids) {$ids.VEN} else {$null}; DEV = if ($ids) {$ids.DEV} else {$null}
    }
}

function Get-HgmGpuInventory {
    $drivers = @(Get-HgmSignedDrivers)
    $partitionable = @(GetPartitionableGPUs)
    $seen = @{}
    foreach ($gpu in $partitionable) {
        $path = GetPartitionablePath $gpu
        $key = Get-HgmDeviceKey $path
        $seen[$key] = $true
        $driver = @($drivers | Where-Object { (Get-HgmDeviceKey $_.DeviceID) -eq $key })
        $metadata = if ($driver.Count -eq 1) {$driver[0]} else {$null}
        [pscustomobject]@{
            Name=if ($metadata) {$metadata.DeviceName} else {'Unresolved partitionable device'}
            Status=if ($metadata) {'Enumerated'} else {'Metadata unresolved'}
            DriverVersion=if ($metadata) {$metadata.DriverVersion} else {$null}
            Provider=if ($metadata) {$metadata.DriverProviderName} else {$null}
            Partitionable=$true; DeviceId=if ($metadata) {$metadata.DeviceID} else {$key}
            InstancePath=$path; DeviceClass=if ($metadata) {$metadata.DeviceClass} else {'Unknown'}
            Compatibility='Ready for GPU-PV assignment; guest workload validation pending'
            TotalVRAM=$gpu.TotalVRAM; AvailableVRAM=$gpu.AvailableVRAM
            PartitionCount=$gpu.PartitionCount; ValidPartitionCounts=@($gpu.ValidPartitionCounts)
        }
    }
    foreach ($driver in $drivers | Where-Object DeviceClass -eq 'DISPLAY') {
        $key = Get-HgmDeviceKey $driver.DeviceID
        if ($key -and !$seen.ContainsKey($key)) {
            [pscustomobject]@{Name=$driver.DeviceName; Status='Not reported partitionable';DriverVersion=$driver.DriverVersion
                Provider=$driver.DriverProviderName; Partitionable=$false; DeviceId=$driver.DeviceID; InstancePath=$null
                DeviceClass=$driver.DeviceClass; Compatibility='Unavailable through the Hyper-V GPU-P interface'}
        }
    }
}

function GetGpuPartitionResourceCapacity($PartitionableGpu, $ResourceName, [UInt64]$Fallback=0) {
    if (!$PartitionableGpu -or $null -eq $PartitionableGpu."Total$ResourceName") { return [UInt64]0 }
    return [UInt64]$PartitionableGpu."Total$ResourceName"
}

function GetGpuPartitionResourceAllocation($PartitionableGpu, $ResourceName, $Percent, [UInt64]$Fallback=0) {
    $settings = Get-HgmResourceSettings $PartitionableGpu $Percent
    return [pscustomobject]@{Min=$settings["MinPartition$ResourceName"];Max=$settings["MaxPartition$ResourceName"]
        Optimal=$settings["OptimalPartition$ResourceName"];Capacity=$PartitionableGpu."Total$ResourceName"
        IsUnbounded=($PartitionableGpu."Total$ResourceName" -eq [UInt64]::MaxValue)}
}

function ResolveInfPathForGpu($GPU) {
    if (!$GPU) { return $null }
    $inf = $GPU.InfName
    if (!$inf -and $GPU.DeviceID -and (Get-Command Get-PnpDeviceProperty -EA SilentlyContinue)) {
        $inf = (Get-PnpDeviceProperty -InstanceId $GPU.DeviceID -KeyName 'DEVPKEY_Device_DriverInfPath' -EA Stop).Data
    }
    if (!$inf) { return $null }
    $path = Resolve-HgmContainedPath (Join-Path $env:windir 'INF') $inf
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

function Get-HgmAssociatedDriverFiles($GPU) {
    if (!$GPU.DeviceID) { return @() }
    $device = "$($GPU.DeviceID)".Replace('\','\\').Replace('"','\"')
    $antecedent = '\\' + $env:COMPUTERNAME + '\ROOT\cimv2:Win32_PnPSignedDriver.DeviceID="' + $device + '"'
    $filter = "Antecedent='$($antecedent.Replace('\','\\').Replace("'", "\'"))'"
    foreach ($link in @(Get-CimInstance -ClassName Win32_PnPSignedDriverCIMDataFile -Filter $filter -OperationTimeoutSec 20 -EA Stop)) {
        # CIM returns an embedded reference with Name; WMI/serialized results
        # may instead contain the object-path string. Support both forms.
        if ($link.Dependent.Name) {NormalizeDriverPath $link.Dependent.Name;continue}
        $match = [regex]::Match("$($link.Dependent)", 'Name\s*=\s*"(.+)"')
        if ($match.Success) { NormalizeDriverPath ($match.Groups[1].Value.Replace('\\','\')) }
    }
}

function GetDrivers($GPU) {
    if (!$GPU) { throw 'Signed driver metadata is required.' }
    $folders = @{}; $files = @{}; $associated = @(); $missing = @();$package=$null;$packageInf=$null
    $inf = ResolveInfPathForGpu $GPU
    if ($inf) {
        try {
            $packageInf=Get-HgmDriverStoreInf $inf
            $package=GetDriverStoreFolderRoot $packageInf
            if ($package) {$folders[$package]=$package}
        } catch {Write-HgmEvent 'SetupApiFallback' 'Exact INF resolution was unavailable; trying the device service and file associations.' 'Warning'}
    }
    $service=Get-HgmServiceDriverFile $GPU
    if ($service) {$servicePackage=GetDriverStoreFolderRoot $service;if ($servicePackage) {$folders[$servicePackage]=$servicePackage;if (!$package) {$package=$servicePackage}}}
    # The association provider can enumerate every driver on the machine before
    # applying a filter (20-second timeout observed on this host). The active
    # package plus its declared runtime promotions is the normal path. Keep the
    # legacy association discovery as a bounded recovery path when no active
    # package is available, or when explicitly requested for diagnosis.
    if (!$package -or $script:HgmDeepDriverDiscovery) {
        try { $associated = @(Get-HgmAssociatedDriverFiles $GPU) }
        catch { Write-HgmEvent 'DriverAssociation' 'Windows driver file associations were unavailable within the discovery timeout. Using exact package and runtime metadata.' 'Warning' }
    }
    foreach ($path in $associated) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "An associated host driver file is missing: $path" }
        $folder = GetDriverStoreFolderRoot $path
        if ($folder) { $folders[$folder] = $folder; continue }
        $hostPrefix = [IO.Path]::GetFullPath($env:windir).TrimEnd([char]'\') + '\'
        if ($path.StartsWith($hostPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = '\Windows\' + $path.Substring($hostPrefix.Length)
            if ($relative -match '^(?i)\\Windows\\(System32|SysWOW64)\\') {
                $relative = Assert-HgmDriverDestination $relative
                $files[$relative] = [pscustomobject]@{N=Split-Path -Leaf $path;S=$path;D=('\'+$relative)}
            }
        }
    }
    if (!$folders.Count -and $inf -and (Get-Command Get-WindowsDriver -EA SilentlyContinue)) {
        $packageInfo = Get-WindowsDriver -Online -Driver (Split-Path -Leaf $inf) -EA Stop
        foreach ($item in @($packageInfo)) {
            $folder = GetDriverStoreFolderRoot $item.OriginalFileName
            if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { $folders[$folder] = $folder;if (!$package) {$package=$folder} }
        }
    }
    if (!$package -and $folders.Count -eq 1) {$package=@($folders.Values)[0]}
    # Deliberately retain all staged AMD GL/Vulkan versions; exact hashed paths
    # may be referenced by UMDs. This empirical compatibility rule is documented.
    foreach ($folder in @(GetGpuCompanionDriverFolders $GPU)) { $folders[$folder] = $folder }
    if ($package) {
        $activeCandidates=@(Get-ChildItem -LiteralPath $package -File -Filter *.inf -EA Stop)
        $activeInf=if ($packageInf) {$activeCandidates | Where-Object {$_.Name -eq (Split-Path -Leaf $packageInf)} | Select-Object -First 1} elseif ($activeCandidates.Count -eq 1) {$activeCandidates[0]} else {$null}
        if ($activeInf) {foreach ($folder in @(Get-HgmDeclaredDriverCompanions $activeInf.FullName)) {$folders[$folder]=$folder}}
    }
    # Inspect INF tokens only within the resolved packages and known system paths.
    # A token in another model/version's INF is not a dependency of this device.
    if ($inf) {
        $names = @{}
        foreach ($folder in $folders.Values) {
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse -Force -EA Stop)) { $names[$file.Name] = $true }
        }
        foreach ($reference in @(GetInfReferences $inf)) {
            if ($names.ContainsKey($reference)) { continue }
            $found = $false
            foreach ($dir in @('System32','SysWOW64')) {
                $path = Resolve-HgmContainedPath (Join-Path $env:windir $dir) $reference
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $relative = "\Windows\$dir\$reference"
                    $null = Assert-HgmDriverDestination $relative
                    $files[$relative] = [pscustomobject]@{N=$reference;S=$path;D=$relative}
                    $found = $true
                }
            }
            if (!$found) { $missing += $reference }
        }
    }
    foreach ($promotion in @(Get-HgmDriverPromotions $GPU $package)) {$files[$promotion.D]=$promotion}
    if (!$folders.Count -and !$files.Count) { throw 'No complete driver package could be located from this device. Repair/reinstall the host driver and retry; no guest files have been changed.' }
    return @{
        Folders=@($folders.Values | Sort-Object); Files=@($files.Values | Sort-Object D)
        Missing=@($missing | Sort-Object -Unique); InfPath=$inf
        Strategy='SetupAPI+ExactDeviceAssociation+CopyToVmRules+ScopedPackages+AmdCompanionPackages'
        Confidence='Host driver package and runtime mapping discovered; validate the intended guest workload'
    }
}
