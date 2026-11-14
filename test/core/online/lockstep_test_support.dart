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

  @override
  Future<RetroStatePosition?> saveState(String path) async {
    final frame = next;
    if (frame == null) return null;
    final body = utf8.encode(jsonEncode({'frame': frame, 'ram': ram}));
    final bytes = Uint8List(RetroStateFile.headerBytes + body.length)..setAll(RetroStateFile.headerBytes, body);
    File(path).writeAsBytesSync(bytes);
    return RetroStatePosition(frame: frame, bytes: bytes.length);
  }

  @override
  Future<RetroStatePosition?> loadState(String path) async {
    if (next == null) return null;
    final bytes = File(path).readAsBytesSync();
    final state = jsonDecode(utf8.decode(bytes.sublist(RetroStateFile.headerBytes))) as Map<String, Object?>;
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
    controlBytes += message.length;
    final copy = Uint8List.fromList(message);
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
