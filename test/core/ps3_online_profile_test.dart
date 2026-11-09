import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/ps3_online_profile.dart';
import 'package:anyps5_desktop/core/ps3_update_import.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart' show ps3FixtureSfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Ps3OnlineRelease release;
  String? updateTreeDigest;
  late String disc, core, online, offline;
  final accountConfig = Platform.isWindows ? 'online/system/rpcs3/config/rpcn.yml' : 'online/system/rpcs3/rpcn.yml';
  const account = 'Version: 2\nHost: rpcn.example.invalid\nNPID: fixture\nPassword: test-only\n';

  File write(String name, List<int> bytes) => File(p.join(root.path, name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  void makeRelease() {
    release = Ps3OnlineRelease(
      provider: 'fixture',
      titleId: 'ABCD12345',
      updateVersion: '01.30',
      updateTreeDigest: updateTreeDigest,
      generatedUpdateFiles: const {'USRDIR/generated.dat'},
      coreSha256: sha256.convert([1]).toString(),
      executableSha256: sha256.convert([2]).toString(),
      protection: Ps3SprxProtection('provider.sprx', sha256.convert([3]).toString()),
      rpcnHost: 'rpcn.example.invalid',
      providerFiles: {
        'plugins/provider.conf': sha256.convert([4]).toString(),
      },
      xfloat: Ps3Xfloat.accurate,
      dns: Ps3Dns.cloudflare,
      upnp: true,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('ps3-online-test-');
    disc = write('disc/PS3_DISC.SFB', [0]).path;
    core = write('rpcs3_libretro.dll', [1]).path;
    online = (Directory(p.join(root.path, 'online'))..createSync()).path;
    offline = (Directory(p.join(root.path, 'offline'))..createSync()).path;
    write('disc/PS3_GAME/USRDIR/EBOOT.BIN', [0]);
    write('disc/PS3_GAME/PARAM.SFO', ps3FixtureSfo({'TITLE_ID': 'ABCD12345', 'APP_VER': '01.00'}));
    write(
      'online/system/rpcs3/dev_hdd0/game/ABCD12345/PARAM.SFO',
      ps3FixtureSfo({'TITLE_ID': 'ABCD12345', 'APP_VER': '01.30'}),
    );
    write('online/system/rpcs3/dev_hdd0/game/ABCD12345/USRDIR/EBOOT.BIN', [2]);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.sprx', [3]);
    write(accountConfig, account.codeUnits);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.conf', [4]);
    write('online/system/rpcs3/dev_flash/vsh/module/vsh.self', [5]);
    write('online/system/rpcs3/dev_flash/sys/external/liblv2.sprx', [5]);
    updateTreeDigest = null;
    makeRelease();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<Ps3OnlineProfile> verify({
    String? provider,
    String? onlineRoot,
    ({Ps3UpdateChain chain, String root})? preparedUpdate,
  }) => Ps3OnlineProfile.verify(
    provider: provider ?? release.provider,
    disc: disc,
    core: core,
    onlineRoot: onlineRoot ?? online,
    offlineSystemRoot: offline,
    releases: [release],
    preparedUpdate: preparedUpdate,
  );

  test('validates a provider-independent release and exposes only typed launch values', () async {
    final profile = await verify();
    expect(profile.networkArguments, {'xfloat': 'accurate', 'dns': '1.1.1.1', 'upnp': true});
    final canonical = Directory(online).resolveSymbolicLinksSync();
    expect(profile.systemRoot, p.join(canonical, 'system'));
    expect(profile.saveRoot, p.join(canonical, 'saves'));
    expect(profile.disc, disc);
    expect(profile.core, core);
  });

  test('an explicit preparation copies the reviewed update only into the verified online profile', () async {
    final update = Directory(p.join(online, 'system', 'rpcs3', 'dev_hdd0', 'game', release.titleId));
    final source = p.join(root.path, 'prepared', release.titleId, release.updateVersion);
    Directory(source).parent.createSync(recursive: true);
    update.renameSync(source);
    final manifest = File(p.join(source, 'PARAM.SFO'))
      ..writeAsBytesSync(ps3FixtureSfo({'TITLE_ID': release.titleId, 'APP_VER': '01.30', 'CATEGORY': 'GD'}));
    final sourceAsset = File(p.join(source, 'USRDIR', 'asset.dat'))..writeAsBytesSync([6, 7, 8]);
    updateTreeDigest = await ps3UpdateTreeDigest(Directory(await Directory(source).resolveSymbolicLinks()));
    makeRelease();
    final prepared = (
      root: p.join(root.path, 'prepared'),
      chain: Ps3UpdateChain(
        titleId: release.titleId,
        discVersion: '01.00',
        version: release.updateVersion,
        executableDigest: release.executableSha256,
        packages: const [],
      ),
    );

    await expectLater(verify(), throwsA(Ps3OnlineIssue.update));
    File(p.join(root.path, accountConfig)).deleteSync();
    await expectLater(verify(preparedUpdate: prepared), throwsA(Ps3OnlineIssue.account));
    expect(update.existsSync(), isFalse);
    write(accountConfig, account.codeUnits);

    sourceAsset.writeAsBytesSync([0]);
    await expectLater(verify(preparedUpdate: prepared), throwsA(Ps3OnlineIssue.update));
    expect(update.existsSync(), isFalse);
    sourceAsset.writeAsBytesSync([6, 7, 8]);

    final profile = await verify(preparedUpdate: prepared);
    File(p.join(update.path, 'USRDIR', 'generated.dat')).writeAsBytesSync([1]);
    await profile.revalidate();
    expect(File(p.join(update.path, 'USRDIR', 'asset.dat')).readAsBytesSync(), [6, 7, 8]);
    expect(sourceAsset.existsSync(), isTrue);
    expect(manifest.existsSync(), isTrue);
    expect(Directory(offline).listSync(), isEmpty);
    final unreviewed = File(p.join(update.path, 'USRDIR', 'unreviewed.dat'))..writeAsBytesSync([1]);
    await expectLater(profile.revalidate(), throwsA(Ps3OnlineIssue.update));
    unreviewed.deleteSync();
    File(p.join(update.path, 'USRDIR', 'asset.dat')).writeAsBytesSync([0]);
    await expectLater(profile.revalidate(), throwsA(Ps3OnlineIssue.update));
    final executable = File(p.join(update.path, 'USRDIR', 'EBOOT.BIN'))..writeAsBytesSync([9]);
    await expectLater(verify(preparedUpdate: prepared), throwsA(Ps3OnlineIssue.update));
    expect(executable.readAsBytesSync(), [9]);
  });

  test('verifies the reviewed per-title YAML and carries its required boot patches', () async {
    const ppu = 'PPU-545c1abbf1c562d60fca7435401f020beab76b53';
    const name = 'Patchwork Combined Patch';
    const yaml =
        '''
Version: 1.2
$ppu:
  $name:
    Games:
      Fixture:
        ABCD12345: [01.30]
    Patch:
      - [be32, 0x10000, 0x60000000]
''';
    final file = write('online/system/rpcs3/patches/ABCD12345_patch.yml', utf8.encode(yaml));
    Ps3OnlineRelease review(String source, {String? baseDigest}) => Ps3OnlineRelease(
      provider: release.provider,
      titleId: release.titleId,
      updateVersion: release.updateVersion,
      coreSha256: release.coreSha256,
      executableSha256: release.executableSha256,
      protection: Ps3YamlProtection(
        sha256: sha256.convert(utf8.encode(source)).toString(),
        ppuHash: ppu,
        patches: const {name: 1},
        basePatchSha256: baseDigest,
      ),
      rpcnHost: release.rpcnHost,
      providerFiles: const {},
      xfloat: release.xfloat,
      dns: release.dns,
      upnp: release.upnp,
    );
    release = review(yaml);
    final profile = await verify();
    expect(profile.networkArguments['patchProtection'], {
      'sha256': sha256.convert(utf8.encode(yaml)).toString(),
      'titleId': 'ABCD12345',
      'updateVersion': '01.30',
      'ppuHash': ppu,
      'patches': [
        {'name': name, 'writes': 1, 'option': 'rpcs3_zpatch_0cf6eeaf'},
      ],
    });
    final wrongVersion = yaml.replaceFirst('01.30', '01.28');
    await file.writeAsString(wrongVersion);
    await expectLater(profile.revalidate(), throwsA(Ps3OnlineIssue.patch));
    for (final invalid in [
      wrongVersion,
      yaml.replaceFirst('Version: 1.2', 'Version: 1.20'),
      yaml.replaceFirst('545c', '645c'),
      '$yaml      - [be32, 0x10004, 0x60000000]\n',
    ]) {
      await file.writeAsString(invalid);
      release = review(invalid);
      await expectLater(verify(), throwsA(Ps3OnlineIssue.patch));
    }
    final quoted = yaml.replaceFirst('Version: 1.2', "Version: '1.2'").replaceFirst('[01.30]', '["01.30"]');
    await file.writeAsString(quoted);
    release = review(quoted);
    final quotedProfile = await verify();
    expect(quotedProfile.networkArguments['patchProtection'], {
      ...(profile.networkArguments['patchProtection'] as Map),
      'sha256': sha256.convert(utf8.encode(quoted)).toString(),
    });
    release = review(yaml);
    await file.writeAsString(yaml);
    final competing = write('online/system/rpcs3/patches/imported_patch.yml', [0]);
    await expectLater(profile.revalidate(), throwsA(Ps3OnlineIssue.patch));
    competing.deleteSync();
    final base = write('online/system/rpcs3/patches/patch.yml', [0]);
    await expectLater(profile.revalidate(), throwsA(Ps3OnlineIssue.patch));
    release = review(yaml, baseDigest: sha256.convert([0]).toString());
    expect((await verify()).networkArguments, profile.networkArguments);
    await base.writeAsBytes([1]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.patch));
  });

  test('a listed release and detected update still require a verified profile', () {
    final report = Ps3OnlineReadiness.inspect(disc: disc, managedSystem: p.join(online, 'system'), releases: [release]);
    expect(report.state, Ps3OnlineReadinessState.profileRequired);
    expect(report.discVersion, '01.00');
    expect(report.managedUpdate, '01.30');
    write(
      'online/system/rpcs3/dev_hdd0/game/ABCD12345/PARAM.SFO',
      ps3FixtureSfo({'TITLE_ID': 'WXYZ12345', 'APP_VER': '01.30'}),
    );
    expect(Ps3OnlineReadiness.inspect(disc: disc, managedSystem: p.join(online, 'system')).managedUpdate, isNull);
  });

  test('a verified online launch sends only policy values and isolated storage', () async {
    final profile = await verify();
    const channel = MethodChannel('anyps5/retro_core');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => 7,
        'status' => {'ended': true},
        _ => null,
      };
    });
    Future<EmbeddedRetroGame> start(String path) => EmbeddedRetroGame.start(
      root.path,
      (platform: RetroPlatform.ps3, path: path),
      onlineProfile: profile,
      internalResolution: null,
      graphics: const {},
      onResolutionSelected: (_) {},
      onGraphicsSelected: (_, _) {},
      readPad: () => PadState.idle,
      changed: () {},
    );
    await expectLater(start(p.join(root.path, 'other', 'PS3_DISC.SFB')), throwsA(Ps3OnlineIssue.unqualified));
    final executable = write('online/system/rpcs3/dev_hdd0/game/ABCD12345/USRDIR/EBOOT.BIN', [9]);
    await expectLater(start(disc), throwsA(Ps3OnlineIssue.update));
    expect(calls, isEmpty);
    await executable.writeAsBytes([2]);
    final game = await start(disc);
    expect(await game.exitCode.timeout(const Duration(seconds: 2)), 0);
    final launch = calls.singleWhere((call) => call.method == 'start').arguments as Map;
    expect(launch['ps3Online'], {'xfloat': 'accurate', 'dns': '1.1.1.1', 'upnp': true});
    expect(launch['system'], profile.systemRoot);
    expect(launch['saves'], profile.saveRoot);
    expect(launch.toString(), isNot(contains('test-only')));
  });

  test('rejects an unqualified provider or shared offline system before boot', () async {
    await expectLater(verify(provider: 'unreviewed'), throwsA(Ps3OnlineIssue.unqualified));
    await expectLater(verify(onlineRoot: offline), throwsA(Ps3OnlineIssue.storage));
    write('online/saves', [0]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.storage));
  });

  test('reopens an isolated profile after RPCS3 writes its default VFS', () async {
    final profile = await verify();
    final vfs = <String, Object>{
      r'$(EmulatorDir)': '${profile.systemRoot}/rpcs3/',
      for (final directory in ['dev_hdd0', 'dev_hdd1', 'dev_flash', 'dev_flash2', 'dev_flash3', 'dev_bdvd', 'games'])
        '/$directory/': '\$(EmulatorDir)$directory/',
      '/app_home/': '',
      '/dev_usb***/': {
        '/dev_usb000': {'Path': r'$(EmulatorDir)dev_usb000/', 'Serial': '', 'VID': '', 'PID': ''},
      },
    };
    final config = write(p.join(p.dirname(accountConfig), 'vfs.yml'), utf8.encode(jsonEncode(vfs)));
    final saved = await config.readAsString();
    expect((await verify()).systemRoot, profile.systemRoot);
    expect(await config.readAsString(), saved);

    vfs[r'$(EmulatorDir)'] = '${profile.systemRoot}/other/../rpcs3/';
    await config.writeAsString(jsonEncode(vfs));
    await expectLater(verify(), throwsA(Ps3OnlineIssue.storage));
    vfs[r'$(EmulatorDir)'] = '${profile.systemRoot}/rpcs3/';
    vfs['/dev_hdd0/'] = offline;
    await config.writeAsString(jsonEncode(vfs));
    await expectLater(verify(), throwsA(Ps3OnlineIssue.storage));
    expect(Directory(offline).listSync(), isEmpty);
  });

  test('rejects a missing or modified update and module, without changing the offline profile', () async {
    write('online/system/rpcs3/dev_hdd0/game/ABCD12345/USRDIR/EBOOT.BIN', [7]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.update));
    write('online/system/rpcs3/dev_hdd0/game/ABCD12345/USRDIR/EBOOT.BIN', [2]);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.sprx', [8]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.patch));
    expect(Directory(offline).listSync(), isEmpty);
  });

  test('rejects absent firmware, credentials and changed core bytes before boot', () async {
    File(p.join(online, 'system/rpcs3/dev_flash/vsh/module/vsh.self')).deleteSync();
    File(p.join(online, 'system/rpcs3/dev_flash/sys/external/liblv2.sprx')).deleteSync();
    await expectLater(verify(), throwsA(Ps3OnlineIssue.firmware));
    write('online/system/PS3UPDAT.PUP', [1, 2, 3]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.firmware));
    write('online/system/rpcs3/dev_flash/vsh/module/vsh.self', [5]);
    write('online/system/rpcs3/dev_flash/sys/external/liblv2.sprx', [5]);
    File(p.join(root.path, accountConfig)).deleteSync();
    await expectLater(verify(), throwsA(Ps3OnlineIssue.account));
    write(accountConfig, account.codeUnits);
    File(core).writeAsBytesSync([9]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.core));
  });

  test('rejects a different RPCN endpoint and provider config with redacted errors', () async {
    write(accountConfig, account.replaceFirst('rpcn.example.invalid', 'unknown.example.invalid').codeUnits);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.account));
    write(accountConfig, [0xff]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.account));
    write(accountConfig, account.replaceFirst('test-only', r'"bad\0value"').codeUnits);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.account));
    write(accountConfig, account.codeUnits);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.conf', [6]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.patch));
  });
}
