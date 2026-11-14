import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../retro_host/retro_lockstep.dart';
import '../retro_host/retro_pad.dart';
import 'ps1_lockstep_control.dart';
import 'ps1_netplay_wire.dart';

/// The two channels of the peer connection a match runs on: input datagrams, unordered and
/// without resends, and control messages, reliable and in order ([Ps1LockstepMessage]).
abstract interface class Ps1LockstepLink {
  /// Sends one input datagram; false when it could not be sent now.
  bool sendInput(Uint8List datagram);

  /// Sends one control message; false when the connection is gone.
  bool sendControl(Uint8List message);

  set onInput(void Function(Uint8List datagram) handler);
  set onControl(void Function(Uint8List message) handler);

  /// The connection broke or was closed by the other side.
  set onClosed(void Function() handler);

  Future<void> close();
}

/// Where a match stands.
enum Ps1LockstepPhase {
  /// Each launcher says what it plays with, and the host player's measures the round trip.
  checking,

  /// The friend's launcher starts the game; the host player's game waits.
  preparing,

  /// The host player's game is held and its state goes to the friend.
  transferring,

  /// Both games run frame for frame.
  playing,

  /// The match is over; [Ps1LockstepMatch.end] says how.
  ended,
}

/// How a match ended.
enum Ps1LockstepEnd {
  /// This player left.
  left,

  /// The other player left.
  peerLeft,

  /// The connection broke.
  disconnected,

  /// Nothing came from the other player for [Ps1LockstepMatch.silenceLimit].
  timedOut,

  /// The two launchers do not play with the same disc, core, BIOS or host ([Ps1LockstepMatch.mismatch]).
  mismatch,

  /// The round trip needs more than [Ps1LockstepMatch.maxDelay] frames of input delay.
  tooSlow,

  /// The two games stopped being alike: their main RAM differed after the same frame.
  desync,

  /// This player's emulator host refused a lockstep step (its game ended, or a state could not be
  /// saved or loaded).
  hostFailed,

  /// The other launcher broke the match's rules.
  protocol,
}

/// What two launchers' hellos disagree on, first in this order.
enum Ps1LockstepMismatch { host, core, disc, discName, bios }

/// What this launcher plays the match with ([Ps1LockstepHello] without the options).
class Ps1LockstepIdentity {
  const Ps1LockstepIdentity({
    required this.hostVersion,
    required this.system,
    required this.core,
    required this.disc,
    required this.discName,
    required this.bios,
  });

  final String hostVersion;

  /// The system the launcher runs on, as `Platform.operatingSystem` names it.
  final String system;
  final String core;
  final String disc;
  final String discName;
  final String bios;

  Ps1LockstepHello hello(Map<String, String> options) => Ps1LockstepHello(
    hostVersion: hostVersion,
    system: system,
    core: core,
    disc: disc,
    discName: discName,
    bios: bios,
    options: options,
  );

  /// The first thing [theirs] plays with differently, or null when both match. The SwanStation
  /// libraries are compared only on the same system: a Windows and a Linux build of the same
  /// source are different files, and nothing the host says yet names the build they come from.
  Ps1LockstepMismatch? against(Ps1LockstepHello theirs) => switch (theirs) {
    _ when theirs.hostVersion != hostVersion => Ps1LockstepMismatch.host,
    _ when theirs.system == system && theirs.core != core => Ps1LockstepMismatch.core,
    _ when theirs.disc != disc => Ps1LockstepMismatch.disc,
    _ when theirs.discName != discName => Ps1LockstepMismatch.discName,
    _ when theirs.bios != bios => Ps1LockstepMismatch.bios,
    _ => null,
  };
}

/// One PS1 online match between two launchers, each with its own emulator host, in lockstep
/// (anyps5-retro-host docs/netplay.md): the host player (port 1) holds the game they are playing,
/// saves its state and sends it; the friend (port 2) starts the same game with the host player's
/// options, loads that state, and from then on both hosts run each frame only once both players'
/// input for it is known. Each launcher's input for frame n + [delay] goes out while its host runs
/// frame n, so the round trip is hidden behind the delay. Main RAM hashes are compared every
/// [compareEvery] frames, and the match ends at the first difference.
///
/// The match owns the lockstep of its host, not the game: when it ends, a host still in lockstep
/// leaves it, so the host player's game goes on alone, and the caller stops the friend's.
class Ps1LockstepMatch {
  Ps1LockstepMatch({
    required this.hosting,
    required this.link,
    required this.identity,
    required this.work,
    required this.localInput,
    required this.paused,
    this.host,
    this.options = const {},
    this.prepareGuest,
    this.onChanged,
    this.tick = const Duration(milliseconds: 4),
    this.connectLimit = const Duration(seconds: 60),
    this.silenceLimit = const Duration(seconds: 15),
    this.compareEvery = 60,
    this.pings = 5,
    Random? random,
  }) : _random = random ?? Random.secure() {
    if (hosting && host == null) throw ArgumentError('The host player needs the running game.');
    if (!hosting && prepareGuest == null) throw ArgumentError('The friend needs a way to start the game.');
  }

  /// The most input delay a match plays with; slower connections are refused (netplay.md).
  static const maxDelay = 8;

  /// A frame of a PS1 game at its 60 Hz.
  static const frameTime = Duration(microseconds: 16667);

  /// Steps queued ahead of the frame the host ran, beyond the delay: far below the 600 the host
  /// holds.
  static const _ahead = 8;

  /// Input frames one datagram carries ([Ps1InputWire.maxInputs]); up to [_maxDatagrams] go out
  /// per tick while the other side has not acknowledged them.
  static const _maxDatagrams = 4;

  /// RAM hashes of the other player's not yet compared: its game runs at most the delay and a few
  /// frames ahead, so a few comparisons at most wait.
  static const _maxWaitingHashes = 8;

  /// How often a launcher with nothing new to send still sends its newest input.
  static const _heartbeat = Duration(milliseconds: 250);

  /// Whether this launcher is the host player's: it holds the game, sends the state and plays
  /// port 1.
  final bool hosting;
  final Ps1LockstepLink link;
  final Ps1LockstepIdentity identity;

  /// A folder of this match's own, for the state file; deleted when the match ends.
  final Directory work;

  /// This player's controller now.
  final RetroPadInput Function() localInput;

  /// Whether this player's game is paused now (its menu is open): the other player is told.
  final bool Function() paused;

  /// The host player's game; the friend's comes from [prepareGuest].
  RetroLockstepHost? host;

  /// The core options of the host player's game, sent to the friend.
  final Map<String, String> options;

  /// Starts the friend's game with the host player's hello (its options), with a `saves` folder
  /// of the match's own, and gives its host once its `status` is ready; null when it could not.
  final Future<RetroLockstepHost?> Function(Ps1LockstepHello theirs)? prepareGuest;

  /// Something shown changed: the phase, the other player pausing, the end.
  final void Function()? onChanged;

  final Duration tick;
  final Duration connectLimit;
  final Duration silenceLimit;
  final int compareEvery;
  final int pings;
  final Random _random;

  Ps1LockstepPhase get phase => _phase;
  Ps1LockstepPhase _phase = Ps1LockstepPhase.checking;

  Ps1LockstepEnd? get end => _end;
  Ps1LockstepEnd? _end;

  /// What did not match, when the match ended with [Ps1LockstepEnd.mismatch].
  Ps1LockstepMismatch? get mismatch => _mismatch;
  Ps1LockstepMismatch? _mismatch;

  /// The input delay in frames, once the host player's launcher chose it.
  int? get delay => _delay;
  int? _delay;

  /// The round trip the host player's launcher measured, in milliseconds.
  int? get roundTripMs => _roundTripMs;
  int? _roundTripMs;

  /// Whether the other player's game is paused.
  bool get peerPaused => _peerPaused;
  bool _peerPaused = false;

  /// The newest frame both games ran with matching RAM.
  int? get lastMatched => _lastMatched;
  int? _lastMatched;

  /// The port this launcher's player plays: 0 for the host player, 1 for the friend.
  int get port => hosting ? 0 : 1;
  int get _peerPort => 1 - port;

  Future<void> get done => _done.future;
  final _done = Completer<void>();

  final _theirHello = Completer<Ps1LockstepHello>();
  final _ending = <Completer<Object?>>[];
  final _pongs = <int, Completer<void>>{};
  final _chunks = <Uint8List>[];
  Ps1LockstepStart? _start;
  final _startCame = Completer<Ps1LockstepStart>();
  final _stateCame = Completer<Uint8List>();
  final _loaded = Completer<int>();

  Timer? _timer;
  StreamSubscription<RetroSync>? _syncs;
  DateTime _heard = DateTime.now();

  int _epoch = 0;
  int _first = 0;
  final _local = <int, RetroPadInput>{};
  final _remote = <int, RetroPadInput>{};
  int _produced = -1;
  int _remoteHave = -1;
  int _peerAck = -1;
  int _nextStep = 0;
  int _ran = -1;
  int _sequence = 0;
  int _sentUpTo = -1;
  bool _sentPaused = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  final _ourHashes = <int, String>{};
  final _theirHashes = <int, String>{};

  /// Begins the match on an open [link].
  Future<void> run() async {
    link
      ..onInput = _onInput
      ..onControl = _onControl
      ..onClosed = () => _finish(Ps1LockstepEnd.disconnected);
    try {
      await _guard(_begin());
    } on _Ended {
      return;
    } on Object {
      _finish(Ps1LockstepEnd.hostFailed);
    }
  }

  /// This player leaves: the other player is told, and this host leaves lockstep.
  Future<void> leave() async {
    if (_end != null) return done;
    link.sendControl(const Ps1LockstepLeave().encode());
    _finish(Ps1LockstepEnd.left);
    return done;
  }

  /// [work]'s result while the match goes on: a match that ended meanwhile stops its caller,
  /// whether [work] finished first or not.
  Future<T> _guard<T>(Future<T> work) async {
    final ended = Completer<T>();
    _ending.add(ended);
    final result = await Future.any([work, ended.future]);
    if (_end != null) throw const _Ended();
    return result;
  }

  Future<T> _within<T>(Future<T> work) =>
      _guard(work.timeout(connectLimit, onTimeout: () => throw _finish(Ps1LockstepEnd.timedOut)));

  Future<void> _begin() async {
    _send(identity.hello(hosting ? options : const {}));
    final theirs = await _within(_theirHello.future);
    if (hosting) {
      await _hostMatch();
    } else {
      await _joinMatch(theirs);
    }
    _play();
  }

  Future<void> _hostMatch() async {
    final samples = <int>[];
    for (var id = 0; id < pings; id++) {
      final pong = _pongs[id] = Completer<void>();
      final sent = DateTime.now();
      _send(Ps1LockstepPing(id));
      await _within(pong.future);
      samples.add(DateTime.now().difference(sent).inMicroseconds);
    }
    samples.sort();
    final roundTrip = samples[samples.length ~/ 2];
    _roundTripMs = (roundTrip / 1000).round();
    final delay = delayFor(Duration(microseconds: roundTrip));
    if (delay == null) throw _finish(Ps1LockstepEnd.tooSlow);
    _delay = delay;
    _setPhase(Ps1LockstepPhase.transferring);
    final game = host!;
    final frame = await _guard(game.lockstep(const RetroLockstepSettings(check: 1)));
    if (frame == null) throw _finish(Ps1LockstepEnd.hostFailed);
    work.createSync(recursive: true);
    final file = File(p.join(work.path, 'match.state'));
    final saved = await _guard(game.saveState(file.path));
    if (saved == null) throw _finish(Ps1LockstepEnd.hostFailed);
    final state = await _guard(file.readAsBytes());
    if (state.length != saved.bytes) throw _finish(Ps1LockstepEnd.hostFailed);
    final packed = Uint8List.fromList(gzip.encode(state));
    final chunks = <Uint8List>[
      for (var at = 0; at < packed.length; at += Ps1LockstepChunk.maxBytes)
        Uint8List.sublistView(packed, at, min(at + Ps1LockstepChunk.maxBytes, packed.length)),
    ];
    do {
      _epoch = _random.nextInt(1 << 32) << 32 | _random.nextInt(1 << 32);
    } while (_epoch == 0);
    _first = saved.frame;
    _send(
      Ps1LockstepStart(
        frame: saved.frame,
        delay: delay,
        epoch: _epoch,
        bytes: state.length,
        sha256: sha256.convert(state).toString(),
        chunks: chunks.length,
      ),
    );
    for (final (index, chunk) in chunks.indexed) {
      _send(Ps1LockstepChunk(index, chunk));
    }
    final loaded = await _within(_loaded.future);
    if (loaded != saved.frame) throw _finish(Ps1LockstepEnd.protocol);
  }

  Future<void> _joinMatch(Ps1LockstepHello theirs) async {
    _setPhase(Ps1LockstepPhase.preparing);
    final prepared = prepareGuest!(theirs)..ignore();
    final start = await _within(_startCame.future);
    _delay = start.delay;
    _epoch = start.epoch;
    _first = start.frame;
    final game = host = await _within(prepared);
    if (game == null) throw _finish(Ps1LockstepEnd.hostFailed);
    _setPhase(Ps1LockstepPhase.transferring);
    final packed = await _within(_stateCame.future);
    final state = inflate(packed, start.bytes);
    if (state == null || sha256.convert(state).toString() != start.sha256) throw _finish(Ps1LockstepEnd.protocol);
    work.createSync(recursive: true);
    final file = File(p.join(work.path, 'match.state'));
    await _guard(file.writeAsBytes(state, flush: true));
    if (await _guard(game.lockstep(const RetroLockstepSettings(check: 1))) == null) {
      throw _finish(Ps1LockstepEnd.hostFailed);
    }
    final loaded = await _guard(game.loadState(file.path));
    if (loaded == null || loaded.frame != start.frame) throw _finish(Ps1LockstepEnd.hostFailed);
    _send(Ps1LockstepLoaded(loaded.frame));
  }

  /// The gzip data [packed] inflated, when it is exactly [bytes] long; null for data that is not
  /// gzip or inflates to another size. Inflating stops as soon as it passes [bytes], so data from
  /// the other player cannot take more memory than the state it announced.
  static Uint8List? inflate(Uint8List packed, int bytes) {
    final out = BytesBuilder(copy: false);
    var tooLong = false;
    final input = gzip.decoder.startChunkedConversion(
      _LimitedSink((chunk) {
        if (tooLong) return;
        if (out.length + chunk.length > bytes) {
          tooLong = true;
          return;
        }
        out.add(chunk);
      }),
    );
    try {
      for (var at = 0; at < packed.length && !tooLong; at += 16 * 1024) {
        input.add(Uint8List.sublistView(packed, at, min(at + 16 * 1024, packed.length)));
      }
      if (!tooLong) input.close();
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
    if (tooLong || out.length != bytes) return null;
    return out.takeBytes();
  }

  /// The input delay for a round trip: half of it in frames, rounded up, and one more; null above
  /// [maxDelay] (netplay.md "Lockstep first, rollback after").
  static int? delayFor(Duration roundTrip) {
    final frames = (roundTrip.inMicroseconds / 2 / frameTime.inMicroseconds).ceil() + 1;
    return frames > maxDelay ? null : frames;
  }

  void _play() {
    if (_end != null) return;
    final delay = _delay!;
    _nextStep = _first;
    _ran = _first - 1;
    for (var frame = _first; frame < _first + delay; frame++) {
      _local[frame] = RetroPadInput.idle;
      _remote[frame] = RetroPadInput.idle;
    }
    _produced = _first + delay - 1;
    _remoteHave = _produced;
    _peerAck = _produced;
    _sentUpTo = _produced;
    _heard = DateTime.now();
    _syncs = host!.syncs.listen(_onSync);
    _setPhase(Ps1LockstepPhase.playing);
    _timer = Timer.periodic(tick, (_) => _onTick());
    _onTick();
  }

  void _onTick() {
    if (_end != null) return;
    final now = DateTime.now();
    if (now.difference(_heard) > silenceLimit) {
      _finish(Ps1LockstepEnd.timedOut);
      return;
    }
    final pausedNow = paused();
    if (pausedNow != _sentPaused) {
      _sentPaused = pausedNow;
      _send(Ps1LockstepPause(paused: pausedNow));
    }
    _produce();
    _sendInputs(now);
    _pump();
  }

  /// This player's input for every frame up to the delay past the newest frame the host ran.
  void _produce() {
    final until = _ran + 1 + _delay!;
    while (_produced < until) {
      _produced++;
      _local[_produced] = localInput();
    }
  }

  /// Every input the other side has not acknowledged, in datagrams of up to eight frames: at once
  /// when there is a new one, again each frame while one is not acknowledged, and the newest
  /// every quarter of a second when all are, so the other side hears from this one.
  void _sendInputs(DateTime now) {
    var from = _peerAck + 1;
    final since = now.difference(_lastSent);
    if (from > _produced) {
      if (since < _heartbeat) return;
      from = _produced;
    } else if (_produced <= _sentUpTo && since < frameTime) {
      return;
    }
    _sentUpTo = _produced;
    for (var count = 0; count < _maxDatagrams && from <= _produced; count++) {
      final last = min(from + Ps1InputWire.maxInputs - 1, _produced);
      final datagram = Ps1InputWire.encode(
        Ps1InputPacket(
          epoch: _epoch,
          seat: port,
          sequence: _sequence = (_sequence + 1) & 0xFFFFFFFF,
          acknowledgedFrame: _remoteHave,
          firstFrame: from,
          inputs: [for (var frame = from; frame <= last; frame++) _record(_local[frame]!)],
        ),
      );
      link.sendInput(datagram);
      _lastSent = now;
      from = last + 1;
    }
  }

  /// Steps for every frame both inputs are known for, a little ahead of the host.
  void _pump() {
    final game = host;
    if (game == null) return;
    while (_nextStep <= _ran + 1 + _delay! + _ahead) {
      final mine = _local[_nextStep];
      final theirs = _remote[_nextStep];
      if (mine == null || theirs == null) return;
      final ports = hosting ? [mine, theirs] : [theirs, mine];
      try {
        game.step(RetroStep(_nextStep, ports));
      } on Object {
        _finish(Ps1LockstepEnd.hostFailed);
        return;
      }
      _nextStep++;
    }
  }

  void _onSync(RetroSync sync) {
    if (_end != null || sync.frame < _first) return;
    _ran = max(_ran, sync.frame);
    _remote.remove(sync.frame);
    final kept = min(_ran, _peerAck);
    _local.removeWhere((frame, _) => frame <= kept);
    final ram = sync.ram;
    if (ram != null && (sync.frame - _first) % compareEvery == 0) {
      _ourHashes[sync.frame] = ram;
      _send(Ps1LockstepHash(sync.frame, ram));
      _compare(sync.frame);
    }
    _produce();
    _pump();
  }

  void _compare(int frame) {
    final ours = _ourHashes[frame];
    final theirs = _theirHashes[frame];
    if (ours == null || theirs == null) return;
    _ourHashes.remove(frame);
    _theirHashes.remove(frame);
    if (ours != theirs) {
      _finish(Ps1LockstepEnd.desync);
      return;
    }
    _lastMatched = max(_lastMatched ?? frame, frame);
  }

  void _onInput(Uint8List datagram) {
    if (_end != null || _phase != Ps1LockstepPhase.playing) return;
    final packet = Ps1InputWire.decode(
      datagram,
      expectedEpoch: _epoch,
      expectedSeat: _peerPort,
      oldestFrame: max(_first, _remoteHave - 255),
      newestFrame: _remoteHave + 255,
      lastSentFrame: _produced,
    );
    if (packet == null) return;
    _heard = DateTime.now();
    final acknowledged = packet.acknowledgedFrame;
    if (acknowledged != null && acknowledged > _peerAck) _peerAck = acknowledged;
    for (final (index, input) in packet.inputs.indexed) {
      final frame = packet.firstFrame + index;
      if (frame < _nextStep) continue;
      final value = RetroPadInput(
        buttons: input.buttons,
        leftX: input.leftX,
        leftY: input.leftY,
        rightX: input.rightX,
        rightY: input.rightY,
      );
      final known = _remote[frame];
      if (known != null && known != value) {
        _finish(Ps1LockstepEnd.protocol);
        return;
      }
      _remote[frame] = value;
    }
    while (_remote.containsKey(_remoteHave + 1)) {
      _remoteHave++;
    }
    _pump();
  }

  void _onControl(Uint8List bytes) {
    if (_end != null) return;
    final Ps1LockstepMessage message;
    try {
      message = Ps1LockstepMessage.decode(bytes);
    } on FormatException {
      _finish(Ps1LockstepEnd.protocol);
      return;
    }
    _heard = DateTime.now();
    switch (message) {
      case Ps1LockstepHello() when !_theirHello.isCompleted:
        _theirHello.complete(message);
        final mismatch = identity.against(message);
        if (mismatch != null) {
          _mismatch = mismatch;
          _finish(Ps1LockstepEnd.mismatch);
        }
      case Ps1LockstepPing(:final id) when !hosting:
        _send(Ps1LockstepPong(id));
      case Ps1LockstepPong(:final id) when hosting && _pongs[id]?.isCompleted == false:
        _pongs[id]!.complete();
      case Ps1LockstepStart() when !hosting && _start == null:
        _start = message;
        _startCame.complete(message);
      case Ps1LockstepChunk(:final index, :final data) when !hosting && _start != null && index == _chunks.length:
        _chunks.add(data);
        if (_chunks.length == _start!.chunks) {
          final builder = BytesBuilder(copy: false);
          _chunks.forEach(builder.add);
          _chunks.clear();
          _stateCame.complete(builder.takeBytes());
        }
      case Ps1LockstepLoaded(:final frame) when hosting && !_loaded.isCompleted:
        _loaded.complete(frame);
      case Ps1LockstepHash(:final frame, :final ram)
          when _phase == Ps1LockstepPhase.transferring || _phase == Ps1LockstepPhase.playing:
        if (frame < _first || (frame - _first) % compareEvery != 0) {
          _finish(Ps1LockstepEnd.protocol);
          return;
        }
        if (_theirHashes.length >= _maxWaitingHashes) {
          _finish(Ps1LockstepEnd.protocol);
          return;
        }
        _theirHashes[frame] = ram;
        _compare(frame);
      case Ps1LockstepPause(:final paused):
        _peerPaused = paused;
        onChanged?.call();
      case Ps1LockstepLeave():
        _finish(Ps1LockstepEnd.peerLeft);
      default:
        _finish(Ps1LockstepEnd.protocol);
    }
  }

  void _send(Ps1LockstepMessage message) {
    if (_end != null) return;
    if (!link.sendControl(message.encode())) _finish(Ps1LockstepEnd.disconnected);
  }

  void _setPhase(Ps1LockstepPhase phase) {
    if (_end != null) return;
    _phase = phase;
    onChanged?.call();
  }

  static Ps1PadInput _record(RetroPadInput input) =>
      (buttons: input.buttons, leftX: input.leftX, leftY: input.leftY, rightX: input.rightX, rightY: input.rightY);

  /// Ends the match once: the host leaves lockstep (the host player's game goes on alone), the
  /// connection closes and the match's folder is deleted. Gives a marker to throw, so a step that
  /// ended the match stops its caller.
  _Ended _finish(Ps1LockstepEnd end) {
    if (_end != null) return const _Ended();
    _end = end;
    _phase = Ps1LockstepPhase.ended;
    _timer?.cancel();
    for (final waiting in _ending) {
      if (!waiting.isCompleted) waiting.completeError(const _Ended());
    }
    _ending.clear();
    unawaited(_closeAll());
    onChanged?.call();
    return const _Ended();
  }

  Future<void> _closeAll() async {
    try {
      await _syncs?.cancel();
      final game = host;
      if (game != null) await game.leaveLockstep();
    } on Object {
      // The host may be gone already; its game then ended with it.
    }
    try {
      await link.close();
    } on Object {
      // The connection may be closed already.
    }
    try {
      if (work.existsSync()) work.deleteSync(recursive: true);
    } on FileSystemException {
      // A file still open is removed with the next match's folder.
    }
    if (!_done.isCompleted) _done.complete();
  }
}

class _Ended implements Exception {
  const _Ended();
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this._add);

  final void Function(List<int>) _add;

  @override
  void add(List<int> data) => _add(data);

  @override
  void close() {}
}
