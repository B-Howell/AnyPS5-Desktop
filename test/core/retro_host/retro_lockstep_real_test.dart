import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/ps1_lockstep_match.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../online/lockstep_test_support.dart';

/// The launcher's own client in lockstep with two real emulator hosts running SwanStation, as two
/// players' launchers drive them (anyps5-retro-host docs/protocol.md "Lockstep"): both start in
/// lockstep and are given the same steps, and their main RAM must match after every frame; one
/// then saves its state, which the other, after running on its own, loads and catches up with.
///
/// Then two launchers' matches ([Ps1LockstepMatch]) play one through a link that loses, delays and
/// reorders input: the host player's game runs on its own, is held, and its state goes to the
/// friend's freshly started one, and both run on in lockstep with their RAM compared.
///
/// ANYPS5_RETRO_HOST_REAL names the same JSON file as retro_host_real_test.dart's, for a host with
/// the `ps1Lockstep` capability. Without it the test is skipped.
void main() {
  final configPath = Platform.environment['ANYPS5_RETRO_HOST_REAL'];
  if (configPath == null || configPath.isEmpty) {
    test('two real hosts in lockstep', () {}, skip: 'ANYPS5_RETRO_HOST_REAL is not set');
    return;
  }
  test('two real hosts in lockstep', () async {
    final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
    String path(String key) => File(config[key]! as String).absolute.path;
    final work = Directory.systemTemp.createTempSync('retro-lockstep-real-');
    final clients = <RetroHostClient>[];
    try {
      final system = Directory(p.join(work.path, 'system'))..createSync();
      File(path('bios')).copySync(p.join(system.path, 'openbios.bin'));
      String disc(String player) {
        final folder = Directory(p.join(work.path, '$player-disc'))..createSync();
        final cue = p.join(folder.path, 'program.cue');
        final built = Process.runSync(_python(), [path('discBuilder'), path('program'), cue]);
        expect(built.exitCode, 0, reason: 'make_test_disc.py: ${built.stderr}');
        return cue;
      }

      Map<String, Object?> start(String player, {required bool lockstep}) => {
        'core': path('core'),
        'system': system.path,
        'saves': p.join(work.path, 'saves-$player'),
        'disc': p.join(work.path, '$player-disc', 'program.cue'),
        'options': {
          'swanstation_BIOS_PathNTSCU': 'openbios.bin',
          'swanstation_BIOS_PathNTSCJ': 'openbios.bin',
          'swanstation_BIOS_PathPAL': 'openbios.bin',
          'swanstation_GPU_ResolutionScale': '1',
          'swanstation_Controller_AnalogCombo': '3',
        },
        if (lockstep) 'lockstep': const RetroLockstepSettings(check: 1, paced: false).toArgs(),
      };

      disc('host');
      disc('guest');
      for (var index = 0; index < 2; index++) {
        final client = RetroHostClient.start(
          command: [path('host')],
          environment: (config['environment'] as Map<String, Object?>?)?.cast<String, String>(),
          volume: 0,
          muted: true,
        );
        clients.add(client);
        await client.ready;
        expect(client.canLockstep, isTrue, reason: 'the host lists ps1Lockstep');
      }
      final [host, guest] = clients;
      final syncs = [<int, RetroSync>{}, <int, RetroSync>{}];
      for (final (index, client) in clients.indexed) {
        client.syncs.listen((sync) => syncs[index][sync.frame] = sync);
      }
      await host.startGame(start('host', lockstep: true));
      await guest.startGame(start('guest', lockstep: true));

      RetroStep input(int frame) {
        final buttons = (frame * 2654435761) & 0xFFFF & ~(1 << 2);
        return RetroStep(frame, [
          RetroPadInput(buttons: buttons, leftX: (frame * 977) % 65536 - 32768),
          RetroPadInput(buttons: buttons ^ 0x0F0F & ~(1 << 2)),
        ]);
      }

      Future<void> run(List<RetroHostClient> players, int first, int count) async {
        for (var frame = first; frame < first + count; frame++) {
          for (final client in players) {
            client.step(input(frame));
          }
          if (frame % 60 == 59) await _until(() => players.every((c) => syncs[clients.indexOf(c)].containsKey(frame)));
        }
        await _until(() => players.every((c) => syncs[clients.indexOf(c)].containsKey(first + count - 1)));
      }

      await run(clients, 0, 300);
      for (var frame = 0; frame < 300; frame++) {
        expect(syncs[1][frame]!.ram, syncs[0][frame]!.ram, reason: 'RAM after frame $frame');
        expect(syncs[1][frame]!.video, syncs[0][frame]!.video, reason: 'picture after frame $frame');
      }
      _report('cold boot: 300 frames alike in RAM and picture; last ${syncs[0][299]}');

      final state = p.join(work.path, 'match.state');
      final saved = await host.saveState(state);
      expect(saved, RetroStatePosition(frame: 300, bytes: File(state).lengthSync()));

      await guest.stopGame();
      expect(await guest.call('release'), isNull);
      await guest.startGame(start('guest', lockstep: false));
      await _until(() async => (await guest.status())?.ready ?? false, limit: const Duration(seconds: 60));
      expect(await guest.lockstep(const RetroLockstepSettings(check: 1, paced: false)), 0);
      expect(await guest.loadState(state), saved);
      syncs[1].clear();
      await run(clients, 300, 120);
      for (var frame = 300; frame < 420; frame++) {
        expect(syncs[1][frame]!.ram, syncs[0][frame]!.ram, reason: 'RAM after joined frame $frame');
      }
      _report('join: the guest loaded the state (${saved!.bytes} bytes) and matched for 120 frames');

      expect(await guest.leaveLockstep(), isTrue);
      expect(await host.leaveLockstep(), isTrue);
      for (final client in clients) {
        await client.stopGame();
        client.shutdown();
        expect(await client.ended, RetroHostEnd.clean, reason: client.failureReason);
      }
    } finally {
      for (final client in clients) {
        await client.close();
      }
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('two launchers play a match through a lossy link', () async {
    final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
    String path(String key) => File(config[key]! as String).absolute.path;
    final work = Directory.systemTemp.createTempSync('retro-lockstep-match-');
    final clients = <RetroHostClient>[];
    try {
      final system = Directory(p.join(work.path, 'system'))..createSync();
      File(path('bios')).copySync(p.join(system.path, 'openbios.bin'));
      String disc(String player) {
        final cue = p.join((Directory(p.join(work.path, '$player-disc'))..createSync()).path, 'program.cue');
        expect(Process.runSync(_python(), [path('discBuilder'), path('program'), cue]).exitCode, 0);
        return cue;
      }

      Future<RetroHostClient> open() async {
        final client = RetroHostClient.start(
          command: [path('host')],
          environment: (config['environment'] as Map<String, Object?>?)?.cast<String, String>(),
          volume: 0,
          muted: true,
        );
        clients.add(client);
        await client.ready;
        return client;
      }

      Future<void> ready(RetroHostClient client) =>
          _until(() async => (await client.status())?.ready ?? false, limit: const Duration(seconds: 60));

      const options = {
        'swanstation_BIOS_PathNTSCU': 'openbios.bin',
        'swanstation_BIOS_PathNTSCJ': 'openbios.bin',
        'swanstation_BIOS_PathPAL': 'openbios.bin',
        'swanstation_GPU_ResolutionScale': '1',
        'swanstation_Controller_AnalogCombo': '3',
      };
      final host = await open();
      await host.startGame({
        'core': path('core'),
        'system': system.path,
        'saves': p.join(work.path, 'saves-host'),
        'disc': disc('host'),
        'options': options,
      });
      await ready(host);
      await Future<void>.delayed(const Duration(seconds: 1));
      final guest = await open();
      final guestDisc = disc('guest');
      final identity = Ps1LockstepIdentity(
        hostVersion: host.hostVersion,
        system: 'linux',
        core: 'a' * 64,
        disc: 'b' * 64,
        discName: 'program.cue',
        bios: 'c' * 64,
      );
      final (a, b) = TestLink.pair(
        const Duration(milliseconds: 15),
        jitter: const Duration(milliseconds: 10),
        loss: 0.1,
      );
      var frame = 0;
      RetroPadInput pad(int salt) {
        frame++;
        return RetroPadInput(buttons: ((frame * 40503) ^ salt) & 0xFFFF & ~(1 << 2));
      }

      Map<String, String>? received;
      final hosting = Ps1LockstepMatch(
        hosting: true,
        link: a,
        identity: identity,
        work: Directory(p.join(work.path, 'match-host')),
        localInput: () => pad(1),
        paused: () => false,
        host: host,
        options: options,
      );
      final joining = Ps1LockstepMatch(
        hosting: false,
        link: b,
        identity: identity,
        work: Directory(p.join(work.path, 'match-guest')),
        localInput: () => pad(2),
        paused: () => false,
        prepareGuest: (hello) async {
          received = hello.options;
          await guest.startGame({
            'core': path('core'),
            'system': system.path,
            'saves': p.join(work.path, 'saves-guest'),
            'disc': guestDisc,
            'options': hello.options,
          });
          await ready(guest);
          return guest;
        },
      );
      unawaited(hosting.run());
      unawaited(joining.run());
      await _until(
        () => (hosting.lastMatched ?? -1) >= 600 && (joining.lastMatched ?? -1) >= 600 || hosting.end != null,
        limit: const Duration(seconds: 90),
      );
      expect(hosting.end, isNull, reason: 'the match ended: ${hosting.end} ${hosting.mismatch}');
      expect(received, options, reason: "the friend's game starts with the host player's options");
      _report(
        'match: delay ${hosting.delay} frames, round trip ${hosting.roundTripMs} ms, RAM matched up to frame '
        '${hosting.lastMatched} on both sides',
      );
      await hosting.leave();
      await joining.done;
      expect(joining.end, Ps1LockstepEnd.peerLeft);
      expect((await host.status())?.ended, isFalse, reason: "the host player's game goes on alone");
      for (final client in clients) {
        await client.stopGame();
        client.shutdown();
        expect(await client.ended, RetroHostEnd.clean, reason: client.failureReason);
      }
    } finally {
      for (final client in clients) {
        await client.close();
      }
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _until(FutureOr<bool> Function() done, {Duration limit = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(limit);
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('not done within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String _python() {
  final name = Platform.isWindows ? 'python' : 'python3';
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [name]);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('$name is not on PATH');
  return path.trim();
}

void _report(String line) => stdout.writeln(line);
