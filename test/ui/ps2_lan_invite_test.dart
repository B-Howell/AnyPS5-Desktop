import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/fixtures.dart' show ps2LanFixtureDll, writePs2IdentityIso;
import '../support/online_fakes.dart';
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
    bool cancelAdmission = false,
    bool hostChanged = false,
    bool quickBootCancel = false,
    bool quickMenuDuringPlay = false,
  }) async {
    final server = await FakeTogether.start();
    addTearDown(server.close);
    final network = FakeGameNetwork();
    final environment = {'ANYPS5_PS2_LAN': '1'};
    late File bios;
    final extensionsPicked = <List<String>>[];
    final fixture = makeFixture(
      together: server.base,
      system: HostSystem.windows,
      environment: environment,
      gameLinks: () => network.links,
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
    const local = '12345678-1234-4234-8234-123456789ab2';
    const hostDevice = '12345678-1234-4234-8234-123456789ab3';
    if (quickBootCancel || quickMenuDuringPlay) server.me['id'] = local;
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
      var paused = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop') stopped = true;
        if (call.method == 'pause') paused = call.arguments == true;
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
      model.padCommand(PadCommand.home);
      expect(model.quickMenuPaused, isTrue);
      await until(() => paused);
      model.padCommand(PadCommand.home);
      await until(() => !paused);
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
    if (quickBootCancel || quickMenuDuringPlay) {
      const path = 'game-sessions/$roomId';
      final room = {
        ...(server.answers['GET $path']!.$2 as Map<String, dynamic>),
        'members': [
          {'userId': local},
          {
            'userId': host,
            'device': hostDevice,
            'properties': {'protocol': protocol},
          },
        ],
      };
      server.answers.addAll({
        'GET $path': (200, room),
        'POST $path/join': (204, null),
        'PUT $path/members/me': (200, room),
        'GET $path/ice-servers': (200, {'iceServers': []}),
        'POST $path/leave': (204, null),
      });
      const channel = MethodChannel('anyps5/retro_core');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final starting = Completer<void>();
      final finishStart = Completer<void>();
      final pauseRequests = <Object?>[];
      final inputRequests = <Object?>[];
      var exchanges = 0;
      var stopped = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          starting.complete();
          await finishStart.future;
          return 42;
        }
        if (call.method == 'stop') stopped = true;
        if (call.method == 'pause') pauseRequests.add(call.arguments);
        if (call.method == 'input') inputRequests.add(call.arguments);
        if (call.method == 'ps2LanExchange') {
          exchanges++;
          return <Uint8List>[];
        }
        return call.method == 'status' ? {'presented': quickMenuDuringPlay, 'ended': stopped} : null;
      });
      addTearDown(() async {
        for (final row in model.together.ps2LanRows()) {
          if (row.kind case final ActionRow action) action.run();
        }
        if (!finishStart.isCompleted) finishStart.complete();
        if (model.running != null) await model.stopRunningGame();
        await until(() => model.starting == null && model.running == null && model.together.ps2LanRows().isEmpty);
        messenger.setMockMethodCallHandler(channel, null);
      });
      final peer = await network.links.link([]);
      addTearDown(peer.close);
      await peer.openChannel();
      final offer = await peer.createOffer();
      await peer.setLocal(offer);
      press(continueId);
      await server.nextFrame('signal', test: (frame) => frame['kind'] == 'renegotiate');
      server.push('game_session.signal', {
        'sessionId': roomId,
        'from': host,
        'device': hostDevice,
        'kind': 'offer',
        'data': {'sdp': offer['sdp']},
      });
      final answer = await server.nextFrame('signal', test: (frame) => frame['kind'] == 'answer');
      await peer.setRemote({'type': 'answer', ...(answer['data'] as Map<String, dynamic>)});
      await starting.future.timeout(const Duration(seconds: 5));
      expect(model.starting?.titleId, 'PS2-TIMESPLITTERS');
      if (quickMenuDuringPlay) {
        network.readPath = () async => (relayed: false, roundTripMs: 42);
        finishStart.complete();
        await until(() => model.embeddedGame?.presented == true && model.starting == null && exchanges > 0);
        inputRequests.clear();
        model.padCommand(PadCommand.home);
        expect(model.overlay, Layer.quickMenu);
        expect(row('ps2-lan-status').kind, isA<ActionRow>());
        final before = exchanges;
        await until(() => exchanges > before);
        expect(inputRequests, anyElement(equals([0, 0, 0, 0, 0])));
        expect(pauseRequests, isEmpty);
        expect(model.quickMenuPaused, isFalse);
        await until(() => row('ps2-lan-status').detail?.endsWith(' · Direct · 42 ms') == true);
        final readingOldPath = Completer<void>();
        final oldPath = Completer<({bool? relayed, int? roundTripMs})?>();
        addTearDown(() {
          if (!oldPath.isCompleted) oldPath.complete(null);
        });
        network.readPath = () {
          readingOldPath.complete();
          return oldPath.future;
        };
        await readingOldPath.future.timeout(const Duration(seconds: 5));
        final localLink = network.all.last;
        localLink.reportState('disconnected');
        await until(() => row('ps2-lan-status').detail == 'LAN connection interrupted. Reconnecting…');
        network.readPath = () async => (relayed: true, roundTripMs: 65);
        localLink.reportState('connected');
        await until(() => row('ps2-lan-status').detail?.startsWith("Open the game's LAN mode") == true);
        oldPath.complete((relayed: false, roundTripMs: 999));
        await Future<void>.delayed(Duration.zero);
        expect(row('ps2-lan-status').detail, isNot(contains('999 ms')));
        await until(() => row('ps2-lan-status').detail?.endsWith(' · Through the relay · 65 ms') == true);
        final worker = model.embeddedGame;
        expect(row('ps2-lan-status').title, 'Leave LAN Play');
        press('ps2-lan-status');
        await until(() => model.together.ps2LanRows().isEmpty);
        expect(server.callsTo('$path/leave'), hasLength(1));
        expect(model.embeddedGame, same(worker));
        expect(stopped, isFalse);
        expect(model.toast, contains('Your game is still open'));
        final afterLeave = exchanges;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(exchanges, afterLeave);
        model.padCommand(PadCommand.home);
        expect(model.overlay, isNull);
        expect(pauseRequests, isEmpty);
        await model.stopRunningGame();
        await until(() => stopped && model.running == null);
        expect(server.callsTo('$path/leave'), hasLength(1));
        return;
      }
      model.padCommand(PadCommand.home);
      expect(model.overlay, Layer.quickMenu);
      expect(row('ps2-lan-status').title, 'Cancel LAN Play');
      expect(row('ps2-lan-status').detail, 'Starting the PS2 LAN game…');
      press('ps2-lan-status');
      expect(row('ps2-lan-status').kind, isA<InfoRow>());
      finishStart.complete();
      await until(() => stopped && model.starting == null && model.running == null);
      expect(server.callsTo('$path/leave'), hasLength(1));
      return;
    }
    if (hostChanged) {
      const path = 'game-sessions/$roomId';
      final answer = server.answers.remove('GET $path')!;
      var reads = 0;
      server.handlers.add((call) {
        if (call.method != 'GET' || call.path != path) return null;
        if (++reads == 1) return answer;
        return (
          200,
          {
            ...(answer.$2 as Map<String, dynamic>),
            'host': {'userId': '12345678-1234-4234-8234-123456789abd'},
          },
        );
      });
      press(continueId);
      await until(() => reads == 2);
      await until(() => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'));
      expect(server.callsTo('$path/join'), isEmpty);
      expect(model.toast, contains('host has changed'));
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
    if (cancelAdmission) {
      const path = 'game-sessions/$roomId';
      final answer = server.answers['GET $path']!;
      final admitting = Completer<void>();
      final admitted = Completer<void>();
      final leaving = Completer<void>();
      final left = Completer<void>();
      server.answers.remove('POST $path/join');
      server.answers['PUT $path/members/me'] = answer;
      server.handlers.add((call) async {
        if (call.method != 'POST') return null;
        if (call.path == '$path/join') {
          admitting.complete();
          await admitted.future;
          return (204, null);
        }
        if (call.path == '$path/leave') {
          leaving.complete();
          await left.future;
          return (204, null);
        }
        return null;
      });
      addTearDown(() {
        if (!admitted.isCompleted) admitted.complete();
        if (!left.isCompleted) left.complete();
      });
      press(continueId);
      await admitting.future.timeout(const Duration(seconds: 5));
      press('ps2-lan-status');
      expect(row('ps2-lan-status').kind, isA<InfoRow>());
      await Future<void>.delayed(const Duration(milliseconds: 8250));
      expect(row('ps2-lan-status').kind, isA<InfoRow>());
      press('game-accept-$roomId');
      expect(model.toast, 'Closing the LAN session…');
      expect(server.callsTo('$path/join'), hasLength(1));

      admitted.complete();
      await leaving.future.timeout(const Duration(seconds: 5));
      expect(row('ps2-lan-status').kind, isA<InfoRow>());
      left.complete();
      await until(() => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'));
      expect(model.running, isNull);
      server.answers['POST $path/join'] = (403, {'code': 'fixture_done'});
      press('game-accept-$roomId');
      await until(() => server.callsTo('$path/join').length == 2);
      expect(server.callsTo('$path/leave'), hasLength(1));
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
  test(
    'PS2 LAN retry waits for a canceled admission and its room leave after local close times out',
    () => verifyBundledSetup(expired: false, cancelAdmission: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN refuses a room that changes host after the disc lookup',
    () => verifyBundledSetup(expired: false, hostChanged: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN can be canceled from the Quick Menu before the worker opens',
    () => verifyBundledSetup(expired: false, quickBootCancel: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN keeps exchanging frames while the Quick Menu is open',
    () => verifyBundledSetup(expired: false, quickMenuDuringPlay: true),
    skip: Abi.current() != Abi.windowsX64,
  );
}
