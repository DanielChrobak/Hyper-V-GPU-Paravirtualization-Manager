function ResolveGuestSystemDestinationPath($DestinationPath) {
    $relative = "$DestinationPath" -replace '^[A-Za-z]:', ''
    $relative = $relative.Replace('/', '\')
    if ($relative -eq '\Windows\System32\cmd.exe') { return $null }
    $relative = $relative -replace '^(?i)\\Windows\\System32\\DriverStore\\FileRepository\\', '\Windows\System32\HostDriverStore\FileRepository\'
    $null = Assert-HgmDriverDestination $relative
    return $relative
}

function Get-HgmManifest([string]$Root) {
    $path = Resolve-HgmContainedPath $Root 'Windows\System32\HostDriverStore\gpu-driver-manifest.json'
    if (!(Test-Path -LiteralPath $path)) { return @() }
    try {
        $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json -EA Stop
        if ($doc.PSObject.Properties['SchemaVersion']) {
            if ([int]$doc.SchemaVersion -ne 2) { throw 'Unrecognized manifest schema.' }
            return @($doc.Entries)
        }
        # Legacy ownership can be displayed/migrated, but cannot prove safe deletion.
        return @($doc)
    } catch { throw 'Guest driver manifest is unreadable. Restore its .bak copy or repair it before continuing; ownership data will not be discarded.' }
}

function ReadDriverManifest($MountPath) { return @(Get-HgmManifest $MountPath) }
function WriteDriverManifest($MountPath, $Entries) {
    $path = Resolve-HgmContainedPath $MountPath 'Windows\System32\HostDriverStore\gpu-driver-manifest.json'
    Write-HgmAtomicJson $path ([pscustomobject]@{SchemaVersion=2;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Entries=@($Entries)})
}

function Get-HgmDriverPlan($Gpus) {
    $all = @{}; $entries = @()
    foreach ($gpu in @($Gpus)) {
        Test-HgmCancellation
        Write-HgmEvent 'DriverDiscovery' "Discovering installed driver files for '$($gpu.DeviceName)'."
        $set = GetDrivers $gpu
        $paths = New-Object 'System.Collections.Generic.List[string]'
        $candidates = New-Object 'System.Collections.Generic.List[object]'
        foreach ($folder in @($set.Folders)) {
            $sourceFiles = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -EA Stop)
            if (!$sourceFiles.Count) { throw "Driver package is empty: $folder" }
            foreach ($file in $sourceFiles) {
                $tail = $file.FullName.Substring($folder.TrimEnd([char]'\').Length).TrimStart([char]'\')
                $candidates.Add([pscustomobject]@{Source=$file.FullName;RelativePath="Windows\System32\HostDriverStore\FileRepository\$(Split-Path -Leaf $folder)\$tail"})
            }
        }
        foreach ($file in @($set.Files)) {
            $destination = ResolveGuestSystemDestinationPath $file.D
            if ($destination) { $candidates.Add([pscustomobject]@{Source=$file.S;RelativePath=$destination.TrimStart([char]'\');Policy=$file.Policy}) }
        }
        foreach ($candidate in $candidates) {
            Test-HgmCancellation
            $null = Assert-HgmDriverDestination $candidate.RelativePath
            $source = Get-Item -LiteralPath $candidate.Source -Force -EA Stop
            if ($source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Driver source must be a regular file.' }
            $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256 -EA Stop).Hash
            $key = $candidate.RelativePath
            if ($all.ContainsKey($key) -and $all[$key].Hash -ne $hash) { throw "Selected GPUs require conflicting bytes at '$key'. Deploy separately only after resolving the driver conflict." }
            $all[$key] = [pscustomobject]@{Source=$source.FullName;RelativePath=$key;Hash=$hash;Length=$source.Length;Version=$source.VersionInfo.FileVersion;Policy=$candidate.Policy}
            $paths.Add($key)
        }
        if ($set.Missing.Count) { Write-HgmEvent 'UnresolvedInfTokens' "$($set.Missing.Count) INF tokens could not be resolved. INF parsing is advisory; this deployment requires guest validation." 'Warning' }
        $entries += [pscustomobject]@{EntryId=[guid]::NewGuid().ToString('N');CapturedUtc=[DateTime]::UtcNow.ToString('o')
            GpuDeviceId=$gpu.DeviceID;GpuName=$gpu.DeviceName;DriverVersion=$gpu.DriverVersion
            Resolver=$set.Strategy;InfPath=$set.InfPath;Missing=@($set.Missing);Paths=@($paths.ToArray() | Sort-Object -Unique)
            Folders=@($set.Folders | ForEach-Object {"\Windows\System32\HostDriverStore\FileRepository\$(Split-Path -Leaf $_)"})}
    }
    if (!$all.Count) { throw 'The driver plan contains no files.' }
    return [pscustomobject]@{Entries=$entries;Files=@($all.Values | Sort-Object RelativePath);FileCount=$all.Count
        Bytes=[long](($all.Values | Measure-Object Length -Sum).Sum);Compatibility='Windows GPU-PV host-driver deployment; workload validation inside the guest is recommended'}
}

function Undo-HgmDriverTransaction([string]$Root, $Journal) {
    $errors = @()
    $reversed = @($Journal.Items)
    [array]::Reverse($reversed)
    foreach ($item in $reversed) {
        if (!$item.Applied) { continue }
        try {
            $target = Resolve-HgmContainedPath $Root $item.RelativePath
            if ($item.Existed) {
                $backup = Resolve-HgmContainedPath $Root $item.RollbackPath
                Copy-Item -LiteralPath $backup -Destination $target -Force -EA Stop
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $item.PreviousHash) { throw 'Rollback hash mismatch.' }
            } elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -EA Stop }
        } catch { $errors += $_.Exception.Message }
    }
    if ($errors.Count) { throw "Rollback is incomplete. Keep the VM off and run recover-drivers. $($errors -join '; ')" }
}

function Get-HgmTransactionDirectory([string]$Root) {
    Resolve-HgmContainedPath $Root 'Windows\System32\HostDriverStore\.manager\transactions'
}

function Repair-HgmDriverTransactions([string]$Root) {
    $directory = Get-HgmTransactionDirectory $Root
    if (!(Test-Path -LiteralPath $directory)) { return 0 }
    $recovered = 0
    foreach ($folder in @(Get-ChildItem -LiteralPath $directory -Directory -Force -EA Stop)) {
        $journalPath = Resolve-HgmContainedPath $Root "Windows\System32\HostDriverStore\.manager\transactions\$($folder.Name)\journal.json"
        if (!(Test-Path -LiteralPath $journalPath)) { continue }
        $journal = Get-Content -LiteralPath $journalPath -Raw -EA Stop | ConvertFrom-Json -EA Stop
        if ($journal.State -in @('Committed','RolledBack')) { continue }
        Undo-HgmDriverTransaction $Root $journal
        $journal.State = 'RolledBack'
        Write-HgmAtomicJson $journalPath $journal
        $recovered++
    }
    return $recovered
}

function Invoke-HgmDriverTransaction([string]$Root, $Plan, [string[]]$RemoveGpuIds, [switch]$SkipExisting) {
    $pending = Repair-HgmDriverTransactions $Root
    if ($pending) { Write-HgmEvent 'RecoveredTransaction' "Recovered $pending interrupted driver transaction(s)." 'Warning' }
    $old = @(Get-HgmManifest $Root)
    $selectedIds = if ($Plan) {@($Plan.Entries | ForEach-Object GpuDeviceId)} else {@($RemoveGpuIds)}
    $retained = @($old | Where-Object { $_.GpuDeviceId -notin $selectedIds })
    $owned = @{}; $shared = @{}
    foreach ($entry in $old) { foreach ($record in @($entry.Records)) { if ($record) { $owned[$record.RelativePath] = $record } } }
    foreach ($entry in $retained) { foreach ($record in @($entry.Records)) { if ($record) { $shared[$record.RelativePath] = $record } } }
    $transactionId = [guid]::NewGuid().ToString('N')
    $transactionRelative = "Windows\System32\HostDriverStore\.manager\transactions\$transactionId"
    $transactionRoot = Resolve-HgmContainedPath $Root $transactionRelative
    New-Item -ItemType Directory -Path $transactionRoot -Force -EA Stop | Out-Null
    $journalPath = Join-Path $transactionRoot 'journal.json'
    $items = New-Object 'System.Collections.Generic.List[object]'
    $records = @{}; $newFiles = @{}; $skipped = 0; $copied = 0; $journal = $null
    if ($Plan) { foreach ($file in $Plan.Files) { $newFiles[$file.RelativePath] = $file } }
    try {
        $sequence = 0
        foreach ($file in @($newFiles.Values)) {
            Test-HgmCancellation
            $target = Resolve-HgmContainedPath $Root $file.RelativePath
            $exists = Test-Path -LiteralPath $target -PathType Leaf
            $priorHash = if ($exists) {(Get-FileHash -LiteralPath $target -Algorithm SHA256 -EA Stop).Hash} else {$null}
            if ($file.Policy -eq 'WhenNewer' -and $exists -and $priorHash -ne $file.Hash -and !(Test-HgmSourceNewer $file.Source $target)) {
                $skipped++;Write-HgmEvent 'NewerGuestRuntime' "Preserved newer guest runtime '$($file.RelativePath)' according to the driver promotion rule."
                continue
            }
            if ($shared.ContainsKey($file.RelativePath) -and $shared[$file.RelativePath].Hash -ne $file.Hash) { throw "A retained GPU owns different bytes at '$($file.RelativePath)'. Synchronize all sharing GPUs together." }
            $original = if ($owned.ContainsKey($file.RelativePath)) {$owned[$file.RelativePath].OriginalPath} else {$null}
            $originalHash = if ($owned.ContainsKey($file.RelativePath)) {$owned[$file.RelativePath].OriginalHash} else {$null}
            if (!$owned.ContainsKey($file.RelativePath) -and $exists) {
                $original = "Windows\System32\HostDriverStore\.manager\originals\$([guid]::NewGuid().ToString('N')).bin"
                $originalPath = Resolve-HgmContainedPath $Root $original
                New-Item -ItemType Directory -Path (Split-Path -Parent $originalPath) -Force -EA Stop | Out-Null
                Copy-Item -LiteralPath $target -Destination $originalPath -EA Stop
                $originalHash=$priorHash
                if ((Get-FileHash -LiteralPath $originalPath).Hash -ne $originalHash) {throw 'Original guest file backup failed verification.'}
            }
            $records[$file.RelativePath] = [pscustomobject]@{RelativePath=$file.RelativePath;Hash=$file.Hash;Length=$file.Length;Version=$file.Version;OriginalPath=$original;OriginalHash=$originalHash}
            if ($SkipExisting -and $priorHash -eq $file.Hash) { $skipped++; continue }
            $sequence++
            $stageRelative = "$transactionRelative\stage\$sequence.bin"
            $stage = Resolve-HgmContainedPath $Root $stageRelative
            New-Item -ItemType Directory -Path (Split-Path -Parent $stage) -Force -EA Stop | Out-Null
            Copy-Item -LiteralPath $file.Source -Destination $stage -EA Stop
            if ((Get-FileHash -LiteralPath $stage -Algorithm SHA256 -EA Stop).Hash -ne $file.Hash) { throw 'Host driver changed during staging. Retry after the host driver update completes.' }
            $items.Add([pscustomobject]@{RelativePath=$file.RelativePath;StagePath=$stageRelative;ExpectedHash=$file.Hash;Existed=$exists;PreviousHash=$priorHash;RollbackPath="$transactionRelative\rollback\$sequence.bin";Applied=$false;Delete=$false})
        }
        # Remove stale files only when their recorded bytes still match and no
        # retained GPU shares them. Guest-modified files are preserved and reported.
        $staleSeen=@{}
        foreach ($entry in @($old | Where-Object { $_.GpuDeviceId -in $selectedIds })) {
            if (!$entry.PSObject.Properties['Records']) { Write-HgmEvent 'LegacyOwnership' 'Legacy manifest has no file hashes; unknown old files are preserved. New deployments establish tracked ownership.' 'Warning' }
            foreach ($record in @($entry.Records)) {
                if (!$record -or $newFiles.ContainsKey($record.RelativePath) -or $shared.ContainsKey($record.RelativePath) -or $staleSeen.ContainsKey($record.RelativePath)) { continue }
                $staleSeen[$record.RelativePath]=$true
                $target = Resolve-HgmContainedPath $Root (Assert-HgmDriverDestination $record.RelativePath)
                if (!(Test-Path -LiteralPath $target -PathType Leaf)) { continue }
                $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -EA Stop).Hash
                if ($hash -ne $record.Hash) { throw "Guest-modified file '$($record.RelativePath)' will be preserved. Resolve the conflict before cleanup." }
                $sequence++
                $original = if ($record.OriginalPath) {Resolve-HgmContainedPath $Root $record.OriginalPath} else {$null}
                if ($original -and !(Test-Path -LiteralPath $original -PathType Leaf)) { throw 'An original file backup is missing; cleanup cannot restore it safely.' }
                if ($original -and (!$record.OriginalHash -or (Get-FileHash -LiteralPath $original).Hash -ne $record.OriginalHash)) {throw 'An original file backup is damaged or unverified. Keep the current driver files and restore a known-good backup before cleanup.'}
                $items.Add([pscustomobject]@{RelativePath=$record.RelativePath;StagePath=$record.OriginalPath;ExpectedHash=if ($original) {(Get-FileHash -LiteralPath $original).Hash} else {$null}
                    Existed=$true;PreviousHash=$hash;RollbackPath="$transactionRelative\rollback\$sequence.bin";Applied=$false;Delete=(!$original)})
            }
        }
        $newEntries = @()
        if ($Plan) {
            foreach ($entry in $Plan.Entries) {
                $entry | Add-Member NoteProperty Records @($entry.Paths | Where-Object {$records.ContainsKey($_)} | ForEach-Object {$records[$_]}) -Force
                $entry | Add-Member NoteProperty Files @($entry.Paths) -Force
                $newEntries += $entry
            }
        }
        # Include manifest replacement in the same rollback journal.
        $manifestRelative = 'Windows\System32\HostDriverStore\gpu-driver-manifest.json'
        $manifestPath = Resolve-HgmContainedPath $Root $manifestRelative
        $manifestStageRelative = "$transactionRelative\manifest.json"
        Write-HgmAtomicJson (Resolve-HgmContainedPath $Root $manifestStageRelative) ([pscustomobject]@{SchemaVersion=2;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Entries=@($retained+$newEntries)})
        $items.Add([pscustomobject]@{RelativePath=$manifestRelative;StagePath=$manifestStageRelative;ExpectedHash=(Get-FileHash -LiteralPath (Resolve-HgmContainedPath $Root $manifestStageRelative)).Hash
            Existed=(Test-Path -LiteralPath $manifestPath);PreviousHash=if (Test-Path -LiteralPath $manifestPath) {(Get-FileHash -LiteralPath $manifestPath).Hash} else {$null}
            RollbackPath="$transactionRelative\manifest.previous";Applied=$false;Delete=$false})
        $journal = [pscustomobject]@{Id=$transactionId;State='Prepared';Items=@($items.ToArray())}
        foreach ($item in $journal.Items) {
            if ($item.Existed) {
                $backup = Resolve-HgmContainedPath $Root $item.RollbackPath
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force -EA Stop | Out-Null
                Copy-Item -LiteralPath (Resolve-HgmContainedPath $Root $item.RelativePath) -Destination $backup -EA Stop
                if ((Get-FileHash -LiteralPath $backup).Hash -ne $item.PreviousHash) { throw 'Destination changed during preparation.' }
            }
        }
        Write-HgmAtomicJson $journalPath $journal
        # All rollback copies exist. Record intent once before any write; recovery
        # may safely restore unchanged files as well. Avoid a quadratic-size journal
        # rewrite after every DLL in a large vendor package.
        foreach ($item in $journal.Items) { $item.Applied = $true }
        $journal.State = 'Applying'; Write-HgmAtomicJson $journalPath $journal
        foreach ($item in $journal.Items) {
            Test-HgmCancellation
            $target = Resolve-HgmContainedPath $Root $item.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force -EA Stop | Out-Null
            if ($item.Delete) { Remove-Item -LiteralPath $target -Force -EA Stop }
            else {
                Copy-Item -LiteralPath (Resolve-HgmContainedPath $Root $item.StagePath) -Destination $target -Force -EA Stop
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -EA Stop).Hash -ne $item.ExpectedHash) { throw "Verification failed: $($item.RelativePath)" }
                $copied++
            }
        }
        $journal.State='Committed'; Write-HgmAtomicJson $journalPath $journal
        Write-HgmEvent 'DriverCommit' "Committed driver transaction $transactionId."
        return [pscustomobject]@{TransactionId=$transactionId;Copied=$copied-1;Skipped=$skipped;Entries=@($retained+$newEntries).Count}
    } catch {
        $failure = $_
        if ($journal) {
            Undo-HgmDriverTransaction $Root $journal
            $journal.State='RolledBack'; Write-HgmAtomicJson $journalPath $journal
        }
        throw $failure
    }
}

function Test-HgmDriverDrift([string]$Root) {
    foreach ($entry in @(Get-HgmManifest $Root)) {
        if (!$entry.PSObject.Properties['Records']) { [pscustomobject]@{Gpu=$entry.GpuName;Path=$null;Status='Legacy manifest: redeploy to establish file hashes'}; continue }
        foreach ($record in @($entry.Records)) {
            $path = Resolve-HgmContainedPath $Root (Assert-HgmDriverDestination $record.RelativePath)
            $status = if (!(Test-Path -LiteralPath $path -PathType Leaf)) {'Missing'}
                elseif ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -EA Stop).Hash -ne $record.Hash) {'Changed'} else {'Current'}
            [pscustomobject]@{Gpu=$entry.GpuName;DriverVersion=$entry.DriverVersion;Path=$record.RelativePath;Status=$status}
        }
    }
}
