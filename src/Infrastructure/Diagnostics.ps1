function Initialize-HgmDiagnostics {
    param([string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'HyperV-Gpu-Manager\Logs'))
    $script:HgmLogRoot = $LogRoot
    $script:HgmOperationId = [guid]::NewGuid().ToString('N')
    $script:HgmEvents = New-Object 'System.Collections.Generic.List[object]'
}

function Write-HgmEvent([string]$Code, [string]$Message, [string]$Level = 'Info') {
    if (!$script:HgmOperationId) { Initialize-HgmDiagnostics }
    $event = [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o'); OperationId = $script:HgmOperationId
        Level = $Level; Code = $Code; Message = $Message
    }
    $script:HgmEvents.Add($event)
    if ($script:HgmProgressQueue) { $script:HgmProgressQueue.Enqueue($event) }
    try {
        if (!(Test-Path -LiteralPath $script:HgmLogRoot)) { New-Item -ItemType Directory -Path $script:HgmLogRoot -Force -EA Stop | Out-Null }
        $file = Join-Path $script:HgmLogRoot ("{0}.jsonl" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        [IO.File]::AppendAllText($file, ($event | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { Write-Verbose 'Diagnostic file could not be written; in-memory diagnostics remain available.' }
}

function Test-HgmCancellation {
    if ($script:HgmCancellation -and $script:HgmCancellation.IsCancellationRequested) {
        throw (New-Object OperationCanceledException('Operation cancelled at a safe boundary.'))
    }
}

function Write-HgmAtomicJson([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force -EA Stop | Out-Null }
    $temporary = Join-Path $parent ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 30), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, "$Path.bak", $true) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -EA SilentlyContinue } }
}

function Invoke-HgmExclusive([string]$Key, [scriptblock]$Action) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Global\HyperVGpuManager_$hash")
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (!$owned) { throw 'Another manager operation is using this VM or configuration. Wait for it to finish.' }
        & $Action
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
