import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gamepad/pad_navigation.dart';
import 'embedded_retro_game.dart';

final embeddedRetroKeys = Map<LogicalKeyboardKey, PadButton>.unmodifiable({
  LogicalKeyboardKey.arrowUp: PadButton.dpadUp,
  LogicalKeyboardKey.arrowDown: PadButton.dpadDown,
  LogicalKeyboardKey.arrowLeft: PadButton.dpadLeft,
  LogicalKeyboardKey.arrowRight: PadButton.dpadRight,
  LogicalKeyboardKey.keyZ: PadButton.south,
  LogicalKeyboardKey.keyX: PadButton.east,
  LogicalKeyboardKey.keyA: PadButton.west,
  LogicalKeyboardKey.keyS: PadButton.north,
  LogicalKeyboardKey.keyQ: PadButton.l1,
  LogicalKeyboardKey.keyW: PadButton.r1,
  LogicalKeyboardKey.keyE: PadButton.l2,
  LogicalKeyboardKey.keyR: PadButton.r2,
  LogicalKeyboardKey.enter: PadButton.start,
  LogicalKeyboardKey.backspace: PadButton.select,
});

class EmbeddedRetroView extends StatelessWidget {
  const EmbeddedRetroView({super.key, required this.game});

  final EmbeddedRetroGame game;

  @override
  Widget build(BuildContext context) {
    final texture = Texture(
      textureId: game.textureId,
      filterQuality: game.filter == 0 ? FilterQuality.none : FilterQuality.low,
    );
    final aspect = game.displayAspect;
    return ColoredBox(
      color: const Color(0xff000000),
      child: SizedBox.expand(
        child: aspect == null
            ? texture
            : Center(
                child: AspectRatio(aspectRatio: aspect, child: texture),
              ),
      ),
    );
  }
}
