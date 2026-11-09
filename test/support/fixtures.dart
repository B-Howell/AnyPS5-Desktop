import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Builds a small PARAM.SFO with string metadata for PS3 tests.
Uint8List ps3FixtureSfo(Map<String, String> fields) {
  final keys = fields.keys.map((key) => [...key.codeUnits, 0]).toList();
  final values = fields.values.map((value) => [...value.codeUnits, 0]).toList();
  final keyStart = 20 + fields.length * 16;
  final valueStart = keyStart + keys.fold<int>(0, (size, key) => size + key.length);
  final data = Uint8List(valueStart + values.fold<int>(0, (size, value) => size + value.length));
  final header = ByteData.sublistView(data);
  header.setUint32(0, 0x00505346);
  header.setUint32(8, keyStart, Endian.little);
  header.setUint32(12, valueStart, Endian.little);
  header.setUint32(16, fields.length, Endian.little);
  var key = 0;
  var value = 0;
  for (var i = 0; i < fields.length; i++) {
    final entry = 20 + i * 16;
    header.setUint16(entry, key, Endian.little);
    header.setUint16(entry + 2, 0x0204, Endian.little);
    header.setUint32(entry + 4, values[i].length, Endian.little);
    header.setUint32(entry + 12, value, Endian.little);
    data.setAll(keyStart + key, keys[i]);
    data.setAll(valueStart + value, values[i]);
    key += keys[i].length;
    value += values[i].length;
  }
  return data;
}

/// A temporary folder removed after the test.
Directory temporaryFolder(String prefix) {
  final folder = Directory.systemTemp.createTempSync('anyps5_$prefix');
  return folder;
}

/// Writes the ISO sectors needed to read a PS2 disc's boot serial and revision.
void writePs2IdentityIso(File iso, {required String bootSerial, required String revision}) {
  const sector = 2048;
  final bytes = Uint8List(sector * 22);
  final words = ByteData.sublistView(bytes);
  const descriptor = 16 * sector;
  const directory = 20 * sector;
  const config = 21 * sector;
  final text = ascii.encode('BOOT2 = cdrom0:\\$bootSerial;1\r\nVER = $revision\r\nVMODE = NTSC\r\n');
  bytes.setAll(descriptor, [1, ...ascii.encode('CD001'), 1]);
  words.setUint32(descriptor + 158, 20, Endian.little);
  words.setUint32(descriptor + 166, sector, Endian.little);
  bytes[directory] = 46;
  words.setUint32(directory + 2, 21, Endian.little);
  words.setUint32(directory + 10, text.length, Endian.little);
  bytes[directory + 32] = 12;
  bytes.setAll(directory + 33, ascii.encode('SYSTEM.CNF;1'));
  bytes.setAll(config, text);
  iso.writeAsBytesSync(bytes);
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
