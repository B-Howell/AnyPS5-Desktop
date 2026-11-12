import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/online/retro_room_ledger.dart';
import 'package:anyps5_desktop/core/together/account.dart';
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

/// Records [rooms] as a launcher that has since exited would have.
void _earlierRun(File file, List<(String, String, bool)> rooms) {
  final ledger = RetroRoomLedger(file);
  for (final (id, user, hosted) in rooms) {
    ledger.add(id, user: user, hosted: hosted);
  }
  ledger.close();
}

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('retro-room-ledger');
    file = File(p.join(temp.path, 'Together', 'retro-rooms.json'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('a room this run recorded is left by its own match, not by the cleanup', () {
    final ledger = RetroRoomLedger(file)..add(_hosted, user: _me, hosted: true);
    expect(ledger.earlier(_me), isEmpty);
    ledger.close();
    expect(RetroRoomLedger(file).earlier(_me), hasLength(1));
    ledger.remove(_hosted);
    expect(file.existsSync(), isFalse);
  });

  test('a room of a launcher still running is kept', () async {
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
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('[{"id":"$_hosted","user":"$_me","hosted":true,"run":"$live"}]');
    final lock = File(p.join(file.parent.path, 'retro-room-runs', '$live.lock'))..createSync(recursive: true);
    final holder = await Process.start(_dart!, [script.path, lock.path]);
    try {
      await holder.stdout.transform(const SystemEncoding().decoder).firstWhere((line) => line.contains('held'));
      final calls = <String>[];
      await RetroRoomLedger(file).endEarlier(_me, (method, path, [body]) async {
        calls.add(path);
        return {};
      });
      expect(calls, isEmpty);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
    expect(RetroRoomLedger(file).earlier(_me), hasLength(1));
  }, skip: _dart == null ? 'needs FLUTTER_ROOT for the dart program' : false);

  test('the next run ends what an earlier run left open and forgets what is gone', () async {
    _earlierRun(file, [
      (_hosted, _me, true),
      (_joined, _me, false),
      ('01a1cc22-8fc6-7cc6-93e5-e19493f61745', _friend, true),
    ]);
    final calls = <String>[];
    final next = RetroRoomLedger(file);
    await next.endEarlier(_me, (method, path, [body]) async {
      calls.add('$method $path');
      if (path.endsWith('/leave')) throw const TogetherProblem(404, 'not_found', 'Gone');
      return {};
    });
    expect(calls, ['DELETE game-sessions/$_hosted', 'POST game-sessions/$_joined/leave']);
    expect(next.earlier(_me), isEmpty);
    expect(next.earlier(_friend), hasLength(1));
  });

  test('a room the service could not be asked about, or refused, is kept for next time', () async {
    _earlierRun(file, [(_hosted, _me, true)]);
    final next = RetroRoomLedger(file);
    for (final failure in <Object>[
      const SocketException('offline'),
      const TogetherProblem(503, 'down', 'Down'),
      const TogetherProblem(429, 'rate_limited', 'Slow down'),
      const TogetherProblem(403, 'forbidden', 'No'),
    ]) {
      await next.endEarlier(_me, (method, path, [body]) async => throw failure);
      expect(next.earlier(_me), hasLength(1), reason: '$failure');
    }
  });

  test('sweeps run one at a time and never end a room this run took up again', () async {
    _earlierRun(file, [(_hosted, _me, true), (_joined, _me, true)]);
    final next = RetroRoomLedger(file);
    final first = Completer<Map<String, dynamic>>();
    final calls = <String>[];
    final sweep = next.endEarlier(_me, (method, path, [body]) {
      calls.add(path);
      return calls.length == 1 ? first.future : Future.value({});
    });
    final again = next.endEarlier(_me, (method, path, [body]) async {
      calls.add('again $path');
      return {};
    });
    await Future<void>.delayed(Duration.zero);
    next.add(_joined, user: _me, hosted: false);
    first.complete({});
    await sweep;
    await again;
    expect(calls, ['game-sessions/$_hosted']);
    expect(next.earlier(_me), isEmpty);
    expect(file.readAsStringSync(), contains(_joined));
  });

  test('reads when a room was created from its ID', () {
    expect(RetroRoomLedger.createdAt(_hosted), DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6));
    expect(RetroRoomLedger.createdAt('00000000-0000-4000-8000-000000000000'), isNull);
  });

  group('room admission', () {
    Map<String, dynamic> session(String id, {bool friend = false}) => {
      'id': id,
      'host': {'userId': _me},
      'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
      'members': [
        {'userId': _me, 'device': 'an-earlier-connection'},
        if (friend) {'userId': _friend, 'device': 'their-connection'},
      ],
    };

    Future<List<String>> host(RetroRoomLedger ledger, Map<String, dynamic>? current) async {
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
      await expectLater(rooms.host(), throwsA(anything));
      return calls;
    }

    test('ends a recorded room from an earlier run before checking', () async {
      _earlierRun(file, [(_hosted, _me, true)]);
      final calls = await host(RetroRoomLedger(file), null);
      expect(calls.take(3), ['DELETE game-sessions/$_hosted', 'GET me/game-session', 'POST game-sessions']);
    });

    test('ends an unanswered room opened before this run', () async {
      final calls = await host(RetroRoomLedger(file), session(_hosted));
      expect(calls.take(4), [
        'GET me/game-session',
        'DELETE game-sessions/$_hosted',
        'GET me/game-session',
        'POST game-sessions',
      ]);
    });

    test('keeps a room someone else is in', () async {
      final calls = await host(RetroRoomLedger(file), session(_hosted, friend: true));
      expect(calls, ['GET me/game-session']);
    });

    test('keeps an unanswered room opened within the hour', () async {
      final now = DateTime.now().millisecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
      final fresh = '${now.substring(0, 8)}-${now.substring(8)}-7cc6-93e5-e19493f61743';
      final calls = await host(
        RetroRoomLedger(file, started: DateTime.now().add(const Duration(minutes: 1))),
        session(fresh),
      );
      expect(calls, ['GET me/game-session']);
    });

    test('keeps a room that is not a PS1, PS2 or PS3 room', () async {
      final calls = await host(RetroRoomLedger(file), session(_hosted)..['properties'] = {'protocol': 'other'});
      expect(calls, ['GET me/game-session']);
    });

    test('keeps an unanswered room opened since this run began', () async {
      final ledger = RetroRoomLedger(file, started: DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6 - 1));
      final calls = await host(ledger, session(_hosted));
      expect(calls, ['GET me/game-session']);
    });
  });
}
