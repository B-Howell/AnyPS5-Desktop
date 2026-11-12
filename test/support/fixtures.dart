import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/binary.dart';
import 'package:anyps5_desktop/core/embedded_core_host.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:path/path.dart' as p;

/// Minimal x64 PE export table for the PS2 LAN installer. It is never loaded.
Uint8List ps2LanFixtureDll({bool dev9 = true}) {
  const pe = 64;
  const optional = pe + 24;
  const section = optional + 120;
  const raw = 512;
  const rva = 0x1000;
  final bytes = Uint8List(1024);
  final dll = ByteData.sublistView(bytes);
  void u16(int at, int value) => dll.setUint16(at, value, Endian.little);
  void u32(int at, int value) => dll.setUint32(at, value, Endian.little);
  u16(0, 0x5a4d);
  u32(60, pe);
  u32(pe, 0x4550);
  u16(pe + 4, 0x8664);
  u16(pe + 6, 1);
  u16(pe + 20, 120);
  u16(pe + 22, 0x2000);
  u16(optional, 0x20b);
  u32(optional + 108, 1);
  u32(optional + 112, rva);
  u32(optional + 116, 128);
  u32(section + 12, rva);
  u32(section + 16, 512);
  u32(section + 20, raw);
  u32(section + 36, 0x20000000);
  u32(raw + 20, 1);
  u32(raw + 24, 1);
  u32(raw + 28, rva + 40);
  u32(raw + 32, rva + 44);
  u32(raw + 36, rva + 48);
  u32(raw + 40, rva + 128);
  u32(raw + 44, rva + 52);
  if (dev9) bytes.setAll(raw + 52, 'retro_anyps5_dev9_bind_v1'.codeUnits);
  return bytes;
}

/// [platform]'s core for [host] in [folder], a library the launcher accepts as installed (it is
/// never loaded): the library shows that console's games only once its emulator is there.
File installFixtureCore(String folder, EmbeddedCoreHost host, RetroPlatform platform) =>
    File(p.join(folder, host.libraryName(platform)))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(host == EmbeddedCoreHost.windowsX64 ? ps2LanFixtureDll(dev9: false) : ps2LanFixtureSo());

/// Minimal Linux x64 ELF export table for the PS2 LAN installer. It is never loaded.
Uint8List ps2LanFixtureSo() {
  final bytes = Uint8List(0x400);
  bytes.setRange(0, 7, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  Binary.put16(bytes, 16, 3); // ET_DYN
  Binary.put16(bytes, 18, 62); // EM_X86_64
  Binary.put32(bytes, 20, 1);
  Binary.put64(bytes, 32, 0x280);
  Binary.put16(bytes, 54, 56);
  Binary.put16(bytes, 56, 2);
  Binary.put64(bytes, 40, 0x100);
  Binary.put16(bytes, 52, 64);
  Binary.put16(bytes, 58, 64);
  Binary.put16(bytes, 60, 4);
  // Dynamic symbol table linked to the string table.
  Binary.put32(bytes, 0x144, 11);
  Binary.put64(bytes, 0x150, 0x200);
  Binary.put64(bytes, 0x158, 0x200);
  Binary.put64(bytes, 0x160, 48);
  Binary.put32(bytes, 0x168, 2);
  Binary.put64(bytes, 0x178, 24);
  Binary.put32(bytes, 0x184, 3);
  Binary.put64(bytes, 0x190, 0x240);
  Binary.put64(bytes, 0x198, 0x240);
  Binary.put64(bytes, 0x1a0, 64);
  // Executable allocated section and one exported function.
  Binary.put32(bytes, 0x1c4, 1);
  Binary.put64(bytes, 0x1c8, 6);
  Binary.put64(bytes, 0x1d0, 0x300);
  Binary.put64(bytes, 0x1d8, 0x300);
  Binary.put64(bytes, 0x1e0, 16);
  Binary.put32(bytes, 0x218, 1);
  bytes[0x21c] = 0x12; // STB_GLOBAL, STT_FUNC
  Binary.put16(bytes, 0x21e, 3);
  Binary.put64(bytes, 0x220, 0x300);
  Binary.put64(bytes, 0x228, 1);
  bytes.setRange(0x241, 0x241 + 'retro_anyps5_dev9_bind_v1'.length, 'retro_anyps5_dev9_bind_v1'.codeUnits);
  // Loader mappings and runtime dynamic table, independently of section flags.
  Binary.put32(bytes, 0x280, 1); // PT_LOAD
  Binary.put32(bytes, 0x284, 5); // PF_R | PF_X
  Binary.put64(bytes, 0x2a0, bytes.length);
  Binary.put64(bytes, 0x2a8, bytes.length);
  Binary.put32(bytes, 0x2b8, 2); // PT_DYNAMIC
  Binary.put64(bytes, 0x2c0, 0x80);
  Binary.put64(bytes, 0x2c8, 0x80);
  Binary.put64(bytes, 0x2d8, 0x50);
  Binary.put64(bytes, 0x2e0, 0x50);
  for (final (at, tag, value) in [(0x80, 6, 0x200), (0x90, 11, 24), (0xa0, 5, 0x240), (0xb0, 10, 64)]) {
    Binary.put64(bytes, at, tag);
    Binary.put64(bytes, at + 8, value);
  }
  return bytes;
}

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
