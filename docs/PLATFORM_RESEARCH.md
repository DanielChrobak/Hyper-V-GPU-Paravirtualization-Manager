# GPU-PV implementation research

Reviewed 2026-11-02. The product's purpose is sharing existing GPUs with ordinary
Windows 10/11 Hyper-V guests. A Windows Server installation or commercial vGPU
software subscription is not a prerequisite of this workflow. Capability checks
inspect the installed Windows interfaces and driver metadata. Hardware testing
and application testing are recorded separately in VALIDATION.md.

## Community lineage

The earliest concrete guide located in this investigation is
[Nimoa's Cfx guide, May 25, 2020](https://forum.cfx.re/t/running-fivem-in-a-hyper-v-vm-with-full-gpu-performance-for-testing-gpu-partitioning/1281205).
It describes assigning a GPU partition on Windows 10, placing the NVIDIA package
in the guest HostDriverStore and copying nvapi64.dll. It credits **nta** and mentions
an earlier developer gist. This is evidence of the documented method, not proof
that one individual invented it first.

[neggles' guide and packaging script](https://gist.github.com/neggles/e35793da476095beac716c16ffba1d23)
was created August 4, 2020 (GitHub API metadata). It explicitly credits Nimoa and
the Hyper-V community. It automated package discovery using the device service
and signed-driver file associations, including System32/SysWOW64 files. Its source
also records Get-CimAssociatedInstance difficulties and the older/newer Hyper-V
enumeration command names.

[Easy-GPU-PV by James Stringer](https://github.com/jamesstringer90/Easy-GPU-PV)
automated consumer VM creation, unattended Windows setup and driver copying. The
repository was created June 22, 2021, moved from jamesstringerparsec to
jamesstringer90, and was archived June 1, 2026. Its driver helper copies the service
package plus signed-driver-associated files. First-result device matching and
skipping already-present package folders are useful points to improve here.

[Enhanced-GPU-PV by Timminator](https://github.com/timminator/Enhanced-GPU-PV)
extends that work with display/streaming integration and documents practical
Windows version and driver synchronization concerns. Its streaming requirements
are not universal prerequisites for compute-only GPU-PV. This manager does not
require Parsec, Sunshine or a hardware video encoder just to assign an adapter.

## Current implementations examined

### App Sandbox

[App Sandbox](https://github.com/jamesstringer90/appsandbox) is James Stringer's
newer MIT project. Its Windows backend uses HCS/HCN and Virtual Machine Platform,
including a Windows Home route, rather than managing VMMS Hyper-V VMs. Its
[GPU enumeration code](https://github.com/jamesstringer90/appsandbox/blob/main/src/backend_win/gpu_enum.c)
uses SetupAPI to identify active packages. Its
[guest runtime provisioning](https://github.com/jamesstringer90/appsandbox/blob/main/tools/agent/gl_vk_provision.c)
does more than copy vendor binaries: it configures graphics runtimes and deploys
compatibility shims. Linux support has separate kernel/Mesa components.

Applied here: resolve active packages through SetupAPI, preserve exact package
paths and make runtime coverage visible. HCS-only VMs, custom display/audio/guest
agents and graphics shims are distinct features; they are not silently substituted
for the existing VMMS workflows or advertised as implemented by this manager.

### ExHyperV

[ExHyperV](https://github.com/Justsenger/ExHyperV) is a broader Hyper-V management
application. Its [driver mapping document](https://github.com/Justsenger/ExHyperV/blob/main/doc/drivermapping.md)
distinguishes active-package resolution, CopyToVm file promotions, vendor-specific
runtime registrations, version-matched AMD companions and ARM64 mappings. It also
separates file deployment from runtime verification.

Applied here: use the exact device's class key, interpret driver-declared renames
and replacement policy, support Wow64 promotions, and select declared AMD runtime
companions by INF version. Intel's media SDK loader aliases were independently
confirmed in this host's package. ExHyperV is GPL-3.0; no ExHyperV source code or
binaries are incorporated. This manager's implementation of documented platform
interfaces is original and its existing MIT license remains unchanged.

### Other corroboration

[WorkstationVM](https://github.com/Devsh-Graphics-Programming/WorkstationVM/blob/main/enable-gpu-pv.ps1)
handles both embedded CIM references and serialized WMI object paths, uses full
physical device identities, and preserves original VM settings. Those concerns
are also covered by this manager's own implementation and tests.

[Easy-GPU-PV issue 461](https://github.com/jamesstringer90/Easy-GPU-PV/issues/461)
documents missing AMD OpenGL/Vulkan packages on a consumer RX 9070 XT. The baseline
local changes already retained all staged amdogl/amdvlk package paths. Preserve
that behavior: timestamps alone do not establish which exact hashed path an
application will request. Separately declared OpenCL/HIP/Windows companions use
an exact INF DriverVer match to avoid mixing generations.

## Platform interfaces used

| Source | Establishes | Implementation consequence / limits |
|---|---|---|
| [WDDM GPU paravirtualization](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-paravirtualization) | Client and server GPU-PV architecture, guest HostDriverStore mapping, driver registry queries and CopyToVm rules | Primary technical platform reference. Microsoft documentation has inconsistent `drivers` prefixes in some prose; its concrete mapping example and community implementations use System32/HostDriverStore. |
| [SetupGetInfDriverStoreLocationW](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupgetinfdriverstorelocationw) | Resolves a published OEM INF to its exact staged INF location | Avoid filename/timestamp guesses and scanning unrelated packages for a matching DLL. |
| [Signed-driver association class](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/whqlprov/win32-pnpsigneddrivercimdatafile) | Device-to-file associations | Bounded recovery/deep-discovery path. Native CIM references expose Dependent.Name; string parsing alone is insufficient. |
| [Get-VMHostPartitionableGpu](https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vmhostpartitionablegpu) | Host resource metadata and instance paths | Detect command availability and target exact identities. Do not confuse same-model cards. |
| [Set-VMGpuPartitionAdapter](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmgpupartitionadapter) | Per-resource UInt64 allocation controls | Scale reported totals, retain unmetered sentinel values and reject unknown capacity instead of inventing it. |
| [Oscdimg](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options) | Bootable installation-media construction | ADK discovery, quoted arguments, verified output and private staging. |

Server 2025's SR-IOV GPU-P deployment and its vendor licensing requirements describe
a different deployment context. DDA dedicates a device and is also distinct from
this app's consumer GPU-PV sharing. Those requirements are not imposed on regular
Windows GPU-PV users. Windows Home through HCS is a possible separate backend,
not an existing capability of this VMMS-based application.

## Read-only verification on this Windows host

Windows 11 IoT Enterprise LTSC build 26100; native graphics kernel 26100.9711.
The exact NVIDIA RTX 4090 device maps from oem58.inf to its active nv_dispi package;
the Intel Graphics device maps from oem62.inf to its active iigd_dch package.
Both device class keys expose CopyToVm rules for native and Wow64 runtimes.
NVIDIA's 14 rules include renamed CUDA, NVML, video decode, OpenCL and Vulkan
loaders. Intel's rules include Control API, media SDK, OpenCL, Vulkan and a Level
Zero ray-tracing library. Two Intel rules reference historical libmfx filenames;
the actual package ships mfx_loader_dll_hw32/64 instead, matching the documented
community aliases. Resolving these aliases removes the two missing-source warnings.

Get-CimAssociatedInstance returned Invalid parameter. Full association enumeration
returned 938 records, including 236 for NVIDIA, but took minutes. Exact WQL queries
also exceeded a 20-second timeout. Normal discovery therefore uses SetupAPI,
service metadata and driver-declared promotions; bounded association recovery is
retained, with `-DeepDriverDiscovery` for diagnosis. Intel package/runtime discovery
completed in approximately 0.63 seconds in a measured read-only run.

These checks establish actual host file and mapping discovery. Guest DirectX,
OpenGL, Vulkan, CUDA/OpenCL, encoding and decoding require execution in a guest;
they have not been tested in this non-elevated session.
