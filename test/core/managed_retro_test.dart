import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a configured PS3 package must exist and match the supported build', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final packages = Directory(p.join(temp.path, 'packages'))..createSync();
    final managed = ManagedRetro(p.join(temp.path, 'emulators'), packageDirectory: packages.path);

    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
    await expectLater(
      ManagedRetro(managed.root).install(RetroPlatform.ps3),
      throwsA(
        isA<FormatException>().having((error) => error.message, 'message', contains('verified emulator packages')),
      ),
    );
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    File(p.join(packages.path, 'rpcs3_libretro.dll.zip')).writeAsBytesSync([0, 1, 2]);
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
  });

  test('PS1 and PS2 reject an unverified package without contacting a server', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = Directory(p.join(root.path, 'packages'))..createSync();
    final managed = ManagedRetro(p.join(root.path, 'emulators'), packageDirectory: packages.path);
    for (final platform in [RetroPlatform.ps1, RetroPlatform.ps2]) {
      final name = ManagedRetro.libraryName(platform);
      final archive = File(p.join(packages.path, '$name.zip'))..writeAsBytesSync([0, 1, 2]);
      await expectLater(managed.install(platform), throwsFormatException);
      expect(managed.isInstalled(platform), isFalse);
      expect(await archive.exists(), isTrue);
    }
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

  test('user-supplied PS3 firmware is staged and rejected replacements preserve it', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-firmware-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final managed = ManagedRetro(p.join(temp.path, 'emulators'));
    final source = File(p.join(temp.path, 'downloaded.pup'));
    final header = ByteData(113)
      ..setUint64(0, 0x5343455546000000)
      ..setUint64(24, 1)
      ..setUint64(32, 112)
      ..setUint64(40, 1);
    final bytes = header.buffer.asUint8List();
    expect(managed.hasPs3FirmwarePackage, isFalse);
    await source.writeAsBytes(bytes);
    await managed.importPs3Firmware(source.path);
    expect(managed.hasPs3FirmwarePackage, isTrue);
    expect(managed.hasPs3Firmware, isFalse);

    final imported = File(p.join(managed.systemPath, 'PS3UPDAT.PUP'));
    expect(await imported.readAsBytes(), bytes);
    for (final invalid in [
      [0],
      bytes.sublist(0, 112),
    ]) {
      await source.writeAsBytes(invalid);
      await expectLater(managed.importPs3Firmware(source.path), throwsFormatException);
      expect(await imported.readAsBytes(), bytes);
    }
    expect(await Directory(managed.systemPath).list().length, 1);
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
