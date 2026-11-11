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

Live input history and catch-up, rollback and presentation still need a Linux
implementation. The launcher also needs qualified Linux core packages and
mixed-platform real-game verification before exposing Linux PS1 online play.

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
