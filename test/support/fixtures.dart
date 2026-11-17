import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A temporary folder removed after the test.
Directory temporaryFolder(String prefix) {
  final folder = Directory.systemTemp.createTempSync('anyps5_$prefix');
  return folder;
}

const elfHead = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0];
const selfHead = [0x4F, 0x15, 0x3D, 0x1D];

/// Writes a small synthetic dump: sce_sys/param.json, an eboot.bin starting with [eboot]
/// (an ELF by default) and the pictures named in [pictures].
String makeDump(
  String parent,
  String folderName, {
  String titleId = 'PPSA00001',
  Map<String, String> names = const {'en-US': 'Test Game'},
  String? defaultLanguage,
  bool defaultLanguageAtTop = false,
  String version = '01.000.000',
  List<int> eboot = elfHead,
  List<String> pictures = const [],
  bool bom = false,
  Map<String, String> files = const {},
  Map<String, Object>? ageLevel,
}) {
  final folder = p.join(parent, folderName);
  Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
  final localized = <String, Object>{
    for (final entry in names.entries) entry.key: {'titleName': entry.value},
  };
  final parameters = <String, Object>{'titleId': titleId, 'contentVersion': version, 'localizedParameters': localized};
  if (ageLevel != null) parameters['ageLevel'] = ageLevel;
  if (defaultLanguage != null) {
    if (defaultLanguageAtTop) {
      parameters['defaultLanguage'] = defaultLanguage;
    } else {
      localized['defaultLanguage'] = defaultLanguage;
    }
  }
  final json = utf8.encode(jsonEncode(parameters));
  File(p.join(folder, 'sce_sys', 'param.json')).writeAsBytesSync([
    if (bom) ...[0xEF, 0xBB, 0xBF],
    ...json,
  ]);
  File(p.join(folder, 'eboot.bin')).writeAsBytesSync([...eboot, ...List.filled(56, 0)]);
  for (final picture in pictures) {
    File(p.join(folder, 'sce_sys', picture)).writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
  }
  for (final entry in files.entries) {
    final file = File(p.join(folder, entry.key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return folder;
}

/// The PS4 parameter files of test/fixtures/ps4_param_sfo (made by PSL1GHT's sfo.py from the
/// .sfo.xml beside each): a game (CATEGORY gd, APP_VER 01.00), its update (gp, 01.02) and an
/// add-on (ac), all of title ANPS40001.
List<int> ps4ParamSfo(String kind) =>
    File(p.join('test', 'fixtures', 'ps4_param_sfo', '$kind.param.sfo')).readAsBytesSync();

/// Writes a PS4 dump: sce_sys/param.sfo from the fixture [kind], an eboot.bin starting with
/// [eboot] (a SELF by default, as a PS4 dump keeps it) unless [eboot] is null, and the pictures
/// named in [pictures].
String makePs4Dump(
  String parent,
  String folderName, {
  String kind = 'game',
  List<int>? eboot = selfHead,
  List<String> pictures = const [],
}) {
  final folder = p.join(parent, folderName);
  Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
  File(p.join(folder, 'sce_sys', 'param.sfo')).writeAsBytesSync(ps4ParamSfo(kind));
  if (eboot != null) File(p.join(folder, 'eboot.bin')).writeAsBytesSync([...eboot, ...List.filled(60, 0)]);
  for (final picture in pictures) {
    File(p.join(folder, 'sce_sys', picture)).writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
  }
  return folder;
}
