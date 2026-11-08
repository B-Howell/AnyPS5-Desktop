# AnyPS5 Desktop PS2 LAN implementation plan

> **Execution workflow:** Use superpowers:executing-plans after implementation is requested. This document is a plan.

**Goal:** Two players finish a Gran Turismo 4 LAN race from separate networks, each running and rendering their own PS2 copy in AnyPS5.

**Architecture:** Gran Turismo 4 uses its own LAN multiplayer protocol. Each LRPS2 instance presents an emulated Ethernet adapter to the game. A private, per-match virtual LAN carries only that match's traffic. AnyTogether coordinates the invitation and connects the peers. The player who hosts in the game's LAN menu remains the race host.

**Stack:** Windows x64, pinned LRPS2, DEV9, the embedded runner, AnyTogether game sessions and WebRTC data channels.

## Test titles

Use Gran Turismo 4 first. Its two-player split-screen mode checks both
controller ports in one instance. Its native LAN mode checks discovery,
hosting, joining and racing with two separately rendered copies. The same
LAN path can be tested on one PC and then carried over an isolated internet
link without a matchmaking service. [Sony's release announcement](https://sony.mediaroom.com/2005-02-22-Gran-Turismo-4-for-PlayStation-2-Hits-Stores-Nationwide) · [Official LAN manual](https://www.gran-turismo.com/local/jp/data1/pdf/gt4_lan.pdf)

For a separate test of an original game's Internet menu and a replacement
matchmaking service, use the PS2 version of Star Wars Battlefront II (2005).
The [server operator's PS2 guide](https://www.swbfii.com/ps2/online) and
[SWBFSpy implementation](https://github.com/SWBFSpy/SWBFSpy) describe that
path. Qualify it separately from the Gran Turismo 4 virtual LAN.

### Local Gran Turismo 4 media fixture

The local NTSC-U v2.00 dump is identified as `SCUS_973.28` and lives under
`D:\PS2\Gran Turismo 4\Gran Turismo 4 (USA) (v2.00)`. Its folder contains
the original ISO plus the user-provided `cover.webp` and `wallpaper.png`.
`retro.json` in that same folder points to the disc and local artwork, and
`theme-48k-loop.wav` is a local library-music asset. The AnyPS5 scanner reads
that manifest and resolves all media paths relative to the game directory.

The music was extracted offline from the game's own `GT4.VOL` using the
open-source [GT4FS volume extractor](https://github.com/Razer2015/GT4FS),
then decoded from the streamed `gt4qm-01` ADS menu track with
[vgmstream](https://github.com/vgmstream/vgmstream) and made loopable as
48 kHz stereo WAV. The [GT4 volume-format notes](https://nenkai.github.io/gt-modding-hub/formats/volume/ps2_gt4_volume/)
describe the archive layout. The source ISO was not modified. Track naming
in `bgmads.inf` identifies this as the GT4 quick/menu music; it does not
provide a more descriptive song title.
These files are machine-local test assets and must not be included in source
control or redistributed with AnyPS5. A headless call to
[GameLibrary.scan](../lib/core/game_library.dart) on the review checkpoint
found one PS2 title, `PS2-SCUS97328`, and resolved the disc, both images,
and the WAV. A one-PC two-instance race remains the LAN exit gate below.

## Choose the transport after a native LAN baseline

- **Preferred embedded path:** Use a small adapter at LRPS2's DEV9 network boundary. Carry the Ethernet frames required by the title across an isolated virtual segment. Verify the pinned build exposes a usable boundary first. A core patch is a separate maintainer and distribution decision if the shipped DLL lacks one.
- **Reference path:** Use standalone PCSX2 with its supported DEV9 configuration on an isolated virtual segment to establish what the title does. This is a diagnostic comparator. Installing a system driver or bridging to a real LAN needs its own implementation decision.
- **Existing sockets backend:** Qualify it if both host and guest can discover and race with that backend. The standalone [PCSX2 DEV9 report](https://pcsx2.net/blog/2023/q1-2022-progress-report/#dev9) distinguishes socket joining from TAP/Pcap hosting. A working guest connection alone does not qualify the backend for hosting.

The [LRPS2 build source](https://github.com/libretro/ps2/blob/master/Makefile.common) contains DEV9, and [its CMake configuration](https://github.com/libretro/ps2/blob/master/CMakeLists.txt) makes PCAP opt-in. That establishes source capabilities. Check the exact AnyPS5 Windows artifact and its options separately. The [LRPS2 feature table](https://docs.libretro.com/library/lrps2/#features) lists frontend netplay as unsupported. This plan uses the game's own networking, with no PS1-style frame replay.

## 1. Pin a title and inventory the actual core

**Read:** [ManagedRetro](../lib/core/managed_retro.dart), [native runner](../windows/runner/retro_core_host.cpp), and the [Gran Turismo 4 LAN manual](https://www.gran-turismo.com/local/jp/data1/pdf/gt4_lan.pdf).

1. Confirm an available GT4 disc revision with LAN mode. Record title ID, region, revision and disc content hash. Pin the core DLL hash and source revision, BIOS, title options and memory-card policy. Start with matching content and core builds to remove variables. Broaden compatibility only with evidence.
2. Determine whether the pinned core can enable DEV9 Ethernet, select the transport, and assign a distinct guest network identity per process. Capture the effective configuration and backend initialization. A legacy setting in [the PCSX2 template](../assets/retro/pcsx2.ini) is not evidence that the embedded DLL uses it.
3. Trace discovery and match traffic with two separate local processes and isolated profiles on a private segment. Start from the documented host and join menus. Verify IP setup, discovery, session establishment, a complete race and a rematch. Record packet types, address behavior and timeouts. Treat requirements such as broadcast, ARP, DHCP, unicast and packet sizes as findings to measure.

**Exit gate:** Both copies finish a native LAN race on the same PC, or the probe identifies the first missing capability. If standalone works and embedded fails, narrow the core change before adding any AnyTogether integration.

## 2. Prove a private segment on one PC

**Planned seam:** A DEV9-facing packet adapter in the selected core or native bridge, and a transport-independent `lib/core/online/retro_lan_transport.dart` in the launcher. Confirm the core boundary before naming native files. Reuse [OnlinePeerMesh](../lib/core/online/online_peer_mesh.dart) at its peer connection boundary. Keep the PS5 virtual socket wire format separate from the PS2 payload.

1. Run two isolated game workers with distinct virtual identities. Connect their packet adapters through an in-memory switch or authenticated local IPC. Assign a bounded queue to each endpoint. Tie addresses to the session and member, and reserve broadcast delivery to members of that segment. Match the title's observed addressing and discovery behavior. Expose only the needed guest networking functions.
2. Add fixtures for the observed discovery exchange and match traffic. Refuse oversized or malformed frames, spoofed source identity, stale epochs and packets for a different match. Test unicast, required broadcast, frame ordering behavior, queue overflow and teardown. Keep traffic off the physical LAN and keep host interfaces, DNS and firewall settings outside the adapter.
3. Prove discovery and a full race over that segment. Inject delay, jitter, duplication, loss and an abrupt disconnect. Record discovery time, time to race start, RTT, packet sizes and rates, stalls, drop counts and clean recovery. Compare the result with the native LAN baseline. The game's protocol handles gameplay timing and any retransmission. Preserve the delivery behavior it needs instead of putting every frame on a reliable ordered queue.

**Exit gate:** Two local copies complete repeated races over the same transport contract intended for internet play. A bad or expired session cannot receive or transmit frames. Host exit leaves a clean adapter and profile. No second computer is required for this gate.

## 3. Wire the match to Play Together

1. Reuse the shared match lifecycle in the [multiplayer design](<AnyPS5 Desktop - Emulator Multiplayer Design.md>). Add a verified `ps2-lan` mode and allowlist the exact supported title revision. The compatibility descriptor identifies the title, mode and any backend/protocol version required to join. Keep the existing PS5 session contract stable.
2. On **Host**, create the party session and the virtual segment, start the local game and guide the player to the game's LAN host menu. On **Join**, verify the local copy, join the segment and guide the player to LAN discovery. Keep launch failure, no discovered host and lost connection distinct. Limit the first release to two invited peers. Approve relay use with the maintainer before a WAN trial.
3. Use a fake AnyTogether service and two peer endpoints for tests. Cover mismatched titles, duplicate join, an invalid peer, host exit during startup, and cancellation from each state. Use the existing [join verdict tests](../test/core/play_together_test.dart) and [mesh tests](../test/core/online/online_peer_mesh_test.dart) as regression controls. Verify that leaving tears down the segment and ordinary PS2 play still starts with its offline defaults.

**Exit gate:** The launcher lifecycle works with fakes and the one-PC game harness. No paid hosting is required for these proofs.

**Planned regression test:** `test/core/online/retro_lan_transport_test.dart`
should assert that discovery reaches the invited peer while the same frame
from an unassigned address or previous epoch reaches neither worker. Add a
party test for cancellation before game launch. Run
`flutter test test/core/online/retro_lan_transport_test.dart test/core/online/online_peer_mesh_test.dart test/core/play_together_test.dart`
once the new suite exists. Keep real title data in the private harness.

## 4. Qualify internet play before release

Use two Windows PCs on separate networks. Complete full races on direct and approved relayed routes, then disconnect and rematch. Record delay and stalls against the local baseline and specify which title revision and backend passed. A one-PC pass cannot establish real NAT traversal, independent machine load or an acceptable WAN experience. Games without a supported LAN mode stay outside the title allowlist. Native PS2 games that rely on an online service need their own provider and title qualification.
