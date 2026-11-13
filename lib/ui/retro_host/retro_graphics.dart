import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/retro_host/retro_graphics_catalog.dart';
import '../../core/retro_host/retro_graphics_optimizer.dart';
import '../../core/retro_host/retro_graphics_profile.dart';
import '../../core/retro_host/retro_hardware.dart';
import '../../core/retro_host/retro_host_protocol.dart';
import 'retro_frame_monitor.dart';
import 'retro_host_game.dart';

/// What the speed check after the Auto Optimizer's Apply found.
class RetroSpeedCheck {
  const RetroSpeedCheck({required this.rate, required this.target, required this.held, this.lowered});

  /// Frames per second measured with the new settings.
  final double rate;

  /// The game's own rate it was held against.
  final double target;

  /// The game kept its rate.
  final bool held;

  /// The setting lowered one notch and the label of its new value; null when the game held, or
  /// when nothing was left to lower.
  final ({String key, String label})? lowered;
}

/// The Graphics page of one game in the emulator host: its picture settings, the presets, and the
/// Auto Optimizer with its preview, Apply, Undo and speed check. What the player chooses is kept
/// in [profile] once the host took it, and [save] is called after each change. It shows no widget
/// itself: the launcher's page lists the settings and calls the actions.
class RetroGraphics extends ChangeNotifier {
  RetroGraphics(
    this.game, {
    required this.profile,
    required this.save,
    this.readHardware,
    this.monitor,
    this.warmup = const Duration(seconds: 1),
    this.measureFor = const Duration(seconds: 3),
    this.tolerance = 0.93,
  }) {
    game.addListener(_notify);
  }

  final RetroHostGame game;
  final RetroGraphicsProfile profile;
  final void Function() save;

  /// Reads the computer for the Auto Optimizer; none where it cannot be read.
  final Future<RetroHardware?> Function()? readHardware;

  /// Counts the game's frames for the speed check; no check without one.
  final RetroFrameMonitor? monitor;

  /// How long the game plays with new settings before its speed is measured, and for how long.
  final Duration warmup;
  final Duration measureFor;

  /// The share of the game's own rate it must keep to count as holding it.
  final double tolerance;

  /// Told when a speed check is done.
  void Function(RetroSpeedCheck check)? onChecked;

  int _generation = 0;
  bool _busy = false;
  bool _disposed = false;

  Map<String, RetroOption> get _options => game.status?.options ?? const {};

  /// The page's settings the host offers now, in the page's order.
  List<(RetroGraphicsSetting, RetroOption)> get settings => RetroGraphicsCatalog.present(_options);

  /// Whether the host offers any of the page's settings.
  bool get available => settings.isNotEmpty;

  /// The preset the settings match, or null for the player's own look.
  RetroGraphicsPreset? get preset => RetroGraphicsCatalog.matching(_options);

  /// A change is being sent to the host.
  bool get busy => _busy;

  /// The player chose [value] for [key]: it is sent to the host, and the Auto Optimizer's Undo is
  /// forgotten. False when the host refused it or another change is still being sent.
  Future<bool> choose(String key, String value) => _manual(() => _set(key, value));

  /// The player chose [preset]: each of its values the host offers is sent, and the Auto
  /// Optimizer's Undo is forgotten.
  Future<bool> choosePreset(RetroGraphicsPreset preset) =>
      _manual(() => _setAll(() => RetroGraphicsCatalog.presetValues(preset, _options)));

  Future<bool> _manual(Future<bool> Function() change) async {
    if (_busy || !game.loaded) return false;
    _forgetOptimizer();
    return _exclusive(change);
  }

  Future<bool> _exclusive(Future<bool> Function() change) async {
    _busy = true;
    _notify();
    try {
      return await change();
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<bool> _set(String key, String value) async {
    if (!await game.setOption(key, value)) return false;
    profile.options[key] = value;
    save();
    return true;
  }

  /// Sends what [wanted] gives that differs from the game's settings, then once more for any that
  /// appeared with the first (the PGXP options once geometry correction is on).
  Future<bool> _setAll(Map<String, String> Function() wanted) async {
    var all = true;
    for (var pass = 0; pass < 2; pass++) {
      final changes = {
        for (final MapEntry(:key, :value) in wanted().entries)
          if (RetroGraphicsCatalog.selectedValue(_options[key]!) != value) key: value,
      };
      for (final MapEntry(:key, :value) in changes.entries) {
        if (!game.loaded) return false;
        all = await _set(key, value) && all;
      }
    }
    return all;
  }

  void _forgetOptimizer() {
    _generation++;
    _check = null;
    _checking = false;
    if (profile.optimized != null) {
      profile.optimized = null;
      save();
    }
  }

  /// The computer is being read.
  bool get reading => _reading;
  bool _reading = false;

  /// The Auto Optimizer's last answer; null before Preview.
  RetroOptimizeResult? get result => _result;
  RetroOptimizeResult? _result;

  /// What Apply would change: each setting's key with the value it would get.
  Map<String, String> get proposed => _result?.advice?.changesFrom(_options) ?? const {};

  /// Reads the computer and works out what the Auto Optimizer suggests.
  Future<void> preview() async {
    if (_reading) return;
    _reading = true;
    _notify();
    RetroHardware? hardware;
    try {
      hardware = await readHardware?.call();
    } on Object {
      hardware = null;
    }
    final status = game.status;
    _result = status == null
        ? (advice: null, blocked: RetroOptimizeBlock.noHardware)
        : RetroGraphicsOptimizer.recommend(hardware: hardware, status: status);
    _reading = false;
    _notify();
  }

  /// Gives the game what the preview suggests, keeps what it changed for Undo, and then checks
  /// the game's speed. False when there is nothing to change or the host took none of it.
  Future<bool> apply() async {
    final advice = _result?.advice;
    if (advice == null || _busy || !game.loaded) return false;
    final options = _options;
    final changes = advice.changesFrom(options);
    if (changes.isEmpty) return false;
    final baseline = monitor?.steadyRate;
    final generation = ++_generation;
    _check = null;
    final changed = await _exclusive(() async {
      final record = <String, RetroOptimizedValue>{...?profile.optimized};
      var any = false;
      for (final MapEntry(:key, :value) in changes.entries) {
        final before = RetroGraphicsCatalog.selectedValue(options[key]!);
        final saved = profile.options[key];
        if (!await _set(key, value)) continue;
        any = true;
        final earlier = record[key];
        record[key] = (
          before: earlier?.before ?? before,
          saved: earlier == null ? saved : earlier.saved,
          applied: value,
        );
      }
      if (any) {
        profile.optimized = record;
        save();
      }
      return any;
    });
    if (changed && monitor != null && generation == _generation) unawaited(_checkSpeed(generation, baseline));
    return changed;
  }

  /// The game's speed is being measured after Apply.
  bool get checking => _checking;
  bool _checking = false;

  /// What the last speed check found; forgotten by a manual change or Undo.
  RetroSpeedCheck? get lastCheck => _check;
  RetroSpeedCheck? _check;

  Future<void> _checkSpeed(int generation, double? baseline) async {
    _checking = true;
    _notify();
    final rate = await monitor!.measure(
      warmup: warmup,
      span: measureFor,
      ready: () => !(game.status?.graphicsPending ?? false),
    );
    if (generation != _generation || _disposed) return;
    _checking = false;
    if (rate == null) {
      _notify();
      return;
    }
    final target = baseline ?? standardRate(rate);
    if (rate >= target * tolerance) {
      _finishCheck(RetroSpeedCheck(rate: rate, target: target, held: true));
      return;
    }
    final step = RetroGraphicsOptimizer.stepDown(_options);
    ({String key, String label})? lowered;
    if (step != null && !_busy) {
      final option = _options[step.key]!;
      final before = RetroGraphicsCatalog.selectedValue(option);
      final saved = profile.options[step.key];
      final taken = await _exclusive(() => _set(step.key, step.value));
      if (generation != _generation || _disposed) return;
      if (taken) {
        final record = <String, RetroOptimizedValue>{...?profile.optimized};
        final earlier = record[step.key];
        record[step.key] = (
          before: earlier?.before ?? before,
          saved: earlier == null ? saved : earlier.saved,
          applied: step.value,
        );
        profile.optimized = record;
        save();
        lowered = (key: step.key, label: RetroGraphicsCatalog.label(option, step.value));
      }
    }
    _finishCheck(RetroSpeedCheck(rate: rate, target: target, held: false, lowered: lowered));
  }

  void _finishCheck(RetroSpeedCheck check) {
    _check = check;
    _notify();
    onChecked?.call(check);
  }

  /// The PS1's own frame rate nearest above [rate], for a check with no rate measured before
  /// Apply: about 60 (NTSC) or 50 (PAL) frames a second.
  static double standardRate(double rate) => rate >= 54.9 ? 59.94 : 50;

  /// Whether Undo has something to put back.
  bool get canUndo => profile.optimized != null;

  /// Puts back what the Auto Optimizer changed, when every one of its settings still has the value
  /// it gave; otherwise Undo is forgotten and false returned.
  Future<bool> undo() async {
    final record = profile.optimized;
    if (record == null || _busy || !game.loaded) return false;
    _generation++;
    _check = null;
    _checking = false;
    final options = _options;
    final kept = record.entries.every(
      (entry) =>
          options[entry.key] == null || RetroGraphicsCatalog.selectedValue(options[entry.key]!) == entry.value.applied,
    );
    if (!kept) {
      profile.optimized = null;
      save();
      _notify();
      return false;
    }
    return _exclusive(() async {
      for (final MapEntry(:key, :value) in record.entries) {
        if (options[key] != null) await game.setOption(key, value.before);
        if (value.saved case final String saved) {
          profile.options[key] = saved;
        } else {
          profile.options.remove(key);
        }
      }
      profile.optimized = null;
      save();
      return true;
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    game.removeListener(_notify);
    super.dispose();
  }
}
