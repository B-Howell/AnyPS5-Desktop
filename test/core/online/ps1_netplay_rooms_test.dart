import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _roomId = '00000000-0000-0000-0000-000000000001';
const _host = '00000000-0000-0000-0000-000000000002';
const _guest = '00000000-0000-0000-0000-000000000003';
const _device = '00000000-0000-0000-0000-000000000004';
const _room = (id: _roomId, hostId: _host);
const _spec = (titleId: 'SCUS94426', gameVersion: '1', mode: RetroOnlineMode.synchronized, capacity: 2);
const _path = 'game-sessions/$_roomId';

Map<String, dynamic> _view() => {
  'id': _roomId,
  'host': {'userId': _host},
  'kind': 'online',
  'titleId': 'SCUS94426',
  'gameVersion': '1',
  'engineBuild': RetroOnlineMode.synchronized.protocol,
  'capacity': 2,
  'joinable': false,
  'endedAt': null,
  'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
};

final class _UnusedRunner implements Ps1NetplayRunner {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedLinks implements GameLinks {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _OpeningLink implements GameLink, GameLinks {
  final opening = Completer<void>();
  final _blocked = Completer<void>();
  bool closed = false;

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async => this;

  @override
  Future<void> openChannel() {
    opening.complete();
    return _blocked.future;
  }

  @override
  Future<void> close() async => closed = true;

  @override
  set onStreamMessage(void Function(Uint8List) handler) {}

  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) {}

  @override
  set onMessage(void Function(Uint8List) handler) {}

  @override
  set onState(void Function(String) handler) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Ps1NetplayIdentity _identity() => Ps1NetplayIdentity.tryRead({
  'version': 1,
  'title': 'SCUS94426',
  for (final key in ['disc', 'bios', 'core', 'profile', 'card']) key: 'a' * 64,
})!;

void main() {
  test('unrecognized future retro protocols still remain outside PS5 routing', () {
    expect(RetroOnlineMode.fromProtocol('anyps5-retro-native-v2'), isNull);
    expect(RetroOnlineMode.isRetroProtocol('anyps5-retro-native-v2'), isTrue);
    expect(RetroOnlineMode.isRetroProtocol('anyps5-ps1-netplay-v2'), isTrue);
    expect(RetroOnlineMode.isRetroProtocol('toolkit-1'), isFalse);
  });

  for (final mode in [RetroOnlineMode.lan, RetroOnlineMode.nativeOnline]) {
    test('uses the supplied title and version for ${mode.name} rooms', () async {
      final spec = (titleId: 'SLUS00001', gameVersion: '1.30', mode: mode, capacity: 4);
      final rooms = RetroOnlineRooms(
        spec: spec,
        me: _host,
        call: (method, path, [body]) async {
          if (path == 'me/game-session') return {'session': null};
          if (path == 'game-sessions') {
            expect(body, containsPair('titleId', spec.titleId));
            expect(body, containsPair('gameVersion', spec.gameVersion));
            expect(body, containsPair('capacity', spec.capacity));
            expect(body, containsPair('engineBuild', mode.protocol));
          }
          return {
            ..._view(),
            'titleId': spec.titleId,
            'gameVersion': spec.gameVersion,
            'engineBuild': mode.protocol,
            'capacity': spec.capacity,
            'properties': {'protocol': mode.protocol},
          };
        },
        signal: (_, _, _, _, _) {},
      );
      expect(await rooms.host(), _room);
    });
  }

  test('opens a private room, publishes the device marker, and invites a friend', () async {
    final calls = <(String, String, Map<String, dynamic>?)>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        calls.add((method, path, body));
        return path == 'me/game-session' ? {'session': null} : _view();
      },
      signal: (_, _, _, _, _) {},
    );
    final room = await rooms.host();
    expect(room, _room);
    await rooms.invite(room, _guest);
    await rooms.leave(room);
    expect(calls.map((c) => (c.$1, c.$2)), [
      ('GET', 'me/game-session'),
      ('POST', 'game-sessions'),
      ('PUT', '$_path/members/me'),
      ('POST', '$_path/invites'),
      ('DELETE', _path),
    ]);
    expect(calls[1].$3, containsPair('joinable', false));
    expect(calls[3].$3, {
      'userIds': [_guest],
    });
  });

  test('keeps another online session and rejects an incompatible invite before joining', () async {
    var busy = true;
    final requests = <String>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _guest,
      call: (method, path, [body]) async {
        requests.add(method);
        if (path == 'me/game-session') {
          return {
            'session': busy ? {'id': 'current'} : null,
          };
        }
        return _view()..['kind'] = 'lan';
      },
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.join(_roomId), throwsStateError);
    expect(requests, ['GET']);
    busy = false;
    await expectLater(rooms.join(_roomId), throwsStateError);
    expect(requests, ['GET', 'GET', 'GET']);
  });

  test('removes an owned room when the provider drops the protocol marker', () async {
    final requests = <(String, String)>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        requests.add((method, path));
        return path == 'me/game-session' ? {'session': null} : (_view()..['properties'] = <String, Object>{});
      },
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.host(), throwsStateError);
    expect(requests, [('GET', 'me/game-session'), ('POST', 'game-sessions'), ('DELETE', _path)]);
  });

  test('cancel during room creation releases the late room without sending an invite', () async {
    final calls = <(String, String)>[];
    final requested = Completer<void>();
    final created = Completer<Map<String, dynamic>>();
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        calls.add((method, path));
        if (path == 'me/game-session') return {'session': null};
        if (path == 'game-sessions') {
          requested.complete();
          return created.future;
        }
        return _view();
      },
      signal: (_, _, _, _, _) {},
    );
    final match = Ps1NetplayMatch(rooms: rooms, links: _UnusedLinks(), identity: _identity(), runner: _UnusedRunner());
    final opening = match.host(_guest);
    await requested.future;
    final leaving = match.leave();
    created.complete(_view());
    await Future.wait([opening, leaving, match.done]);
    expect(calls, [
      ('GET', 'me/game-session'),
      ('POST', 'game-sessions'),
      ('PUT', '$_path/members/me'),
      ('DELETE', _path),
    ]);
  });

  test('cancel closes the room and completes startup even if a plugin open never returns', () async {
    var removed = false;
    final link = _OpeningLink();
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        if (method == 'DELETE') removed = true;
        return {
          ..._view(),
          'iceServers': <Object>[],
          'members': [
            {'userId': _host},
            {
              'userId': _guest,
              'device': _device,
              'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
            },
          ],
        };
      },
      signal: (_, _, _, _, _) {},
    );
    final match = Ps1NetplayMatch(rooms: rooms, links: link, identity: _identity(), runner: _UnusedRunner());
    final opening = match.host(_guest);
    await link.opening.future;
    await Future.wait([match.leave(), opening]).timeout(const Duration(seconds: 1));
    expect(link.closed, isTrue);
    expect(removed, isTrue);
  });

  test('leaves a newly joined room if publishing the member marker fails', () async {
    final paths = <String>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _guest,
      call: (method, path, [body]) async {
        paths.add(path);
        if (path == 'me/game-session') return {'session': null};
        if (method == 'PUT') throw StateError('publish failed');
        return _view();
      },
      signal: (_, _, _, _, _) {},
    );
    await expectLater(rooms.join(_roomId), throwsStateError);
    expect(paths, ['me/game-session', _path, '$_path/join', '$_path/members/me', '$_path/leave']);
  });

  test('only accepts signaling from the authenticated member device in this room', () async {
    final sent = <Object?>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _guest,
      call: (method, path, [body]) async => {
        ..._view(),
        'members': [
          {'userId': _guest},
          {
            'userId': _host,
            'device': _device,
            'properties': {'protocol': RetroOnlineMode.synchronized.protocol},
          },
        ],
      },
      signal: (to, device, room, kind, data) => sent.addAll([to, device, room, kind, data]),
    );
    final peer = (await rooms.peers(_room)).single;
    final payload = {
      'version': 1,
      'kind': 'offer',
      'data': {'type': 'offer', 'sdp': 'v=0'},
    };
    final event = {'sessionId': _roomId, 'from': _host, 'device': _device, 'kind': 'message', 'data': payload};
    expect(Ps1NetplaySignal.tryRead(rooms.receive(_room, peer, event)?.data)?.kind, Ps1NetplaySignalKind.offer);
    expect(rooms.receive(_room, peer, {...event, 'device': _guest}), isNull);
    expect(rooms.receive(_room, peer, {...event, 'sessionId': _guest}), isNull);
    expect(rooms.receive(_room, peer, {...event, 'kind': 'offer'}), isNull);
    rooms.send(_room, peer, payload);
    expect(sent, [_host, _device, _roomId, 'message', payload]);
  });
}
