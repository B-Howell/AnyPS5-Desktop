import 'dart:io';

import 'package:anyps5_desktop/core/ps3_update_import.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';

void main() {
  late Directory root;
  late Directory source;
  late String imports;
  final packages = [
    [1, 2],
    [3, 4, 5],
  ];
  final executable = [9, 8, 7];
  final chain = Ps3UpdateChain(
    titleId: 'BCUS98208',
    discVersion: '01.18',
    version: '01.30',
    executableDigest: sha256.convert(executable).toString(),
    packages: [
      for (final (index, bytes) in packages.indexed)
        (version: index == 0 ? '01.28' : '01.30', size: bytes.length, digest: sha256.convert(bytes).toString()),
    ],
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('ps3-import-');
    source = Directory(p.join(root.path, 'input'))..createSync();
    imports = p.join(root.path, 'prepared');
    // Names and directory iteration order must not determine the install order.
    File(p.join(source.path, 'z.pkg')).writeAsBytesSync(packages[0]);
    File(p.join(source.path, 'a.PKG')).writeAsBytesSync(packages[1]);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> extract(String stage, int count) async {
    expect(count, packages.length);
    for (final (index, bytes) in packages.indexed) {
      expect(await File(p.join(stage, 'packages', '$index.pkg')).readAsBytes(), bytes);
    }
    final title = p.join(stage, 'system', 'rpcs3', 'dev_hdd0', 'game', chain.titleId);
    Directory(p.join(title, 'USRDIR')).createSync(recursive: true);
    File(p.join(title, 'PARAM.SFO'))
        .writeAsBytesSync(ps3FixtureSfo({'TITLE_ID': chain.titleId, 'APP_VER': chain.version, 'CATEGORY': 'GD'}));
    File(p.join(title, 'USRDIR', 'EBOOT.BIN')).writeAsBytesSync(executable);
  }

  test('preflights the complete chain and publishes only verified title data', () async {
    final verified = await chain.inspect(source.path);
    expect(Directory(imports).existsSync(), isFalse);
    final update = await verified.install(imports, extract);
    expect(update, await Directory(p.join(imports, chain.titleId, chain.version)).resolveSymbolicLinks());
    expect(await chain.isPrepared(imports), isTrue);
    expect(Directory(imports).listSync().map((entry) => p.basename(entry.path)), [chain.titleId]);
    expect(await verified.install(imports, (_, _) async => fail('Reinstalled a prepared update')), update);
  });

  test('reports the missing revision before invoking the core', () async {
    File(p.join(source.path, 'z.pkg')).deleteSync();
    await expectLater(
      chain.inspect(source.path),
      throwsA(isA<Ps3UpdateMissing>().having((issue) => issue.versions, 'versions', ['01.28'])),
    );
    expect(Directory(imports).existsSync(), isFalse);
  });

  test('rechecks copied packages and leaves existing updates alone on failure', () async {
    final verified = await chain.inspect(source.path);
    final old = File(p.join(imports, chain.titleId, '01.28', 'old'));
    old.createSync(recursive: true);
    File(p.join(source.path, 'z.pkg')).writeAsBytesSync([7, 8]);
    await expectLater(verified.install(imports, (_, _) async => fail('Ran unverified input')), throwsFormatException);
    expect(old.existsSync(), isTrue);
    expect(await chain.isPrepared(imports), isFalse);
    expect(Directory(imports).listSync().map((entry) => p.basename(entry.path)), [chain.titleId]);
  });

  test('cancellation and an unexpected installed executable never publish', () async {
    final verified = await chain.inspect(source.path);
    await expectLater(verified.install(imports, (_, _) async => throw StateError('Cancelled')), throwsStateError);
    await expectLater(
      verified.install(imports, (stage, count) async {
        await extract(stage, count);
        File(p.join(stage, 'system', 'rpcs3', 'dev_hdd0', 'game', chain.titleId, 'USRDIR', 'EBOOT.BIN'))
            .writeAsBytesSync([0]);
      }),
      throwsFormatException,
    );
    expect(await chain.isPrepared(imports), isFalse);
    expect(Directory(imports).listSync(), isEmpty);
  });

  test('keeps staging when native teardown cannot be confirmed', () async {
    final verified = await chain.inspect(source.path);
    await expectLater(
      verified.install(imports, (_, _) async => throw const Ps3UpdateWorkerUnconfirmed()),
      throwsA(isA<Ps3UpdateWorkerUnconfirmed>()),
    );
    expect(await chain.isPrepared(imports), isFalse);
    expect(p.basename(Directory(imports).listSync().single.path), startsWith('staging-'));
  });

  test('rejects a prepared-update root that redirects into another directory', () async {
    final target = Directory(p.join(root.path, 'offline'))..createSync();
    final link = Link(imports);
    try {
      link.createSync(target.path);
    } on FileSystemException {
      if (Platform.isWindows) {
        markTestSkipped('Creating a symbolic link requires Windows Developer Mode or an elevated test process.');
        return;
      }
      rethrow;
    }
    final verified = await chain.inspect(source.path);
    await expectLater(
      verified.install(imports, (_, _) async => fail('Ran in redirected storage')),
      throwsFormatException,
    );
    expect(await chain.isPrepared(imports), isFalse);
    expect(target.listSync(), isEmpty);
  });
}
