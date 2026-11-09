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

### Private LittleBigPlanet server

[Refresh](https://github.com/LittleBigRefresh/Refresh#-running) is a
self-hostable LittleBigPlanet server with a standalone release and a
Docker Compose deployment. Start a qualification instance with a pinned
release such as [Refresh v3.7.2](https://github.com/LittleBigRefresh/Refresh/releases/tag/v3.7.2),
fresh persistent storage, and the game service bound only to
loopback or a private test network. Verify `/_health` and the configured
`/lbp` endpoint before trying the game. The
[upstream Compose example](https://github.com/LittleBigRefresh/Refresh/blob/v3.7.2/docker-compose.yml)
publishes port 10061 by default, so set an explicit private bind for the
pilot.

Once the exact title update and protected client patch qualify, point the
isolated client profile at the private server using
[Refresher AutoDiscover and Patchwork](https://docs.lbpbonsai.com/rpcs3.html).
Give both players compatible RPCN setup and the same private lobby key.
Check native sign-in, lobby entry, a completed level, and reconnect before
offering the server to invited users. The lobby key and RPCN account data
stay outside AnyTogether invitations.

AnyPS5 should initially manage the selected server URL, readiness and
invitation flow. Run the service independently so a player closing AnyPS5
does not end the server for others. Hosted accounts, levels and persistence
belong to Refresh. RPCN and game-native gameplay connectivity are separate
from hosting the Refresh HTTP service.

## 1. Qualify the exact disc, update and security profile

**Read:** [PS3 disc reader](../lib/core/ps3_disc.dart), [managed core installer](../lib/core/managed_retro.dart), and the [RPCS3 package guide](<AnyPS5 Desktop - Emulator Configuration.md#build-a-ps3-test-package>).

1. Read the title ID, edition, region and installed update from the test profile. Confirm provider support for the resulting ID and patch path. Record the effective game executable/update and patch fingerprints, the DLL SHA-256, firmware version and settings that affect peer simulation. Treat a successful boot or loading the provider's website as a partial check.
2. Confirm the provider's current Patchwork and RPCN requirements. Review the [published client security advisory](https://www.lbpunion.com/post/security-advisory-about-littlebigplanet-online-play/) and the provider's current mitigations for the exact game version. Require a verified provider-specific patch before enabling online. Limit early qualification to invite-only sessions using test saves. Reject unknown patches or unsupported revisions with a clear reason.
3. Specify how the user supplies their own game, updates, firmware and RPCN setup. Store the provider profile separately from offline play and bind any account configuration to the local user. Exclude credentials, session join keys, ROMs, game updates and firmware from AnyTogether offers, logs and diagnostic exports. Preserve the user's original dump and save profile.

**Exit gate:** Record a provider-approved, reproducible test configuration and the supported join flow. Provider incompatibility or missing verified protections blocks the live trial.

The local LittleBigPlanet GOTY disc reports `BCUS98208` at `01.18`.
The same-title data directory has no updated executable or `APP_VER`.
The PlayStation title-update manifests advertise `01.30` for both the GOTY
disc and the standard US disc `BCUS98148`. An isolated, static comparison
confirmed that both update packages have the expected title ID and `01.30`
in their own `PARAM.SFO`. The packaged SELF files differ, but RPCS3's
decrypter produced byte-identical PPU ELFs. Both matched the executable hash
in the [pinned Patchwork profile](https://github.com/HugeSpaceship/Patchwork/blob/452690c29cac8dd4250d488c13008ae06f80d358/lbpdefs/lbp1.yaml).

| Artifact | SHA-256 |
| --- | --- |
| `BCUS98208` update 01.30 PKG | `a3dbaa8e9efb2dc986181202429dd1d3d6d2dbf5c637ff2a232535720e63b925` |
| `BCUS98148` update 01.30 PKG | `e3cb37312a3ab234db277bf8a293cc39fcc1e81f587d20f6474e7be85246bbd7` |
| Decrypted PPU ELF from either package | `686ad6a29d92cf71e7eca9a18765018580a0a3baa89e2f6b24c76c1a98c70ab9` |

The comparison checked package size and the manifest SHA-1 against the
package body and footer, then read only `PARAM.SFO` and `USRDIR/EBOOT.BIN`.
It ran the pinned core's `decrypt_self` in a network-isolated process without
starting the guest. The PPU hash was computed from ELF program headers and
loadable segment data using the [pinned RPCS3 algorithm](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/rpcs3/Emu/Cell/PPUModule.cpp#L2346-L2420).
The manifest endpoint did not validate against the system TLS trust store
and the package URLs used HTTP. The recorded hashes identify the inspected
samples and do not establish download authenticity for a product installer.

Patchwork's generated RPCS3 patch also filters by title ID, and its list
includes `BCUS98148` but omits `BCUS98208`.
[Patch generator](https://github.com/HugeSpaceship/Patchwork/blob/452690c29cac8dd4250d488c13008ae06f80d358/tools/patch_generator/rpcs3_patch/helpers.go#L69-L89)
The matching ELF establishes a candidate for provider qualification. Keep
the GOTY title ID and its own update data. Enable online only after verifying
that the provider-approved protection loads for that title ID and the
isolated native lobby test passes.

### Embedded update installation checkpoint

On the pinned Linux x64 network-policy core, an install-only Libretro probe
opened each package via `retro_load_game` without calling `retro_run`.
The probe set the system and save directories to an empty scratch profile,
selected offline policy, and ran each invocation in a separate network
namespace with the input package mounted read-only. The final package alone
failed because it requires installed version `01.28`. Starting with an
empty profile, all eleven packages installed in order from `01.19` through
`01.28`, then `01.30`. Each returned success with zero video and audio
callbacks. The socket traces recorded no Internet bind, connect or send
calls during installation. The rejected install left no update executable.
The tested chain totaled 466,960,160 bytes. The SHA-256 of the eleven raw
package SHA-256 digests concatenated in installation order was
`8aa306ac11d0d485d126bf8210c507ad861108224d4830cc1b2b30ac7af94a65`.

The resulting `dev_hdd0/game/BCUS98208` contained the expected `01.30`
`PARAM.SFO` and executable. Both matched the files independently extracted
from the final package. A separate disc launch with the same scratch
profile and copied firmware found that update, reported `APP_VER=01.30`
and logged the expected Patchwork PPU hash. The game produced video and
non-silent audio, changed its output from 1280×720 to 1920×1080 during
play, and stopped cleanly. The traced Internet socket calls stayed on
loopback. The installed profile and original disc were untouched.
The probe used core SHA-256
`12f8905517226005767c03b663bab5ca2da9dbc8e0c452bdbd8bed6fda4d67c3`.

The same 11-package chain also succeeded in one RPCS3 initialization,
calling `retro_load_game` and `retro_unload_game` for each package. The
[Windows host](../windows/runner/retro_core_host.cpp) now exposes a separate
`installPs3Packages` operation on its existing emulator channel. Before
calling it, the dashboard must verify the DLL digest and copy the reviewed
packages to its own staging directory. The method takes the verified core
path, the fresh staging root and the package count.
The host requires empty `system` and `saves` directories and exactly the
numbered files `packages/0.pkg` onward. It rejects linked packages and
extra files, including license sidecars. It selects offline network policy
before core initialization and reserves the embedded emulator until release.
The operation registers no texture and calls no gameplay frame function.
`ps3PackageStatus` reports how many packages finished. Stop takes effect
between packages, and a rejected package leaves the count at the preceding
successful package. The [batch test](../windows/runner/tests/ps3_package_batch_test.cpp)
checks order, failure and cancellation through the
[batch loop](../windows/runner/ps3_package_batch.h).
The production batch loop also installed all 11 packages through the pinned
Linux core with zero video and audio callbacks and the expected final
executable digest.
The Windows host compiled with MSVC `/W4 /WX`. A headless method-channel
probe loaded a fixture DLL with no `retro_run` export, verified success,
mid-chain rejection and cancellation, and confirmed that another game
cannot start until the installer releases the core. It also verified
rejection of linked packages, extra files, embedded NULs and an occupied
staging system directory. The actual RPCS3 Windows package remains an
acceptance gate.

The dashboard importer should resolve the complete reviewed update chain
before offering Install, then run the package operation without a gameplay
surface. Install into a fresh staging profile, confirm the installed title,
version and executable fingerprint, and only then make it available to
online setup. If a package fails, report its required version and keep the
previous profile usable. Qualify this flow with the Windows core before
exposing it in Game Settings. The host count identifies the failed package
in the reviewed chain. The caller is responsible for validating package
digests, presenting the dependency information and promoting the staged
title data after success.

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
verifier accepts the exact in-profile VFS layout written by the pinned
core so a second launch can reuse the profile. It rejects redirected
mounts, alternate VFS files and links inside the profile. The launch
bridge revalidates the profile before sending its arguments to the host.

[The launch bridge](../lib/ui/embedded_retro_game.dart) passes the verified
profile separately from graphics preferences. The
[Windows core host](../windows/runner/retro_core_host.cpp) rejects an online
launch before core initialization if the DLL lacks the versioned policy
export. The [network policy patch](../tool/patches/rpcs3-libretro-network-policy.patch)
applies the mode before boot and again after RPCS3 overlays global, title or
database settings. Online policy disables RPCS3's `/host_root` mount. A
normal launch asks a patched core to disable internet, RPCN and UPnP. An
older package still follows its existing offline launch path.
The [package builder](../tool/build-rpcs3-preview.sh) accepts
`--network-policy` for this variant.

The [profile tests](../test/core/ps3_online_profile_test.dart) use synthetic
files to verify safe reopening, artifact hashes and the isolated online
launch arguments. The [offline boot test](../test/ui/ps3_online_boot_test.dart)
checks that a normal launch uses its original system and saves and sends
no online profile. Run both with
`flutter test test/core/ps3_online_profile_test.dart test/ui/ps3_online_boot_test.dart`.
The Windows host compiled with MSVC `/W4 /WX`. A patched Linux x64 core
built from the pinned source and exported the versioned selector. In two
headless LittleBigPlanet boots with the same scratch profile, global and
title configs requested internet, RPCN and UPnP. Mode 0 overrode those
settings on both launches. Both runs rendered frames, produced audio and
stopped cleanly. The selector rejected changes during play and accepted
selection after shutdown. A socket trace captured one loopback bind per
run and zero non-loopback Internet socket connects or sends inside the
isolated network namespace. The tested Linux core SHA-256 was
`12f8905517226005767c03b663bab5ca2da9dbc8e0c452bdbd8bed6fda4d67c3`.
The packaged Windows core, sequential offline and online storage
isolation, and live provider sign-in remain open.

This checkpoint has no approved release entries or launcher action that starts
an online game. Before enabling a provider, verify its native connection uses
the expected endpoint when RPCS3 reloads the config, and verify protected
profile storage through a complete isolated launch. RPCS3 can record the
RPCN account ID and display name in its detailed log after sign-in. Keep
that log private and exclude it from diagnostics before provider activation.
Then qualify a real private level using the provider's approved client setup.

## 3. Reuse party invites and hand off to the game

On Windows x64, **Game Settings → Online Readiness** opens a read-only
[PS3 readiness page](../lib/ui/ps3_online_readiness_page.dart). It reads the
disc ID and application version from the extracted disc and separately
detects a same-title update with an executable in managed RPCS3 storage.
**Check Again** refreshes those facts without restarting the launcher.
The page distinguishes an unreadable disc, a title missing from the
reviewed release catalog, and a listed title that still needs a verified
online profile. Version detection does not authenticate the update. The
page creates no profile and opens no network connection. The release
catalog remains empty while the provider and live-game gates are open.
The [game settings test](../test/ui/ps3_settings_test.dart) covers the
entry, refreshed update, missing disc, and return to the same game.

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
