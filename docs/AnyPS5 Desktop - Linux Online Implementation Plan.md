# AnyPS5 Desktop Linux online implementation plan

Windows and Linux are both required for the emulator online feature. A working
Windows build does not satisfy this requirement. The combined online branch
previously omitted the Linux embedded host already present in review slice #87
and restricted managed emulation to Windows. Linux online implementation is
the immediate priority; no menu-only enablement counts as completion.

## Implementation and acceptance

1. Integrate the Linux embedded foundation from review head
   `990511f1190e31388162be20e2e1010aac84e32b` into the combined branch, preserving
   the Windows optimizer, disc picker, console media and online behavior.
2. Share the input timeline and virtual NIC between platforms. Add native
   session tests for PS2 Ethernet exchange, queue reset and teardown, then
   expose the existing Dart channel contract through the Linux host.
3. Port the complete PS1 worker contract: confirmed input, checkpoint export
   and import, ordinary-game handoff/recovery, rollback, controller seats,
   state fingerprints and clean cancellation. Reuse the protocol, not an
   independently evolving Linux copy.
4. Make package names, immutable core pins, ABI/export validation and managed
   setup platform-aware. Verify native Linux ELF cores. Cross-platform PS1
   compatibility must use an explicitly qualified core-build family; blindly
   equating different DLL/SO hashes or removing compatibility checks is invalid.
5. Integrate PS3 provider setup/status and native online handoff with Linux
   Vulkan. Provider approval and a real two-client level remain required on
   both platforms; neither a fake fixture nor Windows evidence closes Linux.
6. Qualify Linux app setup, in-game invites and recovery, then Windows/Linux
   peer interoperability. Run Windows regression checks. Preserve the existing
   upstream review slices; keep the complete feature set in one integration
   branch/build rather than a reduced Linux edition.

Completion requires actual Linux native and launcher evidence for every online
flow exposed to users, plus mixed-platform compatibility. Native unit tests
and source imports are intermediate gates. Do not advertise unsupported flows.

## Shared native foundation

The [core build](../native/retro/CMakeLists.txt) compiles the common runtime.
[The library loader](../native/retro/retro_library.cpp) and its
[interface](../native/retro/retro_library.h) load host libraries and resolve
the [Libretro ABI](../native/retro/libretro_abi.h). The
[session implementation](../native/retro/retro_session.cpp) and
[session interface](../native/retro/retro_session.h) own the emulation worker,
input, lifecycle, graphics transitions and disc state. Immutable frame
conversion lives in [retro_frame.cpp](../native/retro/retro_frame.cpp) and
[retro_frame.h](../native/retro/retro_frame.h). The
[Vulkan implementation](../native/retro/retro_vulkan_video.cpp) and
[interface](../native/retro/retro_vulkan_video.h) provide the PS3 render path.

The [input timeline](../native/retro/ps1_netplay_timeline.h) and
[virtual NIC](../native/retro/ps2_virtual_lan.h) are shared production code.
The Windows host includes those same headers. The
[native test build](../native/retro/test/CMakeLists.txt) runs the
[core fixture](../native/retro/test/fake_core.cpp),
[lifecycle/frame/disc checks](../native/retro/test/retro_native_test.cpp),
[timeline checks](../native/retro/test/ps1_netplay_timeline_test.cpp) and
[NIC checks](../native/retro/test/ps2_virtual_lan_test.cpp). The latter two
explicitly retain assertions in Release builds and refuse to compile with
`NDEBUG`, so an optimized test cannot silently remove its checks.

The [session LAN checks](../native/retro/test/retro_lan_test.cpp) use a separate
core fixture with the private DEV9 ABI. The test verifies binding before game
load, continuing execution while the launcher menu is open, typed Ethernet
exchange, whole-batch rejection, queue reset, and worker-owned teardown. A core
without the required private export fails before boot; the host never falls
back to a stock core's system networking. Shared fake video/audio and bounded
waits live in [test support](../native/retro/test/retro_test_support.h).

## Linux integration

The [Linux runner build](../linux/runner/CMakeLists.txt) links the common
runtime. [Application registration](../linux/runner/my_application.cc)
creates the [method-channel host](../linux/runner/retro_core_host_linux.cc),
whose [interface](../linux/runner/retro_core_host_linux.h) handles shutdown
before Flutter's view and renderer are disposed. The
[platform interface](../linux/runner/retro_linux_platform.h),
[EGL renderer](../linux/runner/retro_linux_video.cc) and
[PulseAudio output](../linux/runner/retro_linux_audio.cc) supply Linux devices.
[Layer overlay implementation](../linux/runner/layer_overlay.cc) and
[interface](../linux/runner/layer_overlay.h) preserve the reviewed compositor
integration; they are not replaced with a Windows window-control workaround.

Linux retains one texture registration for the view's lifetime. Its start
response therefore includes a separate monotonically increasing session owner;
every subsequent command must match that owner. The
[Dart channel adapter](../lib/ui/retro_core_channel.dart) envelopes Linux calls
while preserving the Windows integer-handle protocol. The
[embedded game](../lib/ui/embedded_retro_game.dart) uses that adapter for input,
status, graphics, discs, LAN exchange and teardown. Delayed traffic from a
closed game cannot reach a later game that reuses the same texture. The
[channel tests](../test/ui/retro_core_channel_test.dart) and
[embedded ownership tests](../test/ui/embedded_retro_ownership_test.dart) cover
both handle formats and consecutive runs with the same texture.

The [Linux channel value adapter](../linux/runner/retro_linux_channel.h) validates
ownership and bounded Ethernet batches using Flutter's actual `FlValue` API.
It explicitly rejects PS1/PS3 online start flags until their complete workers
are ported, avoiding a misleading offline boot. The
[Linux adapter tests](../linux/runner/test/retro_linux_channel_test.cpp) and
[test build](../linux/runner/test/CMakeLists.txt) exercise those values without a
display server and compile the actual host, EGL and PulseAudio implementations.

## Current evidence

The common runtime builds with Ubuntu 22.04 / GCC 11.4.0. Its lifecycle,
timeline, NIC and LAN session suites passed through CTest with assertions enabled. This
uses an actual Linux executable and fixture library, not a Windows test labeled
Linux. It does not yet prove that managed packages, real-game sessions or the
Flutter launcher work. The Linux host has PS2 LAN handlers; Linux PS1 rollback,
handoff/recovery and PS3 provider contracts remain unimplemented. Application
availability is still Windows-only until the entire setup and native path is
qualified together. This is an intermediate implementation checkpoint, not a
Linux online release.

The bounded port checkpoint has four passing shared-native CTest suites on
Ubuntu 22.04 / GCC 11.4 and Windows / MSVC 19.29 Release. The separate Linux
channel value suite passes against Flutter's real Linux library; its build also
compiles the application host, EGL renderer and PulseAudio implementation with
`-Wall -Wextra -Werror`. Fourteen focused Flutter tests pass for both handle
formats, embedded ownership, controls, disc switching and graphics. These are
fixture/regression checks, not a real online game qualification.

The [CI workflow](../.github/workflows/ci.yml) now runs shared-native checks on
Windows and Ubuntu 22.04, plus actual Flutter channel value checks on Linux.
The Linux app job explicitly installs EGL and Epoxy development libraries rather
than assuming a Windows build covers Linux compilation.

The same focused launcher test selection was also executed using the native
Linux Flutter SDK in a separate checkout at `6d5f040`: thirteen tests passed;
the existing Windows-only PS2 LAN profile fixture was skipped. The Linux
channel and worker suites above provide separate PS2 adapter evidence. This
does not replace a real Linux LAN game run.

## Platform-aware managed packages

[EmbeddedCoreHost](../lib/core/embedded_core_host.dart) names the library and
Buildbot path for each target. [Managed setup](../lib/core/managed_retro.dart)
requires an explicit host, so production callers cannot quietly select a DLL on
Linux. The [application model](../lib/ui/app_model.dart),
[folder grouping](../lib/ui/retro_home_folders.dart),
[settings model](../lib/ui/retro_settings_model.dart),
[PS3 readiness page](../lib/ui/ps3_online_readiness_page.dart) and embedded game
pass that selection through. The existing application availability gate stays
closed on Linux until the missing online contracts and package qualification
are completed together.

[ELF inspection](../lib/core/elf_core_library.dart) checks a 64-bit little-endian
x86-64 shared object, rejects PIE executables, and resolves required hooks from
defined visible dynamic function symbols in executable sections. Symbol and string
tables must agree with the runtime `PT_DYNAMIC` entries, and the function's file
bytes must agree with an executable `PT_LOAD` mapping. It uses bounded
file reads rather than loading an untrusted library or matching a name anywhere
in its bytes. Archive/library hashes still establish package provenance. This
inspection does not prove runtime dependency compatibility or gameplay.

Windows default online pins apply only to Windows. Until Linux binaries are
qualified, PS1 online setup fails explicitly; Linux PS2 LAN and PS3 reviewer
imports require their own configured package/library digests. Existing Windows
pins and isolated online storage are preserved. Offline Buildbot requests use
the selected platform's path and retain the existing index/CRC validation.

[ELF and Linux managed-package tests](../test/core/elf_core_library_test.dart)
exercise wrong architectures, truncated tables, missing/hidden/data hooks,
isolated verified `.so` publication and preservation of offline files. Setting
`ANYPS5_TEST_ELF_CORE` to the native LAN fixture additionally validates an actual
compiled Linux shared library. Existing
[managed setup tests](../test/core/managed_retro_test.dart),
[setup-menu tests](../test/ui/retro_settings_setup_test.dart),
[folder tests](../test/ui/retro_home_folders_test.dart),
[PS1 setup tests](../test/ui/ps1_netplay_setup_test.dart),
[media tests](../test/core/online/ps1_netplay_media_test.dart),
[embedded game tests](../test/ui/embedded_retro_game_test.dart),
[controller tests](../test/ui/embedded_ps1_controls_test.dart),
[PS3 boot tests](../test/ui/ps3_online_boot_test.dart) and
[PS3 profile tests](../test/core/ps3_online_profile_test.dart) now follow their
selected synthetic host rather than depending on the machine running the tests.

For this host-aware setup stage, the focused regression selection passed 63 tests
on Windows (18 fixture-dependent skips) and 53 on Ubuntu 22.04 (28 skips).
Independent review then found that section flags alone did not establish a
loadable hook. A new mapping test reproduced that false acceptance; the validator
now requires the matching runtime tables and executable load mapping. Its seven
ELF/package tests passed on Windows and Ubuntu 22.04 after that correction, including inspection
of the compiled Linux private-NIC fixture. This remains structural/package
qualification, not Linux online gameplay acceptance.

Static analysis of `lib` and the new ELF/managed/ownership tests passes with
`dart analyze --fatal-infos`. Independent review approved the bounded stage
after the loader-mapping correction; live Linux online remains unverified.

Hosted CI at `6d5f040` built the full Linux and Windows launchers and passed
their native checks. The overall run is not green: the broad Linux tests found
an outdated PS1 invite-title assertion, and macOS golden images differ. These
must be resolved separately; successful build jobs do not imply passing CI.

The [invite regression](../test/ui/together_test.dart) expected a hardcoded CTR
name although that game was absent from its local library. The
[shared title lookup](../lib/ui/together_model.dart) correctly uses library
metadata and otherwise the canonical title ID. The assertion now expects
`SCUS94426`, preserving the game-independent lookup rather than adding a
title-specific production fallback. The prior assertion was reproduced failing
locally, and the corrected focused test passes. This test-only correction does
not resolve the separate macOS golden differences.

## PS1 checkpoint worker port

The shared [checkpoint component](../native/retro/ps1_checkpoint.h) owns bounded
public exports, private ordinary-game recovery and a single-request mailbox.
The [Windows host](../windows/runner/retro_core_host.cpp) now uses its capture routine too. Public handoff exports use
the core's blank-card exporter; private recovery stays in local memory and is
never included in the public snapshot. Failed private backup cannot park the
game. Failed restore retains recovery for retry. Cancellation during a core
export and stopping the owner discard late results instead of parking a closed
game. Request and source identities are monotonic and do not wrap.

The common session resolves optional private hooks without requiring stock
offline cores to provide them. Requests run only on the emulation worker, at a
frame boundary, including while the Quick Menu has paused ordinary play. A park
freezes execution and configuration/disc changes until resume or cancellation.
Resume refreshes the core's memory-card pointer and flushes stale audio. The
Linux channel exposes ordinary export/park/resume and result/cancel methods,
with the same owned-session guard as other commands and strict source, texture
and 32-byte digest parsing.

The [checkpoint unit test](../native/retro/test/ps1_checkpoint_test.cpp) covers
backup/restore failure, bounded frames, cancellation, concurrent export teardown
and retry. The [native session test](../native/retro/test/retro_ps1_checkpoint_test.cpp)
parks a multi-disc fake PS1 game, checks that it stops stepping, rejects queued
configuration/disc changes, resumes without reopening and verifies its saved
private memory card. Fixture callbacks also detect calls outside the core worker.
These are generic contracts, not CTR-specific behavior.
The same native test also boots a plain PS1 fixture without private exports and
verifies that offline play remains available without advertising handoff.

Independent review identified two transition races. The session now rejects
capture while a disc callback is already executing, not just while its request
is queued. It also rechecks stop after checkpoint service before executing the
next game tick. Both races were reproduced with blocked fake-core callbacks
before their fixes. The six shared native suites pass on Ubuntu 22.04 after
those corrections; the real Flutter Linux channel/host/device compile and value
test also pass. These tests do not use a visible display or a real game's save.
Windows / MSVC 19.29 Release passes the same six suites, including the ordinary
core without private hooks. The Windows Vulkan library builds, and the actual
Windows host passes an MSVC `/Zs` syntax check against the installed Flutter
headers and the pinned Vulkan headers. This is compilation evidence rather
than a new Windows gameplay run.

The Linux host now detaches a parked ordinary session after the public export
has been collected. It retains the private recovery in memory under the source
ticket and joins the old worker before opening another core. Reopening uses
the saved active options and the inserted media when a playlist is in use.
The worker imports the private state before presenting, and the launcher
accepts it only after the restored frame arrives. Failed or abandoned attempts
retain the recovery ticket and leave the on-disk card unchanged.

The native fixture checks failed import, retry, restored position and CPU
selection, ticket ownership, and card persistence after acceptance. The
fixture covers a single-disc reopen. A multi-disc reopen and a real core still
need qualification.

## Confirmed input matches on Linux

The shared session now runs standard and analog PS1 matches on the existing
timeline. The Linux channel exposes match readiness, start and input exchange
with the same payloads as Windows. The worker waits for the remote input for
each frame, applies both seats at the core callback, and publishes the main
RAM fingerprint every 120 confirmed frames.

The Windows and Linux workers share the deterministic options, RAM fingerprint
algorithm and isolated match storage through [the PS1 match header](../native/retro/ps1_match.h).
The match ignores ordinary per-game overrides. On Linux the temporary
directory must enforce owner-only access before the BIOS copy is written.

The [native match fixture](../native/retro/test/retro_ps1_match_test.cpp)
runs each seat through the same 120-frame trace. It checks the missing-input
stall, conflicting-packet rejection, both controller ports and analog axes,
the expected frame 119 RAM fingerprint, and the ordinary save directory.
The Ubuntu run uses memory-backed temporary storage because the Windows
mounted scratch directory does not enforce Unix permissions.

The confirmed worker can export a portable checkpoint and import it before
match start through the existing Flutter request and ticket flow. The worker
checks the imported RAM mapping before reporting success. A pending, failed,
or cancelled import keeps start unavailable until a successful retry. The
fixture checks these transitions and exports the restored core state to
verify that the saved position survived import. The fresh match input
timeline starts at zero after the transfer, as on Windows.

The Linux worker also supports local match staging, a bounded two-port input
history, a frame-boundary hold, and replay from the imported cursor. The
fixture captures the staging host while it runs, resumes it after a hold,
then imports and catches up both guest seats before checking the synchronized
RAM fingerprint. Replay rejects gaps and duplicates and suppresses audio
and video while retaining the recorded controller inputs.

## Linux native rollback

The [native session](../native/retro/retro_session.cpp) checkpoints before
predicting remote input. It restores a same-instance state and replays
corrected input on the core worker. It suppresses replay video, replaces
speculative PCM and releases audio and RAM fingerprints only after
confirmation. The two-frame input buffer is unchanged. The GTK adapter
accepts a boolean `ps1NetplayRollback` start argument. A staged host can
still export and hold before starting the match. Once rollback starts,
the worker rejects live export and hold because the core may be ahead of
the confirmed frame.

The [Linux headless probe](../native/retro/test/ps1_match_probe.cpp) uses
that production worker with in-memory video and audio sinks. Build it with
the shared native suite:

```sh
cmake -S native/retro/test -B build/linux-retro -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux-retro --target ps1_match_probe --parallel 3
```

Build the Linux SwanStation library from `631f0fb31b809e0f889d7c551fe695788e39c1d3`
using GNU 11.4, CMake RelWithDebInfo and Ninja. Apply the
[SPU patch](../tool/patches/swanstation-spu-checkpoint.patch),
[portable checkpoint patch](../tool/patches/swanstation-portable-checkpoint.patch)
and [blank-card patch](../tool/patches/swanstation-blank-card-checkpoint.patch)
in that order. If building from a Windows checkout, use LF patch copies
for `git apply`. The resulting local Linux candidate SHA-256 was
'0fc6f1c2522573b570a4481b1526b0e27e3fd8367c32912b4ba5ceac590ffdd0'.
The Windows cached-interpreter test DLL SHA-256 was
'9e72d4ded35ed5308916e16448edc1c3c39651969c2f6fde68b4e3293eea6347'.

Run the [paced driver](../windows/runner/tests/run_ps1_netplay_probe.py)
from Windows with the native Windows probe and both locally built libraries.
The five WSL arguments must be accessible through the Ubuntu distribution's
drive mounts. Keep Windows TEMP and TMP on the scratch drive. The Ubuntu
probe uses private temporary storage under `/dev/shm`.

```powershell
python -B windows/runner/tests/run_ps1_netplay_probe.py --probe "$winProbe" --core "$winCore" `
  --linux-probe "$linuxProbe" --linux-core "$linuxCore" --disc "$cue" --bios "$bios" `
  --rollback --network-profile 120ms-loss --trace tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json
```

The Windows driver schedules both peers at 60 Hz with 120 ms round-trip
latency, 25 ms jitter, 5% random loss and a ten-tick loss burst. It checks
confirmed main RAM every 120 frames, the placement of both racers from
the finished game`s RAM, and the full confirmed stereo PCM count and hash.

Windows x64 and Ubuntu 22.04 under WSL finished all 13,706 frames in
244.24 seconds using the cached interpreter on both peers. Both reported the
same placements and 114 confirmed RAM fingerprints. The full PCM hashes
matched across 10,104,619 stereo sample pairs. The Linux guest restored
1,268 checkpoints. The two links dropped 753 and 729 packets out of 14,655
each and reordered 1,680 and 1,672 packets, respectively. The Windows probe
reported 11 native work iterations over 16.667 ms, with a 148.311 ms maximum.

The mixed-platform probe exercises native rollback over a simulated
network. Linux uses one core and skips video during catch-up. The
headless probe does not qualify its frame budget or PulseAudio playback
during a burst of confirmed PCM. The Windows spare presentation core and
rollback handoff mode remain separate from this Linux worker.

## Mixed-platform launcher preview

The [media verifier](../lib/core/online/ps1_netplay_media.dart) adds PS1
room version 7. Each platform verifies its own exact executable library
hash before using the same room identity. This identity is derived from
both qualified binary digests and is used in room metadata and the reliable
handshake. Media verification still checks the complete disc layout, tracks
and BIOS. Existing room versions retain their original identities.

The [managed installer](../lib/core/managed_retro.dart) accepts the
Windows rollback ZIP and the Linux x64 rollback ZIP in the configured
reviewer package directory. It verifies the archive, executable library
and Linux ELF rollback export before installing. The Linux archive is
`swanstation-netplay-rollback-linux-x64.zip`, with
`swanstation_libretro.so` at its root and SHA-256
`724fea1bb0f87216d4d3a8cd61a2ad251e208b73069a0c3fb4600712a444c7b3`.
The ZIP used one deflated entry with the default ZIP epoch timestamp.
Archive contents are supplied separately. No emulator binaries or game data
are committed.

After verifying the disc and BIOS, the mixed-platform invite checks for an
installed core and then the configured reviewer package. If the configured
archive is missing or fails verification, the launcher asks the player to
select the ZIP for their platform. It verifies and installs that package before
sending or joining the original room. Dismissing the picker ends the attempt
without changing room membership. A subsequent invite reuses the installed
core. Automatic release downloads still require a distribution source.

For the preview, enable `ANYPS5_PS1_NETPLAY=1` on
both machines and `ANYPS5_PS1_ROLLBACK=1` on a Windows host to select the
mixed-platform room when inviting from the dashboard or Friends. Linux
uses the mixed room automatically. A Windows guest with PS1 netplay enabled
can accept this room. The [embedded game adapter](../lib/ui/embedded_retro_game.dart)
opts both workers into single-core rollback for this room. The mode uses two
digital pads and starts from the disc. Windows-only DualShock, dual-core
presentation and live handoff remain separate modes.

The [media and installer tests](../test/core/online/ps1_netplay_media_test.dart)
cover platform-specific hash rejection, matching wire identity and a fresh
Linux install. The [room setup test](../test/ui/ps1_netplay_setup_test.dart)
uses an optional JSON fixture containing the package directory, a matching
CTR CUE and the user's BIOS. It checks that a wrong disc never opens the
package picker, canceling the picker leaves the invite unjoined, and selecting
the correct ZIP resumes the original admission request. The installer test
also checks that a corrupt configured archive falls back to the picker.
These tests run without loading a visible core. A real AnyTogether
session on separate machines still needs acceptance.

Local source, builds, temporary files and compiler caches remain on D:.
Native builds use `nice -n 19 ionice -c3` and at most three jobs. Tests use fake
video/audio backends and do not control the physical monitor. Flutter 3.47.1
at framework `6655482ec06e547f90abf8ae7590466f4415978d` and GTK/EGL/PulseAudio
development packages were prepared in isolated D: storage. Dependency archives
were extracted without package installation or maintainer scripts; host package
status was verified unchanged. Do not stop the user's existing WSL workloads or
change their display/session configuration.

To run the adapter checks on a normal Linux development machine with Flutter
Linux artifacts already cached:

```sh
cmake -S linux/runner/test -B build/linux-channel -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DFLUTTER_ENGINE_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine/linux-x64"
cmake --build build/linux-channel --parallel 3
ctest --test-dir build/linux-channel --output-on-failure
```

These checks require `gtk+-3.0`, EGL, Epoxy and PulseAudio development libraries
through `pkg-config`. They do not launch the app, an emulator or a visible window.

## Hosted analysis regression

The Linux test job at 7346fbd stopped during Flutter analysis because the
[ordinary WebRTC diagnostic](../tool/ps1_netplay/webrtc_ordinary_probe.dart)
omitted the required embedded-core host argument. The diagnostic loads a
Windows native worker, so it now selects Windows x64 explicitly. Whole-project
analysis under Flutter 3.47.1 passed after the fix. The macOS job in the same
run was canceled by the next push. It produced no golden comparison result.

With analysis fixed, hosted run 42953521356 passed translation validation
and reached the complete Linux test suite. Four optimizer tests combined a
simulated Windows launcher with the real Linux ABI, which hid the managed
optimizer row. The Windows capability is now supplied explicitly in those
fixtures. Production still detects the native host ABI. The restart-tuning
test now creates the mock core filename for the test's host, so it can
exercise the same temporary-settings and Apply contract on Linux.

The macOS job in [run 42953521356](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42953521356/job/130303283377)
passed the recursive watcher and reported 146 pixel mismatches. Its recorded
reference files exactly matched the tracked PNGs. All 146 replacement PNGs
were byte-identical to the corresponding actual images in
[run 42938934662](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42938934662/job/130255797843).
The refresh uses only the filenames reported by the current job. In particular,
the older onboarding screenshot included in the artifact is excluded because
the current onboarding comparison passed. Exact pixel comparison remains
enabled in the workflow.

## Hosted mixed-platform race acceptance

The [hosted race probe](../tool/ps1_netplay/webrtc_live_race.dart) uses
AnyTogether's hosted account, gateway and room APIs and the production
WebRTC match transport. It runs one native rollback core per machine and
plays the pinned digital two-player CTR trace. A Windows Flutter engine
can run without a view through the
[headless probe runner](../windows/runner/tests/ps1_webrtc_loopback.cpp).
The Linux test bundle runs on a private virtual X display. Neither arm
requires access to the user's physical desktop.

Build the probe entry point [webrtc_loopback.dart](../tool/ps1_netplay/webrtc_loopback.dart)
and set `ANYPS5_PS1_WEBRTC_LIVE` to a JSON file with these values in order:
role (`host` or `guest`), friend handle, native probe executable, platform
core, local CUE, local BIOS, pinned race trace, isolated device-session
directory, receipt path and release path. The session file name is
`live-session`. Use dedicated approved AnyTogether device sessions with
two accounts that are already friends. The probe neither reads the normal
launcher account store nor adds friends. Do not share approval codes,
tokens or the session files in logs or commit them.

Start the guest and wait for its hosted gateway readiness message before
starting the host. Each peer waits for the confirmed finish and the last RAM
fingerprint comparison over WebRTC. It then publishes a complete receipt with
the placements, frame count, confirmed RAM hashes and selected route. Compare
both receipts, including all 114 hashes, before creating both release files.
Require both runners to exit successfully after closing the room and workers.
A successful local room fixture is insufficient evidence for this test.

The setup commit `cc758fd` passed all five hosted CI jobs in
[run 42958932127](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42958932127).
The Windows windowless engine and the separate Ubuntu laptop's private
virtual display both reached the expected unsigned-in preflight. Two
isolated device requests expired before approval. No hosted race was
started and the existing launcher sessions were left alone.

The rollback adapter also completed a 240-frame smoke with two real Linux
workers. Both matched the confirmed RAM samples at frames 119 and 239.
This exercises the Dart worker protocol independently of hosted admission.
The full analyzer passed with the hosted probe present.
The focused session suite passed all 23 cases after adding the matching
fingerprint frontier, including a divergence that must never advance it.
### Physical laptop control

The rebuilt offscreen harness at 11e9a35 passed its authentication
preflight in the Windows viewless engine and on the Ubuntu laptop's private
Xvfb display. The Windows kernel blob SHA-256 was
1cc3c90a4f96fb7009809597ac5558261bd03b7f2d420ee82cd7a854ad07476e.
The laptop probe bundle libapp.so SHA-256 was
3312c8d9edb53915d72e8028fe74ccd3cab3d9deb55b2cdfc49cecde3dcb59f4.

The [paced native driver](../windows/runner/tests/run_ps1_netplay_probe.py)
also ran with its Linux worker command pipes forwarded to the physical
laptop over SSH, using the same 120 ms round-trip jitter/loss profile and
the laptop's own CUE, BIOS and pinned Linux core. The full 13,706-frame CTR
race finished in 248.02 seconds. Both workers returned the same placements,
114 confirmed RAM hashes and the hash of 10,104,619 confirmed stereo pairs.
Linux made 1,213 corrections. Windows recorded 14 work iterations over
16.667 ms, with a maximum of 153.003 ms. This verifies the separate
machines' native cores over the simulated profile. Hosted signaling,
WebRTC traversal and the frame budget remain open acceptance gates.

### Windows rollback work timing

The Windows [native worker](../windows/runner/retro_core_host.cpp) records
stage elapsed times only when an input trace is supplied. The
[probe command](../windows/runner/tests/ps1_netplay_runner_probe.cpp) and
paced driver's --work-breakdown option report the worst iteration and count
the largest stage in each overrun. The "other" bucket includes lock and
pacing work outside named stages. Clock time within a stage can include
thread preemption. The spare presentation worker runs outside this report.

On the separate Windows PC and Linux laptop, the instrumented 120 ms
loss-profile race finished all 13,706 frames in 250.47 seconds with matching
placements, 114 RAM hashes and 10,104,619 confirmed stereo pairs. Linux
applied 1,208 rollback corrections. All five Windows primary-worker budget
overruns were dominated by the Libretro step. The worst was 36.534 ms at
frame 8,456, with 36.528 ms inside step and no checkpoint save or restore.
This narrows the next investigation to execution inside retro_run and its
callbacks. It does not distinguish core CPU work, callbacks and preemption.
The 250.587 ms presentation gap and 263.635 ms confirmed PCM gap are separate
measurements. No frame-budget pass is claimed.

The optional --step-breakdown command further records the synchronous video
callback's elapsed time and Windows thread cycles around retro_run. Timing
requires both a paced input trace and an explicit probe opt-in. An unavailable
cycle reading is reported separately. The comparison is with the mean of
measured steps in the same run; cycles are not converted into CPU milliseconds.

In the next full physical Windows–Linux race the game placements, 114 RAM
hashes and 10,104,619 confirmed stereo pairs matched again. The worst Windows
iteration was 148.184 ms at frame 1,566. Its emulator step took 147.138 ms,
including 0.598 ms inside the video callback. The worker accumulated
11,154,077 thread cycles during that step, below its run mean of 15,144,334.
This is consistent with a wait or preemption during the step. The timing
does not identify the wait or measure auxiliary core threads. The pinned
SwanStation source enables an asynchronous CD read worker by default and can
wait for its result. A controlled read-thread comparison or a wait trace is
needed before changing the core or the negotiated match settings.

### CD read-thread comparison

Two scratch Windows probe binaries were compiled from 54bf632 with the same
MSVC settings and pinned DLL. The treatment selected false for
swanstation_CDROM_ReadThread when registering its options. The control kept
the core default. Both queried the effective option before Start. The
physical Linux laptop retained its unchanged pinned worker and core. Both
races used the same two-tick input buffer and 120 ms jitter/loss profile,
with Windows at Idle priority. No launcher settings or package pins changed.

| Windows disc reads | Full race | Iterations over 16.667 ms | Worst work | Worst step | Video time in worst step |
| --- | ---: | ---: | ---: | ---: | ---: |
| Asynchronous | 250.06 s | 8 | 177.432 ms | 176.307 ms | 168.725 ms |
| Synchronous | 248.44 s | 8 | 106.357 ms | 102.751 ms | 0.328 ms |

Both races matched all 114 RAM fingerprints, the placements and the hash
of 10,104,619 confirmed stereo pairs. Linux rolled back 1,196 and 1,226
times, respectively. The asynchronous worst step used 9,734,663 worker
cycles against a mean of 13,609,218. The synchronous worst used 45,456,384
against a mean of 13,262,779. Each arm still missed the frame budget eight
times. One paired run does not isolate a performance improvement, and an
asynchronous disc worker is not necessary for spikes to occur. Keep the
default and investigate the Windows worker's wait or scheduling state around
individual overruns. The control's longest callback uses the headless
registrar, which copies its pixel buffer synchronously; the trace does not
establish the same callback cost with the Flutter display registrar.

### Laptop dashboard build for manual multiplayer

The Linux laptop’s application-menu entry points to the normal release
launcher built from fork commit `cc758fd84b8616336ab104bca5a15faee32e4b50`.
This is the [CI-verified core setup revision](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42958932127).
The on-device release build succeeded. The installed launcher and Dart
bundle matched the build byte for byte, the launcher resolved its shared
libraries, and the desktop entry passed validation. The two superseded
installed bundles were removed. The user profile, managed core packages,
games, BIOS and saves were left in place. The private hosted test bundle
remains separate from the application-menu installation.

The installed application-menu wrapper was also exercised on the laptop
with a private Xvfb display and isolated XDG directories. The launcher
mapped its 1600 × 900 AnyPS5 window, then the smoke closed its own process.
This verifies startup of the installed build. Hosted match acceptance is
still pending two approved AnyTogether sessions.

### Linux PS2 input and LAN smoke

The pinned LRPS2 Linux core with the DEV9 patch loaded TimeSplitters
Future Perfect (SLUS-21148) and produced 2,194 video frames in a private
session. Its DEV9 startup send did not produce an accepted Ethernet frame.
The production adapter requires a frame sourced from the session's
assigned MAC. LAN discovery and a second player are still unverified.

LRPS2 polls the libretro packed joypad mask in ordinary gameplay. The
[shared native session](../native/retro/retro_session.cpp) now advertises
packed input on the capability query, including a null payload, and returns
the full 16-bit mask for player one. The ordinary single-button, analog,
pause and port checks remain in place. The
[native regression](../native/retro/test/retro_native_test.cpp) failed
before the fix and passed afterward along with all seven Linux native
suites. This verifies the callback contract needed to drive the real
game's Network menu. It does not verify a real LAN session.

A subsequent private run verified real D-pad and Cross input from the
title screen through **Network → LAN Game**. A blank scratch memory card
reached the game's missing network-configuration message. With a copy of
the existing DHCP fixture in slot 1, the game accepted the network profile
and the native LAN exchange drained six 342-byte IPv4 Ethernet frames
while the game was connecting. The strict source-MAC filter was active.
The run was single-peer and did not return a DHCP lease. The next gate is
to feed the production LAN bridge's DHCP replies back to the core and
verify that two peers discover and join a lobby. Both private sessions
exited successfully.

The Linux game subsequently reached **Matches Available → Start New
Match**. The private native worker passed frames from its LAN exchange
through the production [DHCP responder](../lib/core/online/retro_lan_dhcp.dart)
and reinjected each reply into the same core. The responder accepted
real 342-byte requests and generated 342-byte replies. This establishes
that the title can configure networking and reach LAN discovery on the
Linux core. No other peer was attached, so lobby visibility, joining,
and gameplay across the room link remain unverified.

A two-worker control ran two isolated TimeSplitters instances with
distinct virtual MAC addresses, separate copies of the scratch memory
card, and production LAN bridge and frame routing between the workers.
Both loaded the profile and reached the main menu. Selecting Network
returned to the main menu on both instances. DEV9 logged the initial
adapter self-test send on each, but neither worker drained a valid
outbound frame and the run exited with status 1. This does not qualify
the local two-player path. Compare the dual-worker input and network
initialization against the successful single-worker run before adding
WebRTC to this test.

Fork CI for `e913ab8` passed Linux analysis and tests, the Linux and Windows
release builds, macOS golden and watcher tests, and the required aggregate
check. See [run 42974101728](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42974101728).
A repeat of the two-worker control timed button holds and release intervals
using the core's emulated step count. Both workers booted, but the control
ended before LAN configuration and produced no accepted frames. The
one-worker DHCP result remains the current verified Linux gameplay evidence.

The automated repeat verified both Linux workers at LAN discovery
using separate scratch cards and distinct MAC and IP assignments. It
used the production LAN bridge, DHCP responder and frame transport,
with the encoded room packets forwarded in process. The host created
a Deathmatch lobby at 1/8 players. The guest's first capture after the
host opened the lobby still showed an empty match list. The bridge
forwarded seven frames from the host and five from the guest by that
capture. Both workers exited with status 0. A guest refresh and join
remain necessary before qualifying the two-player path.

Refreshing the guest list after the host created a match exposed the
lobby. The guest selected it and both cores showed the same Thief lobby
at 2/8 players. Starting from the host advanced both to the same map
loading screen. The production bridge relayed 37 frames from the host
and 26 from the guest before the final captures. Both workers exited
successfully. Gameplay and the end-of-match result still need a longer
run. A prior simultaneous boot attempt had a host native SIGSEGV; the
passing run staggered worker startup by five seconds. The stagger is
a test control and does not establish the crash's root cause.

A longer two-worker run confirmed both players spawned in the same
TimeSplitters map. Independent first-person views and the in-game
radar were visible at 120 and 330 seconds after the first loading
capture. The LAN bridge relayed 5,912 frames from the host and 2,920
from the guest. Both workers exited successfully. The last capture
was still in gameplay, so this run did not establish the match result.
The harness needs to wait for the score screen after the map loads,
rather than using a wall-clock cutoff measured from loading.

The Linux LRPS2 package was also staged in scratch as a single-entry
`pcsx2_libretro.so.zip`. Its 8,756,955 bytes fit the existing 16 MiB
installer cap. Archive SHA-256 is
`27a80722e2d079de8330d32267eb7236c2573cbe3b2458e7166dbf74929fb411`,
and the extracted library matched the tested Linux core SHA-256
`800a2bc3ed710734b36bed6e311100b9d00f87e2634ae3cd5c33c2075135238e`.
The next section covers the launcher integration for this local test package.

### Install the tested Linux PS2 LAN core in the launcher

The PS2 LAN preview uses the same embedded x64 capability check as PS1
netplay. With `ANYPS5_PS2_LAN=1`, Linux x64 shows **Settings → Emulators →
PS2 → Setup → PS2 LAN Network Setup**. The existing setup action uses
`pcsx2_libretro.so.zip` in `ANYPS5_MANAGED_CORE_PACKAGES` when supplied,
or opens the package picker. The [managed installer](../lib/core/managed_retro.dart)
selects distinct Linux and Windows digest pairs and verifies the native
DEV9 export. Linux uses the verified `PS2-LAN` install. Windows still
supports its existing compatible core override.

The [launcher regression](../test/ui/ps2_lan_invite_test.dart) navigates
the Settings route. With `ANYPS5_TEST_PS2_LAN_PACKAGE` set to the actual
Linux package, the test also presses Install and verifies the installed
core is recognized. The [ELF tests](../test/core/elf_core_library_test.dart)
cover installation isolation, rejection of an unverified package, and
validation against the real compiled library. The Linux package is
still a locally staged artifact. Public package delivery and a hosted
PS2 match remain open.

The final focused Linux run passed 16 tests with 19 platform- or
fixture-dependent skips. Flutter analysis of all seven touched Dart files
reported no issues.

### Full Linux PS2 LAN match timer

Two isolated LRPS2 workers discovered, joined and started the same
five-minute TimeSplitters Deathmatch. Both showed the in-game map and
then the Results screen by 405 seconds after the first loading capture.
Both players were idle in the map and finished tied at zero. The bridge
relayed 8,249 frames from the host and 3,128 from the guest through the
445-second capture. Both workers exited with status 0. This qualifies
the local Linux match lifecycle through the game's results screen.
The test used the production frame bridge and routing with an
in-process link, so hosted signaling, mixed Windows/Linux PS2 play
and active controller input during the map remain separate checks.

### Mixed Windows and Linux PS2 LAN control

A native Windows worker loaded the pinned Windows LRPS2 DLL and a
separate WSL Ubuntu worker loaded the Linux SO. Both ran offscreen
with the same disc and independent scratch card copies. The production
DHCP responder and frame transport ran in the test process. The Linux
guest discovered the Windows room after refresh, both showed the same
2/8-player Thief lobby, and both reached the same map loading screen.
The Linux worker then exited with signal 11 before the gameplay
capture. The kernel trace included an instruction fault in generated
code, but the exact failing call site remains unconfirmed. The Windows
worker retained a process-table record with zero threads and handles.
This run verifies cross-platform LAN discovery and admission only.

All five hosted jobs passed on the Linux PS2 setup commit `8db28a3`.
See [run 42984202592](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42984202592).

The initial mixed-platform failure occurred on multiple Linux threads
at the same generated instruction, an indexed byte read
`movzbl (%rbx,%rax),%eax`. The instruction sequence corresponds to the
pinned LRPS2 software renderer's palette-indexed texture read in
`GSDrawScanlineCodeGenerator2::ReadTexelImpl`. A plain debugger run
stopped earlier on an Emotion Engine generated memory read during
boot, so that early debugger stop does not identify the match failure.
The DEV9 RX thread was waiting when inspected. No renderer setting or
core package changed in the follow-up.

A repeat with the debugger passing unrelated signals reached the
same multiplayer map on the Windows host and Linux guest. Both were
still in gameplay at the 90-second capture, with 1,510 host and 759
guest frames forwarded. Both workers exited normally. This verifies
mixed-platform local gameplay on the repeat. The intermittent
software-renderer fault still needs an exact reproduction, and the
repeat did not exercise hosted WebRTC or play through the results.

### PS2 LAN card ownership on Linux

The [profile lease](../lib/core/online/ps2_lan_profile.dart) reserves
the resolved lock path in the launcher before opening the OS lock. POSIX
locks are process-scoped, so the OS lock alone allowed a duplicate open
within the same launcher. The OS lock still protects separate processes.
A contended Linux lock now reaches the same card-in-use handling as
Windows. Failure and close release both forms of ownership, and repeated
close cannot release a newer lease. The [profile tests](../test/core/online/ps2_lan_profile_test.dart)
reproduced the duplicate open before the fix and cover reopen, duplicate
close and failed BIOS refresh. An external POSIX lock also produced the
busy result and allowed reopening after release.

The extended mixed-platform TimeSplitters run joined and started the
match again. The Windows worker then terminated with an access violation
(`0xc0000005`, unknown faulting module in the Windows Application log).
The harness closed the Linux guest, which exited normally. This did not
reproduce the earlier Linux software-renderer fault or complete a
mixed-platform match.

### PS2 LAN invite flow regression coverage on Linux

The [PS2 LAN invite suite](../test/ui/ps2_lan_invite_test.dart) now runs
on Linux x64 and Windows x64 using platform-matched native metadata
fixtures from [test support](../test/support/fixtures.dart). Linux
covers the original invite after core and BIOS setup, expired invites,
cancel and retry, Quick Menu frame exchange, room closure, and rematch.
Those room and native-channel checks use fixtures. The separate Settings
case also installed the actual pinned Linux ZIP during the local run.
The full focused Linux run passed 27 tests without skips, including the
[ELF checks](../test/core/elf_core_library_test.dart) and card lease
tests. Local Windows Flutter testing stopped before executing tests
because its native-asset hook did not discover the installed compiler.

A standalone Windows Dart check also held the card lock from a separate
process, observed the launcher's card-in-use exception, released the
lock, and reopened the profile. This check bypassed Flutter's native
asset build and exercised the production file-lock code directly.

### Laptop preview preflight

The application-menu wrapper installed with the normal laptop build
set the managed package directory but did not enable the PS1 netplay
preview. To expose the hosted CTR flow in the regular launcher,
the wrapper must export `ANYPS5_PS1_NETPLAY=1`. Windows hosts also
need `ANYPS5_PS1_ROLLBACK=1` when creating a mixed-platform room.

The local laptop staging helper checks the exact PS1 and PS2 package
hashes, refuses to replace a mismatching package, and enables the
PS1 and PS2 preview flags in the existing wrapper. In a disposable
Linux home it installed both archives and produced the same wrapper
on a second run. The laptop SSH check timed out, so no remote files
were changed and a hosted CTR session was not started.

After sharing the embedded x64 capability with PS2 LAN, the focused
Linux PS1 setup and media suites passed 17 tests with 18 platform or
fixture skips. The active cases used the pinned SwanStation ZIP, the
local CTR disc and BIOS. Both hosting from Game Settings and resuming
a mixed-platform guest invite after package selection passed against
the simulated room service. This validates the invite and setup path
separately from the pending hosted gameplay test.

### Shared PS3 network policy

The [native policy adapter](../native/retro/ps3_network_policy.h)
carries the same RPCS3 offline and attested-online ABI calls on both
hosts. The [Windows runner](../windows/runner/retro_core_host.cpp)
still requires the v3 export and passes the provider identity and
patch requirements before online boot. The
[shared session](../native/retro/retro_session.cpp) now explicitly
selects offline mode on PS3 cores that expose the v1 policy hook.
Legacy offline cores may omit it. A core rejection aborts launch.

The [native test](../native/retro/test/retro_native_test.cpp) verifies
offline arguments and the complete attestation arguments, and rejects
missing exports, rejected policies, and mismatched patch entries. Linux
PS3 online still needs the native channel parser, provider-status
bridge, and a qualified Linux provider/core profile before it can
expose online launch.

All seven native suites passed on Linux and Windows, and the Windows
runner syntax check passed. The contract test uses fixture callbacks
and did not boot a real RPCS3 core. All five hosted jobs also passed
on the preceding invite-test head in
[run 42992515280](https://github.com/B-Howell/AnyPS5-Desktop/actions/runs/42992515280).
