part of 'app_model.dart';

/// The Graphics page of a PS1 game playing in the emulator host (`Layer.retroGraphics`), opened
/// from its menu: the picture settings with plain names, the presets, and the Auto Optimizer. The
/// page's logic is [RetroGraphics]; this builds its rows and keeps what it changes per game.
extension RetroHostGraphicsPage on AppModel {
  /// [game]'s Graphics page for [host], kept in [Preferences.retroHostGraphics].
  RetroGraphics _retroGraphicsFor(Game game, RetroHostGame host, RetroFrameMonitor monitor) {
    final profile = preferences.retroHostGraphics.putIfAbsent(game.id, RetroGraphicsProfile.new);
    return RetroGraphics(
        host,
        profile: profile,
        save: savePreferences,
        readHardware: services.retroHardware,
        monitor: monitor,
      )
      ..addListener(_retroGraphicsChanged)
      ..onChecked = _retroSpeedChecked;
  }

  void _retroGraphicsChanged() {
    if (!_disposed && retroPlay != null) _changed();
  }

  /// Graphics in the game's menu.
  void openRetroGraphics() {
    final play = retroPlay;
    if (play == null || play.closing || !play.graphics.available) return;
    open(Layer.retroGraphics);
  }

  /// What a command does on the Graphics page: Back returns to the game's menu on Graphics, PS to
  /// the game; the rest move through its rows.
  bool _retroGraphicsCommand(Command command) {
    if (command == Command.home) {
      resumeRetroGame();
      return true;
    }
    if (command == Command.back || command == Command.options) {
      open(Layer.retroMenu, cue: Cue.back);
      final row = panelCategories().firstOrNull?.rows.indexWhere((row) => row.id == 'graphics') ?? -1;
      if (row >= 0) panelRow = row;
      _changed();
      return true;
    }
    return command == Command.previousGame || command == Command.nextGame;
  }

  /// The speed check after the Auto Optimizer's Apply, told while the game plays.
  void _retroSpeedChecked(RetroSpeedCheck check) {
    if (_disposed || retroPlay == null) return;
    if (check.lowered case final lowered?) {
      show(T.format('retroOptimizerLoweredToast', [_retroGraphicsName(lowered.key), lowered.label]));
    } else if (check.held) {
      show(T.text('retroOptimizerHeldToast'));
    } else {
      show(T.text('retroOptimizerSlowToast'));
    }
  }

  List<PanelCategory> _retroGraphicsCategories() {
    final play = retroPlay;
    if (play == null) return const [];
    final graphics = play.graphics;
    return [
      PanelCategory(
        id: 'retroGraphicsPicture',
        title: T.text('retroGraphicsPicture'),
        rows: _retroPictureRows(graphics),
      ),
      PanelCategory(id: 'retroGraphicsOptimizer', title: T.text('retroOptimizer'), rows: _retroOptimizerRows(graphics)),
      if (_retroMoreGraphicsRows(play) case final more when more.isNotEmpty)
        PanelCategory(id: 'retroGraphicsMore', title: T.text('retroGraphicsMore'), rows: more),
    ];
  }

  /// SwanStation's other picture options the menu leaves to this page ([RetroOptionSection.graphics]
  /// without the page's own settings), with the host's titles; kept for this game as the rest are.
  List<PanelRow> _retroMoreGraphicsRows(RetroPlay play) => [
    for (final option in play.menu.optionsIn(RetroOptionSection.graphics))
      if (!RetroGraphicsCatalog.covers(option.key))
        PanelRow(
          id: 'gfx-${option.key}',
          title: option.title,
          detail: option.pending
              ? T.text(option.restartNeeded ? 'retroMenuOptionRestartDetail' : 'retroMenuOptionPendingDetail')
              : (option.restartNeeded ? T.text('retroMenuOptionRestartOnlyDetail') : null),
          kind: ChoiceRow(
            [
              for (final (index, value) in option.option.values.indexed)
                _retroValueLabel(option.option, value, option.option.labels[index]),
            ],
            option.option.selected,
            (index) => unawaited(play.graphics.choose(option.key, option.option.values[index])),
          ),
        ),
  ];

  List<PanelRow> _retroPictureRows(RetroGraphics graphics) {
    final preset = graphics.preset;
    final presets = [for (final preset in RetroGraphicsPreset.values) T.text(_presetKey(preset))];
    return [
      PanelRow(
        id: 'gfx-preset',
        title: T.text('retroGfxPreset'),
        detail: T.text(preset == null ? 'retroGfxPresetCustomDetail' : '${_presetKey(preset)}Detail'),
        kind: ChoiceRow(
          [...presets, if (preset == null) T.text('retroGfxPresetCustom')],
          preset?.index ?? presets.length,
          (index) {
            if (index < RetroGraphicsPreset.values.length) {
              unawaited(graphics.choosePreset(RetroGraphicsPreset.values[index]));
            }
          },
        ),
      ),
      for (final (setting, option) in graphics.settings)
        PanelRow(
          id: 'gfx-${setting.key}',
          title: T.text(setting.name),
          detail: _retroSettingDetail(setting, option),
          kind: ChoiceRow(
            [for (final (index, value) in option.values.indexed) _retroValueLabel(option, value, option.labels[index])],
            option.selected,
            (index) => unawaited(graphics.choose(option.key, option.values[index])),
          ),
        ),
    ];
  }

  static String _presetKey(RetroGraphicsPreset preset) => switch (preset) {
    RetroGraphicsPreset.original => 'retroGfxPresetOriginal',
    RetroGraphicsPreset.enhanced => 'retroGfxPresetEnhanced',
    RetroGraphicsPreset.maximum => 'retroGfxPresetMaximum',
  };

  /// The setting's one line, with what the host says of when a change takes effect.
  String _retroSettingDetail(RetroGraphicsSetting setting, RetroOption option) {
    final description = T.text(setting.detail);
    if (option.restart) return '$description ${T.text('retroGfxRestartNote')}';
    if (RetroGraphicsCatalog.selectedValue(option) != option.activeValue) {
      return T.text('retroMenuOptionPendingDetail');
    }
    return description;
  }

  /// A value as the page names it: On and Off for SwanStation's Enabled and Disabled, plain words
  /// for the texture filters, otherwise the host's label.
  static String _retroValueLabel(RetroOption option, String value, String label) {
    if (option.key == RetroGraphicsCatalog.textureFilter) {
      final key = switch (value) {
        'Nearest' => 'retroGfxFilterNearest',
        'Bilinear' => 'retroGfxFilterBilinear',
        'BilinearBinAlpha' => 'retroGfxFilterBilinearSharp',
        'JINC2' => 'retroGfxFilterJinc',
        'JINC2BinAlpha' => 'retroGfxFilterJincSharp',
        'xBR' => 'retroGfxFilterXbr',
        'xBRBinAlpha' => 'retroGfxFilterXbrSharp',
        _ => null,
      };
      if (key != null) return T.text(key);
    }
    return switch (label) {
      'Enabled' => T.text('on'),
      'Disabled' => T.text('off'),
      _ => label,
    };
  }

  String _retroGraphicsName(String key) => T.text(
    RetroGraphicsCatalog.settings
        .firstWhere((setting) => setting.key == key, orElse: () => RetroGraphicsCatalog.settings.first)
        .name,
  );

  String _retroLabelOf(String key, String value) {
    final option = retroPlay?.host.status?.options[key];
    if (option == null) return value;
    final index = option.values.indexOf(value);
    return _retroValueLabel(option, value, index < 0 ? value : option.labels[index]);
  }

  /// The Auto Optimizer's rows. Each row's second line is what it says; an info row shows its text
  /// there.
  List<PanelRow> _retroOptimizerRows(RetroGraphics graphics) {
    final result = graphics.result;
    final advice = result?.advice;
    final proposed = graphics.proposed;
    final options = graphics.game.status?.options ?? const <String, RetroOption>{};
    final check = graphics.lastCheck;
    final wait = InfoRow(T.text('retroOptimizerWait'));
    return [
      PanelRow(
        id: 'opt-preview',
        title: T.text(graphics.reading ? 'retroOptimizerReading' : 'retroOptimizerPreview'),
        detail: T.text('retroOptimizerPreviewDetail'),
        kind: graphics.reading ? wait : ActionRow(() => unawaited(graphics.preview())),
      ),
      if (result?.blocked case final blocked?)
        PanelRow(
          id: 'opt-blocked',
          title: T.text('retroOptimizerUnavailable'),
          kind: InfoRow(
            T.text(switch (blocked) {
              RetroOptimizeBlock.noHardware => 'retroOptimizerNoHardware',
              RetroOptimizeBlock.noAdapter => 'retroOptimizerNoAdapter',
              RetroOptimizeBlock.software => 'retroOptimizerSoftware',
            }),
          ),
        ),
      if (advice != null) ...[
        PanelRow(
          id: 'opt-summary',
          title: T.format(proposed.isEmpty ? 'retroOptimizerMatchesFor' : 'retroOptimizerSuggestedFor', [
            advice.adapter.name,
          ]),
          kind: InfoRow(
            [
              T.format('retroOptimizerMemory', [(advice.adapter.dedicatedBytes / (1 << 30)).toStringAsFixed(1)]),
              T.format('retroOptimizerDisplay', ['${advice.displayHeight}']),
              if (advice.threads > 0) T.format('retroOptimizerThreads', ['${advice.threads}']),
            ].join(' · '),
          ),
        ),
        for (final MapEntry(:key, :value) in proposed.entries)
          PanelRow(
            id: 'opt-change-$key',
            title: _retroGraphicsName(key),
            kind: InfoRow(
              '${_retroLabelOf(key, RetroGraphicsCatalog.selectedValue(options[key]!))} → ${_retroLabelOf(key, value)}',
            ),
          ),
        if (proposed.isNotEmpty)
          PanelRow(
            id: 'opt-apply',
            title: T.text('retroOptimizerApply'),
            detail: T.text('retroOptimizerApplyDetail'),
            kind: graphics.busy ? wait : ActionRow(() => unawaited(graphics.apply())),
          ),
      ],
      if (graphics.checking)
        PanelRow(
          id: 'opt-checking',
          title: T.text('retroOptimizerChecking'),
          kind: InfoRow(T.text('retroOptimizerCheckingDetail')),
        )
      else if (check != null)
        PanelRow(
          id: 'opt-check',
          title: T.text(
            check.held
                ? 'retroOptimizerHeld'
                : (check.lowered == null ? 'retroOptimizerSlow' : 'retroOptimizerLowered'),
          ),
          kind: InfoRow(
            [
              if (check.lowered case final lowered?)
                T.format('retroOptimizerLoweredDetail', [_retroGraphicsName(lowered.key), lowered.label]),
              T.format('retroOptimizerRate', [check.rate.toStringAsFixed(1), check.target.toStringAsFixed(1)]),
            ].join(' '),
          ),
        ),
      if (graphics.canUndo)
        PanelRow(
          id: 'opt-undo',
          title: T.text('retroOptimizerUndo'),
          detail: T.text('retroOptimizerUndoDetail'),
          kind: graphics.busy ? wait : ActionRow(() => unawaited(graphics.undo())),
        ),
    ];
  }
}
