# Validation matrix

Date: 2026-11-02. Tests must not power off running VMs or modify host security.

| Check | Environment | Result |
|---|---|---|
| Baseline driver copy/discovery fixtures | Windows PowerShell 5.1; temporary files; host APIs mocked | 7 groups passed |
| Baseline VHD chain/cleanup tests | Windows PowerShell 5.1, Pester 3.4 | 18 passed |
| Remote fetch | origin HTTPS; authenticated account | Passed; HEAD equals origin/main |
| Push access | dry run to new codex branch | Accepted; no ref written |
| Host inventory | Windows 11 IoT Enterprise LTSC 26100 x64, non-admin | VMMS running; Intel + NVIDIA enumerated |
| Actual GPU assignment/guest boot/3D/compute | Requires approved isolated off VM and elevation | Not run |
| Other Windows versions/server/SR-IOV/licensed drivers | Unavailable environments | Not run |
| Real driver deployment throughput | Requires isolated guest | Not run |

Performance results will distinguish process startup, module load and fixture file
deployment from actual guest and GPU performance. No compatibility conclusion may
be inferred from a mocked test or successful host enumeration.
