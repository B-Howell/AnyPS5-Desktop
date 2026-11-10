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

The [retro LAN transport](../lib/core/online/retro_lan_transport.dart)
routes guest Ethernet frames between authenticated room members. It
associates each member with a distinct MAC, forwards discovery broadcasts,
and drops stale epochs, spoofed sources and traffic to other segments. The
[transport tests](../test/core/online/retro_lan_transport_test.dart) exercise
those rules with synthetic frames. The [DEV9 adapter source patch](../tool/patches/parallel-ps2-virtual-lan.patch)
adds a versioned binding for frontend-owned Ethernet queues. It uses frames
without a frame check sequence and leaves the original adapter selection in
place when no frontend transport is bound.

The [Windows queue](../windows/runner/ps2_virtual_lan.h) copies frames
into fixed 64-frame buffers in each direction. The [embedded runner](../windows/runner/retro_core_host.cpp)
requires the DEV9 binding for an explicitly configured PS2 LAN launch,
enables the core's Ethernet option for that session, and detaches after
unloading the game. It refuses a core without the binding before boot.
The [Dart bridge](../lib/ui/embedded_retro_game.dart) exchanges batches
of at most 16 frames and accepts caller-supplied LAN system and save
paths for isolation. The [native queue test](../windows/runner/tests/ps2_virtual_lan_test.cpp)
exercises the callback ABI, frame copying, bounded queues, routing checks,
and teardown. The LAN launch preserves its network state by rejecting
graphics changes that reopen the core.

The [PS2 LAN match](../lib/core/online/retro_lan_match.dart) owns a
private two-player room, binds signaling to the invited account and
device, and checks the disc fingerprint through the room API. Each
player gets a distinct virtual MAC. The match waits for the unreliable
WebRTC game channel before starting its embedded-game factory. Once
the SDP exchange is established, repeated setup signals reuse it even
if a channel-open event has yet to reach one of the players. After launch,
a temporary WebRTC disconnect gets eight seconds to recover on the same
connection. The launcher reports interruptions that last at least 750 ms
and confirms recovery. After 1.5 seconds without a usable route, the
designated offerer attempts an ICE restart for the outage. The answerer
can ask the offerer to start it. During recovery, signaling is retried at
1.5-second intervals until the existing eight-second deadline. The peers
reuse the same offer, answer and candidates if the gateway was temporarily
unavailable. The same ICE generation, room, emulated network adapter and
data channels stay in place. Offers, answers and trickle candidates
for a restarted route carry a generation number. The match ignores
already-numbered signaling from older routes and unnumbered startup
signals after an ICE restart. Native WebRTC checks connectivity with the
negotiated credentials. While the link is unavailable, the match drops
peer traffic and continues to service the guest's local DHCP. AnyPS5 has no
replay queue for missed Ethernet packets. A closed room, a closed game
channel, or an expired recovery window ends the LAN session. A failed
peer connection with an open game channel can still attempt an ICE
restart. The game decides whether its own multiplayer session survives
the interruption.

The [LAN bridge](../lib/core/online/retro_lan_bridge.dart) keeps at most
64 incoming frames, retries the head batch while the core is loading,
and allows one exchange of up to 16 frames at a time. On exit, the
match stops forwarding frames and drains the current exchange. A peer
departure, lost game channel, or **Leave LAN Play** releases the room while keeping an
already started game open. The player can return to the game or connect
to a new room from the same host or guest seat. The launcher reuses the
same verified disc, account, running worker and save lease. Changing
seats requires a fresh launch because the network address is fixed at
boot. Before connecting a new bridge, the
[Windows host](../windows/runner/retro_core_host.cpp) clears both queues
in the [virtual adapter](../windows/runner/ps2_virtual_lan.h). When
the connection is ready, Friends returns the player to the running game.
The game still owns its LAN lobby, so players regroup in its multiplayer menu.
After the old room finishes closing, a retained host can choose
**Invite a Friend to LAN Play** from the Quick Menu. The picker uses
the running game's verified disc regardless of the library selection.
Back returns to the Quick Menu. Choosing a friend resumes the game
while AnyPS5 verifies the disc and connects the room.
A retained guest can accept a matching pending invite directly in the
Quick Menu. AnyPS5 still rechecks the disc digest and room before
reusing the worker, then returns the player to the game.
**Close Game** still shuts down the local game. Cancel during startup
also closes a worker that returns after cancellation. Local worker
cleanup runs independently of the room release request. Another LAN
attempt waits for the old room cleanup to settle. The
[transport suite](../test/core/online/retro_lan_transport_test.dart)
covers frame routing and queue bounds. The
[match tests](../test/core/online/retro_lan_match_test.dart) exercise
authentication, repeated signaling, temporary disconnect and traffic
resumption, simultaneous restart requests, dropped restart signaling,
replay of a rejected candidate, stale candidate rejection, recovery
timeout, and exit during an exchange or startup.
Set `ANYPS5_PS2_WEBRTC_LAN=1` on the existing
[headless WebRTC probe](../tool/ps1_netplay/webrtc_loopback.dart) to run
the [two-player room fixture](../tool/ps1_netplay/webrtc_lan_probe.dart)
over real Windows data channels. The probe checks the assigned MACs,
matches broadcast and unicast frames byte for byte, and checks that the
guest can leave without closing the host game, even while the host's room
release request is pending. It injects connection-state changes and
checks that frames resume on the same Windows WebRTC channels. An injected
guest connection failure exercises native ICE restart. The gateway fixture
rejects the first restart request, offer and answer. The probe checks that
the retry uses one fresh SDP offer and that traffic resumes on the same links.
It uses synthetic NICs and a simulated room gateway. A packaged-game
disconnect and rematch across two networks remains part of the release
qualification below.

The [private DHCP service](../lib/core/online/retro_lan_dhcp.dart) supplies
`10.231.0.101/24` to the host console and `10.231.0.102/24` to the guest.
Each bridge answers its own console's discovery, request and renewal
traffic, including ARP for the virtual DHCP server at `10.231.0.1`.
Lease messages and server ARP stay on that console's adapter. Peer game
broadcasts, unicast traffic and ARP for the other console still use the
room transport. The service supplies an address and subnet mask for this
closed LAN. Its offers contain no router or DNS options.

The [DHCP tests](../test/core/online/retro_lan_dhcp_test.dart) check packet
bounds, lease ownership, renewal, ARP and remote reply filtering. The
Windows WebRTC fixture requests leases before sending game frames. Its
initial requests use broadcast Ethernet and IP destinations with the
DHCP broadcast flag clear, matching the earlier GT4 PCSX2 log. Both
simulated consoles check their assigned address and the unicast reply
destination. The embedded TimeSplitters run below separately verifies
that the real console accepts the assigned address.

### Launcher preview

On Windows x64, `ANYPS5_PS2_LAN=1` enables the [PS2 LAN actions](../lib/ui/together_ps2_lan.dart).
Highlight a PS2 disc, open an online friend's options, and choose **Invite
to LAN Play**. The invitee accepts in Friends. The launcher checks the
serial and revision from the [ISO boot metadata](../lib/core/game_library.dart)
and matches the disc SHA-256 before joining. The cover name and manifest
title can be customized independently of matchmaking. This path currently
requires a verified ISO. CHD identity is not implemented.

[Emulator preflight](../lib/core/managed_retro.dart) checks the Windows
DLL for the DEV9 binding before sending an invite. Install the patched
core from the PS2 LAN setup page. The launcher also accepts a compatible
legacy core in the managed emulator directory or `ANYPS5_LIBRETRO_HOME`.
[Embedded launch](../lib/ui/app_model.dart)
uses a [persistent PS2 LAN profile](../lib/core/online/ps2_lan_profile.dart)
under `RetroLan/PS2` beside the launcher toolkits. Each launcher profile
has its own directory, which holds a copy of the selected BIOS, the PS2
LAN memory cards and the core save directory. Games that use the shared
PS2 card can reuse the network configuration across rooms and titles.
Offline cards and saves remain separate. A Windows file lock prevents
another instance from opening the same LAN profile until the game exits.
Closing the game releases the lock and retains the card.

The invite and accept actions show which prerequisite is missing. An
incoming invite first looks up the serial and revision in the library.
Cancel releases the launcher while a read-only room lookup is still
pending. Players can retry the same invite before the old reply arrives.
That reply cannot join the room or start a game. Once room admission
has begun, Cancel still waits for owned room and emulator cleanup. The
Friends panel shows Closing during that cleanup. The local shutdown
wait is bounded at eight seconds for the room request. The launcher
still keeps the online attempt busy until the old admission and leave
requests settle, so a late leave cannot remove a new attempt from the
same room. If the gateway never finishes a response, the online
attempt remains in Closing while local shutdown can finish.
While the admitted PS2 LAN game is loading, Guide opens a Quick Menu
with **Cancel LAN Play** and the startup status. The action belongs to
that match. Cancel releases its room and closes a worker that finishes
opening after cancellation.
During play, the Quick Menu takes local controller input and sends
neutral input to the game. The online PS2 worker stays running and
the LAN bridge continues exchanging frames. The Quick Menu reports
the game as running and shows the selected WebRTC route and measured
round-trip time when available. The [peer mesh](../lib/core/online/online_peer_mesh.dart)
samples those statistics separately from the LAN frame exchange. The
[LAN match](../lib/core/online/retro_lan_match.dart) clears old statistics
on a route interruption or ICE route change. After 750 ms without a route, the Quick Menu
keeps Reconnecting visible until the connection returns, then displays
fresh statistics as they arrive. The local network-card setup can still pause while
its Quick Menu is open.
From **Game Settings → Invite a Friend to LAN Play**, select an online
friend to start a room for that disc. The picker uses the same shared
friend rows as the PS3 dashboard and the in-game invitation menus.
If setup is needed, Back returns to the chosen friend and then to the
game's settings. The setup page creates no room until **Continue to LAN
Play**. Continue rechecks the account, launcher profile and selected
library entry. The room flow verifies the disc identity and hashes the
image before sending the invite to the selected friend. The game needs
its own LAN mode to connect after launch.

The launcher verifies the ISO itself when joining. If the LAN core or
BIOS is missing, the action opens the existing setup page. **Back**
returns to the same friend or invite without creating, joining or
declining a room. If sign-out cleared the selected friend, Back opens
Friends. Once both prerequisites are ready, **Continue to LAN Play**
resumes the original request from the setup page. The
[Friends flow](../lib/ui/together_ps2_lan.dart) rechecks the account,
matching library entry and incoming invitation before opening the room.
For a blank card, the same page offers the supported Gran Turismo 4
setup path if the disc is present. Closing that local setup session
returns to the setup page with the invitation still pending.
The [launcher invite tests](../test/ui/ps2_lan_invite_test.dart) cover
the Game Settings picker, Back, the missing-disc case, an expired
invite and clean-profile setup for hosting and joining. A simulated embedded GT4
session also returns to the pending invite after stopping. A separate Windows probe
repeated the clean-profile path with the pinned LRPS2 package and a
real BIOS dump. The bundled core installed without a ZIP picker, the
offline core fixture kept its original bytes, and the fake room received
the join request after Continue.

You can also open **Settings → Emulators → PS2 → Setup → Set up
LAN network**. **Install PS2 LAN core** uses the pinned
`pcsx2_libretro.dll.zip` from the configured
`ANYPS5_MANAGED_CORE_PACKAGES` directory when supplied with the build.
Without that package the action opens a ZIP picker. The installer verifies the ZIP, DLL and DEV9
export before publishing it under `Emulators/PS2-LAN`. LAN setup and rooms
prefer that dedicated core. Offline PS2 play keeps its usual core.
**Import PS2 BIOS** accepts the user's own BIOS on the same page.
An independently built reviewer ZIP can opt in to its own exact ZIP and
DLL SHA-256 values using `ANYPS5_PS2_LAN_CORE_DIGESTS` as
`<archive-sha256>:<dll-sha256>`. Normal setup uses the pins below.

The [setup page](../lib/ui/emulator_menu.dart) then offers the
verified Gran Turismo 4 USA v2.00 disc from the local library, identified by
serial and revision. It explains when the disc, DEV9-capable core or BIOS
is missing. [Setup launch](../lib/ui/app_model.dart) rereads the disc metadata
before opening the writable profile. It uses the same locked LAN card as a
room and runs the [bridge](../lib/core/online/retro_lan_bridge.dart) with local
DHCP only. It requires no sign-in and sends no frames to peers. PS1 and PS2
online actions wait while setup owns the profile. Save the configuration in
the game, then close it to release the card.

After the room connects, open the game's LAN menu and choose the saved
configuration from slot 1. The launcher does not declare the network ready
just because a card file exists. **Leave LAN Play** in the Quick Menu
closes the room and keeps the game open. The launcher distinguishes
a local leave, a room ended by the other side, and a terminal transport
failure. A transport closure or expired recovery window shows that the
connection ended and confirms the local game is still open. A goodbye
from the bound peer or a room end event shows that the other side
closed the room. Restart trials are unavailable while the LAN worker
is active.

The [LAN invite test](../test/ui/ps2_lan_invite_test.dart) joins two rooms
in sequence with the same guest worker and checks the queue reset.
The [virtual adapter test](../windows/runner/tests/ps2_virtual_lan_test.cpp)
checks that resetting discards both queued directions and keeps the adapter usable.
The [library test](../test/core/retro_library_test.dart) verifies serial
and revision extraction with a conflicting manifest. The
[emulator test](../test/ui/embedded_retro_game_test.dart) checks the private
launch arguments and frame exchange through a mocked runner, then reopens
the same card and save data in a second room with a different virtual MAC.
It also interrupts a launch after native startup and verifies that the
profile stays locked until the core reports exit.
The [profile tests](../test/core/online/ps2_lan_profile_test.dart) cover
exclusive access, separate owners and lease release after a BIOS copy failure.
The [settings test](../test/ui/retro_settings_setup_test.dart) opens the
setup page, rejects a replacement disc and checks its local launch and
frame exchange with a mocked native runner. It also checks the PS1 setup
guard before the emulator starts. The [DHCP test](../test/core/online/retro_lan_dhcp_test.dart)
exercises Discover, Offer, Request and ACK on the setup bridge without a room.
The [managed core test](../test/core/managed_retro_test.dart) verifies the
ZIP and DLL checks, DEV9 export, retry and preservation of offline and
existing LAN cores. The setup test also drives both file pickers, checks
that cancellation restores the page, and verifies the native launch
receives the dedicated DLL path. The [invite routing test](../test/ui/together_test.dart)
checks that PS2 invites cannot join a PS5 session on a build with LAN off.

### Windows core build and native smoke

Build LRPS2 at `da5b07ebebc18016e1ca5b401188a283971a0e8d` with the
[DEV9 patch](../tool/patches/parallel-ps2-virtual-lan.patch) and the
[Windows GNU CMake patch](../tool/patches/parallel-ps2-windows-gnu.patch).
Apply the second patch with `git apply --unidiff-zero` at that exact pin.
It limits MSVC-style AVX flags to MSVC-compatible compilers and
reads the Git version from the LRPS2 source directory. With WinLibs
GCC 15.2.0 r7 and Ninja on `PATH`, configure an out-of-tree build:

```powershell
cmake -S $lrps2Source -B $buildDir -G Ninja -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DLIBRETRO=ON -DPCAP=OFF `
  -DDISABLE_ADVANCE_SIMD=ON -DUSE_VULKAN=ON -DUSE_OPENGL=ON -DLRPS2_SMOKE_GATE=ON `
  '-DCMAKE_SHARED_LINKER_FLAGS=-static -static-libgcc -static-libstdc++'
cmake --build $buildDir --target pcsx2_libretro --parallel 3
```

Package `libretro/pcsx2_libretro.dll` as the only archive entry. The
verified DLL SHA-256 is
`801af1211407964a4851839c3f4e90607f18353671dd1e427f56e12201d712a4`.
The local ZIP SHA-256 is
`2df47bc025ff7dfdfce5594b709fa25884667acdff698334ed2d4942a8dc67f7`.
Archive hashes can vary between packagers. The static link removes the
dependency on an external WinLibs pthread DLL. The launcher export check
accepted the packaged DLL, and the upstream Libretro smoke completed
init, a BIOS-less load attempt, deinit and unload.

A clean Windows scratch profile imported that exact ZIP using the
[managed installer](../lib/core/managed_retro.dart). The dedicated DLL
matched the expected hash on install and retry, and the offline core slot
remained empty. A headless D3D11 worker loaded the installed DLL from
`Emulators/PS2-LAN`, booted TimeSplitters and reached a one-player LAN lobby
after one local DHCP lease. That run used a configured scratch card and
exited zero. Installer, test and native evidence is stored beside the
core under `timesplitters-lan/managed-core-import`.

A separate no-window test opened the TimeSplitters ISO with a copied
BIOS and fresh saves. It rendered 1,467 frames across 1,800 calls to
`retro_run`, polled the bound adapter 3,549 times, sent a DEV9 self-test
frame, and detached the adapter cleanly.

### TimeSplitters LAN in two embedded core instances

On the Windows DLL above, a fresh scratch memory card reached Network →
LAN Game and stopped at the game's message that slot 1 had no valid
network configuration. The game sent no DHCP requests before this check.
TimeSplitters accepted the `BWNETCNF` profile on a copy of the earlier
GT4 scratch card. Its real DEV9 client completed Discover → Offer and
Request → ACK at `10.231.0.101`, then opened **Matches Available**.

A second run used two hidden Libretro workers with independently copied
BIOS and cards, distinct virtual MACs, and the Dart DHCP and Ethernet
routing code. The harness passed room frames over Windows loopback UDP.
Both clients accepted a lease. Player B discovered player A's lobby,
and both captures showed the same **2/8 Players** roster. Both entered
Vietnam Deathmatch loading. The host captured a live first-person frame.
The guest worker terminated during that step with Windows exception
`0xc0000005`. The faulting module was unresolved in Event Viewer. The host
stopped cleanly, and both scratch relay endpoints closed.

#### Renderer control and completed round

The same disc, DLL, scratch-card template, controller sequence, and
loopback transport were reused with a native fault recorder. With
Software (SW), both core processes reached loading and then exited with
`0xc0000005`. The recorder captured read faults at the indexed texel
load in generated code (`movzx eax, byte ptr [rbx+rax]`). The byte pattern
and registers match `ReadTexelImpl` in the pinned
[LRPS2 software rasterizer](https://github.com/libretro/parallel-ps2/blob/da5b07ebebc18016e1ca5b401188a283971a0e8d/pcsx2/GS/Renderers/SW/GSDrawScanlineCodeGenerator.all.cpp#L3276).
The reads targeted uncommitted memory. This identifies the crash site.
The texture bounds or lifetime defect that led to it remains open.

The D3D11 control used a windowless feature-level 11.0 device and the same
Libretro v1 interface as the [embedded runner](../windows/runner/retro_core_host.cpp).
Both consoles acquired leases, joined the same Vietnam Deathmatch, loaded
into first-person gameplay, and reached the results screen after the
timed round. The host scoreboard listed both players at 0–0. The guest
results capture showed its score. Parts of the guest's separate score
table capture appeared blank. At the last sample the host had sent 4,468
and received 1,897 room frames, while the guest had sent 1,897 and received
4,468. Both processes exited cleanly with empty fault logs.

This qualifies a full D3D11 round through the launcher DHCP and packet
rules over one-PC UDP loopback. Local evidence beside the Windows DLL
package includes captured frames, logs, input steps and the diagnostic
source under `timesplitters-lan/renderer-control`.

### Local TURN transport and recovery

The [headless PS2 LAN probe](../tool/ps1_netplay/webrtc_lan_probe.dart)
can run with relay-only ICE. Use the [local TURN fixture](../tool/ps1_netplay/turn_fixture/main.go)
on the Windows WSL virtual adapter, following the build and address
checks in the [PS1 netplay plan](<AnyPS5 Desktop - PS1 Netplay Implementation Plan.md>).

```powershell
pwsh -File tool/ps1_netplay/run_webrtc_probe.ps1 -Runner "path/to/loopback.exe" -Data "path/to/data" -Lan -TurnAddress $adapterAddress -TurnPort $printedPort
```

The Windows direct and relay-only controls both passed. The
[room fixture](../tool/ps1_netplay/webrtc_room_fixture.dart) verifies the
selected relay route on both links before the interruption and after
the ICE restart. The PS2 probe checks both DHCP leases and bidirectional
Ethernet forwarding, then checks that forwarding pauses during an
injected disconnect and resumes on the original links. It rejects
the first restart request, offer and answer to exercise signaling
retries. The new offer has fresh ICE credentials. The guest can leave
while the host game stays open. The relay released its allocations
when the probe closed. This probe uses simulated console interfaces
and injects connection notifications in the test wrapper. The
data channels, selected routes and relay are real and local.

The [LAN bridge](../lib/core/online/retro_lan_bridge.dart) binds each
native NIC exchange to the usable WebRTC connection that started it.
If the peer disconnects or changes routes, pending inbound Ethernet
frames for the retired connection are discarded and late peer output
from that exchange is suppressed. Local DHCP and newly queued frames
from the restored route survive the transition. The
[match regression](../test/core/online/retro_lan_match_test.dart) holds
a native exchange across a reconnect and verifies that fresh traffic
resumes without sending the stale frame. The
[queue test](../test/core/online/retro_lan_transport_test.dart) covers
new input arriving before the old exchange finishes. The focused
Windows suite passed 35 tests and the relay-only probe resumed traffic
after ICE restart with zero relay allocations left at teardown. The
bridge cannot retract frames already handed to the native NIC or
WebRTC. This check did not run a native game.

The launcher also resets both native NIC queues after it
observes an interrupted or restored peer route. The reset runs after
the previous exchange finishes and before another exchange can submit
fresh peer frames. If the route changes during reset, the next pump
resets again. A worker whose NIC is still opening retries reset before
exchanging traffic. If repeated resets report that the NIC is not ready
for eight seconds, the bridge raises a reset timeout. That timeout or
a reset exception ends the room through the connection-failure path
and preserves the game. An in-flight reset is still awaited before the
worker can be reused.
This uses the existing
[native queue reset](../windows/runner/ps2_virtual_lan.h), wired through
the [PS2 launcher](../lib/ui/together_ps2_lan.dart). The bridge retains
its local DHCP replies. Native queued DHCP packets can be dropped by
the reset and follow the console's usual retransmission path.

The Windows regression reproduced zero native resets before the fix.
Afterward the full focused suite passed 38 tests, and a follow-up
22-test core run included the new reset-readiness timeout. The native
[NIC test](../windows/runner/tests/ps2_virtual_lan_test.cpp) passed
after rebuilding with assertions enabled. The relay-only probe verified
that each seat's reset counter advanced across ICE restart and traffic
resumed. That probe uses simulated console interfaces. The launcher
integration test checks the actual `ps2LanReset` method call on the
same worker texture. A native game recovery run with this new reset
callback remains a separate acceptance check.

The [native reset probe](../tool/ps1_netplay/ps2_native_reset_probe.dart)
uses the windowless Windows runner with its real `RetroCoreHost`,
one LRPS2 game and one synthetic WebRTC peer. Compile it as the Dart
entry point in place of `webrtc_loopback.dart`, then set
`ANYPS5_PS2_NATIVE_RESET` to a fixture JSON file. Supply absolute
`core`, `disc`, `bios`, `card` paths, each file's SHA-256 in
`coreSha256`, `discSha256`, `biosSha256`, `cardSha256`, and a
fresh absolute `work` directory. It copies the BIOS and card into
that isolated directory and verifies all file hashes before launch.
The runner should inherit a scratch `TEMP` and `TMP` on the test drive.

At Desktop `dfe945e` with the new probe entry point, the pinned
TimeSplitters disc completed two native resets on texture 1. Published
frames advanced from 1 to 49 across the injected disconnect and
reconnect, then to 66 after leaving the room. The native host stopped
normally and the seed card kept its hash. The D: receipt
`ps2-native-reset-dfe945e` contains the fixture, bundle and runner
output. This verifies actual method-channel queue resets while the
core renders through the launcher's native host. The peer is synthetic
and the game had only just begun rendering. An active two-console LAN
match with the new callback remains unverified.

### Full TimeSplitters round over Windows WebRTC

At Desktop `d7f7911`, the same two native D3D11 workers ran the US disc
with separate scratch cards. A local adapter connected each worker's DEV9
frames to the production [room match](../lib/core/online/retro_lan_match.dart)
and [Windows WebRTC game channels](../lib/ui/online_webrtc.dart). The
[room gateway fixture](../tool/ps1_netplay/webrtc_room_fixture.dart) supplied
signaling. The native game workers used loopback TCP only to exchange raw
frames with their local Dart adapters. Traffic between the two Dart room
peers used the real WebRTC data channels.

The first run reached a shared lobby, then the [headless test runner's
65-second watchdog](../windows/runner/tests/ps1_webrtc_loopback.cpp) closed
both links. With a 600-second watchdog in the scratch build, the rerun paced
network setup and gameplay at up to 60 guest ticks per second. Both consoles
got one DHCP lease, joined the same lobby, entered Vietnam Deathmatch with
separate first-person views and reached matching results and score tables.
Both tables listed A and B tied at 0–0. The native workers and room host all
exited zero. The room released both endpoints, the worker fault logs were
empty, and no owned runner remained. The host adapter queued 4,420 outbound
game frames and received 1,882. The guest queued 1,883 and received 4,419.
Neither scratch adapter overflowed its queues. These counters measure the
adapter boundaries and do not establish packet loss on the wire.

Local evidence under `timesplitters-lan/webrtc-control` includes the pinned
core and bundle hashes, runner source, scripted inputs, teardown receipt
and paired captures of the lobby, gameplay, results and scores. This run
qualifies the two real guest instances and Windows WebRTC transport on one
PC. Hosted AnyTogether signaling, WAN or TURN, and the shipping launcher
UI are separate gates. The workers used preconfigured scratch cards. This
run predates the persistent PS2 LAN profile and does not qualify the first
in-game network setup on a blank card.

### Full TimeSplitters round over local TURN

The native replay reused the same headless Windows D3D11 workers and
scratch-card seed, with both WebRTC peers restricted to TURN on the
private WSL adapter. The room verified the selected relay routes before
launching the workers and again before room release. Both consoles
received one DHCP lease, entered the shared Vietnam Deathmatch round,
and reached its results and score tables. Both score tables listed
A and B tied at 0–0.

The host adapter queued 4,420 outbound frames and received 1,880.
The guest queued 1,881 and received 4,419. Both reported zero adapter
queue overflows. Both native workers and the room exited zero with
empty fault logs, and the original scratch-card seed was unchanged.
The private D: receipt `timesplitters-turn-517bc89-rerun` retains
the pinned runner, driver, relay log, native room output, and paired
captures. The Dart bundle SHA-256 was
`d5d0fd1b2bff5720b30cf7b7d71ff5cd85174058fcbc49b1d6d20aef213c335a`.
The two native games, room signaling and TURN ran on the same PC.
Hosted signaling, play across separate networks and a complete GT4
LAN race remain separate qualification gates.

### Full TimeSplitters round with a simulated outage

At Desktop `69e80f7`, two real D3D11 TimeSplitters workers used the same
local Windows WebRTC room with separate scratch cards. Paired captures
confirmed both players were in Vietnam Deathmatch before the test
reported a failed connection on the guest. The gateway fixture rejected
the first restart request, offer and answer. The room used one new ICE
offer on the original two links. The guest reported recovery after
4,526 ms, and both adapter receive counters had advanced by 4,591 ms.

In the next 1,800-frame checkpoint, entirely after recovery, the host
adapter sent 567 frames and received 281. The guest sent 281 and received
568. Both consoles reached Results and Scores. The host table showed A
and B tied 0–0. The guest showed the same scores with some labels missing.
The room and both native workers exited zero.
Both fault logs were empty, the room released both seats, and neither
adapter reported queue overflow. The source card seed retained its hash.

The local receipt under `timesplitters-lan/native-recovery-69e80f7`
contains the source and binary hashes, recovery timing, worker counters,
scripted inputs and paired captures. The failure was injected at the
connection-state callback while native WebRTC carried the game packets.
This run qualifies game-level survival of that simulated outage on one
PC. Physical network loss, hosted signaling, direct and relayed play
across separate networks, and the installed launcher's UI still need
qualification.

#### Relay-only recovery after the bridge fix

At Desktop `063cf83`, two native D3D11 TimeSplitters workers completed
Vietnam Deathmatch through the local TURN fixture. The probe checked
that both WebRTC links used a relay before and after ICE restart. Both
captures showed active gameplay before the guest connection-state
failure was injected. The room fixture rejected the first restart
request, offer and answer. The original links stayed in the room and
negotiated one offer with fresh ICE credentials. The guest reported
recovery after 2,529 ms and both seats received fresh traffic by
2,873 ms.

Both consoles reached Results and displayed the same 0–0 score table.
The host adapter sent 4,418 frames and received 1,852. The guest sent
1,878 and received 4,368. Each obtained one DHCP lease, and neither
reported queue overflow. Both workers and the room exited zero with
empty fault logs, the original scratch-card seed kept its hash, and the
local relay process stopped. The D: receipt
`timesplitters-reconnect-063cf83-rerun` retains the compiled bundle,
driver, recovery timings and paired screenshots. The bundle SHA-256 was
`a837ea97cf1ff6ff3af6b1d88bc08eeef8970832ccaa682ee67163c5718e0215`.
An initial run stopped at an overly strict whole-frame image comparison
before the disconnect. The rerun used visual confirmation of both
gameplay captures because the camera positions vary between runs.
The failure was simulated on one PC. Physical network loss, hosted
signaling and play across separate networks remain unverified.

### Persistent card reopen on the native core

Two sequential headless TimeSplitters launches used the Windows D3D11
worker and the new profile lease. The first launch used a preconfigured
scratch card and reached the host lobby. The second opened the same
profile directory, verified the first launch's saved card hash, used a
different virtual MAC and reached the LAN browser without repeating the
game's setup. The private DHCP fixture issued one lease in each launch.
Both game and lease processes exited zero. The test used a local DHCP
fixture with one worker at a time. It verifies reuse of a saved card
across processes. It did not exercise blank-card setup or hosted play.
Evidence is stored beside the core under `timesplitters-lan/profile-reopen`.

### Creating a network configuration from a blank card

At Desktop `399a132`, an empty scratch PS2 LAN profile started
TimeSplitters US `SLUS21148` with the pinned Windows D3D11 core. The game
formatted slot 1 and saved a player profile. **Network → Online Game**
stopped at the same missing network configuration message observed earlier
in **Network → LAN Game**. Neither attempt sent a DHCP request, and neither
screen offered a setup option. The
[original game manual](https://www.videogamemanual.com/PS2/TimeSplitters-%20Future%20Perfect%20%28USA%29.pdf)
describes creating the configuration with a compatible title or the PS2
Network Adaptor Start-Up Disc.

Gran Turismo 4 US v2.00 reopened the same scratch profile. **Arcade Mode →
Multi-LAN Race** offered to create a network configuration on slot 1. Keep
Ethernet auto-detect, Authentication set to No, **Use DHCP** and **Use auto
DNS** set to Yes, enter a name and choose **OK** to save. The named entry
then appeared in the slot 1 list. After native shutdown, TimeSplitters
reopened the same card, selected the new profile and accepted a private
DHCP lease. It reached **Matches Available** without repeating setup. The
existing TimeSplitters player profile was still present.

This verifies creation through a real PS2 title and reuse by another
title with the persistent profile. All three boots were headless with one
core at a time. The scratch profile contained no pre-seeded memory card.
This evidence predates the Settings action and does not exercise a built
launcher's new setup screen. Evidence is stored beside the core under
`timesplitters-lan/blank-card-setup`.

The setup action's local bridge was also exercised with two sequential
headless TimeSplitters boots, one as host and one as guest. The harness
passed native DEV9 frames to `RetroLanBridge.local` over process pipes.
Each boot got one lease. The host opened a one-player lobby and the guest
opened an empty LAN browser, consistent with the absence of a peer or
room. Both game and profile processes exited zero. The second boot reused
the first boot's scratch card. The recordings and logs are stored under
`timesplitters-lan/setup-local-bridge`. This verifies the bridge against
the native core. The Settings action itself is covered by the mocked
launcher test and still needs a pass in a packaged app.

### Windows Release package check

The multiplayer tree at `5322d69` with the [MSVC warning flag correction](../windows/CMakeLists.txt)
built a Windows x64 Release bundle with Flutter 3.47.1, MSVC 19.29,
CMake 4.4.4 and Ninja Multi-Config 1.13.2. The first Ninja build failed
with D8021 because it passed literal quotes to `/wd`. The corrected
build retained `/W4`, `/WX` and C4100 suppression. The scratch build also
needed a short path and pre-extraction of media_kit's verified libmpv and
ANGLE archives because the generator tried to link before extraction.
The lockfile and authored application code matched the source archive.

The local archive contains 95 verified release files. The package check
loaded Flutter and WebRTC DLLs, checked the runner's DEV9 channel and
packaged English and Turkish setup strings, and separately loaded the
pinned LRPS2 DLL and resolved its DEV9 export. The
[headless room fixture](../tool/ps1_netplay/webrtc_lan_probe.dart) then
used the exact WebRTC DLLs from that package. It assigned distinct DHCP
leases, exchanged matching Ethernet frames and released both endpoints.
That fixture uses a headless debug Flutter host and synthetic NICs.
The patched core remains a separate local artifact. The launcher import
action uses the pinned local ZIP. A public download requires an approved
package location and distribution of corresponding source and notices.
Hosted AnyTogether signaling, WAN play and setup through the packaged UI
remain open.

TimeSplitters: Future Perfect is a second PS2 fixture. Its US NTSC disc
reports `SLUS21148` and version `1.00` in `SYSTEM.CNF`. The [original manual](https://www.videogamemanual.com/PS2/TimeSplitters-%20Future%20Perfect%20%28USA%29.pdf)
documents separate Online Game and LAN Game modes. The latter can exercise
the private segment with a different game protocol from GT4. Online Game
requires a compatible service, which is a separate qualification.

At [the pinned DEV9 source revision](https://github.com/libretro/parallel-ps2/blob/da5b07ebebc18016e1ca5b401188a283971a0e8d/pcsx2/DEV9/net.cpp),
`tx_put` can pass a stack-backed packet, so an asynchronous adapter must
copy it before returning. The adapter supplies the assigned guest MAC
through `SetMACAddress` before the receive thread starts. The receive side
fills a core-owned `NetPacket` and uses a bounded wait that teardown can
wake. Release the frontend transport only after the core's receive thread
has joined. None of these operations need a system NIC or driver.

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

### Invite progress and in-game handoff

The [room match](../lib/core/online/retro_lan_match.dart) exposes the current
startup step to the [launcher](../lib/ui/together_ps2_lan.dart). While the
disc is being checked the player can cancel. The launcher then shows room
opening, waiting for the friend or host, peer connection, and game startup
as separate steps. If the game is closed, it stays closed until the peer
connection is ready.
The launcher distinguishes a refused room, a missing player, a failed peer
connection and a game launch failure. A failed attempt uses the same room
cleanup as Cancel.

The private bridge can carry DHCP and game frames during boot. The
in-game instructions appear when the first game picture is visible. The
host sees the instruction to host in the game's LAN menu and the guest sees
the instruction to join. LAN discovery and race entry still happen in the game. The
[invite tests](../test/ui/ps2_lan_invite_test.dart) hold a friend outside
the room, delay signaling, verify the host and guest instructions, and
exercise separate room-admission, peer-connection and native boot failures.
The [room tests](../test/core/online/retro_lan_match_test.dart) cancel from
the startup notification and during an in-flight launch to check both
cleanup paths.
The focused Windows room, invite, setup and localization suites passed
all 47 tests. The invite tests use a fake gateway and native method
channel, so this result qualifies the launcher flow.

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

### GT4 offline race control and LAN capture correlation (2026-11-09)

A single isolated PCSX2 v2.8.2 instance used the same USA v2.00 ISO,
software renderer and a copy of the host's scratch card, with DEV9 Ethernet
disabled. Arcade Mode → Single Race loaded Fuji Speedway '90s (FISCO 90's)
and the Toyota SUPERAUTOBACS APEX MR-S (JGTC) '00 with automatic transmission,
TCS & ASM and Racing Hard tires. The game rendered the prerace grid and
the on-track two-lap countdown at roughly 60 VPS. This control exercises
the same course and car assets without the two-console start protocol.
It rules out a general failure to render that race on the test setup.
The private Xvfb and PCSX2 processes exited, and the source card hash
matched before and after. The receipt and captures are under
`/tmp/gt4-offline-934f1a1a`.

A payload-by-payload comparison of the earlier LAN endpoint PCAPs found the
same multiset of 680 UDP/3658 datagrams at both interfaces. During the
black-screen interval from 16:33:10 to 16:35:39 local, 99 datagrams traveled
in each direction, all with 16-byte payloads. The last captured game-port
datagram was at 16:37:26.793, before either recorded F9 result. These are
interface observations. They do not prove that each guest received or
processed every datagram, or establish the meaning of the repeated packets.
The captured setup also matches the two-console role and monitor choices
in the [original LAN manual](https://www.gran-turismo.com/local/jp/data1/pdf/gt4_lan.pdf).

The next comparison should inspect guest DEV9 receive and race-start
behavior in two headless instances of the embedded Windows core, using
copies of the distinct role cards and synchronized input receipts at the
Driving Options confirmation. A full LAN race and results are still open.

### Embedded Windows GT4 LAN race start (2026-11-09)

Two headless Windows workers used the verified LRPS2 DEV9 DLL
`801af1211407964a4851839c3f4e90607f18353671dd1e427f56e12201d712a4`,
native-resolution D3D11 textures and copies of the two distinct scratch
cards from the standalone run. The
[LAN transport](../lib/core/online/retro_lan_transport.dart) and
[DHCP service](../lib/core/online/retro_lan_dhcp.dart) ran over a local
loopback adapter. Each core received one lease and displayed the same
course selection after connecting. Both selected the same Fuji Speedway
'90s and Toyota MR-S as the standalone run. The harness applied the same
five-tick Circle press on both peers from the captured Driving Options
screen. Both briefly rendered black, then showed the starting grid.

The following captures showed separate driver views, two different grid
positions and independent inputs. The positions swapped during driving.
Both remained in the same two-lap race at the one-minute
checkpoint. At that checkpoint the host had sent 10,075 and received
9,606 UDP/5000 frames through the DEV9 callbacks. The guest had sent
9,606 and received 10,072. These counters measure each worker boundary
at the sample instant. The test stopped before the finish and does not
qualify results, the installed launcher UI or WAN play.

The successful start revealed that the earlier UDP/3658 comparison
covered the setup phase only. Rechecking both standalone captures found
seven UDP/5000 datagrams, all from the guest to the host, and zero in the
reverse direction. The embedded run established sustained two-way race
traffic without a title-specific transport change. The evidence does
not isolate the cause of the standalone host's missing race traffic.

Both embedded workers exited zero with empty fault logs. The two source
card hashes matched after teardown and the loopback adapters closed.
The paired input sequence, per-step counters and frame captures are in
the local `gt4-embedded-4e5723` receipt. Next, finish a full embedded race
on the same private LAN and capture the results from both consoles.

### Offscreen race automation follow-up

Two more attempts replayed the same paired menu inputs. A Windows file
sharing error opening a step command interrupted the first driving
attempt. The local harness now retries transient sharing failures before
consuming a command. With that change, the pair reached step 78 with
the same race clock at 27.46 seconds. The host sent 5,183 and received
5,299 UDP/5000 frames. The guest sent 5,299 and received 5,181.

The minimap-only driver lost its red marker when the cars overlapped
and missed the first corner. Both cars stopped at the tire barrier.
The harness then shut down both cores with exit zero, empty fault logs,
and unchanged source cards. This run confirms the command retry and
repeatable shared race entry. A full race still needs a driver that can
recover from occluded markers and read the road at corners. Captures
and logs are in the local `gt4-finish-eaa3a732` receipt.

### GT4 race recovery over Windows WebRTC

Two headless LRPS2 workers used the same pinned core and separate copies
of the GT4 role cards. Their DEV9 traffic passed through the production
[room match](../lib/core/online/retro_lan_match.dart) and Windows WebRTC
data channels. A local [gateway fixture](../tool/ps1_netplay/webrtc_room_fixture.dart)
supplied signaling without a hosted account or relay. Both consoles
received a lease, entered Fuji Speedway '90s and advanced the race clock.

The fixture then reported a failed connection on the guest and rejected
the first restart request, offer and answer. At baseline `f7e8b6f`,
the route recovered in 4,519 ms and two-way traffic resumed in 4,648 ms.
GT4 displayed Disconnected on the guest and left the race despite the
restored route. The [launcher message](../assets/l10n/en.json) now
describes transport recovery and points players back to the game's LAN
menu if the game disconnected.

The recovery scheduler gives the original route one second to resume,
then replays signaling every 750 ms within the existing recovery window.
The [room tests](../test/core/online/retro_lan_match_test.dart) still
exercise brief interruptions, terminal teardown and delayed launch.
The tightened signaling-loss test timed out against the baseline and
passed with the new scheduler.

With the final timing, WebRTC reported recovery in 2,544 ms and two-way
traffic resumed in 2,896 ms. One new ICE offer recovered the original
two links. Both GT4 instances stayed on lap one and advanced to roughly
12.2 seconds on the race clock. After independent throttle and brake
inputs, the host showed first place at 52 mph and the guest showed
second place at 4 mph. Each adapter recorded one lease and zero queue
overflows. The room and both workers exited zero with empty core fault
logs and unchanged source card hashes.

The baseline and final paired captures, timing receipts and raw logs
are under the local `gt4-webrtc-32b4c248` and
`gt4-webrtc-final-58fa554f` directories. This qualifies one simulated
connection interruption on one PC. A full GT4 race, hosted signaling,
and play across separate networks still need verification.

### High-Speed Ring race fixture

The two-console course picker exposed six courses on the GT4 US v2.00
scratch profiles. High-Speed Ring requires a separate Normal or Reverse
confirmation before car selection. The offscreen setup script verifies
that menu, then checks stable car and driving-option text before sending
more inputs. The animated car preview changes with the capture time.
Comparing the whole frame had stopped the first replay even though the
selected car was correct.

Both native-resolution D3D11 workers entered the same two-lap High-Speed
Ring race. The host accelerated first while the guest held position,
which gave the drivers separate inputs from the starting grid. Both
received one lease. By the last sample, the host had transmitted 10,349
and received 10,175 UDP/5000 frames. The guest had transmitted 10,175 and
received 10,347. Both workers exited zero with empty fault logs and
unchanged source cards. This run used the local UDP adapter with the
production LAN frame filter. It did not open a launcher window or run
the Windows WebRTC executable.

The drivers did not finish. The host was centered at 41 mph when a
1.2-pixel difference between its red marker and the traced map line
caused an 11-tick steering pulse. The capture six steps later shows it
at the guardrail. The race clock and DEV9 traffic kept advancing.
This isolates an automation problem on the opening straight even when
the car markers remain distinct. A road-line probe measured the launch
frame's lane marking at x=322.9 for a 640-pixel image and declined to
give an estimate on the stopped guardrail frame. It also found a false
candidate on an intermediate frame, so it needs a continuity check
before its output can control steering. Use the map to identify the
course section and the road view to steer within it.

Local receipts are in `gt4-ring-84ce5599` under the private test
workspace. The setup script, controller trace, paired grid captures,
worker logs, `drive-audit.png` and `road_observation.py` record the
inputs, result and remaining driver limitation.

### High-Speed Ring steering and wall recovery

The next one-PC run used the same pinned LRPS2 DEV9 DLL, two role-card
copies and offscreen D3D11 at native resolution. The first launch pulses
used throttle with zero steering. Both cars stayed on the opening
straight, with the host at 45 mph and the delayed guest at 12 mph.
Speed feedback from the dashboard needle then kept both cars near
60 mph approaching the first turn. Limiting each steering correction
to at most eight of 24 input ticks and estimating heading over multiple
samples carried both cars into the banked turn. Both were on the
tarmac at 41.950 seconds, in separate positions.

The host later hit the inside barrier. The guest passed it and drove
under the bridge into the next bend. A verified reverse input moved
the host off the wall, and later manual inputs got it moving at
31 mph. The [US game manual](https://db.hfsplay.fr/files/2019/12/02/Gran_Turismo_4_USA_teBOv76.pdf)
maps Triangle to reverse and the D-pad to steering. The trial ended
on lap one at about 1:17, with no finish or results screen. The host's
wall contact shows that short steering pulses and a smoothed map
heading still need road-edge feedback, especially as banking changes
what the driver sees.

At the final sample both workers had one DHCP lease. The host sent
12,744 UDP/5000 frames and received 12,742. The guest sent 12,742 and
received 12,739. The workers exited zero with empty fault logs and
unchanged role-card seeds. The private `gt4-steering-5c5406a` receipt
keeps the steering probes, matching captures, and per-worker packet
counts. This used local UDP and the production frame filter. A full
race and hosted network qualification remain open.


### High-Speed Ring analog steering calibration

The next headless pair used the same verified GT4 US v2.00 disc
(`67b6c0075837f3ae1132d608acf2858bf13b2dd62d6eae83dff76df02e4e824f`)
and LRPS2 DEV9 core
(`801af1211407964a4851839c3f4e90607f18353671dd1e427f56e12201d712a4`).
The isolated worker now accepts signed left-stick X samples in its
input script. This uses the same libretro axis as the launcher's
[embedded worker](../windows/runner/retro_core_host.cpp). The private
D: receipt `gt4-analog-race-e762e09` preserves the worker, calibration
script, paired captures and packet logs.

Both cars started the same race. With short samples of magnitude 8,192
and 16,384 the steering indicator stayed near its neutral x-coordinate
of 320. Full-scale opposing commands moved it to x=394 and x=241.
The later 20,500 and 24,576 samples produced intermediate indications
in both directions. These observations verify graded steering in both
workers. The samples began from different driving states and do not
establish an exact deadzone or steering curve. Full-scale pulses at
speed sent the cars into opposite barriers. The next driver should use
short intermediate corrections with road feedback and leave full-scale
commands out of normal steering.

At step 41 each peer recorded one DHCP lease. The host transmitted
3,411 UDP/5000 packets and received 3,306. The guest transmitted 3,306 and
received 3,408. Both worker processes exited zero with empty fault logs.
The two role-card seed hashes were unchanged. This calibration used the
local UDP fixture with the production frame filter. Neither car finished.


### Tsukuba course and race telemetry probe

The two headless clients navigated the LAN course picker and confirmed
all six options: FISCO 90's, Mid-Field, High-Speed Ring, Infineon SP,
Tsukuba and Laguna Seca. The picker showed Tsukuba at 1.27 miles.
Both clients entered its two-lap race in the Toyota Superautobacs Apex
MR-S with automatic transmission, TCS and ASM, and Racing Hard tires.
The private D: receipt `gt4-course-race-da13d3e` retains the course and
race captures, low-speed HUD digit reader, driver script and logs.

At step 85 both HUDs showed 31.083 seconds on lap one. The host had
reached the first turn, and the guest had hit the straight-side
barrier. The driver using the minimap and numeric speed alone failed
to keep both cars on the road. Each worker recorded one DHCP lease.
The host sent 5,760 UDP/5000 packets and received 6,102. The guest
sent 6,105 and received 5,760. Both exited zero with empty fault logs
and unchanged role-card seeds. The local transport was the same UDP
fixture and production frame filter used in the preceding run.

The bounded trace retained 2,475 host and 2,470 guest race datagrams.
The larger UDP payload lengths include 74, 146 and 218 bytes. This
establishes the length pattern for this capture, with field meanings
still open. The local `analyze_race_packets.py` aligns 46 host and 53
guest HUD samples to 74-byte payloads. Candidate offsets 6 and 72
tracked progress in the moving samples but kept increasing while the
guest marker was stationary. The value at offset 18 also changed
during that stopped interval. Those correlations are insufficient
to use these values as car coordinates. A second run with controlled
movement or direct road-view feedback is needed before closing the
race-finish gate.

### Tsukuba road-view steering

The minimap controller's heading estimate lagged the car after a slide.
The next headless pair used the 640 × 448 bumper view to estimate the
asphalt corridor, with the HUD speed digits limiting throttle. The
private D: receipt `gt4-road-feedback-3ddd0ff` includes the detector,
the nine labeled capture checks, the input loop, and the two worker logs.

Both clients entered the two-lap race, stayed on the opening straight,
and reached the first hairpin. At 32.350 seconds on lap one, the host
was stopped near the outside edge and the guest was approaching the
turn at 32 mph. The test driver stopped both workers when it could no
longer steer the host safely. Both exited zero with empty fault logs
and the role-card seeds preserved. The host transmitted 6,074 UDP/5000
packets and received 6,145. The guest transmitted 6,145 and received
6,071. Both obtained a DHCP lease. This run used local UDP and the
production frame filter.

Bright asphalt in the turn exceeded the detector's intensity cutoff.
At steps 178 and 179 it returned leftward targets at x=56 and x=0.
Raising the cutoff from 97 to 112 made the same frames return rightward
targets at x=412 and x=415, and step 184 showed the road to the right
at x=630. All nine prior capture checks still passed. The follow-up
driver uses a three-sample median to reject isolated steering reversals
and keeps steering when the speed read is temporarily unavailable,
with throttle released until the next readable sample.

The revised live pair (`gt4-road-feedback-v2-3ddd0ff`) reproduced the
wrong-way steering at a slightly different point. The host's filtered
target jumped from x=390 to x=38 at step 177, then stayed at x=0 for
three samples. It stopped near the outside edge at 32.283 seconds on
lap one, with the guest still moving at 23 mph. The controller stopped
at step 190 in both runs. Neither reached results. Both revised
workers ran 9,745 video frames, exited zero, recorded no faults, and
preserved the role-card seeds. Each received one DHCP lease. Both
transmitted 6,099 UDP/5000 packets. The host received 6,099 and the guest
received 6,097.

The offline cutoff result did not generalize to new views of the
same turn. Before another race, compare annotated road boundaries
with the detector's candidate and selected spans, including whether
each edge is clipped. Record the raw and filtered targets around the
reversal. The minimap's route bends right near the failure and can
serve as an independent check when the car marker is visible. The
remaining local race gate is a full two-player results screen.

#### Tsukuba hairpin and off-road visibility

At Desktop `9626059`, the private driver recorded all candidate road
spans, the selected span and clipped edges on each sampled row, and
both raw and filtered steering targets. The only driving change in
`gt4-road-edge-9626059` was raising the asphalt brightness limit from
112 to 135. In the previous run's step-176 host capture, the raw target
changed from x=0 to x=524. The new trace shows the wide right-hand road
span at y=242 and y=254. A narrow fence still appears as a candidate
at y=230. Nine labeled controls and three hairpin captures passed.

Both headless clients reached the exit straight at 36.216 seconds.
The test continued to 1:08.700 on lap one, when the guest left the
road and the driver stopped rather than guessing which way to steer.
At the stop the host was still moving at 17 mph. The guest's asphalt
edge was visible only in the lower-left corner, below the normal scan
rows. The host transmitted 11,684 UDP/5000 frames and received 11,030.
The guest transmitted 11,030 and received 11,682. Both workers exited
zero, recorded one DHCP lease and no faults, and left the role-card
seed hashes unchanged. This used the local UDP fixture with the
[production frame filter](../lib/core/online/retro_lan_transport.dart).

The recovery variant checks the lower corners only when the normal
scan loses the road. It requires consistent support on one side across
several rows outside the instrument cluster. The offline check found
the left road edge in the new guest capture and the right road edge in
the earlier host capture. The two barrier controls still returned no
road. These are changes to the private test driver.

The live recovery variant (`gt4-road-edge-recovery-9626059`) stopped
earlier, near the first hairpin exit at 36.766 seconds. The guest
stopped on grass beside a red-and-gray curb. A right-side guardrail
produced an isolated candidate on one normal scan row, so the driver
had no usable road estimate and did not check the lower corners.
Both workers exited zero with empty fault logs and preserved seed
hashes. Each obtained one DHCP lease. The host sent 6,782 UDP/5000
frames and received 6,945. The guest sent 6,948 and received 6,782.

The offline `road_curb_candidate.py` tries lower-corner recovery when
the main scan cannot select a road. It checks for several bands of
asphalt or alternating curb colors, with weak evidence on the
opposite side. It chose left in both saved grass excursions and
abstained in both saved barrier controls. This candidate has not run
in a live race. Neither of these trials reached the finish.
