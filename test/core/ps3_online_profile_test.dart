import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/ps3_online_profile.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _sfo(Map<String, String> fields) {
  final keys = fields.keys.map((key) => [...key.codeUnits, 0]).toList();
  final values = fields.values.map((value) => [...value.codeUnits, 0]).toList();
  final keyStart = 20 + fields.length * 16;
  final valueStart = keyStart + keys.fold<int>(0, (size, key) => size + key.length);
  final data = Uint8List(valueStart + values.fold<int>(0, (size, value) => size + value.length));
  final header = ByteData.sublistView(data);
  header.setUint32(0, 0x00505346);
  header.setUint32(8, keyStart, Endian.little);
  header.setUint32(12, valueStart, Endian.little);
  header.setUint32(16, fields.length, Endian.little);
  var key = 0;
  var value = 0;
  for (var i = 0; i < fields.length; i++) {
    final entry = 20 + i * 16;
    header.setUint16(entry, key, Endian.little);
    header.setUint16(entry + 2, 0x0204, Endian.little);
    header.setUint32(entry + 4, values[i].length, Endian.little);
    header.setUint32(entry + 12, value, Endian.little);
    data.setAll(keyStart + key, keys[i]);
    data.setAll(valueStart + value, values[i]);
    key += keys[i].length;
    value += values[i].length;
  }
  return data;
}

void main() {
  late Directory root;
  late Ps3OnlineRelease release;
  late String disc, core, online, offline;
  final accountConfig = Platform.isWindows ? 'online/system/rpcs3/config/rpcn.yml' : 'online/system/rpcs3/rpcn.yml';
  const account = 'Version: 2\nHost: rpcn.example.invalid\nNPID: fixture\nPassword: test-only\n';

  File write(String name, List<int> bytes) => File(p.join(root.path, name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  setUp(() {
    root = Directory.systemTemp.createTempSync('ps3-online-test-');
    disc = write('disc/PS3_DISC.SFB', [0]).path;
    core = write('rpcs3_libretro.dll', [1]).path;
    online = (Directory(p.join(root.path, 'online'))..createSync()).path;
    offline = (Directory(p.join(root.path, 'offline'))..createSync()).path;
    write('disc/PS3_GAME/USRDIR/EBOOT.BIN', [0]);
    write('disc/PS3_GAME/PARAM.SFO', _sfo({'TITLE_ID': 'ABCD12345', 'APP_VER': '01.00'}));
    write('online/system/rpcs3/dev_hdd0/game/ABCD12345/PARAM.SFO', _sfo({'TITLE_ID': 'ABCD12345', 'APP_VER': '01.30'}));
    write('online/system/rpcs3/dev_hdd0/game/ABCD12345/USRDIR/EBOOT.BIN', [2]);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.sprx', [3]);
    write(accountConfig, account.codeUnits);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.conf', [4]);
    write('online/system/rpcs3/dev_flash/vsh/module/vsh.self', [5]);
    release = Ps3OnlineRelease(
      provider: 'fixture',
      titleId: 'ABCD12345',
      updateVersion: '01.30',
      coreSha256: sha256.convert([1]).toString(),
      executableSha256: sha256.convert([2]).toString(),
      patchName: 'provider.sprx',
      patchSha256: sha256.convert([3]).toString(),
      rpcnHost: 'rpcn.example.invalid',
      providerFiles: {
        'plugins/provider.conf': sha256.convert([4]).toString(),
      },
      xfloat: Ps3Xfloat.accurate,
      dns: Ps3Dns.cloudflare,
      upnp: true,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<Ps3OnlineProfile> verify({String? provider, String? onlineRoot}) => Ps3OnlineProfile.verify(
    provider: provider ?? release.provider,
    disc: disc,
    core: core,
    onlineRoot: onlineRoot ?? online,
    offlineSystemRoot: offline,
    releases: [release],
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

  test('rejects an unqualified provider or shared offline system before boot', () async {
    await expectLater(verify(provider: 'unreviewed'), throwsA(Ps3OnlineIssue.unqualified));
    await expectLater(verify(onlineRoot: offline), throwsA(Ps3OnlineIssue.storage));
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
    await expectLater(verify(), throwsA(Ps3OnlineIssue.firmware));
    write('online/system/rpcs3/dev_flash/vsh/module/vsh.self', [5]);
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
    write(accountConfig, account.codeUnits);
    write('online/system/rpcs3/dev_hdd0/plugins/provider.conf', [6]);
    await expectLater(verify(), throwsA(Ps3OnlineIssue.patch));
  });
}
