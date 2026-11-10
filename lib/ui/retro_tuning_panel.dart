import 'dart:async';

import '../core/game_library.dart';
import '../core/retro_optimizer.dart';
import 'app_model.dart';
import 'embedded_retro_game.dart';

class RetroAutoOptimizePanel {
  RetroAutoOptimizePanel(this.session, {required this.gameName, required this.readHardware, required this.refresh});

  final EmbeddedRetroGame session;
  final String gameName;
  final Future<RetroHardware?> Function()? readHardware;
  final void Function() refresh;
  bool _detecting = true;
  Map<String, String> _before = const {};
  Map<String, String> _recommended = const {};
  String? _result;

  Future<void> detect() async {
    RetroHardware? hardware;
    try {
      hardware = await readHardware?.call();
    } on Exception {
      // Use a conservative cap if adapter detection is unavailable.
    }
    final tuning = session.tuning;
    final platform = tuning.platform;
    final recommendation = hardware == null || platform == RetroPlatform.ps3
        ? null
        : RetroOptimizer.recommend(
            platform: platform,
            mode: RetroOptimizationMode.quality,
            hardware: hardware,
            renderer: null,
            adapter: null,
          );
    final maximum = platform == RetroPlatform.ps3
        ? (hardware?.displayHeight ?? 0) >= 1080
              ? 150
              : 100
        : recommendation?.scale.clamp(1, 4) ?? 3;
    _recommended = tuning.previewPreset(maximum, quality: maximum > 1);
    _before = {for (final key in _recommended.keys) key: tuning.selectedValue(key)!};
    _detecting = false;
    refresh();
  }

  PanelCategory build() {
    final tuning = session.tuning;
    final canApply = !_detecting && tuning.canApplyPreset(_recommended) && _recommended.isNotEmpty && _result == null;
    return PanelCategory(
      id: 'emulator-auto-optimize',
      title: 'Auto Optimize',
      rows: [
        PanelRow(
          id: 'tuning-preset-preview',
          title: gameName,
          kind: InfoRow(
            _detecting
                ? 'Reading graphics hardware…'
                : _recommended.isEmpty
                ? 'No changes are recommended for this session.'
                : 'Before → Recommended',
          ),
        ),
        for (final entry in _recommended.entries)
          PanelRow(
            id: 'auto-setting-${entry.key}',
            title: tuning.optionName(entry.key),
            kind: InfoRow(
              '${tuning.optionLabel(entry.key, _before[entry.key]!)} → ${tuning.optionLabel(entry.key, entry.value)}\n'
              '${tuning.options[entry.key]?.restart == true ? 'Next launch' : 'In this session'}',
            ),
          ),
        PanelRow(
          id: 'tuning-preset-apply',
          title: 'Apply to this game',
          pinToBottom: true,
          kind: canApply
              ? ActionRow(() => unawaited(_apply()))
              : InfoRow(
                  tuning.updating
                      ? 'Applying…'
                      : _result ??
                            (_recommended.isNotEmpty && !tuning.canApplyPreset(_recommended)
                                ? 'Wait for the hardware renderer to be ready.'
                                : ''),
                ),
        ),
        if (_result != null && tuning.canUndo)
          PanelRow(id: 'tuning-preset-undo', title: 'Undo Auto Optimize', kind: ActionRow(() => unawaited(_undo()))),
      ],
    );
  }

  Future<void> _apply() async {
    final applied = await session.tuning.applyPreset(_before, _recommended);
    _result = applied
        ? 'Applied to this game.'
        : 'Settings changed or could not be applied. Reopen Auto Optimize to review again.';
    refresh();
  }

  Future<void> _undo() async {
    await session.tuning.undo();
    _result = session.tuning.status;
    refresh();
  }
}

PanelCategory retroTuningPanel(
  EmbeddedRetroGame session, {
  required void Function() resume,
  required void Function()? openRestartTrials,
}) {
  final tuning = session.tuning;
  Future<void> record(Future<bool> Function() start) async {
    if (await start()) resume();
  }

  return PanelCategory(
    id: 'emulator-tune-game',
    title: 'Tune This Game',
    rows: [
      if (openRestartTrials != null)
        PanelRow(
          id: 'tuning-restart-trials',
          title: 'Restart Trials',
          detail: 'Compare graphics, CPU, renderer or I/O settings that need a restart.',
          kind: ActionRow(openRestartTrials),
        ),
      PanelRow(id: 'tuning-status', title: 'Gameplay test', kind: InfoRow(tuning.status)),
      if (tuning.canStartBaseline)
        PanelRow(
          id: 'tuning-baseline',
          title: 'Record baseline',
          detail: 'Resume and play a repeatable segment for about 10 seconds.',
          kind: ActionRow(() => unawaited(record(tuning.startBaseline))),
        ),
      if (tuning.baseline case final baseline?)
        PanelRow(id: 'tuning-baseline-result', title: 'Baseline', kind: InfoRow(baseline.summary)),
      if (tuning.changes.isNotEmpty)
        for (final (index, change) in tuning.changes.indexed)
          PanelRow(id: 'tuning-change-$index', title: change, kind: const InfoRow('')),
      if (tuning.canStartCandidate)
        PanelRow(
          id: 'tuning-candidate',
          title: 'Test candidate settings',
          detail: 'Repeat the baseline segment. Candidate settings are temporary.',
          kind: ActionRow(() => unawaited(record(tuning.startCandidate))),
        ),
      if (tuning.candidate case final candidate?)
        PanelRow(id: 'tuning-candidate-result', title: 'Candidate', kind: InfoRow(candidate.summary)),
      if (tuning.canApply)
        PanelRow(id: 'tuning-apply', title: 'Apply to this game', kind: ActionRow(() => unawaited(tuning.apply()))),
      if (tuning.canUndo)
        PanelRow(id: 'tuning-undo', title: 'Undo tuning', kind: ActionRow(() => unawaited(tuning.undo()))),
      if (tuning.canCancel)
        PanelRow(id: 'tuning-cancel', title: 'Cancel test', kind: ActionRow(() => unawaited(tuning.cancel()))),
    ],
  );
}
