# AnyPS5 Desktop Linux embedded emulators

The combined Linux launcher needs both a native emulator host and a
host-aware managed installer. The earlier `681f8a7` installation lacked
these and hid the Emulator settings category. The correction reuses the
published Linux host from `990511f` while preserving the newer combined
launcher, console media, controls, disc switching and optimization features.

## Capabilities and setup

[Embedded core hosts](../lib/core/embedded_core_host.dart) define the supported
Windows/Linux x86-64 ABIs and platform library names. The
[managed installer](../lib/core/managed_retro.dart) chooses the correct
Buildbot platform for PS1 and PS2, checks its trusted index, and validates
Linux ELF64 little-endian x86-64 shared objects with bounded load segments.
Windows PE validation and online core identities retain their original pins.
Linux RPCS3 uses its separately pinned local `.so.zip` package. The running
app must have `ANYPS5_MANAGED_CORE_PACKAGES` pointing to that package directory
for installation or repair; its ZIP and library SHA-256 are both checked.
Games and BIOS files are user-supplied and remain outside the repository.

[AppModel](../lib/ui/app_model.dart) exposes the Emulator settings category
and managed offline setup on Linux x86-64. Its `embeddedOnlineAvailable`
capability remains Windows x86-64. PS1 synchronized sessions, PS2 virtual LAN,
PS3 online readiness/update installation and online recovery cannot be
enabled merely by broadening offline availability. The native host also
rejects their start parameters because those newer methods are not ported.

The laptop uses `/home/brett/.local/share/AnyPS5/Emulators` for managed cores
and `/home/brett/.local/share/AnyPS5/CorePackages` for the verified RPCS3 package.
The ordinary profile and PS5 toolkit stay intact. No Windows DLLs are renamed
or used as Linux shared libraries.

## Native execution and surfaces

The [Linux runner build](../linux/runner/CMakeLists.txt) compiles the host,
EGL/epoxy video and PulseAudio output and links the shared native session.
[Application integration](../linux/runner/my_application.cc) registers the
method channel, shuts down notifications when its view is destroyed, and
keeps the texture owner alive until Flutter's renderer has quiesced.

[The host](../linux/runner/retro_core_host_linux.cc), declared by
[its header](../linux/runner/retro_core_host_linux.h), implements ordinary
start/status/input/pause/options/tuning/disc/stop/release calls. It leases
immutable frames under a mutex for Flutter's pixel-buffer texture. Worker
notifications are marshalled to the GLib platform context and cancelled
before release. Optional `ANYPS5_RETRO_DIAGNOSTICS` logs dimensions once when
Flutter first requests a nonblack texture; it does not log image contents.
That message proves texture delivery, not working controls or network play.

[Platform interfaces](../linux/runner/retro_linux_platform.h) connect the
[EGL/OpenGL renderer](../linux/runner/retro_linux_video.cc) and
[PulseAudio output](../linux/runner/retro_linux_audio.cc) to the session.
[Layer overlay integration](../linux/runner/layer_overlay.cc), exposed through
[its header](../linux/runner/layer_overlay.h), retains the launcher's existing
overlay protocol for Linux desktop sessions.

The [shared native build](../native/retro/CMakeLists.txt) builds the session
and optionally fetches a pinned, hash-verified Vulkan-Headers snapshot.
[Libretro ABI declarations](../native/retro/libretro_abi.h) supply the core
contract. [Dynamic loading](../native/retro/retro_library.cpp), declared by
[its interface](../native/retro/retro_library.h), resolves required exports.
[The session](../native/retro/retro_session.cpp), declared by
[its interface](../native/retro/retro_session.h), owns core lifecycle, worker
execution, options, input, disc state, frame pacing and telemetry. It allows
one active callback owner, releases its core before another session begins,
and keeps its audio/video work on the owning worker. Immutable
[frame conversion](../native/retro/retro_frame.cpp) and
[its interface](../native/retro/retro_frame.h) handle pitches and color formats.
[Vulkan rendering](../native/retro/retro_vulkan_video.cpp), exposed through
[its interface](../native/retro/retro_vulkan_video.h), supplies the PS3 core's
Vulkan frontend and transfers completed frames to the same presentation path.

## Verification

[Linux managed setup tests](../test/core/managed_retro_linux_test.dart)
reproduce Linux filename/ELF acceptance and rejection and verify Linux RPCS3
package integrity. [Menu tests](../test/ui/linux_emulator_setup_test.dart)
open the actual Settings and setup rows for every console and keep unavailable
online workers disabled. Existing Windows package tests explicitly choose
their host so Windows validation still runs when testing on Linux.

[The native test build](../native/retro/test/CMakeLists.txt) uses
[a synthetic core](../native/retro/test/fake_core.cpp) and
[lifecycle/frame/input tests](../native/retro/test/retro_native_test.cpp).
Run it with `cmake -S native/retro/test -B build/retro-native-tests`,
`cmake --build build/retro-native-tests -j3`, and
`ctest --test-dir build/retro-native-tests --output-on-failure`.
The laptop passed this suite and the relevant Dart tests. Live acceptance
must additionally bind the installed executable to its source and confirm
actual game frames. PS2/PS3 gameplay and two-machine online play require
their own verification.
