part of 'app_model.dart';

class _RetroRestartTrials {
  _RetroRestartTrials(this.app);

  final AppModel app;
  Game? _game;
  EmbeddedRetroGame? _baselineSession;
  EmbeddedRetroGame? _trialSession;
  RetroTuningSample? _baseline;
  RetroTuningSample? _candidate;
  RestartTuningChoice? _choice;
  Map<String, String> _baselineValues = const {};
  Map<String, String> _savedValues = const {};
  String? _priorOverride;
  bool _applied = false;
  bool _busy = false;
  int _restartGeneration = 0;

  void cancelPendingRestart() => _restartGeneration++;
  String _status = T.text('retroRestartInitial');

  bool isTrial(EmbeddedRetroGame session) => identical(_trialSession, session);

  PanelCategory page(Game game, EmbeddedRetroGame session) {
    final choices = restartTuningChoices(game.retro!.platform, _activeOptions(session));
    final sameGame = _game?.id == game.id;
    final trial = sameGame && isTrial(session);
    final baseline = sameGame && identical(_baselineSession, session) ? _baseline : null;
    final applied = sameGame && _applied;
    final selected = choices.indexWhere((choice) => choice == _choice);
    final current = choices.isEmpty ? null : choices[selected < 0 ? 0 : selected];
    return PanelCategory(
      id: 'emulator-restart-tuning',
      title: '${T.text('retroTuneGame')} › ${T.text('retroRestartTrials')}',
      rows: [
        PanelRow(
          id: 'restart-instructions',
          title: T.text('retroRestartSaveFirst'),
          kind: InfoRow(T.text('retroRestartInstructions')),
        ),
        PanelRow(
          id: 'restart-status',
          title: T.text('retroTuningComparison'),
          kind: InfoRow(!sameGame && !_busy ? T.text('retroRestartBaselinePrompt') : _status),
        ),
        if (game.retro!.platform == RetroPlatform.ps3)
          PanelRow(
            id: 'restart-renderer',
            title: T.text('retroRestartRenderer'),
            kind: InfoRow(T.text('retroRestartRendererInfo')),
          ),
        if (baseline != null || (trial && _baseline != null))
          PanelRow(
            id: 'restart-baseline',
            title: T.text('retroTuningBaseline'),
            kind: InfoRow((baseline ?? _baseline!).summary),
          ),
        if (!_busy && !trial && !applied && choices.isNotEmpty)
          PanelRow(
            id: 'restart-record-baseline',
            title: T.text('retroRecordBaseline'),
            detail: T.text('retroRestartBaselineDetail'),
            kind: ActionRow(() => unawaited(_record(game, session, trial: false))),
          ),
        if (!_busy && baseline != null && current != null && !applied) ...[
          PanelRow(
            id: 'restart-choice',
            title: T.text('retroRestartSetting'),
            kind: ChoiceRow(
              [for (final choice in choices) '${choice.group} · ${choice.label}'],
              selected < 0 ? 0 : selected,
              (index) {
                _choice = choices[index];
                if (!app._disposed) app._changed();
              },
            ),
          ),
          PanelRow(
            id: 'restart-start',
            title: T.text('retroStartTrial'),
            detail: T.text('retroStartTrialDetail'),
            kind: ActionRow(() => unawaited(_startTrial(game, session, current))),
          ),
        ],
        if (trial && _choice != null)
          PanelRow(
            id: 'restart-candidate',
            title: _choice!.label,
            kind: InfoRow(applied ? T.text('retroTrialSaved') : T.text('retroTrialTemporary')),
          ),
        if (_candidate case final result? when trial)
          PanelRow(id: 'restart-result', title: T.text('retroTuningCandidate'), kind: InfoRow(result.summary)),
        if (!_busy && trial && !applied)
          PanelRow(
            id: 'restart-record-candidate',
            title: T.text('retroRecordCandidate'),
            detail: T.text('retroRestartCandidateDetail'),
            kind: ActionRow(() => unawaited(_record(game, session, trial: true))),
          ),
        if (!_busy && trial && !applied && _passesComparison)
          PanelRow(
            id: 'restart-apply',
            title: T.text('retroApplyToGame'),
            kind: ActionRow(() => _apply(game, session)),
          ),
        if (!_busy && trial && !applied)
          PanelRow(
            id: 'restart-restore',
            title: T.text('retroRestartSaved'),
            detail: T.text('retroRestartSaveFirstDetail'),
            kind: ActionRow(() => unawaited(_restore(game, session))),
          ),
        if (!_busy && applied) ...[
          PanelRow(
            id: 'restart-undo',
            title: T.text('retroRestartUndo'),
            detail: T.text('retroRestartSaveFirstDetail'),
            kind: ActionRow(() => unawaited(_undo(game, session))),
          ),
          PanelRow(
            id: 'restart-finish',
            title: T.text('retroRestartFinish'),
            detail: T.text('retroRestartFinishDetail'),
            kind: ActionRow(() {
              _applied = false;
              unawaited(_restore(game, session));
            }),
          ),
        ],
        if (!trial && choices.isEmpty)
          PanelRow(
            id: 'restart-unavailable',
            title: T.text('retroRestartUnavailable'),
            kind: InfoRow(T.text('retroRestartUnavailableInfo')),
          ),
      ],
    );
  }

  bool get _passesComparison {
    final before = _baseline;
    final after = _candidate;
    return before != null && after != null && after.holdsBaseline(before) && after.improvesHeadroom(before);
  }

  Map<String, EmbeddedOption> _activeOptions(EmbeddedRetroGame session) => {
    for (final entry in session.options.entries)
      if (session.activeOptions[entry.key] case final String active)
        if (entry.value.values.indexOf(active) case final index when index >= 0)
          entry.key: (
            values: entry.value.values,
            labels: entry.value.labels,
            title: entry.value.title,
            restart: entry.value.restart,
            selected: index,
          ),
  };

  Map<String, String> _profile(Game game) => {
    if (game.retro!.platform == RetroPlatform.ps3) ...app.preferences.retroPs3Defaults,
    ...?_overrides(game)[_profileId(game)],
    'frontend-resolution': ?app.preferences.retroInternalResolution[game.id],
  };

  String _profileId(Game game) => game.retro!.platform == RetroPlatform.ps3 ? game.titleId : game.id;

  Map<String, Map<String, String>> _overrides(Game game) => game.retro!.platform == RetroPlatform.ps3
      ? app.preferences.retroPs3Graphics
      : app.preferences.retroEmbeddedGraphics;

  Future<void> _record(Game game, EmbeddedRetroGame session, {required bool trial}) async {
    if (_busy || app.embeddedGame != session || !session.presented || isTrial(session) != trial) return;
    if (trial && !_trialMatches(session)) {
      _setStatus(T.text('retroRestartSettingChanged'));
      return;
    }
    final result = session.tuning.captureRestartSample();
    if (result == null) {
      _setStatus(T.text('retroRestartBusy'));
      return;
    }
    if (_game?.id != game.id) {
      _baselineSession = null;
      _trialSession = null;
      _baseline = null;
      _candidate = null;
      _choice = null;
      _priorOverride = null;
      _applied = false;
    }
    _busy = true;
    _game = game;
    final active = Map<String, String>.of(session.activeOptions);
    final saved = _profile(game);
    _status = T.text('retroRecording');
    app.resumeGame();
    final sample = await result;
    _busy = false;
    if (sample == null ||
        app.embeddedGame != session ||
        !mapEquals(active, session.activeOptions) ||
        !mapEquals(saved, _profile(game))) {
      if (trial) {
        _candidate = null;
      } else {
        _baseline = null;
      }
      _setStatus(T.text('retroTrialInterrupted'));
      return;
    }
    if (trial) {
      _candidate = sample;
      _setStatus(_passesComparison ? T.text('retroTrialImproved') : T.text('retroTrialNoImprovement'));
    } else {
      _baselineSession = session;
      _baseline = sample;
      _candidate = null;
      _choice = null;
      _baselineValues = active;
      _savedValues = saved;
      _setStatus(T.text('retroRestartBaselineRecorded'));
    }
  }

  bool _trialMatches(EmbeddedRetroGame session) {
    final choice = _choice;
    if (choice == null ||
        session.activeOptions[choice.key] != choice.value ||
        !restartRendererMatches(choice, hardware: session.hardwareRendering)) {
      return false;
    }
    for (final entry in _baselineValues.entries) {
      if (entry.key == choice.key) continue;
      final reported = session.activeOptions[entry.key];
      if (choice.group == 'Renderer' && reported == null && _baselineSession?.options[entry.key]?.restart == false) {
        continue;
      }
      if (reported != entry.value) return false;
    }
    return true;
  }

  Future<void> _startTrial(Game game, EmbeddedRetroGame session, RestartTuningChoice choice) async {
    if (_busy || app.embeddedGame != session || _baselineSession != session || _baseline == null) return;
    if (!mapEquals(_baselineValues, session.activeOptions) || !mapEquals(_savedValues, _profile(game))) {
      _baseline = null;
      _setStatus(T.text('retroRestartBaselineInvalid'));
      return;
    }
    _busy = true;
    _choice = choice;
    _candidate = null;
    _setStatus(T.text('retroTrialRestarting'));
    final generation = _restartGeneration;
    try {
      final trial = await _restart(game, session, {choice.key: choice.value});
      if (generation != _restartGeneration || app._disposed) return;
      if (trial != null && _trialMatches(trial)) {
        _trialSession = trial;
        _setStatus(T.text('retroTrialActive'));
        app.show(T.text('retroTrialReady'));
      } else {
        if (trial != null && app.embeddedGame == trial && app.starting == null && !app.stopping) {
          await _restart(game, trial, const {});
        }
        _baseline = null;
        _setStatus(T.text('retroTrialSettingUnavailable'));
        if (!app._disposed) app.show(_status);
      }
    } on TimeoutException catch (failure) {
      _setStatus(failure.message ?? T.text('retroTrialStopTimeout'));
      if (!app._disposed) app.show(_status);
    } on StateError catch (failure) {
      debugPrint('Emulator restart failed: ${failure.message}');
      _setStatus(T.text('retroTrialRestartFailed'));
      if (!app._disposed) app.show(_status);
    } finally {
      _busy = false;
      if (!app._disposed) app._changed();
    }
  }

  Future<EmbeddedRetroGame?> _restart(Game game, EmbeddedRetroGame previous, Map<String, String> trialOptions) async {
    final generation = _restartGeneration;
    bool current() => generation == _restartGeneration && !app._disposed && !app._quitting;

    final settled = app._retroSettled;
    if (app.embeddedGame != previous || settled == null) return null;
    unawaited(app.stopRunningGame());
    await settled.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(T.text('retroTrialStopTimeout')),
    );
    if (!current() || app.running != null || app.starting != null) return null;
    if (previous.error.isNotEmpty) throw StateError(previous.error);

    final booted = Completer<EmbeddedRetroGame?>();
    unawaited(
      app._playRetro(game, game.retro!, trialOptions: trialOptions, booted: booted, canBoot: current).whenComplete(() {
        if (!booted.isCompleted) booted.complete(null);
      }),
    );
    final result = await booted.future;
    return current() ? result : null;
  }

  void _apply(Game game, EmbeddedRetroGame session) {
    final choice = _choice;
    if (_busy || choice == null || !_passesComparison || !_trialMatches(session)) return;
    if (!mapEquals(_savedValues, _profile(game))) {
      _setStatus(T.text('retroTrialProfileChanged'));
      return;
    }
    _priorOverride = _overrides(game)[_profileId(game)]?[choice.key];
    if (_save(game, choice.key, choice.value)) {
      _applied = true;
      _setStatus(T.text('retroTrialApplied'));
    }
  }

  Future<void> _restore(Game game, EmbeddedRetroGame session) async {
    if (_busy || app.embeddedGame != session) return;
    _busy = true;
    _setStatus(T.text('retroTrialRestoreRestarting'));
    final generation = _restartGeneration;
    try {
      final restored = await _restart(game, session, const {});
      if (generation != _restartGeneration || app._disposed) return;
      if (restored != null) {
        _trialSession = null;
        _baseline = null;
        _candidate = null;
        _setStatus(T.text('retroTrialRestored'));
      } else {
        _setStatus(T.text('retroTrialStartAgain'));
      }
    } on TimeoutException catch (failure) {
      _setStatus(failure.message ?? T.text('retroTrialStopTimeout'));
      if (!app._disposed) app.show(_status);
    } on StateError catch (failure) {
      debugPrint('Emulator restart failed: ${failure.message}');
      _setStatus(T.text('retroTrialRestartFailed'));
      if (!app._disposed) app.show(_status);
    } finally {
      _busy = false;
      if (!app._disposed) app._changed();
    }
  }

  Future<void> _undo(Game game, EmbeddedRetroGame session) async {
    final choice = _choice;
    if (_busy || !_applied || choice == null || app.embeddedGame != session) return;
    if (_overrides(game)[_profileId(game)]?[choice.key] != choice.value) {
      _setStatus(T.text('retroTrialUndoChanged'));
      return;
    }
    if (_save(game, choice.key, _priorOverride)) {
      _applied = false;
      await _restore(game, session);
    }
  }

  bool _save(Game game, String key, String? value) {
    final profiles = _overrides(game);
    final id = _profileId(game);
    final original = profiles[id];
    final options = {...?original};
    if (value == null) {
      options.remove(key);
    } else {
      options[key] = value;
    }
    if (options.isEmpty) {
      profiles.remove(id);
    } else {
      profiles[id] = options;
    }
    try {
      if (app.persist) app.preferences._saveTuning(app.paths.preferencesFile);
    } on FileSystemException {
      if (original == null) {
        profiles.remove(id);
      } else {
        profiles[id] = original;
      }
      _setStatus(T.text('retroTrialSaveFailed'));
      return false;
    }
    return true;
  }

  void _setStatus(String value) {
    _status = value;
    if (!app._disposed) app._changed();
  }
}
