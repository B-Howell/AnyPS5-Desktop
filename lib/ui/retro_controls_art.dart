import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/controllers/pad_info.dart';
import '../core/gamepad/pad_navigation.dart';
import '../core/retro_button_map.dart';
import 'app_model.dart';
import 'components.dart';
import 'controller_test_view.dart';
import 'strings.dart';
import 'theme.dart';

/// The Controls page's controller: what the selected player is pressing lights up as it is
/// pressed, and the input chosen in the list is tinted. The drawing is a placeholder until the
/// console controllers' artwork replaces [_art].
class RetroControlsArt extends StatefulWidget {
  const RetroControlsArt({super.key, required this.model});

  final AppModel model;

  @override
  State<RetroControlsArt> createState() => _RetroControlsArtState();
}

class _RetroControlsArtState extends State<RetroControlsArt> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  String? get _padId {
    final model = widget.model;
    final player = model.retroControlsPlayer;
    if (player <= 1) return (model.controllers.playerOne ?? model.controllers.pads.firstOrNull)?.id;
    final index = player - 2;
    return index < model.localSeatPads.length ? model.localSeatPads[index] : null;
  }

  PadButton? get _focused {
    final model = widget.model;
    final rows = model.panelCategories().firstOrNull?.rows ?? const <PanelRow>[];
    final row = model.panelRow >= 0 && model.panelRow < rows.length ? rows[model.panelRow] : null;
    final id = row?.id ?? '';
    if (!id.startsWith('retroButton-')) return null;
    return PadButton.values.where((button) => button.name == id.substring('retroButton-'.length)).firstOrNull;
  }

  Widget _art(PadKind kind, PadState state, PadButton? focused) => PadDiagram(
    kind: kind,
    state: state,
    deadzone: widget.model.preferences.stickDeadzone,
    accent: widget.model.accentChoice.color,
    focused: focused,
  );

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    final game = model.selectedGame;
    final id = _padId;
    final state = (id == null ? null : model.controllers.stateOf(id)) ?? PadState.idle;
    final layout = game == null ? RetroButtonMap.standard : model.retroLayout(game.id, model.retroControlsPlayer);
    final pressed = [for (final button in RetroButtonMap.buttons) if (state.pressed.contains(button)) button];
    final muted = Colors.white.withValues(alpha: 0.65);
    String name(PadButton? button) => button == null ? T.text('retroButtonOff') : RetroEmbeddedControls.buttonName(button);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(18 * scale, 22 * scale, 18 * scale, 14 * scale),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18 * scale),
            gradient: const RadialGradient(colors: [Color(0xFF525B70), Color(0xFF2C313D)], radius: 0.9),
          ),
          child: Opacity(opacity: id == null ? 0.45 : 1, child: _art(PadKind.dualShock3, state, _focused)),
        ),
        SizedBox(height: 14 * scale),
        Text(
          pressed.isEmpty
              ? T.text('retroControlsLive')
              : pressed.map((button) => T.format('retroControlsActsAs', [name(button), name(layout.target(button))])).join(' · '),
          textAlign: TextAlign.center,
          style: AppText.display(15 * scale, weight: FontWeight.w600, color: pressed.isEmpty ? muted : Colors.white),
        ),
        SizedBox(height: 8 * scale),
        Text(
          T.text('retroControlsArtPending'),
          textAlign: TextAlign.center,
          style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.45)),
        ),
      ],
    );
  }
}
