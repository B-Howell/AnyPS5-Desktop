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

### Checkpoint capture from ordinary Play

The [Windows runner](../windows/runner/retro_core_host.cpp) reports a
`localBlankCardCheckpoint` source token after an ordinary PS1 session
presents a visible frame with a core that exposes the blank-card exporter.
`ps1LocalCheckpointExport` requires that token and the texture ID and
queues a read-only capture on the emulation thread at a frame boundary.
It returns a request ID for the existing result and cancel methods.
The returned capture frame is the ordinary runner's telemetry counter.
The match still needs its own input epoch. A busy card can reject the
capture while ordinary play continues. The worker only calls the
blank-card exporter for these requests.

The [native worker fixture](../windows/runner/tests/ps1_netplay_runner_probe.cpp)
and its [driver](../windows/runner/tests/run_ps1_netplay_probe.py) exercise
this path with `--ordinary-checkpoint` and a temporary BIOS and save
directory. Pass `--ordinary-control-core` with the preceding checkpoint
core to check that it cannot handle the new request. This entry point
captures state only. Starting the match also needs a verified compatible
core and settings, isolated match cards, and a reversible handoff from
the local session. The ordinary Play invitation described below uses
that separate handoff.

The Windows headless worker used hardware rendering and captured a
4,359,173-byte checkpoint from CTR at telemetry frame 616. The fixture
verified the blank card and absence of its synthetic private marker,
preserved the original scratch save through teardown, rejected a wrong
source token, and kept the same worker rendering after cancellation and
capture. A request while paused completed without advancing the
texture. The preceding core reported no ordinary capture support.
Local receipts are in `ps1-local-bridge-89f15e1`. This fixture calls
the worker directly. The capture route has a mocked Flutter
method-channel test. Live launcher invocation still needs integration
coverage.

The native worker fixture can exercise that renderer boundary with
`--ordinary-checkpoint --ordinary-restore`. The source uses the normal
hardware renderer and reports its active Recompiler CPU mode. Two
isolated software-rendered match workers select that same CPU mode,
restore a held source checkpoint, and start their input history at frame
zero. The fixture checks the held payload for the blank card, checks
initial RAM against the held source, and compares the first match
fingerprint after each seat supplies distinct inputs.
It then resumes the original session and verifies its scratch save.
The fixture exercises the Recompiler choice used by the ordinary Play
handoff. The older co-op-ready path uses the pinned Cached Interpreter
profile.

The Windows headless CTR run passed with the blank-card core
`d1619715fe11db0faa280890c741aff876fd5fd682f3cd00fbcafaa04732b7ac`.
Both software workers published frames and agreed after 120 match
frames. The hardware source resumed and its scratch save stayed
byte-for-byte identical. The preceding Cached Interpreter worker
pair also passed its 120-frame smoke test. Logs are in the local
`ps1-local-restore-3f9600b` directory. This verifies state import and
initial synchronization across renderers. A full hardware-origin race
and the launcher invitation lifecycle still need testing.

The [package tool](../tool/ps1_netplay/package_core.py) builds the separate
`swanstation-netplay-ordinary.zip` with `--profile ordinary`.
The [managed installer](../lib/core/managed_retro.dart) verifies the ZIP
and DLL, then installs the match core under `Emulators/PS1-Netplay-Ordinary`.
The [media verifier](../lib/core/online/ps1_netplay_media.dart) binds that
DLL and the Recompiler profile to the match identity. The
[embedded launch](../lib/ui/embedded_retro_game.dart) passes the CPU choice
to the [native worker](../windows/runner/retro_core_host.cpp), which accepts
it only for an isolated match seat using a core with the blank-card export.
The profile is distinct from the existing Cached Interpreter profile.
The installation targets the match core only.

The optional test in [managed retro](../test/core/managed_retro_test.dart)
accepts a local fixture file via `ANYPS5_TEST_PS1_ORDINARY_FIXTURE`. Its
JSON array contains the package directory, a verified CTR CUE and the BIOS.
The Windows run installed and reverified the exact package in a fresh
profile, rejected using its DLL under the standard profile and preserved
both offline and staged core fixtures. The native probe restored with
the new core and refused the Recompiler profile with the preceding core.
Local receipts are in `ps1-ordinary-package-fd8d600`.

Room version 3 is the ordinary Play checkpoint invitation. The
[guest flow](../lib/ui/together_ps1_netplay.dart) uses that version to
select the ordinary profile, find a compatible disc, provision the BIOS
and core, and join the original room. It expects one held checkpoint.
Version 2 keeps the staged host's catch-up stream and version 1 starts
from a fresh boot. The [launcher capture](../lib/ui/embedded_retro_game.dart)
checks the disc path, source CPU and core hash before sending the
session token and disc digest to the native blank-card endpoint.
The source token binds the request to one session. The host flow still
needs to pin the identity of its mounted disc and loaded core, since
checking the current files at their paths only verifies those files.

The [invite setup tests](../test/ui/ps1_netplay_setup_test.dart) check
that both checkpoint invite versions can open BIOS setup and that
canceling or signing out prevents admission. The local fixture uses the
qualified package and CTR media to verify the version 3 join request
against a fake room. It also checks that the launcher discards a capture
reply if the source closes before the reply arrives. The host Quick Menu
offers **Online couch co-op** for eligible ordinary PS1 sessions. With
`ANYPS5_PS1_NETPLAY=1`, ordinary Play can select the pinned handoff core
when its verified package is available. The host preflight requires a
recognized disc serial, a CUE image, and a single eligible BIOS in that
session's system directory. The pinned core and media digests are
verified before room creation.

The [launcher runner](../lib/ui/ps1_netplay_runner.dart) leaves the source
playing until the peer's handshake reaches preparation. It then parks the
source, detaches it, waits for the old worker to exit, and imports the
blank-card checkpoint into the isolated match worker at frame zero.
AnyPS5 retains the game artwork through the gap between workers. Closing
the room or failing to prepare the match releases the held source or
reopens it at the invite point after the isolated worker has exited.
The original save directory belongs to the local session. Match play
uses isolated storage.

A fresh-start, staged or ordinary checkpoint invite for the running PS1
game appears in the guest's Quick Menu when the local worker supports
recovery. The launcher verifies the local disc against the room before
parking the game. When the invite uses a different core, the launcher
hashes that core separately and reuses the verified disc and BIOS from
the current acceptance attempt. A fresh-start invite uses the supported
core from PS1 Setup and boots from the disc. If that core is missing,
the running game remains available and the launcher points to PS1 Setup.
A staged invite imports the host's checkpoint and replays the
host's inputs to the handoff frame. An ordinary invite imports the
host's checkpoint at the start of the match. The guest's recovery
checkpoint stays local. Leaving or losing the room restores the guest's
original game and memory card.

### Holding and recovering the ordinary game

`ps1LocalCheckpointPark` uses the same source token and texture checks as
capture. The qualified core supplies both portable exporters and the
portable importer. The [worker](../windows/runner/retro_core_host.cpp) saves the
blank-card checkpoint for the guest and a second, private recovery
checkpoint at the same emulation boundary. It returns only the
blank-card checkpoint. The private snapshot stays in the native session
and is never sent over the method channel. The source holds its existing
texture and flushes pending audio. Ordinary playback messages cannot
advance it while parked.

`ps1LocalCheckpointResume` queues a restore of that private state in the
original worker. It releases the hold only after a successful restore and
refreshes the card pointer before the next frame or save. Canceling a
park request before consuming its result releases the unmodified source.
The launcher requests that restore when the room ends before detach.
Canceling a restore already in flight discards its reply. A successful
restore still releases the source.
`ps1LocalCheckpointDetach` moves a consumed park's private snapshot to
the [launcher-side native host](../windows/runner/retro_core_host.h) and
ends the source worker. The host returns an opaque token. It retains the
disc, core, system directory, save directory and active options from the
source. A later `ps1LocalCheckpointReopen` uses only those saved values
and starts the original profile paused after applying the snapshot.
Park waits for pending settings to settle and freezes new changes until
resume or cancel. The launcher waits for `ps1RecoveredSource` to match
before unpausing the restored session. After it presents a visible frame,
`ps1LocalCheckpointAccept` acknowledges the ticket and restored texture.
The native host clears the snapshot only if that worker is still active
and ready. Status polls leave it intact. A failed boot or a Stop before
acceptance leaves the snapshot available so Play can retry the return.
The restored worker may run neutral frames to produce the first visible
image. Until acceptance it ignores player input and settings changes,
and stopping it leaves the persistent memory card untouched.
After unpause, a return that cannot produce a visible frame within eight
seconds also leaves recovery available. `ps1LocalCheckpointDiscard` can
free it with the same token once the worker has exited.

The [headless driver](../windows/runner/tests/run_ps1_netplay_probe.py)
accepts `--ordinary-checkpoint --ordinary-restore --ordinary-park`. The
fixture holds a hardware source while two separate software workers
consume the guest checkpoint. It deliberately erases the marker from the
held worker's scratch card, then exercises the native restore and checks
the original saved bytes at teardown. It also cancels an unclaimed
successful park and checks that normal playback resumes.
The Windows CTR fixture passed these checks with a hardware-rendered
source and the pinned blank-card DLL. The two restored match workers
also agreed at frame 120, and the preceding Cached Interpreter build
passed its separate 120-frame control. Logs are in the local
`ps1-local-park-34f1b3e` directory.

`--ordinary-checkpoint --ordinary-replace --ordinary-control-core`
exercises the native method codec, including a stale texture, a failed
match boot, a live match that blocks return, a failed return using a
temporarily unavailable scratch DLL, and reopening on a new texture.
It compares the recovered state and a non-default crop setting with the
parked source before unpausing and checks the scratch save at teardown.
The Windows CTR run passed with the pinned blank-card DLL. The return
attempt failed while the scratch DLL was unavailable and recovered the
source RAM and Overscan setting after the DLL returned. Local logs are
in `ps1-host-replace-e56c544`. The legacy match control also passed 120
frames. Successful discard and the visibility watchdog have static
coverage. The fixture exercises native method dispatch with an in-memory
texture registrar. It does not exercise the Quick Menu or a WAN invite.

The recovery acknowledgement regression stops a real CTR return after a
visible frame and reopens the same checkpoint, comparing its RAM to the
parked source. It rejects acceptance before a visible frame and against
the previous texture, then verifies that accepted recovery consumes the
ticket. The fixture changes a marker in the scratch card on disk and
checks that Stop before acceptance leaves it intact. Stop after
acceptance saves the restored card. The
[launcher tests](../test/ui/ps1_netplay_setup_test.dart) also send a
visible status with the wrong token, check that input is gated through
acceptance, and exercise cancellation during park and detach.
The host integration test starts ordinary Play with the pinned CTR
media, selects an online friend from the Quick Menu, and checks that the
local worker stays active while waiting for the guest to connect. A
local gateway and paired test links run the real invitation and
checkpoint protocol.
Before opening or joining a room, the Quick Menu for the host and the
AnyTogether Games panel show the PS1 file check with a cancel action.
Cancellation invalidates that attempt, stops an active media hash at a
chunk boundary, and discards late picker and room lookup results. A
pending room lookup releases the attempt immediately on cancel. A
managed core install already in progress can finish safely before the
attempt clears. The local game keeps running, and the same friend can
be invited again when verification has stopped.
The mocked native channel verifies the park, detach, isolated boot,
frame-zero import, and running match. The online row shows **Waiting for
the other player** until the room binds the expected player and their
device. **Connecting to the other player** covers transport negotiation
and compatibility checks. **Preparing both games** covers the game
handoff until play begins. Cancel remains available throughout startup.
During active play the same row can show Direct or Through the relay and
the rounded round-trip time from the selected WebRTC candidate pair.
The [adapter](../lib/ui/online_webrtc.dart) only reports measured data.
The [match](../lib/core/online/ps1_netplay_match.dart) samples it every
two seconds off the input path. Missing statistics leave the ordinary
match status visible, and a sync stall takes precedence over telemetry.
During teardown, **Ending online play**
replaces the action with a status row until cleanup finishes. The
Quick Menu also recognizes the loading card during a worker handoff,
including the gap between the two workers. The integration test holds
the native park and reopen replies and checks the Quick Menu's rows
before progressing. Leaving through the Quick
Menu closes the peer and room and restores the original game on a new
texture. This covers launcher orchestration. A two-client run with real
workers, WebRTC, and the production service remains to be verified.

The Windows focused suite uses the pinned CTR fixture. It includes the
[PS1 setup](../test/ui/ps1_netplay_setup_test.dart), media, session, room
and embedded worker tests plus the existing retro startup, session and
menu window tests. The handoff assertions reproduced the stale waiting
message and the missing row during recovery before the fix. The Guide
command was dispatched through the launcher model. Verification tests
cover cancel and retry with the original worker active, a late BIOS
picker reply, and a retry while the canceled guest lookup is still
pending. The [media test](../test/core/online/ps1_netplay_media_test.dart)
rejects a partial fingerprint when a track read is interrupted.

The launcher uses the handshake's compatibility reason to explain what
the players can change. It distinguishes the game, disc revision, BIOS,
SwanStation package, online settings, starting memory card, and AnyPS5
version. The CTR Quick Menu regression presents an incompatible disc
identity, checks the specific message and room cleanup before any native
handoff, then successfully retries from the original running game.
The [headless Windows WebRTC loopback](../tool/ps1_netplay/webrtc_loopback.dart)
also verifies that both real data-channel peers receive the disc refusal
before either runner prepares. This uses synthetic identities and local
signaling. It does not qualify delivery through the production service.

During a running match, 750 ms without a newly confirmed frame shows
**Waiting for the games to sync** in the Quick Menu and over gameplay.
The hint clears on the next confirmed frame or when the match closes.
The existing timeout still ends a match whose progress does not resume.
The [native WebRTC probe](../tool/ps1_netplay/webrtc_ordinary_probe.dart)
can hold the guest input exchange mid-match and check that both peers
show the stall, continue the same epoch, and agree on subsequent RAM
fingerprints. This exercises an input gap on an open WebRTC route.
The offscreen CTR and Tekken 3 runs each resumed to 360 confirmed
frames, matched three RAM fingerprints, preserved the local card
during the match, and returned to hardware playback. The focused
Windows suite passed 67 tests, including the Quick Menu status change.

On a failed ICE route during an active match, the
[PS1 route recovery](../lib/core/online/ps1_ice_recovery.dart) keeps both
existing channels and the input epoch. Only the host creates a new
offer. The guest can request it, and both ends can replay their current
description and candidates. The authenticated room carries numbered
signals so old route traffic cannot replace the current description.
Retries run every 750 ms and stop after eight seconds. A closed channel
still ends the match and follows the existing return-to-game path.
The [peer regression](../test/core/online/ps1_netplay_peer_test.dart)
also rejects the first local description on each side and verifies
that the same negotiation continues. The offscreen CTR and Tekken 3
probes on the first revision used an injected failure notification and
rejected the first request, offer, and answer through the local gateway
fixture. Both applied fresh ICE credentials and reached 360 confirmed
frames on their original two links. The final SDP retry changes were
verified in the focused suite. Physical route loss and WAN remain open.

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
x64 MSVC developer shell. Compile `ps1_webrtc_loopback.cpp` with
`windows/runner/retro_vulkan_video.cpp` using C++17, `NOMINMAX` and
`WIN32_LEAN_AND_MEAN`. Include the Flutter engine and wrapper headers,
the plugin headers, and the launcher's pinned Vulkan headers. Link
`flutter_windows.dll.lib`, `flutter_wrapper_app.lib`,
`flutter_wrapper_plugin.lib`, `flutter_webrtc_plugin.lib`, `user32.lib`,
`d3d11.lib`, `d3dcompiler.lib`, `winmm.lib`, and `dxgi.lib`.
Stage the matching debug Flutter DLL, plugin DLL and libwebrtc DLL next
to the executable and `icudtl.dat` under `data`. The
[probe host](../windows/runner/tests/ps1_probe_host.h) consumes native
textures in memory and discards audio writes.

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

The [ordinary handoff probe](../tool/ps1_netplay/webrtc_ordinary_probe.dart)
adds room version 3. It starts the real embedded hardware host in the
windowless Flutter engine, waits for it to draw while the invite is
pending, and starts the isolated Recompiler match after the guest joins.
The separate native guest imports the checkpoint over real WebRTC using
the verified disc digest. Both seats provide input and compare three RAM
fingerprints over 360 confirmed frames. The probe checks that the scratch
card is unchanged during the observed match interval. It requires the
host to accept the recovery ticket and draw hardware frames on the
returned texture after the room closes. This exercises the real workers
and transport with fixture signaling. The Quick Menu has a separate
launcher integration test. The production service remains unverified.
Crash Team Racing (`SCUS94426`) and Tekken 3 (`SLUS00402`) both passed
the ordinary probe on Windows with the pinned blank-card SwanStation
core. Each run verified the recovery acceptance and subsequent frame
publication. This is a short synchronization and recovery check.

Run it with PowerShell 7.4 or later and the same five-field fixture, using
the pinned ordinary core for the DLL:

```powershell
pwsh -File tool/ps1_netplay/run_webrtc_probe.ps1 -Runner "path/to/loopback.exe" -Data "path/to/data" -NativeFixture "path/to/fixture.json" -Ordinary
```

The [probe launcher](../tool/ps1_netplay/run_webrtc_probe.ps1) gives the
headless runner and its job-contained children a private temporary root
and removes it after exit. Omit `-Ordinary` for the staged native control.
Omit both fixture options for the synthetic WebRTC control.

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
gaps and conflicting inputs. The timeline can also be constructed with a
bounded prediction window. It marks frames that need a checkpoint,
reports the earliest incorrect prediction at a frame boundary, and
preserves the sampled local inputs and monotonic transport counters on
rewind. Only corrected, completed frames can become confirmed. The
native test exercises 2,000 frames of delayed and out-of-order inputs
against a known-good input sequence. When wiring the worker, key
checkpoints by the emulation cursor and keep speculative fingerprints
private until their frames are confirmed. If an earlier correction
arrives during restore and invalidates the rewind target, restore that
earlier checkpoint before stepping again.

The [Windows embedded worker](../windows/runner/retro_core_host.cpp)
has a headless-only rollback mode. It stores at most one in-memory
SwanStation checkpoint per prediction slot, uses the same-instance
save-state context, and discards speculative fingerprints on rewind.
Replay steps suppress video output. A bounded PCM buffer keeps each
frame's audio until its inputs are confirmed and replaces the earlier
samples if that frame is replayed. The worker hands confirmed audio
to the output in frame order. The confirmed input mode remains the
launcher default while presentation and device pacing are being
integrated.

The [native driver](../windows/runner/tests/run_ps1_netplay_probe.py)
accepts `--rollback --frames 720` with the stock command's disc and BIOS
arguments and the [SPU-patched Release core](<AnyPS5 Desktop - PS1 Determinism Harness.md>).
It withholds frame 119 until the prediction worker passes it, checks
that no speculative RAM fingerprint or PCM escaped, then changes that
frame's second-controller input. A silent capture compares the stereo
sample count and PCM digest against the confirmed-input control as
well as comparing confirmed RAM. This covers native checkpoint
restoration and audio ordering. Full-race pacing, device underruns,
and uninterrupted video presentation need separate verification.

Run the same native driver with `--rollback --trace` and the
[CTR race input fixture](../tool/ps1_netplay/fixtures/ctr_usa_coco_park_versus.json)
to exchange the native workers' actual controller packets at 60 Hz.
The driver uses the 120 ms RTT model with 25 ms jitter, 5% random loss,
a ten-tick loss burst and seeds 2401 and 2402. The workers retain the
two-frame input delay. The single-core prediction window is eight frames. The
driver requires both game-owned finishes, matching confirmed RAM
fingerprints, and matching PCM drained through the final frame. It
reports native worker time before pacing sleep, texture callback gaps,
and confirmed PCM delivery gaps. The silent probe cannot measure
sound device underruns or display timing on a player's monitor.

The single-core native baseline finished all 13,706 frames in 309.65
seconds. Both game instances reported the same finish and placements,
all 114 RAM fingerprints matched, and the workers drained the same
10,104,619 stereo sample pairs through the last frame. Seat 1/2 peak
worker iterations were 266.663/244.619 ms, with 117/118 over 16.667 ms.
Peak texture delivery gaps were 252.375/233.042 ms, and peak PCM
delivery gaps were 349.207/262.254 ms. The baseline passes the race
integrity check and fails the pacing gate. The [two-core harness](<AnyPS5 Desktop - PS1 Determinism Harness.md>)
provides the comparison for keeping presentation active during replay.

The Windows worker now has distinct primary and presentation callback
slots. Each slot binds its own Libretro functions and owns a separate
loaded DLL instance until shutdown. The headless `isolated-cores` mode in
the [native runner probe](../windows/runner/tests/ps1_netplay_runner_probe.cpp)
accepts a second private copy of the same pinned DLL as its final
argument. It checks duplicate-slot and shared-module rejection, distinct
audio and texture output, and continued presentation after the primary
worker unloads. Both cores confirmed 480 frames in one process.

The primary worker can also capture an in-process checkpoint at a frame
boundary. The presentation worker restores it with Libretro's
same-binary context, then processes one or two controller frames per
request. It can continue from its previous render without another
restore. Its mailbox wakes on render and shutdown, and presentation jobs
publish video without sending audio, input packets, or confirmed state.
The probe uses two copies of the same pinned DLL and the same BIOS and
disc. The handoff checks the disc path and checkpoint bounds, and the
caller must supply an identical core and BIOS before launcher wiring.
The probe restores frame 240, steps twice, and checks RAM against an
uninterrupted run.

Pass `--presentation-core` with a separate byte-identical DLL to the
headless rollback driver to enable scheduled handoffs during replay.
The spare publishes to the primary texture while the primary corrects
its timeline. It samples local inputs through the same two-frame buffer
and can preview only within the native prediction window. The primary
resumes video after it catches the spare, and continues to own
confirmed PCM and RAM throughout. The probe counts actual texture
updates forwarded from the spare. The launcher still creates one
primary worker. Its production integration needs verified pairing and
separate validation of display timing and audio device underruns.

The dual-core run under the same network profile finished all 13,706
frames in 292.82 seconds with matching placements, 114 matching RAM
fingerprints, and 10,104,619 matching stereo pairs through the final
frame. The spare supplied 3,758 and 5,316 texture updates for seats 1
and 2. Peak primary-worker iterations were 14.214 and 16.325 ms, with
zero over 16.667 ms. Peak video delivery gaps still reached 238.405
and 230.052 ms, and peak confirmed PCM delivery gaps reached 333.695
and 233.346 ms. The timing counter covers the primary thread, including
both replay slices, and excludes the spare thread. The result passes
the primary work budget and still fails the presentation cadence gate.
That dual-core baseline used an eight-frame prediction window, shorter
than the modeled ten-tick burst. Attaching the spare now expands the
headless primary window to sixteen frames. The worker sizes its
checkpoint and PCM buffers to the selected window. The short test
withholds one input for twelve frames of prediction and verifies
recovery against confirmed-input RAM and PCM.

The sixteen-frame run used the full window on both seats and finished
in 288.80 seconds with the same 114 RAM fingerprints and 10,104,619
stereo pairs. The worst primary work was 21.723 ms with five overruns
on seat 2. The largest video and PCM gaps were 404.254 and 348.712 ms.
This profile improved race completion time over the eight-frame
dual-core baseline while increasing the largest presentation gap.
The forced-gap test showed the spare could keep advancing after the
primary reached its previous high-water mark. The primary needs to
continue catching up until it reaches the spare's displayed frame.

The second catch-up slice now uses the spare's frame as its target.
It retains the two-slice limit and permits the extra step only if
the elapsed work is under 7.5 ms. In the forced-gap regression the
spare supplied eleven updates before the primary caught up, down from
589 with the previous condition. RAM and PCM still matched the
confirmed-input control.

The same full race then finished in 289.35 seconds with matching RAM
and PCM. The spare supplied 3,737 and 4,936 texture updates, down from
6,217 and 7,222. The worst primary work fell to 18.468 ms with four
overruns across both seats. The largest video gap increased to 419.268
ms and the largest PCM gap reached 349.324 ms. These observations
support faster return to the primary after a correction. Presentation
cadence and the strict frame budget remain open.

The paced driver also accepts `--sample-frames 1800` with
`--network-profile clean` or `120ms-loss`. Both prefixes check RAM
and drained PCM. The native probe measures time in polls that could not
advance and late wakes after a scheduled sleep. With the old sender the
clean prefix took 30.08 seconds with zero blocked polls. The impaired
prefix took 38.20 seconds and spent 7.51 to 7.64 seconds in blocked polls.
Peak deadline wake lateness stayed under 2.5 ms in both controls.

When the unacknowledged range exceeds eight inputs, the prediction
timeline now alternates between its newest contiguous batch and its
oldest unacknowledged batch. Both batches retain the existing eight-input
wire limit. This lets recent inputs reach the other player during
retransmission. Confirmed-input sessions retain their existing policy.
With rotation enabled, the clean prefix took 30.09 seconds. The
impaired prefix took 30.20 seconds with zero blocked polls, and its
worst texture gap fell from 100.398 ms to 33.701 ms. Both versions
matched all 15 prefix RAM fingerprints and 1,326,986 stereo pairs.

The full impaired race finished in 233.95 seconds, down from 289.35
seconds with the old sender. Both finishes, all 114 RAM fingerprints
and 10,104,619 stereo pairs matched. The largest texture gap fell from
419.268 ms to 99.312 ms. Blocked polls occupied 160.120 and 63.229 ms
on the two seats. The largest PCM delivery gap was still 347.163 ms.
Peak primary work reached 64.765 ms and 144 iterations across both
seats exceeded 16.667 ms. Keeping the input stream current improves
cadence, while the worker budget and audio delivery still need work.

The headless dual-core path now queues confirmed PCM on a separate
playout worker. The queue holds at most 64 frame blocks, waits 120 ms
before the first audio samples, and emits samples in order at the
core's sample rate. After an underrun, confirmed PCM starts a fresh
120 ms reserve before playout resumes. The probe compares every
drained sample through the final frame and reports recovered underruns
and queue depth. The startup
reserve adds audio latency, and the silent sink measures delivery
cadence without exercising a playback device. The standalone and
launcher audio paths retain their existing behavior.

The 120 ms loss-profile race finished in 233.31 seconds, with both
finishes, all 114 RAM fingerprints and 10,104,619 stereo pairs
matching. The largest PCM delivery gap fell from 347.163 ms to
164.280 ms. The seats recovered from 264 and 265 queue underruns, and
their queues peaked at 13 and 10 blocks. The largest texture gap was
83.569 ms, and the worst primary iteration was 15.621 ms with no
iterations above 16.667 ms in this run. These measurements show an
improvement in silent delivery and leave continuous playout open.
The native probe's `audio-queue-test` also checks the startup reserve,
sample-count spacing and FIFO ordering independently of the race. It
forces a gap and checks that the reserve is rebuilt before emission.

With reserve rebuilding enabled, the same full race finished in
233.32 seconds with identical results, RAM and PCM. Recovered
starvation events fell from 264/265 to 30/30. Peak PCM delivery gaps
were 175.887 and 243.533 ms, compared with the earlier worst of
164.280 ms. Queue depth peaked at 21 and 16 blocks. This trades
fewer interruptions for longer recovery pauses. The slowest primary
iteration was 14.536 ms in this run. Continuous device playout
remains unverified.

### Windows launcher rollback preview

The [Friends invite flow](../lib/ui/together_ps1_netplay.dart) offers a
separate Rollback Preview invitation when both PS1 netplay and the rollback
preview are enabled. Preview rooms use version `4` and a distinct
[execution fingerprint](../lib/core/online/ps1_netplay_media.dart). Both
players boot the matching disc from Home with isolated blank memory cards.
Existing fresh, staged and in-game handoff invitations retain their current
room versions and behavior. In-game handoff into rollback still requires
checkpoint and recovery qualification.

For a Windows test build, put the pinned `swanstation-netplay-rollback.zip`
in the absolute directory configured by `ANYPS5_MANAGED_CORE_PACKAGES`.
Set `ANYPS5_PS1_NETPLAY=1` and `ANYPS5_PS1_ROLLBACK=1` on both launchers.
Use the existing PS1 BIOS setup and select the same game revision on both
PCs. The [package tool](../tool/ps1_netplay/package_core.py) accepts the
qualified DLL with `--profile rollback`. The ZIP pin is
`7446d092547a9ec3ce2a47aff748511a83c3357989ff592dab406024c3d9d1da`.
The [installer](../lib/core/managed_retro.dart) verifies the archive and
both installed DLLs. It stores the preview pair separately from the
offline core and repairs an invalid copy from the verified ZIP.

The [embedded start call](../lib/ui/embedded_retro_game.dart) passes the
presentation library path to the [Windows host](../windows/runner/retro_core_host.cpp).
The host rejects aliased DLLs, waits for both cores, and uses one texture
and one audio output for the session. The
[channel probe](../windows/runner/tests/ps1_netplay_runner_probe.cpp) exercises
the real start, input exchange, presentation and shutdown methods with a
silent output and no launcher window. The
[setup test](../test/ui/ps1_netplay_setup_test.dart) uses a fake service to
verify that joining a version 4 room installs both libraries before admission.
On Windows the channel probe advanced CTR for 120 frames with remote
controller packets and verified a single texture registration. The separate
720-frame native rollback probe corrected a late input, forwarded 12
presentation frames, and matched six RAM fingerprints and 530,793 stereo
sample pairs. The three focused Dart suites passed 31 tests with the local
fixtures, including the existing room modes and the new package repair case.
Production signaling, audible playout and the two-PC player experience
remain release gates.

The [console probe](../windows/runner/tests/ps1_netplay_runner_probe.cpp) and its
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
