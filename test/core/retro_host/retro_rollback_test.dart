import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:anyps5_desktop/core/retro_host/strict_json.dart';
import 'package:test/test.dart';

/// Rollback's messages as the client reads them, replayed from what real hosts sent
/// (test/fixtures/retro_host/rollback_swanstation.json, which says how it was recorded): on
/// Windows and on Linux, two players' SwanStation hosts in rollback, each stepped with the other
/// player's port null while that input had not come and corrected when it came, and a reference
/// host in plain lockstep given every frame's input, every lockstep leaving the state out of its
/// checks as the launcher asks. Each player's messages are replayed through [RetroLockstepTracker]
/// in the order they were sent and read, so every rule it holds the host and the launcher to is
/// checked against the real thing.
void main() {
  final fixture =
      jsonDecode(File('test/fixtures/retro_host/rollback_swanstation.json').readAsStringSync()) as Map<String, Object?>;
  const systems = ['windows', 'linux'];
  Map<String, Object?> recording(String system) => fixture[system]! as Map<String, Object?>;
  Map<String, List<Map<String, Object?>>> playersOf(String system) =>
      (recording(system)['players']! as Map<String, Object?>).map(
        (name, log) => MapEntry(name, (log! as List<Object?>).cast<Map<String, Object?>>()),
      );
  List<String> referenceOf(String system) => (recording(system)['reference']! as List<Object?>).cast<String>();

  Map<String, Object?> decode(String raw) => StrictJson.decodeObject(Uint8List.fromList(utf8.encode(raw)));

  /// One player's log replayed: the tracker given every step, correction, sync and rollback.
  ({List<RetroSync> syncs, List<RetroRollback> rollbacks, int predicted, int corrected, RetroLockstepTracker tracker})
  replay(List<Map<String, Object?>> log) {
    final tracker = RetroLockstepTracker();
    final syncs = <RetroSync>[];
    final rollbacks = <RetroRollback>[];
    var predicted = 0;
    var corrected = 0;
    for (final entry in log) {
      final sent = entry['sent'] as String?;
      if (sent != null) {
        final message = decode(sent);
        switch (message['type']) {
          case 'call' when message['method'] == 'start':
            final args = message['args']! as Map<String, Object?>;
            tracker.started(lockstep: true, rollback: RetroLockstepSettings.rollbackOf(args['lockstep']));
          case 'step':
            final step = RetroStep.parse(message);
            expect(step.toMessage(), message, reason: 'the launcher writes a step as the harness did');
            tracker.sending(step);
            if (step.ports.contains(null)) predicted++;
          case 'correct':
            final correct = RetroCorrect.parse(message);
            expect(correct.toMessage(), message, reason: 'the launcher writes a correction as the harness did');
            tracker.correcting(correct);
            corrected++;
        }
        continue;
      }
      final message = decode(entry['got']! as String);
      switch (message['type']) {
        case 'welcome':
          expect(
            RetroFields(message, 'welcome').strings('capabilities'),
            containsAll([retroCapabilityPs1Rollback, retroCapabilitySyncXxh3]),
          );
        case 'sync':
          syncs.add(tracker.synced(message));
        case 'rollback':
          rollbacks.add(tracker.rolledBack(message));
      }
    }
    return (syncs: syncs, rollbacks: rollbacks, predicted: predicted, corrected: corrected, tracker: tracker);
  }

  test('the recorded hosts play in rollback with a window of 8, leaving the state out of their checks', () {
    for (final system in systems) {
      final players = playersOf(system);
      for (final player in players.keys) {
        final start = players[player]!
            .where((entry) => entry['sent'] != null)
            .map((entry) => decode(entry['sent']! as String))
            .firstWhere((message) => message['method'] == 'start');
        final lockstep = (start['args']! as Map<String, Object?>)['lockstep'];
        expect(RetroLockstepSettings.rollbackOf(lockstep), 8);
        expect(RetroLockstepSettings.setsState(lockstep), isTrue);
        expect(lockstep, const RetroLockstepSettings(check: 1, paced: false, state: false, rollback: 8).toArgs());
      }
    }
  });

  test("each player's steps, corrections, syncs and rollbacks keep rollback's rules, and reach lockstep's frames", () {
    for (final system in systems) {
      final players = playersOf(system);
      final expected = [for (final raw in referenceOf(system)) RetroSync.parse(decode(raw))];
      for (final player in players.keys) {
        final played = replay(players[player]!);
        final name = '$system $player';
        expect(played.predicted, greaterThan(20), reason: '$name: late input was stepped null');
        expect(played.corrected, played.predicted, reason: '$name: every predicted frame was corrected');
        expect(played.rollbacks, isNotEmpty, reason: '$name: wrong guesses were run again');
        for (final rollback in played.rollbacks) {
          expect(rollback.frames, inInclusiveRange(1, 8));
          expect(rollback.loadMicros, lessThanOrEqualTo(rollback.micros));
        }
        expect(
          [for (final sync in played.syncs) sync.frame],
          [for (var frame = 0; frame < expected.length; frame++) frame],
        );
        for (final (frame, sync) in played.syncs.indexed) {
          expect(sync.ram, expected[frame].ram, reason: '$name: RAM of confirmed frame $frame against lockstep');
          expect(sync.video, expected[frame].video, reason: '$name: picture of frame $frame');
          expect(sync.state, isNull, reason: '$name: lockstep.state false leaves the state out of frame $frame');
        }
        expect(played.tracker.confirmed, expected.length - 1, reason: '$name: every frame ended confirmed');
      }
    }
  });

  test('the same input gives the same RAM hashes on Windows and on Linux', () {
    final windows = [for (final raw in referenceOf('windows')) RetroSync.parse(decode(raw))];
    final linux = [for (final raw in referenceOf('linux')) RetroSync.parse(decode(raw))];
    expect(windows, hasLength(180));
    expect([for (final sync in linux) sync.ram], [for (final sync in windows) sync.ram]);
    expect({for (final sync in windows) sync.ram}.length, greaterThan(20), reason: 'the RAM changes as the game runs');
  });

  test('a sync before its frame is confirmed, or a rollback of frames not stepped, is a protocol error', () {
    final log = playersOf('windows')['player1']!;
    final tracker = RetroLockstepTracker()..started(lockstep: true, rollback: 8);
    final steps = [
      for (final entry in log)
        if (entry['sent'] case final String sent when decode(sent)['type'] == 'step') RetroStep.parse(decode(sent)),
    ];
    final firstNull = steps.indexWhere((step) => step.ports.contains(null));
    expect(firstNull, isNonNegative);
    for (final step in steps.take(firstNull + 1)) {
      tracker.sending(step);
    }
    final syncs = [
      for (final entry in log)
        if (entry['got'] case final String got when decode(got)['type'] == 'sync') decode(got),
    ];
    for (final sync in syncs.take(firstNull)) {
      tracker.synced(sync);
    }
    expect(tracker.confirmed, firstNull == 0 ? isNull : firstNull - 1);
    expect(
      () => tracker.synced(syncs[firstNull]),
      throwsA(isA<RetroProtocolError>()),
      reason: 'the frame stepped null is not confirmed before its correction',
    );
    final rollback = log
        .map((entry) => entry['got'])
        .whereType<String>()
        .map(decode)
        .firstWhere((message) => message['type'] == 'rollback');
    expect(
      () => tracker.rolledBack({...rollback, 'frame': firstNull + 1, 'frames': 8}),
      throwsA(isA<RetroProtocolError>()),
    );
    final plain = RetroLockstepTracker()..started(lockstep: true);
    expect(() => plain.rolledBack(rollback), throwsA(isA<RetroProtocolError>()), reason: 'not in rollback');
  });

  test('the launcher is held to the order of steps and corrections', () {
    const known = RetroPadInput(buttons: 1);
    final plain = RetroLockstepTracker()..started(lockstep: true);
    expect(() => plain.sending(RetroStep(0, const [known, null])), throwsStateError, reason: 'null outside rollback');
    expect(() => plain.correcting(RetroCorrect(0, 1, known)), throwsStateError);

    final tracker = RetroLockstepTracker()..started(lockstep: true, rollback: 2);
    tracker
      ..sending(RetroStep(0, const [known, null]))
      ..sending(RetroStep(1, const [known, null]));
    expect(tracker.confirmed, isNull);
    expect(() => tracker.sending(RetroStep(2, const [known, null])), throwsStateError, reason: 'beyond the window');
    expect(() => tracker.correcting(RetroCorrect(1, 1, known)), throwsStateError, reason: 'frame 0 first');
    expect(() => tracker.correcting(RetroCorrect(0, 0, known)), throwsStateError, reason: 'port 1 was known');
    tracker.correcting(RetroCorrect(0, 1, known));
    expect(tracker.confirmed, 0);
    expect(() => tracker.sending(RetroStep(2, const [known, known])), throwsStateError, reason: 'frame 1 first');
    tracker.sending(RetroStep(2, const [known, null]));
    expect(
      () => tracker.replied('saveState', const {'path': 'x'}, const {'frame': 3, 'bytes': 48, 'micros': 1}),
      throwsA(isA<RetroProtocolError>()),
      reason: 'a host saves no state while a frame is not confirmed',
    );
    expect(
      () => tracker.replied('lockstep', const {'check': 1, 'paced': true}, const {'frame': 3}),
      throwsA(isA<RetroProtocolError>()),
      reason: 'a host turns rollback off only with every frame confirmed',
    );
    expect(
      tracker.replied('loadState', const {'path': 'x'}, const {'frame': 3, 'bytes': 48, 'micros': 1}),
      isA<RetroStatePosition>(),
    );
    expect(tracker.confirmed, isNull, reason: 'a load forgets the frames not confirmed');
    tracker.sending(RetroStep(3, const [known, known]));
    expect(tracker.confirmed, 3);
    expect(tracker.replied('lockstep', const {'check': 1, 'paced': true}, const {'frame': 4}), 4);
    expect(tracker.rollback, isNull);
  });

  test('settings write the rollback window, and only from 1 to 8 frames', () {
    expect(const RetroLockstepSettings(check: 60, rollback: 3).toArgs(), {
      'check': 60,
      'paced': true,
      'rollback': {'frames': 3},
    });
    expect(const RetroLockstepSettings(check: 1).toArgs(), {'check': 1, 'paced': true});
    expect(const RetroLockstepSettings(check: 60, state: false, rollback: 3).toArgs(), {
      'check': 60,
      'paced': true,
      'state': false,
      'rollback': {'frames': 3},
    });
    expect(RetroLockstepSettings.setsState(const RetroLockstepSettings(check: 1).toArgs()), isFalse);
    expect(() => const RetroLockstepSettings(check: 1, rollback: 0).toArgs(), throwsRangeError);
    expect(() => const RetroLockstepSettings(check: 1, rollback: 9).toArgs(), throwsRangeError);
  });
}
