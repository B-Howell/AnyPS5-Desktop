import 'dart:async';

import 'online_peer_mesh.dart';
import 'ps1_checkpoint_catchup.dart';
import 'ps1_checkpoint_transfer.dart';
import 'ps1_netplay_identity.dart';
import 'ps1_netplay_session.dart';

enum Ps1NetplaySignalKind { offer, answer, candidate }

/// Signaling payload carried inside an authenticated, one-use room exchange.
final class Ps1NetplaySignal {
  const Ps1NetplaySignal._(this.kind, this.data);

  static const version = 1;
  static const _maxSdp = 64 * 1024;
  static const _maxCandidate = 2048;

  final Ps1NetplaySignalKind kind;
  final Map<String, dynamic> data;

  static Ps1NetplaySignal? tryRead(Object? value) {
    if (value is! Map || value.length != 3 || value['version'] is! int || value['version'] != version) return null;
    final kind = Ps1NetplaySignalKind.values.where((kind) => kind.name == value['kind']).firstOrNull;
    final data = value['data'];
    if (kind == null || data is! Map) return null;
    return _read(kind, data);
  }

  static Ps1NetplaySignal? _read(Ps1NetplaySignalKind kind, Map<dynamic, dynamic> data) {
    if (kind != Ps1NetplaySignalKind.candidate) {
      final sdp = data['sdp'];
      if (data.length != 2 || data['type'] != kind.name || !_validString(sdp, _maxSdp)) return null;
      return Ps1NetplaySignal._(kind, Map.unmodifiable({'type': kind.name, 'sdp': sdp}));
    }

    final candidate = data['candidate'];
    final mid = data['sdpMid'];
    final index = data['sdpMLineIndex'];
    if (data.length != 3 ||
        !data.containsKey('sdpMid') ||
        !data.containsKey('sdpMLineIndex') ||
        !_validString(candidate, _maxCandidate) ||
        (mid != null && !_validString(mid, 64)) ||
        (index != null && (index is! int || index < 0 || index > 65535)) ||
        (mid == null && index == null)) {
      return null;
    }
    return Ps1NetplaySignal._(kind, Map.unmodifiable({'candidate': candidate, 'sdpMid': mid, 'sdpMLineIndex': index}));
  }

  static bool _validString(Object? value, int limit) =>
      value is String && value.isNotEmpty && value.length <= limit && !value.contains('\u0000');

  Map<String, Object> toJson() => {'version': version, 'kind': kind.name, 'data': data};
}

/// Connects one authenticated PS1 match to a dedicated WebRTC peer.
///
/// The caller binds [sendSignal] and [receiveSignal] to the same authorized
/// peer and unique room attempt. A link belongs to this match alone.
/// Seat zero offers. The ordered stream carries PS1 control messages and the
/// unordered game channel carries PS1 inputs.
final class Ps1NetplayPeer {
  Ps1NetplayPeer({
    required GameLink link,
    required Ps1NetplayIdentity identity,
    required Ps1NetplayRunner runner,
    required int seat,
    required this.sendSignal,
    Future<Ps1CheckpointSnapshot> Function()? captureCheckpoint,
    Future<void> Function(Ps1CheckpointSnapshot)? restoreCheckpoint,
    Ps1CatchupSource? catchupSource,
    Ps1CatchupReplay? catchupReplay,
    int? hostEpoch,
    Duration timeout = const Duration(seconds: 30),
  }) : _link = link,
       _timeout = timeout,
       session = Ps1NetplaySession(
         seat: seat,
         identity: identity,
         runner: runner,
         hostEpoch: hostEpoch,
         timeout: timeout,
         captureCheckpoint: captureCheckpoint,
         restoreCheckpoint: restoreCheckpoint,
         catchupSource: catchupSource,
         catchupReplay: catchupReplay,
         sendControl: (bytes) {
           if (!link.sendStream(bytes)) throw StateError('The PS1 control channel closed.');
         },
         sendInput: (bytes) => link.send(bytes),
       ) {
    unawaited(session.done.then((_) => _closeLink()));
  }

  static const _maxCandidates = 64;
  static const _pollInterval = Duration(milliseconds: 8);

  final GameLink _link;
  final Future<void> Function(Ps1NetplaySignal) sendSignal;
  final Duration _timeout;
  final Ps1NetplaySession session;
  final _closed = Completer<void>();
  final _pending = <Ps1NetplaySignal>[];
  final _earlyCandidates = <Map<String, dynamic>>[];
  final _remoteCandidates = <(Object?, Object?, Object?)>{};
  final _localCandidates = <(Object?, Object?, Object?)>{};

  Timer? _poll;
  Timer? _connectTimeout;
  bool _opened = false;
  bool _closing = false;
  bool _receivedDescription = false;
  bool _remoteSet = false;
  bool _draining = false;
  bool _offerSet = false;

  bool get _host => session.seat == 0;
  bool get _finished => _closing || session.phase == Ps1NetplayPhase.closed;
  Future<void> get done => _closed.future;

  Future<void> open() async {
    if (_opened || _finished) throw StateError('This PS1 peer was already opened or closed.');
    _opened = true;
    _link
      ..onStreamMessage = session.receiveControl
      ..onMessage = session.receiveInput
      ..onCandidate = _localCandidate
      ..onState = (state) {
        if (state == 'failed' || state == 'closed') session.disconnect();
      };
    _poll = Timer.periodic(_pollInterval, (_) => _tick());
    _connectTimeout = Timer(_timeout, () {
      if (!_link.streamOpen) session.disconnect();
    });

    if (!_host) {
      session.open();
      unawaited(_drain());
      return;
    }
    try {
      await _link.openChannel();
      if (_finished) return;
      final offer = await _link.createOffer();
      if (_finished) return;
      await _link.setLocal(offer);
      if (_finished) return;
      await _sendDescription(Ps1NetplaySignalKind.offer, offer);
      _offerSet = true;
      unawaited(_drain());
    } on Object {
      session.disconnect();
      rethrow;
    }
  }

  /// Accepts a signal already bound by the caller to this match and peer.
  void receiveSignal(Ps1NetplaySignal signal) {
    if (_finished) return;
    if (signal.kind == Ps1NetplaySignalKind.candidate) {
      if (_remoteCandidates.length >= _maxCandidates || !_remoteCandidates.add(_candidateKey(signal.data))) return;
    } else {
      final expected = _host ? Ps1NetplaySignalKind.answer : Ps1NetplaySignalKind.offer;
      if (_receivedDescription || signal.kind != expected) return;
      _receivedDescription = true;
    }
    _pending.add(signal);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || !_opened || (_host && !_offerSet)) return;
    _draining = true;
    try {
      while (!_finished && _pending.isNotEmpty) {
        final signal = _pending.removeAt(0);
        if (signal.kind == Ps1NetplaySignalKind.candidate) {
          if (_remoteSet) {
            await _addCandidate(signal.data);
          } else {
            _earlyCandidates.add(signal.data);
          }
          continue;
        }
        await _link.setRemote(signal.data);
        if (_finished) return;
        _remoteSet = true;
        for (final candidate in _earlyCandidates) {
          await _addCandidate(candidate);
          if (_finished) return;
        }
        _earlyCandidates.clear();
        if (!_host) {
          final answer = await _link.createAnswer();
          if (_finished) return;
          await _link.setLocal(answer);
          if (_finished) return;
          await _sendDescription(Ps1NetplaySignalKind.answer, answer);
        }
      }
    } on Object {
      session.disconnect();
    } finally {
      _draining = false;
    }
  }

  Future<void> _sendDescription(Ps1NetplaySignalKind kind, Map<String, dynamic> data) {
    final signal = Ps1NetplaySignal._read(kind, data);
    if (signal == null) throw StateError('WebRTC provided an invalid PS1 session description.');
    return sendSignal(signal);
  }

  Future<void> _addCandidate(Map<String, dynamic> data) async {
    try {
      await _link.addCandidate(data);
    } on Object {
      // WebRTC can discard an unusable or superseded candidate.
    }
  }

  static (Object?, Object?, Object?) _candidateKey(Map<String, dynamic> data) =>
      (data['candidate'], data['sdpMid'], data['sdpMLineIndex']);

  void _localCandidate(Map<String, dynamic> data) {
    if (_finished || _localCandidates.length >= _maxCandidates) return;
    final signal = Ps1NetplaySignal._read(Ps1NetplaySignalKind.candidate, {
      'candidate': data['candidate'],
      'sdpMid': data['sdpMid'],
      'sdpMLineIndex': data['sdpMLineIndex'],
    });
    if (signal == null || !_localCandidates.add(_candidateKey(signal.data))) return;
    unawaited(Future.sync(() => sendSignal(signal)).catchError((Object _) => session.disconnect()));
  }

  void _tick() {
    if (_finished || !_link.streamOpen) return;
    _connectTimeout?.cancel();
    if (_host && session.phase == Ps1NetplayPhase.idle) session.open();
    unawaited(session.pump());
  }

  Future<void> leave() {
    session.leave();
    return done;
  }

  Future<void> disconnect() {
    session.disconnect();
    return done;
  }

  Future<void> _closeLink() async {
    _closing = true;
    _poll?.cancel();
    _connectTimeout?.cancel();
    _pending.clear();
    _earlyCandidates.clear();
    try {
      await _link.close();
    } on Object {
      // The transport can already have closed when the peer disconnects.
    } finally {
      _closed.complete();
    }
  }
}
