import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/controllers/pad_info.dart';
import '../core/game_library.dart';
import '../core/gamepad/pad_navigation.dart';
import '../core/retro_button_map.dart';
import 'app_model.dart';
import 'components.dart';
import 'controller_test_view.dart';
import 'retro_pad_art.dart';
import 'retro_pad_art_view.dart';
import 'strings.dart';
import 'theme.dart';

/// The Controls page's controller: the emulated console's own, each input lighting as the
/// selected player presses the button that does it, with a label on a line out to every input
/// naming that button. Choosing a label waits for the button that should take the input over.
class RetroControlsArt extends StatefulWidget {
  const RetroControlsArt({super.key, required this.model, this.art, this.loadArt = RetroPadArt.load});

  final AppModel model;

  /// The drawing to show at once, for tests; the launcher reads its own with [loadArt].
  final RetroPadArt? art;
  final Future<RetroPadArt> Function() loadArt;

  @override
  State<RetroControlsArt> createState() => _RetroControlsArtState();
}

class _RetroControlsArtState extends State<RetroControlsArt> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  RetroPadArt? _art;
  bool _unreadable = false;

  @override
  void initState() {
    super.initState();
    _art = widget.art;
    if (_art == null) {
      widget.loadArt().then(
        (art) {
          if (mounted) setState(() => _art = art);
        },
        onError: (Object _) {
          if (mounted) setState(() => _unreadable = true);
        },
      );
    }
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  PadButton? get _focused {
    final model = widget.model;
    final rows = model.panelCategories().firstOrNull?.rows ?? const <PanelRow>[];
    final row = model.panelRow >= 0 && model.panelRow < rows.length ? rows[model.panelRow] : null;
    return RetroEmbeddedControls.rowButton(row?.id ?? '');
  }

  static double _held(PadButton button, PadState state) {
    final pressed = state.pressed.contains(button) ? 1.0 : 0.0;
    return switch (button) {
      PadButton.l2 => math.max(state.l2, pressed),
      PadButton.r2 => math.max(state.r2, pressed),
      _ => pressed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    final game = model.selectedGame;
    final platform = game?.retro?.platform ?? RetroPlatform.ps3;
    final id = model.retroControlsPadId;
    final state = (id == null ? null : model.controllers.stateOf(id)) ?? PadState.idle;
    final layout = game == null ? RetroButtonMap.standard : model.retroLayout(game, model.retroControlsPlayer);
    final focused = _focused;
    final waiting = model.retroCapture;
    final art = _art;
    final muted = Colors.white.withValues(alpha: 0.65);
    String name(PadButton? button) => RetroEmbeddedControls.buttonName(button);

    final held = [for (final button in RetroButtonMap.buttons) if (_held(button, state) > 0) button];
    final lit = <PadButton, double>{if (state.pressed.contains(PadButton.guide)) PadButton.guide: 1};
    for (final button in held) {
      final function = layout.target(button);
      if (function != null) lit[function] = math.max(lit[function] ?? 0, _held(button, state));
    }
    final left = Offset(state.leftX, state.leftY), right = Offset(state.rightX, state.rightY);

    final back = name(model.preferences.confirmCircle ? PadButton.south : PadButton.east);
    final status = waiting != null
        ? T.format('retroControlsHoldFor', [name(waiting), back])
        : held.isEmpty
        ? (focused == null ? T.text('retroControlsLive') : T.format('retroControlsChoose', [name(focused)]))
        : held.map((button) => T.format('retroControlsActsAs', [name(button), name(layout.target(button))])).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(14 * scale, 14 * scale, 14 * scale, 12 * scale),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18 * scale),
            gradient: const RadialGradient(colors: [Color(0xFF343B4C), Color(0xFF171A22)], radius: 0.95),
          ),
          child: Opacity(
            opacity: id == null ? 0.45 : 1,
            child: art == null
                ? Column(
                    children: [
                      // Narrower than the pane, so the labels listed under it fit the page too.
                      SizedBox(
                        width: 430 * scale,
                        child: PadDiagram(
                          kind: PadKind.dualShock3,
                          state: state,
                          deadzone: model.preferences.stickDeadzone,
                          accent: model.accentChoice.color,
                          focused: focused,
                        ),
                      ),
                      // The drawing could not be read: the labels are listed under the plain
                      // controller, so every input can still be chosen and changed.
                      if (_unreadable) ...[
                        SizedBox(height: 12 * scale),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 6 * scale,
                          runSpacing: 6 * scale,
                          children: [
                            for (final function in RetroButtonMap.buttons)
                              _PlainLabel(
                                text: waiting == function
                                    ? T.text('retroControlsPress')
                                    : '${name(function)}: ${layout.sources(function).isEmpty ? name(null) : layout.sources(function).map(name).join(' / ')}',
                                chosen: waiting == function || focused == function,
                                accent: model.accentChoice.color,
                                scale: scale,
                                onTap: () => model.startRetroCapture(function),
                              ),
                          ],
                        ),
                      ],
                    ],
                  )
                : Center(
                    child: RetroPadArtView(
                      art: art,
                      platform: platform,
                      accent: model.accentChoice.color,
                      labelScale: scale,
                      lit: lit,
                      leftStick: layout.swapSticks ? right : left,
                      rightStick: layout.swapSticks ? left : right,
                      callouts: [
                        for (final function in RetroButtonMap.buttons)
                          PadCallout(
                            button: function,
                            label: waiting == function
                                ? T.text('retroControlsPress')
                                : layout.sources(function).isEmpty
                                ? name(null)
                                : layout.sources(function).map(name).join(' / '),
                            changed: layout.sources(function).length != 1 || layout.source(function) != function,
                            focused: focused == function,
                            waiting: waiting == function,
                            progress: waiting == function ? model.retroCaptureProgress : 0,
                          ),
                      ],
                      onCallout: model.startRetroCapture,
                    ),
                  ),
          ),
        ),
        SizedBox(height: 12 * scale),
        Text(
          status,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(15 * scale, weight: FontWeight.w600, color: waiting == null && held.isEmpty && focused == null ? muted : Colors.white),
        ),
      ],
    );
  }
}

/// An input's label where the controller's drawing is missing: its name and its button.
class _PlainLabel extends StatelessWidget {
  const _PlainLabel({required this.text, required this.chosen, required this.accent, required this.scale, required this.onTap});

  final String text;
  final bool chosen;
  final Color accent;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
          decoration: BoxDecoration(
            color: chosen ? accent.withValues(alpha: 0.28) : Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(8 * scale),
            border: Border.all(color: chosen ? accent : Colors.white.withValues(alpha: 0.24), width: (chosen ? 2 : 1.2) * scale),
          ),
          child: Text(text, style: AppText.display(13.5 * scale, weight: FontWeight.w600, color: Colors.white)),
        ),
      ),
    );
  }
}
