function Find-HgmOscdimg {
    $command=Get-Command oscdimg.exe -EA SilentlyContinue
    if ($command) {return $command.Source}
    $roots=@()
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
        $kits=Get-ItemProperty -LiteralPath $key -EA SilentlyContinue
        if ($kits.KitsRoot10) {$roots+=$kits.KitsRoot10}
    }
    foreach ($root in $roots | Select-Object -Unique) {
        foreach ($architecture in @('amd64','x86')) {
            $candidate=Join-Path $root "Assessment and Deployment Kit\Deployment Tools\$architecture\Oscdimg\oscdimg.exe"
            if (Test-Path -LiteralPath $candidate) {return $candidate}
        }
    }
    return $null
}
function Publish-HgmAutoIso([string]$Stage,[string]$VM) {
    Assert-HgmVmName $VM
    $output=Resolve-HgmContainedPath $script:Paths.ISO "$VM-AutoInstall.iso"
    $preserved=$null
    while ($true) {
        if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath "$output.manager.json")) {
            if (!$preserved) {$preserved=$output}
            $output=Resolve-HgmContainedPath $script:Paths.ISO ("$VM-AutoInstall-"+[guid]::NewGuid().ToString('N')+'.iso')
            continue
        }
        try {
            # Move fails rather than overwriting if another publisher claims the
            # filename after the check. Retry with a fresh name in that case.
            [IO.File]::Move($Stage,$output)
            break
        } catch [IO.IOException] {
            if (!(Test-Path -LiteralPath $Stage) -or !(Test-Path -LiteralPath $output)) {throw}
        }
    }
    try {
        Write-HgmAtomicJson "$output.manager.json" ([pscustomobject]@{Kind='GeneratedInstallationMedia';VmName=$VM;CreatedUtc=[DateTime]::UtcNow.ToString('o')})
    } catch {
        # Only this freshly moved file belongs to the failed publication.
        [IO.File]::Delete($output)
        throw
    }
    if ($preserved) {Write-HgmEvent 'PreviousIsoPreserved' "Existing installation media was preserved at '$preserved'. New media: '$output'."}
    return $output
}

function Test-HgmGeneratedIso([string]$Path,[string]$VM) {
    Assert-HgmVmName $VM
    $root=[IO.Path]::GetFullPath($script:Paths.ISO).TrimEnd([char]'\')
    $full=[IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full) -ne $root) {return $false}
    $name=[IO.Path]::GetFileName($full)
    # Keep cleanup compatibility with the original fixed-name media.
    if ($name -eq "$VM-AutoInstall.iso") {return $true}
    if ($name -notmatch ('^'+[regex]::Escape($VM)+'-AutoInstall-[0-9a-f]{32}\.iso$')) {return $false}
    $marker=Resolve-HgmContainedPath $root "$name.manager.json"
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) {return $false}
    try {
        $metadata=Get-Content -LiteralPath $marker -Raw -EA Stop | ConvertFrom-Json -EA Stop
        return ($metadata.Kind -eq 'GeneratedInstallationMedia' -and $metadata.VmName -eq $VM)
    } catch {return $false}
}

function NewAutoISO($Src,$VM,$ImageSelection=$null,$LocalAccount=$null) {
    Assert-HgmVmName $VM
    $script:LastAutoUnattendFallbackPath=$null
    $work=$null; $ownedMount=$false; $process=$null
    $source=[IO.Path]::GetFullPath($Src)
    try {
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) {throw 'Installation ISO not found.'}
        if ($ImageSelection -and $ImageSelection.Index -gt 0) {
            $images=@(GetWindowsInstallImageOptions $source)
            if (!@($images | Where-Object Index -eq $ImageSelection.Index).Count) {throw 'The requested installation image index is not present in the ISO.'}
        }
        $xml=BuildAutoUnattendXml (GetHostLocaleSettings) $ImageSelection $LocalAccount
        $osc=Find-HgmOscdimg
        if (!$osc) {
            $desktop=[Environment]::GetFolderPath('Desktop')
            $fallback=Join-Path $desktop 'autounattend.xml'
            if (Test-Path -LiteralPath $fallback) {$fallback=Join-Path $desktop "autounattend-$([guid]::NewGuid().ToString('N')).xml"}
            [IO.File]::WriteAllText($fallback,$xml,(New-Object Text.UTF8Encoding($false)))
            $script:LastAutoUnattendFallbackPath=$fallback
            Write-HgmEvent 'AdkMissing' "Windows ADK Oscdimg is unavailable. Answer file exported to '$fallback'; attach it to your installation media. The original ISO will be used." 'Warning'
            return $null
        }
        SecureDir $script:Paths.ISO
        $work=Resolve-HgmContainedPath $script:Paths.ISO ("work-"+[guid]::NewGuid().ToString('N'))
        SecureDir $work
        $media=Join-Path $work 'media';SecureDir $media
        Test-HgmCancellation
        $image=Get-DiskImage -ImagePath $source -EA Stop
        if (!$image.Attached) {$image=Mount-DiskImage -ImagePath $source -PassThru -EA Stop;$ownedMount=$true}
        $volume=@($image | Get-Volume -EA Stop | Where-Object DriveLetter)
        if ($volume.Count -ne 1) {throw 'Could not identify the mounted ISO volume.'}
        $sourceRoot="$($volume[0].DriveLetter):\"
        Write-HgmEvent 'IsoCopy' 'Copying Windows installation media into a private working directory.'
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -EA Stop)) {
            Test-HgmCancellation
            $relative=$file.FullName.Substring($sourceRoot.Length)
            $destination=Resolve-HgmContainedPath $media $relative
            New-Item -Path (Split-Path -Parent $destination) -ItemType Directory -Force -EA Stop | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -EA Stop
            (Get-Item -LiteralPath $destination -Force).IsReadOnly=$false
        }
        [IO.File]::WriteAllText((Join-Path $media 'autounattend.xml'),$xml,(New-Object Text.UTF8Encoding($false)))
        $bios=Join-Path $media 'boot\etfsboot.com'
        $efi=Join-Path $media 'efi\microsoft\boot\efisys_noprompt.bin'
        if (!(Test-Path -LiteralPath $efi)) {$efi=Join-Path $media 'efi\microsoft\boot\efisys.bin'}
        if (!(Test-Path -LiteralPath $bios) -or !(Test-Path -LiteralPath $efi)) {throw 'The source media is missing BIOS/UEFI boot files.'}
        $stage=Join-Path $work 'output.iso'
        $arguments=@('-m','-o','-u2','-udfver102',"-bootdata:2#p0,e,b$bios#pEF,e,b$efi",$media,$stage)
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$osc
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        # None of these values may contain quotes (validated Windows file paths).
        $start.Arguments=($arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
        $process=[Diagnostics.Process]::Start($start)
        while (!$process.WaitForExit(200)) {
            if ($script:HgmCancellation -and $script:HgmCancellation.IsCancellationRequested) {$process.Kill();$process.WaitForExit();Test-HgmCancellation}
        }
        if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $stage -PathType Leaf)) {throw 'Oscdimg did not produce an ISO. Check ADK installation, source media and free space.'}
        Test-HgmCancellation
        return Publish-HgmAutoIso $stage $VM
    } catch {
        $script:LastAutoUnattendFallbackPath=$null
        throw
    } finally {
        if ($process) {$process.Dispose()}
        if ($ownedMount) {Dismount-DiskImage -ImagePath $source -EA Stop | Out-Null}
        if ($work) {
            $resolved=Resolve-HgmContainedPath $script:Paths.ISO (Split-Path -Leaf $work)
            if ((Split-Path -Leaf $resolved) -notmatch '^work-[0-9a-f]{32}$') {throw 'Unexpected ISO working path.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force -EA Stop
        }
    }
}
