import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/fixtures.dart' show ps2LanFixtureDll, writePs2IdentityIso;
import '../support/ui_support.dart';

void main() {
  LoopbackTestBinding();

  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue, reason: reason);
  }

  test('a PS2 LAN invite opens missing setup and Back restores the same invite', () async {
    final lanServer = await FakeTogether.start();
    addTearDown(lanServer.close);
    lanServer.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    final lanFixture = makeFixture(
      together: lanServer.base,
      system: HostSystem.windows,
      environment: {'ANYPS5_PS2_LAN': '1'},
    );
    final lan = lanFixture.model;
    addTearDown(() {
      lan.dispose();
      lanFixture.dispose();
    });
    lan.together.email = 'fixture@example.invalid';
    await lan.together.sendCode();
    lan.together.code = '123456';
    await lan.together.verify();
    await until(() => lan.together.hub.friends.loaded);
    final disc = File(p.join(lanFixture.temp.path, 'game.iso'));
    writePs2IdentityIso(disc, bootSerial: 'SLUS_211.48', revision: '1.00');
    final game = Game(
      folder: lanFixture.temp.path,
      titleId: 'PS2-TIMESPLITTERS',
      name: 'TimeSplitters: Future Perfect',
      names: const {},
      defaultLanguage: 'en',
      version: '1.00',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: disc.path),
      retroSerial: 'SLUS21148',
    );
    const roomId = '12345678-1234-4234-8234-123456789abc';
    final invite = {
      'sessionId': roomId,
      'from': lanServer.person('u-ana', 'ana', 'Ana'),
      'titleId': 'SLUS21148',
      'gameVersion': '1.00',
      'engineBuild': RetroOnlineMode.lan.protocol,
    };
    lanServer.gameInvites.add(invite);
    lanServer.push('game_session.invite', invite);
    await until(() => lan.together.hub.games.invites.isNotEmpty);
    lan.open(Layer.friends);
    final origin = (layer: Layer.friends, category: lan.panelCategories().single.id, row: 'game-accept-$roomId');
    lan.returnTo(origin);
    PanelRow accept() => lan.panelCategories().single.rows.singleWhere((row) => row.id == origin.row);
    expect(accept().detail, 'This room needs a matching PS2 disc ISO in your library.');
    (accept().kind as ActionRow).run();
    expect(lan.overlay, Layer.friends);
    lan.games.add(game);
    expect(accept().detail, 'Install the LAN-enabled PS2 emulator before starting.');
    (accept().kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    expect(lan.panelCategories().single.rows.map((row) => row.id), contains('ps2-lan-setup-install'));
    await lan.together.hub.games.refresh();
    expect(lanServer.callsTo('game-sessions/$roomId'), isEmpty);
    expect(lanServer.callsTo('game-sessions/$roomId/join'), isEmpty);
    expect(lanServer.callsTo('game-sessions/$roomId/decline'), isEmpty);
    expect(lan.running, isNull);
    lan.handle(Command.back);
    expect(lan.spot, origin);
    expect(lan.together.hub.games.invites.single.sessionId, roomId);

    lan.selected = lan.games.indexOf(game);
    lan.together.openFriend(lan.together.hub.friends.friends.single);
    final outgoing = lan.panelCategories().single.rows.singleWhere((row) => row.id == 'ps2-lan-invite');
    final friendOrigin = (layer: lan.overlay!, category: lan.panelCategories().single.id, row: outgoing.id);
    lan.returnTo(friendOrigin);
    expect(outgoing.detail, 'Install the LAN-enabled PS2 emulator before starting.');
    (outgoing.kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    await lan.together.hub.games.refresh();
    expect(lanServer.callsTo('game-sessions', method: 'POST'), isEmpty);
    lan.handle(Command.back);
    expect(lan.spot, friendOrigin);
    (outgoing.kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    await lan.together.signOut();
    lan.handle(Command.back);
    expect(lan.overlay, Layer.friends);
  }, skip: Abi.current() != Abi.windowsX64);

  Future<void> verifyBundledSetup({
    required bool expired,
    bool configureCard = false,
    bool cancelLookup = false,
  }) async {
    final server = await FakeTogether.start();
    addTearDown(server.close);
    final environment = {'ANYPS5_PS2_LAN': '1'};
    late File bios;
    final extensionsPicked = <List<String>>[];
    final fixture = makeFixture(
      together: server.base,
      system: HostSystem.windows,
      environment: environment,
      pickFile: (_, extensions) async {
        extensionsPicked.add(extensions);
        return bios.path;
      },
    );
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final root = fixture.temp.path;
    bios = File(p.join(root, 'bios.bin'))..writeAsBytesSync(Uint8List(4 * 1024 * 1024)..[0] = 7);
    final packages = Directory(p.join(root, 'packages'))..createSync();
    final bytes = ps2LanFixtureDll();
    final archive = File(p.join(packages.path, 'pcsx2_libretro.dll.zip'))
      ..writeAsBytesSync(
        ZipEncoder().encode(Archive()..addFile(ArchiveFile('pcsx2_libretro.dll', bytes.length, bytes))),
      );
    environment['ANYPS5_MANAGED_CORE_PACKAGES'] = packages.path;
    environment['ANYPS5_PS2_LAN_CORE_DIGESTS'] =
        '${await AssetDownload.sha256Of(archive.path)}:${sha256.convert(bytes)}';
    final offline = File(p.join(p.dirname(model.paths.toolkits), 'Emulators', 'pcsx2_libretro.dll'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final disc = File(p.join(root, 'game.iso'));
    writePs2IdentityIso(disc, bootSerial: 'SLUS_211.48', revision: '1.00');
    final setupDisc = File(p.join(root, 'network-setup.iso'));
    writePs2IdentityIso(setupDisc, bootSerial: 'SCUS_973.28', revision: '2.00');
    model.games.add(
      Game(
        folder: root,
        titleId: 'PS2-TIMESPLITTERS',
        name: 'TimeSplitters fixture',
        names: const {},
        defaultLanguage: 'en',
        version: '1.00',
        executable: ExecutableKind.disc,
        retro: (platform: RetroPlatform.ps2, path: disc.path),
        retroSerial: 'SLUS21148',
      ),
    );
    model.games.add(
      Game(
        folder: root,
        titleId: 'PS2-GT4',
        name: 'Gran Turismo 4',
        names: const {},
        defaultLanguage: 'en',
        version: '2.00',
        executable: ExecutableKind.disc,
        retro: (platform: RetroPlatform.ps2, path: setupDisc.path),
        retroSerial: 'SCUS97328',
      ),
    );
    const host = '12345678-1234-4234-8234-123456789ab1';
    const roomId = '12345678-1234-4234-8234-123456789abc';
    final protocol = RetroOnlineMode.lan.protocol;
    final invite = {
      'sessionId': roomId,
      'from': server.person(host, 'ana', 'Ana'),
      'titleId': 'SLUS21148',
      'gameVersion': '1.00',
      'engineBuild': protocol,
    };
    server.gameInvites.add(invite);
    server.answers['GET game-sessions/$roomId'] = (
      200,
      {
        ...invite,
        'id': roomId,
        'host': {'userId': host},
        'kind': 'online',
        'capacity': 2,
        'joinable': false,
        'properties': {'protocol': protocol, 'discSha256': await AssetDownload.sha256Of(disc.path)},
      },
    );
    server.answers['POST game-sessions/$roomId/join'] = (403, {'code': 'fixture_done'});
    model.together.email = 'fixture@example.invalid';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.socket.status.name == 'ready');
    await model.together.hub.games.refresh();
    model.open(Layer.friends);
    PanelRow row(String id) => model.panelCategories().single.rows.singleWhere((row) => row.id == id);
    void press(String id) => (row(id).kind as ActionRow).run();
    const continueId = 'ps2-lan-setup-continue';
    press('game-accept-$roomId');
    expect(row(continueId).kind, isA<InfoRow>());
    press('ps2-lan-setup-install');
    await until(() => model.ps2LanCoreInstalled && model.managedSetupConsole == null);
    expect(extensionsPicked, isEmpty);
    expect(row(continueId).kind, isA<InfoRow>());
    press('ps2-lan-setup-bios');
    await until(() => model.ps2LanBiosPath != null && model.managedSetupConsole == null);
    expect(extensionsPicked.single, contains('bin'));
    expect(row('ps2-lan-setup-launch').kind, isA<ActionRow>());
    expect(offline.readAsBytesSync(), [1, 2, 3]);
    expect(server.callsTo('game-sessions/$roomId'), isEmpty);
    if (configureCard) {
      const channel = MethodChannel('anyps5/retro_core');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var stopped = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop') stopped = true;
        return switch (call.method) {
          'start' => 42,
          'status' => {'presented': true, 'ended': stopped},
          'ps2LanExchange' => <Uint8List>[],
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      press('ps2-lan-setup-launch');
      await until(() => model.embeddedGame?.presented == true && model.starting == null);
      expect(model.overlay, isNull);
      expect(model.running?.$1.titleId, 'PS2-GT4');
      await model.stopRunningGame();
      await until(() => model.overlay == Layer.emulatorMenu && !model.ps2LanSetupActive);
      expect(row(continueId).kind, isA<ActionRow>());
      expect(server.callsTo('game-sessions/$roomId'), isEmpty);
    }
    if (expired) {
      server.gameInvites.clear();
      server.push('game_session.ended', {'sessionId': roomId});
      await until(() => model.together.hub.games.invites.isEmpty);
      press(continueId);
      expect(model.toast, contains('no longer active'));
      expect(server.callsTo('game-sessions/$roomId'), isEmpty);
      expect(server.callsTo('game-sessions/$roomId/join'), isEmpty);
      expect(model.running, isNull);
      return;
    }
    if (cancelLookup) {
      const roomPath = 'game-sessions/$roomId';
      final answer = server.answers.remove('GET $roomPath')!;
      final requested = Completer<void>();
      final reply = Completer<void>();
      server.handlers.add((call) async {
        if (call.method != 'GET' || call.path != roomPath) return null;
        if (!requested.isCompleted) requested.complete();
        await reply.future;
        return answer;
      });
      addTearDown(() {
        if (!reply.isCompleted) reply.complete();
      });
      press(continueId);
      await requested.future.timeout(const Duration(seconds: 5));
      press('ps2-lan-status');
      await until(
        () => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'),
        reason: 'Canceled lookup must release the attempt before the first room reply.',
      );
      expect(server.callsTo('$roomPath/join'), isEmpty);
      expect(model.together.hub.games.invites.single.sessionId, roomId);

      server.answers['GET $roomPath'] = answer;
      press('game-accept-$roomId');
      await until(
        () => server.callsTo('$roomPath/join', method: 'POST').length == 1,
        reason: 'Retry must reach room admission while the old reply is withheld.',
      );
      reply.complete();
      await until(
        () => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'),
        reason: 'The fixture rejects retry admission, so the attempt must finish.',
      );
      expect(server.callsTo('$roomPath/join', method: 'POST'), hasLength(1));
      expect(model.running, isNull);
      return;
    }
    press(continueId);
    await until(() => server.callsTo('game-sessions/$roomId/join', method: 'POST').isNotEmpty);
    expect(model.overlay, Layer.friends);
    expect(model.running, isNull);
  }

  test(
    'a bundled PS2 LAN core and BIOS setup continue the original invite',
    () => verifyBundledSetup(expired: false),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'finishing PS2 LAN setup cannot join an invite that ended during setup',
    () => verifyBundledSetup(expired: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'closing the local PS2 card setup restores the pending LAN invite',
    () => verifyBundledSetup(expired: false, configureCard: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'canceling a stalled PS2 LAN lookup releases the invite for retry before the old reply',
    () => verifyBundledSetup(expired: false, cancelLookup: true),
    skip: Abi.current() != Abi.windowsX64,
  );
}
