part of 'app_model.dart';

extension RetroEmbeddedControls on AppModel {
  PanelRow _retroSwapCrossCircleRow(Game game) => PanelRow(
    id: 'retroSwapCrossCircle',
    title: T.text('retroSwapCrossCircle'),
    detail: T.text('retroSwapCrossCircleDetail'),
    kind: ToggleRow(preferences.retroSwapCrossCircle.contains(game.id), (enabled) {
      if (enabled) {
        preferences.retroSwapCrossCircle.add(game.id);
      } else {
        preferences.retroSwapCrossCircle.remove(game.id);
      }
      if (running?.$1.id == game.id) embeddedGame?.setSwapCrossCircle(enabled);
      savePreferences();
    }),
  );
}
