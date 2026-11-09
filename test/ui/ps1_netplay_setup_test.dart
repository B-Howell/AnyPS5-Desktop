import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:anyps5_desktop/ui/ps1_netplay_runner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

void main() {
  _LoopbackBinding();
  test('ordinary host imports a new epoch and restores the original after stopping the match', () async {
    final events = <String>[];
    final state = Uint8List.fromList([1, 2, 3]);
    final runner = OrdinaryPs1NetplayRunner(
      match: _FixtureMatch(events),
      park: () async {
        events.add('park');
        return (frame: 616, state: state);
      },
      detach: () async {
        events.add('detach');
        return 17;
      },
      unpark: () async => events.add('unpark'),
      drainWorker: () async => events.add('drain'),
      importMatch: (snapshot) async {
        expect(snapshot, (frame: 0, state: state));
        events.add('import');
      },
      recover: (ticket) async => events.add('recover $ticket'),
    );
    await runner.prepare(0);
    expect(await runner.capture(), (frame: 0, state: state));
    await runner.start();
    await runner.stop();
    await runner.stop();
    expect(events, ['park', 'detach', 'drain', 'prepare 0', 'import', 'start', 'stop', 'drain', 'recover 17']);
  });

  test('canceling during park releases the original without detaching it', () async {
    final events = <String>[];
    final parked = Completer<void>();
    final runner = OrdinaryPs1NetplayRunner(
      match: _FixtureMatch(events),
      park: () async {
        events.add('park');
        await parked.future;
        return (frame: 616, state: Uint8List.fromList([1]));
      },
      detach: () async => throw StateError('Unexpected detach'),
      unpark: () async => events.add('unpark'),
      drainWorker: () async => throw StateError('Unexpected drain'),
      importMatch: (_) async => throw StateError('Unexpected import'),
      recover: (_) async => throw StateError('Unexpected restore'),
    );
    final preparation = expectLater(runner.prepare(0), throwsStateError);
    final stopped = runner.stop();
    parked.complete();
    await preparation;
    await stopped;
    expect(events, ['park', 'stop', 'unpark']);
  });

  test('canceling during detach drains the source before reopening it', () async {
    final events = <String>[];
    final detaching = Completer<void>();
    final ticket = Completer<int>();
    final runner = OrdinaryPs1NetplayRunner(
      match: _FixtureMatch(events),
      park: () async => (frame: 616, state: Uint8List.fromList([1])),
      detach: () {
        events.add('detach');
        detaching.complete();
        return ticket.future;
      },
      unpark: () async => throw StateError('Unexpected unpark'),
      drainWorker: () async => events.add('drain'),
      importMatch: (_) async => throw StateError('Unexpected import'),
      recover: (token) async => events.add('recover $token'),
    );
    final preparation = expectLater(runner.prepare(0), throwsStateError);
    await detaching.future;
    final stopped = runner.stop();
    ticket.complete(17);
    await preparation;
    await stopped;
    expect(events, ['detach', 'stop', 'drain', 'drain', 'recover 17']);
  });

  test('reopening waits for the matching recovery token before unpausing', () async {
    final root = await Directory.systemTemp.createTemp('anyps5-return-');
    addTearDown(() => root.delete(recursive: true));
    const channel = MethodChannel('anyps5/retro_core');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var polls = 0;
    var resumed = false;
    var stopped = false;
    final input = Completer<void>();
    var padReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ps1LocalCheckpointReopen':
          expect(call.arguments, 17);
          return 41;
        case 'status':
          polls++;
          return {'ps1RecoveredSource': polls > 1 ? 17 : 18, 'startupVisible': polls == 1 || resumed, 'ended': stopped};
        case 'pause':
          expect(polls, greaterThan(1));
          expect(call.arguments, false);
          resumed = true;
        case 'ps1LocalCheckpointAccept':
          expect(resumed, isTrue);
          expect(call.arguments, {'source': 17, 'texture': 41});
          return true;
        case 'stop':
          stopped = true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final game = await EmbeddedRetroGame.start(
      root.path,
      (platform: RetroPlatform.ps1, path: p.join(root.path, 'game.cue')),
      internalResolution: null,
      graphics: const {},
      onResolutionSelected: (_) {},
      onGraphicsSelected: (_, _) {},
      readPad: () {
        padReads++;
        if (!input.isCompleted) input.complete();
        return PadState.idle;
      },
      changed: () {},
      ordinaryRecovery: 17,
    );
    addTearDown(() async {
      await game.close();
      await game.exitCode;
    });
    expect(await game.ready.timeout(const Duration(seconds: 3)), isTrue);
    expect(resumed, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(padReads, 0);
    expect(await game.acceptOrdinaryRecovery(17), isTrue);
    await input.future.timeout(const Duration(seconds: 3));
  });

  for (final version in ['2', '3']) {
    test('PS1 handoff invite version $version prompts for a compatible BIOS before joining', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      const host = '12345678-1234-4234-8234-123456789ab1';
      const roomId = '12345678-1234-4234-8234-123456789abc';
      const protocol = RetroOnlineMode.synchronized;
      final invite = GameInvite(
        sessionId: roomId,
        titleId: 'SCUS94426',
        gameVersion: version,
        engineBuild: 'anyps5-ps1-netplay-v1',
      );
      server.answers['GET game-sessions/$roomId'] = (
        200,
        {
          'id': roomId,
          'host': {'userId': host},
          'kind': 'online',
          'titleId': invite.titleId,
          'gameVersion': invite.gameVersion,
          'engineBuild': protocol.protocol,
          'capacity': 2,
          'joinable': false,
          'properties': {'protocol': protocol.protocol, 'discSha256': 'a' * 64},
        },
      );

      var chosen = Completer<String?>();
      var picking = Completer<void>();
      final fixture = makeFixture(
        together: server.base,
        system: HostSystem.windows,
        environment: {'ANYPS5_PS1_NETPLAY': '1'},
        pickFile: (label, extensions) {
          expect(label, contains('SCPH-1001'));
          expect(extensions, contains('bin'));
          picking.complete();
          return chosen.future;
        },
      );
      final model = fixture.model;
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      await signIn(model.together);

      final folder = fixture.temp.path;
      final cue = File(p.join(folder, 'game.cue'))..createSync();
      model.games.add(
        Game(
          folder: folder,
          titleId: 'PS1-fixture',
          name: 'CTR fixture',
          names: const {},
          defaultLanguage: 'en',
          version: '',
          executable: ExecutableKind.disc,
          retro: (platform: RetroPlatform.ps1, path: cue.path),
          retroSerial: invite.titleId,
        ),
      );
      final incompatible = Uint8List(512 * 1024)..[0] = 3;
      final offline = File(p.join(folder, 'offline.bin'))..writeAsBytesSync(incompatible);
      model.preferences.retroBiosSources['ps1'] = offline.path;

      var joining = model.together.joinPs1Netplay(invite);
      await picking.future.timeout(const Duration(seconds: 5));
      chosen.complete(offline.path);
      await joining;
      expect(model.toast, contains('matching SCPH-1001'));

      chosen = Completer<String?>();
      picking = Completer<void>();
      joining = model.together.joinPs1Netplay(invite);
      await picking.future.timeout(const Duration(seconds: 5));
      chosen.complete(null);
      await joining;

      chosen = Completer<String?>();
      picking = Completer<void>();
      joining = model.together.joinPs1Netplay(invite);
      await picking.future.timeout(const Duration(seconds: 5));
      await model.together.signOut();
      final signedOutNotice = model.toast;
      chosen.complete(offline.path);
      await joining;
      expect(model.toast, signedOutNotice);

      expect(server.callsTo('game-sessions/$roomId/join'), isEmpty);
      expect(model.running, isNull);
      expect(model.preferences.retroBiosSources['ps1'], offline.path);
      expect(offline.readAsBytesSync(), incompatible);
      expect(
        File(p.join(p.dirname(model.paths.toolkits), 'Emulators', 'PS1-Netplay', 'scph1001.bin')).existsSync(),
        isFalse,
      );
    }, skip: Abi.current() != Abi.windowsX64);
  }

  final ordinaryFixture = Platform.environment['ANYPS5_TEST_PS1_ORDINARY_FIXTURE'];
  test('ordinary PS1 capture sends the native source token, texture and verified disc digest', () async {
    final [String packages, String disc, String bios] = jsonDecode(await File(ordinaryFixture!).readAsString()) as List;
    final root = await Directory.systemTemp.createTemp('anyps5-source-capture-');
    addTearDown(() => root.delete(recursive: true));
    const execution = Ps1NetplayExecution.ordinaryHandoff;
    final core = await ManagedRetro(root.path, packageDirectory: packages).ensurePs1NetplayCore(execution: execution);
    final media = await Ps1NetplayMedia.verify(
      profile: Ps1NetplayProfile.tryRead('SCUS94426')!,
      disc: disc,
      bios: bios,
      core: core,
      execution: execution,
    );
    const channel = MethodChannel('anyps5/retro_core');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bytes = Uint8List.fromList([1, 2, 3]);
    var ended = false;
    var captures = 0;
    final resultRequested = Completer<void>();
    final delayedResult = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          return 41;
        case 'status':
          return {
            'ended': ended,
            'startupVisible': true,
            'localBlankCardCheckpoint': 17,
            'options': {
              'swanstation_CPU_ExecutionMode': {
                'values': ['Recompiler'],
                'selected': 0,
                'activeValue': 'Recompiler',
              },
            },
          };
        case 'ps1LocalCheckpointExport':
          captures++;
          expect(call.arguments['texture'], 41);
          expect(call.arguments['source'], 17);
          final digest = (call.arguments['discHash'] as Uint8List).map(
            (byte) => byte.toRadixString(16).padLeft(2, '0'),
          );
          expect(digest.join(), media.discDigest);
          return 51;
        case 'ps1CheckpointResult':
          expect(call.arguments, 51);
          if (captures == 2) {
            resultRequested.complete();
            return delayedResult.future;
          }
          return {'frame': 616, 'state': bytes};
        case 'stop':
          ended = true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final source = await EmbeddedRetroGame.start(
      p.dirname(core),
      (platform: RetroPlatform.ps1, path: disc),
      internalResolution: null,
      graphics: const {},
      onResolutionSelected: (_) {},
      onGraphicsSelected: (_, _) {},
      readPad: () => PadState.idle,
      changed: () {},
    );
    addTearDown(() async {
      await source.close();
      await source.exitCode;
    });
    expect(await source.ready, isTrue);
    final checkpoint = await source.captureOrdinaryNetplayCheckpoint(media);
    expect(checkpoint.frame, 616);
    expect(checkpoint.state, bytes);
    expect(captures, 1);
    final lateCapture = expectLater(source.captureOrdinaryNetplayCheckpoint(media), throwsStateError);
    await resultRequested.future.timeout(const Duration(seconds: 5));
    await source.close();
    delayedResult.complete({'frame': 617, 'state': bytes});
    await lateCapture;
    await expectLater(source.captureOrdinaryNetplayCheckpoint(media), throwsStateError);
    expect(captures, 2);
  }, skip: Abi.current() != Abi.windowsX64 || ordinaryFixture == null);

  test('ordinary PS1 invite installs the right core and continues the original invite', () async {
    final [String packages, String disc, String bios] = jsonDecode(await File(ordinaryFixture!).readAsString()) as List;
    final server = await FakeTogether.start();
    addTearDown(server.close);
    const invite = GameInvite(
      sessionId: '12345678-1234-4234-8234-123456789abc',
      titleId: 'SCUS94426',
      gameVersion: '3',
      engineBuild: 'anyps5-ps1-netplay-v1',
    );
    final path = 'game-sessions/${invite.sessionId}';
    server.answers['GET me/game-session'] = (200, {'session': null});
    server.answers['GET $path'] = (
      200,
      {
        'id': invite.sessionId,
        'host': {'userId': '12345678-1234-4234-8234-123456789ab1'},
        'kind': 'online',
        'titleId': invite.titleId,
        'gameVersion': invite.gameVersion,
        'engineBuild': invite.engineBuild,
        'capacity': 2,
        'joinable': false,
        'properties': {'protocol': invite.engineBuild, 'discSha256': await Ps1NetplayMedia.cueDigest(disc)},
      },
    );
    server.answers['POST $path/join'] = (409, {'error': 'fixture refused admission'});
    final fixture = makeFixture(
      together: server.base,
      system: HostSystem.windows,
      environment: {'ANYPS5_PS1_NETPLAY': '1', 'ANYPS5_MANAGED_CORE_PACKAGES': packages},
      pickFile: (_, _) async => bios,
    );
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    await signIn(model.together);
    model.games.add(
      Game(
        folder: p.dirname(disc),
        titleId: 'PS1-fixture',
        name: 'CTR fixture',
        names: const {},
        defaultLanguage: 'en',
        version: '',
        executable: ExecutableKind.disc,
        retro: (platform: RetroPlatform.ps1, path: disc),
        retroSerial: invite.titleId,
      ),
    );
    await model.together.joinPs1Netplay(invite);
    final join = server.callsTo('$path/join').single;
    expect(join.body, {'gameVersion': '3', 'engineBuild': invite.engineBuild});
    final home = p.join(p.dirname(model.paths.toolkits), 'Emulators');
    expect(File(p.join(home, 'PS1-Netplay-Ordinary', 'swanstation_libretro.dll')).existsSync(), isTrue);
    expect(File(p.join(home, 'PS1-Netplay', 'swanstation_libretro.dll')).existsSync(), isFalse);
    expect(model.running, isNull);
  }, skip: Abi.current() != Abi.windowsX64 || ordinaryFixture == null);
}

class _FixtureMatch implements Ps1NetplayRunner {
  _FixtureMatch(this.events);
  final List<String> events;

  @override
  Future<void> prepare(int seat) async => events.add('prepare $seat');

  @override
  Future<void> start() async => events.add('start');

  @override
  Future<void> stop() async => events.add('stop');

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async => throw UnimplementedError();
}

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<void> signIn(TogetherModel together) async {
  together.email = 'fixture@example.invalid';
  await together.sendCode();
  together.code = '123456';
  await together.verify();
  await Future.doWhile(() async {
    if (together.hub.socket.status.name == 'ready') return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return true;
  }).timeout(const Duration(seconds: 5));
}
