/// Where a SwanStation option is shown. The host lists every option SwanStation lets the player
/// change now (about fifty for a PS1 game, in SwanStation's order); the launcher groups them.
enum RetroOptionSection {
  /// The picture: SwanStation's `GPU`, `Display` and `TextureReplacements` options. They belong on
  /// the game's Graphics page, not in the in-game menu.
  graphics,

  /// The sound: SwanStation's `Audio` options and Mute CD Audio. The menu adds the host's volume.
  audio,

  /// The controllers: SwanStation's `Controller`, `Controller1`, `Controller2`, … and
  /// `ControllerPorts` options.
  controller,

  /// The console: its region and BIOS (`Console`, `BIOS`), the CD-ROM's region check and speed,
  /// and the CPU's clock.
  console,

  /// Everything else: how SwanStation runs the CPU and reads the disc, its compatibility settings
  /// and hacks, and any option a later SwanStation adds.
  advanced,
}

/// The section a SwanStation option key is shown in, or null for an option players have no use
/// for in the launcher (they are not shown, and a value kept for one is not sent):
///
/// - the on-screen messages (`Display_ShowOSDMessages`): the host draws no messages;
/// - the four display offsets (`Display_ActiveStartOffset`, `Display_ActiveEndOffset`,
///   `Display_LineStartOffset`, `Display_LineEndOffset`), sixty-one values of SwanStation's own
///   calibration each;
/// - texture replacements (`TextureReplacements_*`), which read a texture folder the host does
///   not give SwanStation;
/// - the development console's 8 MB of RAM (`Console_Enable8MBRAM`), which no game sold uses;
/// - the CPU recompiler's debugging switches (`CPU_RecompilerICache`,
///   `CPU_RecompilerBlockLinking`, `CPU_FastmemMode`);
/// - the light gun crosshair (`Controller_ShowCrosshair`): the host plugs in only DualShocks.
///
/// Keys are `swanstation_<Group>_<Name>`; a key of another form is [RetroOptionSection.advanced],
/// as every LRPS2 option of a PS2 game is (`pcsx2_...`), but its BIOS (`pcsx2_bios`), which the
/// player chooses in Settings › Emulators and the launcher gives at every start.
RetroOptionSection? retroOptionSection(String key) {
  if (key == 'pcsx2_bios') return null;
  const prefix = 'swanstation_';
  if (!key.startsWith(prefix)) return RetroOptionSection.advanced;
  final name = key.substring(prefix.length);
  if (_hidden.contains(name) || name.startsWith('TextureReplacements_')) return null;
  if (_console.contains(name)) return RetroOptionSection.console;
  if (name == 'CDROM_MuteCDAudio') return RetroOptionSection.audio;
  final separator = name.indexOf('_');
  final group = separator < 0 ? name : name.substring(0, separator);
  if (group == 'GPU' || group == 'Display') return RetroOptionSection.graphics;
  if (group == 'Audio') return RetroOptionSection.audio;
  if (group.startsWith('Controller')) return RetroOptionSection.controller;
  if (group == 'Console' || group == 'BIOS') return RetroOptionSection.console;
  return RetroOptionSection.advanced;
}

/// Whether the option at [key] is shown somewhere, so a value kept for it is sent to the host.
bool retroOptionShown(String key) => retroOptionSection(key) != null;

/// Whether a value kept for [key] goes to a game's `start`: one shown somewhere, and LRPS2's
/// (`pcsx2_...`) to a [ps2] game only, every other to a PS1 game only, since the two cores' options
/// share one list of values the player chose.
bool retroOptionSent(String key, {required bool ps2}) => key.startsWith('pcsx2_') == ps2 && retroOptionShown(key);

/// An option's title without SwanStation's own " (Restart)": the menu says that under every option
/// that takes effect only when the game starts again, not only under those SwanStation named so.
String retroOptionTitle(String title) {
  const mark = '(Restart)';
  final trimmed = title.trimRight();
  if (!trimmed.endsWith(mark)) return title;
  final rest = trimmed.substring(0, trimmed.length - mark.length).trimRight();
  return rest.isEmpty ? title : rest;
}

const _hidden = {
  'Display_ShowOSDMessages',
  'Display_ActiveStartOffset',
  'Display_ActiveEndOffset',
  'Display_LineStartOffset',
  'Display_LineEndOffset',
  'Console_Enable8MBRAM',
  'CPU_RecompilerICache',
  'CPU_RecompilerBlockLinking',
  'CPU_FastmemMode',
  'Controller_ShowCrosshair',
};

const _console = {'CDROM_RegionCheck', 'CDROM_ReadSpeedup', 'CDROM_SeekSpeedup', 'CPU_Overclock'};
