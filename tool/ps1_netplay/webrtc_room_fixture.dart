import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';

/// Local stand-in for the room API and directed gateway events.
final class WebRtcRoomFixture {
  WebRtcRoomFixture(this.spec, this.digest);

  static const roomId = '00000000-0000-0000-0000-000000000001';
  static const host = '00000000-0000-0000-0000-000000000002';
  static const guest = '00000000-0000-0000-0000-000000000003';
  static const hostDevice = '00000000-0000-0000-0000-000000000004';
  static const _devices = {host: hostDevice, guest: '00000000-0000-0000-0000-000000000005'};
  static const _path = 'game-sessions/$roomId';

  final RetroRoomSpec spec;
  final String digest;
  final _invited = Completer<void>();
  final _members = <String>{};
  final _published = <String>{};
  final events = <String, void Function(String, Map<String, dynamic>)>{};
  Future<void>? hostReleaseGate;
  bool Function(String from, String kind, Object? data)? rejectSignal;
  Map<String, dynamic>? _room;
  int signals = 0;

  Future<void> get invited => _invited.future;
  bool get released => _room == null && _members.isEmpty && _published.isEmpty;

  RetroOnlineRooms client(String user, {String? expectedDigest}) => RetroOnlineRooms(
    spec: spec,
    me: user,
    discDigest: expectedDigest,
    call: (method, path, [body]) async {
      if (user == host && method == 'DELETE' && path == _path) await hostReleaseGate;
      return _call(user, method, path, body);
    },
    signal: (to, device, session, kind, data) {
      if (!_published.contains(user) ||
          !_published.contains(to) ||
          to == user ||
          device != _devices[to] ||
          session != roomId) {
        throw StateError('Invalid directed room signal.');
      }
      if (rejectSignal?.call(user, kind, data) ?? false) throw StateError('Fixture signaling socket unavailable.');
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

// Injects only connection-state notifications. The data channels and frame
// exchange still use the real Windows WebRTC plugin.
final class WebRtcProbeLinks implements GameLinks {
  final _delegate = WebRtcGameLinks();
  final opened = <WebRtcProbeLink>[];

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async {
    final link = WebRtcProbeLink(await _delegate.link(iceServers));
    opened.add(link);
    return link;
  }
}

final class WebRtcProbeLink implements GameLink, RestartableGameLink {
  WebRtcProbeLink(this._link);

  final GameLink _link;
  final offerCredentials = <String>[];
  int answersApplied = 0;
  void Function(String)? _onState;
  void reportState(String state) => _onState?.call(state);

  @override
  set onState(void Function(String) handler) => _link.onState = _onState = handler;
  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => _link.onCandidate = handler;
  @override
  set onMessage(void Function(Uint8List) handler) => _link.onMessage = handler;
  @override
  set onStreamMessage(void Function(Uint8List) handler) => _link.onStreamMessage = handler;
  @override
  Future<Map<String, dynamic>> createOffer() async {
    final offer = await _link.createOffer();
    final credential = RegExp(r'^a=ice-ufrag:([^\r\n]+)', multiLine: true).firstMatch(offer['sdp'] as String);
    if (credential == null) throw StateError('WebRTC offer had no ICE credentials.');
    offerCredentials.add(credential.group(1)!);
    return offer;
  }

  @override
  Future<void> restartIce() => (_link as RestartableGameLink).restartIce();
  @override
  Future<bool> routeConnected() => (_link as RestartableGameLink).routeConnected();
  @override
  Future<Map<String, dynamic>> createAnswer() => _link.createAnswer();
  @override
  Future<void> setLocal(Map<String, dynamic> description) => _link.setLocal(description);
  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    await _link.setRemote(description);
    if (description['type'] == 'answer') answersApplied++;
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => _link.addCandidate(candidate);
  @override
  Future<void> openChannel() => _link.openChannel();
  @override
  bool get gameOpen => _link.gameOpen;
  @override
  bool get streamOpen => _link.streamOpen;
  @override
  bool send(Uint8List data) => _link.send(data);
  @override
  bool sendStream(Uint8List data) => _link.sendStream(data);
  @override
  Future<void> close() => _link.close();
}
