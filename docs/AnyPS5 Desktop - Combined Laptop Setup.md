# AnyPS5 Desktop combined laptop setup

## Linux emulator correction

The original laptop installation at `681f8a7` was incomplete: it launched the
combined source but hid Emulator settings and lacked a Linux native emulator
host. The corrective `codex/linux-combined-emulators` branch integrates the
existing Linux PS1/PS2/PS3 host into the newer combined launcher. See
[Linux embedded emulators](<AnyPS5 Desktop - Linux Embedded Emulators.md>) for
the implementation, installation requirements and precise limits.

Linux now has real managed emulator setup, host-appropriate `.so` downloads
and validation, embedded offline play and native graphics/audio support.
Windows online worker support remains a separate capability. Linux synchronized
PS1, PS2 virtual-LAN and PS3 native provider integration remain unimplemented;
the native host rejects online launch arguments rather than treating them as
ordinary offline play. A visible settings menu is not an online readiness claim.

The laptop's actual managed installation succeeded for SwanStation, LRPS2 and
the pinned Linux RPCS3 package, and the transferred PS1 BIOS was imported.
Regression tests first reproduced the missing menu and DLL/ELF mismatch.
After correction, analysis and translations passed, 178 focused Dart tests
passed with 48 Windows/private-fixture skips, and the native fake-core suite
passed. The Linux release build also succeeded. Actual installed-game acceptance
is recorded separately from these tests.

## Original source handoff (superseded for Linux emulators)

The `codex/combined-laptop-20261110` branch preserves the combined Windows
launcher and emulator online preview for a second-machine setup. Its base is
`6a200a714bde405dcbabe8a9a6774d2396769f21`, fetched from the fork's online
branch during publication. This includes the committed PS1 Game Settings
invite, portable-core provisioning, connection recovery and PS2 checkpoint
qualification work added after the older local checkout at `95e359b`.
The original working checkouts are preserved. This is a source handoff, not a
Linux installer or a claim that every online mode is release-ready.

The source contains the PS5 launcher and Together features, optional embedded
PS1/PS2/PS3 play, console media, Auto Optimize, hardware/media-based prelaunch
optimization, native PS1 controls and disc switching, and the PS1 synchronized,
PS2 virtual-LAN and PS3 native co-op invitation flows. It carries Game Settings
friend invites for all three retro platforms. In the online branch, `7f77d29`
restored Auto Optimize and console media, `1430e54` restored prelaunch
optimization and PS1 disc controls, and `e44c4e2` added hardware/media detection.
The older unified branch should not replace these newer implementations.

Read [emulator configuration](<AnyPS5 Desktop - Emulator Configuration.md>)
for offline behavior and [multiplayer design](<AnyPS5 Desktop - Emulator Multiplayer Design.md>)
for the online modes and their separate acceptance requirements.

## Get the exact source on the laptop

Use the full publication commit supplied with this handoff, not a moving
default branch. Clone `https://github.com/B-Howell/AnyPS5-Desktop.git`, fetch
`codex/combined-laptop-20261110`, check out the supplied commit, and create a
local development branch from it. Add that laptop-local folder to Codex.
Codex chat sync does not copy the Windows project directory.

Inspect the laptop's distribution, architecture, GPU, display session and
controller before installing dependencies. Match the Flutter version in
[CI](../.github/workflows/ci.yml), currently 3.47.1; respect
[the locked dependencies](../pubspec.lock). The
[Linux build configuration](../linux/CMakeLists.txt) and
[libmpv bundler](../packaging/linux/bundle-libmpv.sh) are the owning build
sources. Run dependency resolution, analysis, translation validation,
applicable tests, and `flutter build linux --release`. Install the complete
release bundle into a user-owned application directory and create a desktop
entry. Preserve any existing profile and saves. Confirm the actual app opens.

## Original Linux limitation and remaining online work

The original `681f8a7` source gated managed retro to Windows x64 in
[AppModel](../lib/ui/app_model.dart). The
[managed installer](../lib/core/managed_retro.dart) selected and validated
Windows DLLs. Its [Linux runner](../linux/runner/CMakeLists.txt) did not
compile the embedded retro host. The correction above supplies offline Linux
hosting; the newer online protocols still need native integration. A
successful Linux launcher build alone cannot establish that it
can play against the Windows peer. Keep those gates until a real Linux
implementation exists; changing the gate alone does not supply one.

Existing Linux PS1/PS2 embedded work is available in the same fork's
`codex/pr84-embedded-ps12` branch at
`257188475cf37ae2e15a08f3cdae77d60c8a8f16`. Inspect its Linux native host,
audio/video implementation and host-aware installer as a starting point.
It predates the online checkpoint/handoff protocols. Integrating it into
this snapshot requires source reconciliation and focused regression tests;
do not replace the newer combined Dart layer wholesale.

The Windows [native host](../windows/runner/retro_core_host.cpp),
[PS1 runner contract](../lib/ui/ps1_netplay_runner.dart), and
[PS1 netplay plan](<AnyPS5 Desktop - PS1 Netplay Implementation Plan.md>) own
the required execution and identity behavior. Linux needs appropriate shared
libraries, binary validation, real worker/channel support, and a deliberate
cross-platform core identity and determinism policy. Windows DLL digest pins
cannot simply be assigned to Linux shared objects or bypassed. PS2 and PS3
have separate native integration requirements documented in their plans.

Games, BIOS, firmware, saves, account tokens and RPCN credentials remain local
and are not part of this source snapshot. Use player-supplied compatible game
and BIOS copies. Log in through the app. Preserve offline memory cards and
use isolated test state. Report installation, offline play, local paired
tests and actual Windows-to-Linux online gameplay as distinct results.
Only a completed two-machine test can close the laptop online-play gate.

## Original verification for publication

Record the actual command results in the publication handoff. Linux build,
laptop installation and cross-platform online gameplay have not been verified
by publishing this snapshot. Optional local-media tests require private
fixture paths and must be reported as skipped when those are absent.

The source handoff adds documentation only to its publication base. On November
10, dependency resolution preserved the lockfile. Against the final `6a200a7`
source base, `flutter analyze --no-pub` reported no issues, the translation
checker passed, `python -m unittest discover -s tool/ps2_netplay -p test_checkpoint.py -v`
passed all 14 diagnostic unit tests, and `git diff --check` passed. A tracked-text
scan found no matches for private-key,
GitHub-token, AWS-access-key or Google-API-key patterns. A filename scan found
no tracked game images, BIOS files or emulator DLLs/executables. These scans
are bounded checks, not a guarantee that arbitrary sensitive content cannot
exist. Flutter tests could not start because native-assets compiler discovery
did not recognize the installed Visual C++ toolchain. Loading its developer
environment did not resolve that discovery failure. No passing test result or
new Windows executable is claimed for this source snapshot. The Flutter test
attempts stopped during native-assets setup on the earlier `95e359b` candidate;
the newer source has not received a passing Flutter test run here either.
