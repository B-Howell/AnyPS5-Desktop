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

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('retro-room-ledger');
    file = File(p.join(temp.path, 'Together', 'retro-rooms.json'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('a room this run recorded is left by its own match, not by the cleanup', () {
    final ledger = RetroRoomLedger(file)..add((id: _hosted, user: _me, hosted: true));
    expect(ledger.earlier(_me), isEmpty);
    expect(RetroRoomLedger(file).earlier(_me), [(id: _hosted, user: _me, hosted: true)]);
    ledger.remove(_hosted);
    expect(file.existsSync(), isFalse);
  });

  test('the next run ends what an earlier run left open and forgets what is gone', () async {
    RetroRoomLedger(file)
      ..add((id: _hosted, user: _me, hosted: true))
      ..add((id: _joined, user: _me, hosted: false))
      ..add((id: '01a1cc22-8fc6-7cc6-93e5-e19493f61745', user: _friend, hosted: true));
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

  test('a room the service could not be asked about is kept for next time', () async {
    RetroRoomLedger(file).add((id: _hosted, user: _me, hosted: true));
    final next = RetroRoomLedger(file);
    await next.endEarlier(_me, (method, path, [body]) async => throw const SocketException('offline'));
    expect(next.earlier(_me), hasLength(1));
    await next.endEarlier(_me, (method, path, [body]) async => throw const TogetherProblem(503, 'down', 'Down'));
    expect(next.earlier(_me), hasLength(1));
  });

  test('reads when a room was created from its ID', () {
    expect(RetroRoomLedger.createdAt(_hosted), DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6));
    expect(RetroRoomLedger.createdAt('00000000-0000-4000-8000-000000000000'), isNull);
  });

  group('room admission', () {
    Map<String, dynamic> session(String id, {bool friend = false}) => {
      'id': id,
      'host': {'userId': _me},
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
      RetroRoomLedger(file).add((id: _hosted, user: _me, hosted: true));
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

    test('keeps an unanswered room opened since this run began', () async {
      final ledger = RetroRoomLedger(file, started: DateTime.fromMillisecondsSinceEpoch(0x01a1cc228fc6 - 1));
      final calls = await host(ledger, session(_hosted));
      expect(calls, ['GET me/game-session']);
    });
  });
}
