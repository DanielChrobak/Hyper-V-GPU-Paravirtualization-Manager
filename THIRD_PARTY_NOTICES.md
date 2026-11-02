# License and acknowledgements

Hyper-V GPU Paravirtualization Manager remains under its existing MIT license.
The copyright notice in LICENSE is preserved: Copyright (c) 2025 Daniel Chrobak.

The runtime package contains this repository's source and its compiled native
launcher. It does not bundle Microsoft Windows, PowerShell, .NET Framework,
Windows ADK, vendor GPU drivers, streaming applications or external graphics shims.
Those installed components retain their own licenses. Driver synchronization
uses files already installed on the user's host; generated guest media and copied
driver files are not part of the release archive.

The GPU-PV community's published techniques informed the investigation. Credit to
Nimoa and nta, neggles, James Stringer (Easy-GPU-PV and App Sandbox), Timminator
(Enhanced-GPU-PV), Justsenger and ExHyperV contributors, and the wider Hyper-V
community. See [the research record](docs/PLATFORM_RESEARCH.md) for source links,
dates, technical findings and attribution limits.

No source code or binaries from ExHyperV (GPL-3.0), App Sandbox's guest shims, or
the other researched applications are vendored or linked into this application.
Driver mapping facts verified from installed metadata and documented Windows
interfaces are implemented independently. The project does not change its license.

Pester is a development-only test dependency. The build uses an installed Pester
3/4 module; CI pins Pester 4.10.1 from the PowerShell Gallery. It is not included in
the runtime package. Pester's license is available in its installed module and at
https://github.com/pester/Pester/blob/4.10.1/LICENSE.
