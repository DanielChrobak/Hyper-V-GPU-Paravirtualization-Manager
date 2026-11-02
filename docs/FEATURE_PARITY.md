# Feature parity

Reviewed against the preserved starting baseline (commit 5bfbca4). **Implemented**
describes code coverage; the validation column identifies fixtures, manual checks
and hardware-dependent gaps. No placeholder replaces an existing workflow.

| Existing capability | Replacement | Validation |
|---|---|---|
| Double-click launcher, elevation, argument forwarding, exit status | Root PS1/CMD plus native desktop host | CLI process tests; native host build/manual launch; UAC acceptance not automated |
| Arrow/W/S/numeric console navigation, cancel, capacity display | Retained console helpers and Console.Actions | Source parity review; console prompts not driven end-to-end |
| Headless commands, JSON envelope, reusable API | Commands, Dispatcher and API facade | 5 process/API assertions; syntax/manifest checks |
| Cmdlet, service, architecture and device readiness | Host capabilities and desktop readiness | Actual host preflight; non-admin error path |
| Gaming/development/ml presets and custom settings | Command resolver and creation form | Workflow fixtures; manual preset change |
| Gen2 VM, CPU, static RAM, VHD target/overwrite/free space | New-HgmVirtualMachine | Workflow fixtures, including rollback and previous-VHD preservation |
| Secure Boot, vTPM, checkpoints, stop/start policy | Creation workflow | Calls covered by isolated host stubs; real VM creation pending |
| DVD/boot order, original ISO or no ISO | Creation and installation-media workflow | Source/API parity; real media boot pending |
| WIM/ESD image enumeration/index, locale/time zone | Retained verified helpers plus media platform | XML fixtures; actual mounted-media enumeration pending |
| Unattended account/autologon/ADK bootable ISO | XML builder and private, cancellable ISO workflow | XML escaping/index fixtures; ADK execution/guest install pending |
| No-ADK Desktop answer-file fallback | InstallationMedia | Implemented; manual fallback file creation not run on user's Desktop |
| Profile create/edit/list/details/default/delete/reuse | Existing console + desktop + commands | 20 configuration/XML assertions, including encrypted roundtrip and unreadable-secret preservation |
| Schema-1 profile persistence incl ISO/account settings | Read-compatible schema-2 store | Legacy import and encryption-on-save fixture |
| VM state/RAM/summed multi-disk capacity/batched adapters | API inventory and VM helper | Code review; real VM inventory blocked by elevation |
| GPU/non-display inventory, provider/version/identity | GPU platform and Devices tab | Actual NVIDIA/Intel signed-driver discovery; non-display hardware unavailable |
| Old/new partitionable-GPU enumeration | Capability-based native fallback | Implementation review; legacy OS integration pending |
| Exact and multi-GPU assignment; 1-100% | Set-HgmGpu and exact identities | Allocation/update/rollback fixtures; real adapter assignment pending |
| Per-resource min/max/optimal; MMIO/cache setup | Domain rules and saved original VM settings | Resource/sentinel fixtures; larger custom MMIO and restoration fixtures |
| Stop VM before offline work | Explicit graceful shutdown option | No implicit force-off; simulated off-state path; real shutdown intentionally not run |
| Remove one/all GPU adapters with optional cleanup | Remove-HgmGpu | Adapter/MMIO fixtures; real remove/cleanup pending |
| Driver associations/service/INF discovery | SetupAPI primary; exact class/service metadata; bounded association fallback | Real SetupAPI/service mapping on two GPUs; CIM reference form verified; timeout measured |
| NVIDIA/Intel/AMD driver files | Metadata-based package and runtime pipeline | NVIDIA/Intel host discovery; AMD/vendor isolation fixtures; guest workloads pending |
| AMD GL/Vulkan packages and declared companions | All staged GL/Vulkan paths; exact-version CopyINF companions | Existing companion fixtures retained; actual AMD hardware unavailable |
| HostDriverStore mapping and System32/SysWOW64 files | Driver plan plus CopyToVm rules/renames | Real host promotions, destination fixtures and actual temporary-file copies |
| Repeat synchronization and hash skip/repair | Verified transaction and file audit | Repeat/hash repair and failure fixtures |
| Hidden/nested package files and copy failures | Complete file enumeration and verified copies | Original driver regression groups migrated to new workflow |
| Guest manifests/backups/selective cleanup | Schema-2 per-file ownership, legacy read compatibility | Transaction/shared ownership/original restoration/conflict fixtures |
| Multi-disk Windows probing; secured SID mount paths | Open-HgmWindowsDisk and retained disk backend | Original disk tests; actual guest/multiple Windows-volume integration pending |
| Active AVHDX leaf, parent chain, failure cleanup | ResolveVHDChain/MountVHD/strict unmount | 18 Pester disk tests |
| VM deletion/force/file policy and all attached disks | Remove-HgmVirtualMachine | Workflow fixtures; shared chain checks reviewed; no real deletion performed |
| Delete generated ISO; preserve external ISO | Exact generated-media path policy | Source review; real media deletion not run |
| Old src/*.ps1 dot-source paths | Compatibility shims | Syntax checks and migrated fixture use |
| Logging, actionable errors and success/failure returns | Command envelope and structured diagnostics | Process, injected failure and cancellation fixtures |

## New completed capabilities

| Capability | Validation |
|---|---|
| WPF desktop, background operations, progress, cooperative cancellation | Native host compiled and manually inspected; readiness and preset actions exercised |
| Preview driver plan, audit drift, repair by synchronization | Real source discovery plus file fixtures |
| Staged driver copy, journal, rollback, crash recovery | Injected write failure, mid-apply cancellation and interrupted-process fixtures |
| Shared-file ownership and original guest-file restoration | Real file fixtures with multiple simulated GPU owners |
| SetupAPI active-package selection, driver-declared native/Wow64 promotions | Actual RTX 4090/Intel metadata plus 13 promotion/legacy-assignment assertions |
| Intel media SDK loader aliases | Verified against installed Intel package; scoped mapping fixtures |
| Configuration backup/restore and password encryption | DPAPI and schema migration fixtures |
| Native portable launcher and reproducible ZIP | Build/package checks; unsigned |
| CI workflow | Added; remote execution status is recorded in VALIDATION.md |

## Deliberate behavior corrections

Running VMs are not silently force-powered-off. Existing VHD overwrite retains a
backup and validates free space first. Ambiguous identical GPUs, multiple Windows
system disks and unknown resource capacities require resolution. Original MMIO
is restored only when an original snapshot exists; legacy custom settings are
preserved. Cleanup does not heuristically delete unverified or guest-modified
files. Partial cleanup returns failure even if adapter removal already completed.
These changes preserve the operations while making their effects explicit.

## Remaining validation gaps

Real guest boot, rendering/compute/video workloads, ADK-generated installation,
other Windows versions, AMD and non-display hardware have not been exercised.
Linux/ARM64/HCS support and third-party guest graphics shims were not existing
product capabilities and are not claimed as part of this release.
