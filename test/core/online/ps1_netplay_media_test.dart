import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class _FileAccess extends IOOverrides {
  final paths = <String>[];

  @override
  File createFile(String path) {
    paths.add(path);
    return super.createFile(path);
  }
}

void main() {
  late Directory folder;
  late File cue;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('anyps5-cue-test-');
    cue = File(p.join(folder.path, 'game.cue'));
  });

  tearDown(() => folder.delete(recursive: true));

  test('ordinary handoff pins the Recompiler profile and its own core', () {
    const standard = Ps1NetplayExecution.standard;
    const ordinary = Ps1NetplayExecution.ordinaryHandoff;
    const priorProfile =
        'Software;1x;CachedInterpreter;block-linking=0;gpu-thread=0;fast-boot=0;two-digital-pads;delay=2';
    expect(standard.digest, sha256.convert(priorProfile.codeUnits).toString());
    expect(ordinary.digest, isNot(standard.digest));
    expect(ordinary.cpu, 'Recompiler');
    expect(ordinary.coreDigests, {Ps1NetplayMedia.ordinaryHandoffCorePin});
    expect(standard.coreDigests, {Ps1NetplayMedia.corePin, Ps1NetplayMedia.portableCorePin});
  });

  final ordinaryFixture = Platform.environment['ANYPS5_TEST_PS1_ORDINARY_FIXTURE'];
  final standardFixture = Platform.environment['ANYPS5_TEST_PS1_STANDARD_FIXTURE'];
  test('changing the match core reuses only the verified disc and firmware', () async {
    final [String packages, String disc, String bios] = jsonDecode(await File(ordinaryFixture!).readAsString()) as List;
    final [_, String stock] = jsonDecode(await File(standardFixture!).readAsString()) as List;
    final core = await ManagedRetro(
      folder.path,
      host: EmbeddedCoreHost.windowsX64,
      packageDirectory: packages,
    ).ensurePs1NetplayCore(execution: Ps1NetplayExecution.ordinaryHandoff);
    final source = await Ps1NetplayMedia.verify(
      profile: Ps1NetplayProfile.tryRead('SCUS94426')!,
      disc: disc,
      bios: bios,
      core: core,
      execution: Ps1NetplayExecution.ordinaryHandoff,
    );
    final files = _FileAccess();
    final match = await IOOverrides.runWithIOOverrides(
      () => source.withVerifiedCore(stock, Ps1NetplayExecution.standard),
      files,
    );
    expect(files.paths.toSet(), {stock});
    expect(match.disc, source.disc);
    expect(match.bios, source.bios);
    expect(match.identity.toJson(), {
      ...source.identity.toJson(),
      'core': Ps1NetplayMedia.corePin,
      'profile': Ps1NetplayExecution.standard.digest,
    });
    await expectLater(
      source.withVerifiedCore(core, Ps1NetplayExecution.standard),
      throwsA(isA<Ps1NetplayMediaFailure>().having((error) => error.problem, 'problem', Ps1NetplayMediaProblem.core)),
    );
    await expectLater(
      source.withVerifiedCore(stock, Ps1NetplayExecution.standard, canContinue: () => false),
      throwsStateError,
    );
  }, skip: !Platform.isWindows || ordinaryFixture == null || standardFixture == null);

  test('identifies any data disc from its boot serial without a manifest or a known title', () async {
    for (final (mode, stride, dataOffset, serial) in [
      ('MODE2/2352', 2352, 24, 'SLUS00402'),
      ('MODE1/2048', 2048, 0, 'SLES12345'),
    ]) {
      final track = File(p.join(folder.path, 'renamed.bin'));
      final image = Uint8List(stride * 24);
      int sector(int lba) => (lba + 1) * stride + dataOffset;
      final pvd = sector(16);
      image.setRange(pvd, pvd + 7, [1, ...'CD001'.codeUnits, 1]);
      final fields = ByteData.sublistView(image);
      fields.setUint32(pvd + 158, 20, Endian.little);
      fields.setUint32(pvd + 166, 2048, Endian.little);
      final entry = sector(20);
      const file = 'SYSTEM.CNF;1';
      final boot =
          'BOOT = cdrom:\\DIR\\${serial.substring(0, 4)}_${serial.substring(4, 7)}.${serial.substring(7)};1\r\n';
      image[entry] = 46;
      image[entry + 32] = file.length;
      image.setRange(entry + 33, entry + 33 + file.length, file.codeUnits);
      fields.setUint32(entry + 2, 21, Endian.little);
      fields.setUint32(entry + 10, boot.length, Endian.little);
      image.setRange(sector(21), sector(21) + boot.length, boot.codeUnits);
      await track.writeAsBytes(image);
      await cue.writeAsString('FILE\trenamed.bin BINARY\n TRACK 01 $mode\n INDEX 01 00:00:01\n');
      final game = GameLibrary.scan(folder.path).single;
      expect(game.retroSerial, serial);
      final profile = Ps1NetplayProfile.tryRead(serial)!;
      expect(Ps1NetplayRoomMode.values.map((mode) => profile.roomFor(mode).titleId).toSet(), {serial});
      expect(Ps1NetplayRoomMode.values.map((mode) => profile.roomFor(mode).gameVersion).toSet(), {
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
      });
    }
    expect(Ps1NetplayProfile.tryRead('Not a disc serial'), isNull);
  });

  test('fresh DualShock rooms use a distinct execution fingerprint without changing core pins', () {
    const digital = Ps1NetplayRoomMode.fresh;
    const analog = Ps1NetplayRoomMode.freshAnalog;
    expect(Ps1NetplayRoomMode.tryRead('6'), analog);
    expect(analog.needsCheckpoint, isFalse);
    expect(analog.execution.usesDualShock, isTrue);
    expect(digital.execution.usesDualShock, isFalse);
    expect(analog.execution.coreDigests, digital.execution.coreDigests);
    expect(analog.execution.digest, isNot(digital.execution.digest));
  });

  test('rollback rooms boot from disc with a distinct core and execution identity', () {
    final mode = Ps1NetplayRoomMode.tryRead('4')!;
    expect(mode.needsCheckpoint, isFalse);
    expect(mode.execution.cpu, Ps1NetplayExecution.standard.cpu);
    expect(mode.execution.digest, isNot(Ps1NetplayExecution.standard.digest));
    expect(mode.execution.coreDigests.intersection(Ps1NetplayExecution.standard.coreDigests), isEmpty);
  });

  test('rollback handoff preserves the ordinary CPU with a distinct execution identity', () {
    const mode = Ps1NetplayRoomMode.rollbackHandoff;
    expect(Ps1NetplayRoomMode.tryRead('5'), mode);
    expect(mode.needsCheckpoint, isTrue);
    expect(mode.execution.cpu, Ps1NetplayExecution.ordinaryHandoff.cpu);
    expect(mode.execution.coreDigests, Ps1NetplayExecution.ordinaryHandoff.coreDigests);
    expect(mode.execution.digest, isNot(Ps1NetplayExecution.ordinaryHandoff.digest));
  });

  test('fingerprints track bytes and layout independently of the local track name', () async {
    await File(p.join(folder.path, 'Track One.bin')).writeAsBytes([1, 2, 3]);
    await File(p.join(folder.path, 'copy.bin')).writeAsBytes([1, 2, 3]);
    await cue.writeAsString('FILE "Track One.bin" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n');
    final original = await Ps1NetplayMedia.cueDigest(cue.path);
    await cue.writeAsString('rem copied\nfile copy.bin binary\ntrack 01 mode2/2352\nindex 01 00:00:00\n');
    expect(await Ps1NetplayMedia.cueDigest(cue.path), original);
    await cue.writeAsString('file copy.bin binary\ntrack 01 mode2/2352\nindex 01 00:01:00\n');
    expect(await Ps1NetplayMedia.cueDigest(cue.path), isNot(original));
    await cue.writeAsString('file copy.bin binary\ntrack 01 mode2/2352\nindex 01 00:00:00\n');
    await File(p.join(folder.path, 'copy.bin')).writeAsBytes([1, 2, 4]);
    expect(await Ps1NetplayMedia.cueDigest(cue.path), isNot(original));
  });

  test('rejects absolute track paths and a sheet with no tracks', () async {
    final track = await File(p.join(folder.path, 'track.bin')).writeAsBytes([0]);
    await cue.writeAsString('FILE "${track.path}" BINARY\nTRACK 01 AUDIO\n');
    await expectLater(Ps1NetplayMedia.cueDigest(cue.path), throwsFormatException);
    await cue.writeAsString('FILE track.bin BINARY\n');
    await expectLater(Ps1NetplayMedia.cueDigest(cue.path), throwsFormatException);
  });

  test('a canceled track read cannot return a fingerprint for partial media', () async {
    await File(p.join(folder.path, 'track.bin')).writeAsBytes(Uint8List(2 * 1024 * 1024));
    await cue.writeAsString('FILE track.bin BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n');
    var checks = 0;
    await expectLater(Ps1NetplayMedia.cueDigest(cue.path, canContinue: () => ++checks < 3), throwsStateError);
    expect(await Ps1NetplayMedia.cueDigest(cue.path), matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}
