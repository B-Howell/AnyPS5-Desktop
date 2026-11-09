import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/ps1_checkpoint_transfer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';

/// Drives the windowless Windows worker probe over its command pipes.
final class WebRtcNativeWorker implements Ps1NetplayRunner {
  WebRtcNativeWorker._(this._process, this._state)
    : _output = StreamIterator(_process.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
    unawaited(_process.stderr.drain<void>());
  }

  final Process _process;
  final File _state;
  final StreamIterator<String> _output;
  Future<String>? _pending;
  Future<void>? _stopping;
  final fingerprints = <int, String>{};
  final sentButtons = <int>{};

  static Future<WebRtcNativeWorker> spawn(
    List<String> launch,
    File state,
    int seat, {
    bool local = false,
    bool recompiler = false,
  }) async {
    final process = await Process.start(launch.first, [
      ...launch.skip(1),
      '$seat',
      if (local) 'local' else if (recompiler) 'recompiler',
    ]);
    final worker = WebRtcNativeWorker._(process, state);
    try {
      final ready = await worker._read();
      if (ready != 'ready') throw StateError('Unexpected worker greeting: $ready.');
      return worker;
    } on Object {
      process.kill();
      await process.exitCode;
      await worker._output.cancel();
      rethrow;
    }
  }

  Future<String> _read() async {
    if (await _output.moveNext().timeout(const Duration(seconds: 6))) return _output.current;
    throw StateError('The native worker closed its output.');
  }

  Future<String> _command(String command) async {
    if (_stopping != null || _pending != null) throw StateError('The native worker is busy or stopping.');
    final response = _pending = _send(command);
    try {
      return await response;
    } finally {
      _pending = null;
    }
  }

  Future<String> _send(String command) async {
    _process.stdin.writeln(command);
    await _process.stdin.flush();
    return _read();
  }

  Future<void> _expect(String command, String expected) async {
    final actual = await _command(command);
    if (actual != expected) throw StateError('Expected $expected from the native worker, received $actual.');
  }

  String get _quotedState => jsonEncode(_state.path.replaceAll(r'\', '/'));

  Future<Ps1CheckpointSnapshot> capture() async {
    final fields = (await _command('checkpoint 1 $_quotedState')).split(' ');
    if (fields.length != 3 || fields.first != 'checkpoint') throw StateError('The host rejected capture.');
    final state = await _state.readAsBytes();
    if (state.length != int.parse(fields[2])) throw StateError('The checkpoint size changed.');
    return (frame: int.parse(fields[1]), state: state);
  }

  Future<void> restore(Ps1CheckpointSnapshot snapshot, {String discDigest = '1'}) async {
    await _state.writeAsBytes(snapshot.state, flush: true);
    await _expect('restore $discDigest $_quotedState ${snapshot.frame}', 'restored');
  }

  Future<int> hold() async {
    final fields = (await _command('hold')).split(' ');
    if (fields.length != 2 || fields.first != 'held') throw StateError('The host rejected hold.');
    return int.parse(fields[1]);
  }

  Future<void> resume() => _expect('resume-local', 'resumed');

  Future<void> setPad(int buttons) => _expect('pad $buttons', 'pad');

  Future<int> picture() async => int.parse(await _command('published'));

  Future<void> waitForPicture(int target) async {
    final timer = Stopwatch()..start();
    while (await picture() < target) {
      if (timer.elapsed > const Duration(seconds: 8)) throw StateError('The native host stopped drawing.');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<({int nextFrame, List<Ps1FrameInputs> frames})> readHistory(int first, int nextFrame) async {
    final fields = (await _command('history $first')).split(' ').map(int.parse).toList();
    if (fields.first < 1 || fields.length != fields.first * 2 + 1) {
      throw StateError('Native input history is malformed.');
    }
    return (
      nextFrame: nextFrame,
      frames: [for (var i = 1; i < fields.length; i += 2) (_pad(fields[i]), _pad(fields[i + 1]))],
    );
  }

  Future<void> replay(int first, List<Ps1FrameInputs> frames) {
    final pads = frames.expand((frame) => [frame.$1.buttons, frame.$2.buttons]).join(' ');
    return _expect('replay $first ${frames.length} $pads', 'replayed');
  }

  static Ps1PadInput _pad(int buttons) => (buttons: buttons, leftX: 0, leftY: 0, rightX: 0, rightY: 0);

  @override
  Future<void> prepare(int seat) async {}

  @override
  Future<void> start() => _expect('start', 'started');

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async {
    final request = [
      acknowledgedFrame ?? -1,
      remote.length,
      for (final input in remote) ...[input.frame, input.input.buttons],
    ];
    final fields = (await _command('sync ${request.join(' ')}')).split(' ');
    var index = 0;
    int next() => int.parse(fields[index++]);
    final frame = next();
    final received = next();
    final count = next();
    final local = <Ps1NetplayFrame>[for (var item = 0; item < count; item++) (frame: next(), input: _pad(next()))];
    final hashes = next();
    final current = <int, String>{for (var item = 0; item < hashes; item++) next(): fields[index++]};
    if (index != fields.length) throw StateError('Native input packet is malformed.');
    fingerprints.addAll(current);
    sentButtons.addAll(local.map((sample) => sample.input.buttons));
    return (
      frame: frame,
      confirmedFrame: frame == 0 ? null : frame - 1,
      receivedFrame: received < 0 ? null : received,
      waiting: received < frame,
      local: local,
      fingerprints: current,
    );
  }

  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    try {
      try {
        await _pending;
      } on Object {
        // The failed command reports its own error. Still stop the worker.
      }
      _process.stdin.writeln('quit');
      await _process.stdin.close();
      final exit = await _process.exitCode.timeout(const Duration(seconds: 4));
      if (exit != 0) throw StateError('Native worker exited with code $exit.');
    } finally {
      _process.kill();
      await _process.exitCode;
      await _output.cancel();
    }
  }
}
