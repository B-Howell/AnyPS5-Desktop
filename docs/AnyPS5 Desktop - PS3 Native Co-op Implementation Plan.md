# AnyPS5 Desktop PS3 native co-op implementation plan

> **Execution workflow:** Use superpowers:executing-plans after implementation is requested. This document is a plan.

**Goal:** Two invited players complete a LittleBigPlanet Game of the Year level through the game's native online mode, each using their own embedded RPCS3 session.

**Architecture:** The game and its community provider run native online play. RPCN supplies PS3 network services the selected setup requires. AnyTogether coordinates the party, checks readiness and launches each configured local copy. The first version hands players off to the game's own private lobby or join flow.

**Stack:** Windows x64, pinned patched RPCS3 Libretro, official PS3 firmware, a provider-supported game update and Patchwork profile, RPCN and AnyTogether parties.

## Choose the provider path

- **Preferred:** Qualify one provider and one exact title/update combination. Start with the [Bonsai RPCS3 setup](https://docs.lbpbonsai.com/rpcs3.html) as a documented candidate. Verify current provider eligibility, patch support and the intended private join method for the exact GOTY disc before committing to it.
- **Reference:** Establish the same title/provider flow in standalone RPCS3 using isolated profiles. Use this to distinguish provider or game issues from embedded-core integration issues. Repeat against the managed core before claiming AnyPS5 support.
- **Later option:** A separately managed private service may make sense if a provider-supported path is unavailable. Running a LittleBigPlanet backend and providing the RPCN services it expects would introduce compatibility, maintenance and security responsibilities. The first release has no new server requirement. AnyTogether does not proxy or replace native PS3 gameplay traffic.

The [RPCS3 Libretro feature table](https://docs.libretro.com/library/rpcs3/#features) lists frontend netplay and save states as unsupported. Its [network options](https://docs.libretro.com/library/rpcs3/#network) include RPCN. The [RPCN project](https://github.com/RipleyTom/rpcn) documents matchmaking services. Keep the PS1 synchronization protocol and PS2 virtual LAN out of this path.

## 1. Qualify the exact disc, update and security profile

**Read:** [PS3 disc reader](../lib/core/ps3_disc.dart), [managed core installer](../lib/core/managed_retro.dart), and the [RPCS3 package guide](<AnyPS5 Desktop - Emulator Configuration.md#build-a-ps3-test-package>).

1. Read the title ID, edition, region and installed update from the test profile. Confirm provider support for the resulting ID and patch path. Record the effective game executable/update and patch fingerprints, the DLL SHA-256, firmware version and settings that affect peer simulation. Treat a successful boot or loading the provider's website as a partial check.
2. Confirm the provider's current Patchwork and RPCN requirements. Review the [published client security advisory](https://www.lbpunion.com/post/security-advisory-about-littlebigplanet-online-play/) and the provider's current mitigations for the exact game version. Require a verified provider-specific patch before enabling online. Limit early qualification to invite-only sessions using test saves. Reject unknown patches or unsupported revisions with a clear reason.
3. Specify how the user supplies their own game, updates, firmware and RPCN setup. Store the provider profile separately from offline play and bind any account configuration to the local user. Exclude credentials, session join keys, ROMs, game updates and firmware from AnyTogether offers, logs and diagnostic exports. Preserve the user's original dump and save profile.

**Exit gate:** Record a provider-approved, reproducible test configuration and the supported join flow. Provider incompatibility or missing verified protections blocks the live trial.

## 2. Make the embedded profile honor the selected settings

**Existing seam:** [PS3 settings model](../lib/ui/ps3_settings_model.dart), [embedded launch contract](../lib/ui/embedded_retro_game.dart), [native core option handling](../windows/runner/retro_core_host.cpp) and [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch). The frontend supplies saved values for recognized boot and graphics options. Upstream network options being listed does not prove an effective network profile on launch.

1. Trace effective precedence across launcher preferences, core variables, RPCS3 config, per-title overrides and patch state. Verify how the selected core reads `rpcn.yml` and resolves its system directory. Test that a profile with missing credentials, firmware, patch or game update refuses online without changing offline files. An offline launch must still leave RPCN disabled and keep the offline P2P socket on loopback.
2. Define the narrow boot-time contract for a verified native-online profile. Apply only reviewed fields, including network enabled, PSN mode, and the title's required simulation options. Keep network configuration explicit for this launch. Validate effective XFloat settings on both sides, which the [provider FAQ](https://docs.lbpbonsai.com/faq.html) identifies as a divergence risk. Disable tuning trials and changes that affect network or emulation timing during the session. Changes already proven presentation-only can be qualified separately.
3. Use separate process, profile, system, save and config roots for each local instance. The [profile override](../lib/core/host.dart) can separate launcher roots. Also prove distinct RPCS3 network endpoints or use isolated virtual machines. Two core instances may otherwise collide on a native socket or share the same RPCN identity. If the chosen build cannot isolate those endpoints, record that as a limit of a dual-client one-PC run.

**Exit gate:** A one-PC profile probe proves option precedence, offline isolation, redacted errors and clean teardown. A single isolated embedded launch can test provider sign-in and lobby access later with an approved account. Those checks alone do not prove co-op.

### Unarmed launch-profile checkpoint

[Profile verification](../lib/core/ps3_online_profile.dart) accepts only a
cataloged provider and disc serial. It checks the updated executable, core,
provider module and public provider configuration by SHA-256. It checks that
firmware is present and that the locally stored RPCN config names the reviewed
host and supplies an account. It returns only the selected DNS, UPnP and XFloat
settings to the launcher. A separate system and save root is required. The
verifier rejects links in that root and VFS overrides, which can redirect
RPCS3 to another profile.

[The launch bridge](../lib/ui/embedded_retro_game.dart) passes the verified
profile separately from graphics preferences. The
[Windows core host](../windows/runner/retro_core_host.cpp) rejects an online
launch before core initialization if the DLL lacks the versioned policy
export. The [network policy patch](../tool/patches/rpcs3-libretro-network-policy.patch)
applies the mode before boot and again after RPCS3 overlays global, title or
database settings. A normal launch asks a patched core to disable internet,
RPCN and UPnP. An older package still follows its existing offline launch path.
The [package builder](../tool/build-rpcs3-preview.sh) accepts
`--network-policy` for this variant.

The [profile tests](../test/core/ps3_online_profile_test.dart) use synthetic
files. The [mock-channel boot test](../test/ui/ps3_online_boot_test.dart)
checks that a normal launch uses its original system and saves and sends
no online profile. Run both with
`flutter test test/core/ps3_online_profile_test.dart test/ui/ps3_online_boot_test.dart`.
These checks do not observe a game process or its sockets. The patched
RPCS3 translation units were syntax-checked against the pinned build flags.
A packaged runtime test still needs to prove effective options, rejected
redirected storage and no public network connection during offline play.
RPCS3 permits local traffic in its disconnected mode.

This checkpoint has no approved release entries or launcher action that starts
an online game. Before enabling a provider, verify its native connection uses
the expected endpoint when RPCS3 reloads the config, and verify protected
profile storage through a complete isolated launch. Then qualify a real
private level using the provider's approved client setup.

The LittleBigPlanet GOTY fixture is `BCUS98208`, with disc application
version `01.18`. Its installed game-data directory had no update executable
or application version. Patchwork's [current LBP1 definition](https://github.com/HugeSpaceship/Patchwork/blob/HEAD/lbpdefs/lbp1.yaml)
targets `01.30` and omits `BCUS98208`. This fixture needs a provider-approved
update and matching executable before online qualification.

## 3. Reuse party invites and hand off to the game

1. Use the shared lifecycle in the [multiplayer design](<AnyPS5 Desktop - Emulator Multiplayer Design.md>). Advertise a verified `ps3-native` mode with title/update, provider profile version and compatibility policy. The party service handles admission to the AnyTogether session. The game and provider decide admission to the native lobby.
2. **Host** opens an AnyTogether offer and launches the configured local title. **Join** checks the guest's setup and launches it into the same supported provider flow. In v1 guide both players through the game's join steps. Use a supported provider join token or launch interface only if confirmed. Keep credentials and private room keys outside the general party metadata.
3. Keep launcher progress distinct from game state. Report local preflight and launch readiness from observed facts. A player joining the AnyTogether party is not proof they joined the game. Verify native room membership through supported evidence or a player confirmation. Test unavailable provider, sign-in refusal, mismatched patch, stale invite, cancellation and host exit with fakes. Verify PS5 still follows the [existing Play Together path](../lib/ui/together_play.dart).

**Exit gate:** The one-PC fake-service tests cover compatibility, invitation, launch and cleanup. The UI distinguishes party join, native game join and a game that merely launched.

**Planned regression test:** `test/ui/ps3_online_profile_test.dart` should
assert that a wrong patch or missing update blocks the online launch while
offline launch remains available. Add a private harness receipt for the
effective core options and a test confirming native join is never inferred
from process start. Run
`flutter test test/ui/ps3_online_profile_test.dart test/ui/ps3_settings_test.dart test/core/managed_retro_test.dart`
once the new suite exists. Use fake account values in fixtures.

## 4. Separate the one-PC pilot from WAN qualification

- **One PC, no external accounts:** Use fakes for provider errors and party events. Verify exact profile selection, patch/hash checks, offline networking defaults, launch readiness and redaction. Two isolated processes can test separate files and endpoints with synthetic traffic.
- **One PC, optional live pilot:** If the provider allows two test identities from one machine or public IP, and distinct endpoints and resources are available, run two isolated instances to attempt a private level. Establish a single-instance performance baseline first and record host contention. If the provider, port binding or hardware prevents that setup, defer the dual-client gameplay proof. Do not count a fake join or single-client login as co-op.
- **Two PCs on different networks:** Use approved test accounts and verified client patches. Complete a private level, test host exit, a failed join and rejoin, and confirm which native route worked. Record load, divergence, stalls and any NAT restrictions. A local or same-IP result cannot qualify public WAN play. Broaden title and provider support only after repeating the same evidence gates.

Release the first profile only after a real two-PC private level completes, the offline regression checks pass and the maintainer approves the provider, security posture and user-facing setup. Record the exact supported disc, core, update and provider profile together.
