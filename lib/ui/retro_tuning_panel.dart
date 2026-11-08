import 'dart:async';

import 'app_model.dart';
import 'embedded_retro_game.dart';
import 'strings.dart';

PanelCategory retroTuningPanel(
  EmbeddedRetroGame session, {
  required void Function() resume,
  required void Function() openRestartTrials,
}) {
  final tuning = session.tuning;
  Future<void> record(Future<bool> Function() start) async {
    if (await start()) resume();
  }

  return PanelCategory(
    id: 'emulator-tune-game',
    title: T.text('retroTuneGame'),
    rows: [
      PanelRow(
        id: 'tuning-restart-trials',
        title: T.text('retroRestartTrials'),
        detail: T.text('retroRestartTrialsDetail'),
        kind: ActionRow(openRestartTrials),
      ),
      PanelRow(id: 'tuning-status', title: T.text('retroGameplayTest'), kind: InfoRow(tuning.status)),
      if (tuning.canStartBaseline)
        PanelRow(
          id: 'tuning-baseline',
          title: T.text('retroRecordBaseline'),
          detail: T.text('retroLiveBaselineDetail'),
          kind: ActionRow(() => unawaited(record(tuning.startBaseline))),
        ),
      if (tuning.baseline case final baseline?)
        PanelRow(id: 'tuning-baseline-result', title: T.text('retroTuningBaseline'), kind: InfoRow(baseline.summary)),
      if (tuning.changes.isNotEmpty)
        for (final (index, change) in tuning.changes.indexed)
          PanelRow(id: 'tuning-change-$index', title: change, kind: const InfoRow('')),
      if (tuning.canStartCandidate)
        PanelRow(
          id: 'tuning-candidate',
          title: T.text('retroLiveCandidate'),
          detail: T.text('retroLiveCandidateDetail'),
          kind: ActionRow(() => unawaited(record(tuning.startCandidate))),
        ),
      if (tuning.candidate case final candidate?)
        PanelRow(
          id: 'tuning-candidate-result',
          title: T.text('retroTuningCandidate'),
          kind: InfoRow(candidate.summary),
        ),
      if (tuning.canApply)
        PanelRow(
          id: 'tuning-apply',
          title: T.text('retroApplyToGame'),
          kind: ActionRow(() => unawaited(tuning.apply())),
        ),
      if (tuning.canUndo)
        PanelRow(id: 'tuning-undo', title: T.text('retroUndoTuning'), kind: ActionRow(() => unawaited(tuning.undo()))),
      if (tuning.canCancel)
        PanelRow(
          id: 'tuning-cancel',
          title: T.text('retroCancelTest'),
          kind: ActionRow(() => unawaited(tuning.cancel())),
        ),
    ],
  );
}
