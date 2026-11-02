[CmdletBinding()]
param([switch]$SkipTests,[switch]$BuildOnly)

$ErrorActionPreference='Stop'
# cmd.exe can carry PowerShell 7's module paths into Windows PowerShell 5.1.
# Use its native module roots for this build/launch process and its test children.
$moduleRoots=@(
    [IO.Path]::Combine([Environment]::GetFolderPath('MyDocuments'),'WindowsPowerShell','Modules'),
    [IO.Path]::Combine($env:ProgramFiles,'WindowsPowerShell','Modules'),
    [IO.Path]::Combine($PSHOME,'Modules')
)
$env:PSModulePath=$moduleRoots -join [IO.Path]::PathSeparator
$project=Split-Path -Parent $PSScriptRoot
try {
    Write-Host 'Building Hyper-V GPU Manager...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Build.ps1') -SkipTests:$SkipTests

    $executable=Join-Path $project 'HyperV-Gpu-Manager.exe'
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) {throw 'The build did not produce HyperV-Gpu-Manager.exe.'}
    if ($BuildOnly) {Write-Host 'Build completed. Launch skipped (-BuildOnly).' -ForegroundColor Green;exit 0}

    $administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $launch=@{FilePath=$executable;WorkingDirectory=$project;ErrorAction='Stop'}
    if (!$administrator) {
        Write-Host 'Requesting administrator access to launch the app...' -ForegroundColor Cyan
        $launch.Verb='RunAs'
    }
    Start-Process @launch
    Write-Host 'Hyper-V GPU Manager started as administrator.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ("Build or launch failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Close any running copy of the app before rebuilding. If Windows asks for administrator access, approve the UAC prompt to launch.' -ForegroundColor Yellow
    exit 1
}
