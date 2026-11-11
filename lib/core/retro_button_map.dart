import 'gamepad/pad_navigation.dart';

enum RetroControlPreset { standard, swapCrossCircle, custom }

final class RetroButtonMap {
  const RetroButtonMap._(this._targets, this.swapSticks);

  static const standard = RetroButtonMap._({}, false);
  static const swapCrossCircle = RetroButtonMap._({PadButton.south: PadButton.east, PadButton.east: PadButton.south}, false);

  static const buttons = [
    PadButton.south,
    PadButton.east,
    PadButton.west,
    PadButton.north,
    PadButton.dpadUp,
    PadButton.dpadDown,
    PadButton.dpadLeft,
    PadButton.dpadRight,
    PadButton.l1,
    PadButton.r1,
    PadButton.l2,
    PadButton.r2,
    PadButton.l3,
    PadButton.r3,
    PadButton.select,
    PadButton.start,
  ];

  /// The inputs by where they sit on a controller seen from the front, top to bottom: the
  /// Controls page puts their labels on that side and moves the focus through them that way.
  static const leftSide = [
    PadButton.l2,
    PadButton.l1,
    PadButton.dpadUp,
    PadButton.dpadLeft,
    PadButton.dpadDown,
    PadButton.dpadRight,
    PadButton.l3,
  ];
  static const rightSide = [
    PadButton.r2,
    PadButton.r1,
    PadButton.north,
    PadButton.east,
    PadButton.south,
    PadButton.west,
    PadButton.r3,
  ];
  static const topSide = [PadButton.select, PadButton.start];

  final Map<PadButton, PadButton?> _targets;
  final bool swapSticks;

  PadButton? target(PadButton button) => _targets.containsKey(button) ? _targets[button] : button;

  RetroButtonMap assign(PadButton button, PadButton? function) {
    final targets = {..._targets};
    if (function == button) {
      targets.remove(button);
    } else {
      targets[button] = function;
    }
    return RetroButtonMap._(Map.unmodifiable(targets), swapSticks);
  }

  RetroButtonMap withSwapSticks(bool value) => RetroButtonMap._(_targets, value);

  /// The first button that does [function], or null when none does.
  PadButton? source(PadButton function) => buttons.where((button) => target(button) == function).firstOrNull;

  /// Every button that does [function], in the order of [buttons].
  List<PadButton> sources(PadButton function) => [
    for (final button in buttons)
      if (target(button) == function) button,
  ];

  /// [function] moved onto [button]. The button that did it before takes over what [button] did,
  /// so the two trade places. An input that had no button leaves what [button] did without one,
  /// and extra buttons an older layout gave the same input are left unused, so [function] always
  /// ends with [button] alone. Null leaves [function] without a button.
  RetroButtonMap give(PadButton function, PadButton? button) {
    final before = sources(function);
    if (before.length == 1 && before.single == button) return this;
    if (button == null) return before.fold(this, (map, source) => map.assign(source, null));
    final displaced = target(button);
    var next = assign(button, function);
    for (final (index, source) in before.where((source) => source != button).indexed) {
      next = next.assign(source, index == 0 && displaced != function ? displaced : null);
    }
    return next;
  }

  bool get isStandard => _targets.isEmpty && !swapSticks;

  RetroControlPreset get preset {
    if (isStandard) return RetroControlPreset.standard;
    if (!swapSticks &&
        _targets.length == 2 &&
        _targets[PadButton.south] == PadButton.east &&
        _targets[PadButton.east] == PadButton.south) {
      return RetroControlPreset.swapCrossCircle;
    }
    return RetroControlPreset.custom;
  }

  Set<PadButton> map(Iterable<PadButton> held) => {
    for (final button in held)
      if (target(button) case final PadButton mapped) mapped,
  };

  Map<String, Object> toJson() => {
    for (final MapEntry(:key, :value) in _targets.entries) key.name: value?.name ?? '',
    if (swapSticks) 'swapSticks': true,
  };

  static RetroButtonMap fromJson(Object? json) {
    if (json is! Map) return standard;
    final targets = <PadButton, PadButton?>{};
    for (final button in buttons) {
      final value = json[button.name];
      if (value is! String) continue;
      if (value.isEmpty) {
        targets[button] = null;
      } else if (buttons.where((candidate) => candidate.name == value).firstOrNull case final PadButton function) {
        if (function != button) targets[button] = function;
      }
    }
    return RetroButtonMap._(Map.unmodifiable(targets), json['swapSticks'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is RetroButtonMap &&
      other.swapSticks == swapSticks &&
      other._targets.length == _targets.length &&
      _targets.entries.every((entry) => other._targets.containsKey(entry.key) && other._targets[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(swapSticks, Object.hashAllUnordered(_targets.entries.map((e) => Object.hash(e.key, e.value))));
}
