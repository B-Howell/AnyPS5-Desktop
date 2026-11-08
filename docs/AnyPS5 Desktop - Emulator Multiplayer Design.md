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
