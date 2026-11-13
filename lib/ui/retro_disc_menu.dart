part of 'app_model.dart';

extension RetroDiscMenu on AppModel {
  String _retroDiscKey(RetroDisc disc, String path) => p.relative(path, from: p.dirname(disc.path));

  void _cancelRetroDiscPicker() {
    final selection = _retroDiscLaunch?.selection;
    _retroDiscLaunch = null;
    if (selection != null && !selection.isCompleted) selection.complete(null);
  }

  Future<String?> _pickRetroLaunchDisc(Game game, RetroDisc disc, List<String> paths) {
    final selection = Completer<String?>();
    _retroDiscLaunch = (game: game, paths: paths, selection: selection);
    open(Layer.retroStartDisc);
    final last = preferences.retroLastDisc[game.id];
    final index = paths.indexWhere((path) => _retroDiscKey(disc, path) == last);
    if (index > 0) {
      panelRow = index;
      _changed();
    }
    return selection.future;
  }

  List<PanelRow> _retroLaunchDiscRows() {
    final launch = _retroDiscLaunch;
    final disc = launch?.game.retro;
    if (launch == null || disc == null) return const [];
    final last = preferences.retroLastDisc[launch.game.id];
    return [
      for (final (index, path) in launch.paths.indexed)
        PanelRow(
          id: 'retro-start-disc-$index',
          title: T.format('retroDiscNumber', [index + 1]),
          detail: _retroDiscKey(disc, path) == last ? T.text('retroLastDiscPlayed') : null,
          kind: ActionRow(() {
            if (_retroDiscLaunch != launch || overlay != Layer.retroStartDisc) return;
            launch.selection.complete(path);
            closeOverlay();
          }),
        ),
    ];
  }

  String _embeddedDiscLabel(EmbeddedDiscs discs, int index) {
    final label = discs.labels[index].trim();
    return label.isEmpty ? T.format('retroDiscNumber', [index + 1]) : label;
  }

  List<PanelRow> _embeddedDiscRows() {
    final game = embeddedGame;
    final discs = game?.discs;
    if (game == null || discs == null) return const [];
    final busy = game.changingDisc;
    return [
      for (var index = 0; index < discs.labels.length; index++)
        PanelRow(
          id: 'retro-disc-$index',
          title: _embeddedDiscLabel(discs, index),
          detail: index == discs.inserted ? T.text('retroDiscInserted') : null,
          kind: busy || index == discs.inserted
              ? const InfoRow('')
              : ActionRow(() => unawaited(_changeEmbeddedDisc(game, index))),
        ),
      if (busy || discs.failed || discs.inserted == null)
        PanelRow(
          id: 'retro-disc-status',
          title: T.text(
            busy
                ? 'retroDiscChanging'
                : discs.failed
                ? 'retroDiscChangeFailed'
                : 'retroDiscEmpty',
          ),
          detail: !busy && discs.inserted == null && discs.failed ? T.text('retroDiscEmpty') : null,
          kind: const InfoRow(''),
        ),
    ];
  }

  Future<void> _changeEmbeddedDisc(EmbeddedRetroGame game, int index) async {
    if (game.changingDisc) return;
    final request = game.changeDisc(index);
    _changed();
    if (!await request && !_disposed && embeddedGame == game) show(T.text('retroDiscChangeFailed'));
  }
}
