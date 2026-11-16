import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:test/test.dart';

import '../online/lockstep_test_support.dart';

/// `status.core` and `status.timing` (capabilities `coreIdentity` and `gameTiming`) as real hosts
/// sent them: test/fixtures/retro_host/core_identity_swanstation.json and
/// test/fixtures/retro_host/game_timing_swanstation.json, each from the Windows and the Linux
/// release packages of netplay-design 67aec4e.
void main() {
  Map<String, Object?> recording(String system) =>
      (jsonDecode(File('test/fixtures/retro_host/game_timing_swanstation.json').readAsStringSync())
              as Map<String, Object?>)[system]!
          as Map<String, Object?>;

  Map<String, Object?> result(String system, String game, String when) {
    final replies = (recording(system)['replies']! as List<Object?>).cast<Map<String, Object?>>();
    final reply = replies.firstWhere((reply) => reply['game'] == game && reply['when'] == when);
    return (jsonDecode(reply['reply']! as String) as Map<String, Object?>)['result']! as Map<String, Object?>;
  }

  RetroStatus status(String system, String game, String when) =>
      RetroStatus.parse(result(system, game, when), coreIdentity: true, gameTiming: true);

  test('both hosts list coreIdentity, gameTiming and syncXxh3', () {
    for (final system in ['windows', 'linux']) {
      for (final file in [recording(system), recordedCoreIdentity(system)]) {
        final welcome = jsonDecode(file['welcome']! as String) as Map<String, Object?>;
        expect(welcome['capabilities'], contains(retroCapabilityCoreIdentity), reason: system);
      }
      final welcome = jsonDecode(recording(system)['welcome']! as String) as Map<String, Object?>;
      expect(welcome['capabilities'], contains(retroCapabilityGameTiming), reason: system);
      expect(welcome['capabilities'], contains(retroCapabilitySyncXxh3), reason: system);
    }
  });

  test("a game's frame rate is its video mode's, the same on Windows and Linux", () {
    for (final system in ['windows', 'linux']) {
      expect(status(system, 'hello', 'first').timing, isNull, reason: 'no game is loaded yet');
      final ntsc = status(system, 'hello', 'ready').timing!;
      expect(ntsc.region, 'ntsc');
      expect(ntsc.fps, closeTo(59.817, 0.001));
      expect(status(system, 'hello', 'running').timing, ntsc);
      final pal = status(system, 'palCorner', 'running').timing!;
      expect(pal.region, 'pal');
      expect(pal.fps, closeTo(49.747, 0.001));
      expect(pal.frame.inMicroseconds, closeTo(20102, 1));
      expect(status(system, 'palCorner', 'running').core, status(system, 'hello', 'ready').core);
    }
    expect(status('windows', 'palCorner', 'running').timing, status('linux', 'palCorner', 'running').timing);
    expect(status('windows', 'hello', 'ready').core, status('linux', 'hello', 'ready').core);
  });

  test('without the capabilities their fields are not read', () {
    final plain = RetroStatus.parse(result('windows', 'hello', 'ready'));
    expect(plain.core, isNull);
    expect(plain.timing, isNull);
  });

  test('a host that lists the capabilities must send the fields as protocol.md says', () {
    final ready = result('windows', 'palCorner', 'ready');
    final timing = ready['timing']! as Map<String, Object?>;
    final core = ready['core']! as Map<String, Object?>;
    for (final (field, value) in [
      ('timing', {...timing, 'fps': 1}),
      ('timing', {...timing, 'fps': 1000}),
      ('timing', {...timing, 'fps': '50'}),
      ('timing', {...timing, 'region': 'secam'}),
      ('timing', {'fps': timing['fps']}),
      ('core', {...core, 'version': 'x' * 257}),
      ('core', {...core, 'name': 'Swan\u0007Station'}),
      ('core', {'name': core['name']}),
    ]) {
      expect(
        () => RetroStatus.parse({...ready, field: value}, coreIdentity: true, gameTiming: true),
        throwsA(isA<RetroProtocolError>()),
        reason: '$field $value',
      );
    }
    for (final field in ['timing', 'core']) {
      expect(
        () => RetroStatus.parse({...ready}..remove(field), coreIdentity: true, gameTiming: true),
        throwsA(isA<RetroProtocolError>()),
        reason: 'a missing $field',
      );
    }
    expect(RetroStatus.parse({...ready, 'timing': null}, gameTiming: true).timing, isNull);
    expect(
      RetroStatus.parse({
        ...ready,
        'timing': {...timing, 'region': ''},
      }, gameTiming: true).timing!.region,
      '',
    );
  });
}
