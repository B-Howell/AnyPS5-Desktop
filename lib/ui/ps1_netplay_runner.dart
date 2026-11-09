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
