# AnyPS5 Desktop emulator multiplayer design

## Product direction

Use AnyTogether's **Play Together** to invite friends into a game session.
Every player launches a compatible local copy, renders locally, and plays
through their own controller. The session exchanges game traffic or frame
inputs. The streaming path is outside this design.

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

The [current PS1 match controller](../lib/core/online/ps1_netplay_match.dart)
and [embedded runner](../lib/ui/ps1_netplay_runner.dart) boot both copies
together. Joining an existing game needs a separate bootstrap path. Verify
the guest's copy and core before touching the running game. At an agreed
frame boundary, capture the host state, give the guest a bounded verified
checkpoint and keep a bounded history of subsequent inputs. Let the guest
catch up before assigning its seat. If capture, transfer, restore or catch-up
fails, close the pending invitation and continue the host's game. A guest
leaving returns their controller to neutral. Keep guest saves isolated and
keep local paths and unrelated save data out of the payload.

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

Portable snapshots can contain memory-card data. Treat this probe's
snapshots as trusted local artifacts and use isolated cards. Live transfer
needs an explicit card-sharing policy and a validated bootstrap in the
match controller before it can be exposed in the Quick Menu.

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
than waiting for all three. The plans require no hosted service, build or live
test during design. Keep multiplayer work separate from PR #84.

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
a second tester is available. Keep this as a design until implementation is
requested.

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
Then add an AnyTogether invitation that launches the configured title and
guides players to the same session. Automate room joining only if the game
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

## Acceptance before exposing Play Together

- Two players on separate networks each run a local copy and complete a level
  or race with their own controller. Verify invites, compatibility refusals,
  disconnects and a second session after cleanup.
- Record local button-to-display latency, RTT, jitter, stalls and desyncs.
  For synchronized emulation, also record rollback depth and replay cost.
  Compare with offline local play. Local rendering removes streaming delay;
  distance and network instability still affect multiplayer.
- Show availability by verified title, core and mode. Games without a native
  or local multiplayer mode need a separate game-specific mod.
- Keep existing PS5 Play Together behavior covered by the
  [launcher session tests](../test/ui/together_test.dart).
