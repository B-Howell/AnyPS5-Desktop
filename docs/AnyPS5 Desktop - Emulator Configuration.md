# AnyPS5 Desktop emulator configuration

## Windows and Linux preview status

The Windows preview exposes managed PS1, PS2 and PS3. On Linux x64, PS1 uses the managed SwanStation setup, PS2 LAN has its own setup, and general managed offline PS3 setup remains gated. See the [Linux implementation plan](<AnyPS5 Desktop - Linux Online Implementation Plan.md#managed-ps1-setup-on-linux>) for the installed PS1 setup proof and the [multiplayer design](<AnyPS5 Desktop - Emulator Multiplayer Design.md#product-direction>) for parity and lobby requirements. PS5 onboarding does not include emulator setup. Button layouts for emulated games live on the per-game Controls page (Game settings → Controls, or Controls in the PS menu while playing), not in the Quick Menu.


This Windows x64 preview adds optional PS1, PS2 and PS3 support to the PS5
launcher. It uses the existing Home, library, controller navigation and
Quick Menu. Emulator setup stays under Settings. On Windows x64 the
existing onboarding library step adds a Skip option for users who want
to configure a library later.

## Set up a console

1. Open **Settings → Emulators → PS1**, **PS2**, or **PS3**, then **Setup**.
2. Select the embedded emulator. PS1 uses SwanStation and PS2 uses LRPS2.
   PS3 uses a verified RPCS3 Libretro package and needs a Vulkan driver.
3. For PS1 or PS2, select a BIOS dumped from your console. The launcher
   imports a private copy. PS3 Setup downloads Sony's official firmware
   after the RPCS3 package has been verified.
4. Optionally select a games folder. Setup shows its path and a preview
   of the recognized games. **Finish setup** returns to Home, including
   when the folder is empty.

[Managed setup](../lib/core/managed_retro.dart) installs Windows x64 cores
into launcher storage. The PS1 and PS2 prototype uses Libretro Buildbot
over HTTPS, validates the archive's expected size and the indexed DLL CRC,
and checks SHA-256 for known archive revisions. Before a general release,
the maintainers should decide how to pin, verify and license core
distribution. Cores, games, BIOS images, firmware and memory cards are
separate from the launcher source.

## Library and media

The [library scanner](../lib/core/game_library.dart) recognizes PS1 CUE
sheets with their tracks, M3U playlists, PBP images and CHDs. It recognizes
PS2 DVD dumps with a PS2 boot marker and PS2 CHDs. Use a console-named
root to disambiguate CHDs or supply a manifest. The
[PS3 disc reader](../lib/core/ps3_disc.dart) recognizes extracted disc
folders with PS3_DISC.SFB and PS3_GAME at the top level. Extract a decrypted
PS3 disc ISO to that folder layout before scanning it in AnyPS5.

An optional retro.json beside a PS1 or PS2 image can supply the platform,
title ID, name and media. Paths are relative to that title's folder.
For a nested multi-track PS1 dump, put the manifest and media beside the
CUE so the launcher discovers one entry and keeps its tracks together.
For the US Tekken 3 disc, use the boot serial `SLUS00402`. Its second
disc track contains CD audio that can be exported as a stereo WAV loop
for the `music` field. Keep original art and disc tracks separate from
any resized or looped exports.

```json
{
  "platform": "ps1",
  "titleId": "SCUS00000",
  "name": "My game",
  "disc": "game.cue",
  "icon": "cover.png",
  "background": "wallpaper.jpg",
  "music": "theme.wav"
}
```

PS3 disc folders are discovered automatically from their disc metadata.
At the disc root, cover.webp, cover.png or cover.jpg takes precedence
over PS3_GAME/ICON0.PNG. The launcher uses PS3_GAME/PIC1.PNG as the
wallpaper when present. For PS1 and PS2, the manifest can point at a
local WAV for looping selection music. The
[selection audio player](../lib/core/audio/theme_music.dart)
can also play one optional local WAV per console from ConsoleAudio in the
launcher config folder, using ps1-startup.wav, ps2-startup.wav and
ps3-startup.wav. Each preview profile has its own config folder. Copy the
same three local cues into the profile you want to test. Moving into the
game row selects the game's usual music.

**Settings → Emulators → Show as folders** puts each installed console
after the regular games on Home. Highlight a console to preview its
titles, then press Down to enter the row or Up to return. Before a core is
installed, its games remain individual tiles so First Play can offer
setup. Each highlighted console uses its bundled wallpaper and
[console logo](../lib/ui/console_badge.dart). Moving down changes the
[backdrop](../lib/ui/home.dart) to the selected game's artwork. The
[folder projection](../lib/ui/retro_home_folders.dart) uses real
library titles and preserves their IDs. Console indicators in this
submission use text labels. Experiment artwork stays in its local profile.

### Multi-disc PS1 games

Use one UTF-8 M3U playlist with one relative CUE or CHD filename per line
in disc order. Point the title's manifest at the playlist and keep its
existing title ID, folder, and artwork. This gives the library one game
entry. In standalone DuckStation, the playlist makes those discs
available in Change Disc and lets the title share its memory card.
[DuckStation's playlist implementation](https://github.com/stenzek/duckstation/blob/master/src/util/cd_image_m3u.cpp)
opens each disc separately and switches the active image.

The local library scan found one Metal Gear Solid entry with discs 1–2
and one Final Fantasy VII entry with discs 1–3. The FFVII playlist uses
the exact former Disc 1 filename stem with the `.m3u` extension.
The existing [Windows core host](../windows/runner/retro_core_host.cpp)
derives its PS1 card filename from the launch path's stem, so this
preserves the card filename without changing any saves.

The embedded host still needs a Quick Menu disc selector. The intended
flow shows the inserted disc and ordered choices. It uses the core's
disc-control interface to eject, select, and reinsert within the same
session. Keep the tile and memory card identity fixed, and leave the
game running at its own change-disc prompt. Verify each swap and a
subsequent save in a scratch profile before shipping the control.

## Play and tune

Press PS/Guide or Escape to open the Quick Menu over the embedded game.
Resume and Close return to the same session. Losing focus clears held
inputs. Settings for existing portable DuckStation and PCSX2
installations remain available as an advanced path.

The existing launch card keeps the title, cover, and single progress bar
visible during embedded PS1 and PS2 startup, including while the core
outputs blank frames. The [Windows host](../windows/runner/retro_core_host.cpp)
reports when Flutter first reads a visible game frame. The
[embedded session](../lib/ui/embedded_retro_game.dart) latches that signal
for the [launch card and startup timeout](../lib/ui/app_model.dart).
Later in-game fades do not show the card again. RPCS3 retains its
compile and shader progress.

| Core | Controls exercised in the same session |
| --- | --- |
| SwanStation | Internal resolution and texture filtering |
| LRPS2 | Internal resolution, anisotropic filtering and trilinear filtering |
| RPCS3 | Internal resolution and anisotropic filtering |

The [Windows host](../windows/runner/retro_core_host.cpp) retains the last
frame when applying settings that require an in-memory checkpoint.
SwanStation restores the checkpoint after changing its active renderer.
LRPS2 reopens its core for a resolution change and restores the checkpoint
behind the same Flutter texture. The launcher saves a selected resolution
after the new frame is available. RPCS3's tested live options use its
existing Vulkan device.

From a game's tile, open **Game Settings → Auto Optimize**. The launcher
reads the graphics adapter, display height, and logical CPU count without
booting the game. It computes a recommendation directly from those inputs and
the game's media. It compares the recommendation against the title's
effective settings, including inherited PS3 defaults. **Apply** stays at the
bottom of the review and appears only when there are changes to save.
Up and Down move through each change and scroll it into view. Backing out
discards the preview. Saving writes the selected game's settings
for the next launch and displays a check mark.

The [recommendation policy](../lib/core/retro_launch_optimizer.dart) uses
the embedded cores' advertised settings for resolution, filtering,
rendering, CPU execution, and I/O where applicable. PS2 checks CPU headroom
before recommending 4×. PS3 allows up to 200% on a 1440p or larger display
with at least 12 GiB dedicated video memory and 12 logical CPU threads.
SwanStation uses a longer disc read-ahead for CHD media, including playlists
with CHD discs, when there are at least eight logical threads. Compatibility
choices such as PS2 MTVU and fast CD/DVD stay at their configured values.
If adapter detection fails or the PS3 adapter is ambiguous, the preview
explains why it cannot recommend changes and offers no Apply action.
These are hardware and media estimates made before gameplay can be measured.
The [preview](../lib/ui/retro_tuning_panel.dart) and
[per-game save path](../lib/ui/retro_launch_optimization.dart) share the
same review layout with **Quick Menu → Graphics → Auto Optimize**.
**In this session** uses the core's live update path. **Next launch**
queues the setting. **Advanced** shows effective values and applies manual
edits when you select **Apply changes**, which clears the check mark.
The online preview restricts changes during active multiplayer.
The [optimizer policy tests](../test/core/retro_optimizer_test.dart) cover
hardware and disc-media variation. The
[prelaunch workflow tests](../test/ui/retro_quick_optimize_test.dart) cover
controller navigation, dismissal, failed detection, and save on Apply.

[Compare gameplay performance](../lib/ui/retro_game_tuning.dart) measures a baseline and
a temporary candidate while the player repeats the same section. It
restores the baseline before offering Apply. The comparison uses frame
pacing and audio telemetry. Check the image yourself before applying a
candidate. [Restart Trials](../lib/ui/retro_restart_workflow.dart) are a
separate path for startup settings such as CPU or renderer selection.
Save in-game first for those trials. The menu marks startup-only settings.

For multi-disc PS1 titles, Play opens the [disc picker](../lib/ui/retro_disc_menu.dart)
and marks the last played disc. **Quick Menu → Change disc** changes media
inside the same game surface. An inserted disc becomes last played after
the emulation advances. The offscreen Windows SwanStation check booted Metal
Gear Solid on Disc 2 and Final Fantasy VII on Disc 3, swapped both to Disc 1
while paused, then resumed each on its original texture.

The [Controls page](../lib/ui/retro_embedded_controls.dart) of an emulated game
(Game settings → Controls, or Controls in the PS menu while playing) remaps
every button, keeps named profiles and decides which games a profile applies
to.

**The controller.** The left of the page draws the emulated console's own
controller from one [SVG asset](../assets/retro/controller-dualshock.svg): grey
for PlayStation, dark for PlayStation 2, black with a round PS button for
PlayStation 3. The [art reader](../lib/ui/retro_pad_art.dart) turns each shape
into a path and keeps its `id` and `data-role`. The
[art view](../lib/ui/retro_pad_art_view.dart) paints it, fills an input with
its colour as far as it is pressed (L2 and R2 fill gradually), moves the stick
caps, and puts a label on a line out to every input. Labels are sized like the
rest of the screen's text and the drawing takes the width left between them;
labels that would overlap are spread down their side, and a pane too narrow for
labels shows the drawing alone. The
[controller pane](../lib/ui/retro_controls_art.dart) feeds it the selected
player's controller. It shows the older `PadDiagram` until the asset has
loaded, and keeps showing it if the asset cannot be read.

**Replacing the artwork.** The asset is meant to be swapped, within this
contract:

- The reader takes `path`, `circle` and `rect` elements that carry a
  `data-role` (body, part, detail, outline, ring, label, led, symbol). It does
  not apply `transform` attributes or read other shapes, so coordinates must be
  final. Paths may use M L H V C S Q A Z, absolute or relative.
- Every input needs one shape with its id: `btn-cross`, `btn-circle`,
  `btn-square`, `btn-triangle`, `btn-up`, `btn-down`, `btn-left`, `btn-right`,
  `btn-l1`, `btn-r1`, `btn-l2`, `btn-r2`, `btn-l3` and `btn-r3` (the stick
  caps), `btn-select`, `btn-start`. Face-button signs are stroked shapes with
  `sym-cross`, `sym-circle`, `sym-square`, `sym-triangle`.
- `data-only="analog"` marks what only the DualShock and DualShock 2 have
  (`btn-analog`, its light, its lettering); `data-only="ps"` marks the
  DualShock 3's `btn-ps`.
- Line weights, the stick travel, the ring drawn in each stick cap and the
  L1/L2/R1/R2 lettering are set in the art view in the units of a drawing about
  974 wide, seen from the front with the shoulder buttons above the body. Art
  at another scale or angle needs those numbers, and the sides the labels sit
  on (`RetroButtonMap.leftSide`, `rightSide`, `topSide`), revisited.

**What a label says.** Each label names the button on the player's controller
that presses that PlayStation input, in amber when it is not the standard one.
An input lights when the button that does it is held, so the drawing shows what
the game receives. The inputs are not rows in the list beside the controller:
the labels are the only place to change them.

**Changing a button.** Choosing a label makes it wait ("Hold a button…").

- The button that should take the input is **held** for half a second on the
  controller of the player being set up; the label fills while it is held. The
  button that had the input gets the other one's, so the two trade places
  (`RetroButtonMap.give` in the
  [button layout](../lib/core/retro_button_map.dart)). An input that had no
  button leaves the giving button's old input without one, and its label then
  says Not used. Extra buttons an older layout put on the same input are left
  unused, so an input always ends with one button.
- A **tap** does nothing, so a press meant for moving about can never reassign
  an input. A tap of the launcher's Back button (Circle, or Cross when Circle
  confirms) cancels, from any controller and whatever else is being held at
  the time; held on the player's controller for the full half second, Back can
  be given away like any other button.
- The wait ends by itself six seconds after the label was chosen; taps do not
  push that back, and a hold in progress at that moment may finish. Until then
  no button, stick or key moves the focus. Esc, the controller going away, PS,
  the page closing, or a click anywhere the launcher draws all end the wait
  without changing anything. Every such click reaches the launcher's one
  pointer handler (`_pointerDown` in
  [the launcher shell](../lib/ui/launcher.dart)) as the button goes down.
  While a label waits, that handler ends the wait and takes the whole gesture,
  so what is under the pointer and acts on a tap, a drag or a long press does
  not: a row, the Back pill, the area around the panel, another label, a toast
  or a card drawn over the page; the right button's Back is skipped too. This
  does not depend on the screen having drawn the wait yet. A widget that acts
  on the bare pointer going down, without a gesture, would still see it; none
  on this page changes a setting that way.
- The window's own title bar and edges belong to the system, so a click there
  never reaches the launcher. What it does to the window ends the wait: going
  full screen (what the title bar's Maximize does on Windows), a new size
  (Maximize on Linux, dragging an edge), or the window no longer being the
  active one (minimised, another window clicked). The wait ends when the
  launcher is told of the change, which is not guaranteed to be before a
  button already held completes its half second. A click on the title bar that
  changes none of those, such as starting to move the window, ends nothing: a
  button held through it can still take the input, and otherwise the wait runs
  to its six seconds.
- Remapping never changes how the launcher's own menus are driven: the layout
  applies to the game only.

**Moving about with a controller.** The page opens with the focus on a label
(Cross), since the labels are what the page is for. The directions follow the
screen: up and down along one side of the controller, left and right across to
the label level with it on the other side, up from a side's first label to
Select or Start. The list is to the right of the controller, so right from the
right-hand labels reaches it, as does down from the last label of a side. From
the list, left returns to the label the focus was last on, and so does up from
the first row. With a controller that holds for every row: a controller changes
a row's value only after the row is chosen with the confirm button (Cross, or
Circle when that is set to confirm; then left and right are the value until
confirm or Back), so until then left is free and always goes back. With the keys, left and right step a value at once, so left goes back
only from a row that has no value. While a row's value is being changed with a
controller, Back ends that and a second Back leaves the page. Player 1's
controller on this page is the one driving the launcher, the last to have moved
the focus, unless that one is seated as another player: then it is the
launcher's first controller that is not, and if every connected controller is
seated elsewhere Player 1 has none. Choosing a label for a player with no
controller does not wait; it says that player has no controller connected. Profile name is typed, so
choosing it with a controller only says to use a keyboard. L1 and R1 move to
the next game's Controls, and the focus goes back on a label there. When a
focused row goes (Save as a profile, Delete this profile), the focus moves to
Profile. The labels are rows after the
list's last so that one can hold the focus; `_retroLabelCommand` holds these
moves, and a change that adds or removes a row (Save as a profile) puts the
focus back on the row it was on when that row is still there. With the mouse a label is clicked. On a
mirrored screen (Arabic, Urdu) the list and the controller change sides but the
controller is drawn as it is, so among the labels left stays left and the list
is reached from the left-hand labels; Select and Start are beside neither. If
the asset cannot be read, a smaller plain controller is shown with every
input's label listed under it, so each can still be chosen with the mouse or
the controller.

**Profiles.** The [profile store](../lib/core/retro_control_profiles.dart)
keeps layouts by scope, and every game has its own: `gameId` for Player 1,
`gameId#p2` and up for the others. So a game always plays with what was chosen
on its own page, and choosing something for one game changes no other game. A
scope holds the name of a saved profile, a layout of its own, or both (the
unsaved layout stays behind a chosen profile, so Custom can be chosen again).

- **Profile** chooses Standard, Swap Cross and Circle, a saved profile, or
  Custom when the game has an unsaved layout. Changing a button while a saved
  profile is chosen changes that profile, for every game that uses it.
  Changing one on Standard or the swap makes the Custom layout.
- **Save as a profile** appears for a Custom layout and stores it under the
  first free "Profile 1", "Profile 2", …; a saved profile is offered on every
  game's page. **Profile name** renames the chosen profile and **Delete this
  profile** removes it, sending the games that used it back to their own
  layout.

The three preference keys are `retroButtonMaps` (a scope's own layout),
`retroControlProfiles` and `retroProfileChoice`; all three travel with a
launcher profile. Layouts saved before profiles existed used the same per-game
scopes and are read as they were. A change reaches the running game at once,
for every seat. Swap sticks and Reset stay on the page; the controller test is
not offered here (it is in Settings › Controllers).

The [screen test](../test/ui/retro_controls_screen_test.dart) reads the real
asset and checks that every input has a shape and a side. It covers a held
button taking a label over and a tap not doing so; Back (alone and with
another button held), the six seconds, the page closing, the controller going
away, another controller's buttons, a library scan during a hold, and real
clicks while a label waits (on a row, with no frame drawn in between, with the
right button, on the Back pill and held down outside the panel), as well as
the window going full screen or changing size;
the focus moving between the labels and the list, on a mirrored screen too
(top labels included), and staying put when a row appears; the page when the
asset cannot be read; the profile rows; older saved layouts; and
the trade for layouts with two buttons on one input. It writes pictures of the page to
`ANYPS5_SCREENSHOT_DIR` when that is set. The
[controls test](../test/ui/embedded_ps1_controls_test.dart) covers a game
keeping its layout across launches, the older swap setting, the PS menu entry
and a second controller taking Player 2. Neither has been run against a built
launcher with a physical controller.

**Artwork licence.** The drawing comes from the PCSX2 project
(`pcsx2-qt/resources/images/DualShock_2.svg`) and is GPL-3.0; the source and the
changes made are recorded in a comment at the top of the asset. This launcher
is GPL-2.0-only and upstream declined GPL-3 code and assets in
[AnyTogether/AnyPS5-Desktop#86](https://github.com/AnyTogether/AnyPS5-Desktop/pull/86),
so this asset stays on the fork and ships in every build made from this
branch: replace it with artwork under a compatible licence before any of this
is offered upstream.

## RPCS3 preview and release gates

AnyPS5 loads the RPCS3 Libretro library directly in its embedded runner.
RetroArch served as a separate frontend for the stock-core boot control.
The launcher supplies its own video, audio, controller and progress
integration. Users only need the verified core package and its prerequisites.

The [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch) relays
compilation progress, reports active controller ports and confines offline
peer-to-peer traffic to loopback. The [package builder](../tool/build-rpcs3-preview.sh)
uses the [RPCS3 Libretro Windows CLANG64 recipe](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/.ci/build-windows-clang-libretro.sh).
It pins RPCS3 Libretro, FFmpeg and Abseil by commit. RPCS3 submodules follow the
pinned tree. MSYS2 dependencies and upstream's optional embedded game-patch
database can change between builds. The builder records the MSYS2 versions.
Its output is a reviewer build with its own digests.

RPCS3 stores its PPU object cache beneath the persistent `system/rpcs3` core
directory. A warm startup can still scan and validate PPU modules; the pinned
core used to label that phase “Compiling PPU Modules” before it knew whether a
cache hit or a real compile was needed. The frontend patch now reports that
phase as scanning and retains the separate compile label for missing objects.
In the RPCS3 log, `PPU: LLVM: Loaded module` records reuse and
`PPU: LLVM: Compiled module` records actual host compilation.

The legacy package retained discovered guest SPU programs, then rebuilt
native SPU code on launch. In a Skate 3 warm-start log (BLUS30464,
2026-11-09), RPCS3 loaded 219 PPU modules, compiled zero PPU modules, and
finished building 6,281 SPU programs at 20.98 seconds.

The [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch) adds a
separate per-title native object cache for x64 Libretro when the LLVM SPU
decoder and SPU Cache are enabled. It leaves the original debug cache alone.
The cache key covers the final LLVM IR, the core cache ABI, the LLVM version
and the CPU target. Instructions that embed process-specific values produce
a different key when those values change. The loader accepts only complete
gzip streams containing relocatable x64 ELF objects with the expected SPU
entry symbol. Rejected entries are recompiled and replaced atomically. Warm
launches still analyze guest SPU programs, link native objects and build the
SPU interpreter.

On Linux x64, two independent headless LittleBigPlanet GOTY launches shared
the same profile, firmware and preexisting PPU and guest SPU caches. The first
process created 2,746 native objects. The second loaded 2,704 objects and
wrote 42 additional ones. RPCS3's SPU worker completion timestamp moved from
15.83 to 4.64 seconds. The unmodified core took 9.32 seconds for the same
2,746 programs from the same guest-cache seed. Both patched runs rendered
Vulkan frames, produced audio, changed resolution in game and stopped
cleanly.

A third launch used a clone of the warm profile with three deliberately
damaged entries. It rejected a truncated gzip, a complete gzip containing
non-ELF data, and a valid ELF from another SPU entry. All three replacements
matched the original decompressed objects byte for byte, 2,702 other
objects were reused, and the game rendered and stopped cleanly. These runs
used Clang and LLVM 22.1.8. The tested Linux core SHA-256 was
`135671eb895f080c8cf09ca78b8d309e88717a4ea12cde47bd8c63ba79016be3`.

The Windows reviewer package booted LittleBigPlanet GOTY 1.30 in a clean
profile, then reopened the same profile in separate processes. One warm
run loaded 96 cached PPU modules, compiled none, and logged 1,897 native
SPU object loads. It produced Vulkan frames and non-silent audio and
stopped cleanly within 11.39 seconds of process start. Warm launches
still scan guest programs and link the cached objects. The
[PS3 online plan](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md>)
records the exact packages and profile checks. On Windows, the v3 package
also started Skate 3 (BLUS30464) twice through the production native
session and Vulkan bridge. The isolated profile started with a copy of
the title's legacy compiler cache and no saves. Both boots reused 219 PPU
objects and compiled zero PPU modules. The first populated 6,280 native
SPU cache files and the second logged 6,259 native object loads. Both
published Vulkan frames and stopped cleanly. RPCS3 can still show
“Building SPU Cache” while reading and linking cached objects. Matched
gameplay frame times and incompatible CPU or build fallback remain open.
The frontend and optional network-policy patches apply together to the pinned
RPCS3 source. On Windows x64, that source explicitly targets ELF for the SPU
JIT, so the object-format check applies to both Linux and Windows packages.
The app pins the qualified Windows v3 archive and DLL by default. It also
accepts a build-specific digest override for reviewers. A launcher build can
upgrade an existing legacy core before a PS3 boot when its configured package
directory contains the matching `rpcs3_libretro.dll.zip`. The installer first
checks the archive, extracts to a temporary directory, validates the DLL, then
replaces only `rpcs3_libretro.dll`. If the package is missing or either digest
does not match, installation stops before replacing the existing core. Keep
the firmware, emulator cache, and saves in their existing locations. The first
boot after upgrade can still create native objects. Later launches reuse them.

The older Windows UnifiedRetro launcher still has the legacy DLL, whose SHA-256
starts with `7ac7504d`, and a legacy ZIP. Updating source alone does not change
an already running build. For the next build, point
`ANYPS5_MANAGED_CORE_PACKAGES` at the qualified v3 `packages` directory from
the [PS3 plan](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md>).
No digest override is needed for that exact package because its archive and
DLL hashes are pinned in the app. The pre-launch installer upgrades the core
when the user starts a PS3 game. The PS3 Setup action can also perform the
upgrade. Do not ship the old ZIP under the v3 pins. A mismatched or missing
package leaves the existing DLL untouched and shows a setup error.

The isolated Windows upgrade test replaced a legacy DLL with the qualified v3
package while firmware, cache and save sentinels remained unchanged. A second
install call kept the verified DLL and its modification timestamp. The cold
and warm Skate 3 results above were separate qualification runs, not a matched
performance comparison. To distinguish startup scanning from actual work,
use the detailed RPCS3 log: `PPU: LLVM: Loaded module` means reuse,
`PPU: LLVM: Compiled module` means a PPU cache miss, and
`LLVM: Loaded module: spu-objects-v1-` means native SPU object reuse. The SPU
progress label can remain active while cached objects are loaded and linked.
The [managed-core tests](../test/core/managed_retro_test.dart) cover successful
upgrade, preservation of firmware/cache/save files, rejected digest safety,
and repeat installation.

### Build a PS3 test package

Use a disposable [MSYS2](https://www.msys2.org/) installation. The upstream
recipe replaces several CLANG64 import archives with static libraries, so
keep this install separate from your normal development toolchain. A signed
[portable MSYS2 archive](https://www.msys2.org/docs/installer/) works for
headless builds. Verify its detached signature against the published
fingerprint before extracting. Run `pacman -Syu` and open a fresh shell if
the runtime update closes the first one. Finish updating, then run these
commands in **CLANG64** from a checkout of this branch. Use a short build path
with space for the compiler outputs.

```bash
pacman -S --needed base-devel curl git p7zip \
  mingw-w64-clang-x86_64-{clang,cmake,lld,ninja,llvm,nasm,pkgconf,opencv,glew,vulkan-headers,vulkan-loader}
bash tool/build-rpcs3-preview.sh /c/anyps5-ps3-review
```

For the dashboard update importer and native-online profile testing, add
`--network-policy` to the build command and use a new output directory.
That variant exports the policy selector the installer checks before loading
a staged PKG. For the import and provider acceptance checks, see the
[PS3 native co-op plan](<AnyPS5 Desktop - PS3 Native Co-op Implementation Plan.md>).

The output path must be new. The resulting `packages` directory contains
`rpcs3_libretro.dll.zip` and `ps3-core-digests.txt`. Keep the two SHA-256 values
from your own build. The installer verifies the ZIP before extraction and
checks the DLL before publishing it and at subsequent launches. The default
test package hashes still apply when no digest override is configured.
The [checkout attributes](../.gitattributes) keep the shell script and patch
in LF format on Windows.

Build the launcher as described below, then set the reviewer environment in
PowerShell and start the launcher from the same shell. Use a new profile path.

```powershell
$env:ANYPS5_DESKTOP_EXPERIMENT_HOME = 'C:/anyps5-ps3-clean-profile'
$env:ANYPS5_MANAGED_CORE_PACKAGES = 'C:/anyps5-ps3-review/packages'
$env:ANYPS5_PS3_CORE_DIGESTS = (Get-Content "$env:ANYPS5_MANAGED_CORE_PACKAGES/ps3-core-digests.txt" -Raw).Trim()
& .\build\windows\x64\runner\Release\anyps5_desktop.exe
```

Finish normal launcher onboarding. For a PS3-only test, skip the games
folder and PS5 engine steps and choose Offline. Open
**Settings → Emulators → PS3 → Setup**, install the core and let the
launcher fetch the checksum-verified official Sony firmware. Add a folder
containing your extracted PS3 disc and finish setup. On the first launch,
check compilation progress, the embedded viewport and PS/Guide or Escape
opening the Quick Menu. Resume should return to the same session.

For a public one-click install, the maintainers need to approve the RPCS3 fork
and patch, where to publish the package and its corresponding source and
notices, and how to pin and update the downloadable ZIP and DLL. The reviewer
workflow uses a local build and explicit hashes. It needs no published binary.

The [Vulkan bridge](../windows/runner/retro_vulkan_video.cpp) presents the
RPCS3 frame to Flutter and rejects synchronization it cannot support.
The [trophy reader](../lib/core/ps3_trophies.dart) reads PS3 definitions and
the local RPCS3 profile. LittleBigPlanet GOTY definitions and a controlled
unlock record were read in the experiment. That does not establish
physical-controller trophy unlocks or broad game compatibility.

## Build and verify

Use the Flutter version in the [upstream CI workflow](../.github/workflows/ci.yml)
with the Windows Desktop C++ toolchain. A fresh
[Windows runner build](../windows/runner/CMakeLists.txt) fetches pinned,
hash-verified Vulkan headers. Run `flutter pub get`, `flutter analyze`
and `flutter build windows --release` from the repository root. Use a short
build path when running Ninja on Windows. The [Windows CMake settings](../windows/CMakeLists.txt)
keep `/W4` and `/WX` enabled and pass `/wd4100` as one MSVC argument. Literal
quotes around `4100` can survive Ninja generation and cause MSVC error D8021.
For a separate local test profile, set ANYPS5_DESKTOP_EXPERIMENT_HOME to an
absolute scratch directory before launching. The profile has its own
config, emulator storage and logs, and skips desktop file and URL
registration.

## Verification and suggested review order

The local experiment exercised installation with empty profiles and
manual and tuner graphics transitions offscreen. Crash Bandicoot 2
reached its first warp room. Vice City and LittleBigPlanet verification
covered the opening sequence and tutorial. These are representative
checks, not a compatibility matrix. The upstream draft is a separate
port and should be tested on its own commit.

The [package installer tests](../test/core/managed_retro_test.dart) cover
missing packages, invalid pins, ZIP and DLL mismatches, and retrying with
an installed core. Use a new profile root for the manual PS3 acceptance run.

Start review with Windows PS1 and PS2 library, setup and embedded
controls. Review the PS3 host and packaging separately. Keep core-license
compatibility, reproducible packages and complete upstream CI as release
gates. PS5 and Linux behavior require regression coverage on the proposed
branch.
