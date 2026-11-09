import 'dart:async';

import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';

/// Local stand-in for the room API and directed gateway events.
final class WebRtcRoomFixture {
  WebRtcRoomFixture(this.spec, this.digest);

  static const roomId = '00000000-0000-0000-0000-000000000001';
  static const host = '00000000-0000-0000-0000-000000000002';
  static const guest = '00000000-0000-0000-0000-000000000003';
  static const _devices = {host: '00000000-0000-0000-0000-000000000004', guest: '00000000-0000-0000-0000-000000000005'};
  static const _path = 'game-sessions/$roomId';

  final RetroRoomSpec spec;
  final String digest;
  final _invited = Completer<void>();
  final _members = <String>{};
  final _published = <String>{};
  final events = <String, void Function(String, Map<String, dynamic>)>{};
  Map<String, dynamic>? _room;
  int signals = 0;

  Future<void> get invited => _invited.future;
  bool get released => _room == null && _members.isEmpty && _published.isEmpty;

  RetroOnlineRooms client(String user, {String? expectedDigest}) => RetroOnlineRooms(
    spec: spec,
    me: user,
    discDigest: expectedDigest,
    call: (method, path, [body]) async => _call(user, method, path, body),
    signal: (to, device, session, kind, data) {
      if (!_published.contains(user) ||
          !_published.contains(to) ||
          to == user ||
          device != _devices[to] ||
          session != roomId) {
        throw StateError('Invalid directed room signal.');
      }
      signals++;
      scheduleMicrotask(
        () => events[to]?.call('game_session.signal', {
          'sessionId': session,
          'from': user,
          'device': _devices[user],
          'kind': kind,
          'data': data,
        }),
      );
    },
  );

  Map<String, dynamic> _call(String user, String method, String path, Map<String, dynamic>? body) {
    if (method == 'GET' && path == 'me/game-session') {
      return {'session': _members.contains(user) ? _view() : null};
    }
    if (method == 'POST' && path == 'game-sessions' && user == host && _room == null) {
      final properties = body?['properties'];
      if (body == null ||
          body['joinable'] != false ||
          body['titleId'] != spec.titleId ||
          body['gameVersion'] != spec.gameVersion ||
          properties is! Map ||
          properties['discSha256'] != digest) {
        throw StateError('The host did not create a private room for the expected disc.');
      }
      _room = {
        ...body,
        'id': roomId,
        'host': {'userId': host},
        'endedAt': null,
      };
      _members.add(host);
      return _view();
    }
    if (method == 'DELETE' && path == _path && user == host) {
      _room = null;
      _members.clear();
      _published.clear();
      events[guest]?.call('game_session.ended', {'sessionId': roomId});
      return {};
    }
    if (method == 'POST' && path == '$_path/leave' && user == guest) {
      final wasMember = _members.remove(guest);
      _published.remove(guest);
      if (wasMember) events[host]?.call('game_session.member_left', {'sessionId': roomId});
      return {};
    }
    if (_room == null) throw StateError('The fixture room is closed.');
    if (method == 'PUT' && path == '$_path/members/me' && _members.contains(user)) {
      final properties = body?['properties'];
      if (properties is! Map || properties['protocol'] != spec.mode.protocol) {
        throw StateError('The member did not publish its protocol marker.');
      }
      _published.add(user);
      return _view();
    }
    if (method == 'POST' && path == '$_path/invites' && user == host && _published.contains(host)) {
      final invited = body?['userIds'];
      if (invited is! List || invited.singleOrNull != guest) throw StateError('Unexpected fixture invite.');
      _invited.complete();
      return {};
    }
    if (method == 'GET' && path == _path && (user == host || _invited.isCompleted)) return _view();
    if (method == 'POST' && path == '$_path/join' && user == guest && _invited.isCompleted) {
      if (body?['gameVersion'] != spec.gameVersion || body?['engineBuild'] != spec.mode.protocol) {
        throw StateError('The guest joined with a different room version.');
      }
      _members.add(guest);
      return _view();
    }
    if (method == 'GET' && path == '$_path/ice-servers' && _published.contains(user)) {
      return {'iceServers': <Object>[]};
    }
    throw StateError('Unexpected fixture room request: $method $path.');
  }

  Map<String, dynamic> _view() => {
    ..._room!,
    'members': [
      for (final member in _members)
        {
          'userId': member,
          'device': _devices[member],
          if (_published.contains(member)) 'properties': {'protocol': spec.mode.protocol},
        },
    ],
  };
}
