# AnyPS5 Desktop emulator configuration

## Set up a console

Open **Settings → Emulators**, choose PS1, PS2 or PS3, then **Setup**:

1. Install the emulator. PS1 uses SwanStation, PS2 uses LRPS2 and PS3 uses RPCS3, which needs a
   Vulkan driver. [Managed setup](../lib/core/managed_retro.dart) downloads each emulator into
   launcher storage and checks it against a pinned SHA-256.
2. Select a BIOS dumped from your own console (PS1, PS2); the launcher keeps a private copy.
3. Optionally select a games folder. **Finish setup** returns to Home.

An emulator already installed on the PC (DuckStation, PCSX2, RPCS3) can be chosen instead.
Games, BIOS images, firmware and memory cards are never part of the launcher.

## Library

The [library scanner](../lib/core/game_library.dart) finds PS1 CUE sheets, M3U playlists, PBP
and CHD images, PS2 DVD dumps and CHDs, and extracted PS3 disc folders (PS3_DISC.SFB and
PS3_GAME at the top level). A console's games appear only once its emulator is installed or
chosen (`retroPlayable` in the [folder projection](../lib/ui/retro_home_folders.dart)).
**Show as folders** puts each console after the regular games on Home.

An optional `retro.json` beside a PS1 or PS2 image supplies the platform, title ID, name, disc
and artwork; paths are relative to its folder. A multi-disc PS1 game is one M3U playlist with one
CUE or CHD per line, in disc order. A PS3 disc folder uses `cover.webp`, `cover.png` or
`cover.jpg` at its root before `PS3_GAME/ICON0.PNG`, and `PS3_GAME/PIC1.PNG` as its wallpaper.

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

## Playing

Games play inside the launcher window. A short **PS** press (or **Escape**) opens the Quick
Menu; holding PS (or Escape) for half a second goes to Home with the game paused, where its
tile says Resume. Button layouts are on the game's Controls page (Game settings → Controls, or
Controls in the Quick Menu). Graphics settings are kept per game.

## Online play

Online play for these games uses the launcher's AnyTogether sessions and invites. Closing the
game, leaving the session or closing the launcher ends it on AnyTogether, and a new game
replaces any older session the launcher no longer uses
([room admission](../lib/core/online/retro_online_rooms.dart)).
