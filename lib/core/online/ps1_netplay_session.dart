import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'online_wire.dart';
import 'ps1_netplay_identity.dart';
import 'ps1_netplay_wire.dart';

typedef Ps1NetplayFrame = ({int frame, Ps1PadInput input});
typedef Ps1NetplayTick = ({
  int frame,
  int? confirmedFrame,
  int? receivedFrame,
  bool waiting,
  List<Ps1NetplayFrame> local,
  Map<int, String> fingerprints,
});

/// The runner owns frame mutation. Prepare returns once the core is ready at frame zero.
abstract interface class Ps1NetplayRunner {
  Future<void> prepare(int seat);
  Future<void> start();
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame);

  /// Cancels any in-flight preparation and releases the isolated game session.
  Future<void> stop();
}

enum Ps1NetplayPhase { idle, preparing, running, closed }

enum Ps1NetplayEnd { left, peerLeft, disconnected, timedOut, mismatch, desync, protocol, runner }

/// One match between two already authenticated peers. The caller owns the links and calls [pump]
/// on its polling cadence. Only [sendControl] requires reliable ordered delivery.
final class Ps1NetplaySession {
  Ps1NetplaySession({
    required this.seat,
    required this.identity,
    required this.runner,
    required this.sendControl,
    required this.sendInput,
    int? hostEpoch,
    this.timeout = const Duration(seconds: 30),
  }) : _epoch = hostEpoch {
    if ((seat != 0 && seat != 1) ||
        (seat == 0 && (hostEpoch == null || hostEpoch == 0)) ||
        (seat == 1 && hostEpoch != null) ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid PS1 netplay session parameters.');
    }
  }

  static const _protocol = 'anyps5-ps1';
  static const _maxControlBytes = 1024;
  static const _sequenceWindow = 64;
  static const _nativeBatch = 32;
  static const _nativeHistory = 64; // Timeline::kHistory in the Windows runner.
  static const _fingerprintInterval = 120;
  static const _maxFingerprints = 16;
  static final _fingerprintHash = RegExp(r'^[0-9a-f]{16}$');

  final int seat;
  final Ps1NetplayIdentity identity;
  final Ps1NetplayRunner runner;
  final void Function(Uint8List) sendControl;
  final void Function(Uint8List) sendInput;
  final Duration timeout;

  int? _epoch;
  Ps1NetplayPhase _phase = Ps1NetplayPhase.idle;
  Ps1NetplayEnd? _ended;
  Ps1NetplayMismatch? _mismatch;
  int? _desyncFrame;
  Timer? _watchdog;
  final _done = Completer<void>();
  bool _peerIdentified = false;
  bool _preparing = false;
  bool _ready = false;
  bool _peerReady = false;
  bool _startSent = false;
  bool _starting = false;
  bool _syncing = false;
  bool _waiting = false;
  int _frame = 0;
  int? _confirmed;
  int? _received;
  int? _acknowledged;
  int? _lastSent;
  int _sequence = 0;
  int _highestSequence = -1;
  final _seen = <int>{};
  final _remoteHistory = <int, Ps1PadInput>{};
  final _pending = <int, Ps1PadInput>{};
  final _localFingerprints = <int, String>{};
  final _peerFingerprints = <int, String>{};
  int _lastLocalFingerprint = -1;
  int _lastPeerFingerprint = -1;
  String? _lastPeerHash;

  Ps1NetplayPhase get phase => _phase;
  Ps1NetplayEnd? get ended => _ended;
  Ps1NetplayMismatch? get mismatch => _mismatch;
  int? get desyncFrame => _desyncFrame;
  bool get waiting => _waiting;
  int? get confirmedFrame => _confirmed;
  Future<void> get done => _done.future;

  void open() {
    if (_phase != Ps1NetplayPhase.idle) throw StateError('This PS1 match was already opened.');
    _phase = Ps1NetplayPhase.preparing;
    _touch();
    if (seat == 0) _sendControl('hello', identity.toJson());
  }

  void receiveControl(Uint8List bytes) {
    if (_phase == Ps1NetplayPhase.idle || _phase == Ps1NetplayPhase.closed) return;
    if (bytes.length > _maxControlBytes) {
      _close(Ps1NetplayEnd.protocol, notify: true);
      return;
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      _close(Ps1NetplayEnd.protocol, notify: true);
      return;
    }
    if (data is! Map ||
        data['protocol'] != _protocol ||
        data['version'] != Ps1InputWire.version ||
        data['seat'] != 1 - seat ||
        data['epoch'] is! String ||
        data['kind'] is! String) {
      _close(Ps1NetplayEnd.protocol, notify: true);
      return;
    }
    final epoch = OnlineWire.parseUnsigned(data['epoch'] as String);
    final kind = data['kind'] as String;
    final carriesData = kind == 'hello' || kind == 'reject' || kind == 'fingerprint';
    if (epoch == null || epoch == 0 || data.length != (carriesData ? 6 : 5)) {
      _close(Ps1NetplayEnd.protocol, notify: true);
      return;
    }
    if (_epoch != null && epoch != _epoch) return;
    if (kind == 'hello') {
      _hello(epoch, data['data']);
      return;
    }
    if (_epoch == null) return;
    switch (kind) {
      case 'reject':
        final reason = data['data'];
        final field = Ps1NetplayMismatch.values.where((field) => field.name == reason).firstOrNull;
        if (_phase == Ps1NetplayPhase.running || field == null) {
          _close(Ps1NetplayEnd.protocol, notify: true);
        } else {
          _mismatch = field;
          _close(Ps1NetplayEnd.mismatch);
        }
      case 'ready' when _peerIdentified:
        if (_peerReady) return;
        _peerReady = true;
        _touch();
        _maybeStartHost();
      case 'start' when seat == 1 && _ready && _peerReady:
        if (_phase != Ps1NetplayPhase.running && !_starting) {
          _touch();
          unawaited(_start());
        }
      case 'started' when seat == 0 && _startSent:
        if (_phase != Ps1NetplayPhase.running && !_starting) {
          _touch();
          unawaited(_start());
        }
      case 'fingerprint' when _phase == Ps1NetplayPhase.running:
        _receiveFingerprint(data['data']);
      case 'leave':
        _close(Ps1NetplayEnd.peerLeft);
      default:
        _close(Ps1NetplayEnd.protocol, notify: true);
    }
  }

  static bool _validFingerprint(int frame, String hash) =>
      frame >= 0 &&
      frame <= Ps1InputWire.maxFrame &&
      (frame + 1) % _fingerprintInterval == 0 &&
      hash.length == 16 &&
      _fingerprintHash.hasMatch(hash);

  void _receiveFingerprint(Object? value) {
    if (value case [final int frame, final String hash] when _validFingerprint(frame, hash)) {
      if (frame < _lastPeerFingerprint) return;
      if (frame == _lastPeerFingerprint && hash == _lastPeerHash) return;
      if (frame == _lastPeerFingerprint + _fingerprintInterval && _peerFingerprints.length < _maxFingerprints) {
        _lastPeerFingerprint = frame;
        _lastPeerHash = hash;
        _peerFingerprints[frame] = hash;
        _compareFingerprint(frame);
        return;
      }
    }
    _close(Ps1NetplayEnd.protocol, notify: true);
  }

  void _publishFingerprints(Map<int, String> samples, int? confirmed) {
    if (samples.length > _maxFingerprints ||
        samples.entries.any((entry) => entry.key > (confirmed ?? -1) || !_validFingerprint(entry.key, entry.value))) {
      _close(Ps1NetplayEnd.runner, notify: true);
      return;
    }
    final frames = samples.keys.where((frame) => frame > _lastLocalFingerprint).toList()..sort();
    for (final frame in frames) {
      if (frame != _lastLocalFingerprint + _fingerprintInterval) {
        _close(Ps1NetplayEnd.runner, notify: true);
        return;
      }
      if (_localFingerprints.length >= _maxFingerprints) {
        _close(Ps1NetplayEnd.timedOut, notify: true);
        return;
      }
      final hash = samples[frame]!;
      _lastLocalFingerprint = frame;
      _localFingerprints[frame] = hash;
      _sendControl('fingerprint', [frame, hash]);
      if (_phase == Ps1NetplayPhase.closed) return;
      _compareFingerprint(frame);
      if (_phase == Ps1NetplayPhase.closed) return;
    }
    if (_lastLocalFingerprint + _fingerprintInterval <= (confirmed ?? -1)) {
      _close(Ps1NetplayEnd.runner, notify: true);
    }
  }

  void _compareFingerprint(int frame) {
    final local = _localFingerprints[frame];
    final peer = _peerFingerprints[frame];
    if (local == null || peer == null) return;
    _localFingerprints.remove(frame);
    _peerFingerprints.remove(frame);
    if (local != peer) {
      _desyncFrame = frame;
      _close(Ps1NetplayEnd.desync);
    }
  }

  void _hello(int epoch, Object? value) {
    final peer = Ps1NetplayIdentity.tryRead(value);
    if (peer == null) {
      _close(Ps1NetplayEnd.protocol, notify: true);
      return;
    }
    _epoch = epoch;
    if (identity.mismatchWith(peer) case final field?) {
      _mismatch = field;
      _sendControl('reject', field.name);
      _close(Ps1NetplayEnd.mismatch);
      return;
    }
    if (_peerIdentified) return;
    _peerIdentified = true;
    _touch();
    if (seat == 1) _sendControl('hello', identity.toJson());
    if (_phase != Ps1NetplayPhase.closed) unawaited(_prepare());
  }

  Future<void> _prepare() async {
    _preparing = true;
    try {
      await runner.prepare(seat);
      if (_phase == Ps1NetplayPhase.closed) return;
      _ready = true;
      _touch();
      _sendControl('ready');
      _maybeStartHost();
    } on Object {
      _close(Ps1NetplayEnd.runner, notify: true);
    }
  }

  void _maybeStartHost() {
    if (seat != 0 || !_ready || !_peerReady || _startSent || _phase == Ps1NetplayPhase.closed) return;
    _startSent = true;
    _sendControl('start');
  }

  Future<void> _start() async {
    _starting = true;
    try {
      await runner.start();
      if (_phase == Ps1NetplayPhase.closed) return;
      _phase = Ps1NetplayPhase.running;
      _touch();
      if (seat == 1) _sendControl('started');
    } on Object {
      _close(Ps1NetplayEnd.runner, notify: true);
    }
  }

  void receiveInput(Uint8List bytes) {
    if (!_ready || !_peerReady || _phase == Ps1NetplayPhase.closed) return;
    final oldest = _oldestRetained;
    final packet = Ps1InputWire.decode(
      bytes,
      expectedEpoch: _epoch!,
      expectedSeat: 1 - seat,
      oldestFrame: oldest,
      newestFrame: math.min(Ps1InputWire.maxFrame, _frame + _nativeHistory),
      lastSentFrame: _lastSent,
    );
    if (packet == null || packet.sequence <= _highestSequence - _sequenceWindow || !_seen.add(packet.sequence)) return;
    _highestSequence = math.max(packet.sequence, _highestSequence);
    _seen.removeWhere((sequence) => sequence <= _highestSequence - _sequenceWindow);
    for (final (index, input) in packet.inputs.indexed) {
      final frame = packet.firstFrame + index;
      final previous = _remoteHistory[frame];
      if (previous != null) {
        if (previous == input) continue;
        _close(Ps1NetplayEnd.protocol, notify: true);
        return;
      }
      _remoteHistory[frame] = input;
      if (frame > (_received ?? -1)) _pending[frame] = input;
    }
    if (packet.acknowledgedFrame case final ack? when ack > (_acknowledged ?? -1)) {
      _acknowledged = ack;
    }
  }

  // A peer that hasn't received our ACK can resend its oldest unacknowledged
  // frames, carrying a newer ACK for our own inputs.
  int get _oldestRetained => math.max(0, (_received ?? 0) - (_nativeHistory - 1));

  Future<void> pump() async {
    if (_phase != Ps1NetplayPhase.running || _syncing) return;
    _syncing = true;
    try {
      final frames = _pending.keys.toList()..sort();
      final remote = [for (final frame in frames.take(_nativeBatch)) (frame: frame, input: _pending[frame]!)];
      final tick = await runner.sync(remote, _acknowledged);
      if (_phase == Ps1NetplayPhase.closed) return;
      if (tick.frame < _frame ||
          tick.frame > Ps1InputWire.maxFrame ||
          !_validProgress(_confirmed, tick.confirmedFrame) ||
          (tick.confirmedFrame ?? -1) >= tick.frame ||
          !_validProgress(_received, tick.receivedFrame) ||
          tick.local.length > Ps1InputWire.maxInputs) {
        _close(Ps1NetplayEnd.runner, notify: true);
        return;
      }
      _frame = tick.frame;
      // Repeated packets cannot keep a stalled emulation alive.
      if (tick.confirmedFrame != _confirmed) _touch();
      _confirmed = tick.confirmedFrame;
      _received = tick.receivedFrame;
      _waiting = tick.waiting;
      for (final sample in remote) {
        _pending.remove(sample.frame);
      }
      _remoteHistory.removeWhere((frame, _) => frame < _oldestRetained);
      _publishFingerprints(tick.fingerprints, tick.confirmedFrame);
      if (_phase == Ps1NetplayPhase.closed || tick.local.isEmpty) return;
      final firstFrame = tick.local.first.frame;
      if (tick.local.indexed.any((entry) => entry.$2.frame != firstFrame + entry.$1)) {
        _close(Ps1NetplayEnd.runner, notify: true);
        return;
      }
      final bytes = Ps1InputWire.encode(
        Ps1InputPacket(
          epoch: _epoch!,
          seat: seat,
          sequence: _sequence++,
          acknowledgedFrame: _received,
          firstFrame: firstFrame,
          inputs: [for (final sample in tick.local) sample.input],
        ),
      );
      _lastSent = math.max(tick.local.last.frame, _lastSent ?? -1);
      try {
        sendInput(bytes);
      } on Object {
        _close(Ps1NetplayEnd.disconnected);
      }
    } on Object {
      _close(Ps1NetplayEnd.runner, notify: true);
    } finally {
      _syncing = false;
    }
  }

  static bool _validProgress(int? previous, int? next) =>
      next == null ? previous == null : next >= (previous ?? 0) && next <= Ps1InputWire.maxFrame;

  void leave() => _close(Ps1NetplayEnd.left, notify: true);

  void disconnect() => _close(Ps1NetplayEnd.disconnected);

  void _touch() {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, () => _close(Ps1NetplayEnd.timedOut, notify: true));
  }

  void _sendControl(String kind, [Object? data]) {
    try {
      sendControl(_controlBytes(kind, data));
    } on Object {
      _close(Ps1NetplayEnd.disconnected);
    }
  }

  Uint8List _controlBytes(String kind, Object? data) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'protocol': _protocol,
        'version': Ps1InputWire.version,
        'kind': kind,
        'epoch': OnlineWire.unsigned(_epoch!),
        'seat': seat,
        'data': ?data,
      }),
    ),
  );

  void _close(Ps1NetplayEnd reason, {bool notify = false}) {
    if (_phase == Ps1NetplayPhase.closed) return;
    _ended = reason;
    _phase = Ps1NetplayPhase.closed;
    _waiting = false;
    _watchdog?.cancel();
    _pending.clear();
    _remoteHistory.clear();
    _seen.clear();
    _localFingerprints.clear();
    _peerFingerprints.clear();
    if (notify && _epoch != null) {
      try {
        sendControl(_controlBytes('leave', null));
      } on Object {
        // The peer may already be gone.
      }
    }
    unawaited(_stop());
  }

  Future<void> _stop() async {
    try {
      if (_preparing) await runner.stop();
    } on Object {
      // Keep the original terminal reason.
    } finally {
      _done.complete();
    }
  }
}
