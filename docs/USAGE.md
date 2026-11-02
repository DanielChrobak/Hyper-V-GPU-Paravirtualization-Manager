# Usage and troubleshooting

## Desktop and console

The CMD launcher opens the desktop with elevation. The native EXE can also open
readiness diagnostics without elevation. Select a VM in the Virtual machines tab
before using GPU and driver actions. Choose a host device for assignment; choose
an assigned device (or all) for maintenance. The Windows system disk selector
offers explicit attached paths and automatic probing. Automatic probing refuses
multiple accessible Windows installations rather than writing to an arbitrary one.

The console supports arrows, W/S, Enter, Esc and numeric shortcuts. It retains
presets, custom creation, profiles, inventory and selective GPU workflows. The
desktop adds plans, audits, recovery and saved operation results.

## Command parameters

The entry point is HyperV-GPU-Virtualization-Manager.ps1. Run `-Command help` for
the command list; `-Json` returns one structured envelope with Operation, Success,
Data, Message, TimestampUtc, SchemaVersion, OperationId, ErrorCode, DurationMs and
Diagnostics. Exit code is 0 on success and 1 on failure. Readiness may return useful
Data even when Success is false. The PowerShell module exports Invoke-HgmCommand
and the previous Invoke-HyperVGpuApi* facade.

| Command | Parameters |
|---|---|
| desktop / interactive | Human interface; elevation through the launcher |
| preflight | Host prerequisites and diagnostic details |
| list-vms / list-gpus | VM and device inventory; list-gpus includes exact InstancePath |
| create-vm | VMName, Preset, Cpu, RamGB, StorageGB, VhdPath, IsoPath, EnableAutoInstall, InstallImageIndex, UnattendUsername, UnattendPassword, OverwriteVhd, ProfileName |
| set-gpu | VMName, GpuPath, GpuPercent (1-100), optional Shutdown |
| remove-gpu | VMName, optional GpuPath or All, CleanDrivers, SystemDiskPath, Shutdown |
| plan-drivers | VMName, optional GpuPath; reads host sources without mounting the guest |
| install-drivers | VMName, optional GpuPath or All, SkipExisting, SystemDiskPath, Shutdown, DeepDriverDiscovery |
| audit-drivers / recover-drivers | VMName, optional SystemDiskPath and Shutdown |
| delete-vm | VMName, Force, optional DeleteFiles and Shutdown |
| list-profiles | Returns profile settings without passwords |
| save-profile | ProfileName, VMName, Cpu, RamGB, StorageGB, VhdPath, IsoPath, unattended settings, OverwriteVhd, SetDefault |
| default-profile / delete-profile | ProfileName |
| backup-config / restore-config | ConfigurationPath |

VhdPath is the VHD directory, preserving the original parameter meaning.
SystemDiskPath is an attached VHD/AVHDX file path. GpuName remains an accepted
compatibility parameter; exact GpuPath controls selection. Omitting GpuPath for
driver installation/removal selects all assigned adapters, as before. All does
not mean all host GPUs. SkipPreflight remains accepted for compatibility but never
bypasses command input, privilege or offline-disk validation.

The built-in presets are gaming (8 vCPU / 16 GiB / 256 GiB), development
(4 / 8 / 128) and ml-training (12 / 32 / 512); ml is an alias. Custom creation
requires explicit positive CPU, memory and disk values. Preset values can be
overridden with explicit parameters. With ProfileName, saved settings are loaded
and explicit parameters override them.

## Unattended setup and profiles

```powershell
.\HyperV-GPU-Virtualization-Manager.ps1 -Command save-profile -ProfileName Dev -VMName DevVM -Cpu 4 -RamGB 8 -StorageGB 128 -IsoPath C:\ISOs\Windows.iso -SetDefault
.\HyperV-GPU-Virtualization-Manager.ps1 -Command create-vm -ProfileName Dev
.\HyperV-GPU-Virtualization-Manager.ps1 -Command backup-config -ConfigurationPath C:\Backups\gpu-manager.json
.\HyperV-GPU-Virtualization-Manager.ps1 -Command restore-config -ConfigurationPath C:\Backups\gpu-manager.json
```

EnableAutoInstall builds bootable media using installed ADK Oscdimg. An explicitly
selected image index is checked against the source ISO. Locale and time zone
follow the host. A local setup account and first-login autologon are optional.
The answer file configures disk 0, so attach it only to the newly created VM.

If ADK is absent, an answer file is exported to the Desktop and the original ISO
is attached. The result reports the fallback path. An existing answer file is not
overwritten. ISO mounts already owned by the user are left mounted. Working
directories are private and removed on completion or cancellation.

Profile passwords are protected by Windows DPAPI for the current user/machine.
The desktop masks password entry and leaves an existing saved password unchanged
when the field is blank. Headless callers should prefer module invocation over
passing a password on a process command line. Answer files and generated ISOs
necessarily contain setup credentials; protect and remove that media when done.
Configuration restore replaces the current profile set and retains its previous
store as .bak. It does not change any VM.

## Driver synchronization and recovery

Normal discovery resolves the active OEM INF through SetupAPI, adds the device's
service package and driver-declared runtime promotions, and retains relevant AMD
companions. It preserves the package's exact hashed folder name. Native and Wow64
CopyToVm rules can rename files and request overwrite or newer-only replacement.
An Intel compatibility alias handles current media SDK loader filenames.

DeepDriverDiscovery additionally asks Windows for signed-driver file associations.
That provider is slow on some hosts; queries are bounded to 20 seconds and failures
are reported. It is a recovery/diagnostic option rather than a startup requirement.
Unresolved textual INF tokens are advisory, because a package can contain optional
components and directives for other install sections. They are not replaced with
random files from a global filename search.

Deployment stages files on the guest volume, hashes sources and staged copies,
saves rollback data and writes a durable journal before mutation. The manifest is
part of the same transaction. A failed copy or safe cancellation restores the
previous bytes. If the process is interrupted, keep the guest off and run
recover-drivers before booting it. Completed staging payloads are cleaned up;
journals and original-file backups remain for diagnostics and selective cleanup.

Audit checks deployed files against the stored hashes. Install-drivers with
SkipExisting repairs drift and skips matching bytes. After a host driver update,
rerun the plan and synchronize; audit alone compares the guest with its last
deployment rather than proving it matches a newly installed host package.

Selective cleanup only removes verified, tracked files without another GPU owner.
It restores the original file when one existed before deployment. Modified guest
files and unverified legacy paths are preserved. Cleanup conflicts produce failure
with an explanation. GPU adapter removal can already have completed when a later
cleanup fails; inspect assignments and run audit before retrying.

## Storage and deletion

The default VHD directory is C:\ProgramData\Microsoft\Windows\Virtual Hard Disks.
Disk mounts use SID-secured directories under C:\ProgramData\HyperV-Mounts.
The active AVHDX leaf is validated through its parent chain; missing parents and
cycles are rejected. Already-mounted disks are not taken over. Detach failures are
reported; no recursive removal is attempted through an active volume mount point.

OverwriteVhd retains the old disk as a uniquely named .previous-* backup.
VM creation failure restores it and removes the partial VM. Free-space checks
occur before replacement. Deletion requires Force; DeleteFiles separately opts
into deleting all currently attached disk files and this VM's generated ISO.
External installation ISOs and disks used by another VM or its ancestor chain are
protected. Unattached checkpoint ancestors and manually retained backups are not
guessed or recursively purged.

## Troubleshooting

| Symptom | Next step |
|---|---|
| Elevation blocked | Use Run as administrator or an elevated Windows PowerShell 5.1 session. CLI never hides a new UAC process behind JSON. |
| No partitionable device | Check the installed vendor driver and the Hyper-V feature; refresh after host updates. The application does not turn on BIOS settings or reboot the host. |
| Device reported but app fails | Check guest device status, host/guest Windows versions and driver synchronization. Test the specific graphics or compute API in the guest. |
| Black screen or poor capture | Separate GPU rendering from display/capture. VMConnect/RDP may use a different session. Configure your chosen virtual display or streaming solution in the guest. No display driver is silently installed by this app. |
| AMD OpenGL/Vulkan missing modules | Preview the plan and check amdogl/amdvlk package coverage, then synchronize after a driver update. See the linked community issue in PLATFORM_RESEARCH.md. |
| NVIDIA CUDA/NVML/OpenCL missing DLLs | Check CopyToVm promotions in the plan, including loader renames and Wow64 files. |
| Intel media runtime missing | Current loader aliases are package-scoped. Check the host's active INF and the media runtime names in the plan. |
| Windows volume unavailable | Confirm Windows is installed, the VM is off, BitLocker permits access, and the selected disk is correct. Multiple Windows volumes need an explicit SystemDiskPath. |
| Interrupted driver copy | Keep VM off, run recover-drivers, then synchronize and audit. Preserve the journal if recovery reports a missing/damaged backup. |
| Profile fails to decrypt | Use the Windows user/machine that saved it, or edit the profile with a new password. |

Logs are JSONL under %LOCALAPPDATA%\HyperV-Gpu-Manager\Logs, correlated by OperationId.
The desktop can save the last structured result. Diagnostics contain file/device
metadata and error messages, not passwords or answer-file contents. Logs have no
automatic upload or telemetry; review them before sharing.
