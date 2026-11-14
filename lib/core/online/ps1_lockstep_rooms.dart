import 'dart:async';

import 'online_peer.dart';

/// A member of a match's room: the account and the device (the launcher) it plays on.
typedef Ps1LockstepMember = ({String userId, String device});

/// A match's room: its AnyTogether game session and who hosts it.
typedef Ps1LockstepRoom = ({String id, String hostId});

/// What a friend's invite says of the game: its disc, by SHA-256, and the disc's size, so a
/// launcher looks only at discs that can be it.
typedef Ps1LockstepInvite = ({Ps1LockstepRoom room, String disc, int discBytes});

/// This account is still in another game session, used by this launcher.
final class Ps1LockstepRoomBusy implements Exception {
  const Ps1LockstepRoomBusy();
}

/// The invite is not for a room of this kind, or its host is not who sent it.
final class Ps1LockstepRoomInvalid implements Exception {
  const Ps1LockstepRoomInvalid(this.reason);

  final String reason;

  @override
  String toString() => 'Ps1LockstepRoomInvalid: $reason';
}

/// The private AnyTogether game session a PS1 lockstep match is arranged in, as the launcher's
/// other emulator online play does: the host player's launcher creates it (not joinable, for two),
/// invites one friend, and both bind their device to it; WebRTC signals and the TURN servers come
/// through it (anyps5-retro-host docs/netplay.md "NAT and relays"). Nothing of the game is sent to
/// AnyTogether but the disc's hash and size.
final class Ps1LockstepRooms {
  const Ps1LockstepRooms({required this.call, required this.signal, required this.me, this.holds});

  /// The rooms' `engineBuild` and member `protocol`.
  static const protocol = 'anyps5-ps1-lockstep-v1';

  /// The rooms' `gameVersion`.
  static const gameVersion = '1';

  static const capacity = 2;

  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  final OnlineCall call;
  final OnlineSignal signal;
  final String me;

  /// Whether this launcher uses the game session with that ID. Any other session this account is
  /// still in is an old one, left by a launcher that crashed or was closed, and is replaced.
  final bool Function(String sessionId)? holds;

  /// The room's `titleId`: the same on every machine with the same disc, whatever its path.
  static String titleFor(String disc) => 'PS1-${disc.substring(0, 16).toUpperCase()}';

  static const _deadline = Duration(seconds: 12);

  /// Creates the room for the disc with SHA-256 [disc] of [discBytes] bytes.
  Future<Ps1LockstepRoom> host({required String disc, required int discBytes}) async {
    if (!_digest.hasMatch(disc) || discBytes < 1) throw ArgumentError('A lockstep room needs a disc digest and size.');
    await _requireIdle();
    final json = await call('POST', 'game-sessions', {
      'kind': 'online',
      'titleId': titleFor(disc),
      'gameVersion': gameVersion,
      'engineBuild': protocol,
      'versionRule': 'exact',
      'capacity': capacity,
      'joinable': false,
      'properties': {'protocol': protocol, 'discSha256': disc, 'discBytes': discBytes},
    });
    final invite = _read(json);
    if (invite.room.hostId != me || invite.disc != disc) {
      await _leaveQuietly(invite.room);
      throw const Ps1LockstepRoomInvalid('The service made a room for another game.');
    }
    return _publish(invite.room);
  }

  /// What the room [id] that [expectedHost] invited this account to is for.
  Future<Ps1LockstepInvite> readInvite(String id, {required String expectedHost}) async {
    final invite = _read(await call('GET', _path(id)).timeout(_deadline), id: id);
    if (invite.room.hostId == me || invite.room.hostId != expectedHost) {
      throw const Ps1LockstepRoomInvalid('The invite is not from the room\'s host.');
    }
    return invite;
  }

  /// Joins the room of [invite].
  Future<Ps1LockstepRoom> join(Ps1LockstepInvite invite) async {
    await _requireIdle();
    await call('POST', '${_path(invite.room.id)}/join', {'gameVersion': gameVersion, 'engineBuild': protocol});
    return _publish(invite.room);
  }

  /// Invites the friend [userId] to the room this account hosts.
  Future<void> invite(Ps1LockstepRoom room, String userId) async {
    if (room.hostId != me || userId == me || !_uuid.hasMatch(userId)) {
      throw ArgumentError('A lockstep invite needs a friend and the host account.');
    }
    await call('POST', '${_path(room.id)}/invites', {
      'userIds': [userId],
    }).timeout(_deadline);
  }

  /// The other member, once their launcher published itself in the room; null before.
  Future<Ps1LockstepMember?> peer(Ps1LockstepRoom room, {required String expectedUser}) async {
    final json = await call('GET', _path(room.id));
    if (_read(json, id: room.id).room != room) throw const Ps1LockstepRoomInvalid('The room changed hosts.');
    final members = json['members'];
    if (members is! List || members.isEmpty || members.length > capacity) {
      throw const Ps1LockstepRoomInvalid('This launcher is outside the room.');
    }
    var own = false;
    Ps1LockstepMember? found;
    for (final member in members) {
      if (member is! Map) throw const Ps1LockstepRoomInvalid('The room has a member that is not one.');
      final id = member['userId'];
      final device = member['device'];
      final properties = member['properties'];
      if (id == me) {
        own = true;
      } else if (id != expectedUser) {
        throw const Ps1LockstepRoomInvalid('Someone else entered the private room.');
      } else if (device is String &&
          _uuid.hasMatch(device) &&
          properties is Map &&
          properties['protocol'] == protocol) {
        found = (userId: expectedUser, device: device);
      }
    }
    if (!own) throw const Ps1LockstepRoomInvalid('This launcher left the room.');
    return found;
  }

  /// The STUN and TURN servers for the room's peer connection.
  Future<List<Map<String, dynamic>>> iceServers(Ps1LockstepRoom room) async {
    final response = await call('GET', '${_path(room.id)}/ice-servers').timeout(_deadline);
    final servers = response['iceServers'];
    if (servers is! List) throw const Ps1LockstepRoomInvalid('The room gave no connection settings.');
    return [for (final server in servers) Map<String, dynamic>.from(server as Map)];
  }

  /// Sends [data] to [peer]'s launcher in the room.
  void send(Ps1LockstepRoom room, Ps1LockstepMember peer, Object? data) =>
      signal(peer.userId, peer.device, room.id, 'message', data);

  /// [event]'s signal when it is a `message` from [peer]'s launcher in the room; null otherwise.
  OnlinePeerSignal? receive(Ps1LockstepRoom room, Ps1LockstepMember peer, Map<String, dynamic> event) {
    if (event['sessionId'] != room.id) return null;
    final sender = OnlinePeerSignal.fromEvent(event);
    if (sender == null || sender.kind != 'message' || sender.from != peer.userId || sender.device != peer.device) {
      return null;
    }
    return sender;
  }

  /// Ends the room this account hosts, or leaves the one it joined.
  Future<void> leave(Ps1LockstepRoom room) async {
    final path = _path(room.id);
    if (room.hostId == me) {
      await call('DELETE', path);
    } else {
      await call('POST', '$path/leave');
    }
  }

  Future<void> _leaveQuietly(Ps1LockstepRoom room) async {
    try {
      await leave(room);
    } on Object {
      return;
    }
  }

  /// No other game session for this account: an old one this launcher does not use is ended (as
  /// its host) or left.
  Future<void> _requireIdle() async {
    final session = await _currentSession();
    if (session == null) return;
    final id = session is Map ? session['id'] : null;
    final using = holds;
    if (using == null || id is! String || !_uuid.hasMatch(id) || using(id)) throw const Ps1LockstepRoomBusy();
    final host = (session as Map)['host'];
    final hosted = host is Map && host['userId'] == me;
    try {
      await call(hosted ? 'DELETE' : 'POST', hosted ? _path(id) : '${_path(id)}/leave');
    } on Object {
      throw const Ps1LockstepRoomBusy();
    }
    if (await _currentSession() != null) throw const Ps1LockstepRoomBusy();
  }

  Future<Object?> _currentSession() async => (await call('GET', 'me/game-session').timeout(_deadline))['session'];

  Future<Ps1LockstepRoom> _publish(Ps1LockstepRoom room) async {
    try {
      final json = await call('PUT', '${_path(room.id)}/members/me', {
        'properties': {'protocol': protocol},
      });
      if (_read(json, id: room.id).room != room) throw const Ps1LockstepRoomInvalid('The room changed hosts.');
      return room;
    } on Object {
      await _leaveQuietly(room);
      rethrow;
    }
  }

  static String _path(String id) {
    if (!_uuid.hasMatch(id)) throw ArgumentError('Invalid room ID.');
    return 'game-sessions/$id';
  }

  /// The room [json] describes, checked to be a private lockstep room for two.
  static Ps1LockstepInvite _read(Map<String, dynamic> json, {String? id}) {
    final actual = json['id'];
    final host = json['host'];
    final hostId = host is Map ? host['userId'] : null;
    final properties = json['properties'];
    final disc = properties is Map ? properties['discSha256'] : null;
    final bytes = properties is Map ? properties['discBytes'] : null;
    if (actual is! String ||
        !_uuid.hasMatch(actual) ||
        (id != null && actual != id) ||
        hostId is! String ||
        !_uuid.hasMatch(hostId) ||
        json['kind'] != 'online' ||
        json['gameVersion'] != gameVersion ||
        json['engineBuild'] != protocol ||
        json['capacity'] != capacity ||
        json['joinable'] != false ||
        json['endedAt'] != null ||
        properties is! Map ||
        properties['protocol'] != protocol ||
        disc is! String ||
        !_digest.hasMatch(disc) ||
        json['titleId'] != titleFor(disc) ||
        bytes is! int ||
        bytes < 1) {
      throw const Ps1LockstepRoomInvalid('This is not a PS1 online room.');
    }
    return (room: (id: actual, hostId: hostId), disc: disc, discBytes: bytes);
  }
}
