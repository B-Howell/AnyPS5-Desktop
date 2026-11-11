part of 'app_model.dart';

extension RetroEmbeddedControls on AppModel {
  static const _buttonKeys = {
    PadButton.south: 'retroButtonCross',
    PadButton.east: 'retroButtonCircle',
    PadButton.west: 'retroButtonSquare',
    PadButton.north: 'retroButtonTriangle',
    PadButton.dpadUp: 'retroButtonUp',
    PadButton.dpadDown: 'retroButtonDown',
    PadButton.dpadLeft: 'retroButtonLeft',
    PadButton.dpadRight: 'retroButtonRight',
    PadButton.l1: 'retroButtonL1',
    PadButton.r1: 'retroButtonR1',
    PadButton.l2: 'retroButtonL2',
    PadButton.r2: 'retroButtonR2',
    PadButton.l3: 'retroButtonL3',
    PadButton.r3: 'retroButtonR3',
    PadButton.select: 'retroButtonSelect',
    PadButton.start: 'retroButtonStart',
  };

  static PadGlyph? _glyph(PadButton button) => switch (button) {
    PadButton.south => PadGlyph.cross,
    PadButton.east => PadGlyph.circle,
    PadButton.west => PadGlyph.square,
    PadButton.north => PadGlyph.triangle,
    _ => null,
  };

  static String buttonName(PadButton? button) => button == null ? T.text('retroButtonOff') : T.text(_buttonKeys[button]!);

  static String retroLayoutKey(String gameId, int player) => player <= 1 ? gameId : '$gameId#p$player';

  RetroButtonMap retroLayout(String gameId, int player) =>
      preferences.retroButtonMaps[retroLayoutKey(gameId, player)] ?? RetroButtonMap.standard;

  RetroButtonMap _retroButtonMap(Game game) => retroLayout(game.id, retroControlsPlayer);

  String _retroControlsSummary(Game game) => switch (_retroButtonMap(game).preset) {
    RetroControlPreset.standard => T.text('retroControlsStandard'),
    RetroControlPreset.swapCrossCircle => T.text('retroSwapCrossCircle'),
    RetroControlPreset.custom => T.text('retroControlsCustom'),
  };

  void _setRetroButtonMap(Game game, RetroButtonMap map) {
    final key = retroLayoutKey(game.id, retroControlsPlayer);
    if (map.isStandard) {
      preferences.retroButtonMaps.remove(key);
    } else {
      preferences.retroButtonMaps[key] = map;
    }
    if (running?.$1.id == game.id) {
      if (retroControlsPlayer <= 1) {
        embeddedGame?.setButtonMap(map);
      } else {
        embeddedGame?.setSeatButtonMap(retroControlsPlayer, map);
      }
    }
    savePreferences();
    _changed();
  }

  List<PanelRow> _retroControlRows(Game game, RetroPlatform platform) {
    final map = _retroButtonMap(game);
    const presets = [RetroControlPreset.standard, RetroControlPreset.swapCrossCircle, RetroControlPreset.custom];
    const functions = [...RetroButtonMap.buttons, null];
    final players = running?.$1.id == game.id ? coopSeats : (platform == RetroPlatform.ps3 ? 1 : 2);
    return [
      if (players > 1)
        PanelRow(
          id: 'retroControlsPlayer',
          title: T.text('retroControlsPlayer'),
          detail: T.text('retroControlsPlayerDetail'),
          kind: ChoiceRow(
            [for (var player = 1; player <= players; player++) T.format('coopPlayer', [player])],
            (retroControlsPlayer - 1).clamp(0, players - 1),
            (index) {
              retroControlsPlayer = index + 1;
              _changed();
            },
          ),
        ),
      PanelRow(
        id: 'retroControlsPreset',
        title: T.text('retroControlsPreset'),
        detail: T.text('retroControlsPresetDetail'),
        kind: ChoiceRow(
          [T.text('retroControlsStandard'), T.text('retroSwapCrossCircle'), T.text('retroControlsCustom')],
          presets.indexOf(map.preset),
          (index) => switch (presets[index]) {
            RetroControlPreset.standard => _setRetroButtonMap(game, RetroButtonMap.standard),
            RetroControlPreset.swapCrossCircle => _setRetroButtonMap(game, RetroButtonMap.swapCrossCircle),
            RetroControlPreset.custom => null,
          },
        ),
      ),
      PanelRow(id: 'retroControlsAssign', title: T.text('retroControlsAssign'), kind: const InfoRow('')),
      for (final button in RetroButtonMap.buttons)
        PanelRow(
          id: 'retroButton-${button.name}',
          title: buttonName(button),
          glyph: _glyph(button),
          kind: ChoiceRow(
            [for (final function in functions) buttonName(function)],
            functions.indexOf(map.target(button)),
            (index) => _setRetroButtonMap(game, map.assign(button, functions[index])),
          ),
        ),
      PanelRow(
        id: 'retroSwapSticks',
        title: T.text('retroSwapSticks'),
        detail: T.text(platform == RetroPlatform.ps1 ? 'retroSwapSticksPs1Detail' : 'retroSwapSticksDetail'),
        kind: ToggleRow(map.swapSticks, (value) => _setRetroButtonMap(game, map.withSwapSticks(value))),
      ),
      PanelRow(
        id: 'padTest',
        title: T.text('padTest'),
        detail: T.text('padTestDetail'),
        kind: ActionRow(openControllerTest),
      ),
      PanelRow(
        id: 'retroControlsReset',
        title: T.text('retroControlsReset'),
        kind: ActionRow(() => _setRetroButtonMap(game, RetroButtonMap.standard), destructive: !map.isStandard),
      ),
    ];
  }
}
