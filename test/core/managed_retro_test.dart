import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart' show ps2LanFixtureDll;

void main() {
  test('PS1 online BIOS validation leaves offline and previously imported files intact', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final online = File(p.join(root.path, 'PS1-Netplay', 'scph1001.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final offline = File(p.join(root.path, 'system', 'anyps5-imported.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([2]);
    final invalid = File(p.join(root.path, 'wrong.bin'))..writeAsBytesSync(Uint8List(512 * 1024)..[0] = 3);
    final managed = ManagedRetro(root.path);

    expect(await managed.verifiedPs1NetplayBios(offline.path), isNull);
    await expectLater(managed.importPs1NetplayBios(invalid.path), throwsFormatException);
    expect(online.readAsBytesSync(), [1]);
    expect(offline.readAsBytesSync(), [2]);
  });

  test('PS1 checkpoint setup rejects a mismatched package and preserves the offline core', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final offline = File(p.join(root.path, 'swanstation_libretro.dll'))..writeAsBytesSync([4, 3, 2, 1]);
    final packages = Directory(p.join(root.path, 'packages'))..createSync();
    File(p.join(packages.path, 'swanstation-netplay.zip')).writeAsBytesSync([1, 2, 3, 4]);
    File(p.join(packages.path, 'swanstation-netplay-ordinary.zip')).writeAsBytesSync([4, 3, 2, 1]);
    final managed = ManagedRetro(root.path, packageDirectory: packages.path);

    await expectLater(managed.ensurePs1NetplayCore(), throwsFormatException);
    await expectLater(
      managed.ensurePs1NetplayCore(execution: Ps1NetplayExecution.ordinaryHandoff),
      throwsFormatException,
    );
    expect(offline.readAsBytesSync(), [4, 3, 2, 1]);
    expect(File(p.join(root.path, 'PS1-Netplay', 'swanstation_libretro.dll')).existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'PS1-Netplay-Ordinary')).existsSync(), isFalse);
  });

  final rollbackPackages = Platform.environment['ANYPS5_TEST_PS1_ROLLBACK_PACKAGES'];
  test('installs and repairs both verified rollback cores without touching the offline core', () async {
    final root = await Directory.systemTemp.createTemp('anyps5-rollback-core-');
    addTearDown(() => root.delete(recursive: true));
    final name = ManagedRetro.libraryName(RetroPlatform.ps1);
    final offline = File(p.join(root.path, name))..writeAsBytesSync([1]);
    final managed = ManagedRetro(root.path, packageDirectory: rollbackPackages);
    const execution = Ps1NetplayExecution.rollbackPreview;
    final primary = await managed.ensurePs1NetplayCore(execution: execution);
    expect(p.basename(p.dirname(primary)), 'PS1-Netplay-Rollback');
    final spare = Ps1NetplayMedia.presentationCorePath(primary);
    expect(spare, isNot(primary));
    for (final path in [primary, spare]) {
      expect(await AssetDownload.sha256Of(path), Ps1NetplayMedia.rollbackCorePin);
    }
    final installedOnly = ManagedRetro(root.path);
    expect(await installedOnly.ensurePs1NetplayCore(execution: execution), primary);
    await File(spare).writeAsBytes([2]);
    await expectLater(installedOnly.ensurePs1NetplayCore(execution: execution), throwsFormatException);
    expect(await managed.ensurePs1NetplayCore(execution: execution), primary);
    expect(await AssetDownload.sha256Of(spare), Ps1NetplayMedia.rollbackCorePin);
    expect(offline.readAsBytesSync(), [1]);
  }, skip: rollbackPackages == null ? 'Requires the local qualified rollback package.' : false);

  final ordinaryFixture = Platform.environment['ANYPS5_TEST_PS1_ORDINARY_FIXTURE'];
  test('installs the ordinary handoff package separately and verifies its match identity', () async {
    final [String packages, String disc, String bios] = jsonDecode(await File(ordinaryFixture!).readAsString()) as List;
    final root = await Directory.systemTemp.createTemp('anyps5-ordinary-core-');
    addTearDown(() => root.delete(recursive: true));
    final name = ManagedRetro.libraryName(RetroPlatform.ps1);
    final offline = File(p.join(root.path, name))..writeAsBytesSync([1]);
    final staged = File(p.join(root.path, 'PS1-Netplay', name))
      ..createSync(recursive: true)
      ..writeAsBytesSync([2]);
    const execution = Ps1NetplayExecution.ordinaryHandoff;
    final managed = ManagedRetro(root.path, packageDirectory: packages);
    final installed = await managed.ensurePs1NetplayCore(execution: execution);
    expect(p.basename(p.dirname(installed)), 'PS1-Netplay-Ordinary');
    expect(await ManagedRetro(root.path).ensurePs1NetplayCore(execution: execution), installed);
    final profile = Ps1NetplayProfile.tryRead('SCUS94426')!;
    final media = await Ps1NetplayMedia.verify(
      profile: profile,
      disc: disc,
      bios: bios,
      core: installed,
      execution: execution,
    );
    expect(media.execution, execution);
    expect(media.identity.toJson()['profile'], execution.digest);
    expect(media.identity.toJson()['core'], Ps1NetplayMedia.ordinaryHandoffCorePin);
    await expectLater(
      Ps1NetplayMedia.verify(profile: profile, disc: disc, bios: bios, core: installed),
      throwsA(
        isA<Ps1NetplayMediaFailure>().having((failure) => failure.problem, 'problem', Ps1NetplayMediaProblem.core),
      ),
    );
    expect(offline.readAsBytesSync(), [1]);
    expect(staged.readAsBytesSync(), [2]);
  }, skip: ordinaryFixture == null ? 'Requires the local qualified package, disc and BIOS.' : false);

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
    final bytes = ps2LanFixtureDll(dev9: false);
    final dll = ByteData.sublistView(bytes);
    void u32(int at, int value) => dll.setUint32(at, value, Endian.little);
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

  test('a verified PS3 core update replaces only the core and is repeat safe', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final name = ManagedRetro.libraryName(RetroPlatform.ps3);
    Uint8List dllBytes(int marker) {
      final dll = ByteData(88)
        ..setUint16(0, 0x5a4d, Endian.little)
        ..setUint32(60, 64, Endian.little)
        ..setUint32(64, 0x4550, Endian.little)
        ..setUint16(68, 0x8664, Endian.little)
        ..setUint16(86, 0x2000, Endian.little);
      final bytes = Uint8List(89)..setRange(0, 88, dll.buffer.asUint8List());
      bytes[88] = marker;
      return bytes;
    }

    final legacy = dllBytes(1);
    final updated = dllBytes(2);
    final core = File(p.join(root.path, name))..writeAsBytesSync(legacy);
    final system = Directory(p.join(root.path, 'system', 'rpcs3'))..createSync(recursive: true);
    final firmware = File(p.join(system.path, 'firmware.sentinel'))..writeAsStringSync('firmware');
    final cache = File(p.join(system.path, 'cache.sentinel'))..writeAsStringSync('cache');
    final saves = Directory(p.join(root.path, 'Saves'))..createSync();
    final save = File(p.join(saves.path, 'save.sentinel'))..writeAsStringSync('save');

    final packages = Directory(p.join(root.path, 'packages'))..createSync();
    final archive = Archive()..addFile(ArchiveFile(name, updated.length, updated));
    final package = File(p.join(packages.path, '$name.zip'))..writeAsBytesSync(ZipEncoder().encode(archive));
    final updatedCandidate = File(p.join(root.path, 'updated.dll'))..writeAsBytesSync(updated);
    final archiveDigest = await AssetDownload.sha256Of(package.path);
    // A mismatched DLL pin must fail before replacing the installed core.
    final rejected = ManagedRetro(
      root.path,
      packageDirectory: packages.path,
      ps3CoreDigests: '$archiveDigest:${'0' * 64}',
    );
    await expectLater(rejected.install(RetroPlatform.ps3), throwsFormatException);
    expect(await core.readAsBytes(), legacy);

    final updatedDigests =
        '${await AssetDownload.sha256Of(package.path)}:${await AssetDownload.sha256Of(updatedCandidate.path)}';
    final managed = ManagedRetro(root.path, packageDirectory: packages.path, ps3CoreDigests: updatedDigests);
    await managed.install(RetroPlatform.ps3);
    expect(await core.readAsBytes(), updated);
    expect(await firmware.readAsString(), 'firmware');
    expect(await cache.readAsString(), 'cache');
    expect(await save.readAsString(), 'save');

    await package.delete();
    await managed.install(RetroPlatform.ps3);
    expect(await core.readAsBytes(), updated);
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
