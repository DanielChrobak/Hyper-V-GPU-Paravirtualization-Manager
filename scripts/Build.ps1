[CmdletBinding()]
param([switch]$Package,[switch]$SkipTests)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$powershellAssembly=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\System.Management.Automation.dll'
if (!(Test-Path -LiteralPath $powershellAssembly)) {
    $powershellAssembly=[Management.Automation.PSObject].Assembly.Location
}
$framework=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\WPF'
if (!(Test-Path -LiteralPath $compiler)) {throw 'The Windows .NET Framework x64 C# compiler is required.'}
if (!$SkipTests) {& (Join-Path $PSScriptRoot 'Test.ps1')}
$output=Join-Path $project 'HyperV-Gpu-Manager.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Xaml.dll "/out:$output" "/reference:$powershellAssembly" "/reference:$framework\PresentationFramework.dll" "/reference:$framework\PresentationCore.dll" "/reference:$framework\WindowsBase.dll" (Join-Path $project 'src\Desktop\Program.cs')
if ($LASTEXITCODE -ne 0) {throw 'Desktop compilation failed.'}
Write-Host "Built $output"
if ($Package) {
    $artifact=Join-Path $project 'artifacts'
    New-Item -Path $artifact -ItemType Directory -Force | Out-Null
    $staging=Join-Path $artifact ('package-'+[guid]::NewGuid().ToString('N'))
    New-Item -Path $staging -ItemType Directory | Out-Null
    try {
        foreach ($name in @('HyperV-Gpu-Manager.exe','HyperV-GPU-Virtualization-Manager.ps1','Run-HyperV-GPU-Virtualization-Manager.cmd','Build-And-Run.bat','src','docs','README.md','LICENSE','THIRD_PARTY_NOTICES.md','scripts','tests')) {
            Copy-Item -LiteralPath (Join-Path $project $name) -Destination $staging -Recurse -Force
        }
        $zip=Join-Path $artifact 'HyperV-Gpu-Manager-2.0.0-windows-x64.zip'
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
        Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Format-List
    } finally {
        $safe=[IO.Path]::GetFullPath($staging)
        $base=[IO.Path]::GetFullPath($artifact).TrimEnd([char]'\')+'\'
        if (!$safe.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $safe) -notmatch '^package-[0-9a-f]{32}$') {throw 'Unexpected packaging staging directory.'}
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
