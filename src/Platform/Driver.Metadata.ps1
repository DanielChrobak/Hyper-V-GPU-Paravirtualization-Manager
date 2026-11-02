function Get-HgmDriverStoreInf([string]$PublishedInf) {
    if (!$PublishedInf) {return $null}
    if (!('HyperVGpuManager.Native.SetupApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace HyperVGpuManager.Native {
    public static class SetupApi {
        [DllImport("setupapi.dll", EntryPoint="SetupGetInfDriverStoreLocationW", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DriverStoreInf(string inf, IntPtr platform, IntPtr locale, StringBuilder buffer, UInt32 size, out UInt32 required);
    }
}
'@
    }
    $buffer=New-Object Text.StringBuilder 4096
    $required=[UInt32]0
    if (![HyperVGpuManager.Native.SetupApi]::DriverStoreInf($PublishedInf,[IntPtr]::Zero,[IntPtr]::Zero,$buffer,$buffer.Capacity,[ref]$required)) {
        throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error(),'Windows could not resolve the installed INF to its exact driver-store package.'))
    }
    return $buffer.ToString()
}

function Get-HgmDeviceDriverKey($Gpu) {
    if (!$Gpu.DeviceID) {return $null}
    $enumPath='HKLM:\SYSTEM\CurrentControlSet\Enum\'+$Gpu.DeviceID
    $device=Get-ItemProperty -LiteralPath $enumPath -EA SilentlyContinue
    if (!$device.Driver -or $device.Driver -notmatch '^\{[0-9a-fA-F-]+\}\\\d{4}$') {return $null}
    return ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$device.Driver)
}

function Get-HgmServiceDriverFile($Gpu) {
    if (!$Gpu.DeviceID) {return $null}
    $device=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$Gpu.DeviceID) -EA SilentlyContinue
    if (!$device.Service -or $device.Service -match '[\\/:]') {return $null}
    $service=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$device.Service) -EA SilentlyContinue
    if (!$service.ImagePath) {return $null}
    $path=NormalizeDriverPath $service.ImagePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {return $path}
    return $null
}

function ConvertTo-HgmPromotion([string]$Package,[string]$Rule,$Value) {
    if ($Rule -notin @('CopyToVmOverwrite','CopyToVmWhenNewer','CopyToVmOverwriteWow64','CopyToVmWhenNewerWow64')) {throw 'Unknown driver promotion rule.'}
    $pair=@($Value)
    if ($pair.Count -lt 1 -or $pair.Count -gt 2 -or !$pair[0]) {throw 'CopyToVm values must contain one source path and an optional destination filename.'}
    $source=Resolve-HgmContainedPath $Package $pair[0]
    $name=if ($pair.Count -eq 2 -and $pair[1]) {[string]$pair[1]} else {Split-Path -Leaf $source}
    if ($name -match '[\\/:*?]' -or $name -in @('.','..')) {throw 'CopyToVm destination must be a filename.'}
    $directory=if ($Rule.EndsWith('Wow64')) {'SysWOW64'} else {'System32'}
    $relative="\Windows\$directory\$name"
    $null=Assert-HgmDriverDestination $relative
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) {
        # Intel's current INF declares historical libmfx filenames while shipping
        # loader-named binaries. Confirmed against the host package and ExHyperV's
        # published mapping; never search another installed package for the DLL.
        $aliases=@{'libmfxhw64.dll'='mfx_loader_dll_hw64.dll';'libmfxhw32.dll'='mfx_loader_dll_hw32.dll'}
        $leaf=Split-Path -Leaf $source
        if ($aliases.ContainsKey($leaf)) {
            $alternate=Resolve-HgmContainedPath $Package $aliases[$leaf]
            if (Test-Path -LiteralPath $alternate -PathType Leaf) {$source=$alternate}
        }
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) {throw "Driver-declared promotion source is missing: $source"}
    }
    return [pscustomobject]@{N=$name;S=$source;D=$relative;Policy=if ($Rule -like '*WhenNewer*') {'WhenNewer'} else {'Overwrite'};Rule=$Rule}
}

function Get-HgmDeclaredDriverCompanions([string]$ActiveInf) {
    if (!$ActiveInf -or !(Test-Path -LiteralPath $ActiveInf)) {return @()}
    $text=[IO.File]::ReadAllText($ActiveInf)
    $version=[regex]::Match($text,'(?im)^\s*DriverVer\s*=\s*([^;\r\n]+)').Groups[1].Value.Trim().ToLowerInvariant() -replace '\s',''
    $declared=@{}
    foreach ($match in [regex]::Matches($text,'(?im)^\s*CopyINF\s*=\s*([^;\r\n]+)')) {
        foreach ($part in ($match.Groups[1].Value -split ',')) {
            $name=$part.Trim().Trim('"')
            if ($name -match '^(?i)(amdocl|amdogl|amdvlk|amdwin-[a-z0-9_-]+)\.inf$') {$declared[$name]=$true}
        }
    }
    $repo=Join-Path $env:windir 'System32\DriverStore\FileRepository'
    foreach ($name in $declared.Keys) {
        $matches=@()
        foreach ($folder in @(Get-ChildItem -LiteralPath $repo -Directory -Filter "$name`_amd64_*" -EA Stop)) {
            $candidate=Join-Path $folder.FullName $name
            if (!(Test-Path -LiteralPath $candidate)) {continue}
            $candidateVersion=[regex]::Match([IO.File]::ReadAllText($candidate),'(?im)^\s*DriverVer\s*=\s*([^;\r\n]+)').Groups[1].Value.Trim().ToLowerInvariant() -replace '\s',''
            if ($version -and $candidateVersion -eq $version) {$matches+=$folder.FullName}
        }
        if ($matches.Count -eq 1) {$matches[0]}
        else {Write-HgmEvent 'CompanionPackage' "Declared driver companion '$name' has $($matches.Count) exact-version matches. It was not selected automatically." 'Warning'}
    }
}

function Get-HgmDriverPromotions($Gpu,[string]$Package) {
    $key=Get-HgmDeviceDriverKey $Gpu
    if (!$key -or !$Package) {return @()}
    foreach ($rule in @('CopyToVmOverwrite','CopyToVmWhenNewer','CopyToVmOverwriteWow64','CopyToVmWhenNewerWow64')) {
        $path=Join-Path $key $rule
        if (!(Test-Path -LiteralPath $path)) {continue}
        $properties=Get-ItemProperty -LiteralPath $path -EA Stop
        foreach ($property in $properties.PSObject.Properties | Where-Object {$_.Name -notmatch '^PS'}) {
            try {ConvertTo-HgmPromotion $Package $rule $property.Value}
            catch {Write-HgmEvent 'PromotionUnavailable' "$($Gpu.DeviceName): $($_.Exception.Message)" 'Warning'}
        }
    }
}

function Test-HgmSourceNewer([string]$Source,[string]$Destination) {
    if (!(Test-Path -LiteralPath $Destination -PathType Leaf)) {return $true}
    $src=Get-Item -LiteralPath $Source -EA Stop;$dst=Get-Item -LiteralPath $Destination -EA Stop
    if ($Destination -match '\.(dll|exe)$') {
        $sourceVersion=[version]'0.0';$destinationVersion=[version]'0.0'
        [void][version]::TryParse(($src.VersionInfo.FileVersion -replace ',\s*','.' -replace '\s.*$',''),[ref]$sourceVersion)
        [void][version]::TryParse(($dst.VersionInfo.FileVersion -replace ',\s*','.' -replace '\s.*$',''),[ref]$destinationVersion)
        if ($sourceVersion -and $destinationVersion -and $sourceVersion -ne $destinationVersion) {return $sourceVersion -gt $destinationVersion}
    }
    return $src.LastWriteTimeUtc -gt $dst.LastWriteTimeUtc
}
