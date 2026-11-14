import 'dart:async';
import 'dart:typed_data';

import 'online_peer_mesh.dart';
import 'ps1_lockstep_match.dart';

enum Ps1LockstepSignalKind { offer, answer, candidate }

/// A WebRTC signal between the two launchers of a match, carried as AnyTogether's
/// `game_session.signal` `message` data in the match's room: a session description or one ICE
/// candidate, in the shapes a browser's toJSON() gives them.
final class Ps1LockstepSignal {
  const Ps1LockstepSignal._(this.kind, this.data);

  static const version = 1;
  static const _maxSdp = 64 * 1024;
  static const _maxCandidate = 2048;

  final Ps1LockstepSignalKind kind;
  final Map<String, Object?> data;

  /// The signal [value] holds, or null for anything else.
  static Ps1LockstepSignal? tryRead(Object? value) {
    if (value is! Map || value.length != 3 || value['version'] != version) return null;
    final kind = Ps1LockstepSignalKind.values.where((kind) => kind.name == value['kind']).firstOrNull;
    final data = value['data'];
    if (kind == null || data is! Map) return null;
    return of(kind, data);
  }

  /// A signal of [kind] with [data] as WebRTC gave it, or null when it is not one.
  static Ps1LockstepSignal? of(Ps1LockstepSignalKind kind, Map<Object?, Object?> data) {
    if (kind != Ps1LockstepSignalKind.candidate) {
      final sdp = data['sdp'];
      if (data.length != 2 || data['type'] != kind.name || !_text(sdp, _maxSdp)) return null;
      return Ps1LockstepSignal._(kind, Map.unmodifiable({'type': kind.name, 'sdp': sdp}));
    }
    final candidate = data['candidate'];
    final mid = data['sdpMid'];
    final index = data['sdpMLineIndex'];
    if (data.length != 3 ||
        !data.containsKey('sdpMid') ||
        !data.containsKey('sdpMLineIndex') ||
        !_text(candidate, _maxCandidate) ||
        (mid != null && !_text(mid, 64)) ||
        (index != null && (index is! int || index < 0 || index > 65535)) ||
        (mid == null && index == null)) {
      return null;
    }
    return Ps1LockstepSignal._(kind, Map.unmodifiable({'candidate': candidate, 'sdpMid': mid, 'sdpMLineIndex': index}));
  }

  static bool _text(Object? value, int limit) =>
      value is String && value.isNotEmpty && value.length <= limit && !value.contains('\u0000');

  Map<String, Object?> toJson() => {'version': version, 'kind': kind.name, 'data': data};
}

/// The peer connection of one match, over a [GameLink]: the launcher that invited offers, the
/// friend answers, and signals go through the match's room. Input datagrams go on the link's
/// unordered `game` channel and control messages on its reliable `stream` channel; a connection
/// that fails or closes is the match's [onClosed].
final class Ps1LockstepPeer implements Ps1LockstepLink {
  Ps1LockstepPeer({
    required this.link,
    required this.offering,
    required this.sendSignal,
    this.timeout = const Duration(seconds: 30),
  });

  static const _maxCandidates = 64;

  /// The peer connection, with its `game` and `stream` channels.
  final GameLink link;

  /// Whether this side makes the offer: the host player's launcher.
  final bool offering;
  final Future<void> Function(Ps1LockstepSignal signal) sendSignal;
  final Duration timeout;

  void Function(Uint8List)? _onInput;
  void Function(Uint8List)? _onControl;

  /// Control messages that came before the match took the connection: the other side's hello
  /// can come as soon as the channel opens, and is sent only once.
  final _earlyControl = <Uint8List>[];
  static const _maxEarlyControl = 64;
  void Function()? _onClosed;
  final _open = Completer<void>();
  final _pending = <Ps1LockstepSignal>[];
  final _earlyCandidates = <Map<String, Object?>>[];
  final _remoteCandidates = <(Object?, Object?, Object?)>{};
  final _localCandidates = <(Object?, Object?, Object?)>{};
  bool _receivedDescription = false;
  bool _remoteSet = false;
  bool _draining = false;
  bool _offerSet = false;
  bool _closed = false;
  Timer? _poll;

  /// Connects, and completes once the stream channel is open; throws [TimeoutException] when it
  /// did not open within [timeout], and [StateError] when the connection failed.
  Future<void> open() async {
    link
      ..onMessage = (Uint8List data) {
        _onInput?.call(data);
      }
      ..onStreamMessage = (Uint8List data) {
        final handler = _onControl;
        if (handler != null) {
          handler(data);
        } else if (_earlyControl.length < _maxEarlyControl) {
          _earlyControl.add(data);
        } else {
          _broke();
        }
      }
      ..onCandidate = _localCandidate
      ..onState = (String state) {
        if (state == 'failed' || state == 'closed') _broke();
      };
    _poll = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (link.streamOpen && !_open.isCompleted) _open.complete();
    });
    if (offering) {
      await link.openChannel();
      final offer = await link.createOffer();
      await link.setLocal(offer);
      await _describe(Ps1LockstepSignalKind.offer, offer);
      _offerSet = true;
      unawaited(_drain());
    }
    try {
      await _open.future.timeout(timeout);
    } finally {
      _poll?.cancel();
    }
  }

  /// A signal from the other launcher of this match, already checked to be from them.
  void receiveSignal(Ps1LockstepSignal signal) {
    if (_closed) return;
    if (signal.kind == Ps1LockstepSignalKind.candidate) {
      if (_remoteCandidates.length >= _maxCandidates || !_remoteCandidates.add(_key(signal.data))) return;
    } else {
      final expected = offering ? Ps1LockstepSignalKind.answer : Ps1LockstepSignalKind.offer;
      if (_receivedDescription || signal.kind != expected) return;
      _receivedDescription = true;
    }
    _pending.add(signal);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || (offering && !_offerSet)) return;
    _draining = true;
    try {
      while (!_closed && _pending.isNotEmpty) {
        final signal = _pending.removeAt(0);
        if (signal.kind == Ps1LockstepSignalKind.candidate) {
          if (_remoteSet) {
            await _addCandidate(signal.data);
          } else {
            _earlyCandidates.add(signal.data);
          }
          continue;
        }
        await link.setRemote(Map<String, dynamic>.of(signal.data));
        _remoteSet = true;
        for (final candidate in _earlyCandidates) {
          await _addCandidate(candidate);
        }
        _earlyCandidates.clear();
        if (!offering) {
          final answer = await link.createAnswer();
          await link.setLocal(answer);
          await _describe(Ps1LockstepSignalKind.answer, answer);
        }
      }
    } on Object {
      _broke();
    } finally {
      _draining = false;
    }
  }

  Future<void> _describe(Ps1LockstepSignalKind kind, Map<String, dynamic> data) {
    final signal = Ps1LockstepSignal.of(kind, data);
    if (signal == null) throw StateError('WebRTC gave a session description that cannot be sent.');
    return sendSignal(signal);
  }

  Future<void> _addCandidate(Map<String, Object?> data) async {
    try {
      await link.addCandidate(Map<String, dynamic>.of(data));
    } on Object {
      return;
    }
  }

  static (Object?, Object?, Object?) _key(Map<String, Object?> data) =>
      (data['candidate'], data['sdpMid'], data['sdpMLineIndex']);

  void _localCandidate(Map<String, dynamic> data) {
    if (_closed || _localCandidates.length >= _maxCandidates) return;
    final signal = Ps1LockstepSignal.of(Ps1LockstepSignalKind.candidate, {
      'candidate': data['candidate'],
      'sdpMid': data['sdpMid'],
      'sdpMLineIndex': data['sdpMLineIndex'],
    });
    if (signal == null || !_localCandidates.add(_key(signal.data))) return;
    unawaited(Future.sync(() => sendSignal(signal)).catchError((Object _) => _broke()));
  }

  /// How the other launcher is reached now: directly or through the TURN relay, and the round
  /// trip, as the connection's statistics say.
  Future<PeerPath> path() async {
    try {
      return PeerPath.of(await link.stats());
    } on Object {
      return const PeerPath(PeerRoute.connected);
    }
  }

  void _broke() {
    if (_closed) return;
    if (!_open.isCompleted) _open.completeError(StateError('The connection to the other player failed.'));
    _onClosed?.call();
  }

  @override
  bool sendInput(Uint8List datagram) => !_closed && link.send(datagram);

  @override
  bool sendControl(Uint8List message) => !_closed && link.sendStream(message);

  @override
  set onInput(void Function(Uint8List datagram) handler) => _onInput = handler;

  @override
  set onControl(void Function(Uint8List message) handler) {
    _onControl = handler;
    final early = List.of(_earlyControl);
    _earlyControl.clear();
    early.forEach(handler);
  }

  @override
  set onClosed(void Function() handler) => _onClosed = handler;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    if (!_open.isCompleted) _open.completeError(StateError('The connection was closed.'));
    _open.future.ignore();
    _pending.clear();
    _earlyCandidates.clear();
    try {
      await link.close();
    } on Object {
      return;
    }
  }
}
