# Rebuild record

## Starting point — 2026-11-02

Repository: https://github.com/DanielChrobak/Hyper-V-GPU-Paravirtualization-Manager
Base: `4b436f2`, equal to fetched `origin/main` (0 ahead, 0 behind).
Branch: `codex/rebuild-gpu-manager`. Origin fetch and effective push URL are correct.
Authenticated GitHub CLI account: DanielChrobak. Fetch and `git push --dry-run origin HEAD:refs/heads/codex/rebuild-gpu-manager` succeeded. A dry run is evidence of receive-pack access, not evidence of a published branch.

Pre-existing work: modified .gitignore, README, Core/Gpu/Gpu.Helpers.ps1,
Core/Main.Actions.ps1 and Core/Vhd.Operations.ps1; untracked tests, AGENTS.md and
.codex. Preserve the source/test changes in a separate baseline commit. Leave
machine-local .codex configuration and AGENTS.md outside application commits.

Baseline: existing driver fixture regression script passed all seven groups;
Pester 3.4 disk regression suite passed 18/18 under Windows PowerShell 5.1.
Host: Windows 11 IoT Enterprise LTSC, build 26100, x64; VMMS running;
Intel Graphics 32.0.101.8331 and RTX 4090 32.0.16.1742. Session is not elevated.
No real VM, disk, security or GPU configuration changes are authorized for testing.

## Product investigation

All product code was located via the existing Graphify graph (181 nodes).
There is no .codegraph directory. Graphify wiki is absent. Legacy source is a
PowerShell 5.1 menu, headless dispatcher and API over mutable script state.
Compatibility shims support old dot-source paths. There is no existing desktop
GUI, updater, installer, CI, release build or external runtime dependency.

## Architecture decision

Keep Windows PowerShell 5.1 and the inbox Hyper-V/Storage/DISM interfaces for
native module compatibility and deployment without a compiler/runtime install.
Build a native WPF desktop with background runspaces, alongside the existing
console and command contract. Separate domain validation, host platform access,
transactional driver deployment, orchestration, presentation and diagnostics.
Retain verified locale/unattended setup and profile/menu behavior where suitable;
replace state-changing workflows rather than deleting the existing product first.
Do not represent mocked tests or enumeration as hardware compatibility proof.

## Defects distinct from parity

- Model-only VEN/DEV identity conflates identical physical cards.
- Global recursive INF filename fallback can select the wrong driver version.
- Invented billion-unit capacities misrepresent unknown hardware metadata.
- Existing VHD removed before free-space validation; partial VM creation remains.
- Driver copies have no rollback; stale manifests may lose ownership history.
- Cleanup may delete shared/unowned files, silently succeed or reset custom MMIO.
- Hidden automatic force power-off; nonterminating errors can become success.
- Plaintext profile passwords; command relaunch quoting/exit/JSON issues.
- Cosmetic sleeps delay operations; headless output includes host formatting.

Implementation and validation details are maintained in FEATURE_PARITY.md,
PLATFORM_RESEARCH.md and VALIDATION.md. Update these as work proceeds.

## Product direction clarification

The user's 2026-11-02 clarification makes regular Windows 10/11 GPU-PV with consumer
GPUs the primary product. Server vGPU licensing is not a prerequisite or the design
center. Avoid blanket experimental labels; report specific detection results and
which workloads/hardware were actually exercised. Investigate community source,
history and present host driver metadata as well as platform documentation.

Read the live original GitHub README through the GitHub connector and origin/main.
Research lineage: Nimoa/nta (Cfx May 2020), neggles (gist created August 2020),
James Stringer's Easy-GPU-PV (repo created June 2021), Timminator's Enhanced-GPU-PV,
and newer App Sandbox/ExHyperV/WorkstationVM implementations. The original Easy
repo moved to jamesstringer90 and was archived June 2026. Do not call a particular
person the first inventor without evidence; Nimoa credits nta and an earlier gist.

Host inspection discovered actual CopyToVm rules on both the RTX 4090 and Intel GPU,
including CUDA/NVML/OpenCL/Vulkan renames, Intel media SDK, Level Zero and Wow64
variants. Native CIM associations use embedded reference objects (Dependent.Name),
not just WMI strings. Correct both reference forms. Full association enumeration
took minutes; use exact filtering/time limits and SetupAPI as the primary package
resolver. Get-CimAssociatedInstance fails with Invalid parameter on this host.

## Final local implementation state

Milestones: 5bfbca4 preserves pre-existing work; ae6641e records the baseline;
b945cad implements the replacement. Follow-up checks cover legacy assignment
identity, foreign-user DPAPI profiles, strict unmount errors and staging cleanup.
The final suite passes 161 assertions/tests. Native desktop compilation and the
portable package succeeded; remote CI and actual guest workloads remain unrun.
The feature checklist has no placeholder replacement workflows. Its outstanding
items are explicit integration/hardware validation limits. The release remains
unsigned and no actual push/release publication has been performed.

The initial fixture deployment is slower because of staging/verification/recovery
I/O; the final serial benchmark records 2333.8 ms versus 271.6 ms baseline, while
hash-skipping repeat synchronization is 414.9 ms versus 975.2 ms. Keep this tradeoff
visible. Native host metadata discovery is independent of the slow CIM association
provider and uses actual CopyToVm rules by default.
