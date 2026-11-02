# Feature parity

Status starts as **baseline inspected**. A fixture is not hardware validation.

| Existing capability | Baseline location / behavior | Replacement / validation |
|---|---|---|
| Double-click launcher, elevation, argument forwarding, exit code | root PS1/CMD | Pending |
| Arrow/W/S/numeric console menus, cancel, tables, capacity units | Config.Helpers, Interactive.Menu | Pending |
| Headless commands, JSON envelope, API results | Command.Dispatcher, Manager.Api | Pending |
| Startup cmdlet/service/edition/device checks | API preflight | Pending |
| Built-in gaming/development/ml and custom settings | Config.Helpers, NewVM | Pending |
| Gen2 VM, CPU/static RAM, VHD target/overwrite/free space | NewVM | Pending |
| Secure Boot, local vTPM, checkpoints, stop/start policy | NewVM | Pending |
| DVD and boot order, original ISO, no ISO | NewVM | Pending |
| WIM/ESD image enumeration/index, locale/time zone | AutoInstallIso | Pending |
| Unattended XML/local admin/autologon/ADK bootable ISO | AutoInstallIso | Pending |
| No-ADK Desktop answer-file fallback | NewAutoISO | Pending |
| Profile create/edit/list/details/default/delete/reuse | Config.Helpers, Interactive.Menu | Pending |
| Schema-1 profiles incl ISO/account/overwrite settings | project JSON store | Pending |
| VM state, RAM, summed multi-disk capacity, batched adapters | API, ShowVMs, SelectVM | Pending |
| GPU display/non-display inventory, provider/version/IDs | Gpu.Helpers/API | Pending |
| Host partition cmdlet version fallback | GetPartitionableGPUs | Pending |
| Specific and multiple GPU assignments, resource percentages | SetGPU | Pending |
| Per-resource min/max/optimal and MMIO/cache setup | SetGPU | Pending |
| Stop VM before offline operations | EnsureOff/StopVM | Pending: explicit graceful shutdown; no implicit force-off |
| Select/remove one/all adapters and optional cleanup | RemoveGPU | Pending |
| Driver associations, service binary, INF fallback | GetDrivers | Pending |
| NVIDIA/Intel/AMD and all staged AMD GL/Vulkan companions | GetDrivers | Preserve regular Windows GPU-PV; host metadata and fixtures distinguish validation coverage |
| HostDriverStore mapping + System32/SysWOW64 files | InstallDrivers | Pending |
| Repeat deployment, hash skip/repair, hidden/nested files | InstallDrivers + local regression | Pending |
| Guest manifest, backup, selective cleanup, unresolved refs | Config/RemoveGPU | Pending |
| Multi-disk Windows volume search, secured SID mount directory | Vhd.Operations | Pending |
| Active AVHDX leaf, parent validation, cleanup on failure | local disk changes | Pending |
| VM delete/force/file preservation, all attached VHDs | DeleteVM | Pending |
| Delete only generated ISO, preserve external ISO | DeleteVM | Pending |
| Old src/*.ps1 compatibility dot-source paths | compatibility shims | Pending |
| Logging, actionable failures, return success/cancel/failure | helpers/actions/API | Pending |

New capabilities must also be completed and validated: desktop background work,
safe cancellation, structured diagnostics, driver plan and drift audit, staged
rollback/recovery, encrypted profile persistence and configuration backup/restore.
