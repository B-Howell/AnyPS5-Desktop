import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:xml/xml.dart';

import '../core/gamepad/pad_navigation.dart';

/// What a shape of the controller drawing is, which decides how it is painted.
enum PadArtRole { body, part, detail, outline, ring, label, led, symbol }

class PadArtShape {
  const PadArtShape({required this.path, required this.role, this.id, this.only});

  final Path path;
  final PadArtRole role;

  /// `btn-…` for an input, `sym-…` for a face button's sign.
  final String? id;

  /// `analog` for what only the DualShock and DualShock 2 have, `ps` for the DualShock 3's.
  final String? only;
}

/// The Controls page's controller drawing, read from an SVG whose shapes carry an id per input
/// and a `data-role`: swapping the asset swaps the artwork.
class RetroPadArt {
  RetroPadArt._(this.size, this.shapes);

  static const asset = 'assets/retro/controller-dualshock.svg';

  static const _ids = {
    PadButton.south: 'cross',
    PadButton.east: 'circle',
    PadButton.west: 'square',
    PadButton.north: 'triangle',
    PadButton.dpadUp: 'up',
    PadButton.dpadDown: 'down',
    PadButton.dpadLeft: 'left',
    PadButton.dpadRight: 'right',
    PadButton.l1: 'l1',
    PadButton.r1: 'r1',
    PadButton.l2: 'l2',
    PadButton.r2: 'r2',
    PadButton.l3: 'l3',
    PadButton.r3: 'r3',
    PadButton.select: 'select',
    PadButton.start: 'start',
  };

  static Future<RetroPadArt>? _loaded;

  /// The drawing from the launcher's assets, read once.
  static Future<RetroPadArt> load() => _loaded ??= rootBundle.loadString(asset).then(parse);

  static RetroPadArt parse(String svg) {
    final root = XmlDocument.parse(svg).rootElement;
    final box = (root.getAttribute('viewBox') ?? '').split(RegExp(r'[\s,]+')).where((part) => part.isNotEmpty).toList();
    if (box.length != 4) throw const FormatException('The controller drawing has no viewBox.');
    final shapes = <PadArtShape>[];
    for (final element in root.descendantElements) {
      final role = PadArtRole.values.where((role) => role.name == element.getAttribute('data-role')).firstOrNull;
      if (role == null) continue;
      final path = switch (element.name.local) {
        'path' => parsePathData(element.getAttribute('d') ?? ''),
        'circle' => Path()..addOval(
          Rect.fromCircle(center: Offset(_number(element, 'cx'), _number(element, 'cy')), radius: _number(element, 'r')),
        ),
        'rect' => Path()..addRect(
          Rect.fromLTWH(_number(element, 'x'), _number(element, 'y'), _number(element, 'width'), _number(element, 'height')),
        ),
        _ => null,
      };
      if (path == null) continue;
      shapes.add(PadArtShape(path: path, role: role, id: element.getAttribute('id'), only: element.getAttribute('data-only')));
    }
    return RetroPadArt._(Size(double.parse(box[2]), double.parse(box[3])), List.unmodifiable(shapes));
  }

  final Size size;
  final List<PadArtShape> shapes;

  /// The button a shape belongs to: its own (`btn-cross`) or the one its sign is on (`sym-cross`).
  static PadButton? buttonOf(String? id) {
    if (id == null || id.length < 5) return null;
    final name = id.substring(4);
    if (name == 'ps' || name == 'analog') return PadButton.guide;
    return _ids.entries.where((entry) => entry.value == name).firstOrNull?.key;
  }

  /// Where [button] is in the drawing, in the drawing's own units.
  Rect? boundsOf(PadButton button) {
    final id = 'btn-${_ids[button]}';
    return shapes.where((shape) => shape.id == id).firstOrNull?.path.getBounds();
  }

  static double _number(XmlElement element, String name) => double.parse(element.getAttribute(name) ?? '0');
}

final _pathToken = RegExp(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?');

/// An SVG path's `d` as a [Path]: move, line, curve, arc and close commands, absolute or relative.
Path parsePathData(String data) {
  final tokens = [for (final match in _pathToken.allMatches(data)) match[0]!];
  final path = Path();
  var index = 0;
  var command = '';
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  double? controlX, controlY;

  bool isCommand(String token) => token.length == 1 && RegExp('[A-Za-z]').hasMatch(token);
  double next() {
    if (index >= tokens.length || isCommand(tokens[index])) throw FormatException('A number is missing in the path', data);
    return double.parse(tokens[index++]);
  }

  while (index < tokens.length) {
    if (isCommand(tokens[index])) {
      command = tokens[index++];
    } else if (command.isEmpty || command.toUpperCase() == 'Z') {
      throw FormatException('The path has a number with no command', data);
    }
    final relative = command == command.toLowerCase();
    final baseX = relative ? x : 0.0, baseY = relative ? y : 0.0;
    var curved = false;
    switch (command.toUpperCase()) {
      case 'M':
        x = baseX + next();
        y = baseY + next();
        startX = x;
        startY = y;
        path.moveTo(x, y);
        command = relative ? 'l' : 'L';
      case 'L':
        x = baseX + next();
        y = baseY + next();
        path.lineTo(x, y);
      case 'H':
        x = baseX + next();
        path.lineTo(x, y);
      case 'V':
        y = baseY + next();
        path.lineTo(x, y);
      case 'C':
        final x1 = baseX + next(), y1 = baseY + next();
        final x2 = baseX + next(), y2 = baseY + next();
        x = baseX + next();
        y = baseY + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        controlX = x2;
        controlY = y2;
        curved = true;
      case 'S':
        final x1 = controlX == null ? x : 2 * x - controlX, y1 = controlY == null ? y : 2 * y - controlY;
        final x2 = baseX + next(), y2 = baseY + next();
        x = baseX + next();
        y = baseY + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        controlX = x2;
        controlY = y2;
        curved = true;
      case 'Q':
        final x1 = baseX + next(), y1 = baseY + next();
        x = baseX + next();
        y = baseY + next();
        path.quadraticBezierTo(x1, y1, x, y);
      case 'A':
        final radius = Radius.elliptical(next(), next());
        final rotation = next();
        final large = next() != 0, clockwise = next() != 0;
        x = baseX + next();
        y = baseY + next();
        path.arcToPoint(Offset(x, y), radius: radius, rotation: rotation, largeArc: large, clockwise: clockwise);
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('The path command $command is not read', data);
    }
    if (!curved) {
      controlX = null;
      controlY = null;
    }
  }
  return path;
}
