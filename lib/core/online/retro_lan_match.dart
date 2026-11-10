import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'online_peer.dart';
import 'online_peer_mesh.dart';
import 'online_wire.dart';
import 'retro_lan_bridge.dart';
import 'retro_lan_dhcp.dart';
import 'retro_lan_transport.dart';
import 'retro_online_rooms.dart';

typedef RetroLanGame = ({
  Future<List<Uint8List>?> Function(List<Uint8List>) exchange,
  Future<void> Function() close,
  Future<void> done,
});

enum RetroLanStartupPhase { openingRoom, waitingForPlayer, connecting, startingGame }

/// One private two-player PS2 room, its peer transport, and its embedded game.
final class RetroLanMatch {
  RetroLanMatch({
    required this.rooms,
    required this.links,
    required this.launch,
    this.ownsGame = true,
    this.onStartupChanged,
    this.onRecoveryChanged,
    this.onPathChanged,
    this.recoveryWindow = const Duration(seconds: 8),
  }) {
    if (rooms.spec.mode != RetroOnlineMode.lan || rooms.spec.capacity != 2 || rooms.discDigest == null) {
      throw ArgumentError('A PS2 LAN room needs two seats and a verified disc fingerprint.');
    }
  }

  final RetroOnlineRooms rooms;
  final GameLinks links;
  final Future<RetroLanGame> Function(Uint8List mac) launch;
  final bool ownsGame;
  final void Function()? onStartupChanged;
  final void Function(bool recovering)? onRecoveryChanged;
  final void Function()? onPathChanged;
  final Duration recoveryWindow;
  final _closing = Completer<void>();
  final _done = Completer<void>();
  final _roomCleanupDone = Completer<void>();
  final _early = <Map<String, dynamic>>[];
  Future<RetroRoom>? _entering;
  Future<RetroLanGame>? _launching;
  RetroRoom? _room;
  RetroRoomMember? _peer;
  OnlinePeerMesh? _mesh;
  RetroLanBridge? _bridge;
  Timer? _pump;
  GamePathMonitor? _path;
  bool _recovering = false;
  String? _pendingRoom;
  bool _closed = false;
  bool _gameContinues = false;
  bool remoteEnded = false;
  Object? failure;
  RetroLanStartupPhase _startupPhase = RetroLanStartupPhase.openingRoom;
  RetroLanStartupPhase get startupPhase => _startupPhase;

  Future<void> get done => _done.future;

  /// Room cleanup can outlast the bounded local shutdown wait.
  Future<void> get roomCleanupDone => _roomCleanupDone.future;

  Future<void> get ending => _closing.future;
  bool get closed => _closed;
  bool get gameContinues => _gameContinues;
  bool get attached => !_closed && _bridge != null;
  bool get recovering => !_closed && _recovering;
  GamePathStats? get connectionPath => _path?.sample;

  Future<void> host(String friend) => _open(() => rooms.host(cancelBeforeAdmission: _closing), friend: friend);
  Future<void> join(String id, {String? expectedHost}) => _open(
    () => rooms.join(id, expectedHost: expectedHost, cancelBeforeAdmission: _closing),
    roomId: id,
  );

  Future<T?> _untilClose<T>(Future<T> action) => Future.any<T?>([action, _closing.future.then((_) => null)]);

  void _setStartupPhase(RetroLanStartupPhase phase) {
    _startupPhase = phase;
    onStartupChanged?.call();
  }

  Future<void> _open(Future<RetroRoom> Function() enter, {String? friend, String? roomId}) async {
    if (_closed || _entering != null) throw StateError('This PS2 LAN match has already been opened or closed.');
    _pendingRoom = roomId;
    final entering = _entering = Future.microtask(enter).then((room) => _room = room);
    try {
      final room = await _untilClose(entering);
      if (room == null || _closed) return;
      if (friend != null) await _untilClose(rooms.invite(room, friend));
      if (_closed) return;
      _setStartupPhase(RetroLanStartupPhase.waitingForPlayer);
      final member = await _waitForMember(room, friend ?? room.hostId);
      if (member == null || _closed) return;
      _setStartupPhase(RetroLanStartupPhase.connecting);
      if (_closed) return;
      await _attach(room, member);
    } on Object catch (error) {
      if (_closed) return;
      failure = error;
      await leave();
      rethrow;
    }
  }

  Future<RetroRoomMember?> _waitForMember(RetroRoom room, String expected) async {
    const budget = Duration(minutes: 2);
    final timer = Stopwatch()..start();
    while (!_closed && timer.elapsed < budget) {
      final members = await _untilClose(rooms.peers(room, expectedUser: expected)).timeout(budget - timer.elapsed);
      if (members == null || _closed) return null;
      if (members.singleOrNull case final peer?) return peer;
      await _untilClose(Future<void>.delayed(const Duration(seconds: 1)));
    }
    if (_closed) return null;
    throw StateError('The invited player did not join the PS2 LAN room in time.');
  }

  Future<void> _attach(RetroRoom room, RetroRoomMember peer) async {
    _peer = peer;
    final servers = await _untilClose(rooms.iceServers(room));
    if (servers == null || _closed) return;
    final amHost = rooms.me == room.hostId;
    final mac = amHost ? 0x020000000001 : 0x020000000002;
    final peerMac = amHost ? 0x020000000002 : 0x020000000001;
    final peerAddress = OnlineWire.virtualNetwork + (amHost ? 2 : 1);
    final hash = sha256.convert(utf8.encode(room.id)).bytes;
    final epoch = ByteData.sublistView(Uint8List.fromList(hash)).getUint32(0);
    final mesh = _mesh = OnlinePeerMesh(
      links: links,
      iceServers: servers,
      fixedPeers: true,
      context: OnlinePeerContext(
        call: rooms.call,
        signal: (to, device, id, kind, data) {
          if (to != peer.userId || device != peer.device || id != room.id) return;
          if (!_closed) {
            rooms.signal(to, device, id, kind, data);
          } else if (kind == 'bye' && !remoteEnded) {
            try {
              rooms.signal(to, device, id, kind, data);
            } on Object {
              // The room may already have been released by the peer.
            }
          }
        },
        deliver: (datagram) {
          if (datagram.peer == peerAddress &&
              datagram.kind == DatagramKind.p2p &&
              datagram.peerPort == 0 &&
              datagram.localPort == 0 &&
              datagram.peerVport == 0 &&
              datagram.localVport == 0 &&
              _mesh?.canSendGame(peerAddress) == true) {
            _bridge?.receive(peer.userId, datagram.data);
          }
        },
        peerGone: (_) => unawaited(_failed(StateError('The PS2 LAN game channel closed.'), preserveGame: true)),
      ),
    );
    mesh.update(
      OnlinePeerSession(
        id: room.id,
        me: rooms.me,
        addresses: {rooms.me: OnlineWire.virtualNetwork + (amHost ? 1 : 2), peer.userId: peerAddress},
        devices: {peer.userId: peer.device},
      ),
    );
    for (final event in _early) {
      _receiveSignal(event);
    }
    _early.clear();

    final timer = Stopwatch()..start();
    const deadline = Duration(seconds: 30);
    while (!_closed && !mesh.canSendGame(peerAddress)) {
      if (timer.elapsed > deadline) throw RetroConnectionTimeout(deadline);
      await _untilClose(Future<void>.delayed(const Duration(milliseconds: 12)));
    }
    if (_closed) return;
    _setStartupPhase(RetroLanStartupPhase.startingGame);
    if (_closed) return;
    final launching = _launching = Future.microtask(
      () => launch(Uint8List.fromList([for (var shift = 40; shift >= 0; shift -= 8) (mac >> shift) & 255])),
    );
    final game = await _untilClose(launching);
    if (game == null || _closed) return;
    final bridge = _bridge = RetroLanBridge(
      dhcp: RetroLanDhcp(mac: mac, address: amHost ? 0x0ae70065 : 0x0ae70066),
      segment: RetroLanTransport(
        epoch: epoch == 0 ? 1 : epoch,
        me: rooms.me,
        addresses: {rooms.me: mac, peer.userId: peerMac},
      ),
      exchange: game.exchange,
      peerRoute: () => mesh.gameRouteIdentity(peerAddress),
      send: (_, packet) {
        if (!mesh.canSendGame(peerAddress)) return;
        mesh.send(
          WireDatagram(
            peer: peerAddress,
            peerPort: 0,
            peerVport: 0,
            localPort: 0,
            localVport: 0,
            kind: DatagramKind.p2p,
            data: packet,
          ),
        );
      },
    );
    unawaited(_untilClose(game.done).then((_) => leave(), onError: (Object error) => _failed(error)));
    final path = _path = GamePathMonitor(() => mesh.readGamePath(peerAddress), onPathChanged);
    ({Stopwatch timer, int route})? outage;
    // Allow transient disconnects to recover before restarting ICE. Retry
    // promptly because the native game can end the match during recovery.
    const routeGrace = Duration(seconds: 1);
    const routeRetryInterval = Duration(milliseconds: 750);
    var nextRouteAttempt = routeGrace;
    var lastRoute = mesh.gameRoute(peerAddress);
    _pump = Timer.periodic(const Duration(milliseconds: 8), (_) {
      final route = mesh.gameRoute(peerAddress);
      final routeChanged = route != lastRoute;
      lastRoute = route;
      final connected = mesh.canSendGame(peerAddress);
      if (routeChanged || (!connected && outage == null)) path.clear();
      if (!connected) {
        final interruption = outage ??= (timer: Stopwatch()..start(), route: route);
        final elapsed = interruption.timer.elapsed;
        if (elapsed >= recoveryWindow) {
          unawaited(_failed(StateError('The PS2 LAN game channel did not recover.'), preserveGame: true));
          return;
        }
        if (!_recovering && elapsed >= const Duration(milliseconds: 750)) {
          _recovering = true;
          onRecoveryChanged?.call(true);
        }
        if (elapsed >= nextRouteAttempt) {
          nextRouteAttempt = elapsed + routeRetryInterval;
          unawaited(mesh.restartGameRoute(peerAddress, interruption.route));
        }
      } else {
        if (outage != null || routeChanged) unawaited(path.refresh());
        outage = null;
        nextRouteAttempt = routeGrace;
        if (_recovering) {
          _recovering = false;
          onRecoveryChanged?.call(false);
        }
      }
      unawaited(bridge.pump().catchError((Object error) => _failed(error)));
    });
  }

  Future<void> _failed(Object error, {bool preserveGame = false}) async {
    if (_closed) return;
    failure = error;
    await _end(preserveGame: preserveGame);
  }

  void receive(String type, Map<String, dynamic> event) {
    if (_closed || event['sessionId'] != (_room?.id ?? _pendingRoom) || event['sessionId'] == null) return;
    if (type == 'game_session.member_left' || type == 'game_session.ended') {
      _remoteEnded();
    } else if (type == 'game_session.signal') {
      if (_mesh != null) {
        _receiveSignal(event);
      } else if (_early.length < 65) {
        _early.add(event);
      }
    }
  }

  void _remoteEnded() {
    if (_closed) return;
    remoteEnded = true;
    unawaited(_end(preserveGame: true));
  }

  void _receiveSignal(Map<String, dynamic> event) {
    final signal = OnlinePeerSignal.fromEvent(event);
    final peer = _peer;
    if (signal != null && peer != null && signal.from == peer.userId && signal.device == peer.device) {
      if (signal.kind == 'bye') {
        _remoteEnded();
      } else {
        _mesh?.receive(signal);
      }
    }
  }

  Future<void> leave({bool keepGame = false}) => _end(preserveGame: keepGame);

  Future<void> _end({bool preserveGame = false}) async {
    if (_closed) return done;
    _closed = true;
    _gameContinues = preserveGame && _bridge != null;
    _closing.complete();
    _early.clear();
    _pump?.cancel();
    _path?.close();
    _bridge?.close();
    _mesh?.stop();
    await Future.wait([_releaseRoom().timeout(const Duration(seconds: 8), onTimeout: () {}), _finishGame()]);
    _done.complete();
  }

  Future<void> _releaseRoom() async {
    try {
      await _entering;
      final room = _room;
      if (room != null) await rooms.leave(room);
    } on Object {
      // The room can already be gone after a peer exits.
    } finally {
      _roomCleanupDone.complete();
    }
  }

  Future<void> _finishGame() async {
    try {
      final game = await _launching;
      if (game == null) return;
      await _bridge?.drained;
      if (_gameContinues || !ownsGame) return;
      await game.close();
      await game.done;
    } on Object catch (error) {
      failure ??= error;
    }
  }
}
