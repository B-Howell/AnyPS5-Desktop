import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../retro_host/retro_host_protocol.dart';
import '../retro_host/retro_lockstep.dart';
import '../retro_host/retro_pad.dart';
import 'ps1_lockstep_control.dart';
import 'ps1_netplay_state.dart';
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

  /// The friend's launcher starts the game and says which core its host loaded; the host player's
  /// game plays on until the two cores are known to be the same build.
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

  /// The host player's emulator host saved a state that is not fit for netplay
  /// ([Ps1NetplayState]): it lacks the host's SwanStation patches, so its state would name the
  /// player's disc path or could make the two games differ. Nothing was sent.
  hostOld,

  /// The other launcher broke the match's rules.
  protocol,
}

/// What two launchers disagree on: their hellos, first in the order host, the hash of the hosts'
/// checks ([syncHash]), disc, BIOS, and then the cores, once the friend's game has loaded its own
/// ([Ps1LockstepReady]).
enum Ps1LockstepMismatch { host, syncHash, core, disc, bios }

/// What this launcher plays the match with ([Ps1LockstepHello] without the options).
class Ps1LockstepIdentity {
  const Ps1LockstepIdentity({
    required this.hostVersion,
    required this.core,
    required this.disc,
    required this.bios,
    this.rollback = false,
    this.syncXxh3 = false,
  });

  final String hostVersion;

  /// The core of the host player's game, from its host's `status.core`; null for the friend,
  /// whose host loads its core only for the game the match starts.
  final RetroCore? core;
  final String disc;
  final String bios;

  /// Whether this launcher's emulator host can roll back (`ps1Rollback`).
  final bool rollback;

  /// Whether this launcher's emulator host hashes its checks with XXH3 (`syncXxh3`).
  final bool syncXxh3;

  Ps1LockstepHello hello(Map<String, String> options) => Ps1LockstepHello(
    hostVersion: hostVersion,
    core: core,
    disc: disc,
    bios: bios,
    options: options,
    rollback: rollback,
    syncXxh3: syncXxh3,
  );

  /// The first thing [theirs] plays with differently, or null when both match. The disc's file
  /// names do not count: the state names the disc by its place in the disc list. The cores are
  /// compared once the friend's is known ([RetroCore.playsWith]), on any two systems: the host's
  /// SwanStation builds name the same build identity on Windows, Linux and macOS. Hosts that
  /// differ in `syncXxh3` hash the same RAM differently, so their checks could never match
  /// (protocol.md "sync"): they are refused before the game is held, not found out of sync at the
  /// first check.
  Ps1LockstepMismatch? against(Ps1LockstepHello theirs) => switch (theirs) {
    _ when theirs.hostVersion != hostVersion => Ps1LockstepMismatch.host,
    _ when theirs.syncXxh3 != syncXxh3 => Ps1LockstepMismatch.syncHash,
    _ when theirs.disc != disc => Ps1LockstepMismatch.disc,
    _ when theirs.bios != bios => Ps1LockstepMismatch.bios,
    _ => null,
  };
}

/// The friend's game once it is ready for the match: its host, and the core that host loaded.
typedef Ps1LockstepGuest = ({RetroLockstepHost host, RetroCore core});

/// The input delay a match plays with and, in rollback, its window.
typedef Ps1LockstepTiming = ({int delay, int? window});

/// How rollback has gone lately in a match ([Ps1LockstepMatch.rollbackHealth]), from the host's
/// `rollback` messages of the last [Ps1LockstepMatch.healthSpan].
class Ps1RollbackHealth {
  const Ps1RollbackHealth({
    required this.window,
    required this.rollbacks,
    required this.frames,
    required this.micros,
    required this.waited,
    this.frame = Ps1LockstepMatch.defaultFrameTime,
  });

  /// The match's rollback window in frames.
  final int window;

  /// Rollbacks in the span.
  final int rollbacks;

  /// Frames run again in the span, all rollbacks together.
  final int frames;

  /// Time the rollbacks took in the span, loads included, in microseconds.
  final int micros;

  /// Frames this launcher waited, in the whole match, so as not to run ahead of the other (GGPO's
  /// time sync).
  final int waited;

  /// How long a frame of the game lasts now.
  final Duration frame;

  /// Rollbacks a minute, at the span's rate.
  int get perMinute => (rollbacks * Duration.secondsPerMinute / Ps1LockstepMatch.healthSpan.inSeconds).round();

  /// The average time of one rollback, in milliseconds; 0 without one.
  int get millisEach => rollbacks == 0 ? 0 : (micros / rollbacks / 1000).round();

  /// Whether a rollback takes longer than a frame on average, so the game stutters when one comes.
  bool get slow => rollbacks > 0 && micros / rollbacks > frame.inMicroseconds;
}

/// One PS1 online match between two launchers, each with its own emulator host (anyps5-retro-host
/// docs/netplay.md): the host player (port 1) holds the game they are playing, saves its state and
/// sends it; the friend (port 2) starts the same game with the host player's options and loads
/// that state. The host player's game is held only once the friend's game is ready and both hosts
/// loaded the same core build (protocol.md "status", `core`). Main RAM hashes are compared every [compareEvery] frames, and the match ends at the
/// first difference.
///
/// When both launchers' hosts can roll back (`ps1Rollback`), the match plays in rollback, GGPO's
/// way (netplay.md "Rollback"): each launcher steps its host every frame on its own clock with the
/// other player's input when it has come and null when not, so the host predicts it, and sends the
/// real input as a correction once it arrives; the host runs the frames again when the guess was
/// wrong. The input delay is lowered to [rollbackDelay] frames, the rest of the round trip is
/// predicted within the [window], and the two launchers keep level with GGPO's time sync: each
/// tells the other its frame advantage every [advantageEvery], and the one further ahead waits half
/// the difference. Otherwise the match is in plain lockstep: both hosts run each frame only once
/// both players' input for it is known, and each launcher's input for frame n + [delay] goes out
/// while its host runs frame n, so the round trip is hidden behind the delay.
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
    this.frameRate,
    this.onChanged,
    this.tick = const Duration(milliseconds: 4),
    this.connectLimit = const Duration(seconds: 60),
    this.silenceLimit = const Duration(seconds: 15),
    this.compareEvery = 60,
    this.pings = 5,
    Random? random,
  }) : _random = random ?? Random.secure() {
    if (hosting && host == null) throw ArgumentError('The host player needs the running game.');
    if (hosting != (identity.core != null)) {
      throw ArgumentError(
        "Only the host player's identity names a core: the friend's is known once its game is ready.",
      );
    }
    if (!hosting && prepareGuest == null) throw ArgumentError('The friend needs a way to start the game.');
    if (hosting && host!.canHashXxh3 != identity.syncXxh3) {
      throw ArgumentError("The identity's syncXxh3 is not what the running game's host lists.");
    }
  }

  /// The most input delay a match plays with; slower connections are refused (netplay.md).
  static const maxDelay = 8;

  /// A frame at 60 frames a second: the frame clock of a match whose host gives no frame rate
  /// (protocol.md "Rollback", "The clock").
  static const defaultFrameTime = Duration(microseconds: 16667);

  /// The input delay a match in rollback plays with when the round trip allows: netplay.md's
  /// "fixed 1 or 2 frames", the rest predicted.
  static const rollbackDelay = 2;

  /// Frames of the window beyond the round trip's, for input that comes later than usual.
  static const _jitterFrames = 2;

  /// Frames a host in rollback may run behind its steps before the launcher waits for it. A host
  /// runs each step as it comes, so it falls behind only when it cannot keep up for a while: when
  /// a rollback, or the hashes of a `sync`, take longer than the frames they cover.
  static const _lead = 4;

  /// Frames a launcher in rollback catches up, one a tick, when its timer was late: a tick later
  /// than that resets its frame clock instead, so frames never come in a burst.
  static const _catchUp = 2;

  /// The most frames one time-sync wait lasts: GGPO's MAX_FRAME_ADVANTAGE.
  static const _maxWait = 9;

  /// How often a launcher in rollback tells the other its frame advantage, as GGPO's quality
  /// reports do.
  static const advantageEvery = Duration(seconds: 1);

  /// How far back [rollbackHealth] looks.
  static const healthSpan = Duration(seconds: 10);

  /// Steps queued ahead of the frame the host ran, beyond the delay: far below the 600 the host
  /// holds.
  static const _ahead = 8;

  /// Input frames one datagram carries ([Ps1InputWire.maxInputs]); up to [_maxDatagrams] go out
  /// per tick while the other side has not acknowledged them.
  static const _maxDatagrams = 4;

  /// RAM hashes not yet compared, of either side: neither game runs more than the delay and a few
  /// frames ahead of the other, so a few comparisons at most wait. More is a launcher that keeps
  /// its hashes back, and ends the match.
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
  /// of the match's own, and gives its host and the core it loaded once its `status` is ready;
  /// null when it could not.
  final Future<Ps1LockstepGuest?> Function(Ps1LockstepHello theirs)? prepareGuest;

  /// The frame rate of this player's game now, its host's `status.timing.fps` (capability
  /// `gameTiming`): about 60 in an NTSC video mode and 50 in a PAL one. Null, or a host without
  /// it, gives [defaultFrameTime]. Both players' hosts give the same rate at the same frame, as it
  /// comes from the emulated console.
  final double? Function()? frameRate;

  /// How long a frame of the game lasts now ([frameRate]).
  Duration get frameTime {
    final fps = frameRate?.call();
    return fps == null || !(fps > 1 && fps < 1000) ? defaultFrameTime : RetroTiming(fps: fps).frame;
  }

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

  /// The rollback window in frames, once the host player's launcher chose it; null before, and for
  /// a match in plain lockstep.
  int? get window => _window;
  int? _window;

  /// Whether one of the two hosts cannot roll back, so the match plays in plain lockstep; known
  /// once both hellos came.
  bool get lockstepOnly => _lockstepOnly;
  bool _lockstepOnly = false;

  /// How rollback has gone over the last [healthSpan]; null unless the match plays in rollback.
  Ps1RollbackHealth? get rollbackHealth {
    final window = _window;
    if (window == null || _phase != Ps1LockstepPhase.playing) return null;
    _forgetOldRollbacks();
    return Ps1RollbackHealth(
      window: window,
      rollbacks: _rollbackLog.length,
      frames: _rollbackLog.fold(0, (sum, entry) => sum + entry.$2.frames),
      micros: _rollbackLog.fold(0, (sum, entry) => sum + entry.$2.micros),
      waited: _waited,
      frame: frameTime,
    );
  }

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
  final _guestReady = Completer<RetroCore>();
  final _ending = <Completer<Object?>>[];
  final _pongs = <int, Completer<void>>{};
  final _chunks = <Uint8List>[];
  Ps1LockstepStart? _start;
  final _startCame = Completer<Ps1LockstepStart>();
  final _stateCame = Completer<Uint8List>();
  final _loaded = Completer<int>();

  Timer? _timer;
  StreamSubscription<RetroSync>? _syncs;
  StreamSubscription<RetroRollback>? _rollbacks;
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

  /// In rollback: the newest frame whose input from the other player the host has, in a step or a
  /// correction, with every frame before it.
  int _given = -1;

  /// The newest frame the host sent a `sync` for, so it has run it.
  int _lastSync = -1;

  /// In rollback, the launcher's frame clock: frame [_anchorFrame] was due at [_anchorMicros] of
  /// [_clock], and each later one [_frameMicros] after the one before: a [frameTime] when the clock
  /// last looked.
  final _clock = Stopwatch();
  int _anchorFrame = 0;
  int _anchorMicros = 0;
  int _frameMicros = defaultFrameTime.inMicroseconds;
  int _advantageSum = 0;
  int _advantageCount = 0;
  int? _theirAdvantage;
  int _lastAdvantageMicros = 0;
  int _waited = 0;
  final _rollbackLog = Queue<(int, RetroRollback)>();

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
    _lockstepOnly = !identity.rollback || !theirs.rollback;
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
    final game = host!;
    _lockstepOnly = _lockstepOnly || !game.canRollback;
    final timing = timingFor(
      Duration(microseconds: roundTrip),
      rollback: !_lockstepOnly,
      frame: frameTime,
    );
    if (timing == null) throw _finish(Ps1LockstepEnd.tooSlow);
    final delay = _delay = timing.delay;
    _window = timing.window;
    _setPhase(Ps1LockstepPhase.preparing);
    await _within(_guestReady.future);
    _setPhase(Ps1LockstepPhase.transferring);
    final frame = await _guard(game.lockstep(_settings(game)));
    if (frame == null) throw _finish(Ps1LockstepEnd.hostFailed);
    work.createSync(recursive: true);
    final file = File(p.join(work.path, 'match.state'));
    final saved = await _guard(game.saveState(file.path));
    if (saved == null) throw _finish(Ps1LockstepEnd.hostFailed);
    final state = await _guard(file.readAsBytes());
    if (state.length != saved.bytes || RetroStateFile.read(state)?.frame != saved.frame) {
      throw _finish(Ps1LockstepEnd.hostFailed);
    }
    if (Ps1NetplayState.problem(state) != null) throw _finish(Ps1LockstepEnd.hostOld);
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
        window: _window ?? 0,
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
    final guest = await _within(prepareGuest!(theirs));
    if (guest == null) throw _finish(Ps1LockstepEnd.hostFailed);
    final game = host = guest.host;
    // The hello said which hash this launcher's host checks with; a game in another host would
    // send hashes the other launcher cannot compare.
    if (game.canHashXxh3 != identity.syncXxh3) throw _finish(Ps1LockstepEnd.hostFailed);
    _send(Ps1LockstepReady(guest.core));
    if (!guest.core.playsWith(theirs.core!)) throw _mismatched(Ps1LockstepMismatch.core);
    final start = await _within(_startCame.future);
    if (start.window != 0 && _lockstepOnly) throw _finish(Ps1LockstepEnd.protocol);
    _delay = start.delay;
    _window = start.window == 0 ? null : start.window;
    _epoch = start.epoch;
    _first = start.frame;
    if (_window != null && !game.canRollback) throw _finish(Ps1LockstepEnd.hostFailed);
    _setPhase(Ps1LockstepPhase.transferring);
    final packed = await _within(_stateCame.future);
    final state = inflate(packed, start.bytes);
    if (state == null ||
        sha256.convert(state).toString() != start.sha256 ||
        RetroStateFile.read(state)?.frame != start.frame ||
        Ps1NetplayState.problem(state) != null) {
      throw _finish(Ps1LockstepEnd.protocol);
    }
    work.createSync(recursive: true);
    final file = File(p.join(work.path, 'match.state'));
    await _guard(file.writeAsBytes(state, flush: true));
    if (await _guard(game.lockstep(_settings(game))) == null) {
      throw _finish(Ps1LockstepEnd.hostFailed);
    }
    final loaded = await _guard(game.loadState(file.path));
    if (loaded == null || loaded.frame != start.frame) throw _finish(Ps1LockstepEnd.hostFailed);
    _send(Ps1LockstepLoaded(loaded.frame));
  }

  /// The gzip data [packed] inflated, when it is exactly [bytes] long; null for data that is not
  /// gzip or inflates to another size. Inflating stops as soon as it passes [bytes], so no more
  /// than the state the other player announced is kept, beyond the inflater's own buffer.
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

  /// What the host plays the match with. In plain lockstep the host keeps to its core's frame rate
  /// and the steps wait for it, and a `sync` comes after every frame, which is how the match knows
  /// which frame its host ran. In rollback, as in GGPO, the game has one clock, the launcher's
  /// frame clock: the host runs each step as it comes (`paced` false), since a host that kept its
  /// own time as well would run behind the steps by however far the two clocks drift apart, and
  /// the other player's input would come before the frame ran, so rollback would add nothing to
  /// lockstep. A `sync` comes every [compareEvery] frames, those whose RAM is compared, as
  /// netplay.md "Desync checks" advises: a check frame is hashed again each time a rollback runs it
  /// again. Only `ram` is compared, so a host that lists `syncXxh3` is told to leave the core's
  /// state out of its hashes (`state` false): it then serializes nothing for a check, which under a
  /// GPU would read the console's video memory back. A host without it hashes the state too.
  RetroLockstepSettings _settings(RetroLockstepHost game) => RetroLockstepSettings(
    check: _window == null ? 1 : compareEvery,
    rollback: _window,
    paced: _window == null,
    state: game.canHashXxh3 ? false : null,
  );

  /// Whether the RAM after [frame] is compared: every [compareEvery] frames from the first of the
  /// match in plain lockstep, and in rollback the frames the host sends a `sync` for, whose number
  /// is a multiple of it.
  bool _compares(int frame) => (frame - (_window == null ? _first : 0)) % compareEvery == 0;

  /// The frames the other player's input comes late by with no delay: half the round trip in
  /// frames of [frame] each, rounded up, and one more (netplay.md "Lockstep first, rollback after").
  static int lateFrames(Duration roundTrip, {Duration frame = defaultFrameTime}) =>
      (roundTrip.inMicroseconds / 2 / frame.inMicroseconds).ceil() + 1;

  /// The input delay of plain lockstep for a round trip: [lateFrames]; null above [maxDelay].
  static int? delayFor(Duration roundTrip, {Duration frame = defaultFrameTime}) =>
      timingFor(roundTrip, rollback: false, frame: frame)?.delay;

  /// The timing a match plays with for a round trip; null when it is too slow. In plain lockstep
  /// the delay is [lateFrames], at most [maxDelay]. In rollback, as GGPO plays (a fixed input delay
  /// set by the game, the rest of the round trip predicted within a window of at most 8 frames):
  /// the delay is [rollbackDelay], or [lateFrames] when that is less, and the window is the frames
  /// that leaves predicted and two more for input that comes later than usual, at most
  /// [RetroLockstepSettings.maxRollback]. A round trip that would need a wider window raises the
  /// delay instead, up to [maxDelay].
  static Ps1LockstepTiming? timingFor(Duration roundTrip, {required bool rollback, Duration frame = defaultFrameTime}) {
    final late = lateFrames(roundTrip, frame: frame);
    if (!rollback) return late > maxDelay ? null : (delay: late, window: null);
    final delay = max(min(late, rollbackDelay), late - (RetroLockstepSettings.maxRollback - _jitterFrames));
    if (delay > maxDelay) return null;
    return (delay: delay, window: min(RetroLockstepSettings.maxRollback, late - delay + _jitterFrames));
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
    _given = _first - 1;
    _lastSync = _first - 1;
    _anchorFrame = _first;
    _frameMicros = frameTime.inMicroseconds;
    _clock.start();
    _anchorMicros = _lastAdvantageMicros = _clock.elapsedMicroseconds;
    _syncs = host!.syncs.listen(_onSync);
    if (_window != null) _rollbacks = host!.rollbacks.listen(_onRollback);
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
    if (_window != null) {
      _advanceRollback();
      _sendInputs(now);
      _timeSync();
      return;
    }
    _produce();
    _sendInputs(now);
    _pump();
  }

  /// In rollback: gives the host the other player's input that came for frames it was stepped
  /// without, in frame order, and steps the next frame once the frame clock says it is due. No
  /// frame is stepped while this player's game is paused, while the window is full (the frame a
  /// window back is not confirmed), or while the host is known to be more than [_lead] frames
  /// behind its steps (it has the other player's input for the frame of the next `sync` and has not
  /// sent it, so it has not run that frame); the clock waits then too, so the frames do not come in a burst after. One
  /// frame is stepped at a time. Stepping frame n reads this player's input for frame n + [delay].
  void _advanceRollback() {
    final game = host;
    if (game == null || _end != null) return;
    try {
      final known = min(_remoteHave, _nextStep - 1);
      while (_given < known) {
        final frame = _given + 1;
        game.correct(RetroCorrect(frame, _peerPort, _remote.remove(frame)!));
        _given = frame;
      }
      final now = _clock.elapsedMicroseconds;
      _followFrameRate(now);
      final due = _anchorFrame + (now - _anchorMicros) ~/ _frameMicros;
      if (_nextStep > due) return;
      final held = paused() || _rollbackBlocked();
      if (_nextStep < due - _catchUp || held) {
        _anchorFrame = _nextStep;
        _anchorMicros = now;
        if (held) return;
      }
      final frame = _nextStep;
      final mine = _local[frame]!;
      final theirs = frame == _given + 1 ? _remote[frame] : null;
      game.step(RetroStep(frame, hosting ? [mine, theirs] : [theirs, mine]));
      if (theirs != null) {
        _given = frame;
        _remote.remove(frame);
      }
      _advantageSum += _remoteHave - frame;
      _advantageCount++;
      _nextStep++;
      _produced = frame + _delay!;
      _local[_produced] = localInput();
    } on Object {
      _finish(Ps1LockstepEnd.hostFailed);
    }
  }

  /// A new frame rate (the game changed its video mode) takes effect from the frame now due: the
  /// frames before it keep the time they were due at, the later ones come at the new rate.
  void _followFrameRate(int now) {
    final length = frameTime.inMicroseconds;
    if (length == _frameMicros) return;
    final passed = max(0, (now - _anchorMicros) ~/ _frameMicros);
    _anchorFrame += passed;
    _anchorMicros += passed * _frameMicros;
    _frameMicros = length;
  }

  bool _rollbackBlocked() {
    final behind = _nextStep - _window!;
    if (behind >= _first && min(_given, _nextStep - 1) < behind) return true;
    final due = _nextSync;
    return _given >= due && _nextStep - 1 - due > _lead;
  }

  /// The next frame the host sends a `sync` for in rollback: the first multiple of [compareEvery]
  /// after the last one that came.
  int get _nextSync {
    final from = max(_lastSync + 1, _first);
    return (from + compareEvery - 1) ~/ compareEvery * compareEvery;
  }

  /// GGPO's time sync: every [advantageEvery] this launcher tells the other its average frame
  /// advantage (how far the other player's newest input is ahead of the frames stepped here), and
  /// when both agree this one is ahead, its clock waits half the difference, at most [_maxWait]
  /// frames. Without it the launcher that started first would stay ahead and predict all of the
  /// round trip alone.
  void _timeSync() {
    final now = _clock.elapsedMicroseconds;
    if (now - _lastAdvantageMicros < advantageEvery.inMicroseconds || _advantageCount == 0) return;
    _lastAdvantageMicros = now;
    final ours = (_advantageSum / _advantageCount).round().clamp(-Ps1LockstepAdvantage.most, Ps1LockstepAdvantage.most);
    _advantageSum = 0;
    _advantageCount = 0;
    _send(Ps1LockstepAdvantage(ours));
    final theirs = _theirAdvantage;
    _theirAdvantage = null;
    if (theirs != null && ours < theirs) {
      final wait = min((theirs - ours) ~/ 2, _maxWait);
      if (wait > 0) {
        _anchorMicros += wait * _frameMicros;
        _waited += wait;
      }
    }
    onChanged?.call();
  }

  void _onRollback(RetroRollback rollback) {
    if (_end != null) return;
    _rollbackLog.add((_clock.elapsedMicroseconds, rollback));
    _forgetOldRollbacks();
  }

  void _forgetOldRollbacks() {
    final oldest = _clock.elapsedMicroseconds - healthSpan.inMicroseconds;
    while (_rollbackLog.isNotEmpty && _rollbackLog.first.$1 < oldest) {
      _rollbackLog.removeFirst();
    }
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
    _lastSync = max(_lastSync, sync.frame);
    _remote.remove(sync.frame);
    final kept = min(_ran, _peerAck);
    _local.removeWhere((frame, _) => frame <= kept);
    final ram = sync.ram;
    if (ram != null && _compares(sync.frame)) {
      if (_ourHashes.length >= _maxWaitingHashes) {
        _finish(Ps1LockstepEnd.protocol);
        return;
      }
      _ourHashes[sync.frame] = ram;
      _send(Ps1LockstepHash(sync.frame, ram));
      _compare(sync.frame);
    }
    if (_window != null) {
      _advanceRollback();
      return;
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
      newestFrame: _window == null ? _ran + 1 + 2 * (_delay! + _ahead) + 8 : _produced + _window! + _delay! + 8,
      lastSentFrame: _produced,
    );
    if (packet == null) return;
    _heard = DateTime.now();
    final acknowledged = packet.acknowledgedFrame;
    if (acknowledged != null && acknowledged > _peerAck) _peerAck = acknowledged;
    for (final (index, input) in packet.inputs.indexed) {
      final frame = packet.firstFrame + index;
      if (frame <= (_window == null ? _nextStep - 1 : _given)) continue;
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
    if (_window != null) {
      _advanceRollback();
      return;
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
        if (hosting != (message.core == null)) {
          _finish(Ps1LockstepEnd.protocol);
          return;
        }
        _theirHello.complete(message);
        if (identity.against(message) case final mismatch?) _mismatched(mismatch);
      case Ps1LockstepReady(:final core) when hosting && _theirHello.isCompleted && !_guestReady.isCompleted:
        // Compared as it comes, as the hellos are: the friend ends the match right after sending a
        // ready whose core differs, maybe while this launcher still measures the round trip.
        if (!identity.core!.playsWith(core)) {
          _mismatched(Ps1LockstepMismatch.core);
          return;
        }
        _guestReady.complete(core);
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
        if (frame < _first || !_compares(frame)) {
          _finish(Ps1LockstepEnd.protocol);
          return;
        }
        if (_theirHashes.length >= _maxWaitingHashes) {
          _finish(Ps1LockstepEnd.protocol);
          return;
        }
        _theirHashes[frame] = ram;
        _compare(frame);
      case Ps1LockstepAdvantage(:final frames) when _window != null && _phase == Ps1LockstepPhase.playing:
        _theirAdvantage = frames;
      case Ps1LockstepPause(:final paused):
        _peerPaused = paused;
        onChanged?.call();
      case Ps1LockstepLeave():
        _finish(Ps1LockstepEnd.peerLeft);
      default:
        _finish(Ps1LockstepEnd.protocol);
    }
  }

  /// Ends the match because the two launchers do not play with the same [what].
  _Ended _mismatched(Ps1LockstepMismatch what) {
    if (_end == null) _mismatch = what;
    return _finish(Ps1LockstepEnd.mismatch);
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
      await _rollbacks?.cancel();
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
