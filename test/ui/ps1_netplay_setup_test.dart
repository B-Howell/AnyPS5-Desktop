import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';
import 'package:anyps5_desktop/ui/ps1_netplay_runner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/online_fakes.dart' show FakeGameNetwork, eventually;
import '../support/ui_support.dart';

void main() {
  LoopbackTestBinding();
  test('game connection stats use the selected ICE pair and only report known values', () {
    final transport = StatsReport('transport', 'transport', 0, {'selectedCandidatePairId': 'chosen'});
    final pair = StatsReport('chosen', 'candidate-pair', 0, {
      'state': 'succeeded',
      'localCandidateId': 'local',
      'remoteCandidateId': 'remote',
      'currentRoundTripTime': '0.084',
    });
    final local = StatsReport('local', 'local-candidate', 0, {'candidateType': 'host'});
    final remote = StatsReport('remote', 'remote-candidate', 0, {'candidateType': 'relay'});
    expect(gameWebRtcPath([pair, local, remote]), isNull);
    expect(gameWebRtcPath([transport, pair, local, remote]), (relayed: true, roundTripMs: 84));
    expect(gameWebRtcPath([transport, pair, local]), (relayed: null, roundTripMs: 84));
    remote.values['candidateType'] = 'prflx';
    pair.values['currentRoundTripTime'] = 'NaN';
    expect(gameWebRtcPath([transport, pair, local, remote]), (relayed: false, roundTripMs: null));
  });
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
      final invite = GameInvite.fromJson({
        'sessionId': roomId,
        'titleId': 'SCUS94426',
        'gameVersion': version,
        'engineBuild': protocol.protocol,
        'from': server.person(host, 'ana', 'Ana'),
      });
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
      addTearDown(() {
        if (!chosen.isCompleted) chosen.complete(null);
      });
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

      final roomPath = 'game-sessions/$roomId';
      final roomAnswer = server.answers.remove('GET $roomPath')!;
      server.answers['GET $roomPath'] = (
        200,
        {
          ...(roomAnswer.$2 as Map<String, dynamic>),
          'host': {'userId': '12345678-1234-4234-8234-123456789abd'},
        },
      );
      final refused = model.together.joinPs1Netplay(invite);
      await Future.any([refused, picking.future]).timeout(const Duration(seconds: 5));
      expect(picking.isCompleted, isFalse);
      expect(model.toast, contains('host has changed'));
      await refused;
      server.answers.remove('GET $roomPath');
      final roomRequested = Completer<void>();
      final roomReply = Completer<void>();
      server.handlers.add((call) async {
        if (call.method != 'GET' || call.path != roomPath) return null;
        if (!roomRequested.isCompleted) roomRequested.complete();
        await roomReply.future;
        return roomAnswer;
      });
      addTearDown(() {
        if (!roomReply.isCompleted) roomReply.complete();
      });
      var joining = model.together.joinPs1Netplay(invite);
      await roomRequested.future.timeout(const Duration(seconds: 5));
      final stalled = model.together.gameRows().singleWhere((row) => row.id == 'ps1-netplay-cancel-verification');
      (stalled.kind as ActionRow).run();
      await joining.timeout(const Duration(seconds: 3));
      expect(picking.isCompleted, isFalse);

      server.answers['GET $roomPath'] = roomAnswer;
      joining = model.together.joinPs1Netplay(invite);
      await picking.future.timeout(const Duration(seconds: 5));
      roomReply.complete();
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
      final cancel = model.together.gameRows().singleWhere((row) => row.id == 'ps1-netplay-cancel-verification');
      (cancel.kind as ActionRow).run();
      final canceledNotice = model.toast;
      chosen.complete(offline.path);
      await joining;
      expect(model.toast, canceledNotice);

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

  final standardFixture = Platform.environment['ANYPS5_TEST_PS1_STANDARD_FIXTURE'];
  Future<void> verifyOrdinaryHandoff({
    required bool guestMode,
    Ps1NetplayRoomMode mode = Ps1NetplayRoomMode.ordinary,
  }) async {
    final [String packages, String disc, String bios] = jsonDecode(await File(ordinaryFixture!).readAsString()) as List;
    var packageDirectory = packages;
    String? stockCore;
    if (mode != Ps1NetplayRoomMode.ordinary) {
      final [String standardPackage, String stock] = jsonDecode(await File(standardFixture!).readAsString()) as List;
      stockCore = stock;
      final both = await Directory.systemTemp.createTemp('anyps5-ps1-invite-cores-');
      addTearDown(() => both.delete(recursive: true));
      for (final source in [p.join(packages, 'swanstation-netplay-ordinary.zip'), standardPackage]) {
        await File(source).copy(p.join(both.path, p.basename(source)));
      }
      packageDirectory = both.path;
    }
    const hostId = '12345678-1234-4234-8234-123456789ab1';
    const friendId = '12345678-1234-4234-8234-123456789ab2';
    const device = '12345678-1234-4234-8234-123456789ab3';
    const roomId = '12345678-1234-4234-8234-123456789abc';
    const path = 'game-sessions/$roomId';
    const titleId = 'SCUS94426';
    const protocol = RetroOnlineMode.synchronized;
    final network = FakeGameNetwork();
    final server = await FakeTogether.start();
    addTearDown(server.close);
    server
      ..me = {'id': guestMode ? friendId : hostId, 'handle': 'local', 'displayName': 'Local'}
      ..friend(guestMode ? hostId : friendId, 'remote', 'Remote', presence: {'state': 'online'});
    final fixture = makeFixture(
      together: server.base,
      system: HostSystem.windows,
      environment: {'ANYPS5_PS1_NETPLAY': '1', 'ANYPS5_MANAGED_CORE_PACKAGES': packageDirectory},
      gameLinks: () => network.links,
    );
    final model = fixture.model;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('anyps5/retro_core');
    Future<void>? localPlay;
    addTearDown(() async {
      try {
        if (model.together.ps1NetplayRows().singleOrNull?.kind case final ActionRow leave) {
          leave.run();
          expect(
            await eventually(() => model.together.ps1NetplayRows().isEmpty),
            isTrue,
            reason: 'Host room did not close',
          );
        }
        await model.embeddedGame?.close();
        await model.waitForRetroWorkerExit().timeout(const Duration(seconds: 5));
        await localPlay?.timeout(const Duration(seconds: 5));
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        model.dispose();
        fixture.dispose();
      }
    });
    final home = p.join(p.dirname(model.paths.toolkits), 'Emulators');
    final system = await Directory(p.join(home, 'system')).create(recursive: true);
    final localBios = await File(bios).copy(p.join(system.path, 'scph1001.bin'));
    final managed = ManagedRetro(home, packageDirectory: packageDirectory);
    final matchCore = switch (mode) {
      Ps1NetplayRoomMode.ordinary => await managed.ensurePs1NetplayCore(execution: mode.execution),
      Ps1NetplayRoomMode.staged => p.join(home, 'PS1-Netplay', ManagedRetro.libraryName(RetroPlatform.ps1)),
      Ps1NetplayRoomMode.fresh => (await File(
        stockCore!,
      ).copy(p.join(home, ManagedRetro.libraryName(RetroPlatform.ps1)))).path,
    };
    var hostCore = matchCore;
    if (mode == Ps1NetplayRoomMode.staged) {
      final hostHome = await Directory.systemTemp.createTemp('anyps5-ps1-staged-host-');
      addTearDown(() => hostHome.delete(recursive: true));
      hostCore = await ManagedRetro(hostHome.path, packageDirectory: packageDirectory).ensurePs1NetplayCore();
    }
    final game = Game(
      folder: p.dirname(disc),
      titleId: 'PS1-fixture',
      name: 'CTR fixture',
      names: const {},
      defaultLanguage: 'en',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: disc),
      retroSerial: titleId,
    );
    model.games.add(game);
    final native = <String>[];
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hostBytes = Uint8List.fromList([4, 5, 6]);
    var worker = 0;
    var ended = false;
    var recoveredPlaying = false;
    var matchPumped = false;
    final matchProgress = Stopwatch();
    final finishPark = Completer<void>();
    final finishRecovery = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          worker++;
          ended = false;
          final arguments = call.arguments as Map;
          if (worker == 1) {
            expect(arguments['ps1NetplaySeat'], isNull);
            expect(arguments['saves'], p.join(home, 'saves', 'ps1'));
            native.add('local');
          } else {
            expect(worker, 2);
            expect(arguments['ps1NetplaySeat'], guestMode ? 1 : 0);
            expect(arguments['ps1NetplayCpu'], mode == Ps1NetplayRoomMode.ordinary ? mode.execution.cpu : isNull);
            expect(arguments['saves'], Directory.systemTemp.path);
            expect(
              await File(arguments['core'] as String).resolveSymbolicLinks(),
              await File(matchCore).resolveSymbolicLinks(),
            );
            native.add('match');
          }
          return 40 + worker;
        case 'status':
          return {
            'ended': ended,
            'startupVisible': worker != 3 || recoveredPlaying,
            if (worker == 1) 'localBlankCardCheckpoint': 17,
            if (worker == 2) ...{'netplayReady': true, 'portableCheckpoint': true},
            if (worker == 3) 'ps1RecoveredSource': 17,
            'options': {
              'swanstation_CPU_ExecutionMode': {
                'values': ['Recompiler'],
                'selected': 0,
                'activeValue': 'Recompiler',
              },
            },
          };
        case 'ps1LocalCheckpointPark':
          expect(call.arguments['texture'], 41);
          native.add('park');
          return 51;
        case 'ps1CheckpointImport':
          expect(mode.needsCheckpoint, isTrue);
          expect(call.arguments['state'], guestMode ? hostBytes : bytes);
          expect(call.arguments['frame'], 0);
          native.add('import');
          return 52;
        case 'ps1CheckpointReplay':
          expect(mode, Ps1NetplayRoomMode.staged);
          expect(call.arguments, {
            'frame': 0,
            'frames': [
              [
                [0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0],
              ],
            ],
          });
          native.add('replay');
          return 53;
        case 'ps1CheckpointResult':
          if (call.arguments == 51) await finishPark.future;
          return call.arguments == 51 ? {'frame': 616, 'state': bytes} : true;
        case 'ps1LocalCheckpointDetach':
          native.add('detach');
          return 17;
        case 'netplayStart':
          native.add('start match');
          return true;
        case 'netplaySync':
          matchPumped = true;
          final frame = matchProgress.isRunning ? 1 + matchProgress.elapsedMilliseconds ~/ 100 : 0;
          return {
            'frame': frame,
            if (frame > 0) 'confirmedFrame': frame - 1,
            'waiting': frame == 0,
            'local': [],
            'fingerprints': [],
          };
        case 'ps1LocalCheckpointReopen':
          expect(call.arguments, 17);
          worker = 3;
          ended = false;
          native.add('reopen');
          await finishRecovery.future;
          return 43;
        case 'pause':
          if (worker == 3 && call.arguments == false) recoveredPlaying = true;
        case 'ps1LocalCheckpointAccept':
          expect(call.arguments, {'source': 17, 'texture': 43});
          native.add('accept');
          return true;
        case 'stop':
          native.add('stop $worker');
          ended = true;
        case 'release':
          native.add('release $worker');
      }
      return null;
    });
    await signIn(model.together);
    expect(await eventually(() => model.together.hub.friends.friends.isNotEmpty), isTrue);
    localPlay = model.play(game);
    expect(
      await eventually(() => model.embeddedGame?.canParkOrdinaryPs1 == true && model.starting == null),
      isTrue,
      reason: '${model.toast}, native: $native',
    );
    if (mode != Ps1NetplayRoomMode.ordinary) expect(p.equals(model.embeddedGame!.corePath, matchCore), isFalse);
    final media = await Ps1NetplayMedia.verify(
      profile: Ps1NetplayProfile.tryRead(titleId)!,
      disc: disc,
      bios: localBios.path,
      core: hostCore,
      execution: mode.execution,
    );
    final room = {
      'id': roomId,
      'host': {'userId': hostId},
      'kind': 'online',
      'titleId': titleId,
      'gameVersion': mode.version,
      'engineBuild': protocol.protocol,
      'capacity': 2,
      'joinable': false,
      'properties': {'protocol': protocol.protocol, 'discSha256': media.discDigest},
      'members': [
        {
          'userId': hostId,
          if (guestMode) 'device': device,
          if (guestMode) 'properties': {'protocol': protocol.protocol},
        },
        {
          'userId': friendId,
          if (!guestMode) 'device': device,
          if (!guestMode) 'properties': {'protocol': protocol.protocol},
        },
      ],
    };
    server.answers.addAll({
      'GET me/game-session': (200, {'session': null}),
      'POST game-sessions': (201, room),
      'PUT $path/members/me': (200, room),
      'POST $path/invites': (200, <String, Object>{}),
      'POST $path/join': (204, null),
      'POST $path/leave': (204, null),
      'GET $path': (200, room),
      'GET $path/ice-servers': (200, {'iceServers': []}),
      'DELETE $path': (200, <String, Object>{}),
    });
    PanelRow row(String id) =>
        model.panelCategories().expand((category) => category.rows).singleWhere((row) => row.id == id);
    void choose(String id) => (row(id).kind as ActionRow).run();

    if (guestMode) {
      server.gameInvites.add({
        'sessionId': roomId,
        'from': server.person(hostId, 'remote', 'Remote'),
        'titleId': titleId,
        'gameVersion': mode.version,
        'engineBuild': protocol.protocol,
      });
      server.answers['GET me/game-session'] = (200, {'session': null, 'invites': server.gameInvites});
      await model.together.hub.games.refresh();
      server.answers['GET $path'] = (
        200,
        {
          ...room,
          'properties': {'protocol': protocol.protocol, 'discSha256': 'f' * 64},
        },
      );
      await model.openQuickMenu();
      choose('game-accept-$roomId');
      expect(
        await eventually(
          () => model.toast == 'Your PS1 disc files differ. Both players need the same disc and revision.',
          timeout: const Duration(seconds: 25),
        ),
        isTrue,
      );
      expect(server.callsTo('$path/join'), isEmpty);
      expect(native, ['local']);
      server.answers['GET $path'] = (200, room);
      if (mode == Ps1NetplayRoomMode.fresh) {
        final held = await File(matchCore).rename('$matchCore.unavailable');
        await model.openQuickMenu();
        choose('game-accept-$roomId');
        expect(
          await eventually(
            () => model.toast == 'Install the supported SwanStation core in PS1 Setup.',
            timeout: const Duration(seconds: 25),
          ),
          isTrue,
        );
        expect(server.callsTo('$path/join'), isEmpty);
        expect(native, ['local']);
        await held.rename(matchCore);
      }
      await model.openQuickMenu();
      choose('game-accept-$roomId');
      expect(
        await eventually(() => server.callsTo('$path/join').isNotEmpty, timeout: const Duration(seconds: 25)),
        isTrue,
      );
      final host = Ps1NetplayPeer(
        link: await network.links.link([]),
        identity: media.identity,
        runner: _FixtureMatch([]),
        seat: 0,
        hostEpoch: 17,
        captureCheckpoint: mode.needsCheckpoint ? () async => (frame: 0, state: hostBytes) : null,
        catchupSource: mode == Ps1NetplayRoomMode.staged
            ? (
                hold: () async => 1,
                read: (_) async {
                  const neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);
                  return (nextFrame: 1, frames: [(neutral, neutral)]);
                },
              )
            : null,
        sendSignal: (signal) async => server.push('game_session.signal', {
          'sessionId': roomId,
          'from': hostId,
          'device': device,
          'kind': 'message',
          'data': signal.toJson(),
        }),
      );
      addTearDown(host.leave);
      finishPark.complete();
      finishRecovery.complete();
      await host.open();
      final answer = await server.nextFrame('signal', test: (frame) => (frame['data'] as Map)['kind'] == 'answer');
      host.receiveSignal(Ps1NetplaySignal.tryRead(answer['data'])!);
      expect(await eventually(() => matchPumped), isTrue, reason: 'Guest did not start: $native, ${model.toast}');
      expect(native, [
        'local',
        'park',
        'detach',
        'match',
        if (mode.needsCheckpoint) 'import',
        if (mode == Ps1NetplayRoomMode.staged) 'replay',
        'start match',
      ]);
      await model.openQuickMenu();
      choose('ps1-netplay-leave');
      expect(await eventually(() => model.together.ps1NetplayRows().isEmpty), isTrue);
      expect(server.callsTo('$path/leave'), hasLength(1));
      expect(model.embeddedGame?.textureId, 43);
      expect(native.where((event) => event == 'accept'), hasLength(1));
      expect(model.running?.$1, same(game));
      return;
    }

    await model.openQuickMenu();
    choose('ps1-invite-from-game');
    expect(model.overlay, Layer.retroOnlineFriends);
    choose('ps1-invite-$friendId');
    expect(model.overlay, isNull);
    await model.openQuickMenu();
    expect(row('ps1-netplay-cancel-verification').detail, contains('Verifying your PS1 game'));
    choose('ps1-netplay-cancel-verification');
    expect(
      await eventually(() => model.together.ps1QuickRows().any((row) => row.id == 'ps1-invite-from-game')),
      isTrue,
    );
    expect(server.callsTo('game-sessions', method: 'POST'), isEmpty);
    expect(native, ['local']);
    expect(model.overlay, Layer.quickMenu);
    server.answers['GET $path'] = (
      200,
      {
        ...room,
        'members': [
          {'userId': hostId},
        ],
      },
    );
    choose('ps1-invite-from-game');
    choose('ps1-invite-$friendId');
    expect(
      await eventually(() => server.callsTo('$path/invites').isNotEmpty, timeout: const Duration(seconds: 25)),
      isTrue,
    );
    expect(server.callsTo('game-sessions', method: 'POST').single.body['gameVersion'], '3');
    expect(server.callsTo('$path/invites').single.body['userIds'], [friendId]);
    await model.openQuickMenu();
    expect(row('ps1-netplay-leave').detail, 'Waiting for the other player');
    server.answers['GET $path'] = (200, room);
    Future<Map<String, dynamic>> nextOffer() =>
        server.nextFrame('signal', test: (frame) => (frame['data'] as Map)['kind'] == 'offer');
    final offer = await nextOffer();
    expect(native, ['local']);
    expect(row('ps1-netplay-leave').detail, 'Connecting to the other player');
    choose('resume');
    Future<Ps1NetplayPeer> connectGuest(
      Map<String, dynamic> offer,
      Ps1NetplayIdentity identity, {
      void Function()? onRunning,
    }) async {
      final guest = Ps1NetplayPeer(
        link: await network.links.link([]),
        identity: identity,
        runner: _FixtureMatch([]),
        seat: 1,
        sendSignal: (signal) async => server.push('game_session.signal', {
          'sessionId': roomId,
          'from': friendId,
          'device': device,
          'kind': 'message',
          'data': signal.toJson(),
        }),
        restoreCheckpoint: (snapshot) async {
          expect(snapshot.frame, 0);
          expect(snapshot.state, bytes);
        },
        onRunning: onRunning,
      );
      addTearDown(guest.leave);
      await guest.open();
      guest.receiveSignal(Ps1NetplaySignal.tryRead(offer['data'])!);
      return guest;
    }

    final incompatible = Ps1NetplayIdentity.tryRead({...media.identity.toJson(), 'disc': 'f' * 64})!;
    final rejected = await connectGuest(offer, incompatible);
    await rejected.done.timeout(const Duration(seconds: 5));
    expect(rejected.session.mismatch, Ps1NetplayMismatch.disc);
    expect(
      await eventually(() => model.together.ps1QuickRows().any((row) => row.id == 'ps1-invite-from-game')),
      isTrue,
    );
    expect(model.toast, 'Your PS1 disc files differ. Both players need the same disc and revision.');
    expect(server.callsTo(path, method: 'DELETE'), hasLength(1));
    expect(native, ['local']);
    await model.openQuickMenu();
    choose('ps1-invite-from-game');
    choose('ps1-invite-$friendId');
    expect(
      await eventually(() => server.callsTo('$path/invites').length == 2, timeout: const Duration(seconds: 25)),
      isTrue,
    );
    final guestStarted = Completer<void>();
    final guest = await connectGuest(await nextOffer(), media.identity, onRunning: guestStarted.complete);
    addTearDown(() {
      if (!finishPark.isCompleted) finishPark.complete();
      if (!finishRecovery.isCompleted) finishRecovery.complete();
    });
    expect(await eventually(() => native.contains('park')), isTrue);
    await model.openQuickMenu();
    expect(row('ps1-netplay-leave').detail, 'Preparing both games');
    choose('resume');
    finishPark.complete();
    await guestStarted.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('Guest did not start: ${guest.session.phase}, ${guest.session.ended}. Host calls: $native'),
    );
    expect(await eventually(() => matchPumped), isTrue);
    expect(native, ['local', 'park', 'detach', 'match', 'import', 'start match']);
    await model.openQuickMenu();
    expect(await eventually(() => row('ps1-netplay-leave').detail == 'Waiting for the games to sync'), isTrue);
    expect(model.together.ps1ProgressStalled, isTrue);
    matchProgress.start();
    expect(await eventually(() => row('ps1-netplay-leave').detail == 'Match in progress'), isTrue);
    expect(model.together.ps1ProgressStalled, isFalse);
    network.readPath = () async => (relayed: true, roundTripMs: 84);
    expect(
      await eventually(() => row('ps1-netplay-leave').detail == 'Match in progress · Through the relay · 84 ms'),
      isTrue,
    );
    choose('ps1-netplay-leave');
    expect(await eventually(() => native.contains('reopen')), isTrue);
    expect(model.starting, same(game));
    model.padCommand(PadCommand.home);
    expect(model.overlay, Layer.quickMenu);
    final returning = row('ps1-netplay-ending');
    expect(returning.title, 'Ending online play');
    expect(returning.focusable, isFalse);
    choose('resume');
    finishRecovery.complete();
    expect(await eventually(() => server.callsTo(path, method: 'DELETE').length == 2), isTrue);
    expect(native, [
      'local',
      'park',
      'detach',
      'match',
      'import',
      'start match',
      'stop 2',
      'release 2',
      'reopen',
      'accept',
    ]);
    expect(model.embeddedGame?.textureId, 43);
    expect(model.running?.$1, same(game));
    expect(model.ordinaryPs1RecoveryPending, isFalse);
    expect(model.overlay, isNull);
    await guest.done.timeout(const Duration(seconds: 5));
    expect(guest.session.phase, Ps1NetplayPhase.closed);
    expect(guest.session.ended, Ps1NetplayEnd.peerLeft);
  }

  const handoffFixtureTimeout = Timeout(Duration(seconds: 90));
  test(
    'Quick Menu starts an ordinary host match and returns to the original session',
    () => verifyOrdinaryHandoff(guestMode: false),
    skip: Abi.current() != Abi.windowsX64 || ordinaryFixture == null,
    timeout: handoffFixtureTimeout,
  );
  test(
    'Quick Menu joins an ordinary PS1 invite and returns to the original session',
    () => verifyOrdinaryHandoff(guestMode: true),
    skip: Abi.current() != Abi.windowsX64 || ordinaryFixture == null,
    timeout: handoffFixtureTimeout,
  );
  for (final mode in [Ps1NetplayRoomMode.fresh, Ps1NetplayRoomMode.staged]) {
    test(
      'Quick Menu joins a ${mode.name} PS1 invite and returns to the original session',
      () => verifyOrdinaryHandoff(guestMode: true, mode: mode),
      skip: Abi.current() != Abi.windowsX64 || ordinaryFixture == null || standardFixture == null,
      timeout: handoffFixtureTimeout,
    );
  }

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
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async => (
    frame: 0,
    confirmedFrame: null,
    receivedFrame: null,
    waiting: true,
    local: <Ps1NetplayFrame>[],
    fingerprints: <int, String>{},
  );
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
