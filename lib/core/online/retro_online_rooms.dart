import 'online_peer.dart';

typedef RetroRoomMember = ({String userId, String device});
typedef RetroRoom = ({String id, String hostId});

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
  });

  String get protocol => spec.mode.protocol;
  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  final OnlineCall call;
  final OnlineSignal signal;
  final String me;
  final RetroRoomSpec spec;
  final String? discDigest;

  Future<RetroRoom> host() async {
    await _requireIdle();
    final json = await call('POST', 'game-sessions', {
      'kind': 'online',
      'titleId': spec.titleId,
      'gameVersion': spec.gameVersion,
      'engineBuild': protocol,
      'versionRule': 'exact',
      'capacity': spec.capacity,
      'joinable': false,
      'properties': {'protocol': protocol, if (discDigest != null) 'discSha256': discDigest},
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

  Future<RetroRoom> join(String id) async {
    final path = _path(id);
    await _requireIdle();
    final room = _room(await call('GET', path), id: id);
    if (room.hostId == me) throw StateError('The retro room belongs to this account.');
    await call('POST', '$path/join', {'gameVersion': spec.gameVersion, 'engineBuild': protocol});
    return _publish(room);
  }

  /// Reads an invited host's disc fingerprint before choosing a local copy.
  Future<String?> invitedDiscDigest(String id) async {
    final json = await call('GET', _path(id));
    final room = _room(json, id: id);
    if (room.hostId == me) throw StateError('The retro room belongs to this account.');
    return (json['properties'] as Map)['discSha256'] as String?;
  }

  Future<void> invite(RetroRoom room, String userId) async {
    if (room.hostId != me || userId == me || !_uuid.hasMatch(userId)) {
      throw ArgumentError('A retro invite needs a friend and the host account.');
    }
    await call('POST', '${_path(room.id)}/invites', {
      'userIds': [userId],
    });
  }

  Future<List<RetroRoomMember>> peers(RetroRoom room, {String? expectedUser}) async {
    final json = await call('GET', _path(room.id));
    if (_room(json, id: room.id) != room) throw StateError('The retro room changed hosts.');
    final members = json['members'];
    if (members is! List || members.isEmpty || members.length > spec.capacity) {
      throw StateError('This launcher is outside the retro room.');
    }
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

  Future<List<Map<String, dynamic>>> iceServers(RetroRoom room) async {
    final response = await call('GET', '${_path(room.id)}/ice-servers');
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
    final current = await call('GET', 'me/game-session');
    if (current['session'] != null) throw StateError('Leave your current online game before starting another.');
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
        (discDigest != null && properties['discSha256'] != discDigest)) {
      throw StateError('This invite is not for a compatible retro room.');
    }
    return (id: actual, hostId: hostId);
  }
}
