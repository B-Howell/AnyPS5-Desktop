import 'dart:io';

import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/invite_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('anyps5-invite-log-'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('a line holds the time, the step and its fields, with ids hashed', () {
    final log = InviteLog.inFolder(folder.path, now: () => DateTime.utc(2026, 11, 12, 4, 5, 6));
    log.write('send.chosen', {'to': InviteLog.hash('user-1'), 'name': 'Remote Friend', 'room': null, 'inGame': true});
    final text = File(p.join(folder.path, 'Invites.log')).readAsStringSync();
    expect(
      text,
      '2026-11-12T04:05:06.000Z send.chosen to=${InviteLog.hash('user-1')} name="Remote Friend" inGame=true\n',
    );
    expect(InviteLog.hash('user-1'), hasLength(12));
    expect(InviteLog.hash('user-1'), isNot(contains('user-1')));
    expect(InviteLog.hash(null), '-');
  });

  test('a log past its limit is set aside before the next line', () {
    final log = InviteLog.inFolder(folder.path, limit: 64);
    for (var index = 0; index < 4; index++) {
      log.write('event', {'type': 'game_session.invite', 'index': index});
    }
    final previous = File(InviteLog.previousFile(log.file));
    expect(previous.existsSync(), isTrue);
    expect(File(log.file).lengthSync() + previous.lengthSync(), lessThan(4 * 80));
    expect(File(log.file).readAsStringSync(), contains('index=3'));
  });

  test('an AnyTogether refusal is logged by its status and code, never its words', () {
    expect(InviteLog.error(const TogetherProblem(403, 'forbidden', 'Not your friend secret-ish words')), {
      'error': 'TogetherProblem',
      'status': 403,
      'code': 'forbidden',
    });
    expect(InviteLog.error(StateError('x')), {'error': 'StateError'});
  });

  group('retro room steps', () {
    const me = '12345678-1234-4234-8234-123456789ab1';
    const friend = '12345678-1234-4234-8234-123456789ab2';
    const roomId = '12345678-1234-4234-8234-123456789abc';
    const spec = (titleId: 'SCUS94426', gameVersion: '8', mode: RetroOnlineMode.synchronized, capacity: 2);
    final room = {
      'id': roomId,
      'host': {'userId': me},
      'kind': 'online',
      'titleId': 'SCUS94426',
      'gameVersion': '8',
      'engineBuild': RetroOnlineMode.synchronized.protocol,
      'capacity': 2,
      'joinable': false,
      'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
    };

    RetroOnlineRooms rooms(List<(String, Map<String, Object?>)> steps, {Object? inviteError}) => RetroOnlineRooms(
      call: (method, path, [body]) async {
        if (path == 'me/game-session') return {'session': null};
        if (path.endsWith('/invites') && inviteError != null) throw inviteError;
        return path.endsWith('/invites') ? <String, dynamic>{} : room;
      },
      signal: (_, _, _, _, _) {},
      me: me,
      spec: spec,
      trace: (event, fields) => steps.add((event, fields)),
    );

    test('the room created and the invite sent are logged with their results', () async {
      final steps = <(String, Map<String, Object?>)>[];
      final retro = rooms(steps);
      final created = await retro.host();
      await retro.invite(created, friend);
      expect(steps.map((step) => step.$1), ['room.create', 'invite.send']);
      expect(steps[0].$2, {'title': 'SCUS94426', 'mode': '8', 'result': 'ok', 'room': roomId});
      expect(steps[1].$2, {'room': roomId, 'to': InviteLog.hash(friend), 'result': 'ok'});
    });

    test('a refused invite is logged with its HTTP status and still fails', () async {
      final steps = <(String, Map<String, Object?>)>[];
      final retro = rooms(steps, inviteError: const TogetherProblem(409, 'conflict', 'busy'));
      final created = await retro.host();
      await expectLater(retro.invite(created, friend), throwsA(isA<TogetherProblem>()));
      expect(steps.last.$1, 'invite.send');
      expect(steps.last.$2, {
        'room': roomId,
        'to': InviteLog.hash(friend),
        'result': 'failed',
        'error': 'TogetherProblem',
        'status': 409,
        'code': 'conflict',
      });
    });
  });
}
