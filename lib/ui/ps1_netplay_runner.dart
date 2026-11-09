import '../core/online/ps1_checkpoint_transfer.dart';
import '../core/online/ps1_netplay_session.dart';
import '../core/online/ps1_netplay_wire.dart';
import 'embedded_retro_game.dart';

/// Owns the lifetime of one match's embedded game, including cancellation during boot.
final class EmbeddedPs1NetplayRunner implements Ps1NetplayRunner {
  EmbeddedPs1NetplayRunner(this._launch);

  final Future<EmbeddedRetroGame> Function(int seat) _launch;
  Future<EmbeddedRetroGame>? _launching;
  EmbeddedRetroGame? _game;
  Future<void>? _stopping;

  @override
  Future<void> prepare(int seat) async {
    if (_launching != null || _stopping != null) throw StateError('This PS1 match has already been opened.');
    final game = await (_launching = Future.sync(() => _launch(seat)));
    _game = game;
    if (_stopping != null || !await game.netplayReady || _stopping != null) {
      throw StateError('The PS1 netplay runner did not finish preparing.');
    }
  }

  @override
  Future<void> start() => _activeGame.startNetplayFrames();

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) =>
      _activeGame.exchangeNetplayFrames(remote, acknowledgedFrame);

  Future<void> restoreCheckpoint(Ps1CheckpointSnapshot snapshot) => _activeGame.restoreNetplayCheckpoint(snapshot);

  Future<void> replayHistory(int first, List<Ps1FrameInputs> frames) => _activeGame.replayNetplayHistory(first, frames);

  EmbeddedRetroGame get _activeGame {
    final game = _game;
    if (game == null || _stopping != null) throw StateError('The PS1 netplay runner is unavailable.');
    return game;
  }

  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    final launching = _launching;
    if (launching == null) return;
    final EmbeddedRetroGame game;
    try {
      game = await launching;
    } on Object {
      // A failed launch has no embedded session to close.
      return;
    }
    await game.close();
    await game.exitCode;
  }
}

/// Owns the ordinary host from the moment it parks until local play returns.
final class OrdinaryPs1NetplayRunner implements Ps1NetplayRunner {
  OrdinaryPs1NetplayRunner({
    required this._match,
    required this._park,
    required this._detach,
    required this._unpark,
    required this._drainWorker,
    required this._importMatch,
    required this._recover,
  });

  final Ps1NetplayRunner _match;
  final Future<Ps1CheckpointSnapshot> Function() _park;
  final Future<int> Function() _detach;
  final Future<void> Function() _unpark;
  final Future<void> Function() _drainWorker;
  final Future<void> Function(Ps1CheckpointSnapshot) _importMatch;
  final Future<void> Function(int) _recover;
  Future<void>? _preparing;
  Future<void>? _stopping;
  Ps1CheckpointSnapshot? _checkpoint;
  int? _ticket;
  bool _cancelled = false;
  bool detaching = false;

  @override
  Future<void> prepare(int seat) {
    if (seat != 0 || _preparing != null || _cancelled) {
      throw StateError('The ordinary PS1 host cannot prepare this match.');
    }
    return _preparing = _prepare();
  }

  Future<void> _prepare() async {
    final source = await _park();
    _checkpoint = (frame: 0, state: source.state);
    _checkOpen();
    detaching = true;
    _ticket = await _detach();
    await _drainWorker();
    _checkOpen();
    await _match.prepare(0);
    _checkOpen();
    await _importMatch(_checkpoint!);
  }

  Future<Ps1CheckpointSnapshot> capture() async {
    _checkOpen();
    final checkpoint = _checkpoint;
    if (checkpoint == null || _ticket == null) throw StateError('The ordinary PS1 checkpoint is unavailable.');
    return checkpoint;
  }

  void _checkOpen() {
    if (_cancelled) throw StateError('The PS1 match was canceled.');
  }

  @override
  Future<void> start() => _match.start();

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) =>
      _match.sync(remote, acknowledgedFrame);

  @override
  Future<void> stop() {
    _cancelled = true;
    return _stopping ??= _stop();
  }

  Future<void> _stop() async {
    try {
      await _match.stop();
    } finally {
      try {
        await _preparing;
      } on Object {
        // Cleanup still owns the original worker if preparation failed.
      }
      if (_ticket case final ticket?) {
        await _drainWorker();
        await _recover(ticket);
      } else if (_checkpoint != null) {
        await _unpark();
      }
    }
  }
}
