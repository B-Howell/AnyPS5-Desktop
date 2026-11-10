part of 'app_model.dart';

extension RetroLaunchOptimization on AppModel {
  bool _canOptimizeBeforeLaunch(Game game) =>
      game.retro != null &&
      (managedRetroAvailable || retroCoreOverride != null) &&
      (retroCoreOverride != null || retroSettings.program(game.retro!.platform) == null);

  RetroOptimizePlan _prepareLaunchOptimization(Game game, RetroHardware? hardware) {
    final profile = preferences;
    final disc = game.retro!;
    final ps3 = disc.platform == RetroPlatform.ps3;
    final overrides = ps3 ? profile.retroPs3Graphics : profile.retroEmbeddedGraphics;
    final id = ps3 ? game.titleId : game.id;
    const scales = {RetroLaunchOptimizer.ps1Scale, RetroLaunchOptimizer.ps2Scale};
    final settings = RetroLaunchOptimizer.recommend(disc, hardware);
    String current(RetroLaunchSetting option) =>
        (scales.contains(option.key) ? profile.retroInternalResolution[game.id] : overrides[id]?[option.key]) ??
        (ps3 ? profile.retroPs3Defaults[option.key] : null) ??
        option.baseline;
    final before = {for (final option in settings) option.key: current(option)};
    final proposed = settings.where((option) => before[option.key] != option.value).toList();
    bool available() =>
        !_disposed &&
        identical(preferences, profile) &&
        running == null &&
        starting == null &&
        selectedGame?.id == game.id &&
        _canOptimizeBeforeLaunch(game);
    return (
      changes: [
        for (final option in proposed)
          (
            key: option.key,
            name: option.name,
            before: RetroLaunchOptimizer.label(option.key, before[option.key]!),
            after: RetroLaunchOptimizer.label(option.key, option.value),
            group: option.group,
            nextLaunch: true,
          ),
      ],
      emptyReason: settings.isEmpty
          ? 'Could not identify the hardware used by this emulator. Your settings are unchanged.'
          : null,
      undo: null,
      canApply: available,
      apply: () async {
        if (!available() || proposed.isEmpty || settings.any((option) => current(option) != before[option.key])) {
          return false;
        }
        final original = overrides[id];
        final originalScale = profile.retroInternalResolution[game.id];
        final wasOptimized = profile.retroAutoOptimized.contains(game.id);
        final updated = {...?original};
        for (final option in proposed) {
          if (scales.contains(option.key)) {
            profile.retroInternalResolution[game.id] = option.value;
          } else {
            updated[option.key] = option.value;
          }
        }
        if (updated.isNotEmpty) overrides[id] = updated;
        profile.retroAutoOptimized.add(game.id);
        try {
          if (persist) profile._saveTuning(paths.preferencesFile);
        } on FileSystemException {
          if (original == null) {
            overrides.remove(id);
          } else {
            overrides[id] = original;
          }
          if (originalScale == null) {
            profile.retroInternalResolution.remove(game.id);
          } else {
            profile.retroInternalResolution[game.id] = originalScale;
          }
          if (!wasOptimized) profile.retroAutoOptimized.remove(game.id);
          return false;
        }
        _changed();
        return true;
      },
    );
  }
}
