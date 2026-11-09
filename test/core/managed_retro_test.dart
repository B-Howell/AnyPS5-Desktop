import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('PS2 LAN verifies the DEV9 export and installs separately from the offline core', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(root.path);
    final file = File(p.join(root.path, ManagedRetro.libraryName(RetroPlatform.ps2)));
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
    file.writeAsBytesSync(bytes);
    expect(managed.isInstalled(RetroPlatform.ps2), isTrue);
    expect(managed.supportsPs2Lan, isFalse);
    bytes.setAll(raw + 52, 'retro_anyps5_dev9_bind_v1'.codeUnits);
    file.writeAsBytesSync(bytes);
    expect(managed.supportsPs2Lan, isTrue);
    final package = File(p.join(root.path, 'pcsx2_libretro.dll.zip'))
      ..writeAsBytesSync(
        ZipEncoder().encode(Archive()..addFile(ArchiveFile('pcsx2_libretro.dll', bytes.length, bytes))),
      );
    final archiveDigest = await AssetDownload.sha256Of(package.path);
    final libraryDigest = await AssetDownload.sha256Of(file.path);
    u32(section + 36, 0);
    file.writeAsBytesSync(bytes);
    expect(managed.supportsPs2Lan, isFalse, reason: 'A data export is not a DEV9 implementation.');
    u32(section + 36, 0x20000000);
    u32(raw + 40, rva + 52);
    file.writeAsBytesSync(bytes);
    expect(managed.supportsPs2Lan, isFalse, reason: 'A forwarded export is not a DEV9 implementation.');
    final offline = file.readAsBytesSync();
    final preview = ManagedRetro(root.path, ps2LanCoreDigests: '$archiveDigest:$libraryDigest');
    expect(preview.installedPs2LanHome, isNull);
    await expectLater(managed.installPs2Lan(package.path), throwsFormatException);
    expect(preview.installedPs2LanHome, isNull);
    await preview.installPs2Lan(package.path);
    final installed = File(p.join(preview.installedPs2LanHome!, 'pcsx2_libretro.dll'));
    expect(await AssetDownload.sha256Of(installed.path), libraryDigest);
    expect(await file.readAsBytes(), offline);
    await preview.installPs2Lan(package.path);
    expect(await AssetDownload.sha256Of(installed.path), libraryDigest);

    final invalid = File(p.join(root.path, 'invalid.zip'))..writeAsBytesSync([1, 2, 3]);
    await expectLater(preview.installPs2Lan(invalid.path), throwsFormatException);
    expect(await AssetDownload.sha256Of(installed.path), libraryDigest);
    final wrongCore = File(p.join(root.path, 'wrong-core.zip'))
      ..writeAsBytesSync(
        ZipEncoder().encode(Archive()..addFile(ArchiveFile('pcsx2_libretro.dll', offline.length, offline))),
      );
    final wrongArchiveDigest = await AssetDownload.sha256Of(wrongCore.path);
    final wrongLibraryDigest = await AssetDownload.sha256Of(file.path);
    final wrong = ManagedRetro(root.path, ps2LanCoreDigests: '$wrongArchiveDigest:$wrongLibraryDigest');
    await expectLater(wrong.installPs2Lan(wrongCore.path), throwsFormatException);
    expect(await AssetDownload.sha256Of(installed.path), libraryDigest);
    await installed.writeAsBytes([0], mode: FileMode.append);
    expect(ManagedRetro(p.dirname(installed.path)).supportsPs2Lan, isTrue);
    expect(
      preview.installedPs2LanHome,
      isNull,
      reason: 'A DEV9 export does not establish the managed package identity.',
    );
    await preview.installPs2Lan(package.path);
    expect(preview.installedPs2LanHome, isNotNull);
  });

  test('a configured PS3 package must exist and match the supported build', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final packages = Directory(p.join(temp.path, 'packages'))..createSync();
    final managed = ManagedRetro(p.join(temp.path, 'emulators'), packageDirectory: packages.path);

    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
    await expectLater(
      ManagedRetro(managed.root).install(RetroPlatform.ps3),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('verified RPCS3 package'))),
    );
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    File(p.join(packages.path, 'rpcs3_libretro.dll.zip')).writeAsBytesSync([0, 1, 2]);
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
  });

  test('an existing PS3 DLL still needs a matching digest', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(root.path);
    final dll = ByteData(88)
      ..setUint16(0, 0x5a4d, Endian.little)
      ..setUint32(60, 64, Endian.little)
      ..setUint32(64, 0x4550, Endian.little)
      ..setUint16(68, 0x8664, Endian.little)
      ..setUint16(86, 0x2000, Endian.little);
    File(p.join(root.path, ManagedRetro.libraryName(RetroPlatform.ps3))).writeAsBytesSync(dll.buffer.asUint8List());

    expect(managed.isInstalled(RetroPlatform.ps3), isTrue);
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
  });

  test('a clean profile can install a locally built PS3 package using explicit digests', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final name = ManagedRetro.libraryName(RetroPlatform.ps3);
    final dll = ByteData(88)
      ..setUint16(0, 0x5a4d, Endian.little)
      ..setUint32(60, 64, Endian.little)
      ..setUint32(64, 0x4550, Endian.little)
      ..setUint16(68, 0x8664, Endian.little)
      ..setUint16(86, 0x2000, Endian.little);
    final bytes = dll.buffer.asUint8List();
    final packages = Directory(p.join(root.path, 'packages'))..createSync();
    final original = File(p.join(root.path, name))..writeAsBytesSync(bytes);
    final archive = Archive()..addFile(ArchiveFile(name, bytes.length, bytes));
    final zip = File(p.join(packages.path, '$name.zip'))..writeAsBytesSync(ZipEncoder().encode(archive));
    final archiveDigest = await AssetDownload.sha256Of(zip.path);
    final libraryDigest = await AssetDownload.sha256Of(original.path);
    final emulatorRoot = p.join(root.path, 'emulators');
    ManagedRetro configured(String digests) =>
        ManagedRetro(emulatorRoot, packageDirectory: packages.path, ps3CoreDigests: digests);

    await expectLater(configured('malformed').install(RetroPlatform.ps3), throwsFormatException);
    await expectLater(configured('$libraryDigest:$libraryDigest').install(RetroPlatform.ps3), throwsFormatException);
    await expectLater(configured('$archiveDigest:$archiveDigest').install(RetroPlatform.ps3), throwsFormatException);
    final managed = configured('$archiveDigest:$libraryDigest'.toUpperCase());
    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
    await managed.install(RetroPlatform.ps3);
    expect(await File(p.join(emulatorRoot, name)).readAsBytes(), bytes);
    await zip.delete();
    await managed.install(RetroPlatform.ps3);
  });

  test('a rejected BIOS replacement preserves the private copy', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final managed = ManagedRetro(p.join(temp.path, 'emulators'));
    final source = File(p.join(temp.path, 'source.rom'));
    final bytes = Uint8List(512 * 1024)..[0] = 1;
    await source.writeAsBytes(bytes);

    expect(managed.hasBios(RetroPlatform.ps1), isFalse);
    await managed.importBios(RetroPlatform.ps1, source.path);
    final imported = File(p.join(managed.systemPath, 'anyps5-imported.bin'));
    expect(managed.hasBios(RetroPlatform.ps1), isTrue);
    expect(managed.hasBios(RetroPlatform.ps2), isFalse);

    bytes[0] = 2;
    await source.writeAsBytes(bytes);
    await managed.importBios(RetroPlatform.ps1, source.path);
    await source.writeAsBytes([0]);
    await expectLater(managed.importBios(RetroPlatform.ps1, source.path), throwsFormatException);
    await source.delete();
    expect(await imported.readAsBytes(), bytes);
  });
}
