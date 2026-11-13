# The emulator host client

PS1 games run in a separate program, the emulator host
([anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host)), which
runs SwanStation through libretro. It talks to the launcher over a private
control stream and shares each picture through shared memory. Both sides follow
that repository's `docs/protocol.md`, version 1. This page explains the
launcher's side. It was written from the protocol alone, and has no UI yet:
that is the next step.

## Files

| File | What it does |
| --- | --- |
| [`native/retro_host/anyps5_retro_host.c`](../native/retro_host/anyps5_retro_host.c) | Starts the host with its control stream. Reads and writes whole messages on threads of its own. Watches the host exit. Maps the frame ring after the protocol's memory checks. Built by [`hook/build.dart`](../hook/build.dart). |
| [`lib/core/retro_host/retro_host_native.dart`](../lib/core/retro_host/retro_host_native.dart) | The Dart bindings for that library. |
| [`lib/core/retro_host/strict_json.dart`](../lib/core/retro_host/strict_json.dart) | Reads message bodies as the protocol's "Values" section says. `dart:convert` silently keeps the last of two equal keys and keeps lone surrogates; the protocol makes both errors. |
| [`lib/core/retro_host/retro_host_protocol.dart`](../lib/core/retro_host/retro_host_protocol.dart) | The protocol's values, field checks and the game's `status`. |
| [`lib/core/retro_host/frame_ring.dart`](../lib/core/retro_host/frame_ring.dart) | Checks a ring's header and growth. Pins the newest frame and checks its size. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | One host process, as described in the sections below. |

`retro_host_client.dart` handles:

- `hello` and `welcome`, and the first `volume` call;
- calls and pings in order, with their time limits;
- frames and rumble;
- what to report when the host fails.

## Starting the host

The client adds the protocol's own arguments after the command it is given:

- `--ipc-fd 3 --parent-pid <pid>` on Linux and macOS;
- `--ipc-read <h> --ipc-write <h> --parent-pid <pid>` on Windows.

**Windows.**

- The host gets two anonymous pipes. Their host ends are made inheritable only
  for the moment of `CreateProcessW`, under one lock, and are passed with
  `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
- `dart:io` starts its own processes with a handle list too, so its processes
  never inherit these pipes.
- The host starts suspended. It is assigned to a job object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumed, so it never outlives the
  launcher.

**macOS.** `posix_spawn` with:

- `POSIX_SPAWN_CLOEXEC_DEFAULT`;
- a `dup2` of the socket to descriptor 3;
- an empty signal mask, with `SIGTERM` at its default.

The Dart VM waits for its own process ids through kqueue, so the host's exit
code belongs to this client.

**Linux.** The same `posix_spawn` call as macOS, with two differences:

- **A dedicated start thread.** The host is started from one thread that lives
  as long as the launcher, because the host's `PR_SET_PDEATHSIG` fires when
  the thread that started it exits.
- **The Dart VM can reap the host.** Whenever a `dart:io` process is running,
  the VM reaps children with a plain `wait()` (`runtime/bin/process_linux.cc`),
  and that can take the host. So the client watches the host through a pidfd:
  - its exit is seen even when the VM reaps it first;
  - the exit code is read with `WNOWAIT` while the process still exists;
  - kills go through `pidfd_send_signal`, so they can never reach a later
    process given the same id.

  With glibc 2.39 or later, `pidfd_spawn` makes the pidfd together with the
  process. Where it is missing, or the kernel cannot do it, the host is started
  with `posix_spawn` and its pidfd is opened just after. A pidfd fixes its
  process once opened, so the client then checks in `/proc` that the process is
  its own child (or has already ended), and drops the pidfd otherwise. That
  covers a host that ended at once, was reaped by the VM, and had its id given
  to another process in between. On Linux 5.3, which has `pidfd_open` but not
  `waitid(P_PIDFD)`, the pid is waited for instead.

**The exit code is not always known.** If the VM reaps the host before the
client reads its exit code, the code is lost. That can happen on any Linux
kernel, and on kernels without pidfd it applies to kills too. The client then
reports the code as unknown, and treats an unknown code after `shutdown` as a
clean exit.

**The last reply comes before the exit.** On every system, the exit is
reported only after the reader has passed on everything the host wrote, so a
reply sent just before the host exits is not overtaken. The exception is when
something else still holds the host's end of the stream: the reader then
cannot see the stream end, and the exit is reported after 2 seconds anyway.

## Threads and the UI

The control stream is read and written only by the native threads. Messages
reach Dart through a `NativeCallable.listener`, which never blocks them.
`close()` waits for the host and the threads inside `Isolate.run`. Nothing on
the UI isolate ever waits on the host, as the protocol's "Timeouts" section
requires.

## Time limits and failures

| Limit | Time | When it is missed |
| --- | --- | --- |
| `welcome` after the start | 10 s | The host is killed: `hostHung` |
| A reply to each call | 5 s | The host is killed: `hostHung` |
| A `pong` to each ping (pings every 2 s) | 5 s | The host is killed: `hostHung` |
| A write in progress | 5 s | The host is killed: `hostHung` |
| The game ends after `stopGame()` sends `stop`, counted from the send, also while `start` is still waiting | 10 s | The host is killed: `hostHung` |
| The host exits after `shutdown()` | 15 s | The host is killed: `hostHung` |

`stopGame()` asks for `status` until the game has ended, because the client
has to see the end to enforce the stop limit. So `call('stop')` is refused:
`stop` goes only through `stopGame()`.

If the host breaks a rule, exits unasked or misses a limit while a game is
loaded:

- `status()` gives the short report from the protocol's "Host failure"
  section;
- `pause`, `stop`, `release` and `volume` give null;
- `connectedPorts`, `changeDisc` and `option` give false.

This lasts until `release`. A call still waiting when the connection ends is
answered the same way, and never left waiting.

## Frames

- **Each `frame` message.** The client pins the newest frame and checks it, as
  the protocol's "Checks the launcher makes" section says, and adds an event to
  `frames`.
- **Which frames are drawn.** Only a frame of the current game (its `epoch` is
  the one `start` returned) is drawn and kept as `frame`.
- **How long a frame stays readable.** A ring stays mapped while the frame
  being shown is in it, but the client never maps more than two rings. So
  `frame` stays readable until another frame replaces it, or until a second
  newer ring arrives first; then `frame` becomes null. Read `frame` again after
  each message. A frame that was not drawn can be read only until the next
  message.

## Resets

- **Input.** Losing input focus zeroes both controllers' input. A started game
  gets zero input on both ports.
- **Rumble.** All motors are set to zero:
  - on `start`, `release` and `pause(true)`;
  - when a `status` first shows the game ended;
  - when input focus is lost;
  - on a host failure.

## Tests

[`test/core/retro_host/retro_host_fixtures_test.dart`](../test/core/retro_host/retro_host_fixtures_test.dart)
is the launcher's conformance test.

- **How it works.** It plays every fixture session whose `tests` includes
  `launcher` against the host repository's fake host (`tests/fake_host.py`).
  The client starts the fake host through its real start path, as if it were
  the host.
- **What the test does.** It does what the UI would: the calls, `input`,
  `shutdown` and `stopGame()`, reading frames, and `status()` after a failure.
- **What it checks.** The outcome, and the fake host's report of every message
  the client sent.
- **Extra session.** One session of its own checks that a reply with a wrong
  result still answers its call.

[`test/core/retro_host/strict_json_test.dart`](../test/core/retro_host/strict_json_test.dart)
covers the JSON rules.

To run the fixture test, point `ANYPS5_RETRO_HOST_CHECKOUT` at a checkout of
the host repository. Python 3 must be on `PATH`:

```bash
ANYPS5_RETRO_HOST_CHECKOUT=/path/to/anyps5-retro-host flutter test test/core/retro_host
```

CI runs the test on Linux (in the test shards) and on macOS (in the goldens
job), against the host repository at the commit named in
`.github/workflows/ci.yml`. It also passes on Windows.

## Not yet

- **No UI.** Picking the host's files, showing frames and the player's
  controls are the next step.
- **No signature checks.** The release-time file checks from the protocol's
  "Finding and checking the host" section come with signed distribution.
  Until then, the client runs the command it is given.
- **No host log.** The host's standard error is not captured.
