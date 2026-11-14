# PS1 online play through the emulator host

A PS1 game that plays in the emulator host
([The emulator host in the launcher's UI](RETRO_HOST_UI.md)) can be played
online with a friend from its lobby. Each player's launcher runs its own host
and its own copy of the game; only controller input crosses the network, and
both games run each frame with the same input. This is the launcher's side of
the host repository's design, `docs/netplay.md`, and of the protocol's
"Lockstep" section (capability `ps1Lockstep`), both on the `netplay-design`
branch of [anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host)
at 5a4cda9, whose SwanStation patches make the state a friend joins from fit
for netplay: it names no path, names the disc by its place in the disc list,
and carries the analog-mode button combination and each controller's mode.

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_lockstep.dart`](../lib/core/retro_host/retro_lockstep.dart) | The protocol's lockstep messages: `RetroLockstepSettings` (the `lockstep` argument), `RetroStatePosition` (what `saveState` and `loadState` give, with the `micros` they took), `RetroStateFile` (the state file's header), `RetroStep`, `RetroSync`, and `RetroLockstepTracker`, which holds the client and the host to the order of steps and syncs. `RetroLockstepHost` is what a match uses of a host. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | `lockstep`, `leaveLockstep`, `saveState`, `loadState`, `step` and the `syncs` stream ([RETRO_HOST_CLIENT.md](RETRO_HOST_CLIENT.md), "Lockstep"). |
| [`lib/core/online/ps1_netplay_wire.dart`](../lib/core/online/ps1_netplay_wire.dart) | `Ps1InputWire`: the input datagram, up to eight frames of one player's controller with the match's epoch and an acknowledgement. It is the input wire of the launcher's own PS1 online play on the fork's integrated branch, unchanged, as netplay.md asks. |
| [`lib/core/online/ps1_lockstep_control.dart`](../lib/core/online/ps1_lockstep_control.dart) | The reliable messages between the two launchers: `hello`, `ping` and `pong`, `start`, the state's `chunk`s, `loaded`, `hash`, `pause` and `leave`, each read strictly. |
| [`lib/core/online/ps1_lockstep_match.dart`](../lib/core/online/ps1_lockstep_match.dart) | `Ps1LockstepMatch`: one match, from the hellos to the end. `Ps1LockstepIdentity` is what a launcher plays with, and `Ps1LockstepLink` the two channels it needs. |
| [`lib/core/online/ps1_lockstep_media.dart`](../lib/core/online/ps1_lockstep_media.dart) | `Ps1LockstepMedia`: what two launchers compare. The disc list is each disc's layout (its cue sheet's `FILE`, `TRACK`, `INDEX`, `PREGAP`, `POSTGAP` and `FLAGS` lines, each `FILE` naming its track by its SHA-256 instead of its name) and its tracks' contents, disc by disc in the playlist's order, so file names and remarks do not count but the number of discs, their layout and their order do; the core is its library; the BIOS is its 512 KiB images. A cue sheet that names a track that is not there gives no digest. |
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
2. **The invite.** Choosing a friend takes the digests of the disc, the core
   and the BIOS images (read only when `Ps1FileDigests` does not know a file as
   it is now), makes a private room for two (`Ps1LockstepRooms.host`, with the
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
   opens a host, muted, checks it can lockstep, joins the room and connects.
4. **The connection.** Each launcher gets the room's STUN and TURN servers and
   makes a `GameLink`. The host player's launcher offers, the friend's answers,
   and the signals go through the room. Signals that come before the
   connection is made are kept for it.
5. **The hellos.** Each launcher says its host's version, its system, and its
   core, disc and BIOS digests (version 2 of the control messages; rooms are
   `anyps5-ps1-lockstep-v2`). Any difference ends the match with what differs,
   before the game is held. The disc's file names do not count: the state names
   the disc by its place in the disc list. The cores are compared only between
   two launchers on the same system: a Windows and a Linux build of the same
   SwanStation are different files ("Not yet" says what would close this). A hello can come before the other side's
   match has taken the connection, so the connection keeps the control messages
   that come early for it. The host player's hello also carries the
   core options its game runs with (the status's `activeValue`s).
6. **The delay.** The host player's launcher measures the round trip with five
   pings and takes the median. The delay in frames is half the round trip in
   frames, rounded up, plus one. Above eight frames the match ends as too slow,
   again before the game is held.
7. **The state.** The host player's game enters lockstep and saves its state.
   The host saves a file for netplay, so it names no path. The launcher checks
   that (`Ps1NetplayState`) before anything is sent: a state that is not fit
   ends the match as "This emulator host cannot play online", and the host
   player's game goes on alone. The file is compressed and sent in 64 KiB
   chunks with its SHA-256, after a `start` that names the frame, the delay and
   the match's input epoch. Meanwhile the friend's game starts with the host
   player's options and a memory card folder of the match's own
   (`retro/online/<room>/saves`), muted and not shown: the screen shows the
   game's name over black with "Preparing both games" (`RetroPlay.joining`),
   as netplay.md step 4 asks. The match waits for its `status` to be ready. It
   then enters lockstep, checks the state the same way, loads it and says
   `loaded`. The state is inflated only up to the size the `start` announced.
   Once the match plays, the friend's game shows and its sound comes back at the
   player's volume. Meanwhile the menu's Volume and Mute change only what the
   game gets then; it stays muted. A
   match that ends while the friend's game is still starting waits for it and
   closes it.
8. **Play.** From the state's frame on, the first `delay` frames of both ports
   are idle. Each launcher reads its player's controller for the frame `delay`
   past the newest one its host ran, and sends every input the other side has
   not acknowledged: at once when new, again each frame while not
   acknowledged, and the newest every quarter of a second otherwise. A step
   goes to the host once both inputs for its frame are known, at most eight
   frames past the delay ahead of the host. Port 1 is the host player's and port
   2 the friend's. While a game is paused (its menu is open, or the window lost
   focus) its host runs no frame, no new input is read, and the other game
   waits; the other player is told and sees "Paused".
9. **Checks.** Every 60 frames each launcher sends its RAM hash. A difference
   ends the match on both sides as out of sync. A launcher whose hashes stop
   coming while its input still does, or whose input runs further ahead than
   its game could, is not followed: the match ends, or the input is dropped.
10. **The end.** Leaving from the lobby, or the other player leaving, the
    connection breaking or 15 seconds without word from the other side, ends
    the match. Each host leaves lockstep: the host player's game goes on alone
    from where the match was, and the friend's game is closed. The room is
    ended or left and the match's folder deleted.

## Controllers in a match

`RetroHostControls.onlinePort` says which port this computer plays. The
controller at port 1 here then plays the match: its state is
`RetroHostControls.onlineInput`, idle while the menu is open or the window has
no focus, and the game gets no `input` and no `connectedPorts` (in lockstep it
takes only steps, whose `ports` say how many are connected). The core's
vibration for this player's port goes to that controller; the other port's is
the other player's.

## Tests

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
- [`test/core/retro_host/retro_lockstep_real_test.dart`](../test/core/retro_host/retro_lockstep_real_test.dart)
  runs the launcher's own client against two real hosts, with the same
  `ANYPS5_RETRO_HOST_REAL` file as the real host test. Both run 300 frames from
  a cold boot alike in RAM and picture, then one loads the other's state, from
  a disc of another name, and they stay alike in RAM and state. Then two
  `Ps1LockstepMatch`es play a match through a link that loses a tenth of the
  input and delays and reorders it: the friend's game starts with the host
  player's options, loads the state, and both compare RAM up to frame 600.
- [`test/core/online/ps1_lockstep_match_test.dart`](../test/core/online/ps1_lockstep_match_test.dart)
  plays matches between test hosts whose RAM mixes every input: the same steps
  on both sides over a lossy link, a different disc, a slow connection, RAM
  that stops matching, a pause, a broken connection, and a state that names a
  path, which the host player's launcher does not send and the friend's does
  not load. The shared helpers in
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
  has the lobby's goldens, signed out and with a friend invited, and
  [`test/ui/retro_host_online_together_test.dart`](../test/ui/retro_host_online_together_test.dart)
  signs in to the fake AnyTogether: the friends offered, a friend invited
  through a private room, a friend's invite in Friends, and an invite's notice
  and its answer: the disc found by its tracks, the friend's host opened muted,
  and the next invite naming the game without reading the disc again.
  [`test/ui/retro_host_play_golden_test.dart`](../test/ui/retro_host_play_golden_test.dart)
  has the golden of the friend's game while it joins.

## Not yet

- **Two computers.** No match has been played between two PCs through
  AnyTogether. The WebRTC connection is tested with an in-memory link, and the
  rooms with a fake AnyTogether. Direct and relayed connections, and a Windows
  and a Linux PC together, are still to be tried.
- **Windows with Linux.** Nothing checks that a Windows and a Linux core are the
  same SwanStation build: the host version must match (every build says
  1.0.0), both must save netplay-fit states (the host player's state is
  checked, and a stock core refuses to load one), and the RAM checks end a
  match whose games differ. The host reports no build identity: it never calls
  `retro_get_system_info`, and nothing in `welcome` or `status` names the core's
  source. To close this the host would need to report, once a game is ready, a
  field such as `status.core` = `{"name": …, "version": …}` taken from the
  core's `retro_get_system_info` (`library_name`, `library_version`), behind a
  capability the launcher can ask for; and its builds would need that
  `library_version` to name the SwanStation commit and the host's patch set
  (for example the SHA-256 of `cores/patches/*.patch` in the order they are
  applied, written in by `cores/apply-swanstation-patches.sh`), so that every
  operating system's build of one release reports the same string. The hellos
  would then carry it and compare it across systems, the SHA-256 of the library
  staying a same-system check.
- **Rollback.** Only lockstep with input delay is built; netplay.md's
  `ps1Rollback` is not, and the client offers no in-memory state slots.
- **Seats 3 and 4, and couch players online.** Four players need the Multitap,
  which the host keeps off. A second controller here and an online friend
  cannot play at once.
- **Focus.** A window that loses focus pauses its game, so the other player
  waits until it comes back.
- **A friend in a game.** An invite reaches a friend whose PS1 game is playing,
  but accepting it asks them to close that game first.
- **The controller picture.** `coop-controller.png` comes from the fork's
  integrated builds; where it was first made is not recorded there.
