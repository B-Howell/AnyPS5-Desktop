# The emulator host client

PS1 games run in a separate program, the emulator host
([anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host)), which
runs SwanStation through libretro. It talks to the launcher over a private
control stream and shares each picture through shared memory. Both sides follow
that repository's `docs/protocol.md`, version 1. This page explains the
launcher's side. It was written from the protocol alone. The first UI built on
it, the game's picture and the object that runs one game, is described in
[The emulator host in the launcher's UI](RETRO_HOST_UI.md).

## Files

| File | What it does |
| --- | --- |
| [`native/retro_host/anyps5_retro_host.c`](../native/retro_host/anyps5_retro_host.c) | Starts the host with its control stream. Reads and writes whole messages on threads of its own. Watches the host exit. Maps the frame ring after the protocol's memory checks. Built by [`hook/build.dart`](../hook/build.dart). |
| [`lib/core/retro_host/retro_host_native.dart`](../lib/core/retro_host/retro_host_native.dart) | The Dart bindings for that library. |
| [`lib/core/retro_host/strict_json.dart`](../lib/core/retro_host/strict_json.dart) | Reads message bodies as the protocol's "Values" section says. `dart:convert` silently keeps the last of two equal keys and keeps lone surrogates; the protocol makes both errors. |
| [`lib/core/retro_host/retro_host_protocol.dart`](../lib/core/retro_host/retro_host_protocol.dart) | The protocol's values, field checks and the game's `status`, with `RetroCore`, the core a game loaded, and `RetroTiming`, its frame rate and region (see "Core identity and timing"). |
| [`lib/core/retro_host/frame_ring.dart`](../lib/core/retro_host/frame_ring.dart) | Checks a ring's header and growth. Pins the newest frame and checks its size. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | One host process, as described in the sections below. |
| [`lib/core/retro_host/retro_lockstep.dart`](../lib/core/retro_host/retro_lockstep.dart) | The lockstep and rollback messages and the rules of their order (see "Lockstep" and "Rollback"). |
| [`lib/core/retro_host/retro_host_release.dart`](../lib/core/retro_host/retro_host_release.dart) | Checks a signed host release before it is unpacked and before each start, and installs it whole or not at all (see "Finding and checking the host" below). |
| [`lib/core/retro_host/retro_host_store.dart`](../lib/core/retro_host/retro_host_store.dart) | `RetroHostStore`: the host downloaded from the host repository's signed GitHub releases into the launcher's own storage, and its check before each start. |
| [`lib/core/retro_host/retro_host_install.dart`](../lib/core/retro_host/retro_host_install.dart) | `RetroHostInstall`: the host and SwanStation a build runs, the downloaded release's (checked) or, in a debug or test build (`RetroHostBuild`), the one `ANYPS5_RETRO_HOST` names (unchecked). |
| [`lib/core/retro_host/checked_file.dart`](../lib/core/retro_host/checked_file.dart) | A release file held open while it is checked and started: no sharing for writing or deleting on Windows, a close-on-exec descriptor above 3 elsewhere. It hashes what it holds, never the path again. |

`retro_host_client.dart` handles:

- `hello` and `welcome`, and the first `volume` call;
- calls and pings in order, with their time limits;
- frames and rumble;
- lockstep and rollback, for online play (see "Lockstep" and "Rollback");
- what to report when the host fails.

## Starting the host

The client adds the protocol's own arguments after the command it is given:

- `--ipc-fd 3 --parent-pid <pid>` on Linux and macOS;
- `--ipc-read <h> --ipc-write <h> --parent-pid <pid>` on Windows.

**The environment.** The host inherits the launcher's environment, with any
variables the caller adds on top. On Windows names that differ only in case are
one variable, so an added `Path` replaces the inherited `PATH` instead of
sitting beside it, where the host would read whichever came first. When the
caller adds variables on Windows, the native code builds the block for
`CreateProcessW` itself:

- it adds the launcher's hidden entries whose names start with `=`, such as
  the drives' current directories (`=C:`), which `Platform.environment` leaves
  out and `CreateProcessW` does not add to a block it is given;
- it sorts the entries by name without regard to case, as Windows requires.

With `inheritEnvironment: false` the variables the caller gives are the host's
whole environment, and nothing is inherited. The launcher does this on Linux,
where it gives the host its own environment without what its AppImage set
([RETRO_HOST_UI.md](RETRO_HOST_UI.md), "The host's environment"). That
environment cannot be empty: the native code gives the host the launcher's own
environment when it is given no entries, so `start` refuses an empty one with
an `ArgumentError` instead.

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
  process once opened, so the client then checks that the process is the host:
  its descriptor 3 must be the launcher's own socket (`/proc/<pid>/fd/3`).
  This guards against a host that ended at once, was reaped by the VM, and had
  its id given to another process, even another child of the launcher.
  - If the check fails, the client never signals or waits for that id, and takes
    the end of the control stream as the host's exit. That includes systems
    where `/proc` hides a child's descriptors (`ptrace_scope` 2 or 3) and the
    glibc is older than 2.39. A host that has to be ended is then ended by
    closing its stream, which the protocol makes it exit on within 10 seconds.
  - On Linux 5.3, which has `pidfd_open` but not `waitid(P_PIDFD)`, the pidfd
    still shows the exit, but the exit code is unknown and the host is left for
    the VM to reap, since waiting by id could reach a later process.
  - Before 5.3 there is no pidfd, and the client kills and waits by id, as
    programs did before pidfd existed.

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
(In lost mode, where a Linux host's identity could not be checked, the end of
the stream is the exit, so there is no such limit.)

## Finding and checking the host

`RetroHostRelease` does what the protocol's "Finding and checking the host"
section asks of a launcher. A host release is signed like a launcher release:
`SHA256SUMS` and `SHA256SUMS.sig`, checked with
[`release_signing.dart`](../lib/core/release_signing.dart) and the keys in
[`release_keys.dart`](../lib/core/release_keys.dart). Beside them, each system
has `anyps5-retro-host-<version>-<os>-<arch>.zip` and its `.files`, which lists
every file in the zip in `shasum` format. The host repository's
`tools/package_release.py` writes them, and its `docs/host.md` "Releases" says
where the maintainers sign.

- **Where the host lives.** In `RetroHost/host` in the launcher's own data
  folder, beside its toolkits and its ffmpeg (`AppPaths.retroHost`:
  `%LOCALAPPDATA%\AnyPS5\RetroHost` on Windows,
  `~/.local/share/AnyPS5/RetroHost` on Linux). The folder holds the unpacked
  zip, with `SHA256SUMS`, `SHA256SUMS.sig` and this system's `.files` kept
  beside it. protocol.md "Finding and checking the host" (stage5-release
  61ef19b, and netplay-design from 098cc0a) lets a release launcher keep a
  host it downloads in a folder of its own data folder, for this reason: the
  launcher's own directory often cannot take a download, as the AppImage
  mounts it read-only and the Windows installer may put it where the user
  cannot write. The data folder is the launcher's own storage that only the
  user can write, which is what the protocol's Linux rule for SwanStation
  relies on, and the toolkits and ffmpeg already live there. The checks are
  the same wherever the host is kept.
- **Which files are this system's.** Only the names for `windows-x64`,
  `linux-x64` or `macos-arm64`, by exact name. A release with no `.files` for
  this system, or more than one, is refused. The version is read from that
  name, so it is covered by the signature.
- **Minimum version.** `RetroHostRelease.minimumVersion` (1.0.0 now) is built
  in. An older host is refused even when it is signed, so a signed host with a
  known fault cannot be put back. Versions are exactly three numbers.
- **The download** (`RetroHostStore`,
  [`retro_host_store.dart`](../lib/core/retro_host/retro_host_store.dart)).
  Host releases are read from the GitHub releases of
  `AnyTogether/anyps5-retro-host`, tagged `v<version>`. `RetroHostStore.newest`
  takes the newest that is not a draft or a pre-release, is at or above the
  minimum version, and has `SHA256SUMS` and `SHA256SUMS.sig`. `fetch` then
  downloads `SHA256SUMS` and `SHA256SUMS.sig` first and checks the signature
  (`RetroHostRelease.signed`) before anything else is fetched. Only then does it
  download this system's `.files` and zip, each checked against the digest the
  signed sums give it. The other systems' files and the source archive are not
  downloaded. Files go to `RetroHost/.downloads/<tag>`, resuming as the ffmpeg
  and toolkit downloads do. A release with no signature is "not available yet",
  and there is no way to take one unsigned. A release that has no host for
  this system is also "not available". `putInPlace` then installs.
- **On install** (`RetroHostRelease.install`). The signature is checked again
  from the files on disk, then the zip and the `.files` against `SHA256SUMS`,
  then every file in the zip against the `.files`. A file that is missing, an
  extra file, or a symbolic link is refused, and so is any name with `..`,
  `\`, `:` or an empty part. Only then is the zip written out, into
  `host.new`. The old host is moved aside to `host.old` first, then
  `host.new` takes its place, and `host.old` is removed. On Windows the move
  fails while a host started from that folder still holds its files. The
  install then stops with the old host whole ("the host is in use"), never
  half deleted. Stop the host before installing.
- **Before each start** (`checkBeforeStart`, through `RetroHostStore.check`).
  The signature is checked again, then the `.files` against `SHA256SUMS`, then
  the host executable and SwanStation against the `.files`. Each of the two is
  hashed from a `CheckedFile`, on another isolate.
  - On Windows both stay open with read sharing only (no `FILE_SHARE_WRITE`
    or `FILE_SHARE_DELETE`). Nothing can write, rename or delete them, or
    rename another file onto them, until the host has exited. The host loads
    SwanStation again for every game it starts, so a file let go after the
    first game would leave the next game's load unchecked.
  - On Linux the host's descriptor is above 3 and close-on-exec. The host is
    started through it: `RetroHostChecked.program` is `/proc/self/fd/<n>`,
    which the native start passes to `posix_spawn` as the path, while
    `argv[0]` stays the real path. So the file that was checked is the file
    that runs, even if the path is replaced in between. SwanStation is checked
    by path, as the protocol allows on Linux.
  - `RetroHostClient.start(checked: ...)` releases the files once the host
    has exited, whether it was shut down, exited unasked or was killed after
    a time limit or a broken rule, and before `exited` completes; a start that
    fails releases them at once. It refuses a command whose program is not
    the checked executable, and for the whole life of that host it refuses
    any `start` whose `core` is not the release's SwanStation, so a checked
    host never loads another core. A check is good for one start: a second
    start with it, or a start after it was released, is refused, so run
    `checkBeforeStart` again before each start.
  - A kept host that plays another game is checked again before that game
    (`AppModel._recheckKeptRetroHost`): its own check's files are still held,
    but on Linux SwanStation was checked by path and is loaded again for each
    game. The second check is let go at once. A host that fails it is shut
    down, and so is a kept host while a download is installing.
  - A file swapped for something that is not a regular file (a FIFO, say) is
    refused at once; the descriptor is opened without blocking.
- **When a check fails.** `RetroHostReleaseFailure` is thrown and the host is
  not started. The UI says that the emulator needs to be downloaded again
  ([RETRO_HOST_UI.md](RETRO_HOST_UI.md), "In the launcher").
- **Debug and test builds.** `RetroHostInstall.locate`
  ([`retro_host_install.dart`](../lib/core/retro_host/retro_host_install.dart))
  finds the host that `ANYPS5_RETRO_HOST` names, with the SwanStation library
  beside it, only in a debug build or a test build (`RetroHostBuild`, below).
  That host is started without any check, and Settings › Emulators says so
  ("Unchecked PS1 emulator (test build)"). A release, and a profile build,
  ignore the variable and only run the downloaded release's host
  (`RetroHostStore.installed`, a `RetroHostInstall` with `checked` set), and
  only with that release's SwanStation.

## Debug and test builds

A tester's PS1 host is usually one they built themselves, and no signed host
release exists yet. A debug launcher can run it, but a debug Windows build
links Microsoft's debug C++ runtime (`MSVCP140D`, `VCRUNTIME140D`,
`ucrtbased`), which may not be redistributed, so a friend without Visual
Studio cannot start it. A **test build** is the way to hand someone an
unchecked host: it is compiled in release mode, so it ships the normal
release runtime (`windows/CMakeLists.txt` installs it beside the launcher with
`InstallRequiredSystemLibraries`), and it is told at compile time that it may
run the host `ANYPS5_RETRO_HOST` names.

```bash
flutter build windows --release --dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true
flutter build linux --release --dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true
```

Then start it with `ANYPS5_RETRO_HOST` set to the absolute path of the host
executable, with `swanstation_libretro.dll` (or `.so`) beside it, as for a
debug build.

On Windows the build folder's path must stay short (MSBuild's 260-character
limit). Built this way with Flutter 3.47.1 and the VS 2022 Build Tools, the
launcher and every plugin import only the release runtime (`MSVCP140`,
`VCRUNTIME140`, `VCRUNTIME140_1` and the system's UCRT), and
`runner/Release` holds those DLLs. The one exception is the `zlib.dll` that
media_kit's ANGLE archive puts beside the launcher in every release build: it
imports `VCRUNTIME140D` and `ucrtbased`, but nothing in the bundle imports it.

**How it is decided.** `RetroHostBuild.of(debug: kDebugMode)` gives `debug`,
`test` or `release`. `test` comes only from `RetroHostBuild.testDefined`,
which is `const bool.fromEnvironment('ANYPS5_UNCHECKED_RETRO_HOST_BUILD')`:
the Dart compiler folds it into the compiled program, so it is `true` only
when that `--dart-define` was given to `flutter build`. No setting, file,
command-line argument or environment variable of the running launcher can
change it (an environment variable of that name is ignored, which the tests
check). A build without it is a `release`, and `RetroHostInstall.locate`
returns nothing for a `release` whatever the environment holds. The official
builds are made by `.github/workflows` and `packaging/`, and none of them
gives the define: a test fails if any of them, or anything in `tool/`, names
it. So everything a normal release does is unchanged: only the signed,
checked host runs.

**Why this design.** It is the usual way to keep a developer route out of a
shipped program:

- Flutter's own build modes leave no room for it. A debug build has the debug
  runtime above, and Flutter's documentation keeps profile mode for measuring
  performance, with DevTools still able to connect and some service
  extensions on (<https://docs.flutter.dev/testing/build-modes>); release mode
  is the one for deploying. Flutter's `--flavor` is not offered for Windows
  and Linux builds, so `--dart-define` read by `bool.fromEnvironment` is
  Flutter's way to make a release-mode build that differs at compile time.
- Firefox enforces add-on signatures the same way: release and beta builds are
  compiled with `MOZ_REQUIRE_SIGNING`, which makes the
  `xpinstall.signatures.required` preference ignored, and developers who need
  unsigned add-ons use differently built (unbranded, Developer Edition or
  Nightly) builds instead of a switch in the release
  (<https://wiki.mozilla.org/Add-ons/Extension_Signing>).
- RetroArch and Lutris let a tester point at any core or runner build, but
  they check no signatures, so they have no secure path to keep. Emulators
  that publish both kinds, as Dolphin does with its development builds and
  releases, make them separate builds on separate update tracks; that is the
  part that applies here: a test build is a different program, not a setting.

A runtime switch (a setting, a command-line flag, a variable read by a
release) was rejected: anyone, or any program, able to set it for a normal
user's launcher could make that launcher run an unchecked program.

**What a test build is not.** It is never published. It still checks a
downloaded host as a release does; it only also runs the named one, which
comes first, as in a debug build. It is still updated by the launcher's own
update check like any build, and an update replaces it with a normal release.

## Threads and the UI

The control stream is read and written only by the native threads. Messages
reach Dart through a `NativeCallable.listener`, which never blocks them. On
Linux and macOS the writer and the exit watcher wait on one condition variable
(the watcher from the start in lost mode), so queueing a message wakes every
waiter: waking only one could wake the watcher and leave the message unsent.

`close()` waits, inside `Isolate.run`, for the host and the threads; when the
client gave up on the host itself, `close()` waits for that same release. Nothing on
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

"Killed" means signalled through its pidfd, `TerminateProcess` on Windows, or
by id only where the system has no pidfd. In every case the client then closes
the connection, so a host it could not signal sees its stream end and exits.

`stopGame()` asks for `status` until the game has ended, because the client
has to see the end to enforce the stop limit. So `call('stop')` is refused:
`stop` goes only through `stopGame()`. Only a reply to a call sent after
that `stop` can lift the limit: a `status` sent before it, still answered
null or ended for an earlier state, does not. `failureReason` names the limit
that was missed.

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
  being shown is in it, but the client never maps more than two rings: when a
  third arrives, it lets go of the oldest, and the frame shown from it, before
  mapping the new one. So
  `frame` stays readable until another frame replaces it, or until a second
  newer ring arrives first, or until a `frame` message moves the pin without
  pinning a newer frame of this game (the host may then write the old slot);
  in the last two cases `frame` becomes null. Read `frame` again after
  each message. A frame that was not drawn can be read only until the next
  message.

## Which game is loaded

The client counts a game as loaded from `start`'s reply until `release` is
answered for a game a `status` showed ended, or until a `status` returns null,
which means no game is loaded. `release` does nothing while the game still
runs, and its reply is null either way, so a `release` answered before the end
was seen leaves the game loaded. The protocol has the launcher call `release`
for an ended game, so the client relies on a `status` showing the end first:
the host may then answer `release` and exit with no game loaded (a stuck
core), which reports no failed game, while a host that exits after a
`release` of a running game reports the game failed. A host failure reports a
failed game (see above) only while a game is loaded, and zeroes the motors
whenever one is.

## Resets

- **Input.** Losing input focus zeroes both controllers' input. A started game
  gets zero input on both ports.
- **Rumble.** All motors are set to zero:
  - on `start`, `release` and `pause(true)`;
  - when a `status` first shows the game ended;
  - when input focus is lost;
  - when `connectedPorts(1)` takes the controller out of port 2. Rumble for a
    port without a controller (port 2 until `connectedPorts(2)`, and again
    after `connectedPorts(1)`) is not forwarded;
  - when the connection ends with a game loaded, a clean shutdown included;
  - on a host failure.
- **Which rumble is forwarded.** Only rumble of a running game: none while no
  game is loaded, and none once a `status` showed the game ended, until the
  next `start` is answered. The host takes calls in order, so the client
  judges each `rumble` by the state the host will have once it has taken every
  call sent so far: what the replies confirmed, then each call still waiting as
  if it succeeds. A `pause(true)` or `connectedPorts(1)` stops rumble as soon
  as it is sent, a `pause` or `connectedPorts` sent before an earlier `start`
  was answered still counts, and a call the host refuses changes nothing. A
  `start` sent while a game is loaded counts for nothing, since the host
  refuses it with `busy`. When a reply leaves rumble stricter than before (a
  refused resume, say), the motors are zeroed again.
- **Rumble events** come asynchronously, so a listener may call anything on the
  client, `close()` included. Frame events stay synchronous because a frame
  that is not drawn can be read only until the next message.
- **After the end.** Once the connection has ended, a change of input focus is
  ignored: there is no host to send input to, no rumble comes, and after
  `close()` the rumble stream is closed.

## Lockstep

A host that lists `ps1Lockstep` runs a game frame by frame for online play
(protocol.md "Lockstep"; what the launcher does with it is in
[RETRO_HOST_ONLINE.md](RETRO_HOST_ONLINE.md)). The client adds:

- **Methods.** `lockstep(settings)` gives the frame the next step is for, or
  null when the host could not. `leaveLockstep()` is `lockstep` with `false`.
  `saveState(path)` and `loadState(path)` give a `RetroStatePosition`, the
  frame, the file's size and the `micros` the host took, or null.
  `RetroStateFile.read` reads the file's 48-byte header (version 2: the frame
  and the port count) and gives the core's data after it. The host's in-memory
  slots (`{"slot": n}`) are not offered: in rollback the host keeps the states
  it needs itself (protocol.md "Rollback"), and a friend joins from a file.
  `start` takes `lockstep` through
  `RetroHostStartRequest.lockstep`. None of them may be sent to a host that
  does not list the capability: that is a `StateError`, as for `ps1`.
- **Steps.** `step(RetroStep)` sends one frame's input for one or two ports.
  `RetroLockstepTracker` keeps the frame the next step is for: from 0 after a
  `start` with `lockstep` or entering lockstep, the same after a `lockstep`
  that changes settings, and the state's frame after `loadState`. Any other
  step is a `StateError`, so a launcher mistake never reaches the host as a
  protocol error. The step's port count is what rumble follows from then on,
  also after leaving lockstep, as the host keeps it.
- **Syncs.** `syncs` gives each `sync`, checked: the frame from 0 to
  4294967295 and stepped in the current count, after the last one, and each
  hash 16 lowercase hexadecimal digits or `null`. A `sync` from a host without
  the capability, for a game not in lockstep, for a frame not stepped or out
  of order is a protocol error. A `lockstep` result for a frame other than the
  next step (or 0 when entering), or a state of a game not in lockstep, is one
  too.
- **After a failure.** `lockstep` gives null, `leaveLockstep` false and the
  state methods null, as the other calls give their "no game" results.

## Rollback

A host that also lists `ps1Rollback` (`canRollback`) runs a game in lockstep
ahead of the other player's input (protocol.md "Rollback"):

- **Settings.** `RetroLockstepSettings.rollback` is the window, 1 to 8 frames,
  written as `lockstep.rollback.frames`; `start.lockstep` takes it too.
  Sending it to a host without the capability is a `StateError`.
- **Steps and corrections.** A `RetroStep` port may be null, its input not
  known yet. `correct(RetroCorrect)` gives that port's real input later. The
  tracker holds the launcher to rollback's rules, each broken one a
  `StateError`: a null port only in rollback; a port's input known in frame
  order, so neither a step nor a correction gives a port's input while an
  earlier frame's is unknown; a correction only for a port its step left null;
  and no step beyond the window, for a frame the window back of which is not
  confirmed. `RetroLockstepTracker.confirmed` is the newest frame every port's
  input is known for, with every frame before it.
- **What the host sends.** A `sync` in rollback must be for a confirmed frame;
  one that is not is a protocol error. `rollbacks` gives each `rollback`
  message as a `RetroRollback` (the first frame run again, how many, and the
  microseconds of the whole and of the load), for a game in rollback and for
  frames stepped; a host without the capability that sends one, or one for
  frames not stepped, breaks the protocol. A `saveState` result while a frame
  is not confirmed, or a `lockstep` result that turned rollback on or off or
  changed its window then, is one too, as the host refuses both. A
  `loadState` forgets the frames not confirmed.

## Core identity and timing

A host that lists `coreIdentity` (`canIdentifyCore`) names the core each game
loaded in `status.core` (protocol.md "status"):

- **Reading it.** `RetroStatus.core` is a `RetroCore`, the core's
  `library_name` and `library_version`, or null until the core is loaded and
  when it could not be. From a host that lists the capability, a `status`
  without `core`, or with a name or version that is not printable ASCII of at
  most 256 bytes, is a protocol error. Another host's `core` is not read.
- **What it is for.** Two players' launchers compare it before a match
  ([RETRO_HOST_ONLINE.md](RETRO_HOST_ONLINE.md), "The cores").
  `RetroCore.identified` says whether the version is a core build identity,
  `anyps5-1-` and 64 lowercase hexadecimal digits, which the host's own
  SwanStation builds report; `playsWith` is protocol.md's rule: both strings
  equal and the version identified. The client does not judge the value
  itself.
- **Timing.** A host that lists `gameTiming` (`canReportTiming`) gives
  `status.timing`, read as `RetroStatus.timing`: `fps`, above 1 and below
  1000, the rate the host paces the game to, and `region` (`ntsc`, `pal` or
  `""`); null until the core has loaded the game. A `status` without it, or
  with a value out of those, is a protocol error from such a host; another
  host's is not read. A match's frame clock follows `fps` in rollback
  ([RETRO_HOST_ONLINE.md](RETRO_HOST_ONLINE.md), "Rollback").

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
- **Extra sessions.** Sessions of its own check that a reply with a wrong
  result still answers its call, that a frame of another game takes away the
  frame shown, that a refused call keeps the calls in order, that a pause with
  no game does not silence the next game's rumble, and that the motors are
  zeroed when a rumble listener closes the client, when `connectedPorts(1)`
  takes away port 2, and on a clean shutdown.

[`test/core/retro_host/retro_host_real_test.dart`](../test/core/retro_host/retro_host_real_test.dart)
runs the client against the real host and the real SwanStation core, as the
host repository's `tests/real_core.py` does:

- **What it plays.** The free OpenBIOS boots a small PS-EXE that the host
  repository's `tests/make_test_disc.py` puts on a disc image.
- **What it checks.** `start` with the BIOS options, `status` until `ready`, at
  least 100 drawn frames in 10 seconds, two pinned frames that are not black
  and differ, then `stopGame()`, `release` and `shutdown`, ending `clean` with
  exit code 0.
- **How to run it.** Set `ANYPS5_RETRO_HOST_REAL` to a JSON file naming
  `host`, `core`, `bios`, `program` and `discBuilder` (the path of
  `make_test_disc.py`), with an optional `environment` for the host, such as
  a `PATH` that has the host's runtime libraries. Python 3 must be on `PATH`.
  Add `packer` (the host repository's `tools/package_release.py`) and
  `coreLicence` (SwanStation's `LICENSE`) to start the host from a checked
  release. Without the variable the test is skipped, so CI skips it.

[`test/core/retro_host/retro_host_release_test.dart`](../test/core/retro_host/retro_host_release_test.dart)
covers the release checks. It replays a recorded release in
[`test/fixtures/retro_host_release`](../test/fixtures/retro_host_release), as
the host repository publishes one: each system's zip and `.files` and a source
archive, packed from small stand-in files by that repository's
`tools/package_release.py` (stage5-release 15c4f50), `SHA256SUMS` from its
`--sums`, and `SHA256SUMS.sig` written by AnyPS5-ARM's `tools/release/sign.sh`
with a throwaway key kept beside them (`test-release-signing.key`, its public
half in `test-release-signing.pub`). No launcher trusts that key; it is not a
secret. [`retro_host_release_fixture.dart`](../test/support/retro_host_release_fixture.dart)
reads the fixture for the tests. They check:

- that the recorded `SHA256SUMS.sig` is exactly the fixture key's signature
  (Ed25519 signatures are deterministic, so the launcher's own signing of the
  same sums gives the same line), and that the recorded release installs and
  checks out unchanged for all three systems;
- that a signed download unpacks and checks out before a start;
- that each of these is refused: an untrusted key, a changed zip or `.files`,
  an extra or missing file in the zip, a host below the minimum version, a
  changed, missing or replaced host or core, and unsafe names;
- that on Windows the held files cannot be written, renamed or deleted;
- that on Linux a real program started from a checked release runs from the
  checked descriptor even after its path was replaced, and that the
  descriptor does not reach it;
- that installing over a host replaces it whole, and that on Windows a host
  whose files are held is left whole and is replaced once they are let go.

Tests that change the release sign the copy again with keys of their own,
to tell the trusted key from a stranger's.

To make the fixture again, pack each system's stand-in files with
`package_release.py --version 1.0.0 --system <system> --host <stand-in>
--core <stand-in> --core-licence <stand-in> --core-notices <folder>
--notice swanstation-vulkan-headers-Apache-2.0.txt=<stand-in> --host-commit
<sha> --swanstation-commit <sha> --out <folder>`, add a stand-in source archive,
write `SHA256SUMS` with `--sums`, then sign it with `sign.sh -k <key> -o
<folder> <zips> <.files> <source archive>`, after adding the key's public line
to a copy of `tools/release/release-signing.pub`. Keep the key file beside the
release.

[`test/core/retro_host/retro_host_store_test.dart`](../test/core/retro_host/retro_host_store_test.dart)
serves the recorded release from a fake GitHub
([`fake_github.dart`](../test/support/fake_github.dart)) and checks the
download. It checks that only this system's `.files` and zip are fetched after
the signed sums, and that the result installs and checks before a start. It
checks that the newest signed release at or above the minimum is taken, never
a pre-release. A release without a signature downloads nothing, and one signed
by an untrusted key stops after the sums. A changed zip is refused before it is
unpacked, a release with no host for this system is not available, and a
stopped download resumes.

With `packer` and `coreLicence` in its JSON, the real-host test packs the host
and SwanStation as a release, signs it, installs it, checks it and starts it
from the checked files. It also checks that both files stay held while the
game loads and after it was stopped and released, ready for the next game's
core load (on Windows, that nothing can write them), and that they are
released once the host has exited.

The fixture test also starts the fake host as a checked host, with the
session's core as the checked file. It checks that the file stays held after
every reply through a game that gets ready, ends and is released, and a second
game, then is let go once the host exits; on Windows it tries to write,
replace, rename and delete the core after each reply. Two more sessions check
the same when the host exits unasked and when it is killed for a broken rule.

[`test/core/retro_host/retro_lockstep_test.dart`](../test/core/retro_host/retro_lockstep_test.dart)
replays lockstep messages recorded from real hosts,
[`test/core/retro_host/retro_rollback_test.dart`](../test/core/retro_host/retro_rollback_test.dart)
replays rollback messages recorded from real hosts and checks the tracker's
rules, and
[`test/core/retro_host/retro_lockstep_real_test.dart`](../test/core/retro_host/retro_lockstep_real_test.dart)
runs the client in lockstep and in rollback with two real hosts, with the same
`ANYPS5_RETRO_HOST_REAL` file ([RETRO_HOST_ONLINE.md](RETRO_HOST_ONLINE.md),
"Tests").

[`test/core/retro_host/retro_host_environment_test.dart`](../test/core/retro_host/retro_host_environment_test.dart)
covers how the host's environment is put together, and
[`test/core/retro_host/retro_host_close_test.dart`](../test/core/retro_host/retro_host_close_test.dart)
checks that a focus change after `close()` is ignored.

[`test/core/retro_host/strict_json_test.dart`](../test/core/retro_host/strict_json_test.dart)
covers the JSON rules, and
[`test/core/retro_host/frame_ring_test.dart`](../test/core/retro_host/frame_ring_test.dart)
covers pinning, including three tries that all miss.

To run the fixture test, point `ANYPS5_RETRO_HOST_CHECKOUT` at a checkout of
the host repository. Python 3 must be on `PATH`:

```bash
ANYPS5_RETRO_HOST_CHECKOUT=/path/to/anyps5-retro-host flutter test test/core/retro_host
```

CI runs the test on Linux (in the test shards) and on macOS (in the goldens
job), against the host repository at the commit named in
`.github/workflows/ci.yml`. It also passes on Windows.

## Not yet

- **protocol.md names debug builds only.** The host repository's protocol.md
  "Finding and checking the host" says "Debug builds of the launcher MAY run
  the host named by the environment variable `ANYPS5_RETRO_HOST`" and
  "Release builds ignore that variable". A test build ("Debug and test builds"
  above) is compiled in release mode but is no release and is never
  published; the protocol's text should say "debug or test builds, never a
  published release" before a host release ships.

- **No signed release yet.** The download reads the host repository's
  GitHub releases, and none is published there yet: until the maintainers
  sign and publish one (that repository's `docs/host.md` "Releases"), a
  release build says no signed PS1 emulator has been published yet, and has no
  host to run. The whole path was tested with a real release that the host
  repository's release workflow packed, signed with the test key
  ([RETRO_HOST_UI.md](RETRO_HOST_UI.md), "Against the real host").
- **No update check on its own.** A newer host is looked for only when the
  player selects the emulator's row in Settings › Emulators, as ffmpeg's
  download works. Nothing asks GitHub unprompted.
- **No host log.** The host's standard error is not captured.
