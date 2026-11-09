# AnyPS5 Desktop PS1 netplay implementation plan

> **Execution workflow:** Use superpowers:executing-plans after implementation is requested. This document is a plan.

**Goal:** Two players complete a Crash Team Racing split-screen race over the internet, each running and rendering a matching PS1 copy inside AnyPS5 Desktop.

**Architecture:** One player's PC coordinates the match. Both PCs run the same emulation frames with the same controller inputs. AnyTogether handles the invitation and helps the two PCs connect. A relay may forward packets when direct connectivity fails. Neither the invitation service nor the relay runs the game.

**Stack:** Windows x64, pinned SwanStation Libretro DLL, the C++ embedded runner, Dart session orchestration and the existing WebRTC data-channel transport.

## What hosting means

| Role | Job | Where it runs |
| --- | --- | --- |
| Match host | Opens a private room, assigns ports, coordinates start frame and confirmed input, closes the match when the host leaves | Host player's PC |
| Rendezvous | Authenticates the users, delivers the party offer, and introduces their devices for a connection | Existing AnyTogether service, subject to checking the session API |
| Relay | Forwards encrypted traffic when the direct path fails | Existing TURN service if available for this session type, subject to maintainer approval |

The proposed experience is **Crash Team Racing → Play Together → Host**.
The friend chooses **Join** from the party offer. The app checks local copies,
tests the connection and shows Direct, Relayed or Unable to connect. Both
players confirm readiness and enter the same two-player game from a clean
boot. Either can leave. If the host quits, the app ends the match and restores
normal offline settings. Each PC draws the original split-screen view.

A dedicated match server is a later option for persistent rooms or neutral
hosting. A relay already solves the narrower connectivity problem when a
direct route fails. v1 needs neither a separately deployed emulator service
nor a user-managed port-forward. If the approved relay is unavailable, report
that connection failed and return to the lobby. Relay reuse and its traffic
policy remain service decisions.

## Approach decision

- **Recommended product path:** Add a small embedded netplay session to the
  launcher after the determinism gate. Reuse AnyTogether for identity, party
  offers and connectivity. Keep the frame scheduler in the native runner.
- **Reference and possible reuse:** Try the exact core and game in RetroArch
  netplay on two local instances as a comparison. Evaluate wire compatibility
  separately if interop would simplify the embedded design. RetroArch is a
  frontend with its own [netplay protocol](https://docs.libretro.com/development/retroarch/netplay/).
  Review [RetroArch's GPLv3 license](https://github.com/libretro/RetroArch),
  [SwanStation's license](https://github.com/libretro/swanstation) and the
  [desktop license](../LICENSE) with the maintainer before reusing implementation
  code or distributing a combined build. A comparator can stay separate from
  the launcher.
- **Correctness control:** Implement confirmed-input lockstep in the local
  harness first. It waits when a required input is late. Use it to prove the
  two-copy model. The playable candidate can use a small input buffer and
  bounded rollback if frame replay is deterministic and fast enough.

Scope the first release to two invited players, one verified disc revision,
one core build and one tested configuration. Public lobbies, spectators,
mid-match joins, host migration, and sync across arbitrary settings can wait.

## 1. Pin the fixture and prove determinism on one PC

The [PS1 determinism harness](<AnyPS5 Desktop - PS1 Determinism Harness.md>) records the local proof and its limits.

**Existing code:** [ManagedRetro](../lib/core/managed_retro.dart) resolves a
moving Buildbot package for PS1. The [native runner](../windows/runner/retro_core_host.cpp)
calls `retro_run`, installs input and output callbacks, and already exercises
serialization during some live graphics changes. It uses a process-wide
callback target. Use two separate worker processes for the harness. The
current input bridge accepts one pad. Keep its offline entry point while the
match adapter supplies explicit snapshots for both ports.

1. Record the core DLL SHA-256, canonical disc track hashes and order, region,
   BIOS hash, pad layout, options, and initial memory-card policy. Keep actual
   game and BIOS files local. Verify the same CUE content under different paths
   resolves to the same identity. Reject different track data before launch.
2. Use isolated temporary system and save paths. Boot both copies with the
   same blank temporary cards. Keep ordinary cards outside the session and
   discard temporary writes after the match. Check that CTR can start a
   two-player race under that policy before keeping it. If starting from an
   unlocked save is necessary, use an agreed local fixture and verify its hash.
3. In a standalone headless runner using the same native core contract, feed
   explicit P1 and P2 input snapshots before each `retro_run`. Advance by
   emulation frame number, even when no distinct picture is rendered. Capture
   a complete race with a fixed input script and compare checkpoints at the
   same confirmed frames. Qualify a stable state hash or game-visible memory
   fingerprint. Serialized blobs can contain nondeterministic padding or
   host metadata. A video hash can be a useful additional local control.
4. Repeat at least three cold runs. Restore several mid-race checkpoints and
   replay a fixed input window. Compare the resulting fingerprints with the
   uninterrupted control. Compare the software and intended hardware paths as
   separate configurations. Record checkpoint bytes and p50, p95 and worst
   save, restore and replay times. Investigate the first divergent frame before
   starting any connection work. If only one renderer works, gate the first
   match mode to that renderer and label the restriction.

**Exit gate:** A pinned pair agrees through the full race and after replay.
Record exact fixture hashes, supported settings, timing and failure evidence.
A headless pass is local evidence. It cannot qualify different machines.

## 2. Prove the frame protocol without a service

The [compatibility metadata](../lib/core/online/ps1_netplay_identity.dart)
validates title and protocol version plus SHA-256 digests for disc tracks,
BIOS, core, deterministic profile and initial memory card. Its
[tests](../test/core/online/ps1_netplay_identity_test.dart) check that mismatches
are distinguishable and local paths cannot be passed as identity fields.

The [input wire codec](../lib/core/online/ps1_netplay_wire.dart) encodes up to
eight complete controller snapshots in a 108-byte datagram. It validates the
match epoch, assigned seat, receive window and cumulative acknowledgement.
The [codec tests](../test/core/online/ps1_netplay_wire_test.dart) include
malformed packets and a PS5 separation control. A receiver must retain seven
frames of overlap for redundant snapshots or trim validated old snapshots
at the receive-window boundary. The session layer still owns peer binding,
duplicate suppression, readiness and the WebRTC connection.


**Planned modules:** A testable frame driver and bounded history in
`windows/runner/ps1_netplay_timeline.{h,cpp}`. Keep the existing runner as the
core adapter. Add a transport-independent codec in
`lib/core/online/ps1_netplay_wire.dart` and focused codec tests in
`test/core/online/ps1_netplay_wire_test.dart`.

1. Define a versioned handshake with mode, session epoch, peer identity,
   deterministic profile fingerprint, seat, ready and start acknowledgement.
   Match protocol, content, BIOS, DLL, configuration and initial card identity.
   Give actionable mismatch reasons. Include only metadata and hashes in the
   handshake. Keep local paths, firmware, discs and saves out of packets.
2. Send full controller snapshots keyed by emulation frame, with a sequence
   number and cumulative receipt acknowledgement. Bundle recent inputs with
   the newest packet to recover ordinary loss. Validate bounds, sender's seat,
   epoch and frame window. Drop duplicate, stale, oversized and unauthorized
   messages. Use the reliable channel for handshake and teardown. Use small
   unordered packets for inputs. Set bounded queues on both sides of the
   Dart/native boundary. The emulation thread owns frame mutation.
3. Run both workers through an in-process or loopback network simulator.
   Implement confirmed-input lockstep. Assert identical confirmed-frame
   fingerprints under reordering, burst loss, duplication and asymmetric
   delay. Exchange periodic fingerprints for frames both peers have confirmed.
   In v1, stop on confirmed desync and provide the frame and a diagnostic code.
   Start a new epoch for a rematch. State transfer and live recovery are later
   features with their own trust and compatibility requirements.

**Exit gate:** Matching fingerprints under network simulation and a clean
failure path on mismatch, peer timeout and disconnect. Validate every codec
limit with malformed packets. The game worker remains responsive during waits.

## 3. Fit rollback within the game frame budget

1. Add a local input delay and keep a ring of in-memory checkpoints. A trial
   starting point is two frames of input delay and an eight-frame prediction
   limit. These are measurement settings. The final window depends on core
   state size, replay speed and measured frame pacing. Cap total bytes and work
   per tick. Pause visibly if the remote input exceeds the prediction window.
2. When a late input disagrees with prediction, restore the checkpoint just
   before the first affected frame and replay using actual inputs where known.
   Compare confirmed states against lockstep. Keep catch-up output internal.
   Suppress replay video publication and manage speculative audio so sound
   effects play once. Measure the audio-buffer tradeoff alongside controls.
3. Test renderer resets and settings. Disable save/load, tuner trials,
   frame-skipping and simulation-changing options during a session. Quick Menu
   keeps the synchronized timeline running or uses an explicit pause agreed
   by both peers. Clear held local input on focus loss and menu entry. A peer
   that stalls or disconnects triggers bounded waiting and session teardown.

**Exit gate:** Under a published impairment matrix such as 0, 40, 80 and
120 ms RTT with separate jitter and packet-loss cases, measure per-player
button-to-display delay against offline, p95 frame time, audio underruns,
rollback depth, replay cost, memory and stall time. Complete repeated full
races with zero confirmed desyncs in the supported envelope. Document the
envelope and refuse or warn before start outside it. Keep lockstep for
diagnostics if rollback exceeds the frame budget.

## 4. Connect to AnyTogether without changing PS5 sessions

The [Windows worker](../windows/runner/retro_core_host.cpp) now detects the
portable core exports. It captures on the emulation thread and returns
the snapshot together with the exact next input frame. It can import into
an isolated guest only while the guest is held before starting its input
timeline. The [Flutter bridge](../lib/ui/embedded_retro_game.dart) submits
the verified disc hash and polls the request without blocking the UI
thread. Closing or cancelling a request cannot carry it into a later
game session. [Media verification](../lib/core/online/ps1_netplay_media.dart)
accepts the qualified portable build alongside the stock build. Peers still
need matching binaries because the core hash is part of match identity.

The [native probe driver](../windows/runner/tests/run_ps1_netplay_probe.py)
accepts `--checkpoint-guest` to test a running host and a separately
booted guest with a renamed CUE. It compares their full RAM fingerprints
and checks rejection for an incorrect digest and for importing after
start. The Windows portable test ran 360 confirmed frames with three
matching periodic RAM fingerprints before importing into a separate guest.
This is the worker boundary for the live handoff.

The [checkpoint transfer](../lib/core/online/ps1_checkpoint_transfer.dart)
now handles the authenticated transfer in the existing reliable peer stream.
Both peers opt into the checkpoint bootstrap during the
[identity handshake](../lib/core/online/ps1_netplay_session.dart). Chunks
are ordered and bound to the match epoch. Each acknowledged window carries
at most 64 KiB of state bytes, and the guest checks the payload SHA-256
before calling its restore handler. The session keeps both input timelines
held until the restore succeeds. Cancellation and link failure release the
pending transfer. The [session tests](../test/core/online/ps1_netplay_session_test.dart)
exercise multiple windows, delayed restore, corruption, mismatched startup
modes and cancellation.

The Windows worker now keeps the last 1,024 confirmed controller pairs on
the portable core. The [Flutter bridge](../lib/ui/embedded_retro_game.dart)
can request contiguous history in batches of at most 120 frames. An
isolated guest records the checkpoint frame on import and accepts replay
only at that cursor while its input timeline is still held. Replay runs on
the emulation thread, uses both recorded controllers, and suppresses its
video and audio. Closing an active replay stops the isolated guest.
The native catch-up probe combines the recorded race and `--checkpoint-guest`
to capture at frame 6,600 and compare the held guest's replayed RAM after
the host advances 180 frames. The Windows run matched at the catch-up
boundary and both original racers finished after 13,706 frames with 114
matching RAM fingerprints.

The [catch-up protocol](../lib/core/online/ps1_checkpoint_catchup.dart)
starts after the guest has restored that checkpoint. The host holds at a
confirmed frame and sends up to 120 controller pairs at a time over the
ordered peer stream. The guest acknowledges each batch after replay, and
both peers agree on the final frame before the ready handshake. That frame
is the checkpoint cursor. Both peers start the new input epoch at zero. The
session tests cover delayed restore and replay, a wrong cursor, incompatible
bootstrap modes, cancellation, and the first live fingerprint after cutover.

The [Windows worker](../windows/runner/retro_core_host.cpp) holds between
committed frames and keeps that history stable for the guest. Starting again
clears the previous peer's inputs, history, and fingerprint counters while
preserving the emulator state. The [input timeline](../windows/runner/ps1_netplay_timeline.h)
refuses to hold while a frame is being committed. The [headless probe](../windows/runner/tests/run_ps1_netplay_probe.py)
can replace a peer with `--cutover` and verify the fresh input epoch with
the real core. With the recorded CTR fixture, `--cutover-frame 4748`
selects a neutral input span for the new two-tick buffer. The headless
Windows run replayed 180 frames into the replacement guest, then both
peers finished at frame 13,706 with 113 matching RAM fingerprints across
the two input epochs. The control run finished at the same frame with
114 matches in a single epoch.

The portable state includes memory card data, so checkpoint exchange
uses session-owned storage. The deterministic profile is selected at
boot for this experimental path. Converting a normal play session in
place remains open.

An opt-in local staging mode now runs the deterministic worker before a
peer connects. The [embedded bridge](../lib/ui/embedded_retro_game.dart)
can start it with verified host media and hold or resume it on invitation
cancellation. While staging, the host plays on port one and the worker
records a neutral port two. It records the same confirmed input history
used by the online handoff. Online start requires a hold and resets the
input counters without restarting the core. The mode uses the match's
isolated memory card and is available to the app bridge for integration.
Run the headless probe with `--local-handoff --checkpoint-guest` to exercise
local play, cancellation, catch-up and the first online fingerprint.
The Windows CTR probe replayed 247 local frames, verified host input on
port one and neutral input on port two, and matched RAM at the first
online fingerprint. The control probe confirmed 360 frames with both
seats active, then verified an already-online host's replacement guest.

On a Windows experimental build with `ANYPS5_PS1_NETPLAY=1`, open a
recognized PS1 CUE game's options and select **Play with online co-op
available**. Accepting an in-game handoff invite uses the same core setup.
The [managed installer](../lib/core/managed_retro.dart) verifies the
configured `swanstation-netplay.zip` and the enclosed Windows DLL, then
installs it under `Emulators/PS1-Netplay`. A verified installation works
without the ZIP on subsequent starts. The offline SwanStation core and
regular game saves stay separate. In the running game, choose
**Quick Menu → Online couch co-op** and pick an online friend. The
[invite flow](../lib/ui/together_ps1_netplay.dart) uses a separate room
version for checkpoint handoff. It continues the local game while the
guest connects and offers **Cancel online session** while waiting.
The [handoff owner](../lib/core/online/ps1_local_handoff.dart) drains
outstanding native checkpoint, hold, start and input calls before resuming local play.
The [lifecycle tests](../test/core/online/ps1_local_handoff_test.dart)
cover cancellation during checkpoint capture and hold, and leaving during input exchange.
The native probe also verifies the host resumes local video after the
online match. The guest owns its own temporary game and exits it when the
match ends.

### Package the Windows checkpoint core

Run the [package builder](../tool/ps1_netplay/package_core.py) with the
qualified DLL from the [determinism harness](<AnyPS5 Desktop - PS1 Determinism Harness.md>).
Use an absolute package directory and pass it to the experimental launcher.

```powershell
python tool/ps1_netplay/package_core.py $coreDll $packages
$env:ANYPS5_MANAGED_CORE_PACKAGES = $packages
$env:ANYPS5_PS1_NETPLAY = '1'
```

The builder accepts the qualified DLL digest
`5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb`.
The resulting archive digest is
`86ab673a1a1b4260dc73256955d600dd64a5ee57e78e17696ae3504791a6633e`.
The package contains only the DLL. Each player still supplies their own
matching BIOS and game. The [co-op setup](../lib/ui/together_ps1_netplay.dart)
reuses an already verified BIOS. If the configured offline BIOS is
missing or incompatible, the [launcher preflight](../lib/ui/app_model.dart)
opens a file picker from the same invite or co-op-ready launch. The
[managed importer](../lib/core/managed_retro.dart) verifies the
SCPH-1001 digest before copying it to `Emulators/PS1-Netplay/scph1001.bin`.
The ordinary PS1 BIOS selection and saves stay separate. Cancelling the
picker or changing accounts during the invite leaves the room unjoined.
The [invite setup test](../test/ui/ps1_netplay_setup_test.dart) exercises
invalid selection, cancellation and sign-out before a join.
An isolated Windows probe reused a matching BIOS, then imported it into
a fresh profile with an incompatible offline fixture. The fixture kept
its original bytes and the imported BIOS passed CTR handoff media
verification with the managed checkpoint core. A separate launcher
fixture used the real CTR media and BIOS with a local fake AnyTogether
service. After choosing the BIOS, the original invite reached the room
join request. The fake service declined admission so no game started.

The ordinary PS1 invitation flow continues to use
its existing core selection. An explicit `ANYPS5_LIBRETRO_HOME` still
selects the reviewer core, which must pass the handoff pin check.

An isolated Windows install reproduced the archive digest, installed the
core, then reused the same DLL without a configured package directory.
The offline core and card fixtures kept their original bytes. With the
installed DLL, the [CTR checkpoint replay](../tool/ps1_netplay/late_join.py)
restored the guest at frame 6,600 using a renamed copy of the same disc.
All 62 checkpoints matched through frame 13,706 and both racers finished.
The guest rejected a truncated checkpoint and a wrong disc digest.
The local install and race receipts are under `ps1-netplay-package`.
This verifies package setup and the native checkpoint path on one PC.

### Windows development checkpoint

Set `ANYPS5_PS1_NETPLAY=1` on an experimental Windows x64 build to invite
friends to the selected PS1 game or accept invites in AnyTogether Games.
The [boot serial reader](../lib/core/ps1_disc_serial.dart) reads the CUE's
data track. The library records that serial separately from its existing
IDs and save paths. No title registration is required. This path accepts
CUEs with a recognized boot serial. CHD, PBP, playlists and discs without
a supported boot record still need identity support.

Both players need matching CUE and track content, an SCPH-1001 BIOS dump,
and the pinned SwanStation DLL. [Media verification](../lib/core/online/ps1_netplay_media.dart)
hashes the local files. The private room advertises the disc fingerprint
so the guest can choose the matching revision when multiple local copies
share a serial. The direct handshake checks the full compatibility identity.
The [launcher integration](../lib/ui/together_ps1_netplay.dart) routes PS1
invites separately from PS5. The game controls its local multiplayer mode
and camera layout, including split-screen where applicable.

[Shared room handling](../lib/core/online/retro_online_rooms.dart) uses a private
two-seat `online` room with a versioned marker in its properties and build
field. This follows the [AnyTogether game-session schema](https://github.com/AnyTogether/AnyTogether/blob/main/packages/shared/src/gameSessions.ts).
The [match owner](../lib/core/online/ps1_netplay_match.dart) binds signals
to the invited friend's account and published device, or to the room host
when joining. An unexpected room member is rejected before signaling.
After publication, cancelling releases the room while a pending member
lookup, invitation, or ICE lookup finishes independently. The
[peer adapter](../lib/core/online/ps1_netplay_peer.dart) carries reliable
handshake and lifecycle messages separately from the unordered input
snapshots. The [session protocol](../lib/core/online/ps1_netplay_session.dart)
checks compatibility before boot, acknowledges inputs and closes the runner
if either player leaves or stops advancing. It also compares RAM fingerprints
every 120 confirmed frames and stops the match at the first mismatch. The
other player may see a disconnect if the link closes before their copy
receives the final fingerprint.

The [headless Flutter runner](../windows/runner/tests/ps1_webrtc_loopback.cpp)
registers the real Windows WebRTC plugin without creating a view. Its
[Dart probe](../tool/ps1_netplay/webrtc_loopback.dart) connects two local
peers over real data channels with in-process signaling. It verified a
3 MiB synthetic checkpoint, 180 replay frames, and 120 matching live input
frames. For a Windows developer build, use `flutter build bundle --debug
--target-platform windows-x64 --target tool/ps1_netplay/webrtc_loopback.dart
--asset-dir <stage>/data/flutter_assets`. Compile the C++ runner in an
x64 MSVC developer shell with the Flutter engine and wrapper headers and
the plugin headers. Link `flutter_windows.dll.lib`, `flutter_wrapper_app.lib`,
`flutter_wrapper_plugin.lib`, `flutter_webrtc_plugin.lib` and `user32.lib`.
Stage the matching debug Flutter DLL, plugin DLL and libwebrtc DLL next
to the executable and `icudtl.dat` under `data`. Run the executable with
the `data` directory as its only argument.

To include the real emulator, build the [native worker probe](../windows/runner/tests/ps1_netplay_runner_probe.cpp)
and set `ANYPS5_PS1_WEBRTC_NATIVE` to a JSON file containing an array of
five strings in this order. Use the worker executable, portable SwanStation
DLL, local CUE, BIOS, and boot serial. The [worker client](../tool/ps1_netplay/webrtc_native_worker.dart)
starts isolated host and guest cores, pipes digital pad input, and sends
the host's actual checkpoint through WebRTC. It verifies guest replay,
360 confirmed frames, three matching RAM fingerprints, and local frames
after the guest leaves. The runner owns the worker processes through a
Windows job object so a probe timeout cannot leave them behind.
The [local room fixture](../tool/ps1_netplay/webrtc_room_fixture.dart)
drives the launcher room coordinator with an in-memory provider. It
requires a private invite, matching disc fingerprint, a published device
per participant, directed signals, and room release after the guest leaves.
Crash Team Racing and Tekken 3 passed this check with two Windows cores
and real WebRTC channels. Both reached the 360-frame fingerprint gate
and returned the host to local play after room release.
Hosted AnyTogether authentication, WAN or relay play, and a finished match
remain separate checks.

The [Windows worker](../windows/runner/retro_core_host.cpp) starts with
isolated storage, the full BIOS boot and two digital pads. It holds until both inputs for a
frame are confirmed, with a two-tick input buffer. The stock SwanStation DLL
diverged when restoring checkpoints in the earlier tests. The separate patched
core and prediction lane established the rollback performance result in
section 3. Shipping rollback still requires the patched core, native
prediction scheduling and frame pacing verification through the application.
A patched native single-core test completed the same race under 120 ms RTT,
25 ms jitter, 5% random loss and a ten-tick burst with the two-tick buffer.
All 114 fingerprints matched. Peak worker costs were 59.06 and 71.75 ms,
which exceed the 16.67 ms budget. The earlier separate prediction lane is
the implementation target for smooth rollback.
A scratch Windows prototype then ran two isolated core workers per peer
and passed the same 13,706-frame race with 114 matching checkpoints.
That run shared the machine with the PS2 test and used the Python harness
clock. Treat it as a correctness result. Native frame-budget qualification
and continuous in-app video and audio remain separate tests.
The [native timeline](../windows/runner/ps1_netplay_timeline.h) owns the
delay, retransmit window and ordered inputs. Its
[unit test](../windows/runner/tests/ps1_netplay_timeline_test.cpp) checks
gaps and conflicting inputs. The
[console probe](../windows/runner/tests/ps1_netplay_runner_probe.cpp) and its
[driver](../windows/runner/tests/run_ps1_netplay_probe.py) use the real
embedded worker with a headless texture and audio sink. They check periodic
RAM fingerprints and the race result against the recorded CTR trace.
On Windows x64, two stock-core workers finished the 13,706-frame Coco Park
Versus fixture with 114 matching RAM fingerprints. CTR marked both seats as
finished. This run used local confirmed inputs. The 120 ms fault-injection
rollback results in section 3 use a separate harness and patched core.

[Room tests](../test/core/online/ps1_netplay_rooms_test.dart) cover invite
validation, member binding, cancellation during room creation and teardown
while the WebRTC plugin is opening.
[Peer tests](../test/core/online/ps1_netplay_peer_test.dart) use fake data
channels for negotiation and teardown.
[Session tests](../test/core/online/ps1_netplay_session_test.dart) exercise
input delivery, acknowledgement under reordering, timeout and cleanup.
[Media tests](../test/core/online/ps1_netplay_media_test.dart) cover track
resolution and disc identity. Service sign-in, direct or relayed WebRTC,
and WAN gameplay still need the qualification below.

The Windows Release bundle built without launching it. The local CMake
build used the media plugin's hash-checked libmpv and ANGLE archives and
normalized the generated MSVC warning option to `/wd4100`. The online
core suite passed 76 tests and skipped seven external-probe tests. The
three focused launcher invite tests passed. The broader AnyTogether
widget run reproduced the same eight failures on the pre-change control.

**Existing code:** [GameSessions](../lib/core/together/game_sessions.dart)
creates LAN Play Together rooms and validates title/version/build.
[Play Together](../lib/ui/together_play.dart) launches that PS5 flow.
[OnlinePeerMesh](../lib/core/online/online_peer_mesh.dart) and its
[WebRTC adapter](../lib/ui/online_webrtc.dart) already support reliable and
unordered data channels. The mesh fetches session-scoped ICE servers through
the game-session API. Existing PS5 datagrams have their own wire format.

1. Confirm with the service maintainer how to advertise a typed retro session
   and grant it signaling and short-lived relay access. Do not assume the
   existing `kind: lan` contract accepts arbitrary retro metadata. Prefer a
   versioned capability. Old clients must reject unknown modes cleanly and the
   PS5 bridge must never receive a retro packet. Check authentication, capacity
   and permission to invite or join on the service as well as the client.
2. Implement a small retro session controller under `lib/core/online/` that
   reuses the peer connection layer and owns the retro handshake. Bind each
   connection to its party member and match epoch. Keep controller assignments
   host-authorized. Ensure the session closes peer links and stops the runner
   safely on cancellation, invite expiration, launch failure or app exit.
3. Hook only verified titles into the current party and Quick Menu flows.
   Show compatibility reason, connection route and coarse latency. Test with
   the [peer mesh suite](../test/core/online/online_peer_mesh_test.dart),
   [join verdict suite](../test/core/play_together_test.dart) and
[launcher party tests](../test/ui/together_test.dart), including the guard
that keeps CTR invites out of the PS5 launch path. Run focused suites
   with `flutter test test/core/play_together_test.dart test/core/online/online_peer_mesh_test.dart`
   and the applicable launcher tests on the project's supported CI platform.

**Exit gate:** Fake-service tests prove the invite, join, mismatch and cleanup
flows without production accounts. Existing PS5 tests pass. Maintainer agrees
on the session contract and relay scope before a WAN trial.

## 5. Qualify with a second tester before release

Use two Windows PCs on separate networks, each with its own compatible copy
and controller. Try a direct connection and a relay-only connection. Complete
multiple races and record both players' input delay, frame pacing and stalls.
Test quit, timeout, stale invite and clean rematch. Verify offline cards and
settings stay intact. Repeat on different CPU/GPU configurations before
claiming wider compatibility. This is the first phase that needs another PC.

Develop this feature on its own branch after approval to implement. Keep the
retro launcher preview in PR #84 independent of the netplay release gates.

If CTR fails determinism or replay cost, return to the pinned fixture and
investigate the first mismatched frame or timing bottleneck. A different core
or title is a separate qualification. Preserve local play and publish only the
title/core combinations that pass. PS2 LAN and PS3 native co-op share the
invitation UX and use their own transports and acceptance tests.
