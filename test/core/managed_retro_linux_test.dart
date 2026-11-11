import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List linuxCore({int machine = 62, int type = 3}) {
  final bytes = Uint8List(128);
  bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  final fields = ByteData.sublistView(bytes);
  fields.setUint16(16, type, Endian.little);
  fields.setUint16(18, machine, Endian.little);
  fields.setUint32(20, 1, Endian.little);
  fields.setUint64(32, 64, Endian.little);
  fields.setUint16(52, 64, Endian.little);
  fields.setUint16(54, 56, Endian.little);
  fields.setUint16(56, 1, Endian.little);
  fields.setUint32(64, 1, Endian.little);
  fields.setUint32(68, 5, Endian.little);
  fields.setUint64(96, bytes.length, Endian.little);
  fields.setUint64(104, bytes.length, Endian.little);
  return bytes;
}

void main() {
  test('Linux managed setup selects shared-object names for every console', () {
    expect(ManagedRetro.libraryName(RetroPlatform.ps1), 'swanstation_libretro.so');
    expect(ManagedRetro.libraryName(RetroPlatform.ps2), 'pcsx2_libretro.so');
    expect(ManagedRetro.libraryName(RetroPlatform.ps3), 'rpcs3_libretro.so');
  }, skip: !Platform.isLinux);

  test('Linux managed setup validates ELF architecture and rejects renamed Windows cores', () {
    final root = Directory.systemTemp.createTempSync('anyps5-linux-core-');
    addTearDown(() => root.deleteSync(recursive: true));
    final manager = ManagedRetro(root.path);
    final file = File(p.join(root.path, 'swanstation_libretro.so'));
    file.writeAsBytesSync(linuxCore());
    expect(manager.isInstalled(RetroPlatform.ps1), isTrue);
    file.writeAsBytesSync(linuxCore(machine: 183));
    expect(manager.isInstalled(RetroPlatform.ps1), isFalse);
    file.writeAsBytesSync(linuxCore(type: 2));
    expect(manager.isInstalled(RetroPlatform.ps1), isFalse);
    file.writeAsBytesSync(linuxCore().sublist(0, 63));
    expect(manager.isInstalled(RetroPlatform.ps1), isFalse);
    file.writeAsBytesSync(Uint8List(128)..setAll(0, [0x4d, 0x5a]));
    expect(manager.isInstalled(RetroPlatform.ps1), isFalse);
  }, skip: !Platform.isLinux);

  test('Linux RPCS3 setup verifies its shared-object package without accepting a Windows package', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-linux-package-');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = Directory(p.join(root.path, 'packages'))..createSync();
    final bytes = linuxCore();
    final library = File(p.join(root.path, 'fixture.so'))..writeAsBytesSync(bytes);
    final archive = File(
      p.join(packages.path, 'rpcs3_libretro.so.zip'),
    )..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('rpcs3_libretro.so', bytes.length, bytes))));
    final pins = '${await AssetDownload.sha256Of(archive.path)}:${await AssetDownload.sha256Of(library.path)}';
    final manager = ManagedRetro(p.join(root.path, 'installed'), packageDirectory: packages.path, ps3CoreDigests: pins);
    await manager.install(RetroPlatform.ps3);
    expect(manager.isInstalled(RetroPlatform.ps3), isTrue);
    final installed = File(manager.libraryPath(RetroPlatform.ps3));
    expect(await installed.readAsBytes(), bytes);
    await archive.writeAsBytes([1]);
    await installed.writeAsBytes([1]);
    await expectLater(manager.install(RetroPlatform.ps3), throwsFormatException);
    expect(await installed.readAsBytes(), [1]);
    expect(File(p.join(manager.root, 'rpcs3_libretro.dll')).existsSync(), isFalse);
  }, skip: !Platform.isLinux);
}
