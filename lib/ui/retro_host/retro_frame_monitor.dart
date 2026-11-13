import 'dart:async';

import '../../core/retro_host/retro_frame_rate.dart';
import '../../core/retro_host/retro_host_client.dart';
import 'retro_host_game.dart';

/// How fast a [RetroHostGame]'s frames come, counted from the client's frame events while the
/// game plays and is not paused. The host publishes a frame for each `retro_run` that draws one,
/// at the core's own rate, so a slower rate means the computer could not keep up.
class RetroFrameMonitor {
  RetroFrameMonitor(
    this.game, {
    Duration Function()? clock,
    this.steady = const Duration(seconds: 2),
    Duration window = const Duration(seconds: 3),
  }) : _clock = clock ?? _stopwatch(),
       _meter = RetroFrameRate(window: window) {
    _frames = game.session.frames.listen(_onFrame);
    game.addListener(_onGame);
  }

  final RetroHostGame game;

  /// How long play must last for its rate to count as the game's steady rate.
  final Duration steady;

  final Duration Function() _clock;
  final RetroFrameRate _meter;
  late final StreamSubscription<RetroFrameEvent> _frames;
  final _measures = <_Measure>[];
  double? _lastSteady;
  bool _disposed = false;

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  bool get _running => game.phase == RetroHostGamePhase.playing && !game.paused;

  /// The rate of the play going on now once it has lasted [steady], otherwise of the last play
  /// that did (before a pause or the menu); null before any did.
  double? get steadyRate => _meter.span >= steady ? _meter.rate : _lastSteady;

  /// Measures the rate over [span] of play, after [warmup] of it. Play counts only while the game
  /// runs, is not paused and [ready] says so; whatever stops it starts the wait again. Null when
  /// the game ends or the monitor is disposed first.
  Future<double?> measure({required Duration warmup, required Duration span, bool Function()? ready}) {
    if (_disposed || !game.loaded) return Future.value();
    final measure = _Measure(warmup, span, ready ?? () => true);
    _measures.add(measure);
    return measure.done.future;
  }

  void _onFrame(RetroFrameEvent event) {
    if (!event.drawn || !_running) return;
    final now = _clock();
    _meter.add(now);
    for (final measure in List.of(_measures)) {
      final rate = measure.frame(now);
      if (rate != null) _finish(measure, rate);
    }
  }

  void _onGame() {
    if (!_running) {
      if (_meter.span >= steady) _lastSteady = _meter.rate;
      _meter.reset();
      for (final measure in _measures) {
        measure.restart();
      }
    }
    if (!game.loaded && game.phase != RetroHostGamePhase.starting) {
      for (final measure in List.of(_measures)) {
        _finish(measure, null);
      }
    }
  }

  void _finish(_Measure measure, double? rate) {
    _measures.remove(measure);
    if (!measure.done.isCompleted) measure.done.complete(rate);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_frames.cancel());
    game.removeListener(_onGame);
    for (final measure in List.of(_measures)) {
      _finish(measure, null);
    }
  }
}

/// One measure: the frames that come from the end of its warm-up until its span has passed, over
/// the time since the warm-up ended, so a stall anywhere after the warm-up lowers the rate.
class _Measure {
  _Measure(this.warmup, this.span, this.ready);

  final Duration warmup;
  final Duration span;
  final bool Function() ready;
  final done = Completer<double?>();
  Duration? _start;
  var _frames = 0;

  void restart() {
    _start = null;
    _frames = 0;
  }

  /// A frame at [now]: the rate once [span] after [warmup] has been measured, otherwise null.
  double? frame(Duration now) {
    if (!ready()) {
      restart();
      return null;
    }
    final from = (_start ??= now) + warmup;
    if (now <= from) return null;
    _frames++;
    if (now - from < span) return null;
    return _frames * Duration.microsecondsPerSecond / (now - from).inMicroseconds;
  }
}
