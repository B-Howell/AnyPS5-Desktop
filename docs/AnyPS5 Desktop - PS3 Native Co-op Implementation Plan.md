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

### Patchwork protection checkpoint

The [Refresher 2.3.4 release](https://github.com/LittleBigRefresh/Refresher/releases/tag/v2.3.4)
bundles the [Patchwork 1.3 RPCS3 module](https://github.com/HugeSpaceship/Patchwork/releases/tag/1.3).
The extracted assembly resource matches the module's published SHA-256
`c849af910568ccfcb613917ff86371096b990c39ad5dcc51325aee3d4671440d`.
The released LBP patch steps successfully generated a wrapped GOTY
executable in scratch storage. This path is insufficient for qualification:
1.3 uses a shared lobby key to restrict joins, and its source lists blocking
P2P scripts and verifying invites as future work.
[Patchwork 1.3 source notes](https://github.com/HugeSpaceship/Patchwork/blob/6b61f8c9aa7b6ae98955a37e10ae37d068fef7e6/README.md#current-fixes)

[Patchwork 2.0 RC1](https://github.com/HugeSpaceship/Patchwork/releases/tag/2.0-rc1)
adds P2P script blocking and forged-join protection. Its RPCS3 route uses
patch YAML against the unmodified executable. The published YAML SHA-256
was `91272f665002417949de1cef825f5690834711cb110290c9156ffc542c6c3316`.
On the pinned Linux core in two offline, network-isolated boots, the
original YAML exposed no protection option for GOTY. A scratch fixture
limited to the Combined Patch mapped that same executable hash and
version to the GOTY title ID. It preserved all 26 upstream patch
instructions and included no server redirect. The core requested
`rpcs3_zpatch_0bc541a4`, applied all 26 instructions, and shut down
cleanly. Both boots used the same stock 1.30 executable and offline
network policy. This tests patch application, without testing sign-in,
invite enforcement or gameplay with another peer.

The pinned core rebuilds `patch_config.yml` from its frontend options
before boot. The launch profile now verifies the reviewed YAML and derives
the expected frontend protection options. To enable this route, the core
must verify the effective patch identity and the applied writes before
online initialization. An equal or newer base patch can take precedence
over a title patch with the same description and PPU hash, even if its
write count matches.
[Core patch-manager source](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/rpcs3/libretro/libretro_patch_manager.cpp)

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

In a Windows reviewer configuration, **Game Settings → Online Readiness →
Prepare Game Update** opens the [dashboard import panel](../lib/ui/ps3_update_panel.dart)
for a matching disc and revision. The default offline package does not expose
this action. The [managed core check](../lib/core/managed_retro.dart) requires
an explicitly configured DLL SHA-256 and the network-policy export before
the update worker can run.

The [import transaction](../lib/core/ps3_update_import.dart) identifies local
PKG files by size and SHA-256, reports missing revisions, and waits for
**Install Update** before copying anything. It rechecks the staged copies,
then publishes only the expected title, version and executable from the
staging system into the isolated `OnlineUpdates` store. A redirected store is
rejected. The [channel client](../lib/ui/ps3_update_worker.dart) reports
package counts, retries temporary status failures and requests cancellation
when the user leaves the page. It releases the lease after confirmed exit.
If exit cannot be confirmed, the staging directory stays in place for safety.
No network download or provider sign-in is part of this workflow.

The [profile verifier](../lib/core/ps3_online_profile.dart) can explicitly
prepare an empty title slot using that stored update. It first checks the
isolated paths, core, protection, firmware and account, then matches the
prepared chain to the selected disc, target version and executable digest.
The [handoff](../lib/core/ps3_update_import.dart) copies title assets into
temporary storage on the profile's volume, rejects redirected entries,
checks the copied SFO and EBOOT, and matches the complete sorted file
tree against the release digest before publishing the directory in one
rename. Existing title data is checked in place and preserved. Normal
revalidation checks the same digest and may exclude only the release's
exact game-generated file paths. It still rejects redirected entries and
unknown additions. LittleBigPlanet GOTY preserved all 33 prepared files
after the Windows boot tests and added seven files. Five matched disc
assets byte for byte, and two were generated runtime data. The tested
prepared tree digest was
`b903631d139f167e66c4caae16ca03c8335508627b714130e8d9f2f813f38bcc`.
The seven paths are evidence for a reviewed profile, pending qualification
through a complete online session. The
[profile regression](../test/core/ps3_online_profile_test.dart) covers the
explicit handoff, account failure before copy, changed assets, allowed
game output, unknown files and preservation of existing data. The
dashboard supplies the prepared chain when it recognizes the disc ID
and disc version. The release catalog remains empty pending provider
qualification.

The [transaction tests](../test/core/ps3_update_import_test.dart) cover
missing and changed packages, failed publication, cancellation and staging
isolation. The [channel tests](../test/ui/ps3_update_worker_test.dart) cover
success, cancellation, separate initialization and package errors, and
lease recovery. The [settings widget test](../test/ui/ps3_settings_test.dart)
exercises the route, visible update chain and Back focus. The production
Dart transaction also published all 11 real LittleBigPlanet GOTY packages
with the pinned Linux RPCS3 core through an isolated test adapter.

On Windows x64, the headless reviewer harness installed the locally built
core through ManagedRetro and ran the production dashboard transaction
through the native install-only host. The native worker applied all 11
packages to a scratch profile and confirmed exit and release. The
transaction published LittleBigPlanet GOTY `BCUS98208` at `01.30` with the
expected executable digest. The CLANG64 Clang/LLVM 23.1.5 build used the
pinned RPCS3 source with the frontend SPU-cache patch and v1 network policy.
The package SHA-256 was
`d44cb27a45a58631c672031c97713ea9abfef34e31b83c58353f5afabe2ef82b`
and its DLL SHA-256 was
`d0aa98b5cd54216e39790905b5af9e24f582e5ce9081b66476b02099d052f0ba`.
This run qualifies Windows update installation. The
[launch-profile checkpoint](#unarmed-launch-profile-checkpoint) records
the later Windows v2 boot tests.

## 2. Make the embedded profile honor the selected settings

**Existing seam:** [PS3 settings model](../lib/ui/ps3_settings_model.dart), [embedded launch contract](../lib/ui/embedded_retro_game.dart), [native core option handling](../windows/runner/retro_core_host.cpp) and [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch). The frontend supplies saved values for recognized boot and graphics options. Upstream network options being listed does not prove an effective network profile on launch.

1. Trace effective precedence across launcher preferences, core variables, RPCS3 config, per-title overrides and patch state. Verify how the selected core reads `rpcn.yml` and resolves its system directory. Test that a profile with missing credentials, firmware, patch or game update refuses online without changing offline files. An offline launch must still leave RPCN disabled and keep the offline P2P socket on loopback.
2. Define the narrow boot-time contract for a verified native-online profile. Apply only reviewed fields, including network enabled, PSN mode, and the title's required simulation options. Keep network configuration explicit for this launch. Validate effective XFloat settings on both sides, which the [provider FAQ](https://docs.lbpbonsai.com/faq.html) identifies as a divergence risk. Disable tuning trials and changes that affect network or emulation timing during the session. Changes already proven presentation-only can be qualified separately.
3. Use separate process, profile, system, save and config roots for each local instance. The [profile override](../lib/core/host.dart) can separate launcher roots. Also prove distinct RPCS3 network endpoints or use isolated virtual machines. Two core instances may otherwise collide on a native socket or share the same RPCN identity. If the chosen build cannot isolate those endpoints, record that as a limit of a dual-client one-PC run.

**Exit gate:** A one-PC profile probe proves option precedence, offline isolation, redacted errors and clean teardown. A single isolated embedded launch can test provider sign-in and lobby access later with an approved account. Those checks alone do not prove co-op.

### Unarmed launch-profile checkpoint

[Profile verification](../lib/core/ps3_online_profile.dart) accepts only a
cataloged provider and disc serial. It checks the updated executable, core,
public provider configuration and selected protection artifact by SHA-256.
Protection can be an SPRX module or the title's RPCS3 YAML. The YAML
preflight checks the PPU hash, disc serial, update version, patch
descriptions and instruction counts against the reviewed release. It
rejects a competing imported patch database and requires the reviewed
digest for any on-disk base database. The pinned DLL identifies the base
database it installs when the profile has none. The verifier checks that
firmware is present and that the locally stored RPCN config names the reviewed
host and supplies an account. It returns only the selected DNS, UPnP and XFloat
settings to the launcher for an SPRX release. A YAML release also carries
the exact file digest, title ID, update version, PPU hash, patch
descriptions, instruction counts and option keys. A separate system and
save root is required. The
verifier accepts the exact in-profile VFS layout written by the pinned
core so a second launch can reuse the profile. It rejects redirected
mounts, alternate VFS files and links inside the profile. The launch
bridge revalidates the profile before sending its arguments to the host.

[The launch bridge](../lib/ui/embedded_retro_game.dart) passes the verified
profile separately from graphics preferences. The
[Windows core host](../windows/runner/retro_core_host.cpp) rejects an online
launch before core initialization if the DLL lacks the versioned policy
export. Online play requires the version 3 export and a reviewed
provider certificate pin. The host never falls back to an older online
policy. The release catalog remains empty while package
and provider qualification are open. The
[network policy patch](../tool/patches/rpcs3-libretro-network-policy.patch)
applies the mode before boot and again after RPCS3 overlays global, title or
database settings. Online policy disables RPCS3's `/host_root` mount. A
normal launch asks a patched core to disable internet, RPCN and UPnP. An
older package still follows its existing offline launch path.
The [package builder](../tool/build-rpcs3-preview.sh) accepts
`--network-policy` for this variant.

The [native YAML gate](../tool/patches/rpcs3-libretro-patch-attestation.patch)
starts disconnected and resolves the reviewed title patch in its
isolated profile. It hashes one bounded read and parses those same bytes
into a fresh patch map. It enables only the reviewed title and version,
without merging the base or imported maps or inheriting mutable patch
settings. It checks the running title, version and PPU hash, then
compares successful operations by description on the main executable.
Only then can it activate the selected network policy before
`init_fxo_for_exec` initializes the NP handler. A failed check aborts
the protected PPU boot. Protected launches reject savestate and directory
scan boot paths, and virtual PPU scans skip the reviewed patch. Each new
load clears the prior attestation, and a Libretro boot cannot report
success without it. Ordinary offline launches retain the original patch
discovery. The v2
export also accepts a disconnected verification mode for headless tests.
The [native contract fixture](../tool/ps3_patch_attestation_test.cpp)
checks identity, exact per-patch counts and malformed input. Compile it
with `clang++ -std=c++20 -I <patched RPCS3 source> tool/ps3_patch_attestation_test.cpp -o attestation-test`.
Package qualification must still boot the exact release and reject a
modified file or count using the real core with networking disabled. The
fixture exercises the input contract in isolation and does not run RPCS3.
The Windows host passed the MSVC `/W4 /WX` build, and all four affected
RPCS3 translation units passed CLANG64 syntax checks using the pinned
build's include paths and defines. These checks do not qualify the
linked version 2 package.

The first linked Windows test rejected altered YAML, then remained on
the loading screen. Vulkan deferred the actual boot until its context
callback, after Libretro had already accepted the content. The version 2
core now reports the protected-boot error and requests frontend shutdown
when that deferred boot fails. The Windows runner retains the error for
the launcher after cleanup. A fresh headless run rejected both altered
YAML bytes and a wrong operation count, exited cleanly in both cases,
and showed no non-loopback endpoints in the sampled process sockets.
[Pinned patch loader](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/Utilities/bin_patch.cpp)
[Pinned PPU loader](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/rpcs3/Emu/Cell/PPUModule.cpp)

The same Windows package booted LittleBigPlanet GOTY `BCUS98208` 1.30
with the reviewed YAML in disconnected v2 verification mode. RPCS3
recorded all 26 operations and attested the patch before the game
produced Vulkan frames and audio. After a clean exit, a new process
reopened the same scratch profile, reattested the patch, and reached
video and audio in an 11.53-second start-to-exit probe. A third process
rejected a changed patch in that already verified profile and exited
without producing gameplay frames. The successful boots showed
only `127.0.0.1:3658` in sampled socket tables.
The tested archive SHA-256 was
`af51f1ec4b56405f7c9757a5404563e429414ebc4cfae416691c77f2d067f70c`
and the DLL SHA-256 was
`bfc408d6304fe3a43bd19a259cd9dc28f40496f30ce9729a8964919198a5b80c`.
This verifies boot, patch rejection and repeat launch on Windows.
Provider connection, lobby admission and co-op remain separate tests.

The same Windows DLL also passed a loopback test with the v2 network
policy enabled. The probe configured the scratch RPCN host to a listener
on `127.0.0.1`, used a loopback bind address, disabled UPnP, and
provided only synthetic account data. With the expected count set to
25, RPCS3 rejected the patch and exited without attempting a connection.
With the correct count of 26, RPCS3 logged attestation before it began
connecting, and the listener received a TLS ClientHello. Both processes
exited cleanly. Sampled emulator sockets stayed on loopback. The listener
closed at the handshake boundary, so this test did not send a login or
join a lobby.

A second loopback run used a freshly generated self-signed certificate
for an unrelated hostname. The pinned Windows client completed TLS
1.2 anyway, then waited for the RPCN protocol greeting. The listener
sent no greeting, and the core did not attempt login. This matches
the pinned client's `SSL_VERIFY_NONE` setting.
[Pinned RPCN transport](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/rpcs3/Emu/NP/rpcn_client.cpp)

The [version 3 RPCN policy](../tool/patches/rpcs3-libretro-rpcn-identity.patch)
binds the reviewed host and SHA-256 digest of the provider's DER leaf
certificate. It rejects a changed configured host before resolving it,
and a missing or mismatched certificate after TLS and before setting
`connected` or waking the RPCN packet threads. The Windows host supplies
the public host and certificate pin alongside the patch requirements.
The account credentials remain in the isolated profile. Version 1 is
offline only in this build, and version 2 is retained for disconnected
verification. Catalog pins require independent provider review before
trying a live account.

The Windows v3 loopback fixture used the RPCN protocol version 32
greeting and a synthetic account. A changed configured host reached
no listener. A mismatching certificate closed the TLS connection
without sending a login. The matching certificate allowed one
synthetic login packet, after the game patch and provider certificate
were both verified. The server supplied no login reply or lobby.
The tested archive SHA-256 was
`d472de683cb57aba711453e214a6da91420486a5d739e5cba2d492de300f8083`
and the DLL SHA-256 was
`874b90826fccd5eb162fbdbe2e48a970e21a09867d4167c8eee63f4b16ad6d51`.

A follow-up Windows headless run used the same DLL with two isolated
LittleBigPlanet GOTY 1.30 profiles and a loopback TLS and UDP fixture.
With an accepted synthetic login, RPCS3 used the returned account ID in
its first UDP signaling ping, accepted the loopback pong and resumed
signaling at a 5.5-second interval. LittleBigPlanet proceeded to
`sceNpMatching2Init2`. The fixture observed but did not answer the later
trophy-sync request. With an invalid-password reply, RPCS3 logged the
login failure, closed the TLS connection and sent no signaling ping
during the rejection check. LittleBigPlanet called
`sceNpMatching2Init2` after rejection as well, so the call alone is
insufficient as a connection signal. Both headless processes stopped cleanly.
The accepted case's TCP and UDP sockets were observed on loopback.

These checks distinguish provider authentication and UDP signaling from
both a rendered game frame and a native game join. For launcher
feedback, wait for the native signaling result before indicating the
provider connection is ready, and report a rejected login separately.
A game lobby or co-op session still needs a separate observation from
the game.

The [provider status patch](../tool/patches/rpcs3-libretro-provider-status.patch)
records the initial connection outcome at RPCS3's NP initialization
boundary. A versioned read-only export carries a numeric state and no
account data. The [Windows host](../windows/runner/retro_core_host.cpp)
samples it on the core worker. [The embedded session](../lib/ui/embedded_retro_game.dart)
interprets it independently of frame readiness and the
[Quick Menu](../lib/ui/app_model.dart) shows it only for PS3 online play.
If the export is missing, the menu reports that status is unavailable.
The state describes initial connection only. A provider connection can
drop after startup, and joining a game remains the responsibility of the
title's own multiplayer menu.

The Windows headless fixture ran three LittleBigPlanet GOTY 1.30 boots
through the production native host. The accepted login with a signaling
reply reached Ready, the rejected login reached Sign-in Rejected, and
the accepted login with its signaling reply withheld reached Signaling
Failed. Each session stopped cleanly. The test package ZIP SHA-256 was
`e45e3595a178207a9fd2bb59f5b9672a4f73b1b3cc426121a948a8a585f214ed`.
Its DLL SHA-256 was
`5a0797e062bd798e3cad0de618c0aa2e715d1436f70cb0a8183286dfc3df2108`.

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
Sequential offline and live online storage isolation and provider sign-in
remain open.

This checkpoint has no approved release entries. Before enabling a
provider, verify its native connection uses
the expected endpoint when RPCS3 reloads the config, and verify protected
profile storage through a complete isolated launch. RPCS3 can record the
RPCN account ID and display name in its detailed log after sign-in. Keep
that log private and exclude it from diagnostics before provider activation.
Then qualify a real private level using the provider's approved client setup.

## 3. Reuse party invites and hand off to the game

On Windows x64, **Game Settings → Online Readiness** opens the
[PS3 readiness page](../lib/ui/ps3_online_readiness_page.dart). It reads the
disc ID and application version from the extracted disc and separately
detects a same-title update with an executable in managed RPCS3 storage.
**Check Again** refreshes those facts without restarting the launcher.
The page distinguishes an unreadable disc, a title missing from the
reviewed release catalog, and a listed title that still needs a verified
online profile. Version detection does not authenticate the update.
For a title with one reviewed YAML release and a pinned update tree,
**Play Online** verifies the preconfigured profile at
`OnlineProfiles/<provider>/<title ID>` under managed emulator storage.
It uses a matching prepared update when the title slot is empty, reports
the first setup issue on the same action, and starts the existing embedded
game view only after verification. Leaving the page during the check
suppresses the launch. The [launch coordinator](../lib/ui/app_model.dart)
uses the verified core and isolated storage, and skips the offline
trophy watcher for this session. Joining the native room is an explicit
step in the game's online menu.

**Import Protection Patch** on the same page accepts a local YAML file
for the listed release. The [profile importer](../lib/core/ps3_online_profile.dart)
checks the exact digest before creating the isolated profile directories,
rejects redirected managed paths, and publishes the checked bytes with a
same-volume rename. A different file leaves the installed patch in place.
Importing a patch does not launch the game. Launch verification still
checks the reviewed patch structure and all other prerequisites.
The scratch Windows import verified the real 26-operation GOTY patch
in a fresh profile. The tested Windows core also generates
`patches/patch.yml` with SHA-256
`79cefe64677e4018efcfe1046825bef08427822b2fc99ff8c03d446c23473ebe`.
A release for that core needs this base pin so the verifier can reopen
the profile after the first boot.

**Import Provider Account** accepts an existing RPCN version 2
configuration whose host matches the reviewed provider. The importer
reads a bounded file and writes only the version, host, account ID,
password and token to the isolated RPCS3 profile. It rejects embedded
NULs in account fields because RPCN uses NUL-terminated fields. It
writes an empty token when the selected configuration has none and drops the
saved server list and unrelated settings. RPCS3 reads those credentials
from its local configuration, and the launcher channel receives only
the verified network policy and patch metadata. Invalid input leaves
the existing configuration intact. The action imports a local account
file. The YAML library from the pinned Windows RPCS3 build parsed the
normalized output in a scratch probe with synthetic credentials. Account
registration and provider sign-in remain separate.

**Prepare PS3 Firmware** uses the same pinned PlayStation firmware
package as ordinary setup. It reuses a verified cached package or
downloads into a disposable directory in the online profile. It checks
the copied package before publishing and leaves the offline firmware
alone. The verifier accepts the exact staged package for first launch.
The pinned core extracts it during initialization. On repeat launch,
the verifier checks the native installed-firmware marker and VSH file.
It refuses an earlier package in RPCS3's search order that could
shadow the verified package.
The Windows offscreen probe reused the real checksum-pinned PUP in a
fresh online profile with no extracted firmware. RPCS3 created both
firmware markers, booted the protected LittleBigPlanet GOTY update to
Vulkan frames and audio, and exited cleanly. The probe used disconnected
verification mode and observed only a loopback endpoint.

The [embedded session](../lib/ui/embedded_retro_game.dart) keeps RPCS3
running under the Quick Menu and sends neutral input while the menu has
focus. The protected session does not offer in-game graphics changes
or [restart trials](../lib/ui/retro_restart_workflow.dart), which would
otherwise restart with the ordinary offline launch path.

The release catalog remains empty while the provider and live-game gates
are open. The [game settings test](../test/ui/ps3_settings_test.dart)
exercises the action with a synthetic release and a fake native channel.
It checks that a missing account blocks launch, the corrected profile
passes isolated paths and protection metadata, the Quick Menu sends no
pause command, and an unlisted title has no Play Online action.

The [PS3 Friends handoff](../lib/ui/together_ps3_online.dart) opens the
[existing readiness page](../lib/ui/ps3_online_readiness_page.dart) for
both the sender and the recipient. It verifies the local game and isolated
profile before making room calls. The
[room protocol](../lib/core/online/retro_online_rooms.dart) checks title
ID, update version and a [public profile fingerprint](../lib/core/ps3_online_profile.dart).
The fingerprint covers the reviewed core, update, provider identity,
patch policy and network configuration. Room metadata excludes credentials,
paths and room keys. The recipient checks the inviter when the invite
includes their identity.

The launcher uses a private two-seat AnyTogether room. RPCS3 and the
provider handle gameplay traffic and admission to the native lobby.
Both players use the game's online menu to meet. Leaving the AnyTogether
room or receiving its end event cancels a pending launch and leaves an
already-running game open. Stopping the host's game closes the room.
Signing out or closing the launcher gives the handoff time to release
the room while the account is still available.
While the launcher opens the room, Friends focuses **Cancel PS3
invite**. Cancel releases pending read-only room checks so the player
can retry without waiting for a stale reply. Once a create or join
request has been sent, the launcher waits for its result and releases
any room it acquired before allowing another attempt. Friends shows
the closing status during that cleanup.
The [existing PS5 flow](../lib/ui/together_play.dart) remains separate.

The [PS3 settings integration tests](../test/ui/ps3_settings_test.dart)
exercise host invite, guest acceptance, profile mismatch, isolated
emulator arguments, room cleanup and the native game's continued
execution after leaving. They use local fake AnyTogether responses and
a fake native channel. Hosted room behavior and native lobby entry
remain live qualification gates. The release catalog remains empty
until a provider profile is approved and qualified.

## 4. Separate the one-PC pilot from WAN qualification

- **One PC, no external accounts:** Use fakes for provider errors and party events. Verify exact profile selection, patch/hash checks, offline networking defaults, launch readiness and redaction. Two isolated processes can test separate files and endpoints with synthetic traffic.
- **One PC, optional live pilot:** If the provider allows two test identities from one machine or public IP, and distinct endpoints and resources are available, run two isolated instances to attempt a private level. Establish a single-instance performance baseline first and record host contention. If the provider, port binding or hardware prevents that setup, defer the dual-client gameplay proof. Do not count a fake join or single-client login as co-op.
- **Two PCs on different networks:** Use approved test accounts and verified client patches. Complete a private level, test host exit, a failed join and rejoin, and confirm which native route worked. Record load, divergence, stalls and any NAT restrictions. A local or same-IP result cannot qualify public WAN play. Broaden title and provider support only after repeating the same evidence gates.

Release the first profile only after a real two-PC private level completes, the offline regression checks pass and the maintainer approves the provider, security posture and user-facing setup. Record the exact supported disc, core, update and provider profile together.
