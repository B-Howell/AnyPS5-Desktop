import 'dart:async';

import '../together/account.dart';
import '../together/invite_log.dart';
import 'online_peer.dart';
import 'retro_room_ledger.dart';

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

/// A game session this account is already in, that this launcher does not use and no launcher
/// still running here recorded: the player may choose to end it ([RetroOnlineRooms.endOther]).
typedef OtherOnlineGame = ({String id, bool hosted, String titleId, DateTime? since, int others});

final class RetroRoomOccupied implements Exception {
  const RetroRoomOccupied([this.other]);

  /// The session in the way, when the player may end it from here.
  final OtherOnlineGame? other;
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

/// A step of a room's admission for the invite log: what was asked and how it ended.
typedef RetroRoomTrace = void Function(String event, Map<String, Object?> fields);

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
    this.trace,
    this.device,
    this.holds,
    this.ledger,
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
  final RetroRoomTrace? trace;

  /// This launcher's device as the service names it (the realtime socket's session).
  final String? device;

  /// Whether this launcher still uses the game session with that ID.
  final bool Function(String sessionId)? holds;

  /// Where the rooms this launcher is in are recorded, so a run closed by force is cleaned up by
  /// the next one.
  final RetroRoomLedger? ledger;

  Future<T> _traced<T>(String event, Map<String, Object?> fields, Future<T> Function() step) async {
    try {
      final result = await step();
      trace?.call(event, {...fields, 'result': 'ok', if (result is RetroRoom) 'room': result.id});
      return result;
    } on Object catch (error) {
      trace?.call(event, {...fields, 'result': 'failed', ...InviteLog.error(error)});
      rethrow;
    }
  }

  Future<RetroRoom> host({Completer<void>? cancelBeforeAdmission}) =>
      _traced('room.create', {'title': spec.titleId, 'mode': spec.gameVersion}, () => _host(cancelBeforeAdmission));

  Future<RetroRoom> _host(Completer<void>? cancelBeforeAdmission) async {
    await _requireIdle(cancelBeforeAdmission);
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
    ledger?.add(room.id, user: me, hosted: true);
    return _publish(room);
  }

  Future<RetroRoom> join(String id, {String? expectedHost, Completer<void>? cancelBeforeAdmission}) async {
    final path = _path(id);
    if (ledger?.unresolved(id) ?? false) throw const RetroRoomOccupied();
    await _requireIdle(cancelBeforeAdmission);
    final room = _room(await _admissionRead(() => _readRoomView(path), cancelBeforeAdmission), id: id);
    _checkInviteHost(room, expectedHost);
    _checkAdmission(cancelBeforeAdmission);
    await call('POST', '$path/join', {'gameVersion': spec.gameVersion, 'engineBuild': protocol});
    ledger?.add(room.id, user: me, hosted: false);
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

  Future<void> invite(RetroRoom room, String userId) =>
      _traced('invite.send', {'room': room.id, 'to': InviteLog.hash(userId)}, () => _invite(room, userId));

  Future<void> _invite(RetroRoom room, String userId) async {
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
    try {
      if (room.hostId == me) {
        await call('DELETE', path);
      } else {
        await call('POST', '$path/leave');
      }
    } on TogetherProblem catch (problem) {
      if (RetroRoomLedger.isGone(problem)) ledger?.remove(room.id);
      rethrow;
    }
    ledger?.remove(room.id);
  }

  /// No session for this account, after ending the ones an earlier run left behind. The reads
  /// stop waiting when [cancellation] completes; the cleanup is sent only by an attempt that is
  /// still wanted, and is always waited for.
  Future<void> _requireIdle(Completer<void>? cancellation) async {
    _checkAdmission(cancellation);
    if (ledger case final kept?) {
      await kept.endEarlier(me, call, trace: trace).timeout(const Duration(seconds: 12), onTimeout: () {});
      _checkAdmission(cancellation);
    }
    final session = await _admissionRead(_currentSession, cancellation);
    if (session == null) return;
    final id = _leftHere(session);
    if (id == null) {
      final other = _other(session);
      trace?.call('room.occupied', {
        'endable': other != null,
        if (session is Map) ...{'room': session['id'], 'kind': session['kind'], 'title': session['titleId']},
        'deviceKnown': device != null,
        if (session is Map && session['members'] is List)
          'others': (session['members'] as List).where((member) => member is! Map || member['userId'] != me).length,
        if (session is Map && session['members'] is List)
          'myDevices': [
            for (final member in session['members'] as List)
              if (member is Map && member['userId'] == me) member['device'] == device ? 'this' : 'other',
          ].join(','),
      });
      throw RetroRoomOccupied(other);
    }
    _checkAdmission(cancellation);
    final hosted = (session as Map)['host'] is Map && (session['host'] as Map)['userId'] == me;
    try {
      await call(hosted ? 'DELETE' : 'POST', hosted ? _path(id) : '${_path(id)}/leave');
    } on Object catch (error) {
      trace?.call('room.leftover', {'room': id, 'hosted': hosted, 'result': 'failed', ...InviteLog.error(error)});
      throw const RetroRoomOccupied();
    }
    ledger?.remove(id);
    trace?.call('room.leftover', {'room': id, 'hosted': hosted, 'result': 'ok'});
    if (await _admissionRead(_currentSession, cancellation) != null) throw const RetroRoomOccupied();
  }

  Future<Object?> _currentSession() async {
    const deadline = Duration(seconds: 12);
    final current = await call(
      'GET',
      'me/game-session',
    ).timeout(deadline, onTimeout: () => throw RetroRoomStatusTimeout(deadline));
    return current['session'];
  }

  /// The ID of [session] when this device left it behind: every membership of this account in
  /// it is on this socket's device and this launcher no longer uses it. The socket's device
  /// changes with each connection, so this is a room from earlier in this run; a room from an
  /// earlier run is ended through the [ledger], and any other is the player's to end.
  String? _leftHere(Object? session) {
    final using = holds;
    final here = device;
    if (using == null || here == null || session is! Map) return null;
    final id = session['id'];
    final members = session['members'];
    if (id is! String || !_uuid.hasMatch(id) || members is! List || using(id)) return null;
    final mine = [
      for (final member in members)
        if (member is Map && member['userId'] == me) member['device'],
    ];
    if (mine.isEmpty || mine.any((device) => device != here)) return null;
    return id;
  }

  /// [session] as one the player may end: this account is in it, this launcher does not use it,
  /// and no launcher running here recorded it.
  OtherOnlineGame? _other(Object? session) {
    final using = holds;
    if (using == null || session is! Map) return null;
    final id = session['id'];
    final members = session['members'];
    final host = session['host'];
    if (id is! String || !_uuid.hasMatch(id) || members is! List || using(id)) return null;
    if (ledger?.liveOwned(id) ?? false) return null;
    if (!members.any((member) => member is Map && member['userId'] == me)) return null;
    return (
      id: id,
      hosted: host is Map && host['userId'] == me,
      titleId: session['titleId'] is String ? session['titleId'] as String : '',
      since: RetroRoomLedger.createdAt(id),
      others: members.where((member) => member is! Map || member['userId'] != me).length,
    );
  }

  /// Ends [game] (as its host) or leaves it, at the player's word; a session already gone counts
  /// as ended.
  Future<void> endOther(OtherOnlineGame game) async {
    try {
      await call(game.hosted ? 'DELETE' : 'POST', game.hosted ? _path(game.id) : '${_path(game.id)}/leave');
    } on TogetherProblem catch (problem) {
      if (!RetroRoomLedger.isGone(problem)) rethrow;
    }
    trace?.call('room.ended-by-player', {'room': game.id, 'hosted': game.hosted});
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
