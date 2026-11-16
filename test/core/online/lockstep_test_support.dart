import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_lockstep_match.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';

/// What two real hosts sent about the core they loaded:
/// test/fixtures/retro_host/core_identity_swanstation.json, the Windows and the Linux release
/// packages of the host's netplay-design 67aec4e, each with its own SwanStation build.
Map<String, Object?> recordedCoreIdentity(String system) =>
    (jsonDecode(File('test/fixtures/retro_host/core_identity_swanstation.json').readAsStringSync())
            as Map<String, Object?>)[system]!
        as Map<String, Object?>;

/// The status a real host of [system] (`windows` or `linux`) sent [when] (`first`, `ready` or
/// `ended`), read as the client reads it from a host that lists `coreIdentity`.
RetroStatus recordedCoreStatus(String system, String when) {
  final replies = recordedCoreIdentity(system)['replies']! as List<Object?>;
  final reply = replies.cast<Map<String, Object?>>().firstWhere(
    (reply) => reply['method'] == 'status' && reply['when'] == when,
  );
  final result = (jsonDecode(reply['reply']! as String) as Map<String, Object?>)['result']! as Map<String, Object?>;
  return RetroStatus.parse(result, coreIdentity: true);
}

/// The core a real host of [system] loaded, from its ready status.
RetroCore recordedCore(String system) => recordedCoreStatus(system, 'ready').core!;

/// A host that runs a lockstep frame for each step as the real one does, with a "RAM" that mixes
/// every input it was given, as the host repository's test core does: two of them given the same
/// steps from the same state report the same RAM. In rollback it keeps protocol.md's "Rollback":
/// a null port runs on that port's latest known input, a correction that differs from what a frame
/// ran with runs that frame and every later one again from the RAM before it, a `rollback`
/// message reports it, and a frame's `sync` comes once the frame is confirmed. A launcher that
/// breaks a rule of step or correct gets a [StateError], as the real host ends the connection.
class LockstepHost implements RetroLockstepHost {
  LockstepHost({this.salt = 0, this.ram = 0x811c9dc5, this.canRollback = true, this.canHashXxh3 = true});

  /// Mixed into the RAM after every frame: a host whose game is not the other's.
  final int salt;
  int ram;
  int? next;
  bool paused = false;
  final steps = <RetroStep>[];
  final corrections = <RetroCorrect>[];
  final reports = <RetroRollback>[];
  final _waiting = <RetroStep>[];
  final _syncs = StreamController<RetroSync>.broadcast();
  final _rollbacks = StreamController<RetroRollback>.broadcast();
  int leaves = 0;

  @override
  final bool canRollback;

  @override
  final bool canHashXxh3;

  /// The `state` of the current lockstep's settings: whether its syncs would hash the state.
  bool? state;

  /// The rollback window of the current lockstep, null in plain lockstep.
  int? window;

  /// A `sync` comes for every frame whose number is a multiple of this.
  int check = 1;

  /// Frames run in the current count: the RAM before each, the input it last ran with, and its
  /// input as known now (null for a port not known yet).
  final _before = <int, int>{};
  final _ranWith = <int, List<RetroPadInput>>{};
  final _known = <int, List<RetroPadInput?>>{};
  int _first = 0;
  int _ran = -1;
  int _synced = -1;

  @override
  String get hostVersion => '1.0.0';

  @override
  bool get canLockstep => true;

  @override
  bool get canIdentifyCore => true;

  @override
  Stream<RetroSync> get syncs => _syncs.stream;

  @override
  Stream<RetroRollback> get rollbacks => _rollbacks.stream;

  @override
  Future<int?> lockstep(RetroLockstepSettings settings) async {
    if (settings.rollback != null && !canRollback) throw StateError('This host has no rollback.');
    if (settings.state != null && !canHashXxh3) throw StateError('This host has no syncXxh3.');
    state = settings.state;
    window = settings.rollback;
    check = settings.check;
    if (next == null) _restart(0);
    return next;
  }

  void _restart(int frame) {
    next = frame;
    _first = frame;
    _ran = frame - 1;
    _synced = frame - 1;
    _before.clear();
    _ranWith.clear();
    _known.clear();
    _waiting.clear();
  }

  @override
  Future<bool> leaveLockstep() async {
    leaves++;
    next = null;
    window = null;
    return true;
  }

  /// Whether its states are fit for netplay, as a host with the host repository's SwanStation
  /// patches saves them; false writes the state the way stock SwanStation would name the disc.
  bool netplaySafe = true;

  @override
  Future<RetroStatePosition?> saveState(String path) async {
    final frame = next;
    if (frame == null || _confirmed < frame - 1) return null;
    final bytes = stateFile(frame, utf8.encode(jsonEncode({'frame': frame, 'ram': ram})), pathless: netplaySafe);
    File(path).writeAsBytesSync(bytes);
    return RetroStatePosition(frame: frame, bytes: bytes.length);
  }

  /// States loaded.
  int loads = 0;

  @override
  Future<RetroStatePosition?> loadState(String path) async {
    if (next == null) return null;
    loads++;
    final bytes = File(path).readAsBytesSync();
    final state = jsonDecode(utf8.decode(stateBody(bytes))) as Map<String, Object?>;
    ram = state['ram']! as int;
    _restart(state['frame']! as int);
    return RetroStatePosition(frame: next!, bytes: bytes.length);
  }

  /// The newest frame every port's input is known for, with every frame before it.
  int get _confirmed {
    var frame = _first - 1;
    while (_known[frame + 1]?.contains(null) == false) {
      frame++;
    }
    return frame;
  }

  @override
  void step(RetroStep step) {
    if (step.frame != next) throw StateError('step ${step.frame}, wanted $next');
    final window = this.window;
    if (window == null && step.ports.contains(null)) throw StateError('a null port outside rollback');
    if (window != null) {
      if (step.frame - window >= _first && _confirmed < step.frame - window) {
        throw StateError('step ${step.frame} is beyond the window');
      }
      for (final (port, input) in step.ports.indexed) {
        final before = _known[step.frame - 1];
        if (input != null && before != null && port < before.length && before[port] == null) {
          throw StateError('port $port of step ${step.frame} is known after an unknown one');
        }
      }
    }
    next = step.frame + 1;
    steps.add(step);
    _known[step.frame] = List.of(step.ports);
    _waiting.add(step);
    scheduleMicrotask(run);
  }

  @override
  void correct(RetroCorrect correct) {
    if (window == null) throw StateError('a correction outside rollback');
    final known = _known[correct.frame];
    if (known == null || correct.port >= known.length || known[correct.port] != null) {
      throw StateError('a correction of port ${correct.port} in frame ${correct.frame}, which is not unknown');
    }
    final before = _known[correct.frame - 1];
    if (before != null && correct.port < before.length && before[correct.port] == null) {
      throw StateError('a correction of port ${correct.port} in frame ${correct.frame} out of order');
    }
    known[correct.port] = correct.input;
    corrections.add(correct);
    scheduleMicrotask(run);
  }

  RetroPadInput _input(int frame, int port) => _known[frame]![port] ?? _latestKnown(frame, port);

  RetroPadInput _latestKnown(int frame, int port) {
    for (var earlier = frame - 1; earlier >= _first; earlier--) {
      final known = _known[earlier];
      if (known != null && port < known.length && known[port] != null) return known[port]!;
    }
    return RetroPadInput.idle;
  }

  void _runFrame(int frame) {
    _before[frame] = ram;
    final ports = [for (var port = 0; port < _known[frame]!.length; port++) _input(frame, port)];
    _ranWith[frame] = ports;
    for (final port in ports) {
      for (final value in [port.buttons, port.leftX, port.leftY, port.rightX, port.rightY, salt]) {
        ram = ((ram ^ (value & 0xFFFF)) * 0x01000193) & 0xFFFFFFFF;
      }
    }
    _after[frame] = ram;
  }

  final _after = <int, int>{};

  void run() {
    if (paused) return;
    if (window != null) _rollBack();
    while (_waiting.isNotEmpty) {
      final step = _waiting.removeAt(0);
      if (step.frame < _first) continue;
      _runFrame(step.frame);
      _ran = step.frame;
    }
    _sync();
  }

  void _rollBack() {
    int? wrong;
    for (var frame = _first; frame <= _ran; frame++) {
      final ranWith = _ranWith[frame]!;
      for (var port = 0; port < ranWith.length; port++) {
        if (_input(frame, port) != ranWith[port]) {
          wrong = frame;
          break;
        }
      }
      if (wrong != null) break;
    }
    if (wrong == null) return;
    ram = _before[wrong]!;
    for (var frame = wrong; frame <= _ran; frame++) {
      _runFrame(frame);
    }
    final report = RetroRollback(frame: wrong, frames: _ran - wrong + 1, micros: 2000, loadMicros: 500);
    reports.add(report);
    _rollbacks.add(report);
  }

  void _sync() {
    final upTo = window == null ? _ran : min(_ran, _confirmed);
    while (_synced < upTo) {
      _synced++;
      if (_synced % check != 0) continue;
      _syncs.add(
        RetroSync(frame: _synced, ram: _after[_synced]!.toRadixString(16).padLeft(16, '0'), video: null, state: null),
      );
    }
  }

  Future<void> close() async {
    await _syncs.close();
    await _rollbacks.close();
  }
}

/// The state file a real host of the host repository's `netplay-design` saved for a friend to join
/// from (test/fixtures/retro_host/lockstep_join_state.gz, recorded with lockstep_swanstation.json).
Uint8List recordedJoinState() =>
    Uint8List.fromList(gzip.decode(File('test/fixtures/retro_host/lockstep_join_state.gz').readAsBytesSync()));

/// A state file in the recorded one's form for a test host's [body]: its header for [frame] and two
/// ports, SwanStation's header from the recorded state with [body] as the machine's data, and the
/// recorded disc trailer, pathless unless [pathless] is false.
Uint8List stateFile(int frame, List<int> body, {bool pathless = true}) {
  final recorded = recordedJoinState();
  final core = Uint8List.sublistView(recorded, RetroStateFile.headerBytes);
  final data = ByteData.sublistView(core);
  final trailerAt = data.getUint32(212, Endian.little) + data.getUint32(208, Endian.little);
  final header = Uint8List.fromList(core.sublist(0, 216));
  ByteData.sublistView(header)
    ..setUint32(208, body.length, Endian.little)
    ..setUint32(212, header.length, Endian.little);
  final trailer = Uint8List.fromList(core.sublist(trailerAt, trailerAt + 24));
  if (!pathless) ByteData.sublistView(trailer).setUint32(12, 0, Endian.little);
  final machine = [...header, ...body, ...trailer];
  final file = Uint8List(RetroStateFile.headerBytes + machine.length)
    ..setAll(0, recorded.sublist(0, RetroStateFile.headerBytes))
    ..setAll(RetroStateFile.headerBytes, machine);
  ByteData.sublistView(file)
    ..setUint64(16, frame, Endian.little)
    ..setUint64(32, machine.length, Endian.little);
  return file;
}

/// The test host's body of a [stateFile].
Uint8List stateBody(Uint8List file) {
  final core = ByteData.sublistView(file, RetroStateFile.headerBytes);
  return Uint8List.sublistView(
    file,
    RetroStateFile.headerBytes + 216,
    RetroStateFile.headerBytes + 216 + core.getUint32(208, Endian.little),
  );
}

/// One end of a link between two matches: control messages arrive in order after [latency]; input
/// datagrams after [latency] plus up to [jitter], some dropped ([loss]) and so reordered.
class TestLink implements Ps1LockstepLink {
  TestLink(this.latency, {this.jitter = Duration.zero, this.loss = 0, Random? random}) : _random = random ?? Random(7);

  final Duration latency;
  final Duration jitter;
  final double loss;
  final Random _random;
  late TestLink other;
  void Function(Uint8List)? _input;
  void Function(Uint8List)? _control;
  void Function()? _closed;
  bool closed = false;

  /// Control messages this end sends that are lost on purpose, as a launcher that keeps them back.
  bool Function(Uint8List message)? withhold;

  /// Control messages this end sends as another launcher would change them: what it gives is sent
  /// instead, and nothing when it gives null.
  Uint8List? Function(Uint8List message)? rewrite;
  Future<void> _lastControl = Future.value();
  int controlBytes = 0;

  static (TestLink, TestLink) pair(Duration latency, {Duration jitter = Duration.zero, double loss = 0}) {
    final a = TestLink(latency, jitter: jitter, loss: loss, random: Random(1));
    final b = TestLink(latency, jitter: jitter, loss: loss, random: Random(2));
    a.other = b;
    b.other = a;
    return (a, b);
  }

  @override
  set onInput(void Function(Uint8List datagram) handler) => _input = handler;

  @override
  set onControl(void Function(Uint8List message) handler) => _control = handler;

  @override
  set onClosed(void Function() handler) => _closed = handler;

  @override
  bool sendInput(Uint8List datagram) {
    if (closed) return false;
    if (_random.nextDouble() < loss) return true;
    final extra = jitter.inMicroseconds == 0 ? 0 : _random.nextInt(jitter.inMicroseconds);
    final copy = Uint8List.fromList(datagram);
    Timer(latency + Duration(microseconds: extra), () {
      if (!other.closed) other._input?.call(copy);
    });
    return true;
  }

  @override
  bool sendControl(Uint8List message) {
    if (closed) return false;
    if (withhold?.call(message) ?? false) return true;
    final sent = rewrite == null ? message : rewrite!(message);
    if (sent == null) return true;
    controlBytes += sent.length;
    final copy = Uint8List.fromList(sent);
    final previous = _lastControl;
    _lastControl = Future.wait([previous, Future<void>.delayed(latency)]).then((_) {
      if (!other.closed) other._control?.call(copy);
    });
    return true;
  }

  /// Closes this end after what it sent arrived, as a reliable channel does; the other end is
  /// told the connection closed.
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _lastControl;
    if (!other.closed) other._closed?.call();
  }

  /// The network between the two ends breaks: both are told at once.
  void drop() {
    for (final end in [this, other]) {
      if (end.closed) continue;
      end.closed = true;
      end._closed?.call();
    }
  }
}
