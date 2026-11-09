import 'dart:io';

import 'package:anyps5_desktop/core/online/ps2_lan_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File bios;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ps2-lan-profile-test-');
    bios = await File(p.join(root.path, 'bios.bin')).writeAsBytes([1, 2, 3]);
  });
  tearDown(() => root.delete(recursive: true));

  Future<Ps2LanProfile> open(String owner) =>
      Ps2LanProfile.open(root: p.join(root.path, 'profiles'), owner: owner, bios: bios.path);

  test('one owner holds the memory card at a time and other profiles stay separate', () async {
    final first = await open('alice');
    try {
      await expectLater(open('alice'), throwsA(isA<Ps2LanProfileInUse>()));
      final second = await open('bob');
      try {
        expect(second.system, isNot(first.system));
        expect(second.saves, isNot(first.saves));
      } finally {
        await second.close();
      }
    } finally {
      await first.close();
    }
    final reopened = await open('alice');
    try {
      expect(reopened.system, first.system);
    } finally {
      await reopened.close();
    }
  }, skip: !Platform.isWindows);

  test('a failed BIOS refresh releases the lease and preserves the card', () async {
    final first = await open('alice');
    final card = File(p.join(first.system, 'pcsx2', 'memcards', 'Mcd001.ps2'));
    try {
      await card.create(recursive: true);
      await card.writeAsBytes([4, 5, 6]);
    } finally {
      await first.close();
    }

    await bios.delete();
    await expectLater(open('alice'), throwsA(isA<FileSystemException>()));
    await bios.writeAsBytes([7, 8, 9]);
    final reopened = await open('alice');
    try {
      expect(await card.readAsBytes(), [4, 5, 6]);
      expect(await File(p.join(reopened.system, 'pcsx2', 'bios', 'anyps5-imported.bin')).readAsBytes(), [7, 8, 9]);
    } finally {
      await reopened.close();
    }
  });
}
