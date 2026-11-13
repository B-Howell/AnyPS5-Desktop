import 'dart:async';

import 'online_peer.dart';

typedef RetroRoomMember = ({String userId, String device});
typedef RetroRoom = ({String id, String hostId});
typedef RetroRoomInvite = ({RetroRoom room, String? disc, String? core});

final class RetroRoomHostMismatch implements Exception {
  const RetroRoomHostMismatch();
}

final class RetroRoomLookupTimeout implements Exception {
  const RetroRoomLookupTimeout();
}

final class RetroInviteSendTimeout implements Exception {
  const RetroInviteSendTimeout();
}

final class RetroRoomStatusTimeout extends TimeoutException {
  RetroRoomStatusTimeout(Duration duration) : super('The current online session check timed out.', duration);
}

final class RetroRoomOccupied implements Exception {
  const RetroRoomOccupied();
}

/// A deadline while preparing the connection, before the game can start.
final class RetroConnectionTimeout extends TimeoutException {
  RetroConnectionTimeout(Duration duration) : super('The multiplayer connection did not finish setting up.', duration);
}

enum RetroOnlineMode {
  synchronized('anyps5-ps1-netplay-v1'),
  lan('anyps5-retro-lan-v1'),
  nativeOnline('anyps5-retro-native-v1');

  const RetroOnlineMode(this.protocol);
  final String protocol;

  static RetroOnlineMode? fromProtocol(String protocol) =>
      values.where((mode) => mode.protocol == protocol).firstOrNull;

  static bool isRetroProtocol(String protocol) =>
      protocol.startsWith('anyps5-retro-') || protocol.startsWith('anyps5-ps1-netplay-');
}

typedef RetroRoomSpec = ({String titleId, String gameVersion, RetroOnlineMode mode, int capacity});

/// Private invitation and device binding shared by the retro gameplay modes.
/// The gameplay adapter decides how to handle an authenticated signal.
final class RetroOnlineRooms {
  const RetroOnlineRooms({
    required this.call,
    required this.signal,
    required this.me,
    required this.spec,
    this.discDigest,
    this.coreDigest,
    this.profileDigest,
  });

  String get protocol => spec.mode.protocol;
  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  final OnlineCall call;
  final OnlineSignal signal;
  final String me;
  final RetroRoomSpec spec;
  final String? discDigest;
  final String? coreDigest;
  final String? profileDigest;

  Future<RetroRoom> host({Completer<void>? cancelBeforeAdmission}) async {
    await _admissionRead(_requireIdle, cancelBeforeAdmission);
    _checkAdmission(cancelBeforeAdmission);
    final json = await call('POST', 'game-sessions', {
      'kind': 'online',
      'titleId': spec.titleId,
      'gameVersion': spec.gameVersion,
      'engineBuild': protocol,
      'versionRule': 'exact',
      'capacity': spec.capacity,
      'joinable': false,
      'properties': {
        'protocol': protocol,
        if (discDigest != null) 'discSha256': discDigest,
        if (coreDigest != null) 'coreSha256': coreDigest,
        if (profileDigest != null) 'profileSha256': profileDigest,
      },
    });
    final RetroRoom room;
    try {
      room = _room(json);
    } on StateError {
      final id = json['id'];
      final host = json['host'];
      if (id is String && _uuid.hasMatch(id) && host is Map && host['userId'] == me) {
        try {
          await call('DELETE', _path(id));
        } on Object {
          // Preserve the unsupported-room error.
        }
      }
      rethrow;
    }
    if (room.hostId != me) throw StateError('This launcher did not create the retro room.');
    return _publish(room);
  }

  Future<RetroRoom> join(String id, {String? expectedHost, Completer<void>? cancelBeforeAdmission}) async {
    final path = _path(id);
    await _admissionRead(_requireIdle, cancelBeforeAdmission);
    final room = _room(await _admissionRead(() => _readRoomView(path), cancelBeforeAdmission), id: id);
    _checkInviteHost(room, expectedHost);
    _checkAdmission(cancelBeforeAdmission);
    await call('POST', '$path/join', {'gameVersion': spec.gameVersion, 'engineBuild': protocol});
    return _publish(room);
  }

  /// Binds the host to the fingerprints used to choose the local disc and core.
  Future<RetroRoomInvite> readInvite(String id, {String? expectedHost}) async {
    final json = await _readRoomView(_path(id));
    final room = _room(json, id: id);
    _checkInviteHost(room, expectedHost);
    final properties = json['properties'] as Map;
    return (room: room, disc: properties['discSha256'] as String?, core: properties['coreSha256'] as String?);
  }

  Future<Map<String, dynamic>> _readRoomView(String path) =>
      call('GET', path).timeout(const Duration(seconds: 12), onTimeout: () => throw const RetroRoomLookupTimeout());

  void _checkInviteHost(RetroRoom room, String? expectedHost) {
    if (room.hostId == me || (expectedHost != null && room.hostId != expectedHost)) {
      throw const RetroRoomHostMismatch();
    }
  }

  Future<void> invite(RetroRoom room, String userId) async {
    if (room.hostId != me || userId == me || !_uuid.hasMatch(userId)) {
      throw ArgumentError('A retro invite needs a friend and the host account.');
    }
    // The caller already owns the room and can release it even if this reply
    // never arrives. Do not retry a POST that may have reached the service.
    await call('POST', '${_path(room.id)}/invites', {
      'userIds': [userId],
    }).timeout(const Duration(seconds: 12), onTimeout: () => throw const RetroInviteSendTimeout());
  }

  Future<List<RetroRoomMember>> peers(RetroRoom room, {String? expectedUser}) async {
    final members = await _members(room);
    var own = false;
    final peers = <RetroRoomMember>[];
    for (final member in members) {
      if (member is! Map) throw StateError('The retro room returned an invalid member.');
      final id = member['userId'];
      final device = member['device'];
      final properties = member['properties'];
      if (expectedUser != null && id != me && id != expectedUser) {
        throw StateError('An unexpected player entered the private retro room.');
      }
      if (id == me) {
        own = true;
      } else if (id is String &&
          _uuid.hasMatch(id) &&
          device is String &&
          _uuid.hasMatch(device) &&
          properties is Map &&
          properties['protocol'] == protocol) {
        peers.add((userId: id, device: device));
      }
    }
    if (!own) throw StateError('This launcher left the retro room.');
    return peers;
  }

  /// Checks room admission without waiting for gameplay transport metadata.
  Future<bool> hasInvitedMember(RetroRoom room, String expectedUser) async {
    if (expectedUser == me || !_uuid.hasMatch(expectedUser)) {
      throw ArgumentError('A retro room needs a distinct invited account.');
    }
    final users = <String>{};
    for (final member in await _members(room)) {
      final id = member is Map ? member['userId'] : null;
      if (id is! String || (id != me && id != expectedUser) || !users.add(id)) {
        throw StateError('The private retro room returned an unexpected member.');
      }
    }
    if (!users.contains(me)) throw StateError('This launcher left the retro room.');
    return users.contains(expectedUser);
  }

  Future<List<dynamic>> _members(RetroRoom room) async {
    final json = await call('GET', _path(room.id));
    if (_room(json, id: room.id) != room) throw StateError('The retro room changed hosts.');
    final members = json['members'];
    if (members is! List || members.isEmpty || members.length > spec.capacity) {
      throw StateError('This launcher is outside the retro room.');
    }
    return members;
  }

  Future<List<Map<String, dynamic>>> iceServers(RetroRoom room) async {
    const deadline = Duration(seconds: 12);
    final response = await call(
      'GET',
      '${_path(room.id)}/ice-servers',
    ).timeout(deadline, onTimeout: () => throw RetroConnectionTimeout(deadline));
    final servers = response['iceServers'];
    if (servers is! List) throw StateError('The retro room returned invalid connection settings.');
    return [for (final server in servers) Map<String, dynamic>.from(server as Map)];
  }

  void send(RetroRoom room, RetroRoomMember peer, Object? data) =>
      signal(peer.userId, peer.device, room.id, 'message', data);

  OnlinePeerSignal? receive(RetroRoom room, RetroRoomMember peer, Map<String, dynamic> event) {
    if (event['sessionId'] != room.id) return null;
    final sender = OnlinePeerSignal.fromEvent(event);
    if (sender == null || sender.kind != 'message' || sender.from != peer.userId || sender.device != peer.device) {
      return null;
    }
    return sender;
  }

  Future<void> leave(RetroRoom room) async {
    final path = _path(room.id);
    if (room.hostId == me) {
      await call('DELETE', path);
    } else {
      await call('POST', '$path/leave');
    }
  }

  Future<void> _requireIdle() async {
    const deadline = Duration(seconds: 12);
    final current = await call(
      'GET',
      'me/game-session',
    ).timeout(deadline, onTimeout: () => throw RetroRoomStatusTimeout(deadline));
    if (current['session'] != null) throw const RetroRoomOccupied();
  }

  // Stop waiting only for reads. Once a write is sent, the caller must
  // receive its result so it can release any room it acquired.
  static Future<T> _admissionRead<T>(Future<T> Function() read, Completer<void>? cancellation) {
    _checkAdmission(cancellation);
    if (cancellation == null) return read();
    return Future.any<T>([
      read(),
      cancellation.future.then<T>((_) => throw StateError('Retro room admission canceled.')),
    ]);
  }

  static void _checkAdmission(Completer<void>? cancellation) {
    if (cancellation?.isCompleted == true) throw StateError('Retro room admission canceled.');
  }

  Future<RetroRoom> _publish(RetroRoom room) async {
    try {
      final json = await call('PUT', '${_path(room.id)}/members/me', {
        'properties': {'protocol': protocol},
      });
      if (_room(json, id: room.id) != room) throw StateError('The retro room changed hosts.');
      return room;
    } on Object {
      try {
        await leave(room);
      } on Object {
        // Preserve the original error. The server also monitors the account's device.
      }
      rethrow;
    }
  }

  static String _path(String id) {
    if (!_uuid.hasMatch(id)) throw ArgumentError('Invalid retro room ID.');
    return 'game-sessions/$id';
  }

  RetroRoom _room(Map<String, dynamic> json, {String? id}) {
    final actual = json['id'];
    final host = json['host'];
    final hostId = host is Map ? host['userId'] : null;
    final properties = json['properties'];
    if (actual is! String ||
        !_uuid.hasMatch(actual) ||
        (id != null && actual != id) ||
        hostId is! String ||
        !_uuid.hasMatch(hostId) ||
        json['kind'] != 'online' ||
        json['titleId'] != spec.titleId ||
        json['gameVersion'] != spec.gameVersion ||
        json['engineBuild'] != protocol ||
        json['capacity'] != spec.capacity ||
        json['joinable'] != false ||
        json['endedAt'] != null ||
        properties is! Map ||
        properties['protocol'] != protocol ||
        (properties.containsKey('discSha256') &&
            (properties['discSha256'] is! String || !_digest.hasMatch(properties['discSha256'] as String))) ||
        (discDigest != null && properties['discSha256'] != discDigest) ||
        (properties.containsKey('coreSha256') &&
            (properties['coreSha256'] is! String || !_digest.hasMatch(properties['coreSha256'] as String))) ||
        (coreDigest != null && properties['coreSha256'] != coreDigest) ||
        (spec.mode == RetroOnlineMode.nativeOnline &&
            (profileDigest == null ||
                !_digest.hasMatch(profileDigest!) ||
                properties['profileSha256'] != profileDigest))) {
      throw StateError('This invite is not for a compatible retro room.');
    }
    return (id: actual, hostId: hostId);
  }
}
