# PS1 online play through the emulator host

A PS1 game that plays in the emulator host
([The emulator host in the launcher's UI](RETRO_HOST_UI.md)) can be played
online with a friend from its lobby. Each player's launcher runs its own host
and its own copy of the game; only controller input crosses the network, and
both games run each frame with the same input. This is the launcher's side of
the host repository's design, `docs/netplay.md`, and of the protocol's
"Lockstep" section (capability `ps1Lockstep`), both on the `netplay-design`
branch of [anyps5-retro-host](https://github.com/B-Howell/anyps5-retro-host).

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_lockstep.dart`](../lib/core/retro_host/retro_lockstep.dart) | The protocol's lockstep messages: `RetroLockstepSettings` (the `lockstep` argument), `RetroStatePosition` (what `saveState` and `loadState` give), `RetroStep`, `RetroSync`, and `RetroLockstepTracker`, which holds the client and the host to the order of steps and syncs. `RetroLockstepHost` is what a match uses of a host. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | `lockstep`, `leaveLockstep`, `saveState`, `loadState`, `step` and the `syncs` stream ([RETRO_HOST_CLIENT.md](RETRO_HOST_CLIENT.md), "Lockstep"). |
| [`lib/core/online/ps1_netplay_wire.dart`](../lib/core/online/ps1_netplay_wire.dart) | `Ps1InputWire`: the input datagram, up to eight frames of one player's controller with the match's epoch and an acknowledgement. It is the input wire of the launcher's own PS1 online play on the fork's integrated branch, unchanged, as netplay.md asks. |
| [`lib/core/online/ps1_lockstep_control.dart`](../lib/core/online/ps1_lockstep_control.dart) | The reliable messages between the two launchers: `hello`, `ping` and `pong`, `start`, the state's `chunk`s, `loaded`, `hash`, `pause` and `leave`, each read strictly. |
| [`lib/core/online/ps1_lockstep_match.dart`](../lib/core/online/ps1_lockstep_match.dart) | `Ps1LockstepMatch`: one match, from the hellos to the end. `Ps1LockstepIdentity` is what a launcher plays with, and `Ps1LockstepLink` the two channels it needs. |
| [`lib/core/online/ps1_lockstep_media.dart`](../lib/core/online/ps1_lockstep_media.dart) | `Ps1LockstepMedia`: the digests of the disc, the core and the BIOS images, read on an isolate. |
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
2. **The invite.** Choosing a friend reads the digests of the disc, the core
   and the BIOS images, makes a private room for two (`Ps1LockstepRooms.host`,
   with the disc's SHA-256 and size, the room's `titleId` made from the digest)
   and invites the friend. Player 2 shows the friend as Invited.
3. **The friend accepts.** The invite shows in Friends as "Play PS1 online
   with …". Accepting looks for the disc in the friend's library by its size,
   then its SHA-256, opens a host and checks it can lockstep, joins the room and
   connects.
4. **The connection.** Each launcher gets the room's STUN and TURN servers and
   makes a `GameLink`. The host player's launcher offers, the friend's answers,
   and the signals go through the room. Signals that come before the
   connection is made are kept for it.
5. **The hellos.** Each launcher says its host's version, its system, and its
   core, disc, disc file name and BIOS digests. Any difference ends the match
   with what differs, before the game is held. The cores are compared only
   between two launchers on the same system: a Windows and a Linux build of the
   same SwanStation are different files. A hello can come before the other side's
   match has taken the connection, so the connection keeps the control messages
   that come early for it. The host player's hello also carries the
   core options its game runs with (the status's `activeValue`s).
6. **The delay.** The host player's launcher measures the round trip with five
   pings and takes the median. The delay in frames is half the round trip in
   frames, rounded up, plus one. Above eight frames the match ends as too slow,
   again before the game is held.
7. **The state.** The host player's game enters lockstep and saves its state.
   The file is compressed and sent in 64 KiB chunks with its SHA-256, after a
   `start` that names the frame, the delay and the match's input epoch.
   Meanwhile the friend's game starts with the host player's options and a
   memory card folder of the match's own (`retro/online/<room>/saves`), and the
   match waits for its `status` to be ready. It then enters lockstep, loads the
   state and says `loaded`. The state is inflated only up to the size the
   `start` announced, so data from the other side cannot take more memory than
   that. A match that ends while the friend's game is still starting waits for
   it and closes it.
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
   ends the match on both sides as out of sync.
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
  two hosts of the `netplay-design` branch at 9b75364 running SwanStation
  631f0fb on OpenBIOS and the psyqo hello disc under the host repository's
  `tests/lockstep_test.py`, and
  [`test/fixtures/retro_host/lockstep_test_core.json`](../test/fixtures/retro_host/lockstep_test_core.json),
  that repository's test core refusing what lockstep refuses. It also checks
  every rule the client holds the host and itself to.
- [`test/core/retro_host/retro_lockstep_real_test.dart`](../test/core/retro_host/retro_lockstep_real_test.dart)
  runs the launcher's own client against two real hosts, with the same
  `ANYPS5_RETRO_HOST_REAL` file as the real host test. Both run 300 frames from
  a cold boot alike in RAM and picture, then one loads the other's state and
  they stay alike. Then two `Ps1LockstepMatch`es play a match through a link
  that loses a tenth of the input and delays and reorders it: the friend's
  game starts with the host player's options, loads the state, and both
  compare RAM up to frame 600.
- [`test/core/online/ps1_lockstep_match_test.dart`](../test/core/online/ps1_lockstep_match_test.dart)
  plays matches between test hosts whose RAM mixes every input: the same steps
  on both sides over a lossy link, a different disc, a slow connection, RAM
  that stops matching, a pause and a broken connection, with the shared
  helpers in
  [`test/core/online/lockstep_test_support.dart`](../test/core/online/lockstep_test_support.dart).
- [`test/core/online/ps1_lockstep_peer_test.dart`](../test/core/online/ps1_lockstep_peer_test.dart),
  [`test/core/online/ps1_lockstep_rooms_test.dart`](../test/core/online/ps1_lockstep_rooms_test.dart)
  and [`test/core/online/ps1_netplay_wire_test.dart`](../test/core/online/ps1_netplay_wire_test.dart)
  cover the connection, the rooms and the digests, and the input wire.
- [`test/ui/retro_host_online_test.dart`](../test/ui/retro_host_online_test.dart)
  has the lobby's goldens, signed out and with a friend invited, and
  [`test/ui/retro_host_online_together_test.dart`](../test/ui/retro_host_online_together_test.dart)
  signs in to the fake AnyTogether: the friends offered, a friend invited
  through a private room, and a friend's invite in Friends.

## Not yet

- **Two computers.** No match has been played between two PCs through
  AnyTogether. The WebRTC connection is tested with an in-memory link, and the
  rooms with a fake AnyTogether. Direct and relayed connections, and a Windows
  and a Linux PC together, are still to be tried.
- **The friend's game shows while it gets ready.** netplay.md has it muted and
  not shown until the state is loaded. Here it plays its first seconds on its
  own, on screen, before the state replaces them.
- **Windows with Linux.** Nothing checks that a Windows and a Linux core are the
  same SwanStation: the host version must match, and the RAM checks end a
  match whose games differ. A build identity from the host would close this.
- **Disc file names.** SwanStation finds a loaded state's disc by its path, or
  else its file name, so both players need the disc under the same file name;
  a difference is said before the game is held. The state also names the host
  player's disc path, which the friend's launcher receives. A SwanStation patch
  that names the disc by its hash fixes both (netplay.md "Determinism").
- **The analog button combination.** SwanStation keeps whether L1 + R1 + Select
  is held outside its state, so holding it after the friend joined can make the
  games differ. The RAM check then ends the match. It needs a SwanStation patch.
- **Rollback.** Only lockstep with input delay is built; netplay.md's
  `ps1Rollback` is not.
- **Seats 3 and 4, and couch players online.** Four players need the Multitap,
  which the host keeps off. A second controller here and an online friend
  cannot play at once.
- **Focus.** A window that loses focus pauses its game, so the other player
  waits until it comes back.
- **Invites.** A friend's invite shows only in Friends, with no notice over a
  game. Each invite reads the whole disc again for its digest.
- **The controller picture.** `coop-controller.png` comes from the fork's
  integrated builds; where it was first made is not recorded there.
