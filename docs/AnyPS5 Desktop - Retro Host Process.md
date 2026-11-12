# AnyPS5 Desktop retro host process

Embedded PS1, PS2 and PS3 games run in a separate program,
[anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host) (GPL-3.0).
This launcher (GPL-2.0-only) never loads a libretro core and contains no
core-loading code. The maintainers asked for this in
[AnyTogether/AnyPS5-Desktop#86](https://github.com/AnyTogether/AnyPS5-Desktop/pull/86):
GPL-3.0 cores must not load into the launcher, a crashing or hung core must
not take the launcher down, and people who never play an emulated game must
not pay for it. The contract between the two programs is the host's
[protocol document](https://github.com/B-Howell/anyps5-retro-host/blob/main/docs/protocol.md).

## What the launcher keeps

The [protocol client](../native/retro_ipc/retro_host_proxy.cpp) and its
[interface](../native/retro_ipc/retro_host_proxy.h) are the launcher end of the
`anyps5/retro_core` method channel. The Dart code calls the same methods with
the same arguments as before; the client forwards each call to the host and
returns its reply in order, so the UI is unchanged. It starts the host on the
first call, which means a launcher that never plays an emulated game never
starts it. It finds the host beside the launcher executable, or at
`ANYPS5_RETRO_HOST` for development.

- [Values](../native/retro_ipc/retro_ipc_value.h) have the alternatives of
  Flutter's standard codec, and the [JSON codec](../native/retro_ipc/retro_ipc_json.cpp)
  ([interface](../native/retro_ipc/retro_ipc_json.h)) writes them losslessly, so
  an `int`, a `double` and a `Uint8List` reach the host as the same types.
- The [transport](../native/retro_ipc/retro_ipc_transport.cpp)
  ([interface](../native/retro_ipc/retro_ipc_transport.h)) starts the host and
  frames messages over anonymous pipes on Windows (the host takes its pipe
  ends with `DuplicateHandle`, so nothing is inheritable) and a Unix socket on
  Linux.
- The [frame ring](../native/retro_ipc/retro_ipc_frames.cpp)
  ([interface](../native/retro_ipc/retro_ipc_frames.h)) is shared memory with
  three RGBA slots. The host fills a slot neither side is using; the
  launcher's raster thread pins the newest one while Flutter copies it. This is
  the same picture the in-process pixel-buffer texture showed, because every
  renderer already read its frame back to RGBA.
- The [build](../native/retro_ipc/CMakeLists.txt) is one static library that
  both runners link.

The Windows [channel adapter](../windows/runner/retro_core_host.cpp)
([interface](../windows/runner/retro_core_host.h)) converts Flutter values,
registers one pixel-buffer texture per game as before, and runs replies on the
platform thread through a message-only window. The Linux
[channel adapter](../linux/runner/retro_core_host_linux.cc)
([interface](../linux/runner/retro_core_host_linux.h)) keeps one texture for
the view, as before, draws black until a frame exists, and runs replies on the
GTK main context. The [Windows runner build](../windows/runner/CMakeLists.txt)
no longer links D3D11, the D3D compiler, winmm or the Vulkan headers, and no
longer sets an 8 MB stack; the [Linux runner build](../linux/runner/CMakeLists.txt)
no longer links EGL, epoxy or PulseAudio. A build ships the host when
`ANYPS5_RETRO_HOST_DIR` points at a host release
([Windows install rules](../windows/CMakeLists.txt),
[Linux install rules](../linux/CMakeLists.txt)); the host's licence is
installed beside it.

## The process id

An embedded game now reports the host's pid instead of 0
([running game](../lib/core/game_process.dart),
[embedded session](../lib/ui/embedded_retro_game.dart)), so per-process audio
capture for the replay buffer and Share finds the game's sound. The game is
still drawn in the launcher's window, so window lookups by that pid find no
window, as they found none for pid 0.

## When the host fails

If the host exits, or a call has had no reply for 30 seconds, or a game asked
to stop has not ended after 20 seconds, the client kills the host and answers
for the lost game as an emulator that ended with an error: `status` reports
`ended` with "The emulator closed unexpectedly." or "The emulator stopped
responding and was closed.", and the UI returns to the library through its
usual path. The next game starts a new host. On exit the launcher asks the host
to close its game (memory cards are written as before) and waits up to 15
seconds.

## Verification

The host repository's protocol tests run the real host against fixture cores
on Windows and Linux: frames reach the texture, input reaches the right port,
a PS1 checkpoint exported by one game imports into the next, a crash is
reported and the next game gets a new host, and a hung core or host is killed
after its timeout. Its `ps1_host_probe` drives host processes with the line
commands of the earlier in-process probes, so the
[mixed rollback harness](https://github.com/B-Howell/anyps5-retro-host/blob/main/tests/run_ps1_netplay_probe.py)
runs a Windows host against a Linux host. On 2026-11-11 the full CTR Coco Park
trace (13,706 frames, 120 ms with loss) finished with 114 matching RAM
fingerprints, identical confirmed PCM (10,104,619 stereo pairs) and the same
race result as the in-process baseline. Crash Team Racing also booted through
the host to its title text on Windows (D3D11) and headless Linux (software).
