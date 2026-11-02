# Hyper-V GPU Paravirtualization Manager

Share your Windows host's GPU with Hyper-V Windows guests for games, development,
graphics and compute. The manager discovers your installed drivers, assigns GPU
partitions and synchronizes the guest files needed by GPU-PV.

**The primary workflow is regular Windows 10/11 with consumer NVIDIA, AMD and Intel
GPUs. It does not require Windows Server or a commercial vGPU subscription.**
GPU-PV shares the host GPU; the host keeps using it. This project builds on the
community method documented by Nimoa/nta, neggles, Easy-GPU-PV and its successors.
See the [research and attribution record](docs/PLATFORM_RESEARCH.md).

## What's in version 2

- Native WPF desktop with host readiness, VM/device inventory, creation, profiles,
  GPU assignment and driver maintenance. Background workers keep the UI responsive.
- The interactive console and headless PowerShell commands remain available.
- Full device identities distinguish identical physical GPUs.
- SetupAPI resolves the active OEM driver package. Driver-declared CopyToVm rules
  handle renamed CUDA/NVML/OpenCL/Vulkan loaders and native/32-bit runtime files.
- Intel media-runtime loader aliases and AMD companion-package discovery improve
  file coverage without choosing arbitrary DLLs from unrelated driver versions.
- Driver plans, SHA-256 drift checks, synchronization and interrupted-copy recovery.
- Staging, verified copies and a durable journal protect deployment. Selective
  cleanup preserves shared files and restores backed-up original guest files.
- VM creation validates storage first, retains overwritten VHDs as backups and
  rolls back a partial VM. Existing larger MMIO settings are preserved.
- Saved profile passwords use Windows user encryption. Configuration backup and
  restore, structured operation IDs and JSONL diagnostic logs are included.

## Requirements and compatibility

Use a 64-bit Windows 10/11 host with Hyper-V and its management tools enabled,
administrator rights for VM operations, and a host driver that exposes a
partitionable device. Windows 11 is the preferred target. Windows 10 installations
retain the older enumeration and single-device fallback where the installed
interfaces permit it.

NVIDIA, AMD and Intel use the same metadata-based pipeline. Device names alone
never establish compatibility. A GPU reported by Hyper-V can be selected; games,
rendering APIs, video codecs and compute runtimes still depend on the GPU, driver
and guest Windows version. Driver synchronization is intended for x64 Windows
guests with the Windows system volume accessible offline. Keep host and guest
Windows versions reasonably aligned and synchronize after host driver updates.

Non-display partitionable accelerators remain discoverable and use the same
package mechanism. Their application runtimes need their own workload checks.
Linux driver deployment, ARM64 packages and an HCS backend for Windows Home are
not implemented in this release. App Sandbox's Home/HCS route is a different VM
backend from this application's existing Hyper-V VMs.

No streaming program or hardware encoder is required merely to assign a GPU.
For interactive gaming, the guest's display/capture/streaming setup is a separate
step; Hyper-V VMConnect and RDP may behave differently from a console session.
See [troubleshooting](docs/USAGE.md#troubleshooting).

## Run

Extract the complete package to a writable directory. Keep the executable,
PowerShell entry point and src directory together.

- Double-click Run-HyperV-GPU-Virtualization-Manager.cmd to open the desktop and
  request elevation.
- Or run HyperV-Gpu-Manager.exe directly. The dashboard works without elevation;
  use its **Run as administrator** button before changing Hyper-V resources.
- A source checkout also runs without compiling the native launcher:

~~~powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File .\HyperV-GPU-Virtualization-Manager.ps1 -Command desktop
~~~

The original console remains available:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperV-GPU-Virtualization-Manager.ps1 -Command interactive
~~~

The release executable is built locally; this work does not provide a signing
certificate. The application does not change machine-wide execution policy,
install Hyper-V, change host security settings or reboot Windows.

## Typical workflow

1. Run **Refresh host** and resolve any blocked prerequisites.
2. Create a Generation 2 VM or select an existing Windows VM. Install Windows
   before driver synchronization.
3. Select the VM and a partitionable host GPU; apply the desired allocation.
4. With the VM off, preview the driver plan, then synchronize drivers.
5. Boot the guest and test the intended graphics/compute workload.
6. After updating host drivers, shut down the guest and synchronize again.

An operation refuses to change a running VM unless graceful shutdown is explicitly
enabled. There is no automatic forced power-off. Cancellation takes effect at
safe boundaries; an interrupted driver application is rolled back.

## Automation

Use an elevated **Windows PowerShell 5.1** session for Hyper-V commands.
Headless commands do not launch a separate elevated process. -Json writes one
result object; exit code 0 means success and 1 means failure.

~~~powershell
# Inspect prerequisites and inventory
.\HyperV-GPU-Virtualization-Manager.ps1 -Command preflight -Json
.\HyperV-GPU-Virtualization-Manager.ps1 -Command list-gpus -Json
.\HyperV-GPU-Virtualization-Manager.ps1 -Command list-vms -Json

# Create a VM; attach an existing Windows ISO
.\HyperV-GPU-Virtualization-Manager.ps1 -Command create-vm -Preset gaming -VMName GameVM -IsoPath C:\ISOs\Windows.iso

# Use the exact InstancePath returned by list-gpus
.\HyperV-GPU-Virtualization-Manager.ps1 -Command set-gpu -VMName GameVM -GpuPath '<InstancePath>' -GpuPercent 50

# Preview, synchronize and audit all assigned adapters
.\HyperV-GPU-Virtualization-Manager.ps1 -Command plan-drivers -VMName GameVM -Json
.\HyperV-GPU-Virtualization-Manager.ps1 -Command install-drivers -VMName GameVM -All -SkipExisting
.\HyperV-GPU-Virtualization-Manager.ps1 -Command audit-drivers -VMName GameVM -Json

# Recovery and selective removal
.\HyperV-GPU-Virtualization-Manager.ps1 -Command recover-drivers -VMName GameVM
.\HyperV-GPU-Virtualization-Manager.ps1 -Command remove-gpu -VMName GameVM -GpuPath '<InstancePath>' -CleanDrivers

# Delete the VM registration while retaining disk files
.\HyperV-GPU-Virtualization-Manager.ps1 -Command delete-vm -VMName GameVM -Force
~~~

[Usage and troubleshooting](docs/USAGE.md) covers all parameters, multiple disks,
unattended installation, profiles, backup/restore and cleanup behavior.

## Build, test and package

Windows includes the required PowerShell, WPF and .NET Framework interfaces.
The optional native launcher is compiled with the installed x64 .NET Framework
C# compiler; no NuGet packages or downloaded application runtime are needed.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1 -Package
~~~

The disk regression suite requires Pester 3/4; CI pins Pester 4.10.1. The package
is written to artifacts/HyperV-Gpu-Manager-2.0.0-windows-x64.zip, with its SHA-256
printed by the build. [Development notes](docs/DEVELOPMENT.md) explain the layers,
checks, performance fixture and release process.

## Upgrade and data

Back up profiles before upgrading. Extract the new release into a new directory,
then copy .hyperv-gpu-manager.vm-profiles.json from the previous directory, or use
backup-config / restore-config. Encrypted passwords require the same Windows user
and machine. Legacy schema-1 profiles remain readable and migrate on save; old
backups of legacy stores may still contain plaintext credentials and must be
handled accordingly.

Existing VMs and VHDs are not migrated or recreated on startup. Existing guest
driver manifests are readable. Legacy manifests lack verified per-file ownership:
redeploy to establish hashes; cleanup preserves unverified legacy files instead
of guessing what to delete.

## Validation and known limits

See the [feature-parity checklist](docs/FEATURE_PARITY.md) and
[validation matrix](docs/VALIDATION.md) for the actual checks and remaining
hardware-dependent coverage. This rebuild was tested on Windows 11 IoT Enterprise
LTSC build 26100 in a non-elevated session. Host-side driver discovery was exercised
against an RTX 4090 and Intel Graphics. Automated tests use real temporary files
and mocked Hyper-V boundaries.

No real VM was stopped, mounted, created or reconfigured during this work.
Guest boot, DirectX/OpenGL/Vulkan, CUDA/OpenCL, video codecs, ADK ISO creation and
other hardware/OS combinations still require integration validation. File
discovery or a passing mock does not prove those workloads work.

## License

[MIT](LICENSE), preserving the existing Copyright (c) 2025 Daniel Chrobak.
[Third-party notices and acknowledgements](THIRD_PARTY_NOTICES.md) describe
dependencies and the community work consulted during the rebuild.
