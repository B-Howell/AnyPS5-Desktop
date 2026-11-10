import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/online_fakes.dart';

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

final class _PendingLink implements GameLinks {
  final result = Completer<GameLink>();
  int requests = 0;

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) {
    requests++;
    return result.future;
  }
}

final class _OpeningLink implements GameLink, GameLinks {
  final opening = Completer<void>();
  final _blocked = Completer<void>();
  final closeGate = Completer<void>();
  bool holdClose = false;
  bool closed = false;

  @override
  bool get streamOpen => false;

  void rejectOpen() => _blocked.completeError(StateError('Plugin closed while opening.'));

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async => this;

  @override
  Future<void> openChannel() {
    opening.complete();
    return _blocked.future;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (holdClose) await closeGate.future;
  }

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
      final profile = mode == RetroOnlineMode.nativeOnline ? 'b' * 64 : null;
      final rooms = RetroOnlineRooms(
        spec: spec,
        profileDigest: profile,
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
            'properties': {'protocol': mode.protocol, 'profileSha256': ?profile},
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

  test('a stalled invite expires once without resending it', () {
    fakeAsync((clock) {
      final reply = Completer<Map<String, dynamic>>();
      final calls = <(String, String)>[];
      final rooms = RetroOnlineRooms(
        spec: _spec,
        me: _host,
        call: (method, path, [body]) {
          calls.add((method, path));
          return reply.future;
        },
        signal: (_, _, _, _, _) {},
      );
      Object? failure;
      unawaited(rooms.invite(_room, _guest).then<void>((_) {}, onError: (Object error) => failure = error));
      clock.elapse(const Duration(seconds: 11));
      expect(failure, isNull);
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isA<RetroInviteSendTimeout>());
      reply.complete({});
      clock.flushMicrotasks();
      expect(failure, isA<RetroInviteSendTimeout>());
      expect(calls, [('POST', '$_path/invites')]);
    });
  });

  test('host cancellation releases read-only checks but returns a room already being created', () async {
    final firstRead = Completer<Map<String, dynamic>>();
    final creating = Completer<void>();
    final created = Completer<Map<String, dynamic>>();
    final calls = <(String, String)>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        calls.add((method, path));
        if (path == 'me/game-session') {
          return calls.length == 1 ? await firstRead.future : {'session': null};
        }
        if (path == 'game-sessions') {
          creating.complete();
          return created.future;
        }
        return _view();
      },
      signal: (_, _, _, _, _) {},
    );
    final cancelRead = Completer<void>();
    final opening = rooms.host(cancelBeforeAdmission: cancelRead);
    final rejected = expectLater(opening, throwsStateError);
    cancelRead.complete();
    await rejected.timeout(const Duration(seconds: 2));
    expect(calls, [('GET', 'me/game-session')]);

    final cancelWrite = Completer<void>();
    final retry = rooms.host(cancelBeforeAdmission: cancelWrite);
    await creating.future.timeout(const Duration(seconds: 2));
    cancelWrite.complete();
    firstRead.complete({'session': null});
    created.complete(_view());
    final room = await retry.timeout(const Duration(seconds: 2));
    await rooms.leave(room);
    expect(calls, [
      ('GET', 'me/game-session'),
      ('GET', 'me/game-session'),
      ('POST', 'game-sessions'),
      ('PUT', '$_path/members/me'),
      ('DELETE', _path),
    ]);
  });

  for (final hosting in [true, false]) {
    test('a stalled session check lets the player retry before ${hosting ? 'hosting' : 'joining'}', () {
      fakeAsync((clock) {
        final pending = Completer<Map<String, dynamic>>();
        final calls = <(String, String)>[];
        var reads = 0;
        final rooms = RetroOnlineRooms(
          spec: _spec,
          me: hosting ? _host : _guest,
          call: (method, path, [body]) async {
            calls.add((method, path));
            if (path == 'me/game-session') return ++reads == 1 ? pending.future : {'session': null};
            return _view();
          },
          signal: (_, _, _, _, _) {},
        );
        Future<RetroRoom> enter() => hosting ? rooms.host() : rooms.join(_roomId, expectedHost: _host);

        Object? failure;
        unawaited(
          enter().then<void>(
            (_) => fail('The old attempt admitted the player.'),
            onError: (Object e) {
              failure = e;
            },
          ),
        );
        clock.elapse(const Duration(seconds: 11));
        expect(failure, isNull);
        clock.elapse(const Duration(seconds: 1));
        expect(failure, isA<RetroRoomStatusTimeout>());
        expect(calls, [('GET', 'me/game-session')]);

        RetroRoom? opened;
        unawaited(enter().then<void>((room) => opened = room));
        clock.flushMicrotasks();
        expect(opened, _room);
        pending.complete({'session': null});
        clock.flushMicrotasks();
        expect(calls.where((call) => call.$1 == 'POST'), [('POST', hosting ? 'game-sessions' : '$_path/join')]);
      });
    });
  }

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
    await expectLater(rooms.join(_roomId), throwsA(isA<RetroRoomOccupied>()));
    expect(requests, ['GET']);
    busy = false;
    await expectLater(rooms.join(_roomId), throwsStateError);
    expect(requests, ['GET', 'GET', 'GET']);
  });

  test('reads the invited disc fingerprint and rejects a change before joining', () async {
    final digest = 'b' * 64;
    var advertised = digest;
    var joined = false;
    RetroOnlineRooms rooms([String? expected]) => RetroOnlineRooms(
      spec: _spec,
      me: _guest,
      discDigest: expected,
      call: (method, path, [body]) async {
        if (path == 'me/game-session') return {'session': null};
        if (method == 'POST') joined = true;
        return _view()..['properties'] = {'protocol': _spec.mode.protocol, 'discSha256': advertised};
      },
      signal: (_, _, _, _, _) {},
    );
    expect((await rooms().readInvite(_roomId)).disc, digest);
    advertised = 'c' * 64;
    await expectLater(rooms(digest).join(_roomId), throwsStateError);
    expect(joined, isFalse);
    advertised = 'invalid';
    await expectLater(rooms().readInvite(_roomId), throwsStateError);
  });

  test('reads a fresh invite core fingerprint and rejects changed or malformed metadata', () async {
    final digest = 'a' * 64;
    final core = 'b' * 64;
    Object? advertised = core;
    var joined = false;
    RetroOnlineRooms rooms({String? expectedCore}) => RetroOnlineRooms(
      spec: _spec,
      me: _guest,
      coreDigest: expectedCore,
      call: (method, path, [body]) async {
        if (path == 'me/game-session') return {'session': null};
        if (method == 'POST') joined = true;
        return _view()
          ..['properties'] = {'protocol': _spec.mode.protocol, 'discSha256': digest, 'coreSha256': ?advertised};
      },
      signal: (_, _, _, _, _) {},
    );
    expect(await rooms().readInvite(_roomId), (room: (id: _roomId, hostId: _host), disc: digest, core: core));
    advertised = 'c' * 64;
    await expectLater(rooms(expectedCore: core).join(_roomId), throwsStateError);
    expect(joined, isFalse);
    advertised = 42;
    await expectLater(rooms().readInvite(_roomId), throwsStateError);
    advertised = null;
    expect((await rooms().readInvite(_roomId)).core, isNull);
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

  test('cancel while checking whether PS1 can host never creates a room', () async {
    final requested = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final calls = <(String, String)>[];
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        calls.add((method, path));
        if (path == 'me/game-session') {
          requested.complete();
          return reply.future;
        }
        return _view();
      },
      signal: (_, _, _, _, _) {},
    );
    final match = Ps1NetplayMatch(rooms: rooms, links: _UnusedLinks(), identity: _identity(), runner: _UnusedRunner());
    final opening = match.host(_guest);
    await requested.future.timeout(const Duration(seconds: 2));
    try {
      await Future.wait([opening, match.leave(), match.done]).timeout(const Duration(seconds: 2));
      expect(calls, [('GET', 'me/game-session')]);
    } finally {
      reply.complete({'session': null});
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls, [('GET', 'me/game-session')]);
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

  for (final mode in [RetroOnlineMode.synchronized, RetroOnlineMode.lan]) {
    test('${mode.name} releases a room when connection settings stall', () {
      fakeAsync((clock) {
        final reply = Completer<Map<String, dynamic>>();
        final network = FakeGameNetwork();
        var settingsRequests = 0;
        var released = 0;
        var closed = false;
        Object? failure;
        final spec = (
          titleId: mode == RetroOnlineMode.lan ? 'SLUS21148' : _spec.titleId,
          gameVersion: _spec.gameVersion,
          mode: mode,
          capacity: 2,
        );
        final discDigest = 'a' * 64;
        final rooms = RetroOnlineRooms(
          spec: spec,
          discDigest: discDigest,
          me: _host,
          call: (method, path, [body]) async {
            if (path == 'me/game-session') return {'session': null};
            if (path == '$_path/ice-servers') {
              settingsRequests++;
              return reply.future;
            }
            if (method == 'DELETE') released++;
            return {
              ..._view(),
              'titleId': spec.titleId,
              'engineBuild': mode.protocol,
              'properties': {'protocol': mode.protocol, 'discSha256': discDigest},
              'members': [
                {'userId': _host},
                {
                  'userId': _guest,
                  'device': _device,
                  'properties': {'protocol': mode.protocol},
                },
              ],
            };
          },
          signal: (_, _, _, _, _) {},
        );
        final Future<void> opening;
        final Future<void> done;
        if (mode == RetroOnlineMode.synchronized) {
          final match = Ps1NetplayMatch(
            rooms: rooms,
            links: network.links,
            identity: _identity(),
            runner: _UnusedRunner(),
          );
          opening = match.host(_guest);
          done = match.done;
        } else {
          final match = RetroLanMatch(
            rooms: rooms,
            links: network.links,
            launch: (_) async => throw StateError('The timed-out attempt must not launch.'),
          );
          opening = match.host(_guest);
          done = match.done;
        }
        unawaited(opening.then<void>((_) {}, onError: (Object error) => failure = error));
        unawaited(done.then<void>((_) => closed = true));

        clock.flushMicrotasks();
        expect(settingsRequests, 1);
        clock.elapse(const Duration(seconds: 11));
        expect(released, 0);
        clock.elapse(const Duration(seconds: 1));
        expect(failure, isA<RetroConnectionTimeout>());
        expect(closed, isTrue);
        expect(released, 1);

        expect(network.made, isEmpty);
        reply.complete({'iceServers': <Object>[]});
        clock.flushMicrotasks();
        expect(network.made, isEmpty);
        expect(failure, isA<RetroConnectionTimeout>());
        expect(released, 1);
      });
    });
  }

  for (final cancel in [false, true]) {
    test('PS1 ${cancel ? 'cancel' : 'timeout'} closes a peer connection returned after startup ends', () {
      fakeAsync((clock) {
        var released = 0;
        var completed = false;
        Object? failure;
        final pending = _PendingLink();
        final network = FakeGameNetwork();
        final rooms = RetroOnlineRooms(
          spec: _spec,
          me: _host,
          call: (method, path, [body]) async {
            if (method == 'DELETE') released++;
            return {
              ..._view(),
              'iceServers': <Object>[],
              'members': [
                {'userId': _host},
                {
                  'userId': _guest,
                  'device': _device,
                  'properties': {'protocol': _spec.mode.protocol},
                },
              ],
            };
          },
          signal: (_, _, _, _, _) => fail('An abandoned connection must not signal.'),
        );
        final match = Ps1NetplayMatch(rooms: rooms, links: pending, identity: _identity(), runner: _UnusedRunner());
        unawaited(match.host(_guest).then<void>((_) => completed = true, onError: (Object error) => failure = error));
        clock.flushMicrotasks();
        expect(pending.requests, 1);

        if (cancel) {
          unawaited(match.leave());
          clock.flushMicrotasks();
          expect(completed, isTrue);
        } else {
          clock.elapse(const Duration(seconds: 29));
          expect(match.closed, isFalse);
          clock.elapse(const Duration(seconds: 1));
          expect(failure, isA<RetroConnectionTimeout>());
        }
        expect(match.closed, isTrue);
        expect(released, 1);

        unawaited(network.links.link([]).then(pending.result.complete));
        clock.flushMicrotasks();
        expect(network.all.single.closed, isTrue);
        expect(match.session, isNull);
        expect(released, 1);
      });
    });
  }

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

  test('late plugin rejection keeps the startup timeout while the link closes', () {
    fakeAsync((clock) {
      final link = _OpeningLink()..holdClose = true;
      final peer = Ps1NetplayPeer(
        link: link,
        identity: _identity(),
        runner: _UnusedRunner(),
        seat: 0,
        hostEpoch: 1,
        sendSignal: (_) async {},
        timeout: const Duration(milliseconds: 30),
      );
      Object? failure;
      var opened = false;
      var done = false;
      unawaited(peer.open().then<void>((_) => opened = true, onError: (Object error) => failure = error));
      unawaited(peer.done.then<void>((_) => done = true));
      clock.elapse(const Duration(milliseconds: 30));
      expect(peer.session.ended, Ps1NetplayEnd.startupTimedOut);
      expect(link.closed, isTrue);
      expect(done, isFalse);

      link.rejectOpen();
      clock.flushMicrotasks();
      expect(failure, isNull);
      expect(opened, isTrue);
      expect(peer.session.ended, Ps1NetplayEnd.startupTimedOut);

      link.closeGate.complete();
      clock.flushMicrotasks();
      expect(done, isTrue);
    });
  });

  test('host rejects an uninvited room member before that member publishes a marker', () async {
    var removed = false;
    var askedIce = false;
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        if (method == 'DELETE') removed = true;
        if (path.endsWith('/ice-servers')) askedIce = true;
        return {
          ..._view(),
          'members': [
            {'userId': _host},
            {'userId': _device, 'device': _device},
          ],
        };
      },
      signal: (_, _, _, _, _) {},
    );
    final match = Ps1NetplayMatch(rooms: rooms, links: _UnusedLinks(), identity: _identity(), runner: _UnusedRunner());
    await expectLater(match.host(_guest), throwsA(isA<StateError>()));
    await match.done;
    expect(match.session, isNull);
    expect(askedIce, isFalse);
    expect(removed, isTrue);
  });

  test('cancelling a published room does not wait for a stalled member lookup', () async {
    final lookup = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    var removed = false;
    final rooms = RetroOnlineRooms(
      spec: _spec,
      me: _host,
      call: (method, path, [body]) async {
        if (method == 'GET' && path == _path) {
          lookup.complete();
          return response.future;
        }
        if (method == 'DELETE') removed = true;
        return _view();
      },
      signal: (_, _, _, _, _) {},
    );
    final match = Ps1NetplayMatch(rooms: rooms, links: _UnusedLinks(), identity: _identity(), runner: _UnusedRunner());
    final opening = match.host(_guest);
    await lookup.future;
    try {
      await Future.wait([match.leave(), opening]).timeout(const Duration(milliseconds: 300));
      expect(removed, isTrue);
    } finally {
      response.complete({
        ..._view(),
        'members': [
          {'userId': _host},
        ],
      });
      await match.done;
    }
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
