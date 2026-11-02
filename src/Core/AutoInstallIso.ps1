#region Auto Install ISO
$script:AutoXMLTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>__UI_LANGUAGE__</UILanguage>
            </SetupUILanguage>
            <InputLocale>__INPUT_LOCALE__</InputLocale>
            <SystemLocale>__SYSTEM_LOCALE__</SystemLocale>
            <UILanguage>__UI_LANGUAGE__</UILanguage>
            <UserLocale>__USER_LOCALE__</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>User</FullName>
                <Organization>Organization</Organization>
                <ProductKey>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
            </UserData>
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>Primary</Type>
                            <Size>1024</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>EFI</Type>
                            <Size>260</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Type>MSR</Type>
                            <Size>16</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>4</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Label>WINRE</Label>
                            <Format>NTFS</Format>
                            <TypeID>DE94BBA4-06D1-4D40-A16A-BFD50179D6AC</TypeID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                            <Label>System</Label>
                            <Format>FAT32</Format>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>3</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>4</Order>
                            <PartitionID>4</PartitionID>
                            <Label>Windows</Label>
                            <Format>NTFS</Format>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    __IMAGE_SELECTION__
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>4</PartitionID>
                    </InstallTo>
                    <InstallToAvailablePartition>false</InstallToAvailablePartition>
                </OSImage>
            </ImageInstall>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>*</ComputerName>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>__INPUT_LOCALE__</InputLocale>
            <SystemLocale>__SYSTEM_LOCALE__</SystemLocale>
            <UILanguage>__UI_LANGUAGE__</UILanguage>
            <UserLocale>__USER_LOCALE__</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <TimeZone>__TIME_ZONE__</TimeZone>
            __LOCAL_ACCOUNT_SETUP__
        </component>
    </settings>
</unattend>
'@

if (-not $script:LastAutoUnattendFallbackPath) { $script:LastAutoUnattendFallbackPath = $null }

function XmlEsc($Value) {
    if ($null -eq $Value) { return "" }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function GetHostLocaleSettings {
    $fallback = "en-US"
    $inputLocale = $fallback; $systemLocale = $fallback; $uiLanguage = $fallback; $userLocale = $fallback
    $timeZone = "UTC"

    try { $systemLocale = (Get-WinSystemLocale).Name } catch {}
    try { $userLocale = (Get-Culture).Name } catch {}
    try {
        $uiOverride = Get-WinUILanguageOverride
        if (![string]::IsNullOrWhiteSpace($uiOverride)) { $uiLanguage = $uiOverride }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($uiLanguage) -or $uiLanguage -eq $fallback) {
        try { $uiLanguage = (Get-UICulture).Name } catch {}
    }

    try {
        $langList = Get-WinUserLanguageList
        if ($langList -and $langList.Count -gt 0) {
            $primary = $langList | Select-Object -First 1
            if ($primary.InputMethodTips -and $primary.InputMethodTips.Count -gt 0 -and ![string]::IsNullOrWhiteSpace($primary.InputMethodTips[0])) {
                $inputLocale = $primary.InputMethodTips[0]
            } elseif (![string]::IsNullOrWhiteSpace($primary.LanguageTag)) {
                $inputLocale = $primary.LanguageTag
            }
        }
    } catch {}

    try {
        $tz = Get-TimeZone
        if ($tz -and ![string]::IsNullOrWhiteSpace($tz.Id)) {
            $timeZone = $tz.Id
        }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($systemLocale)) { $systemLocale = $fallback }
    if ([string]::IsNullOrWhiteSpace($userLocale)) { $userLocale = $systemLocale }
    if ([string]::IsNullOrWhiteSpace($uiLanguage)) { $uiLanguage = $systemLocale }
    if ([string]::IsNullOrWhiteSpace($inputLocale)) { $inputLocale = $userLocale }
    if ([string]::IsNullOrWhiteSpace($timeZone)) { $timeZone = "UTC" }

    return [PSCustomObject]@{
        InputLocale  = $inputLocale
        SystemLocale = $systemLocale
        UILanguage   = $uiLanguage
        UserLocale   = $userLocale
        TimeZone     = $timeZone
    }
}

function GetWindowsSetupImagePath($MediaRoot) {
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) { return $null }
    $candidates = @(
        (Join-Path $MediaRoot "sources\install.wim"),
        (Join-Path $MediaRoot "sources\install.esd")
    )
    return ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
}

function GetWindowsInstallImageOptions($IsoPath) {
    if ([string]::IsNullOrWhiteSpace($IsoPath) -or !(Test-Path $IsoPath)) { return @() }

    $mount = $null
    $ownedMount = $false
    try {
        Spin "Scanning ISO installation options..." 1
        $mount = Get-DiskImage -ImagePath $IsoPath -EA Stop
        if (!$mount.Attached) { $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -EA Stop; $ownedMount = $true }
        $drv = ($mount | Get-Volume).DriveLetter
        if (!$drv) { throw "Could not get ISO drive letter" }

        $imagePath = GetWindowsSetupImagePath "${drv}:"
        if (!$imagePath) {
            Log "No install.wim/install.esd found on ISO; edition auto-selection unavailable." "WARN"
            return @()
        }

        if (!(Get-Command Get-WindowsImage -EA SilentlyContinue)) {
            Log "Get-WindowsImage cmdlet is unavailable; edition auto-selection unavailable." "WARN"
            return @()
        }

        $images = @(Get-WindowsImage -ImagePath $imagePath -EA Stop)
        if (!$images) { return @() }

        return @($images | ForEach-Object {
            [PSCustomObject]@{
                Index       = [int]$_.ImageIndex
                Name        = "$($_.ImageName)"
                Description = "$($_.ImageDescription)"
                Version     = if ($_.Version) { "$($_.Version)" } else { "" }
            }
        } | Sort-Object Index)
    } catch {
        Log "Failed to enumerate Windows installation options: $_" "WARN"
        return @()
    } finally {
        if ($ownedMount) { Dismount-DiskImage -ImagePath $IsoPath -EA SilentlyContinue | Out-Null }
    }
}

function PromptWindowsInstallImageSelection($ImageOptions) {
    if (!$ImageOptions -or $ImageOptions.Count -eq 0) { return $null }

    Write-Host ""
    Box "WINDOWS INSTALLATION OPTIONS" "-"
    foreach ($opt in $ImageOptions) {
        $descText = if (![string]::IsNullOrWhiteSpace($opt.Description) -and $opt.Description -ne $opt.Name) { " | $($opt.Description)" } else { "" }
        $verText = if (![string]::IsNullOrWhiteSpace($opt.Version)) { " | Version: $($opt.Version)" } else { "" }
        Write-Host ("  [{0}] {1}{2}{3}" -f $opt.Index.ToString().PadLeft(2, '0'), $opt.Name, $verText, $descText) -ForegroundColor Gray
    }
    Write-Host ""

    while ($true) {
        $raw = (Read-Host "  Installation index (press Enter to select manually during setup)").Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Log "No installation index selected; setup edition selection will remain manual." "INFO"
            return $null
        }

        $idx = 0
        if ([int]::TryParse($raw, [ref]$idx)) {
            $choice = $ImageOptions | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
            if ($choice) {
                Log ("Selected installation index {0}: {1}" -f $choice.Index, $choice.Name) "SUCCESS"
                return [PSCustomObject]@{ Index = [int]$choice.Index; Name = "$($choice.Name)" }
            }
        }

        Log "Invalid selection. Enter a listed index number or press Enter to skip." "WARN"
    }
}

function BuildImageSelectionXml($ImageSelection) {
    if (!$ImageSelection) { return "" }

    $index = 0
    if (![int]::TryParse("$($ImageSelection.Index)", [ref]$index) -or $index -le 0) { return "" }

    return @"
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>$index</Value>
                        </MetaData>
                    </InstallFrom>
"@
}

function BuildLocalAccountXml($LocalAccount) {
    if (!$LocalAccount) { return "" }

    $username = ""
    if ($LocalAccount.PSObject.Properties.Name -contains "Username") {
        $username = "$($LocalAccount.Username)"
    }
    $username = $username.Trim()
    if ([string]::IsNullOrWhiteSpace($username)) { $username = "User" }

    $password = ""
    if ($LocalAccount.PSObject.Properties.Name -contains "Password") {
        $password = "$($LocalAccount.Password)"
    }

    $escUser = XmlEsc $username
    $escPass = XmlEsc $password

    return @"
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$escUser</Name>
                        <DisplayName>$escUser</DisplayName>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>$escPass</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>$escPass</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$escUser</Username>
            </AutoLogon>
            <RegisteredOwner>$escUser</RegisteredOwner>
"@
}

function BuildAutoUnattendXml($LocaleSettings, $ImageSelection=$null, $LocalAccount=$null) {
    if (!$LocaleSettings) {
        $LocaleSettings = [PSCustomObject]@{
            InputLocale  = "en-US"
            SystemLocale = "en-US"
            UILanguage   = "en-US"
            UserLocale   = "en-US"
            TimeZone     = "UTC"
        }
    }

    $timeZone = "UTC"
    if ($LocaleSettings.PSObject.Properties.Name -contains "TimeZone") {
        $candidateTimeZone = "$($LocaleSettings.TimeZone)".Trim()
        if (![string]::IsNullOrWhiteSpace($candidateTimeZone)) {
            $timeZone = $candidateTimeZone
        }
    }

    $xml = $script:AutoXMLTemplate
    $xml = $xml.Replace("__IMAGE_SELECTION__", (BuildImageSelectionXml $ImageSelection))
    $xml = $xml.Replace("__INPUT_LOCALE__", (XmlEsc $LocaleSettings.InputLocale))
    $xml = $xml.Replace("__SYSTEM_LOCALE__", (XmlEsc $LocaleSettings.SystemLocale))
    $xml = $xml.Replace("__UI_LANGUAGE__", (XmlEsc $LocaleSettings.UILanguage))
    $xml = $xml.Replace("__USER_LOCALE__", (XmlEsc $LocaleSettings.UserLocale))
    $xml = $xml.Replace("__TIME_ZONE__", (XmlEsc $timeZone))
    $xml = $xml.Replace("__LOCAL_ACCOUNT_SETUP__", (BuildLocalAccountXml $LocalAccount))
    return $xml
}


#endregion
