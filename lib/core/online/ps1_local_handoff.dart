import 'ps1_checkpoint_catchup.dart';
import 'ps1_checkpoint_transfer.dart';
import 'ps1_netplay_session.dart';
import 'ps1_netplay_wire.dart';

/// Borrows a running host for one match and returns it to local play on exit.
final class Ps1LocalHandoff implements Ps1NetplayRunner {
  Ps1LocalHandoff({
    required this._ready,
    required this._capture,
    required this._hold,
    required this._read,
    required this._resume,
    required this._begin,
    required this._exchange,
  });

  final Future<bool> Function() _ready;
  final Future<Ps1CheckpointSnapshot> Function() _capture;
  final Future<int> Function() _hold;
  final Future<({int nextFrame, List<Ps1FrameInputs> frames})> Function(int) _read;
  final Future<void> Function() _resume;
  final Future<void> Function() _begin;
  final Future<Ps1NetplayTick> Function(List<Ps1NetplayFrame>, int?) _exchange;
  Future<int>? _held;
  Future<Ps1CheckpointSnapshot>? _capturing;
  Future<void>? _starting;
  Future<Ps1NetplayTick>? _exchanging;
  Future<void>? _stopping;

  Ps1CatchupSource get source => (
    hold: () {
      _checkOpen();
      return _held ??= Future.sync(_hold);
    },
    read: _read,
  );

  Future<Ps1CheckpointSnapshot> capture() {
    _checkOpen();
    return _capturing ??= Future.sync(_capture);
  }

  @override
  Future<void> prepare(int seat) async {
    if (seat != 0 || !await _ready()) throw StateError('The local PS1 host is unavailable.');
    _checkOpen();
  }

  @override
  Future<void> start() {
    _checkOpen();
    return _starting ??= Future.sync(_begin);
  }

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) {
    _checkOpen();
    return _exchanging = Future.sync(() => _exchange(remote, acknowledgedFrame));
  }

  @override
  Future<void> stop() => _stopping ??= _restoreLocal();

  Future<void> _restoreLocal() async {
    await _settled(_capturing);
    final held = _held;
    if (held == null) return;
    try {
      await held;
    } on Object {
      return;
    }
    if (await _settled(_starting)) {
      await _settled(_exchanging);
      await _hold();
    }
    await _resume();
  }

  static Future<bool> _settled(Future<Object?>? operation) async {
    if (operation == null) return false;
    try {
      await operation;
      return true;
    } on Object {
      return false;
    }
  }

  void _checkOpen() {
    if (_stopping != null) throw StateError('The local PS1 handoff has ended.');
  }
}
