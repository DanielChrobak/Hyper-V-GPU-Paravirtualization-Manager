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
