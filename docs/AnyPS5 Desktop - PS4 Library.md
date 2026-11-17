# AnyPS5 Desktop PS4 library

The library lists PS4 dumps beside PS5 ones. A PS4 dump is a folder with an
`eboot.bin` and `sce_sys/param.sfo`; a PS5 dump has `sce_sys/param.json`
instead. Both are found by the same scan, in the same games folders, and show
in the same row, sorted by name. A PS4 tile carries a small **PS4** chip in
its top corner. PS4 games cannot be played yet: their tile and button say
**Not playable yet**, and pressing the button says why.

## What a PS4 dump says

[The dump parameters](../lib/core/dump_parameters.dart) read either file into
one shape, and every part of the library uses that shape: the
[scan](../lib/core/game_library.dart), the
[updates and add-ons beside a game](../lib/core/game_addons.dart),
[an update added from a dump](../lib/core/game_updates.dart),
[zipped dumps](../lib/core/game_archives.dart) and the
[watcher's check of a dump still being copied](../lib/core/library_watch.dart).
`param.json` is read first and `param.sfo` second, the order the engine's own
`AppMetadata` reads them in. The [PSF reader](../lib/core/param_sfo.dart) is
the same one the [PS3 disc scan](../lib/core/ps3_disc.dart) uses for
`PS3_GAME/PARAM.SFO`: the format is the same on both consoles (a `\0PSF`
header, then 16-byte entries of a key, a format of 0x0204 for text or 0x0404
for a 32-bit integer, a length and a value).

From `param.sfo` the library takes what shadPS4's game list takes:

| Field | Used as |
|---|---|
| `TITLE_ID` | the title ID (CUSA01234) |
| `TITLE` | the name; `TITLE_00` to `TITLE_30` are the name in each console language (0 Japanese, 1 American English, 2 French...), as locale tags |
| `APP_VER` | the version (01.09) |
| `CONTENT_ID` | an add-on's entitlement label, as for a PS5 add-on |
| `sce_sys/icon0.png` | the tile |
| `sce_sys/pic1.png` | the background (a PS5 dump's is `pic0.png`) |
| `sce_sys/snd0.at9` | the music |

`CATEGORY` (`gd` a game, `gp` its update, `ac` an add-on) does not decide what a
folder is. A game with its update copied over it, which people make for
emulators without an update overlay, keeps the update's `gp`, and is still the
game. As for a PS5 dump, where a folder is says what it is: `CUSA01234-UPDATE`
or `CUSA01234-patch` beside the game is its update, and `CUSA01234-DLC/<label>`
or a folder named by an add-on's content ID is an add-on. These are the
layouts shadPS4 users already keep. `PARENTAL_LEVEL` is a level from 1 to 11,
not an age, so a PS4 game has no age ratings and family settings treat it as
unrated.

## Why PS4 games do not play yet

The engine reads a PS4 dump's files: its `AppMetadata` falls back to
`/app0/sce_sys/param.sfo` for the title and title ID, its relinker reads the
PS4 needed-module tags, and the installed layout (`app0/` with `sce_module/`,
saves in `_sd`) is the same for both consoles. Released AnyPS5 still stops on
PS4 executables. Upstream issue boykopovar/AnyPS5#3093 tracks the relinker
work, and the fixes a PS4 title needs to get past the relink and its first
frames are open pull requests there. So [`DumpPlatform.ps4`](../lib/core/dump_parameters.dart)
says it does not run. While it does not, the [game's state](../lib/ui/app_model.dart)
is `NotPlayableYet`. Its unlock is refused, a new PS4 game is not prepared in
the background, and `anyps5_tool install` refuses it too. Once a released
engine runs PS4 executables, `runs` turns true and these games unlock like PS5
ones.

What a PS4 game would still need in the launcher then:

- the update overlay for a PS4 update folder (the engine reads
  `ANYPS5_UPDATE_DIR`; whether it does so for PS4 titles is not checked);
- trophies, which a PS4 dump keeps as `sce_sys/trophy/trophy00.trp`, not the
  `sce_sys/trophy2/*.ucp` the [trophy list](../lib/core/trophies.dart) reads;
- `APP_VER` passed on as the content version: the engine's `param.sfo` reader
  takes only the title, title ID, download data size and user parameters;
- `.ffpfsc` images, which are read for `param.json` only.

## The chip

[`PlatformChip`](../lib/ui/platform_chip.dart) is drawn by the
[game tile](../lib/ui/home.dart) for a dump of any console but the PS5. The
console's name is the same in every language. The two new texts,
`notPlayableYet` and `notPlayableYetDetail`, are in all 28 language files.

## Tests and fixtures

[The parameter tests](../test/core/dump_parameters_test.dart),
[the library tests](../test/core/ps4_library_test.dart) and
[the launcher tests](../test/ui/ps4_library_ui_test.dart) read the three
`param.sfo` files in [the fixture folder](../test/fixtures/ps4_param_sfo):
a game (`CATEGORY gd`, `APP_VER 01.00`), its update (`gp`, `01.02`) and an
add-on (`ac`), all of the made-up title `ANPS40001`. No game's files are in
the repository. Each fixture was written by `sfo.py` 0.2 from the
[PSL1GHT](https://github.com/ps3dev/PSL1GHT) SDK (MIT, `tools/ps3py/sfo.py` at
commit `dd4e8c9be744e3273d665c393fa6d97a87402e2e`), which writes the PSF format
from an XML list of values: `python sfo.py --fromxml game.sfo.xml game.param.sfo`.
The XML inputs ([game](../test/fixtures/ps4_param_sfo/game.sfo.xml),
[update](../test/fixtures/ps4_param_sfo/update.sfo.xml),
[add-on](../test/fixtures/ps4_param_sfo/addon.sfo.xml)) are kept beside the
files, so they can be made again. Their header (version 0x101) and entry formats
match a PS4 dump's `param.sfo`.
