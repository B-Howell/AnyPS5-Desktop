import 'dart:async';
import 'dart:math';

import 'online_peer_mesh.dart';
import 'ps1_checkpoint_catchup.dart';
import 'ps1_checkpoint_transfer.dart';
import 'ps1_netplay_identity.dart';
import 'ps1_netplay_peer.dart';
import 'ps1_netplay_session.dart';
import 'retro_online_rooms.dart';

/// One room and one peer link. Subscribe to gateway events before opening.
final class Ps1NetplayMatch {
  Ps1NetplayMatch({
    required this.rooms,
    required this.links,
    required this.identity,
    required this.runner,
    this.captureCheckpoint,
    this.restoreCheckpoint,
    this.catchupSource,
    this.catchupReplay,
    this.onStatusChanged,
  });

  final RetroOnlineRooms rooms;
  final GameLinks links;
  final Ps1NetplayIdentity identity;
  final Ps1NetplayRunner runner;
  final Future<Ps1CheckpointSnapshot> Function()? captureCheckpoint;
  final Future<void> Function(Ps1CheckpointSnapshot)? restoreCheckpoint;
  final Ps1CatchupSource? catchupSource;
  final Ps1CatchupReplay? catchupReplay;
  final void Function()? onStatusChanged;
  final _closing = Completer<void>();
  final _done = Completer<void>();
  final _signals = <Map<String, dynamic>>[];
  Future<RetroRoom>? _entering;
  RetroRoom? _room;
  String? _joining;
  String? _invitedFriend;
  RetroRoomMember? _member;
  Ps1NetplayPeer? _peer;
  bool _closed = false;

  Future<void> get done => _done.future;
  Ps1NetplaySession? get session => _peer?.session;
  bool get closed => _closed;

  Future<void> host(String friendId) => _open(0, rooms.host, friendId: friendId);

  Future<void> join(String roomId) => _open(1, () => rooms.join(roomId), roomId: roomId);

  Future<void> _open(int seat, Future<RetroRoom> Function() enter, {String? friendId, String? roomId}) async {
    if (_closed || _entering != null) throw StateError('This PS1 match has already been opened or closed.');
    _joining = roomId;
    _invitedFriend = friendId;
    final entering = _entering = Future.sync(enter).then((room) => _room = room);
    try {
      await _connect(seat, await entering, friendId);
    } on Object {
      await leave();
      rethrow;
    }
  }

  Future<T?> _untilClose<T>(Future<T> action) => Future.any<T?>([action, _closing.future.then((_) => null)]);

  Future<void> _connect(int seat, RetroRoom room, String? friendId) async {
    if (_closed) return;
    if (friendId != null) await _untilClose(rooms.invite(room, friendId));
    final expected = friendId ?? room.hostId;
    final elapsed = Stopwatch()..start();
    const wait = Duration(minutes: 2);
    RetroRoomMember? member;
    while (!_closed && elapsed.elapsed < wait) {
      final peers = await _untilClose(rooms.peers(room, expectedUser: expected)).timeout(wait - elapsed.elapsed);
      if (peers == null || _closed) return;
      member = peers.singleOrNull;
      if (member != null) break;
      await _untilClose(Future<void>.delayed(const Duration(seconds: 1)));
    }
    if (_closed) return;
    if (member == null) throw StateError('The other player did not join the PS1 room in time.');
    final bound = _member = member;
    final servers = await _untilClose(rooms.iceServers(room));
    if (servers == null || _closed) return;
    final link = await Future.any<GameLink?>([
      links.link(servers).then((link) async {
        if (!_closed) return link;
        await link.close();
        return null;
      }),
      _closing.future.then((_) => null),
    ]);
    if (link == null) return;
    if (_closed) {
      await link.close();
      return;
    }
    final peer = _peer = Ps1NetplayPeer(
      link: link,
      identity: identity,
      runner: runner,
      captureCheckpoint: seat == 0 ? captureCheckpoint : null,
      restoreCheckpoint: seat == 1 ? restoreCheckpoint : null,
      catchupSource: seat == 0 ? catchupSource : null,
      catchupReplay: seat == 1 ? catchupReplay : null,
      onStatusChanged: onStatusChanged,
      seat: seat,
      hostEpoch: seat == 0 ? Random.secure().nextInt(0x7fffffff) + 1 : null,
      sendSignal: (message) async => rooms.send(room, bound, message.toJson()),
    );
    unawaited(peer.done.then((_) => leave()));
    for (final event in _signals) {
      final signal = Ps1NetplaySignal.tryRead(rooms.receive(room, bound, event)?.data);
      if (signal != null) peer.receiveSignal(signal);
    }
    _signals.clear();
    await Future.any([peer.open(), done]);
  }

  void receive(String type, Map<String, dynamic> event) {
    final id = _room?.id ?? _joining;
    if (_closed || id == null || event['sessionId'] != id) return;
    if (type == 'game_session.ended' || type == 'game_session.member_left') {
      unawaited(leave());
    } else if (type == 'game_session.signal') {
      final peer = _peer;
      if (peer == null) {
        final expected = _invitedFriend ?? _room?.hostId;
        if (_signals.length < 65 &&
            (expected == null || event['from'] == expected) &&
            event['kind'] == 'message' &&
            Ps1NetplaySignal.tryRead(event['data']) != null) {
          _signals.add(event);
        }
        return;
      }
      final signal = Ps1NetplaySignal.tryRead(rooms.receive(_room!, _member!, event)?.data);
      if (signal != null) peer.receiveSignal(signal);
    }
  }

  Future<void> leave() async {
    if (_closed) return done;
    _closed = true;
    _closing.complete();
    _signals.clear();
    try {
      // Wait for any in-flight creation so it cannot leave a room behind.
      final peer = _peer;
      if (peer == null) {
        onStatusChanged?.call();
        try {
          await _entering;
        } on Object {
          // The caller that opened the room receives the connection failure.
        }
      } else {
        await peer.leave();
      }
    } finally {
      try {
        final room = _room;
        if (room != null) await rooms.leave(room);
      } on Object {
        // The other player or the gateway may have ended the room first.
      } finally {
        _done.complete();
      }
    }
  }
}
