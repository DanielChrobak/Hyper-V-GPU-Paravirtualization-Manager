function Protect-HgmProfilePassword([string]$Password) {
    if ([string]::IsNullOrEmpty($Password)) { return $null }
    return (ConvertTo-SecureString -String $Password -AsPlainText -Force | ConvertFrom-SecureString)
}

function Unprotect-HgmProfilePassword([string]$ProtectedPassword) {
    if (!$ProtectedPassword) { return $null }
    try {
        $secure = ConvertTo-SecureString $ProtectedPassword -EA Stop
        return (New-Object Management.Automation.PSCredential('profile', $secure)).GetNetworkCredential().Password
    } catch { throw 'A saved profile password cannot be decrypted by this Windows user on this machine. Edit the profile and enter its password again.' }
}

function Export-HgmConfiguration([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Specify -ConfigurationPath for the backup file.' }
    $profiles = @(GetHyperVGpuVmProfileInventory -ProjectRoot $script:HyperVGpuProjectRoot)
    $safe = @($profiles | Select-Object Name,IsDefault,VmName,Cpu,RamGB,StorageGB,VhdPath,IsoPath,EnableAutoInstall,InstallImageIndex,UnattendUsername,OverwriteVhd)
    # Passwords in backups remain protected by the current user's Windows DPAPI.
    for ($i=0; $i -lt $safe.Count; $i++) {
        $safe[$i] | Add-Member NoteProperty ProtectedPassword (Protect-HgmProfilePassword $profiles[$i].UnattendPassword)
    }
    Write-HgmAtomicJson ([IO.Path]::GetFullPath($Path)) ([pscustomobject]@{SchemaVersion=2;Kind='HyperVGpuManagerConfiguration';Profiles=$safe})
    return [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);Profiles=$safe.Count;PasswordScope='Current Windows user and machine'}
}

function Import-HgmConfiguration([string]$Path) {
    $doc=Get-Content -LiteralPath $Path -Raw -EA Stop | ConvertFrom-Json -EA Stop
    if ($doc.Kind -ne 'HyperVGpuManagerConfiguration' -or $doc.SchemaVersion -ne 2) { throw 'Unsupported configuration backup format.' }
    $validated=@(); $names=@{}; $default=$null
    foreach ($profile in @($doc.Profiles)) {
        $value=ConvertToHyperVGpuVmProfileObject $profile
        if (!$value) {throw 'Backup contains an invalid profile.'}
        Assert-HgmVmName $value.VmName
        $key=GetHyperVGpuProfileMapKey $value.Name
        if ($names.ContainsKey($key)) {throw 'Backup contains duplicate profile names.'}
        $names[$key]=$true
        $value.UnattendPassword=Unprotect-HgmProfilePassword $profile.ProtectedPassword
        $validated+=$value
        if ($profile.IsDefault) {if ($default) {throw 'Backup has multiple default profiles.'}; $default=$value.Name}
    }
    $store=NewHyperVGpuVmProfileStore $script:HyperVGpuProjectRoot
    foreach ($profile in $validated) {$store.Profiles[(GetHyperVGpuProfileMapKey $profile.Name)]=$profile}
    $store.DefaultProfile=$default
    if (!(ExportHyperVGpuVmProfileStore $store)) {throw 'Could not restore configuration. The previous file is available as .bak.'}
    InitializeHyperVGpuVmProfiles $script:HyperVGpuProjectRoot
    return [pscustomobject]@{Profiles=$validated.Count;StorePath=$store.Path}
}
