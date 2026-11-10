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
    bool timeoutLookup = false,
    bool cancelAdmission = false,
    bool hostChanged = false,
    bool omitInviteSender = false,
    bool failIce = false,
    bool timeoutIce = false,
    bool failNativeBoot = false,
    bool quickBootCancel = false,
    bool quickMenuDuringPlay = false,
    bool explainRoomEnd = false,
    bool hostRematch = false,
    bool dashboardHost = false,
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
    final liveMenu = quickMenuDuringPlay || hostRematch;
    if (quickBootCancel || liveMenu || failIce || timeoutIce || failNativeBoot) server.me['id'] = local;
    if (hostRematch) server.friend(host, 'ana', 'Ana', presence: {'state': 'online'});
    final protocol = RetroOnlineMode.lan.protocol;
    final invite = {
      'sessionId': roomId,
      if (!omitInviteSender) 'from': server.person(host, 'ana', 'Ana'),
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
    if (dashboardHost) {
      model.selected = model.games.indexWhere((game) => game.titleId == 'PS2-TIMESPLITTERS');
      model.open(Layer.gameSettings);
      void select(String id) =>
          model.activateRow(model.panelCategories().single.rows.indexWhere((item) => item.id == id));
      const link = 'ps2-lan-dashboard-invite';
      final friendRow = 'ps2-lan-dashboard-$host';
      await until(() => model.together.hub.friends.friends.any((friend) => friend.person.id == host));
      select(link);
      expect(row(friendRow).title, 'Ana');
      select(friendRow);
      expect(model.overlay, Layer.emulatorMenu);
      expect(row(continueId).kind, isA<InfoRow>());
      model.handle(Command.back);
      expect(model.spot?.row, friendRow);
      model.handle(Command.back);
      expect(model.overlay, Layer.gameSettings);
      expect(model.spot?.row, link);
      expect(server.callsTo('game-sessions', method: 'POST'), isEmpty);
      select(link);
      select(friendRow);
    } else {
      press('game-accept-$roomId');
    }
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
    expect(server.callsTo('game-sessions', method: 'POST'), isEmpty);
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
    if (quickBootCancel || liveMenu || failIce || timeoutIce || failNativeBoot) {
      const path = 'game-sessions/$roomId';
      final room = {
        ...(server.answers['GET $path']!.$2 as Map<String, dynamic>),
        if (hostRematch) 'host': {'userId': local},
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
        if (hostRematch) ...{
          'POST game-sessions': (201, room),
          'POST $path/invites': (204, null),
          'DELETE $path': (204, null),
        },
      });
      if (timeoutIce) {
        final requested = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        server.answers.remove('GET $path/ice-servers');
        server.handlers.add((call) async {
          if (call.method != 'GET' || call.path != '$path/ice-servers') return null;
          requested.complete();
          await release.future;
          return (200, {'iceServers': []});
        });
        press(continueId);
        await requested.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(seconds: 12));
        await until(() => server.callsTo('$path/leave').length == 1);
        await until(() => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'));
        expect(model.toast, 'Connecting took too long. Ask your friend to send a new invite.');
        expect(model.running, isNull);
        expect(network.made, isEmpty);
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(network.made, isEmpty);
        return;
      }
      if (failIce) {
        server.answers['GET $path/ice-servers'] = (500, {'code': 'no_route'});
        press(continueId);
        await until(
          () => model.toast == 'The LAN room opened, but a connection to the other player could not be established.',
          reason: 'Expected connection failure after the room opened. Status: ${model.toast}',
        );
        expect(server.callsTo('$path/leave'), hasLength(1));
        expect(model.running, isNull);
        expect(model.starting, isNull);
        return;
      }
      const channel = MethodChannel('anyps5/retro_core');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final starting = Completer<void>();
      final finishStart = Completer<void>();
      final pauseRequests = <Object?>[];
      final inputRequests = <Object?>[];
      var exchanges = 0;
      var resets = 0;
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
        if (call.method == 'ps2LanReset') {
          expect(call.arguments, 42);
          resets++;
          return true;
        }
        if (call.method == 'ps2LanExchange') {
          exchanges++;
          return <Uint8List>[];
        }
        return call.method == 'status' ? {'presented': liveMenu, 'ended': stopped || failNativeBoot} : null;
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
      Future<void> connectPeer(String id, void Function() admit) async {
        final peer = await network.links.link([]);
        addTearDown(peer.close);
        await peer.openChannel();
        final offer = await peer.createOffer();
        await peer.setLocal(offer);
        final waitForFriend = hostRematch && id == roomId;
        if (waitForFriend) {
          server.answers['GET $path'] = (
            200,
            {
              ...room,
              'members': [
                {'userId': local},
              ],
            },
          );
        }
        admit();
        await until(
          () => server.callsTo('game-sessions/$id/${hostRematch ? 'invites' : 'join'}', method: 'POST').isNotEmpty,
          reason: 'Expected room admission for $id. Status: ${model.toast}',
        );
        if (waitForFriend) {
          await until(
            () => model.together.ps2LanRows().singleOrNull?.detail == 'Waiting for your friend to accept…',
            reason: 'The host should see that the invitation is still pending.',
          );
          expect(model.running, isNull);
          expect(model.starting, isNull);
          server.answers['GET $path'] = (200, room);
        }
        await server.nextFrame('signal', test: (frame) => frame['kind'] == 'renegotiate');
        expect(model.together.ps2LanRows().single.detail, 'Connecting to the other player…');
        server.push('game_session.signal', {
          'sessionId': id,
          'from': host,
          'device': hostDevice,
          'kind': 'offer',
          'data': {'sdp': offer['sdp']},
        });
        final answer = await server.nextFrame('signal', test: (frame) => frame['kind'] == 'answer');
        await peer.setRemote({'type': 'answer', ...(answer['data'] as Map<String, dynamic>)});
      }

      await connectPeer(roomId, () {
        if (hostRematch && !dashboardHost) {
          model.selected = model.games.indexWhere((game) => game.titleId == 'PS2-TIMESPLITTERS');
          expect(model.selectedGame?.titleId, 'PS2-TIMESPLITTERS');
          final friend = model.together.hub.friends.friends.single;
          expect(friend.presence.online, isTrue);
          (model.together.ps2LanInvites(friend).single.kind as ActionRow).run();
        } else {
          press(continueId);
        }
      });
      if (dashboardHost) {
        final request = server.callsTo('game-sessions/$roomId/invites', method: 'POST').single.body;
        expect(request['userIds'], [host]);
      }
      await starting.future.timeout(const Duration(seconds: 5));
      expect(model.starting?.titleId, 'PS2-TIMESPLITTERS');
      if (failNativeBoot) {
        finishStart.complete();
        await until(() => model.toast == 'The LAN connection is ready, but the PS2 game could not start.');
        expect(server.callsTo('$path/leave'), hasLength(1));
        expect(model.running, isNull);
        return;
      }
      if (liveMenu) {
        network.readPath = () async => (relayed: false, roundTripMs: 42);
        finishStart.complete();
        await until(() => model.embeddedGame?.presented == true && model.starting == null && exchanges > 0);
        inputRequests.clear();
        model.padCommand(PadCommand.home);
        expect(model.overlay, Layer.quickMenu);
        expect(row('ps2-lan-status').kind, isA<ActionRow>());
        expect(row('ps2-lan-status').detail, contains(hostRematch ? 'host a game' : 'join the host'));
        final before = exchanges;
        await until(() => exchanges > before);
        expect(inputRequests, anyElement(equals([0, 0, 0, 0, 0])));
        expect(pauseRequests, isEmpty);
        expect(model.quickMenuPaused, isFalse);
        await until(
          () => row('ps2-lan-status').detail?.endsWith(' · Direct · 42 ms') == true,
          reason: 'The first route should report direct latency.',
        );
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
        final beforeDisconnectResets = resets;
        localLink.reportState('disconnected');
        await until(
          () => row('ps2-lan-status').detail == 'LAN connection interrupted. Reconnecting…',
          reason: 'A disconnected link should show Reconnecting.',
        );
        expect(resets, greaterThan(beforeDisconnectResets));
        final beforeReconnectResets = resets;
        network.readPath = () async => (relayed: true, roundTripMs: 65);
        localLink.reportState('connected');
        await until(
          () => row('ps2-lan-status').detail?.startsWith("Open the game's LAN mode") == true,
          reason: 'The restored link should clear Reconnecting.',
        );
        oldPath.complete((relayed: false, roundTripMs: 999));
        await Future<void>.delayed(Duration.zero);
        expect(row('ps2-lan-status').detail, isNot(contains('999 ms')));
        await until(
          () => row('ps2-lan-status').detail?.endsWith(' · Through the relay · 65 ms') == true,
          reason: 'The restored route should report the new relay latency.',
        );
        expect(resets, greaterThan(beforeReconnectResets));
        final worker = model.embeddedGame;
        expect(row('ps2-lan-status').title, 'Leave LAN Play');
        if (explainRoomEnd) {
          localLink.reportState('game-closed');
        } else {
          press('ps2-lan-status');
        }
        await until(() => model.together.ps2LanRows().isEmpty);
        List<FakeCall> leaves(String path) =>
            hostRematch ? server.callsTo(path, method: 'DELETE') : server.callsTo('$path/leave');
        expect(leaves(path), hasLength(1));
        expect(model.embeddedGame, same(worker));
        expect(stopped, isFalse);
        if (explainRoomEnd) {
          expect(model.toast, 'The LAN connection ended. Your game is still open.');
        } else {
          expect(model.toast, contains('Your game is still open'));
        }
        final afterLeave = exchanges;
        final resetsAfterLeave = resets;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(exchanges, afterLeave);
        model.padCommand(PadCommand.home);
        expect(model.overlay, isNull);
        expect(pauseRequests, isEmpty);
        const nextRoom = '12345678-1234-4234-8234-123456789abd';
        const nextPath = 'game-sessions/$nextRoom';
        final next = {...room, 'id': nextRoom, 'sessionId': nextRoom};
        server.answers.addAll({
          'GET $nextPath': (200, next),
          'POST $nextPath/join': (204, null),
          'PUT $nextPath/members/me': (200, next),
          'GET $nextPath/ice-servers': (200, {'iceServers': []}),
          'POST $nextPath/leave': (204, null),
          if (hostRematch) ...{
            'POST game-sessions': (201, next),
            'POST $nextPath/invites': (204, null),
            'DELETE $nextPath': (204, null),
          },
        });
        server.gameInvites
          ..clear()
          ..add({...invite, 'sessionId': nextRoom});
        await model.together.hub.games.refresh();
        if (hostRematch) {
          model.padCommand(PadCommand.home);
          press('ps2-lan-invite-from-game');
          expect(model.overlay, Layer.retroOnlineFriends);
          expect(row('ps2-lan-invite-$host').title, 'Ana');
          expect(model.embeddedGame, same(worker));
          press('retro-invite-back');
          expect(model.overlay, Layer.quickMenu);
          press('ps2-lan-invite-from-game');
          model.selected = model.games.indexWhere((game) => game.titleId == 'PS2-GT4');
          await connectPeer(nextRoom, () => press('ps2-lan-invite-$host'));
          expect(server.callsTo('game-sessions', method: 'POST').last.body['titleId'], 'SLUS21148');
        } else {
          model.open(Layer.quickMenu);
          await connectPeer(nextRoom, () => press('game-accept-$nextRoom'));
        }
        await until(
          () => exchanges > afterLeave && model.overlay == null,
          reason: 'The second room should resume exchange and return from Friends to the same game.',
        );
        expect(model.embeddedGame, same(worker));
        expect(resets, resetsAfterLeave + 1);
        if (explainRoomEnd) {
          server.push('game_session.ended', {'sessionId': nextRoom});
          await until(() => model.together.ps2LanRows().isEmpty);
          expect(model.toast, 'The LAN room closed on the other end. Your game is still open.');
          expect(model.embeddedGame, same(worker));
          expect(stopped, isFalse);
          expect(leaves(nextPath), hasLength(1));
        }
        await model.stopRunningGame();
        await until(() => stopped && model.running == null);
        expect(leaves(path), hasLength(1));
        await until(
          () => leaves(nextPath).length == 1,
          reason: 'Closing the reused worker should release its new room.',
        );
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
    if (cancelLookup || timeoutLookup) {
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
      if (timeoutLookup) {
        expect(
          await eventually(
            () => model.toast?.contains('Try accepting the invite again') == true,
            timeout: const Duration(seconds: 15),
          ),
          isTrue,
        );
      } else {
        press('ps2-lan-status');
      }
      await until(
        () => !model.panelCategories().single.rows.any((row) => row.id == 'ps2-lan-status'),
        reason: 'The attempt must be released before the first room reply.',
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
    await until(() => model.toast == 'The LAN room could not be opened. Try the invitation again.');
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
    'a stalled PS2 LAN lookup times out and can be retried before the old reply',
    () => verifyBundledSetup(expired: false, timeoutLookup: true),
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
    'PS2 LAN refuses a changed host when the invite has no sender',
    () => verifyBundledSetup(expired: false, hostChanged: true, omitInviteSender: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN reports a peer connection failure before the game boots',
    () => verifyBundledSetup(expired: false, failIce: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN explains a connection settings timeout',
    () => verifyBundledSetup(expired: false, timeoutIce: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN reports a native exit before the game becomes visible',
    () => verifyBundledSetup(expired: false, failNativeBoot: true),
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
  test(
    'PS2 LAN explains why a room ended and preserves the running game',
    () => verifyBundledSetup(expired: false, quickMenuDuringPlay: true, explainRoomEnd: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN host can invite a friend to a new room from the Quick Menu',
    () => verifyBundledSetup(expired: false, hostRematch: true),
    skip: Abi.current() != Abi.windowsX64,
  );
  test(
    'PS2 LAN starts from Game Settings and resumes the selected friend after setup',
    () => verifyBundledSetup(expired: false, hostRematch: true, dashboardHost: true),
    skip: Abi.current() != Abi.windowsX64,
  );
}
