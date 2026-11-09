import 'dart:io';

import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('uses the disc serial for a renamed game and separates handoff rooms', () {
    final profile = Ps1NetplayProfile.qualified.single;
    expect(profile.hintsAt(serial: 'PS1-SCUS-94426', name: 'Custom display name'), isTrue);
    expect(profile.handoffRoom.titleId, profile.room.titleId);
    expect(profile.handoffRoom.gameVersion, isNot(profile.room.gameVersion));
  });

  late Directory folder;
  late File cue;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('anyps5-cue-test-');
    cue = File(p.join(folder.path, 'game.cue'));
  });

  tearDown(() => folder.delete(recursive: true));

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
}
