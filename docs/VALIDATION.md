# Validation matrix

Date: 2026-11-02. Host: Windows 11 IoT Enterprise LTSC 26100 x64. Application
execution tests use Windows PowerShell 5.1 and the inbox .NET Framework compiler.
The agent session is non-elevated. No real VM was stopped, mounted, created,
deleted or reconfigured, and no host security setting was changed.

## Baseline and regression checks

| Check | Environment / method | Result |
|---|---|---|
| Starting driver regression | Temporary files, platform boundaries mocked | 7 groups passed before rewrite |
| Starting VHD suite | Pester 3.4, Windows PowerShell 5.1 | 18 passed before rewrite |
| Domain/driver transactions | Actual fixture files, including injected write failure, safe-boundary cancellation and simulated crash | 44 assertions passed |
| Driver promotions | Native/Wow64 rename, Intel alias, path scoping, replacement policy and legacy assignment fixtures | 13 assertions passed |
| Profiles/unattended XML | Real DPAPI, atomic files, schema migration, unreadable-secret preservation and XML parser | 20 assertions passed |
| Installation-media retries | Actual file publication, existing ISO preservation, changed media, ownership and isolated deletion workflow | 20 assertions passed; ADK building remains untested |
| VM/GPU workflows | Isolated host stubs, actual temporary VHD placeholder files | 20 assertions passed |
| CLI/API contract | Child Windows PowerShell processes, parsed JSON and exit codes | 5 assertions passed |
| Migrated driver discovery/injection | Actual nested/hidden/locked/hash-repaired fixture files; mocked host boundaries | 41 assertions passed across 7 groups |
| VHD chain/mount cleanup | Pester 3.4 with fully mocked disk commands | 18 passed |
| Static syntax/module/XAML | PowerShell AST parser, Test-ModuleManifest, XML parser | Passed |
| Native desktop | .NET Framework x64 C# compiler | Built successfully |
| Native UI smoke test | Actual WPF window through computer-use tools | Dashboard/form inspected; preset change exercised; non-admin inventories handled |
| Portable ZIP | Explicit build allowlist; SHA-256; archive inspection | Built; 53 entries; native EXE and LICENSE present; no profiles/logs/Git/Codex/graph files |
| CI | Windows workflow with pinned Pester and official actions | Added; not run remotely in this session |
| Graphify | GRAPHIFY_BACKEND=none, graphify update . | Refreshed after code changes; generated output remains ignored |

Total: **181 passing assertions/tests** (163 fixture/process assertions plus 18
Pester disk tests). Fixtures are not evidence of actual hardware/guest compatibility. The runner
prints each assertion group and the disk test totals; scripts/Test.ps1 fails on
any failed suite.

## Read-only host integration

| Check | Observation |
|---|---|
| Hyper-V interfaces | Native commands available; VMMS running; access requires elevation |
| Native preflight | Correct host/build/architecture and missing-administrator result; valid JSON with failure exit |
| RTX 4090 | Driver 32.0.16.1742; OEM INF resolved through SetupAPI to exact active package |
| Intel Graphics | Driver 32.0.101.8331; OEM INF resolved through SetupAPI to exact active package |
| NVIDIA package/runtime discovery | 217 package files, 2,851,038,254 package bytes, 20 mapped runtime files; 1.092 seconds in one measured run |
| Intel package/runtime discovery | 164 package files, 2,086,305,507 package bytes, 18 mapped runtime files; 0.218 seconds in the same process after initial native setup |
| CopyToVm rules | Native/Wow64 rules read from each exact device's class key; NVIDIA loader renames confirmed |
| Intel alias correction | Both libmfxhw32/64 rules resolved to installed mfx_loader_dll_hw32/64 binaries; missing-source warnings eliminated |
| CIM reference handling | 938 system associations, 236 NVIDIA references; Dependent is an embedded CIM object |
| Association performance | Full enumeration took minutes; exact filtered query reached 20-second timeout; normal path no longer depends on it |

These reads did not copy host drivers into a guest or establish runtime API
compatibility.

## Performance comparison

Reproducible script: scripts/Measure-Performance.ps1 -BaselineCommit 5bfbca4.
One run per variant; warm local filesystem; 100 files x 16 KiB, no hardware calls.
Load times cover relevant implementation files, not UAC or first-boot UI startup.

| Metric | Preserved baseline | Replacement |
|---|---:|---:|
| Implementation load | 129.1 ms | 148.5 ms |
| First fixture deployment | 271.6 ms | 2,333.8 ms |
| Hash-skipping repeat fixture | 975.2 ms | 414.9 ms |

The initial deployment is slower. Investigation identified repeated path/provider
work and recovery I/O. Native attribute checks reduced the initial replacement
fixture from about 3,346 ms to approximately 2,200-2,400 ms. It still performs staging, SHA-256
verification, backup and durable journaling that the baseline direct copy did not.
That reliability cost is retained and is not described as a speedup. Repeat
synchronization improved in this fixture. Small-file fixture timing is not actual
VHD throughput; real deployment and UI startup performance remain unmeasured.

## Hardware-dependent checks not run

- Real GPU assignment/removal, actual Hyper-V resource postconditions and guest boot.
- DirectX, OpenGL, Vulkan, CUDA/OpenCL, Intel Level Zero and hardware codec workloads.
- Actual driver deployment to a VHD/AVHDX, BitLocker volumes and multi-Windows-disk ambiguity.
- ADK Oscdimg construction and boot/install from generated unattended media.
- Other Windows releases, AMD GPUs, identical dual GPUs and non-display accelerators.
- UAC approval and changing to a different Windows elevation account.

## Repository evidence

Origin fetch/push target:
https://github.com/DanielChrobak/Hyper-V-GPU-Paravirtualization-Manager.git

Starting HEAD equaled fetched origin/main. Work is on codex/rebuild-gpu-manager,
with the user's initial local changes preserved in baseline commit 5bfbca4.
GitHub CLI authentication is available for DanielChrobak. Fetch succeeded and a
non-destructive push dry run to the new codex branch was accepted. No actual push
or published GitHub release is implied by that check.

Machine-local .codex/ and AGENTS.md were already untracked and remain outside
application commits. The existing MIT license is unchanged.
