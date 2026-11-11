import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/game_library.dart' show RetroPlatform;
import '../core/gamepad/pad_navigation.dart';
import '../core/retro_button_map.dart';
import 'retro_pad_art.dart';
import 'theme.dart';

/// One label beside the controller: the input it points at and what it says.
class PadCallout {
  const PadCallout({
    required this.button,
    required this.label,
    this.changed = false,
    this.focused = false,
    this.waiting = false,
    this.progress = 0,
  });

  final PadButton button;
  final String label;

  /// Not the standard button for this input: drawn in amber.
  final bool changed;

  /// The input chosen in the list beside the controller.
  final bool focused;

  /// Waiting for the player to hold the button that should do this.
  final bool waiting;

  /// How far a held button is towards taking this input over, 0 to 1.
  final double progress;
}

/// The colours of one console's controller.
class PadArtPalette {
  const PadArtPalette({required this.body, required this.line, required this.part, required this.label, required this.faint});

  static const _ps1 = PadArtPalette(
    body: Color(0xFFC5C8CB),
    line: Color(0xFF16181D),
    part: Color(0xFF9B9EA4),
    label: Color(0xFF2B2D33),
    faint: 0.5,
  );
  static const _ps2 = PadArtPalette(
    body: Color(0xFF20222A),
    line: Color(0xFFE4E7EE),
    part: Color(0xFF343742),
    label: Color(0xFFC5C9D3),
    faint: 0.45,
  );
  static const _ps3 = PadArtPalette(
    body: Color(0xFF111217),
    line: Color(0xFFE4E7EE),
    part: Color(0xFF23252D),
    label: Color(0xFFC5C9D3),
    faint: 0.45,
  );

  static PadArtPalette of(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => _ps1,
    RetroPlatform.ps2 => _ps2,
    RetroPlatform.ps3 => _ps3,
  };

  final Color body;
  final Color line;
  final Color part;
  final Color label;
  final double faint;
}

const _signColors = {
  PadButton.south: Color(0xFF6FB5E3),
  PadButton.east: Color(0xFFFF5B61),
  PadButton.west: Color(0xFFF388AA),
  PadButton.north: Color(0xFF5FD6C4),
};
const _amber = Color(0xFFFFCF6B);
const _shoulderNames = {PadButton.l1: 'L1', PadButton.r1: 'R1', PadButton.l2: 'L2', PadButton.r2: 'R2'};
const _travel = {PadButton.l1: 5.0, PadButton.r1: 5.0, PadButton.l2: 7.0, PadButton.r2: 7.0};
/// The inputs that sit behind another seen from their side: their line comes up from below.
const _hooked = {PadButton.dpadRight, PadButton.west};
const _stickReach = 22.0;

/// A label's place and the line from it to its input, in the widget's pixels.
class _Route {
  const _Route(this.callout, this.chip, this.line);

  final PadCallout callout;
  final Rect chip;
  final List<Offset> line;
}

/// Where the drawing and its labels go in a given width: the labels keep a readable size, so
/// the drawing takes what is left between them.
class _PadLayout {
  _PadLayout(this.art, double width, double labelScale, bool wanted)
    : labelled = wanted && width >= 560 * labelScale,
      unit = labelScale {
    chip = labelled ? Size(132 * unit, 28 * unit) : Size.zero;
    final side = labelled ? chip.width + 22 * unit : 0.0;
    scale = (width - 2 * side) / art.size.width;
    origin = Offset(side, labelled ? chip.height + 12 * unit : 0);
    size = Size(width, origin.dy + art.size.height * scale + 6 * unit);
  }

  final RetroPadArt art;

  /// False in a pane too narrow for labels beside the drawing: the drawing takes it all.
  final bool labelled;
  final double unit;
  late final Size chip;
  late final double scale;
  late final Offset origin;
  late final Size size;

  Offset place(Offset point) => origin + point * scale;

  List<_Route> routes(List<PadCallout> callouts) {
    if (!labelled) return const [];
    List<PadCallout> among(List<PadButton> buttons) => [
      for (final button in buttons) ...callouts.where((callout) => callout.button == button && art.boundsOf(button) != null),
    ];
    return [..._side(among(RetroButtonMap.leftSide), left: true), ..._side(among(RetroButtonMap.rightSide), left: false), ..._top(among(RetroButtonMap.topSide))];
  }

  List<_Route> _side(List<PadCallout> callouts, {required bool left}) {
    final step = chip.height + 4 * unit;
    final rows = <double>[];
    for (final callout in callouts) {
      final bounds = art.boundsOf(callout.button)!;
      final wanted = _hooked.contains(callout.button) ? place(bounds.bottomCenter).dy + 12 * unit : place(bounds.center).dy;
      rows.add(rows.isEmpty ? wanted : math.max(wanted, rows.last + step));
    }
    if (rows.isNotEmpty) {
      rows[rows.length - 1] = math.min(rows.last, size.height - chip.height / 2);
      for (var index = rows.length - 2; index >= 0; index--) {
        rows[index] = math.min(rows[index], rows[index + 1] - step);
      }
    }
    final start = left ? chip.width : size.width - chip.width;
    final edge = left ? origin.dx - 6 * unit : size.width - origin.dx + 6 * unit;
    final routes = <_Route>[];
    for (final (index, callout) in callouts.indexed) {
      final bounds = art.boundsOf(callout.button)!;
      final row = rows[index];
      final box = Rect.fromLTWH(left ? 0 : start, row - chip.height / 2, chip.width, chip.height);
      if (_hooked.contains(callout.button)) {
        final under = place(bounds.bottomCenter);
        routes.add(_Route(callout, box, [Offset(start, row), Offset(under.dx, row), under]));
        continue;
      }
      final target = place(Offset(left ? bounds.left : bounds.right, bounds.center.dy));
      final level = (target.dy - row).abs() < 1;
      routes.add(_Route(callout, box, [Offset(start, row), if (!level) Offset(edge, row), target]));
    }
    return routes;
  }

  List<_Route> _top(List<PadCallout> callouts) {
    final middle = place(Offset(art.size.width / 2, 0)).dx;
    final routes = <_Route>[];
    for (final callout in callouts) {
      final bounds = art.boundsOf(callout.button)!;
      final before = bounds.center.dx < art.size.width / 2;
      final box = Rect.fromLTWH(before ? middle - 5 * unit - chip.width : middle + 5 * unit, 0, chip.width, chip.height);
      final target = place(bounds.topCenter);
      final drop = target.dx.clamp(box.left + 12 * unit, box.right - 12 * unit);
      routes.add(_Route(callout, box, [Offset(drop, box.bottom), Offset(drop, target.dy)]));
    }
    return routes;
  }
}

/// The console's controller with every input lit as it is pressed, the sticks moving, and a
/// label on a line out to each input.
class RetroPadArtView extends StatelessWidget {
  const RetroPadArtView({
    super.key,
    required this.art,
    required this.platform,
    required this.accent,
    this.labelScale = 1,
    this.lit = const {},
    this.leftStick = Offset.zero,
    this.rightStick = Offset.zero,
    this.callouts = const [],
    this.onCallout,
  });

  final RetroPadArt art;
  final RetroPlatform platform;
  final Color accent;

  /// The size of the labels' text, as the rest of the screen's.
  final double labelScale;

  /// How far each input is pressed, 0 to 1.
  final Map<PadButton, double> lit;
  final Offset leftStick;
  final Offset rightStick;
  final List<PadCallout> callouts;
  final void Function(PadButton button)? onCallout;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _PadLayout(art, constraints.maxWidth, labelScale, callouts.isNotEmpty);
        final routes = layout.routes(callouts);
        return SizedBox(
          width: layout.size.width,
          height: layout.size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _PadArtPainter(
                    art: art,
                    palette: PadArtPalette.of(platform),
                    only: platform == RetroPlatform.ps3 ? 'ps' : 'analog',
                    accent: accent,
                    lit: lit,
                    leftStick: leftStick,
                    rightStick: rightStick,
                    routes: routes,
                    layout: layout,
                  ),
                ),
              ),
              for (final route in routes)
                Positioned.fromRect(
                  rect: route.chip,
                  child: _CalloutChip(
                    callout: route.callout,
                    accent: accent,
                    scale: labelScale,
                    onTap: onCallout == null ? null : () => onCallout!(route.callout.button),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CalloutChip extends StatelessWidget {
  const _CalloutChip({required this.callout, required this.accent, required this.scale, this.onTap});

  final PadCallout callout;
  final Color accent;
  final double scale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final strong = callout.waiting || callout.focused;
    final edge = strong ? accent : (callout.changed ? _amber : Colors.white.withValues(alpha: 0.24));
    final fill = callout.waiting
        ? accent.withValues(alpha: 0.34)
        : callout.focused
        ? accent.withValues(alpha: 0.22)
        : callout.changed
        ? _amber.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.42);
    final text = strong ? Colors.white : (callout.changed ? const Color(0xFFFFE3A6) : Colors.white.withValues(alpha: 0.9));
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8 * scale),
            border: Border.all(color: edge, width: (strong ? 2 : 1.2) * scale),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (callout.progress > 0)
                FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: callout.progress.clamp(0.0, 1.0),
                  child: ColoredBox(color: accent.withValues(alpha: 0.75)),
                ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 7 * scale),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    callout.label,
                    maxLines: 1,
                    style: AppText.display(13.5 * scale, weight: FontWeight.w600, color: text),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PadArtPainter extends CustomPainter {
  _PadArtPainter({
    required this.art,
    required this.palette,
    required this.only,
    required this.accent,
    required this.lit,
    required this.leftStick,
    required this.rightStick,
    required this.routes,
    required this.layout,
  });

  final RetroPadArt art;
  final PadArtPalette palette;
  final String only;
  final Color accent;
  final Map<PadButton, double> lit;
  final Offset leftStick;
  final Offset rightStick;
  final List<_Route> routes;
  final _PadLayout layout;

  double _amount(PadButton? button) => button == null ? 0 : (lit[button] ?? 0).clamp(0.0, 1.0);

  Color _hot(PadButton? button) => _signColors[button] ?? accent;

  Offset _shift(PadButton? button) => switch (button) {
    null => Offset.zero,
    PadButton.l3 => leftStick * _stickReach,
    PadButton.r3 => rightStick * _stickReach,
    _ => Offset(0, _amount(button) * (_travel[button] ?? 3)),
  };

  Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;

  PadCallout? _calloutFor(PadButton? button) => routes.where((route) => route.callout.button == button).firstOrNull?.callout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(layout.origin.dx, layout.origin.dy);
    canvas.scale(layout.scale);
    final faint = palette.line.withValues(alpha: palette.faint);
    for (final shape in art.shapes) {
      if (shape.only != null && shape.only != only) continue;
      final button = RetroPadArt.buttonOf(shape.id);
      final amount = _amount(button);
      final path = button == null ? shape.path : shape.path.shift(_shift(button));
      switch (shape.role) {
        case PadArtRole.body:
          canvas.drawPath(path, Paint()..color = palette.body);
          canvas.drawPath(path, _stroke(palette.line, 4.4));
        case PadArtRole.part:
          _part(canvas, path, button, amount);
        case PadArtRole.detail:
          canvas.drawPath(path, _stroke(faint, 1.5));
        case PadArtRole.outline:
          canvas.drawPath(path, _stroke(palette.line, 2.8));
        case PadArtRole.ring:
          canvas.drawPath(path, _stroke(palette.line, 4.4));
        case PadArtRole.label:
          canvas.drawPath(path, Paint()..color = palette.label);
        case PadArtRole.led:
          canvas.drawPath(path, Paint()..color = const Color(0xFFFF2A1F));
          canvas.drawPath(path, _stroke(palette.line, 1.4));
        case PadArtRole.symbol:
          canvas.drawPath(path, _stroke(Color.lerp(_hot(button), Colors.white, amount)!, 6));
      }
    }
    canvas.restore();
    final unit = layout.unit;
    for (final route in routes) {
      final callout = route.callout;
      final strong = callout.waiting || callout.focused;
      final color = strong ? accent : (callout.changed ? _amber : Colors.white.withValues(alpha: 0.5));
      final line = Path()..moveTo(route.line.first.dx, route.line.first.dy);
      for (final point in route.line.skip(1)) {
        line.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(line, _stroke(color, (strong ? 2.2 : 1.2) * unit));
      canvas.drawCircle(route.line.last, (strong ? 4.2 : 3) * unit, Paint()..color = color);
    }
  }

  void _part(Canvas canvas, Path path, PadButton? button, double amount) {
    final hot = _hot(button);
    final callout = _calloutFor(button);
    final chosen = callout != null && (callout.focused || callout.waiting);
    if (amount > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = hot.withValues(alpha: 0.8 * amount)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
    final rest = chosen ? Color.lerp(palette.part, accent, 0.4)! : palette.part;
    canvas.drawPath(path, Paint()..color = Color.lerp(rest, hot, amount)!);
    final stick = button == PadButton.l3 || button == PadButton.r3;
    canvas.drawPath(path, _stroke(chosen ? accent : palette.line, chosen ? 5 : (stick ? 4.4 : 2.8)));
    final bounds = path.getBounds();
    if (stick) {
      canvas.drawCircle(bounds.center, 44, _stroke(palette.line.withValues(alpha: palette.faint), 1.5));
    }
    if (_shoulderNames[button] case final String name) {
      final text = TextPainter(
        text: TextSpan(
          text: name,
          style: AppText.display(22, weight: FontWeight.w700, color: Color.lerp(palette.label, Colors.white, amount)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, bounds.center - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_PadArtPainter old) => true;
}
