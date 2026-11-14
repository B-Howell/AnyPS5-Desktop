import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:anyps5_desktop/core/retro_host/strict_json.dart';
import 'package:test/test.dart';

/// The lockstep messages as the client reads them, replayed from what real hosts sent: two
/// SwanStation hosts in lockstep (test/fixtures/retro_host/lockstep_swanstation.json) and a host
/// running the host repository's test core refusing what lockstep refuses
/// (lockstep_test_core.json). Both say how they were recorded.
void main() {
  final real = _fixture('lockstep_swanstation.json');
  final refusals = _fixture('lockstep_test_core.json');

  Map<String, Object?> decode(String raw) => StrictJson.decodeObject(Uint8List.fromList(utf8.encode(raw)));
  Object? resultOf(Map<String, Object?> reply) => reply['result'];
  List<String> strings(Object? value) => (value! as List<Object?>).cast<String>();

  test('the recorded hosts list ps1Lockstep', () {
    final welcome = RetroFields(decode(real['welcome']! as String), 'welcome');
    expect(welcome.strings('capabilities'), contains(retroCapabilityPs1Lockstep));
  });

  test('the recorded steps are what the launcher writes', () {
    for (final raw in strings(real['steps'])) {
      final message = decode(raw);
      expect(RetroStep.parse(message).toMessage(), message);
    }
  });

  test('both hosts\' recorded syncs follow the steps, and match in RAM, picture and state', () {
    final syncs = strings((real['syncs']! as Map)['host']);
    final guest = strings((real['syncs']! as Map)['guest']);
    final steps = strings(real['steps']).map((raw) => RetroStep.parse(decode(raw))).toList();
    final host = RetroLockstepTracker()..started(lockstep: true);
    final other = RetroLockstepTracker()..started(lockstep: true);
    for (final step in steps) {
      host.sending(step);
      other.sending(step);
    }
    for (var index = 0; index < syncs.length; index++) {
      final ours = host.synced(decode(syncs[index]));
      final theirs = other.synced(decode(guest[index]));
      expect(ours.frame, index);
      expect(theirs.frame, index);
      expect(theirs.ram, ours.ram, reason: 'RAM of frame $index');
      expect(theirs.video, ours.video, reason: 'picture of frame $index');
      expect(
        theirs.state,
        ours.state,
        reason: 'frame $index: a state for netplay names no path, though each disc is elsewhere under another name',
      );
    }
    expect(syncs.map((raw) => decode(raw)['video']).first, isNull, reason: 'no picture before the first one');
  });

  test('the recorded saveState and loadState replies, and the syncs after a load', () {
    final replies = (real['replies']! as List<Object?>).cast<Map<String, Object?>>();
    final save = replies.firstWhere((reply) => reply['method'] == 'saveState');
    final tracker = RetroLockstepTracker()..started(lockstep: true);
    for (var frame = 0; frame < 600; frame++) {
      tracker.sending(RetroStep(frame, const [RetroPadInput.idle, RetroPadInput.idle]));
    }
    final saved = tracker.replied('saveState', save['args'], resultOf(decode(save['reply']! as String)));
    expect(saved, const RetroStatePosition(frame: 600, bytes: 11534384));
    expect((saved! as RetroStatePosition).micros, greaterThan(0), reason: 'every state reply says how long it took');
    expect(tracker.nextStep, 600);

    for (final peer in ['host', 'guest']) {
      final load = replies.lastWhere((reply) => reply['method'] == 'loadState');
      final loading = RetroLockstepTracker()..started(lockstep: true);
      final loaded = loading.replied('loadState', load['args'], resultOf(decode(load['reply']! as String)));
      expect(loaded, saved);
      expect(loading.nextStep, 600);
      final after = strings((real['afterLoad']! as Map)[peer]);
      for (var frame = 600; frame < 600 + after.length; frame++) {
        loading.sending(RetroStep(frame, const [RetroPadInput.idle, RetroPadInput.idle]));
      }
      for (var index = 0; index < after.length; index++) {
        expect(loading.synced(decode(after[index])).frame, 600 + index);
      }
    }
    final hostAfter = strings((real['afterLoad']! as Map)['host']).map((raw) => decode(raw)['ram']);
    final guestAfter = strings((real['afterLoad']! as Map)['guest']).map((raw) => decode(raw)['ram']);
    expect(guestAfter, hostAfter, reason: 'the guest that loaded the state runs as the host replayed it');
    final hostStates = strings((real['afterLoad']! as Map)['host']).map((raw) => decode(raw)['state']);
    final guestStates = strings((real['afterLoad']! as Map)['guest']).map((raw) => decode(raw)['state']);
    expect(guestStates, hostStates, reason: 'state hashes too, the analog-mode combination held across the save');
  });

  test('the recorded entry into lockstep of a running game is at frame 0', () {
    final replies = (real['replies']! as List<Object?>).cast<Map<String, Object?>>();
    final enter = replies.firstWhere((reply) => reply['method'] == 'lockstep');
    final tracker = RetroLockstepTracker()..started(lockstep: false);
    expect(tracker.replied('lockstep', enter['args'], resultOf(decode(enter['reply']! as String))), 0);
    expect(tracker.inLockstep, isTrue);
  });

  test('the recorded refusals and re-entry of the test core', () {
    final replies = (refusals['replies']! as List<Object?>).cast<Map<String, Object?>>();
    final tracker = RetroLockstepTracker()..started(lockstep: true);
    void stepTo(int end) {
      for (var frame = tracker.nextStep!; frame < end; frame++) {
        tracker.sending(RetroStep(frame, const [RetroPadInput.idle]));
      }
    }

    stepTo(600);
    final results = <Object?>[];
    final errors = <Object?>[];
    for (final reply in replies) {
      final method = reply['method']! as String;
      final message = decode(reply['reply']! as String);
      final result = resultOf(message);
      if (message['error'] case final Map<String, Object?> error) {
        errors.add(error['code']);
        continue;
      }
      if (!retroLockstepMethods.contains(method)) {
        results.add(result);
        continue;
      }
      if (method == 'lockstep' && reply['args'] != false && tracker.inLockstep) {
        stepTo((result! as Map<String, Object?>)['frame']! as int);
      }
      results.add(tracker.replied(method, reply['args'], result));
    }
    expect(results, [
      const RetroStatePosition(frame: 600, bytes: 131152),
      const RetroStatePosition(frame: 600, bytes: 131152),
      false,
      false,
      null,
      null,
      null,
      1021,
      true,
      0,
      null,
      const RetroStatePosition(frame: 0, bytes: 131152),
      const RetroStatePosition(frame: 0, bytes: 131152),
    ]);
    expect(errors, List.filled(4, 'argument'), reason: 'slots out of range, and neither or both of a path and a slot');
    expect(tracker.nextStep, 0);
  });

  group('refuses what protocol.md does not allow', () {
    Matcher protocolError(String part) =>
        throwsA(isA<RetroProtocolError>().having((error) => error.message, 'message', contains(part)));

    RetroLockstepTracker stepped(int frames) {
      final tracker = RetroLockstepTracker()..started(lockstep: true);
      for (var frame = 0; frame < frames; frame++) {
        tracker.sending(RetroStep(frame, const [RetroPadInput.idle]));
      }
      return tracker;
    }

    Map<String, Object?> sync(Object? frame, {Object? ram = '0123456789abcdef'}) => {
      'type': 'sync',
      'frame': frame,
      'ram': ram,
      'video': null,
      'state': '0123456789abcdef',
    };

    test('a hash that is not 16 lowercase hexadecimal digits', () {
      expect(() => stepped(1).synced(sync(0, ram: '0123456789ABCDEF')), protocolError('sync.ram'));
      expect(() => stepped(1).synced(sync(0, ram: '0123')), protocolError('sync.ram'));
      expect(() => stepped(1).synced(sync(0, ram: 7)), protocolError('sync.ram'));
      expect(() => stepped(1).synced({...sync(0)}..remove('video')), protocolError('sync.video is missing'));
    });

    test('a frame outside 0 to 4294967295', () {
      expect(() => stepped(1).synced(sync(-1)), protocolError('sync.frame'));
      expect(() => stepped(1).synced(sync(4294967296)), protocolError('sync.frame'));
      expect(() => stepped(1).synced(sync('0')), protocolError('sync.frame'));
    });

    test('a sync for a frame not stepped, twice, or out of order', () {
      expect(() => stepped(2).synced(sync(2)), protocolError('was not stepped'));
      final tracker = stepped(3)..synced(sync(1));
      expect(() => tracker.synced(sync(1)), protocolError('came after'));
      expect(() => tracker.synced(sync(0)), protocolError('came after'));
      expect(tracker.synced(sync(2)).frame, 2);
    });

    test('a sync for a game not in lockstep, or after it left', () {
      expect(
        () => (RetroLockstepTracker()..started(lockstep: false)).synced(sync(0)),
        protocolError('not in lockstep'),
      );
      final left = stepped(2)..replied('lockstep', false, true);
      expect(() => left.synced(sync(1)), protocolError('not in lockstep'));
    });

    test('lockstep results of the wrong shape', () {
      final entering = RetroLockstepTracker()..started(lockstep: false);
      expect(() => entering.replied('lockstep', {'check': 1}, {'frame': 5}), protocolError('entering lockstep'));
      expect(() => stepped(4).replied('lockstep', {'check': 1}, {'frame': 3}), protocolError('not the next step'));
      expect(() => entering.replied('lockstep', {'check': 1}, true), protocolError('object or false'));
      expect(() => entering.replied('lockstep', false, null), protocolError('boolean'));
      expect(entering.replied('lockstep', {'check': 1}, false), isNull);
    });

    test('state results of the wrong shape', () {
      expect(() => stepped(1).replied('saveState', null, {'frame': 1, 'bytes': 47}), protocolError('saveState.bytes'));
      expect(() => stepped(1).replied('loadState', null, {'frame': 1}), protocolError('loadState.bytes'));
      expect(() => stepped(1).replied('saveState', null, {'frame': 1, 'bytes': 48}), protocolError('saveState.micros'));
      expect(() => stepped(1).replied('saveState', null, true), protocolError('object or false'));
      expect(
        () => (RetroLockstepTracker()..started(lockstep: false)).replied('saveState', null, {
          'frame': 0,
          'bytes': 48,
          'micros': 1,
        }),
        protocolError('not in lockstep'),
      );
    });
  });

  group('refuses to send what protocol.md does not allow', () {
    test('a step that is not the next, or outside lockstep', () {
      final tracker = RetroLockstepTracker()..started(lockstep: true);
      expect(() => tracker.sending(RetroStep(1, const [RetroPadInput.idle])), throwsStateError);
      tracker.sending(RetroStep(0, const [RetroPadInput.idle]));
      expect(() => tracker.sending(RetroStep(0, const [RetroPadInput.idle])), throwsStateError);
      expect(
        () => (RetroLockstepTracker()..started(lockstep: false)).sending(RetroStep(0, const [RetroPadInput.idle])),
        throwsStateError,
      );
    });

    test('a step with no port or more than two, and a check out of range', () {
      expect(() => RetroStep(0, const []), throwsRangeError);
      expect(() => RetroStep(0, const [RetroPadInput.idle, RetroPadInput.idle, RetroPadInput.idle]), throwsRangeError);
      expect(() => RetroStep(4294967296, const [RetroPadInput.idle]), throwsRangeError);
      expect(() => const RetroLockstepSettings(check: 0).toArgs(), throwsRangeError);
      expect(() => const RetroLockstepSettings(check: 3601).toArgs(), throwsRangeError);
      expect(const RetroLockstepSettings(check: 60).toArgs(), {'check': 60, 'paced': true});
    });
  });
}

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/retro_host/$name').readAsStringSync()) as Map<String, Object?>;
