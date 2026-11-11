# AnyPS5 Desktop emulator multiplayer design

## Product direction

The required host entry is the PS Quick Menu in a running game on both Windows and Linux. In a focused embedded session, the PS button or Esc opens that menu. The host starts the lobby, chooses an AnyTogether friend, and returns to play. A dashboard ellipsis or prelaunch-only entry cannot fulfill this requirement. Ship the complete feature set in one integrated source revision on both platforms. Move Swap Cross and Circle to per-game Controls.

The current Linux PS1 Quick Menu cannot host from ordinary play because [host mode selection](../lib/ui/together_ps1_netplay.dart) still requires the Windows-only managed capability. Closing the gap requires a qualified Linux core and safe running-session handoff, as well as the visible action.

Windows and Linux are required platforms for the emulator online feature.
Windows-only implementation or qualification cannot satisfy release acceptance.
The Linux port is the immediate implementation priority; the platform gaps
below remain release blockers.

Use AnyTogether's **Play Together** to invite friends into a game session.
Every player launches a compatible local copy, renders locally, and plays
through their own controller. The session exchanges game traffic or frame
inputs. The streaming path is outside this design.

## Integration status

The fork integrates Windows and Linux online work with different remaining platform gaps.
The offline emulator review slices remain upstream PRs #85, #86 and #87.
The online branch also carries subsequent optimizer, disc-menu and
console-artwork changes so local integration preserves those features.
Its cumulative diff is broader than the networking adapters alone.
The [fork draft](https://github.com/B-Howell/AnyPS5-Desktop/pull/1)
tracks integration and qualification while the upstream slices are reviewed.

| Requirement | Current evidence | Still required |
| --- | --- | --- |
| PS1 couch co-op from the running game Quick Menu | The launcher performs compatibility checks, transfers an isolated checkpoint, assigns the remote controller and returns to the local game afterward. Two native CTR copies completed a full race in confirmed-input mode through the local TURN fixture with dropped input packets. | A scripted physical Windows/Linux race passed with hosted signaling and direct WebRTC. Manual in-game hosting, controller verification and separate-network acceptance remain open. |
| PS2 native LAN through AnyTogether | The virtual NIC and room bridge carry local and relayed Ethernet traffic. Two native TimeSplitters copies completed a round after a simulated route failure. | A complete GT4 race, active gameplay with the latest native queue-reset callback, physical network-loss tests and separate-network acceptance. |
| PS3 native online handoff | The launcher verifies an isolated provider profile, prepares its firmware/update, handles invitations and shows provider/membership state. Core and launcher checks use local fixtures. | Approved provider profile and identities, qualified binaries, and a real private level with two clients. The public release catalog is empty. |
| Couch co-op for PS2 and PS3 games without native LAN/online support | The current PS1 input-synchronization adapter is specific to the PS1 core. | An additional synchronization adapter for each core. The existing PS2 LAN and PS3 provider paths do not cover this requirement. |
| Windows and Linux feature parity | Linux has PS1 managed setup, mixed-platform rollback, PS2 LAN setup and PS3 channel support. | Qualify matching combined packages and the ordinary running-game Quick Menu path. macOS offline review and CI are tracked separately. |
| Fresh installation and ordinary-user operation | Managed package verification, missing-setup recovery, in-game invites, cancellation, retry messages and isolated storage have focused regression coverage. | Approved immutable online-core distribution and a fresh-profile end-to-end run with the production room service. |

Detailed evidence and constraints belong to the
[Linux implementation plan](<AnyPS5 Desktop - Linux Online Implementation Plan.md>),
[PS1 plan](<AnyPS5 Desktop - PS1 Netplay Implementation Plan.md>),
[PS2 plan](<AnyPS5 Desktop - PS2 LAN Implementation Plan.md>) and
[PS3 plan](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md>).
Passing one adapter or a one-PC fixture does not close the other rows.

Ordinary online-gaming connections are the target. Measure real
round-trip delay, jitter and packet loss on direct and relayed routes
before publishing connection requirements. PS1 couch co-op exchanges
controller input during play. Its mid-game invitation also sends a
one-time checkpoint, so the host's upload speed affects how long the
guest takes to join. The [paced CTR harness](<AnyPS5 Desktop - PS1 Determinism Harness.md#prediction-worker-scheduling-proof>)
uses a simulated 120 ms round trip with jitter and packet loss. It
qualifies that harness run and leaves real internet play to the two-PC gate.

The existing [Play Together flow](../lib/ui/together_play.dart) owns party
offers, join checks and session teardown. Add a versioned compatibility
descriptor for each supported multiplayer mode. It should identify the
platform, title, compatible game revision and mode. For synchronized
emulation, also require a matching content hash, core build and relevant
emulation settings. Reject incompatible joins with a specific reason before
launching. Keep the existing PS5 engine path separate.

## Shared implementation and validation

### Start couch co-op from a running game

The [PS Quick Menu](../lib/ui/app_model.dart) is the entry point for an
eligible running game. **Play Together → Invite a friend** opens the existing
AnyTogether friend picker in the game overlay. Dismissing the overlay returns
to play while the invitation is pending. The host sees when the friend is
ready, and the guest receives the next free controller seat. For titles with
separate single-player and local multiplayer modes, players use the game's
own mode selector.

The [PS1 match controller](../lib/core/online/ps1_netplay_match.dart)
and [embedded runner](../lib/ui/ps1_netplay_runner.dart) support fresh
boots and two ways to start from a running game. A co-op-ready session
keeps a bounded input history while the guest catches up. The ordinary
Play preview waits for the compatible guest handshake, holds the
original game at a frame boundary, and starts both match workers from
the same blank-card checkpoint. The original session reopens at that
point when the match ends. Its private recovery snapshot stays in the
native host. Both paths isolate match storage and bind the invite to the
verified game media.

The [late-join harness](../tool/ps1_netplay/late_join.py) tests the underlying
state transfer on two independent local processes and different disc paths.
The patched SwanStation probe restored a frame 6,600 CTR checkpoint into
a guest in a separate directory and matched 62 RAM and video checks through
frame 13,706. The initial check compares RAM before the guest renders its
first frame. The snapshot was 11 MiB raw and about 2.1 MiB after compression.
The legacy snapshot contained the host's absolute disc path. An equivalent
CUE with a different basename was rejected, consistent with the pinned core's
[media lookup](https://github.com/libretro/swanstation/blob/631f0fb31b809e0f889d7c551fe695788e39c1d3/src/libretro/libretro_host_interface.cpp).
The [portable checkpoint patch](../tool/patches/swanstation-portable-checkpoint.patch)
adds separate versioned exports for this handoff. The frontend hashes each
player's verified disc and prepares the agreed disc slot. The checkpoint
stores the disc SHA-256 and the core's game ID. Import checks both against
the local verified disc, validates the state length and version, and
restores against the disc already mounted on the guest. The portable
serializer omits the display title, disc path and legacy path trailer.
Ordinary save states still use their existing format.

Portable snapshots can contain memory-card data. Treat the older probe's
snapshots as trusted local artifacts. The ordinary Play preview exports
only the blank-card snapshot and has its own pinned core and recovery
handshake. The PS1 implementation plan records its qualification scope.

The acceptance test for the Quick Menu also needs a successful invitation,
cancel and disconnect during catch-up, proof that host playback and saves
survive each path, and real video and audio during the handoff. Only show
the action when the active backend can join a running session.

The [PS1 netplay plan](<AnyPS5 Desktop - PS1 Netplay Implementation Plan.md>),
[PS2 LAN plan](<AnyPS5 Desktop - PS2 LAN Implementation Plan.md>) and
[PS3 native co-op plan](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md>)
use the same invite and preflight experience with different gameplay adapters.

| Component | Shared contract | Mode-specific work |
| --- | --- | --- |
| Party and invite | Host an invite-only room, accept or decline, show seat and readiness, expire stale offers and tear down on exit | Confirm the service supports typed retro sessions and old clients refuse unknown modes. Keep current PS5 sessions and wire format separate. |
| Preflight | Select a matching local copy and show the first actionable incompatibility before boot | PS1 requires matching deterministic inputs and fingerprints. PS2 checks title revision and backend compatibility. PS3 checks title/update, approved provider profile, patch and effective game settings. |
| Session lifecycle | Prepare, check, connect or hand off, launch, verify readiness, end | PS1 is ready after both frame peers acknowledge start. PS2 needs an attached virtual segment and native LAN discovery. PS3 needs evidence of a native game join. A successful launcher start is a separate state. |
| Transport | Common diagnostics for route, setup time and disconnect when observable | PS1 exchanges controller inputs. PS2 carries approved guest LAN traffic. Both may reuse WebRTC signaling and relay. PS3 leaves gameplay traffic to RPCS3 and the game provider. |
| Isolation | Separate profile, storage and process boundaries for a local harness. Redact diagnostics and restore offline settings after exit. | PS1 isolates temporary cards. PS2 isolates virtual network identities and the segment. PS3 isolates core endpoints and provider configuration. |

Keep the shared layer small. [GameSessions](../lib/core/together/game_sessions.dart)
owns session API calls and party membership. Its current `lan` contract is for
PS5. Negotiate a typed extension with the service maintainer instead of
encoding emulator settings as PS5 engine fields. Use a shared preflight result
and match controller, then hand off to the relevant mode. Do not combine
frame replay, Ethernet and provider traffic into one game protocol.

The experimental [retro room API](../lib/core/online/retro_online_rooms.dart)
takes a title, version, capacity and gameplay mode. It shares invitation,
membership and device binding across modes. The
[PS1 qualification profiles](../lib/core/online/ps1_netplay_media.dart)
keep tested disc revisions outside the launcher UI. The
[invite dispatcher](../lib/ui/together_profile.dart) keeps retro invitations
out of the PS5 launch path. CTR is the first qualified PS1 profile. The
PS2 and PS3 room contracts are testable with fakes while their gameplay
adapters are being qualified.

| Future test | PS1 | PS2 | PS3 |
| --- | --- | --- | --- |
| One PC, fakes | Invite and mismatch, packet validation, failure and teardown | Same launcher checks, virtual segment and packet isolation | Same launcher checks, provider errors, profile verification and redaction |
| One PC, two isolated game processes | Complete and replay a deterministic CTR race under simulated network conditions | Complete a GT4 native LAN race and a virtual-segment race with injected network conditions | Verify distinct profiles and endpoints. A private two-client live pilot depends on provider rules, identities and hardware. |
| Two PCs on separate networks | Validate direct and approved relay routes, latency and rollback | Validate direct and approved relay routes, native discovery and race stability | Validate native private lobby and full level, including reconnect and divergence checks |

Implement the shared flow against [fake peer transport](../test/support/online_fakes.dart)
and [fake party service](../test/support/fake_together.dart) when one mode
passes its local technical gate. Add the other modes as they qualify rather
than waiting for all three. The initial design required no hosted service,
build or live test. Implementation now has local native and transport
evidence in the per-console plans. Keep multiplayer work separate from PR #84.

## What we can reuse

- **PS3:** The RPCS3 core already offers [network and RPCN options](https://docs.libretro.com/library/rpcs3/#network).
  The game and its online service own matchmaking and gameplay traffic.
  AnyTogether can coordinate the party, check compatibility and launch the
  configured game. Reuse a supported join mechanism if the service exposes one.
- **PS2:** Standalone PCSX2 [emulates a PS2 Ethernet adapter through DEV9](https://pcsx2.net/blog/2023/q1-2022-progress-report/#dev9).
  The [LRPS2 build source](https://github.com/libretro/ps2/blob/master/Makefile.common)
  also contains DEV9 and a sockets backend, with packet capture as an opt-in
  build option. Verify which backends and settings the exact Windows DLL
  exposes before designing a bridge. Native LAN can carry a game's own
  multiplayer traffic if the chosen backend supports its discovery and packets.
- **PS1:** SwanStation gives the frontend save-state hooks. [RetroArch's
  netplay layer](https://docs.libretro.com/development/retroarch/netplay/)
  owns input exchange, prediction and replay. Evaluate reuse of its protocol
  or implementation after the core determinism test. Loading SwanStation alone
  does not bring RetroArch's frontend networking into AnyPS5.

## Validation stages

Planning does not require a second computer. A future one-PC harness can use
two isolated processes, with separate profiles and distinct endpoints, to
exercise compatibility checks, replay determinism and synthetic packet delay
or loss. A local pass cannot establish WAN matchmaking, NAT traversal or the
performance of two independent machines. Schedule that acceptance check when
a second tester is available. Implementation is underway. The integration
status above records the remaining gates.

## Multiplayer paths

| Path | First candidate | Engineering gate |
| --- | --- | --- |
| Game's native online protocol | LittleBigPlanet GOTY on PS3 | Two embedded RPCS3 clients can enter the same private online level using a compatible title update, protected server patch, RPCN and matching gameplay-sensitive settings. |
| Game's native LAN protocol | A PS2 LAN title such as Gran Turismo 4 | Two emulated consoles can discover and join each other on a local LAN first. Then evaluate a title-scoped virtual LAN over the [AnyTogether peer mesh](../lib/core/online/online_peer_mesh.dart). |
| Synchronized emulation | Crash Team Racing split-screen on PS1 | Two instances of the pinned SwanStation core stay in sync with the same disc, BIOS, settings, start state and frame-stamped inputs, including after restoring and replaying a checkpoint. |

LAN requires an emulated NIC or link interface that supports the title's
protocol. The [LRPS2 feature table](https://docs.libretro.com/library/lrps2/#features)
does not list frontend netplay support. The [Gran Turismo 4 LAN manual](https://www.gran-turismo.com/local/jp/data1/pdf/gt4_lan.pdf)
establishes the game's native LAN mode. Whether the chosen embedded PS2
backend can carry that traffic remains a separate gate.

## First proof of native PS3 co-op

LittleBigPlanet already has an online protocol. [Bonsai documents an RPCS3 path](https://docs.lbpbonsai.com/rpcs3.html)
using a current game update and a title-specific Patchwork patch. Its [support notes](https://docs.lbpbonsai.com/faq.html)
also call out RPCN and matching XFloat settings. Verify the exact GOTY disc ID
and update against the provider before assuming the standalone path works
with the embedded core. Preserve the offline default and loopback behavior
in the [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch).
Use opt-in, isolated profiles and the provider's current client protections
for an invite-only test. Review the [published client security advisory](https://www.lbpunion.com/post/security-advisory-about-littlebigplanet-online-play/)
before enabling a public option.

First verify native sign-in, join and play through a private level on two
Windows PCs. Record the exact game update, patch, core and relevant settings.
The [AnyTogether invitation handoff](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md#3-reuse-party-invites-and-hand-off-to-the-game>)
opens the configured title after profile verification and directs both players
to its native online menu. Automate native room joining only if the game
or provider exposes a supported way to do it. The [RPCS3 Libretro feature table](https://docs.libretro.com/library/rpcs3/#features)
does not support frontend save states or netplay, so PS3 is outside the
synchronized-emulation path.

## First proof of synchronized PS1 multiplayer

The [PS1 netplay implementation plan](<AnyPS5 Desktop - PS1 Netplay Implementation Plan.md>)
defines player hosting, relay decisions, the local determinism harness,
frame protocol, rollback and two-PC release gates.

Start two local core processes with identical fixtures and replay the same
frame-stamped input log. Compare a repeatable emulated state or game-visible
checksum through a complete race, then restore a checkpoint and replay to
the same result. The [Windows embedded host](../windows/runner/retro_core_host.cpp)
already uses serialization for some graphics transitions. That establishes a
checkpoint mechanism to investigate. Netplay needs determinism and a measured
checkpoint and replay cost under the exact selected renderer and core options.

Once determinism is proven, use synchronized input as a correctness control.
Measure whether a small input buffer plus bounded rollback keeps the controls
responsive under delay, jitter and loss. The [Libretro protocol design](https://docs.libretro.com/development/retroarch/netplay/)
documents the replay model. Track simulation-affecting options in the session
contract and block changing them during a race. Detect desync and end the
match cleanly if recovery fails. Split-screen remains split-screen because
that is the mode the original game supplies.

## Room admission

When an invitation identifies its sender, the launcher checks that
the room is still owned by that account. For PS1 and PS2 it checks
both the initial disc lookup and the read immediately before joining.
PS3 checks before joining. If the host differs, the launcher asks
the player to request a fresh invite. A legacy invite with no sender
continues to use the validated room host.

The [shared room admission checks](../lib/core/online/retro_online_rooms.dart)
use the closing signal from the [PS1 match](../lib/core/online/ps1_netplay_match.dart),
[PS2 LAN match](../lib/core/online/retro_lan_match.dart), or PS3 invite.
Cancel releases pending read-only checks immediately. Once a room
create or join request has gone out, cleanup keeps tracking the result
so it can release any room it acquired. PS2 retains its existing
eight-second close wait cap. Friends keeps the Closing status and
blocks new online attempts until the pending room cleanup finishes.
A canceled PS1 start returns normally so the launcher does not report
a connection failure.

## Acceptance before exposing Play Together

The optional emulator reviews remain separate from multiplayer.
On November 10, [#85](https://github.com/AnyTogether/AnyPS5-Desktop/pull/85),
[#86](https://github.com/AnyTogether/AnyPS5-Desktop/pull/86), and
[#87](https://github.com/AnyTogether/AnyPS5-Desktop/pull/87) regained
mergeability with upstream `7eb9277` after preserving the new install
documentation and Linux overlay. The published heads `0435da3`,
`2571884` and `990511f` passed 8, 22 and 28 focused tests respectively.
The latter two runs included the upstream Linux overlay Dart tests.
Hosted platform jobs and maintainer review remain separate gates.

PS1 and PS2 bind disc verification to the host returned by the first room
lookup. If an older invite omits the sender, the launcher still requires the
same host at admission. A host change before the join request displays the
existing host-changed message. The [room client](../lib/core/online/retro_online_rooms.dart)
returns the host and fingerprints together. The
[PS2 LAN invite tests](../test/ui/ps2_lan_invite_test.dart) exercise the
launcher with both sender-bearing and senderless invites. The
[fresh PS1 invite fixture](../test/ui/ps1_netplay_setup_test.dart) also
rejects the replacement host after selecting the compatible core. The
focused Windows runs passed 33 tests using a local fixture room service.

The initial PS1 and PS2 room lookup has a 12-second deadline. The launcher
releases the pending attempt and lets the player accept the same invite again.
The PS1, PS2, and PS3 room recheck before admission shares that deadline.
A late lookup response cannot launch the old attempt. Room creation and
admission retain their existing cleanup path.
Before hosting or joining, the shared room client also gives the
current-session check 12 seconds. If that read stalls, the launcher
can retry while the old response is still pending. If the service
reports an existing session, the launcher tells the player to leave
it first. It makes no room changes in either case. The
[room tests](../test/core/online/ps1_netplay_rooms_test.dart) cover
host and guest retries after a stalled read, and the
[PS3 host fixture](../test/ui/ps3_settings_test.dart) verifies the
occupied-session message and that the existing room is preserved.
The focused Windows suite passed 71 tests. An existing session can be
on another device. The launcher does not assume it owns that session.
The [PS1 handoff fixture](../test/ui/ps1_netplay_setup_test.dart) and
[PS2 LAN fixture](../test/ui/ps2_lan_invite_test.dart) verify retry while the
first response is still withheld. This update passed 33 focused tests on
Windows with a local fixture room service.

PS1 netplay and PS2 LAN also bound the read-only WebRTC connection
settings request to 12 seconds after a peer joins. If it stalls, the
match takes the existing room cleanup and connection failure path.
A response from the abandoned request cannot create a link or start
the game. The [room regression tests](../test/core/online/ps1_netplay_rooms_test.dart)
hold the response past the deadline in both modes and then deliver it late.

Sending a friend invite also has a 12-second deadline. At this point the
[room client](../lib/core/online/retro_online_rooms.dart) already knows the
room it owns, so PS1, PS2 and PS3 begin releasing that room on timeout
and give the host retry guidance. Another attempt can start once
cleanup completes. The launcher sends the request once because the
service may have sent the invite before the reply was lost.
The [room test](../test/core/online/ps1_netplay_rooms_test.dart) verifies
the deadline and single request. The
[PS3 host fixture](../test/ui/ps3_settings_test.dart) also checks cleanup,
the retry message, and that a late response cannot launch the game.
The Windows room, PS3 settings and language suites passed 68 tests.

PS1 also allows 30 seconds for the WebRTC plugin to create the peer
connection before the existing signaling timer starts. If creation
times out or the player cancels, the match takes its room cleanup path.
If the plugin later returns a connection, the abandoned match closes
it before it can signal, attach a controller, or start the game.
The room tests cover both timeout and cancel with a late link. The
headless CTR control also passed 360 confirmed frames through two
local WebRTC peers after the change.

When a PS1 or PS2 connection setup deadline expires, the launcher gives the
host a prompt to invite their friend again and tells the guest to ask for
a new invite. This covers the connection settings request, PS1 peer
connection creation, PS1 signaling and preparation, and PS2 peer
channel setup. A timeout or disconnect after
play starts keeps its separate message.
The PS1 peer keeps the local timeout reason if a pending plugin call
fails while the connection closes. The wire protocol still sends its
existing leave message to the other peer.

- On a clean AnyPS5 install, set up the needed emulator inside Settings,
  select user-supplied firmware and games, and start or accept a session
  from the dashboard or Quick Menu. Report incompatible media, missing
  setup and expired invites where the player can act on them.
- Two players on separate networks each run a local copy and complete a level
  or race with their own controller. Verify invites, compatibility refusals,
  disconnects and a second session after cleanup. Qualify each supported
  route separately, including synchronized couch multiplayer, virtual LAN,
  and native online providers. A local or mocked run cannot qualify WAN play.
- In synchronized couch multiplayer, the guest's controller occupies the
  game's second controller port on both local copies. Both players see the
  game's normal shared or split-screen view. Starting another race or round
  through the game's own menu keeps the same AnyPS5 party connected.
- For a session started from a running game, verify that leaving or a
  connection failure returns the player to their original game with their
  local saves intact. Keep the other player's session usable where the
  native game mode permits it.
- Record local button-to-display latency, RTT, jitter, stalls and desyncs.
  For synchronized emulation, also record rollback depth and replay cost.
  Compare with offline local play. Local rendering removes streaming delay;
  distance and network instability still affect multiplayer.
- Show availability by verified title, core and mode. Games without a native
  or local multiplayer mode need a separate game-specific mod.
- Keep existing PS5 Play Together behavior covered by the
  [launcher session tests](../test/ui/together_test.dart).
