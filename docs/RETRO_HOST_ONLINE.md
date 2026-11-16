# PS1 online play through the emulator host

A PS1 game that plays in the emulator host
([The emulator host in the launcher's UI](RETRO_HOST_UI.md)) can be played
online with a friend from its lobby. Each player's launcher runs its own host
and its own copy of the game; only controller input crosses the network, and
both games run each frame with the same input. This is the launcher's side of
the host repository's design, `docs/netplay.md`, and of the protocol's
"Lockstep" and "Rollback" sections (capabilities `ps1Lockstep` and
`ps1Rollback`), of the core build identity (`status.core`, capability
`coreIdentity`, and netplay.md "Core build identity", at fb85606), of the
game's frame rate (`status.timing`, capability `gameTiming`, and netplay.md
"Frame rate", at 098cc0a) and of the checks' hash (`sync`, capability
`syncXxh3`, `lockstep.state`, and netplay.md "Desync checks", at 67aec4e),
all on the `netplay-design` branch of
[anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host),
whose SwanStation patches make the state a friend joins from fit for netplay
(it names no path, names the disc by its place in the disc list, and carries
the analog-mode button combination and each controller's mode), make a
state loaded in a rollback exact, and give each build of the core an identity
that is the same on Windows, Linux and macOS. When both players' hosts can
roll back, the match plays in rollback (see "Rollback"); otherwise in plain
lockstep.

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_lockstep.dart`](../lib/core/retro_host/retro_lockstep.dart) | The protocol's lockstep and rollback messages: `RetroLockstepSettings` (the `lockstep` argument, with the rollback window), `RetroStatePosition` (what `saveState` and `loadState` give, with the `micros` they took), `RetroStateFile` (the state file's header), `RetroStep` (a port null when predicted), `RetroCorrect`, `RetroSync`, `RetroRollback`, and `RetroLockstepTracker`, which holds the client and the host to the order of steps, corrections, syncs and rollbacks. `RetroLockstepHost` is what a match uses of a host. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | `lockstep`, `leaveLockstep`, `saveState`, `loadState`, `step`, `correct`, `canRollback`, `canIdentifyCore`, `canReportTiming`, `canHashXxh3` and the `syncs` and `rollbacks` streams ([RETRO_HOST_CLIENT.md](RETRO_HOST_CLIENT.md), "Lockstep", "The checks' hash", "Rollback" and "Core identity and timing"). |
| [`lib/core/retro_host/retro_host_protocol.dart`](../lib/core/retro_host/retro_host_protocol.dart) | `RetroCore`, the core a game loaded as `status.core` names it, and `RetroCore.playsWith`, the rule two players' cores are compared by (see "The cores"); `RetroTiming`, the game's frame rate and region from `status.timing` (see "Rollback"). |
| [`lib/core/online/ps1_netplay_wire.dart`](../lib/core/online/ps1_netplay_wire.dart) | `Ps1InputWire`: the input datagram, up to eight frames of one player's controller with the match's epoch and an acknowledgement. It is the input wire of the launcher's own PS1 online play on the fork's integrated branch, unchanged, as netplay.md asks. |
| [`lib/core/online/ps1_lockstep_control.dart`](../lib/core/online/ps1_lockstep_control.dart) | The reliable messages between the two launchers: `hello`, `ready`, `ping` and `pong`, `start`, the state's `chunk`s, `loaded`, `hash`, `advantage`, `pause` and `leave`, each read strictly (version 5). |
| [`lib/core/online/ps1_lockstep_match.dart`](../lib/core/online/ps1_lockstep_match.dart) | `Ps1LockstepMatch`: one match, from the hellos to the end, in plain lockstep or in rollback, with its timing (`timingFor`) and `Ps1RollbackHealth`. `Ps1LockstepIdentity` is what a launcher plays with, `Ps1LockstepGuest` the friend's game once it is ready, and `Ps1LockstepLink` the two channels it needs. |
| [`lib/core/online/ps1_lockstep_media.dart`](../lib/core/online/ps1_lockstep_media.dart) | `Ps1LockstepMedia`: what two launchers compare. The disc list is each disc's layout (its cue sheet's `FILE`, `TRACK`, `INDEX`, `PREGAP`, `POSTGAP` and `FLAGS` lines, each `FILE` naming its track by its SHA-256 instead of its name) and its tracks' contents, disc by disc in the playlist's order, so file names and remarks do not count but the number of discs, their layout and their order do; the BIOS is its 512 KiB images; the core is the build identity its host names (see "The cores"). A cue sheet that names a track that is not there gives no digest. |
| [`lib/core/online/ps1_file_digests.dart`](../lib/core/online/ps1_file_digests.dart) | `Ps1FileDigests`: the SHA-256 of each file read for a match, kept with its size and modification time in `retro/digests.json` beside the launcher's settings, so a file is read again only once it changed. Files are read on an isolate. |
| [`lib/core/online/ps1_netplay_state.dart`](../lib/core/online/ps1_netplay_state.dart) | `Ps1NetplayState`: whether a state file may go to another player. It must be a version 2 state file holding a SwanStation state of version 58 or later (the host's patch `swanstation-1-netplay-input-state`), with no title and no disc file name, and a disc trailer marked pathless with no path (patch `swanstation-2-pathless-netplay-state`). |
| [`lib/core/online/ps1_lockstep_peer.dart`](../lib/core/online/ps1_lockstep_peer.dart) | `Ps1LockstepPeer`: the WebRTC connection of a match over the launcher's `GameLink`, and `Ps1LockstepSignal`, its offer, answer and candidates. |
| [`lib/core/online/ps1_lockstep_rooms.dart`](../lib/core/online/ps1_lockstep_rooms.dart) | `Ps1LockstepRooms`: the private AnyTogether game session a match is arranged in: made, invited to, joined, signalled through and left. |
| [`lib/ui/retro_host_online.dart`](../lib/ui/retro_host_online.dart) | `RetroOnline` and the `RetroHostOnline` part of `AppModel`: the lobby page, inviting a friend, a friend's invite accepted, and what each end says. |
| [`lib/ui/player_slots_strip.dart`](../lib/ui/player_slots_strip.dart) | `PlayerSlotsStrip`: Player 1 to 4 side by side, drawn under a panel row that has `playerSlots`. The same cards as the Couch Co-op lobby of the fork's integrated builds, with its controller picture, [`assets/retro/coop-controller.png`](../assets/retro/coop-controller.png). |

## Who does what

- **The launcher owns the network.** The host never opens a socket. Rooms,
  invites, the WebRTC connection and its TURN relay are AnyTogether's, as for
  the launcher's other online play.
- **The host runs frames.** In lockstep it runs one frame for each `step`, with
  exactly that input, and reports a `sync` with the hashes of what the frame
  left behind. It saves and loads states between frames.
- **The match joins the two.** `Ps1LockstepMatch` decides the input delay,
  moves the state, exchanges input, hands each host its steps, and compares
  RAM hashes.

## A match, step by step

1. **The lobby.** The PS menu of a game in the host has a Couch Co-op row. Its
   page shows Player 1 to 4 and, when the player is signed in to AnyTogether,
   a row for each friend online now. Seats 3 and 4 say "Not in this game" and
   that they need the Multitap, which is off: version 1 of the host keeps
   SwanStation's Multitap off, so a PS1 game has two ports. A second
   controller on this computer takes Player 2 as before, and while it does, no
   friend can be invited.
2. **The invite.** A friend can be invited once the host lists `ps1Lockstep`
   and `coreIdentity` and the game's `status.core` has a build identity; the
   lobby says which of these is missing otherwise. Choosing a friend takes the
   digests of the disc and the BIOS images (read only when `Ps1FileDigests`
   does not know a file as it is now) and the game's core, makes a private
   room for two (`Ps1LockstepRooms.host`, with the
   SHA-256 and size of the disc's tracks, the room's `titleId` made from the
   digest) and invites the friend. Player 2 shows the friend as Invited. A game
   of its own folder (`retro.json`) has its tracks read from its cue sheet or
   playlist (`GameLibrary.discFiles`).
3. **The friend accepts.** The invite says so as a toast over the launcher and
   over a PS1 game playing in it, and as the launcher's notice card over a game
   in its own window, like any other game invite. It names the game when a disc
   in the library is known by its digest to be it ("Ana invites you to …"), and
   otherwise says "Play PS1 online with …". It shows in Friends as "Play PS1
   online with …". Accepting looks for the disc in the friend's library by the
   size of its tracks, then by its digest, discs whose digests are known first,
   opens a host, muted, checks it lists `ps1Lockstep` and `coreIdentity`
   (saying which it lacks, and joining nothing, when it does not), joins the
   room and connects.
4. **The connection.** Each launcher gets the room's STUN and TURN servers and
   makes a `GameLink`. The host player's launcher offers, the friend's answers,
   and the signals go through the room. Signals that come before the
   connection is made are kept for it.
5. **The hellos.** Each launcher says its host's version, its disc and BIOS
   digests, whether its host lists `ps1Rollback`, and whether it lists
   `syncXxh3` ("The checks"; version 5 of the control messages; rooms are
   `anyps5-ps1-lockstep-v5`); the host player's also names
   its game's core (`status.core`) and carries the core options its game runs
   with (the status's `activeValue`s). Any difference ends the match with what
   differs, before the game is held. The disc's file names do not count: the
   state names the disc by its place in the disc list. A hello can come before
   the other side's match has taken the connection, so the connection keeps
   the control messages that come early for it.
6. **The delay.** The host player's launcher measures the round trip with five
   pings and takes the median. In plain lockstep the delay in frames is half
   the round trip in frames, rounded up, plus one. Above eight frames the match
   ends as too slow, again before the game is held. In rollback the delay and
   the window come from the same round trip ("Rollback").
7. **The friend's game.** Meanwhile the friend's game starts with the host
   player's options and a memory card folder of the match's own
   (`retro/online/<room>/saves`), muted and not shown: the screen shows the
   game's name over black with "Preparing both games" (`RetroPlay.joining`),
   as netplay.md step 4 asks. Once its `status` is ready, its launcher sends
   `ready` with the core its host loaded, and both launchers compare the two
   cores ("The cores"). The host player's game plays on until then; cores that
   differ end the match on both sides before it is held.
8. **The state.** The host player's game enters lockstep and saves its state.
   The host saves a file for netplay, so it names no path. The launcher checks
   that (`Ps1NetplayState`) before anything is sent: a state that is not fit
   ends the match as "This emulator host cannot play online", and the host
   player's game goes on alone. The file is compressed and sent in 64 KiB
   chunks with its SHA-256, after a `start` that names the frame, the delay,
   the rollback window (0 in plain lockstep) and the match's input epoch. The
   friend's game then enters lockstep, checks the state the same way, loads it
   and says `loaded`. The state is inflated only up to the size the `start` announced.
   Once the match plays, the friend's game shows and its sound comes back at the
   player's volume. Meanwhile the menu's Volume and Mute change only what the
   game gets then; it stays muted. A
   match that ends while the friend's game is still starting waits for it and
   closes it.
9. **Play.** From the state's frame on, the first `delay` frames of both ports
   are idle. Each launcher reads its player's controller for the frame `delay`
   past the newest one its host ran, and sends every input the other side has
   not acknowledged: at once when new, again each frame while not
   acknowledged, and the newest every quarter of a second otherwise. In plain
   lockstep a step goes to the host once both inputs for its frame are known,
   at most eight frames past the delay ahead of the host; in rollback each
   frame is stepped on time, the other player's input predicted until it comes
   ("Rollback"). Port 1 is the host player's and port
   2 the friend's. While a game is paused (its menu is open, or the window lost
   focus) its host runs no frame, no new input is read, and the other game
   waits; the other player is told and sees "Paused".
10. **Checks.** Every 60 frames each launcher sends its RAM hash ("The
   checks"). A difference
   ends the match on both sides as out of sync. A launcher whose hashes stop
   coming while its input still does, or whose input runs further ahead than
   its game could, is not followed: the match ends, or the input is dropped.
11. **The end.** Leaving from the lobby, or the other player leaving, the
    connection breaking or 15 seconds without word from the other side, ends
    the match. Each host leaves lockstep: the host player's game goes on alone
    from where the match was, and the friend's game is closed. The room is
    ended or left and the match's folder deleted.

## The cores

Two hosts stay alike only if their cores compute alike, so the cores are
compared before anything is held, as netplay.md "Joining a running game"
step 1 and "Core build identity" ask. Each host names the core a game loaded
in `status.core` (capability `coreIdentity`): the core's `library_name` and
`library_version`. The host's own SwanStation builds report `SwanStation` and
`anyps5-1-<SHA-256>` of the build's source (the SwanStation commit and the
host's patches in the order applied), so a Windows, a Linux and a macOS build
of one host release name the same identity although their library files
differ. The two launchers play only when both strings are equal and the
version has that form (`RetroCore.playsWith`, protocol.md "status"); anything
else, a core built without the host's patch script or a debug build
(`SwanStation Debug`), is a different core.

- **When.** The host loads its core only for a game (netplay.md: `hello`
  cannot carry it), so the host player's launcher names its running game's
  core in its hello, and the friend's launcher names its own in `ready` once
  its game has started. Each launcher compares the other's with its own, so
  both end a match whose cores differ in the same way, with "The PS1 cores
  are different builds".
- **What it replaced.** Version 3 of the hellos sent the SHA-256 of the
  SwanStation library and the launcher's system, and compared the libraries
  only between two launchers on the same system: Windows and Linux players
  were never checked, and two copies of one build made by different compilers
  on one system would be refused. netplay.md rejects a hash of the core file
  for that reason. The library is still checked against its signed release
  before every start ([RETRO_HOST_CLIENT.md](RETRO_HOST_CLIENT.md), "Finding
  and checking the host").
- **A host without it.** A host that does not list `coreIdentity` cannot be
  compared, so it cannot play online: the lobby says so instead of offering
  friends, and a friend whose host lacks it is told so when accepting and
  joins no room. A game whose core reports no build identity is said to be
  one in the lobby.
- **What it does not prove.** The identity is a promise about builds made the
  way the host's release workflow makes them; the RAM checks of every match
  find two games that differ anyway.

## The checks

Each host hashes what a lockstep frame left behind in a `sync` (protocol.md
"sync"), and the match compares the main RAM's hash alone (`sync.ram`), as
RetroArch's lockstep does (netplay.md "Desync checks"):

- **Only RAM.** The state may hold video memory that two GPUs round
  differently, and only reading it back gives it to the host. So a match tells
  a host that lists `syncXxh3` to leave the state out (`lockstep.state`
  false, as netplay.md advises a launcher that compares only RAM): its `sync`
  then has no state hash and the host serializes nothing for a check. A host
  without the capability takes no such setting and hashes the state as well,
  which the match ignores. Nothing in the launcher reads `sync.state`.
- **Which hash.** A host with `syncXxh3` hashes with XXH3-64 and one without
  it with FNV-1a, so the same RAM gives two hashes that never match. The
  hellos say which their hosts use, and two launchers whose hosts differ end
  the match on both sides before either game is held, with "The emulator
  hosts are different builds" (`Ps1LockstepMismatch.syncHash`), as protocol.md
  "sync" asks, rather than finding the games out of sync at the first check.
  Two hosts that both lack it still play, with FNV-1a hashes. A friend's
  launcher whose game started in a host that is not the one its hello spoke
  for ends the match before saying `ready`.
- **What it replaced.** Version 4 of the hellos did not say which hash a host
  used: a host of the `netplay-design` branch from b1ea5ef on and an older
  one, both `hostVersion` 1.0.0, would have been matched and then found out of
  sync at the first check.

## Rollback

When both hellos say their hosts list `ps1Rollback`, the match plays as GGPO
does, the model netplay.md "Rollback" takes, with the network left to the
launcher:

- **Timing.** The other player's input comes `late` frames after the frame it
  is for would run with no delay: half the round trip in frames, rounded up,
  plus one, as in lockstep. The input delay is 2 frames (netplay.md: "a fixed
  1 or 2 frames"), or `late` when that is less, and the window is the frames
  left to predict plus 2 for input that comes later than usual, at most 8
  (GGPO's prediction window): a 100 ms round trip plays with 2 frames of delay
  and a window of 4. A round trip that would need more than 8 raises the delay
  instead, up to 8 frames, so rollback plays up to about a 430 ms round trip
  where lockstep stops at about 233 ms (`Ps1LockstepMatch.timingFor`).
- **One clock.** Each launcher steps its host on its own frame clock and the
  host runs each step as it comes (`paced` false). The clock runs at the
  game's own frame rate, its host's `status.timing.fps` (`gameTiming`), as
  protocol.md "Rollback" asks: about 59.82 frames a second in SwanStation's
  progressive NTSC mode and 49.75 in its PAL mode, so a PAL game runs at 50 as
  on a console. When a game changes its video mode the next `status` (every
  poll of the game) gives the new rate, and the frames from the one then due
  come at it. Both players' hosts give the same rate at the same frame, as it
  comes from the emulated console. A host without `gameTiming` gives none, and
  the clock runs at 60 (`Ps1LockstepMatch.defaultFrameTime`). The round trip
  is counted in frames of that length too, for the delay and the window, in
  plain lockstep as well, where the host keeps to the same rate itself; so is
  whether a rollback takes longer than a frame. A host that also kept to its core's own frame rate would run behind
  the steps by however far the two clocks drift apart, and the other player's
  input would then come before the frame ran, so nothing would be predicted:
  measured against two real hosts with a 100 ms round trip, a paced host rolled
  back 15 times in 600 frames, though about 500 of them were stepped without
  the friend's input, and an unpaced one 280 to 317 times.
- **Steps and corrections.** Stepping frame n reads this player's input for
  frame n + delay. The other player's port is given when its input has come,
  and null otherwise: the host predicts it. Once it comes it is sent as a
  `correct`, in frame order. No frame is stepped while the window is full
  (the frame a window back is not confirmed), while this player's game is
  paused, or while the host is known to be more than 4 frames behind its
  steps; the clock then waits too, so frames never come in a burst.
- **Time sync.** The launcher that started first (the friend, by half a round
  trip) would stay ahead and predict all of the round trip alone. So, as in
  GGPO, each launcher sends its average frame advantage (how far the other
  player's newest input is ahead of the frame it steps) every second in an
  `advantage` message, and when both agree it is ahead, it waits half the
  difference, at most 9 frames.
- **Checks.** The host sends a `sync` every 60 frames, those whose RAM is
  compared, rather than every frame, as netplay.md "Desync checks" advises: a
  check frame is hashed again each time a rollback runs it again. With
  `lockstep.state` false ("The checks") a check costs the RAM's hash and
  little more; a host without `syncXxh3` hashes the whole state too.
- **What the player sees.** The lobby's match row says the delay, how many
  frames may be predicted, how many rollbacks there were a minute over the
  last 10 seconds and how long each took, and that rollbacks are slower than a
  frame on this computer when they are on average. A match in plain lockstep
  because a host cannot roll back says so.

## Controllers in a match

`RetroHostControls.onlinePort` says which port this computer plays. The
controller at port 1 here then plays the match: its state is
`RetroHostControls.onlineInput`, idle while the menu is open or the window has
no focus, and the game gets no `input` and no `connectedPorts` (in lockstep it
takes only steps, whose `ports` say how many are connected). The core's
vibration for this player's port goes to that controller; the other port's is
the other player's.

## Tests

- [`test/fixtures/retro_host/core_identity_swanstation.json`](../test/fixtures/retro_host/core_identity_swanstation.json)
  holds what two real hosts sent about their core: the Windows x64 and the
  Linux x64 release packages of `netplay-design` at 67aec4e (its release
  workflow run 43813580226), each with its own SwanStation 631f0fb build and
  the host's eight patches, on OpenBIOS and the psyqo hello disc, recorded on
  Windows 11 and on Ubuntu 22.04 in WSL. Both list `coreIdentity`,
  `gameTiming` and `syncXxh3`, their first `status` has `core` null, and once
  ready both name `SwanStation` `anyps5-1-744335fe…c7d4`. The match tests, the lobby
  tests and the media test take their cores from it
  ([`test/core/online/lockstep_test_support.dart`](../test/core/online/lockstep_test_support.dart)
  reads it as the client does).
- [`test/fixtures/retro_host/game_timing_swanstation.json`](../test/fixtures/retro_host/game_timing_swanstation.json)
  holds what the same two release packages of `netplay-design` at 67aec4e
  (release workflow run 43813580226) sent about
  their games' timing: the psyqo hello disc on an auto-detected console
  (`ntsc`, 59.817 frames a second) and the host's corner program in a PAL
  video mode on a PAL console (`pal`, 49.747), the same on both systems.
  [`test/core/retro_host/retro_status_identity_test.dart`](../test/core/retro_host/retro_status_identity_test.dart)
  reads both fixtures as the client does, and refuses a `core` or `timing`
  out of what protocol.md allows. In
  [`test/core/online/ps1_lockstep_match_test.dart`](../test/core/online/ps1_lockstep_match_test.dart)
  two launchers in rollback step a PAL game about 50 times a second and,
  once its rate becomes NTSC's, about 60, and a PAL game's round trip is
  counted in its longer frames.
- [`test/core/retro_host/retro_lockstep_test.dart`](../test/core/retro_host/retro_lockstep_test.dart)
  replays what real hosts sent:
  [`test/fixtures/retro_host/lockstep_swanstation.json`](../test/fixtures/retro_host/lockstep_swanstation.json),
  two hosts from the Windows x64 release package of the `netplay-design`
  branch at 5a4cda9 (its release workflow run 43535853189) running
  SwanStation 631f0fb with the host's three patches on OpenBIOS and the psyqo
  hello disc under the host repository's `tests/lockstep_test.py`, each disc
  in another folder under another name: RAM, picture and state hashes match
  frame for frame, and after a join too. And
  [`test/fixtures/retro_host/lockstep_test_core.json`](../test/fixtures/retro_host/lockstep_test_core.json),
  that repository's test core refusing what lockstep refuses, from the same
  host. It also checks every rule the client holds the host and itself to.
- [`test/core/online/ps1_netplay_state_test.dart`](../test/core/online/ps1_netplay_state_test.dart)
  reads the state that real host saved for the join,
  [`test/fixtures/retro_host/lockstep_join_state.gz`](../test/fixtures/retro_host/lockstep_join_state.gz):
  its header is the one its `saveState` reply gave, it is fit for netplay, and
  the same state with a title, a disc file name, a path, a stock trailer or an
  older SwanStation state version is not.
- [`test/core/retro_host/retro_rollback_test.dart`](../test/core/retro_host/retro_rollback_test.dart)
  replays
  [`test/fixtures/retro_host/rollback_swanstation.json`](../test/fixtures/retro_host/rollback_swanstation.json):
  three hosts on Windows 11 and three on Ubuntu 22.04 in WSL, from the same
  two release packages of `netplay-design` at 67aec4e, on OpenBIOS and the
  host's pad program, driven by that repository's `tests/rollback_test.py`
  for 180 frames: two players' hosts in rollback, each stepping the other's
  late port null and correcting it, and a reference in lockstep, every
  lockstep with `state` false as a match sends it. Each player's steps,
  corrections, syncs and rollback messages go through the tracker in the
  order they were sent and read, every confirmed frame's RAM and picture equal
  the reference's, and no `sync` has a state hash. The Windows hosts drew with
  OpenGL and the Linux ones in software, and the two references' RAM hashes
  are the same frame for frame. It also checks the rules the tracker holds
  the launcher and the host to.
- [`test/core/retro_host/retro_lockstep_real_test.dart`](../test/core/retro_host/retro_lockstep_real_test.dart)
  runs the launcher's own client against two real hosts, with the same
  `ANYPS5_RETRO_HOST_REAL` file as the real host test. Both run 300 frames from
  a cold boot alike in RAM and picture, then one loads the other's state, from
  a disc of another name, and they stay alike in RAM and state. Then two
  `Ps1LockstepMatch`es play a match through a link that loses a tenth of the
  input and delays and reorders it: the friend's game starts with the host
  player's options, loads the state, and both compare RAM up to frame 600.
  They play it again in rollback with a 100 ms round trip: both hosts predict
  and roll back, and the RAM still matches up to frame 600. In both matches
  every `sync` has a RAM hash and no state hash.
- [`test/core/online/ps1_lockstep_match_test.dart`](../test/core/online/ps1_lockstep_match_test.dart)
  plays matches between test hosts whose RAM mixes every input: the same steps
  on both sides over a lossy link, a different disc, a slow connection, RAM
  that stops matching, a pause, a broken connection, and a state that names a
  path, which the host player's launcher does not send and the friend's does
  not load. Each host is told to leave the state out of its checks; a friend
  whose host hashes with the other hash ends the match on both sides before
  either game is held, two hosts that both lack `syncXxh3` still play, and a
  friend's game in a host that is not the one its hello spoke for is not
  played. The host player plays the Windows core and the friend the Linux
  one; a friend whose core is another build, or has no build identity, ends
  the match on both sides before the host player's game is held, and a hello
  that names a core from the friend, or none from the host player, is refused. In rollback its test hosts predict, correct and run frames again
  as protocol.md says, and refuse a step or correction that breaks its rules:
  both end with the same input in every confirmed frame, a host that cannot
  roll back makes the match lockstep, the friend waits for the host player as
  GGPO's time sync says, and the timing follows the round trip. The shared helpers in
  [`test/core/online/lockstep_test_support.dart`](../test/core/online/lockstep_test_support.dart)
  write the test hosts' states in the recorded state's form.
- [`test/core/online/ps1_lockstep_media_test.dart`](../test/core/online/ps1_lockstep_media_test.dart)
  covers the digests: a disc under other file names is the same disc; a
  playlist in another order, two one-track discs for one two-track disc, or
  another index is not; a playlist's discs in folders of their own have their
  tracks found beside their sheets; a file is read once while its size and time
  stay, and is kept for the next run.
- [`test/core/online/ps1_lockstep_peer_test.dart`](../test/core/online/ps1_lockstep_peer_test.dart),
  [`test/core/online/ps1_lockstep_rooms_test.dart`](../test/core/online/ps1_lockstep_rooms_test.dart)
  and [`test/core/online/ps1_netplay_wire_test.dart`](../test/core/online/ps1_netplay_wire_test.dart)
  cover the connection, the rooms and the input wire.
- [`test/ui/retro_host_online_test.dart`](../test/ui/retro_host_online_test.dart)
  has the lobby's goldens, signed out and with a friend invited, and what the
  row of a match playing says of its rollback, and
  [`test/ui/retro_host_online_together_test.dart`](../test/ui/retro_host_online_together_test.dart)
  signs in to the fake AnyTogether: the friends offered, a friend invited
  through a private room, a friend's invite in Friends, and an invite's notice
  and its answer: the disc found by its tracks, the friend's host opened muted,
  and the next invite naming the game without reading the disc again.
  [`test/ui/retro_host_play_golden_test.dart`](../test/ui/retro_host_play_golden_test.dart)
  has the golden of the friend's game while it joins.

## Not yet

- **PS2.** A PS2 game's lobby says online play is for PS1 games only
  (`retroOnlineUnavailable`, before any other reason), and a friend's invite
  is only ever matched to a PS1 game. The host has no PS2 lockstep, and
  LRPS2 is not shown to play the same on two computers (host `docs/ps2.md`
  "What stops PS2 online play").

- **Two computers.** No match has been played between two PCs through
  AnyTogether. The WebRTC connection is tested with an in-memory link, and the
  rooms with a fake AnyTogether. Direct and relayed connections, and a Windows
  and a Linux PC together, are still to be tried.
- **Windows with Linux.** The two cores are now compared across systems ("The
  cores"), and a Windows and a Linux release core were recorded naming the
  same identity, but no match has yet been played between a Windows and a
  Linux PC: the RAM checks are what would show their games differ.
- **A real PAL game online.** The frame clock follows `status.timing.fps`,
  checked with the rates real hosts gave and with test hosts in rollback, but
  no PAL disc has been played in a match between two real hosts.
- **Rollback cost.** With a `sync` every 60 frames, a rollback here took 16 to
  21 ms on average against two real hosts (OpenGL, 1x, Windows), for 1.7
  frames run again each; netplay.md's figures for CI runners are 3 to 6 ms a
  frame. A rollback that runs again the frame of a `sync` hashes it again.
- **Seats 3 and 4, and couch players online.** Four players need the Multitap,
  which the host keeps off. A second controller here and an online friend
  cannot play at once.
- **Focus.** A window that loses focus pauses its game, so the other player
  waits until it comes back.
- **A friend in a game.** An invite reaches a friend whose PS1 game is playing,
  but accepting it asks them to close that game first.
- **The controller picture.** `coop-controller.png` comes from the fork's
  integrated builds; where it was first made is not recorded there.
