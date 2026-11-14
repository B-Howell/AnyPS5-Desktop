import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_lockstep_match.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';

/// A host that runs a lockstep frame for each step as the real one does, with a "RAM" that mixes
/// every input it was given, as the host repository's test core does: two of them given the same
/// steps from the same state report the same RAM.
class LockstepHost implements RetroLockstepHost {
  LockstepHost({this.salt = 0, this.ram = 0x811c9dc5});

  /// Mixed into the RAM after every frame: a host whose game is not the other's.
  final int salt;
  int ram;
  int? next;
  bool paused = false;
  final steps = <RetroStep>[];
  final _waiting = <RetroStep>[];
  final _syncs = StreamController<RetroSync>.broadcast();
  int leaves = 0;

  @override
  String get hostVersion => '1.0.0';

  @override
  bool get canLockstep => true;

  @override
  Stream<RetroSync> get syncs => _syncs.stream;

  @override
  Future<int?> lockstep(RetroLockstepSettings settings) async => next ??= 0;

  @override
  Future<bool> leaveLockstep() async {
    leaves++;
    next = null;
    return true;
  }

  /// Whether its states are fit for netplay, as a host with the host repository's SwanStation
  /// patches saves them; false writes the state the way stock SwanStation would name the disc.
  bool netplaySafe = true;

  @override
  Future<RetroStatePosition?> saveState(String path) async {
    final frame = next;
    if (frame == null) return null;
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
    next = state['frame']! as int;
    _waiting.clear();
    return RetroStatePosition(frame: next!, bytes: bytes.length);
  }

  @override
  void step(RetroStep step) {
    if (step.frame != next) throw StateError('step ${step.frame}, wanted $next');
    next = step.frame + 1;
    steps.add(step);
    _waiting.add(step);
    scheduleMicrotask(run);
  }

  void run() {
    while (!paused && _waiting.isNotEmpty) {
      final step = _waiting.removeAt(0);
      for (final port in step.ports) {
        for (final value in [port.buttons, port.leftX, port.leftY, port.rightX, port.rightY, salt]) {
          ram = ((ram ^ (value & 0xFFFF)) * 0x01000193) & 0xFFFFFFFF;
        }
      }
      _syncs.add(RetroSync(frame: step.frame, ram: ram.toRadixString(16).padLeft(16, '0'), video: null, state: null));
    }
  }

  Future<void> close() => _syncs.close();
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
