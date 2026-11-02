[CmdletBinding()]
param(
    [string]$Command='interactive',
    [string]$VMName,[string]$GpuPath,[string]$GpuName,
    [ValidateRange(0,100)][int]$GpuPercent=0,
    [string]$Preset,[int]$Cpu=0,[int]$RamGB=0,[int]$StorageGB=0,
    [string]$VhdPath,[string]$IsoPath,[switch]$EnableAutoInstall,
    [int]$InstallImageIndex=0,[string]$UnattendUsername,[string]$UnattendPassword,
    [switch]$OverwriteVhd,[switch]$All,[switch]$CleanDrivers,[switch]$SkipExisting,
    [switch]$DeleteFiles,[switch]$Force,[switch]$SkipPreflight,[switch]$Json,
    [switch]$Shutdown,[string]$SystemDiskPath,[string]$ProfileName,
    [switch]$SetDefault,[string]$ConfigurationPath,[switch]$DeepDriverDiscovery
)
$ErrorActionPreference='Stop'
if ($Json) {$InformationPreference='SilentlyContinue';$ProgressPreference='SilentlyContinue'}
$root=$PSScriptRoot
try {
    if (![Environment]::Is64BitProcess) {throw 'Run the 64-bit Windows PowerShell executable.'}
    # UAC relaunch is only for human-operated interfaces. Automation keeps its
    # caller, output streams and exit status and reports missing elevation.
    $administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $desktopHost=Join-Path $root 'HyperV-Gpu-Manager.exe'
    if ($Command -eq 'desktop' -and (Test-Path -LiteralPath $desktopHost)) {
        $launch=@{FilePath=$desktopHost;Wait=$true;PassThru=$true}
        if (!$administrator) {$launch.Verb='RunAs'}
        $process=Start-Process @launch
        exit $process.ExitCode
    }
    if ($Command -in @('desktop','interactive') -and !$administrator) {
        $scriptPath=$PSCommandPath.Replace("'","''")
        $mode=$Command.Replace("'","''")
        $launch="& '$scriptPath' -Command '$mode'"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
        $style='Normal'
        $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-Sta','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -WindowStyle $style -Wait -PassThru
        exit $process.ExitCode
    }
    Import-Module (Join-Path $root 'src\HyperVGpuManager.psd1') -Force -DisableNameChecking
    if ($Command -eq 'desktop') {
        . (Join-Path $root 'src\Desktop\Window.ps1')
        Start-HgmDesktop -ProjectRoot $root
        exit 0
    }
    $parameters=@{}+$PSBoundParameters
    [void]$parameters.Remove('SkipPreflight')
    [void]$parameters.Remove('Verbose');[void]$parameters.Remove('Debug')
    if (!$parameters.ContainsKey('Command')) {$parameters.Command=$Command}
    if ($Command -eq 'interactive') {
        $ok=Start-HyperVGpuInteractiveMenu
        if (!$ok) {exit 1}
    } else {
        [void]$parameters.Remove('Command');[void]$parameters.Remove('Json')
        $result=Invoke-HgmCommand -Command $Command -Parameters $parameters
        if ($Json) {ConvertTo-Json -InputObject $result -Depth 30}
        elseif ($Command -eq 'help') {& (Get-Module HyperVGpuManager) {Show-HyperVGpuCliHelp}}
        else {& (Get-Module HyperVGpuManager) {param($r) Write-HyperVGpuCliResult $r} $result}
        if (!$result.Success) {exit 1}
    }
    exit 0
} catch {
    $message=$_.Exception.Message
    if ($UnattendPassword) {$message=$message.Replace($UnattendPassword,'[redacted]')}
    if ($Json) {
        [pscustomobject]@{Operation=$Command;Success=$false;Data=$null;Message=$message;ErrorCode='StartupFailed';SchemaVersion=2;TimestampUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 10
    } else {Write-Error $message -ErrorAction Continue}
    exit 1
}
