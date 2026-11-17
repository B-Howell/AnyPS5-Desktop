import 'dart:io';

import 'package:path/path.dart' as p;

import 'param_sfo.dart';

/// An extracted PS3 disc: a folder with PS3_DISC.SFB and PS3_GAME, which RPCS3 boots from
/// PS3_GAME/USRDIR/EBOOT.BIN.
abstract final class Ps3Disc {
  /// The disc's PARAM.SFO, which names the game.
  static String paramsFile(String folder) => p.join(folder, 'PS3_GAME', 'PARAM.SFO');

  /// Whether [folder] holds a whole extracted disc.
  static bool isDisc(String folder) =>
      File(p.join(folder, 'PS3_DISC.SFB')).existsSync() &&
      File(p.join(folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN')).existsSync() &&
      File(paramsFile(folder)).existsSync();

  /// The text values of the disc's PARAM.SFO (TITLE, TITLE_ID, APP_VER...), null when [folder]
  /// is no disc or its PARAM.SFO cannot be read.
  static Map<String, String>? metadata(String folder) =>
      isDisc(folder) ? ParamSfo.read(paramsFile(folder))?.texts : null;
}
