part of 'ps1_netplay_peer.dart';

/// Renegotiates only the transport. The ordered and unordered channels, the
/// room binding, and the PS1 input epoch belong to the original match.
final class _Ps1IceRecovery {
  _Ps1IceRecovery({
    required this.link,
    required this.host,
    required this.active,
    required this.disconnect,
    required this.send,
  });

  static const _retryInterval = Duration(milliseconds: 750);
  static const _deadline = Duration(seconds: 8);
  static const _maxCandidates = 64;

  final GameLink link;
  final bool host;
  final bool Function() active;
  final void Function() disconnect;
  final Future<void> Function(Ps1NetplaySignal) send;
  final _localCandidates = <(Object?, Object?, Object?), Ps1NetplaySignal>{};
  final _remoteCandidates = <(Object?, Object?, Object?)>{};
  final _pendingCandidates = <Ps1NetplaySignal>[];
  Future<void> _queue = Future.value();
  int _queued = 0;
  int _route = 0;
  int _failureRevision = 0;
  int? _target;
  Timer? _retryTimer;
  Timer? _timeout;
  bool _haveRemote = true;
  bool _localSet = false;
  Ps1NetplaySignal? _local;
  String? _remoteOffer;

  int get route => _route;
  bool get available => active() && link is RestartableGameLink && link.gameOpen && link.streamOpen;

  void request() {
    _failureRevision++;
    if (_target != null) return;
    _begin(_route + 1);
    _enqueue(_retry);
  }

  void receive(Ps1NetplaySignal signal) {
    if (!available || signal.route < _route || signal.route > _route + 1) return;
    _enqueue(() => _receive(signal));
  }

  void localCandidate(Map<String, dynamic> data) {
    if (_localCandidates.length >= _maxCandidates) return;
    final signal = Ps1NetplaySignal._read(Ps1NetplaySignalKind.candidate, {
      'candidate': data['candidate'],
      'sdpMid': data['sdpMid'],
      'sdpMLineIndex': data['sdpMLineIndex'],
    }, route: _route);
    if (signal == null) return;
    final key = _candidateKey(signal);
    if (_localCandidates.containsKey(key)) return;
    _localCandidates[key] = signal;
    unawaited(_transmit(signal));
  }

  void _begin(int target) {
    if (_target == target) return;
    _target = target;
    if (_retryTimer != null) return;
    _retryTimer = Timer.periodic(_retryInterval, (_) {
      if (_queued == 0) _enqueue(_retry);
    });
    _timeout = Timer(_deadline, () {
      close();
      if (active()) disconnect();
    });
  }

  void _enqueue(Future<void> Function() action) {
    if (_queued >= 2 * _maxCandidates + 4) return;
    _queued++;
    _queue = _queue.then((_) async {
      try {
        if (available) await action();
      } on Object {
        // The deadline bounds failed SDP/plugin operations. Signaling can
        // be retried without creating another match or another peer link.
      } finally {
        _queued--;
      }
    });
  }

  Future<void> _retry() async {
    final target = _target;
    if (target == null || await _checkConnected()) return;
    if (host) {
      if (_route < target) {
        await _offer();
      } else {
        await _replay();
      }
    } else {
      await _transmit(Ps1NetplaySignal._(Ps1NetplaySignalKind.restart, const {}, target));
    }
  }

  Future<void> _receive(Ps1NetplaySignal signal) async {
    final route = signal.route;
    if (route < _route || route > _route + 1) return;
    switch (signal.kind) {
      case Ps1NetplaySignalKind.restart when host:
        if (route == _route) {
          await _replay();
        } else if (_haveRemote) {
          _begin(route);
          await _offer();
        }
      case Ps1NetplaySignalKind.offer when !host:
        final sdp = signal.data['sdp'] as String;
        if (route == _route) {
          if (sdp == _remoteOffer) await _answer();
          return;
        }
        _begin(route);
        await link.setRemote(signal.data);
        if (!available) return;
        _advance(route);
        _remoteOffer = sdp;
        await _remoteReady();
        if (!available) return;
        await _answer();
      case Ps1NetplaySignalKind.answer when host && route == _route && !_haveRemote && _localSet:
        await link.setRemote(signal.data);
        if (!available) return;
        await _remoteReady();
        await _checkConnected();
      case Ps1NetplaySignalKind.candidate:
        if (route == _route && _haveRemote) {
          await _addCandidate(signal);
        } else if ((route == _route || !host) &&
            _pendingCandidates.length < _maxCandidates &&
            !_pendingCandidates.any(
              (queued) => queued.route == route && _candidateKey(queued) == _candidateKey(signal),
            )) {
          _pendingCandidates.add(signal);
        }
      default:
        break;
    }
  }

  Future<void> _offer() async {
    await (link as RestartableGameLink).restartIce();
    if (!available) return;
    final offer = await link.createOffer();
    if (!available) return;
    _advance(_route + 1);
    await _describe(Ps1NetplaySignalKind.offer, offer);
  }

  Future<void> _answer() async {
    if (_local == null) {
      await _describe(Ps1NetplaySignalKind.answer, await link.createAnswer());
    } else {
      await _replay();
    }
    await _checkConnected();
  }

  void _advance(int route) {
    _route = route;
    _local = null;
    _localSet = false;
    _haveRemote = false;
    _remoteOffer = null;
    _localCandidates.clear();
    _remoteCandidates.clear();
    _pendingCandidates.removeWhere((candidate) => candidate.route != route);
  }

  Future<void> _describe(Ps1NetplaySignalKind kind, Map<String, dynamic> data) async {
    if (!available) return;
    final signal = Ps1NetplaySignal._read(kind, data, route: _route);
    if (signal == null) throw StateError('Invalid PS1 ICE description.');
    _local = signal;
    await _replay();
  }

  Future<void> _replay() async {
    final description = _local;
    if (description == null || !available) return;
    if (!_localSet) {
      await link.setLocal(description.data);
      if (!available) return;
      _localSet = true;
    }
    await _transmit(description);
    for (final candidate in _localCandidates.values.toList()) {
      await _transmit(candidate);
    }
  }

  Future<void> _transmit(Ps1NetplaySignal signal) async {
    if (!available) return;
    try {
      await send(signal);
    } on Object {
      // A gateway can drop a signal during the route change.
    }
  }

  Future<void> _remoteReady() async {
    _haveRemote = true;
    final pending = _pendingCandidates.toList();
    _pendingCandidates.clear();
    for (final candidate in pending) {
      if (!available) return;
      if (candidate.route == _route) await _addCandidate(candidate);
    }
  }

  Future<void> _addCandidate(Ps1NetplaySignal signal) async {
    if (_remoteCandidates.length >= _maxCandidates || !_remoteCandidates.add(_candidateKey(signal))) return;
    try {
      await link.addCandidate(signal.data);
    } on Object {
      // WebRTC may reject a superseded candidate.
    }
  }

  static (Object?, Object?, Object?) _candidateKey(Ps1NetplaySignal signal) =>
      (signal.data['candidate'], signal.data['sdpMid'], signal.data['sdpMLineIndex']);

  Future<bool> _checkConnected() async {
    if (!available || _target != _route || !_haveRemote || !_localSet) return false;
    final revision = _failureRevision;
    if (!await (link as RestartableGameLink).routeConnected() || !available || revision != _failureRevision) {
      return false;
    }
    close();
    return true;
  }

  void close() {
    _target = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _timeout?.cancel();
    _timeout = null;
  }
}
