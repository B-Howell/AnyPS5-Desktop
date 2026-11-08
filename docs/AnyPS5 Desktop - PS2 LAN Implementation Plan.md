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

### Local backend probe (2026-11-08)

The available Windows LRPS2 artifact was inspected without starting AnyPS5 or
the game. Its SHA-256 is
`47FFAEDBAA0D488039FEDA57D9C8E57FFD3FB97626E67AF4780F9219E2BD901C`.
It exposes `pcsx2_dev9_eth` as the DEV9 Sockets backend. The binary contains
the diagnostic messages `TAP backend not present in this core` and `PCAP
backend not built into this core, use the Sockets api`. The source behavior is
explicit in upstream [`net.cpp`](https://github.com/libretro/ps2/blob/master/pcsx2/DEV9/net.cpp#L180-L212):
TAP is absent, PCAP is conditional on `HAVE_PCAP`, and Sockets constructs a
`SocketAdapter`. The current [`Makefile.common`](https://github.com/libretro/ps2/blob/master/Makefile.common#L1880-L1986)
always includes the socket implementation and includes `pcap_io.cpp` only
when `HAVE_PCAP` is set. The exact DLL reports ParaLLEl PS2
`v2.0.0-da5b07e` through Libretro system info. The
[reported revision](https://github.com/libretro/parallel-ps2/commit/da5b07ebebc18016e1ca5b401188a283971a0e8d)
is the starting point for a patched core build. The hash identifies the
distributed binary independently of that version string.

PCSX2's [DEV9 report](https://pcsx2.net/blog/2023/q1-2022-progress-report/#dev9)
says the Sockets backend can join a LAN game hosted by hardware or by a PCSX2
instance using TAP/PCAP, while hosting through Sockets is unsupported. This
artifact therefore cannot host the reference LAN needed for the one-PC GT4
baseline. No emulator, game, driver, firewall, or desktop state was changed,
and no race was attempted. This is a backend capability blocker, not a GT4
compatibility result.

The upstream extension seam is concrete: [`NetAdapter`](https://github.com/libretro/ps2/blob/master/pcsx2/DEV9/net.h#L78-L124)
defines Ethernet `NetPacket` send/receive plus wake/wait and internal-server
hooks; [`net.cpp`](https://github.com/libretro/ps2/blob/master/pcsx2/DEV9/net.cpp#L80-L128)
receives packets on the DEV9 RX thread and hands them to emulated SMAP, and
[`GetNetAdapter`](https://github.com/libretro/ps2/blob/master/pcsx2/DEV9/net.cpp#L180-L212)
is the backend factory. A custom `NetAdapter` can carry complete Ethernet
frames over a private local IPC link to an in-memory switch, with broadcast
confined to the match. This does not require TAP, PCAP, a host NIC, or an OS
driver. Each core process must have an isolated endpoint and guest identity;
the launcher/host must own segment membership, bounded queues, and teardown.
This is an implementation path to test, not an existing LRPS2 feature.

WSL Ubuntu was available for headless socket work. A process-to-process UDP
echo on `127.0.0.1` passed with a 13-byte payload and required no host network
interface configuration or firewall change. That only verifies the local IPC
building block; it does not verify the proposed adapter, DEV9 integration, or
a GT4 race. The repo does not contain the LRPS2 source checkout, so building a
patched core and exercising this adapter still requires checking out
the reported revision and coordinating the full core build. For a headless game harness,
the core's `Software (SW)` renderer can avoid the production frontend's D3D11
context; a separate libretro runner must supply the BIOS, isolated system/save
directories, and deterministic synthetic controller input. At this source-only
checkpoint, none of those game-run gates had passed yet.

### WSL isolated PCAP feasibility (2026-11-08)

The existing WSL 2 Ubuntu instance (kernel `6.18.33.2-microsoft-standard-WSL2`)
supports an unprivileged user and network namespace. Inside
`unshare --user --map-root-user --net`, an ephemeral veth pair was created;
libpcap opened one endpoint, and `pcap_sendpacket`/capture delivered a 37-byte
broadcast Ethernet frame to the other. The namespace supplied the required
`CAP_NET_ADMIN` and `CAP_NET_RAW` without `sudo` or host network changes. The
namespace and veth pair disappeared when the probe exited. This is a stronger
transport check than localhost UDP: the host kernel can provide a private,
driver-free Ethernet segment usable by PCAP.

That path matches upstream PCSX2's [PCAPAdapter](https://github.com/PCSX2/pcsx2/blob/master/pcsx2/DEV9/pcap_io.cpp#L261-L307),
which opens its selected interface with `pcap_open_live`, and sends full
frames through [`pcap_sendpacket`](https://github.com/PCSX2/pcsx2/blob/master/pcsx2/DEV9/pcap_io.cpp#L137-L179).
Its Linux diagnostics state that PCAP needs `CAP_NET_RAW` and `CAP_NET_ADMIN`;
the rootless namespace probe exercised both. PCSX2's
[`ENABLE_SETCAP`](https://github.com/PCSX2/pcsx2/blob/master/cmake/BuildParameters.cmake#L903-L910)
build option defaults off, so this route does not need to grant capabilities
to a host-installed executable when the process runs inside that namespace.
The upstream source says raw packet capture is unavailable in its Flatpak
build; use a native or AppImage build for this path ([official Linux running
guide](https://pcsx2.net/docs/setup/running/)).

At the time of this initial probe, the local WSL environment had no standalone
PCSX2 or Xvfb. It had the libpcap runtime but not its development header. WSLg's
`DISPLAY` and `WAYLAND_DISPLAY` were set, but neither was used. The kernel and
libpcap checks passed, while game-level testing had not started. The follow-up
below records the later private AppImage run.

### Official PCSX2 headless two-peer gate (2026-11-08)

I fetched the official [PCSX2 v2.8.2 release](https://github.com/PCSX2/pcsx2/releases/tag/v2.8.2)
x64 Linux Qt AppImage into owned WSL scratch
`/tmp/anyps5-gt4-fOqRtVew/downloads` and verified its SHA-256 against the
official release digest:
`0c46bb6a88aa2782b10853a7b07cf3387ba99cbef2b966372cd2315b8571abea`. I
extracted the AppImage and downloaded/extracted Xvfb, xdotool, xwd and Mesa
packages into the same scratch area using `apt download` and `dpkg-deb -x`;
nothing was installed and no host display, driver, firewall, service or system
configuration was changed. I explicitly unset the WSLg display variables and
used two private TCP-only Xvfb displays, one per peer, with Mesa llvmpipe and
muted audio. Screenshots came from those Xvfb displays only.

The game fixture was opened read-only from
`D:\PS2\Gran Turismo 4\Gran Turismo 4 (USA) (v2.00)`. Both peers recognized
the same GT4 v2.00 disc, serial `SCUS-97328`, CRC `77E61C8A`, and the user-owned
SCPH-39001 BIOS. Each used `-datapath <peer> -nogui -- <ISO>` with its own
scratch memory cards and INI.
PCSX2's actual `-datapath` layout created
`<datapath>/PCSX2/inis/PCSX2.ini` and
`<datapath>/PCSX2/logs/emulog.txt`. The per-peer INI selected its veth via
`[DEV9/Eth]` (`EthEnable = true`, `EthApi = PCAP Bridged`, distinct
`EthDevice`, `InterceptDHCP = false`).

Two instances initially collided because upstream PCSX2 v2.8.2 hard-codes
`shm_open("/GS.mem", O_CREAT | O_EXCL)` for GS local memory in
[`GSLocalMemory.cpp`](https://github.com/PCSX2/pcsx2/blob/v2.8.2/pcsx2/GS/GSLocalMemory.cpp).
The second process failed with `File exists`. Giving each emulator process its
own private mount namespace and a 1 GiB tmpfs mounted at `/dev/shm` isolated
that fixed shared-memory name without touching the host's `/dev/shm`; both
instances then coexisted.

Both emulator logs independently show `DEV9: Opening adapter 'gt4i'` / `'gt4j'`,
`Device uses DLT 1: EN10MB`, and `Adapter Ok.` Both opened the same ISO and
logged that the GT4 ELF was executing. The official PCSX2 binary includes its
`PCAPAdapter`/libpcap path, and these messages prove each configured endpoint
opened. They do not prove that GT4 sent or received LAN packets.

The maximum game gate reached was GT4's first-run memory-card dialog: “No GT4
game data found ... Game data is required to play GT mode. Do you wish to create
game data?” An offscreen XWD capture showed `OK` selected. I added isolated
`[Pad1]` keyboard bindings and sent a synthetic `K` press to each private game
window, but the captured screen still showed the dialog; therefore the input
was not verified as accepted. No GT4 main menu, LAN host/join screen, discovery,
race start, finish/results, or rematch was observed. This is not a LAN race
pass. PCSX2 and Xvfb processes were closed at the end of the scratch run; no
host display was touched and no persistent setup changes were made. Logs and
offscreen captures remain under the scratch path above for reproducibility.

**Current next gate:** make the first-run input reproducibly dismiss the dialog
in both peers, then configure the game's own network profiles and verify LAN
host/join discovery over the private veth segment. Do not claim multiplayer
support until both peers finish a race and the results screen is recorded.

### Follow-up: headless input and title-menu progress (2026-11-08)

The keyboard-input gate is now resolved for the two scratch displays. The
original `xdotool windowfocus --sync` path could block indefinitely without a
window manager; the working harness instead uses `windowfocus` without
`--sync`, verifies the focused game window, and holds an XTest key for 250 ms.
Screenshots verified directional selection and Cross acceptance during the
first-run dialog flow. Peer K visibly advanced through the GT3 save-data
question, first-run profile/memory-card flow, and into the title intro. Peer L
reached the title menu; a Down press visibly moved selection from Arcade Mode
to Gran Turismo Mode. Thus game-window focus and synthetic control delivery
are proven independently per private Xvfb display.

The two PCSX2 v2.8.2 processes and distinct PCAP/veth endpoints remained
alive simultaneously in their isolated network namespace, with separate
per-peer configuration and scratch memory cards. The process-private `/dev/shm`
mounts avoid the fixed `/GS.mem` collision. Audio was directed to the null
backend. There were no host display, user save, controller, firewall, driver,
or emulator-install changes.

At this checkpoint, Cross/Start from the title menu entered a black GT loading
screen with an animated spinner, but it had not completed after a bounded
interval; the other peer was still in its intro sequence. The emulators were
under heavy software-rendering load (roughly 200% CPU each as reported by
`ps`), and no in-game LAN lobby, host/join discovery, race, packet exchange,
finish screen, or results screen was captured. The full GT4 LAN race therefore
remains unverified. Do not interpret reaching the title screen or opening the
PCAP adapters as multiplayer success.

The reproducible scratch harness is
`/tmp/anyps5-gt4-fOqRtVew/run-private-pair.sh` with peer configuration and
captures under the same owned scratch root. Its supported commands are
`i-left`, `i-right`, `i-cross`, `i-start`, `i-up`, `i-down` and their `l-*`
counterparts; it saves XWD captures after each input. Keep Xvfb TCP displays
private to the already isolated network namespace. If resuming, first inspect
the saved per-peer cards and XWDs, then consider a one-peer renderer/speed-OSD
probe before starting both peers again. The next acceptance gate is an actual
Arcade Mode → Multi LAN Race host/join pair, observed packet traffic on the
private veth, and both peers reaching finish/results. The publisher's US
manual identifies Circle or Cross as confirm and Triangle or Square as cancel;
Circle remains an alternate title-menu confirm to test if the current load
resumes.

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

### Headless GT4 retry result (2026-11-08)

A clean two-peer retry reused separate saved scratch cards and profiles. Both
isolated PCSX2 v2.8.2 instances booted the same USA v2.00 disc (CRC `77E61C8A`)
and reached Arcade Mode → Multi-LAN Race. Loading briefly showed the GT
spinner. The later 14:52 local-time captures, `screens/peer-k/current.png` and
`screens/peer-l/current.png` under `/tmp/anyps5-gt4-fOqRtVew`, show the saved
`qqq` network profile in both instances at about 60 VPS and 100% speed. The
older `latest.png` files predate this retry.

In the earlier run, both profiles received distinct intercepted DHCP leases
(`10.231.0.101` and `10.231.0.102`). A read of the live `gt4k` capture counted
29 and 16 UDP/3658 broadcasts, respectively, to `10.231.0.255`, plus ARP.
Neither screen showed a joined lobby. The title options were then set to
`Player1xn` as host with two players and `Player1` as client.

The retry PCAP files ended at 4,288 bytes each. The latest logs and captures
do not establish a completed connection with the new roles. The emulator
and Xvfb processes exited, and a final exact-path process check confirmed
the scratch runner and both packet capture helpers also stopped.

**Result:** the input fix, access to the game's LAN profile screen and
guest broadcasts were verified. Host discovery, a shared lobby and a
finished race remain unverified. The next gate is to observe both peers
connect from the saved profiles with the host role active and capture the
discovery reply or first unicast exchange. All interaction used the private
scratch displays and scratch memory cards.

### Headless GT4 LAN race attempt (2026-11-08, 16:26–16:37 local)

The next isolated retry used the same USA v2.00 disc (CRC `77E61C8A`), PCSX2
v2.8.2, native Software renderer (`Renderer = 13`), private Xvfb displays and
the existing scratch-only network namespace. The saved profiles used distinct
intercepted DHCP leases `10.231.0.101` and `10.231.0.102`. The launcher and
installed AnyPS5 profile were not involved.

Both peers reached the title menu and the title-selection gate verified
**Arcade Mode** before confirmation. Both advanced through **Multi-LAN Race**;
the saved `qqq` network profile was connected with the gamepad cursor visibly
on Connect. Each peer initially displayed “Waiting for connection…”, then both
arrived at the same **Course Select** screen (FISCO 90's selected) and then
the same Toyota MR-S car-selection screen. This is stronger evidence than the
earlier title/broadcast-only run: the two peers exchanged UDP/3658 traffic in
both directions and each advanced through the shared course and car flow.
The final mirrored PCAPs `captures/gt4k.pcap` and `captures/gt4l.pcap` were
64,796 bytes each; `tcpdump -nn -r captures/gt4k.pcap 'udp port 3658'` counted
680 packets, including traffic in both directions between `.101` and `.102`.

Both peers confirmed Driving Options (Automatic transmission, TCS & ASM, Racing
Hard tires). The post-confirm captures were black except for the PCSX2 speed
OSD at roughly 59.9 VPS and 100% speed. After more than two minutes, K remained
black. A documented PCSX2 F9 renderer-toggle input had no visible effect on K;
after the same input was sent to L, L showed a GT4 opening-credit movie while K
was still black. The causal relationship, actual race state, and reason for the
divergence are unknown. The run did not show either car on track, a finish, or
results. High CPU use (~181% and ~188%) and increasing process `rchar` showed
ongoing emulator work, so this is not established as a static crash; it is a
race-transition/rendering blocker. Do not describe this as a completed LAN race.

The final XWD-derived captures and PCAPs remain in the owned WSL scratch folder
`/tmp/anyps5-gt4-fOqRtVew`. The parent input runner's quit path emitted an
unhandled SIGSEGV while shutting K down; L stopped on an exact-PID SIGTERM.
A final process scan found no remaining task-owned PCSX2, Xvfb, tcpdump or
xdotool processes. No host display, host network adapter, firewall, driver,
user save, or installed application was changed. The next useful retry should
first determine why a course/car-confirmed pair does not render the race, with
separate evidence for each peer; do not repeat the already-proven lobby steps
unless the saved profiles or PCAP show that the handshake regressed.
