# Development and release

## Architecture

Windows PowerShell 5.1 is the supported host for application execution because
the inbox Hyper-V, Storage, DISM and PnpDevice modules are native to Windows.
The small C# desktop host embeds that runtime and WPF without a console window.
It is built using the installed .NET Framework x64 compiler. Application execution
does not depend on NuGet, a web server, Node.js or another downloaded runtime.

| Layer | Responsibility |
|---|---|
| src/Domain | Device identity, resource rules and path/input validation |
| src/Platform | Hyper-V/Windows access, SetupAPI, driver metadata and installation media |
| src/Application | Orchestration, configuration, driver plan/transaction/recovery and command boundary |
| src/Infrastructure | Atomic persistence, operation lock, cancellation and structured diagnostics |
| src/Api | Stable automation facade and inventory models |
| src/Desktop | WPF presentation, background runspace and native launcher |
| src/Cli | Console presentation and command output |
| src/Core | Verified legacy helpers and compatibility entry points |

Each command returns one envelope. Mutations serialize per VM/configuration.
The desktop uses a background runspace and a thread-safe progress queue; it never
calls WPF controls from the worker. Cancellation is cooperative. Closing during
work requests cancellation and waits for cleanup rather than aborting the worker.

## Checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1 -Package
git diff --check
$env:GRAPHIFY_BACKEND='none'
graphify update .
```

Test.ps1 parses all application/test PowerShell files, validates the module
manifest and XAML XML, and runs isolated fixture processes plus the Pester disk
suite. Tests do not require host elevation or real GPU/VM changes. Pester 3/4 is a
development dependency; CI installs version 4.10.1. Hosted CI builds the native
launcher and portable ZIP. A passing hosted build is not a hardware compatibility
result. The local validation record states whether remote CI has actually run.

```powershell
# Development-only dependency, if no Pester 3/4 is installed
Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser
# Reproduce the recorded comparison against the preserved starting baseline
.\scripts\Measure-Performance.ps1 -BaselineCommit 5bfbca4
```

The performance fixture exports the baseline into a temporary directory and uses
100 real 16-KiB files, with host boundaries stubbed. It compares implementation
load, first deployment and hash-skipping repeat deployment. It does not measure
GPU performance or actual VHD throughput. Initial synchronization does more I/O
than the previous direct copy because staging, hashing and recovery are now
required. Investigate material differences; do not claim a blanket speedup.

## Release and upgrade verification

Build.ps1 -Package includes an explicit allowlist of runtime/source/docs/tests,
prints the ZIP SHA-256 and removes only its own verified staging directory. It
excludes profiles, logs, host drivers, credentials, local .codex settings, Git data
and Graphify output. Build.ps1 -SkipTests is available for iterative desktop builds;
normal release builds run the checks. No signing certificate or release upload is
configured. Publish only after the applicable guest/hardware checks are recorded.

Test upgrades with an existing schema-1 profile and a legacy guest manifest;
neither should be discarded. Existing VMs need no startup migration. Preserve the
original MIT license and notices. Research findings and any borrowed component
must be recorded in PLATFORM_RESEARCH.md and THIRD_PARTY_NOTICES.md; do not import
copyleft code into this MIT project without an explicit licensing decision.
