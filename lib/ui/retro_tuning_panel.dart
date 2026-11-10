import 'dart:async';

import '../core/game_library.dart';
import '../core/retro_launch_optimizer.dart';
import '../core/retro_optimizer.dart';
import 'app_model.dart';
import 'embedded_retro_game.dart';

typedef RetroOptimizeChange = ({String key, String name, String before, String after, String group, bool nextLaunch});
typedef RetroOptimizePlan = ({
  List<RetroOptimizeChange> changes,
  String? emptyReason,
  bool Function() canApply,
  Future<bool> Function() apply,
  Future<bool> Function()? undo,
});

class RetroAutoOptimizePanel {
  RetroAutoOptimizePanel({
    required this.gameName,
    required this.platform,
    required this.readHardware,
    required this.prepare,
    required this.refresh,
  });

  final String gameName;
  final RetroPlatform platform;
  final Future<RetroHardware?> Function()? readHardware;
  final RetroOptimizePlan Function(RetroHardware?) prepare;
  final void Function() refresh;
  bool _detecting = true;
  bool _applying = false;
  RetroOptimizePlan? _plan;
  String? _result;
  String? _hardwareSummary;
  bool _applied = false;

  Future<void> detect() async {
    RetroHardware? hardware;
    try {
      hardware = await readHardware?.call();
    } on Exception {
      // Conservative settings still work when adapter detection fails.
    }
    final adapter = RetroOptimizer.detectedAdapter(platform, hardware);
    _hardwareSummary = [
      if (adapter != null) adapter.name else 'Graphics adapter unavailable. Using conservative settings.',
      if (hardware != null && hardware.displayHeight > 0) '${hardware.displayHeight}p',
      if (hardware != null && hardware.logicalProcessors > 0) '${hardware.logicalProcessors} CPU threads',
    ].join(' · ');
    _plan = prepare(hardware);
    _detecting = false;
    refresh();
  }

  PanelCategory build() {
    final plan = _plan;
    final changes = plan?.changes ?? const <RetroOptimizeChange>[];
    final canApply = !_applying && _result == null && changes.isNotEmpty && plan!.canApply();
    return PanelCategory(
      id: 'emulator-auto-optimize',
      title: 'Auto Optimize',
      rows: [
        PanelRow(
          id: 'tuning-preset-preview',
          title: gameName,
          detail: _hardwareSummary,
          kind: InfoRow(
            _detecting
                ? 'Detecting your PC…'
                : _applying
                ? 'Applying settings…'
                : _result ??
                      (changes.isEmpty
                          ? plan?.emptyReason ?? 'Your settings already match the recommendation.'
                          : canApply
                          ? '${changes.length} recommended changes'
                          : 'Settings cannot be applied in this session.'),
          ),
        ),
        if (_result == null)
          for (final change in changes)
            PanelRow(
              id: 'auto-setting-${change.key}',
              title: change.name,
              detail: '${change.before} → ${change.after}',
              kind: InfoRow('${change.group} · ${change.nextLaunch ? 'Next launch' : 'In this session'}'),
            ),
        if (canApply)
          PanelRow(
            id: 'tuning-preset-apply',
            title: 'Apply ${changes.length} ${changes.length == 1 ? 'change' : 'changes'}',
            pinToBottom: true,
            kind: ActionRow(() => unawaited(_apply(plan))),
          ),
        if (!_applying && _applied && plan?.undo != null)
          PanelRow(
            id: 'tuning-preset-undo',
            title: 'Undo changes',
            pinToBottom: true,
            kind: ActionRow(() => unawaited(_undo(plan!))),
          ),
      ],
    );
  }

  Future<void> _apply(RetroOptimizePlan plan) async {
    if (_applying || _result != null || !plan.canApply()) return;
    _applying = true;
    refresh();
    try {
      _applied = await plan.apply();
      _result = _applied
          ? 'Optimized settings saved for this game.'
          : 'Settings changed or could not be saved. Open Auto Optimize again to refresh.';
    } on Exception {
      _result = 'Could not save the recommendation. Your previous settings are still selected.';
    } finally {
      _applying = false;
      refresh();
    }
  }

  Future<void> _undo(RetroOptimizePlan plan) async {
    if (_applying || !_applied) return;
    _applying = true;
    refresh();
    try {
      if (await plan.undo!()) {
        _applied = false;
        _result = 'Previous settings restored.';
      } else {
        _result = 'Could not restore the previous settings.';
      }
    } finally {
      _applying = false;
      refresh();
    }
  }
}

RetroOptimizePlan liveRetroOptimizePlan(EmbeddedRetroGame session, RetroDisc disc, RetroHardware? hardware) {
  final tuning = session.tuning;
  final supported = RetroLaunchOptimizer.recommend(
    disc,
    hardware,
  ).where((option) => tuning.options[option.key]?.values.contains(option.value) ?? false).toList();
  final changes = <RetroOptimizeChange>[];
  final before = <String, String>{};
  final recommended = <String, String>{};
  for (final option in supported) {
    final current = tuning.selectedValue(option.key);
    if (current == null || current == option.value) continue;
    before[option.key] = current;
    recommended[option.key] = option.value;
    changes.add((
      key: option.key,
      name: option.name,
      before: RetroLaunchOptimizer.label(option.key, current),
      after: RetroLaunchOptimizer.label(option.key, option.value),
      group: option.group,
      nextLaunch: tuning.options[option.key]?.restart == true,
    ));
  }
  return (
    changes: changes,
    emptyReason: supported.isEmpty ? 'The running emulator has not exposed settings to optimize.' : null,
    canApply: () => tuning.canApplyPreset(recommended),
    apply: () => tuning.applyPreset(before, recommended),
    undo: () async {
      if (!tuning.canUndo) return false;
      await tuning.undo();
      return !tuning.canUndo;
    },
  );
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
