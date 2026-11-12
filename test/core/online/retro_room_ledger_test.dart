import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/online/retro_room_ledger.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _me = '00000000-0000-0000-0000-000000000002';
const _friend = '00000000-0000-0000-0000-000000000003';
const _hosted = '01a1cc22-8fc6-7cc6-93e5-e19493f61743';
const _joined = '01a1cc22-8fc6-7cc6-93e5-e19493f61744';
const _spec = (titleId: 'SCUS94426', gameVersion: '1', mode: RetroOnlineMode.synchronized, capacity: 2);

final String? _dart = switch (Platform.environment['FLUTTER_ROOT']) {
  final root? => p.join(root, 'bin', Platform.isWindows ? 'dart.bat' : 'dart'),
  null => null,
};

void main() {
  late Directory temp;
  late Directory folder;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('retro-room-ledger');
    folder = Directory(p.join(temp.path, 'Together', 'retro-rooms'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// Records [rooms] as a launcher that has since exited would have.
  void earlierRun(List<(String, String, bool)> rooms) {
    final ledger = RetroRoomLedger(folder);
    for (final (id, user, hosted) in rooms) {
      ledger.add(id, user: user, hosted: hosted);
    }
    ledger.close();
  }

  Future<List<String>> sweep(RetroRoomLedger ledger, {Object? failure}) async {
    final calls = <String>[];
    await ledger.endEarlier(_me, (method, path, [body]) async {
      calls.add('$method $path');
      if (failure != null) throw failure;
      return {};
    });
    return calls;
  }

  test('a room this run recorded is left by its own match, not by the cleanup', () async {
    final ledger = RetroRoomLedger(folder)..add(_hosted, user: _me, hosted: true);
    expect(await sweep(ledger), isEmpty);
    expect(ledger.liveOwned(_hosted), isTrue);
    ledger.remove(_hosted);
    expect(ledger.liveOwned(_hosted), isFalse);
  });

  test('a later run ends what a run that is gone left open, and forgets it', () async {
    earlierRun([(_hosted, _me, true), (_joined, _me, false), ('01a1cc22-8fc6-7cc6-93e5-e19493f61745', _friend, true)]);
    final next = RetroRoomLedger(folder);
    expect(next.liveOwned(_hosted), isFalse);
    expect(await sweep(next), ['DELETE game-sessions/$_hosted', 'POST game-sessions/$_joined/leave']);
    expect(await sweep(next), isEmpty);
    expect(folder.listSync(), hasLength(2), reason: 'the other account\'s record and its run\'s lock stay');
  });

  test('a room the service says is gone is forgotten', () async {
    earlierRun([(_hosted, _me, true)]);
    final next = RetroRoomLedger(folder);
    await sweep(next, failure: const TogetherProblem(404, 'not_found', 'Gone'));
    expect(await sweep(next), isEmpty);
    expect(folder.listSync(), isEmpty);
  });

  test('a room the service could not be asked about, or refused, is kept for next time', () async {
    earlierRun([(_hosted, _me, true)]);
    final next = RetroRoomLedger(folder);
    for (final failure in <Object>[
      const SocketException('offline'),
      const TogetherProblem(503, 'down', 'Down'),
      const TogetherProblem(429, 'rate_limited', 'Slow down'),
      const TogetherProblem(403, 'forbidden', 'No'),
    ]) {
      expect(await sweep(next, failure: failure), hasLength(1), reason: '$failure');
    }
  });

  test('a room a launcher still running recorded is kept', () async {
    final script = File(p.join(temp.path, 'hold.dart'))
      ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final lock = File(args[0]).openSync(mode: FileMode.write)..lockSync(FileLock.exclusive);
  stdout.writeln('held');
  stdin.listen((_) {}, onDone: () => lock.closeSync());
}
''');
    const live = '00112233445566ff';
    folder.createSync(recursive: true);
    File(p.join(folder.path, '$live.json')).writeAsStringSync('[{"id":"$_hosted","user":"$_me","hosted":true}]');
    final holder = await Process.start(_dart!, [script.path, p.join(folder.path, '$live.lock')]);
    try {
      await holder.stdout.transform(const SystemEncoding().decoder).firstWhere((line) => line.contains('held'));
      final next = RetroRoomLedger(folder);
      expect(await sweep(next), isEmpty);
      expect(next.liveOwned(_hosted), isTrue);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
    expect(await sweep(RetroRoomLedger(folder)), ['DELETE game-sessions/$_hosted']);
  }, skip: _dart == null ? 'needs FLUTTER_ROOT for the dart program' : false);

  test('sweeps run one at a time', () async {
    earlierRun([(_hosted, _me, true)]);
    earlierRun([(_joined, _me, true)]);
    final next = RetroRoomLedger(folder);
    final first = Completer<Map<String, dynamic>>();
    final calls = <String>[];
    final one = next.endEarlier(_me, (method, path, [body]) {
      calls.add(path);
      return calls.length == 1 ? first.future : Future.value({});
    });
    final two = next.endEarlier(_me, (method, path, [body]) async {
      calls.add('again $path');
      return {};
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, hasLength(1));
    first.complete({});
    await one;
    await two;
    expect(calls, hasLength(2));
    expect(calls.where((call) => call.startsWith('again')), isEmpty);
  });

  test('a room whose end has not been answered is not joined meanwhile', () async {
    earlierRun([(_joined, _me, false)]);
    final next = RetroRoomLedger(folder);
    final answer = Completer<Map<String, dynamic>>();
    final sweeping = next.endEarlier(_me, (method, path, [body]) => answer.future);
    await Future<void>.delayed(Duration.zero);
    expect(next.unresolved(_joined), isTrue);
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _me,
      ledger: next,
      call: (method, path, [body]) async => throw StateError('no call expected'),
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.join(_joined), throwsA(isA<RetroRoomOccupied>()));
    answer.complete({});
    await sweeping;
    expect(next.unresolved(_joined), isFalse);
  });

  test('a join waits out its own cleanup that was not answered in time', () {
    fakeAsync((clock) {
      earlierRun([(_joined, _me, false)]);
      final next = RetroRoomLedger(folder);
      final calls = <String>[];
      final rooms = RetroOnlineRooms(
        spec: _spec,
        me: _me,
        ledger: next,
        call: (method, path, [body]) async {
          calls.add('$method $path');
          if (path.endsWith('/leave')) return Completer<Map<String, dynamic>>().future;
          if (path == 'me/game-session') return {'session': null};
          return {
            'id': _joined,
            'host': {'userId': _friend},
            'kind': 'online',
            'titleId': 'SCUS94426',
            'gameVersion': '1',
            'engineBuild': RetroOnlineMode.synchronized.protocol,
            'capacity': 2,
            'joinable': false,
            'endedAt': null,
            'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
          };
        },
        signal: (_, _, _, _, _) {},
      );
      Object? failure;
      rooms
          .join(_joined)
          .then(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      clock.elapse(const Duration(seconds: 13));
      expect(failure, isA<RetroRoomOccupied>());
      expect(calls, isEmpty, reason: 'a room another run recorded is not joined before its cleanup');
      next.endEarlier(_me, (method, path, [body]) async {
        calls.add('$method $path');
        return Completer<Map<String, dynamic>>().future;
      });
      clock.elapse(const Duration(seconds: 7));
      expect(next.unresolved(_joined), isTrue);
      expect(next.blocksJoin(_joined), isTrue);
    });
  });

  test('a room this run failed to leave is ended by its next sweep, and not joined before', () async {
    final ledger = RetroRoomLedger(folder)..add(_hosted, user: _me, hosted: true);
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _me,
      ledger: ledger,
      call: (method, path, [body]) async => throw const TogetherProblem(503, 'down', 'Down'),
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.leave((id: _hosted, hostId: _me)), throwsA(isA<TogetherProblem>()));
    expect(ledger.liveOwned(_hosted), isFalse);
    expect(ledger.blocksJoin(_hosted), isTrue);
    expect(await sweep(ledger), ['DELETE game-sessions/$_hosted']);
    expect(ledger.blocksJoin(_hosted), isFalse);
    expect(await sweep(ledger), isEmpty);
  });

  test('a room another run recorded is not joined until its cleanup is done', () async {
    earlierRun([(_joined, _me, false)]);
    final ledger = RetroRoomLedger(folder);
    final calls = <String>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _me,
      ledger: ledger,
      call: (method, path, [body]) async {
        calls.add('$method $path');
        return {};
      },
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.join(_joined), throwsA(isA<RetroRoomOccupied>()));
    expect(calls, isEmpty);
    await sweep(ledger);
    expect(ledger.blocksJoin(_joined), isFalse);
  });

  test('a request that fails before it is sent leaves nothing waiting', () async {
    earlierRun([(_hosted, _me, true)]);
    final ledger = RetroRoomLedger(folder);
    await ledger.endEarlier(_me, (method, path, [body]) => throw StateError('The AnyTogether account changed.'));
    await Future<void>.delayed(Duration.zero);
    expect(ledger.unresolved(_hosted), isFalse);
    expect(await sweep(ledger), ['DELETE game-sessions/$_hosted']);
  });

  test('a gone run stays locked until a slow request for its room is answered', () {
    fakeAsync((clock) {
      earlierRun([(_hosted, _me, true)]);
      final ledger = RetroRoomLedger(folder);
      final answer = Completer<Map<String, dynamic>>();
      var done = false;
      ledger.endEarlier(_me, (method, path, [body]) => answer.future).then((_) => done = true);
      clock.elapse(const Duration(seconds: 7));
      expect(done, isTrue);
      expect(ledger.unresolved(_hosted), isTrue);
      expect(ledger.blocksJoin(_hosted), isTrue);
      final calls = <String>[];
      ledger.endEarlier(_me, (method, path, [body]) async {
        calls.add(path);
        return {};
      });
      clock.flushMicrotasks();
      expect(calls, isEmpty, reason: 'the run is still being ended');
      answer.complete({});
      clock.flushMicrotasks();
      expect(ledger.unresolved(_hosted), isFalse);
    });
  });

  test('reads when a room was created from its ID', () {
    expect(RetroRoomLedger.createdAt(_hosted), DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6));
    expect(RetroRoomLedger.createdAt('00000000-0000-4000-8000-000000000000'), isNull);
  });

  group('room admission', () {
    Map<String, dynamic> session(String id, {bool friend = false}) => {
      'id': id,
      'titleId': 'SCUS94426',
      'host': {'userId': _me},
      'members': [
        {'userId': _me, 'device': 'an-earlier-connection'},
        if (friend) {'userId': _friend, 'device': 'their-connection'},
      ],
    };

    Future<(List<String>, Object?)> host(RetroRoomLedger ledger, Map<String, dynamic>? current) async {
      final calls = <String>[];
      var occupied = current;
      final rooms = RetroOnlineRooms(
        spec: _spec,
        me: _me,
        device: 'this-connection',
        holds: (_) => false,
        ledger: ledger,
        call: (method, path, [body]) async {
          calls.add('$method $path');
          if (path == 'me/game-session') return {'session': occupied};
          if (method == 'DELETE') {
            occupied = null;
            return {};
          }
          throw StateError('stop after admission');
        },
        signal: (_, _, _, _, _) {},
      );
      Object? failure;
      try {
        await rooms.host();
      } on Object catch (error) {
        failure = error;
      }
      return (calls, failure);
    }

    test('ends a recorded room from a run that is gone before checking', () async {
      earlierRun([(_hosted, _me, true)]);
      final (calls, _) = await host(RetroRoomLedger(folder), null);
      expect(calls.take(3), ['DELETE game-sessions/$_hosted', 'GET me/game-session', 'POST game-sessions']);
    });

    test('never ends an unrecorded room itself, but offers it to the player', () async {
      for (final friend in [false, true]) {
        final (calls, failure) = await host(RetroRoomLedger(folder), session(_hosted, friend: friend));
        expect(calls, ['GET me/game-session']);
        final other = (failure! as RetroRoomOccupied).other!;
        expect((other.id, other.hosted, other.titleId, other.others), (_hosted, true, 'SCUS94426', friend ? 1 : 0));
        expect(other.since, DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6));
      }
    });

    test('offers nothing to end for a room a running launcher recorded', () async {
      final ledger = RetroRoomLedger(folder)..add(_hosted, user: _me, hosted: true);
      final (_, failure) = await host(ledger, session(_hosted));
      expect((failure! as RetroRoomOccupied).other, isNull);
    });

    test('the player ending it leaves a room hosted by someone else', () async {
      final calls = <String>[];
      final rooms = RetroOnlineRooms(
        spec: _spec,
        me: _me,
        call: (method, path, [body]) async {
          calls.add('$method $path');
          if (calls.length == 2) throw const TogetherProblem(404, 'not_found', 'Gone');
          return {};
        },
        signal: (_, _, _, _, _) {},
      );
      const game = (id: _joined, hosted: false, titleId: 'SCUS94426', since: null, others: 1);
      await rooms.endOther(game);
      await rooms.endOther(game);
      expect(calls, ['POST game-sessions/$_joined/leave', 'POST game-sessions/$_joined/leave']);
    });
  });
}
