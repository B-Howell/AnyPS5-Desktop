import 'package:anyps5_desktop/core/online/ps1_lockstep_rooms.dart';
import 'package:test/test.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _friend = '22222222-2222-4222-8222-222222222222';
const _room = '33333333-3333-4333-8333-333333333333';
const _device = '44444444-4444-4444-8444-444444444444';
final _disc = 'ab' * 32;

Map<String, dynamic> _session({String host = _me, List<Map<String, dynamic>> members = const [], Object? disc}) => {
  'id': _room,
  'kind': 'online',
  'titleId': Ps1LockstepRooms.titleFor(_disc),
  'gameVersion': Ps1LockstepRooms.gameVersion,
  'engineBuild': Ps1LockstepRooms.protocol,
  'capacity': 2,
  'joinable': false,
  'endedAt': null,
  'host': {'userId': host},
  'properties': {'protocol': Ps1LockstepRooms.protocol, 'discSha256': disc ?? _disc, 'discBytes': 1000},
  'members': [
    {
      'userId': host,
      'device': _device,
      'properties': {'protocol': Ps1LockstepRooms.protocol},
    },
    ...members,
  ],
};

void main() {
  late List<String> calls;
  late Map<String, Map<String, dynamic> Function(Map<String, dynamic>?)> answers;
  late List<(String, String, String, String, Object?)> signals;

  Ps1LockstepRooms rooms({String me = _me, bool Function(String)? holds}) => Ps1LockstepRooms(
    me: me,
    holds: holds,
    call: (method, path, [body]) async {
      calls.add('$method $path');
      final answer = answers['$method $path'];
      if (answer == null) throw StateError('no answer for $method $path');
      return answer(body);
    },
    signal: (to, device, session, kind, data) => signals.add((to, device, session, kind, data)),
  );

  setUp(() {
    calls = [];
    signals = [];
    answers = {
      'GET me/game-session': (_) => {'session': null},
      'PUT game-sessions/$_room/members/me': (_) => _session(),
    };
  });

  test('the host player makes a private room for two with the disc, invites the friend, and ends it', () async {
    Map<String, dynamic>? made;
    answers['POST game-sessions'] = (body) {
      made = body;
      return _session();
    };
    answers['POST game-sessions/$_room/invites'] = (_) => {};
    answers['DELETE game-sessions/$_room'] = (_) => {};
    final room = await rooms().host(disc: _disc, discBytes: 1000);
    expect(room, (id: _room, hostId: _me));
    expect(made, {
      'kind': 'online',
      'titleId': 'PS1-${_disc.substring(0, 16).toUpperCase()}',
      'gameVersion': '1',
      'engineBuild': 'anyps5-ps1-lockstep-v2',
      'versionRule': 'exact',
      'capacity': 2,
      'joinable': false,
      'properties': {'protocol': 'anyps5-ps1-lockstep-v2', 'discSha256': _disc, 'discBytes': 1000},
    });
    await rooms().invite(room, _friend);
    await rooms().leave(room);
    expect(calls, [
      'GET me/game-session',
      'POST game-sessions',
      'PUT game-sessions/$_room/members/me',
      'POST game-sessions/$_room/invites',
      'DELETE game-sessions/$_room',
    ]);
  });

  test("the friend reads the invite, joins, finds the host player's launcher and signals it", () async {
    answers['GET game-sessions/$_room'] = (_) => _session(
      host: _friend,
      members: [
        {'userId': _me, 'device': null, 'properties': <String, Object?>{}},
      ],
    );
    answers['POST game-sessions/$_room/join'] = (_) => {};
    answers['PUT game-sessions/$_room/members/me'] = (_) => _session(host: _friend);
    final invite = await rooms().readInvite(_room, expectedHost: _friend);
    expect(invite.disc, _disc);
    expect(invite.discBytes, 1000);
    final room = await rooms().join(invite);
    final peer = await rooms().peer(room, expectedUser: _friend);
    expect(peer, (userId: _friend, device: _device));
    rooms().send(room, peer!, {'version': 1});
    final (to, device, session, kind, data) = signals.single;
    expect([to, device, session, kind], [_friend, _device, _room, 'message']);
    expect(data, {'version': 1});
    final event = {'sessionId': _room, 'from': _friend, 'device': _device, 'kind': 'message', 'data': 7};
    expect(rooms().receive(room, peer, event)?.data, 7);
    expect(rooms().receive(room, peer, {...event, 'device': _me}), isNull, reason: 'another device of theirs');
    expect(rooms().receive(room, peer, {...event, 'sessionId': 'x'}), isNull);
  });

  test('an invite that is not for a lockstep room, or not from its host, is refused', () async {
    answers['GET game-sessions/$_room'] = (_) => _session(host: _friend, disc: 'nope');
    await expectLater(rooms().readInvite(_room, expectedHost: _friend), throwsA(isA<Ps1LockstepRoomInvalid>()));
    answers['GET game-sessions/$_room'] = (_) => _session(host: _friend);
    await expectLater(rooms().readInvite(_room, expectedHost: _me), throwsA(isA<Ps1LockstepRoomInvalid>()));
  });

  test('someone else in the private room is refused', () async {
    answers['GET game-sessions/$_room'] = (_) => _session(
      members: [
        {'userId': '55555555-5555-4555-8555-555555555555', 'device': _device, 'properties': <String, Object?>{}},
      ],
    );
    await expectLater(
      rooms().peer((id: _room, hostId: _me), expectedUser: _friend),
      throwsA(isA<Ps1LockstepRoomInvalid>()),
    );
  });

  test('an old session this launcher does not use is ended first; one it uses makes the account busy', () async {
    answers['GET me/game-session'] = (_) => {
      'session': {
        'id': _room,
        'host': {'userId': _me},
      },
    };
    await expectLater(
      rooms(holds: (id) => id == _room).host(disc: _disc, discBytes: 1),
      throwsA(isA<Ps1LockstepRoomBusy>()),
    );
    var ended = false;
    answers['DELETE game-sessions/$_room'] = (_) {
      ended = true;
      answers['GET me/game-session'] = (_) => {'session': null};
      return {};
    };
    answers['POST game-sessions'] = (_) => _session();
    await rooms(holds: (_) => false).host(disc: _disc, discBytes: 1000);
    expect(ended, isTrue);
  });
}
