import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
      expect(Ps1NetplayRoomMode.values.map((mode) => profile.roomFor(mode).gameVersion).toSet(), {'1', '2', '3'});
    }
    expect(Ps1NetplayProfile.tryRead('Not a disc serial'), isNull);
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
