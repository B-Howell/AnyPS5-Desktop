import 'dart:collection';

/// Frames per second over the last [window] of frame times.
class RetroFrameRate {
  RetroFrameRate({this.window = const Duration(seconds: 3)});

  final Duration window;
  final _times = Queue<Duration>();

  /// A frame came at [at], a time on one steady clock.
  void add(Duration at) {
    _times.addLast(at);
    while (_times.length > 1 && at - _times.first > window) {
      _times.removeFirst();
    }
  }

  void reset() => _times.clear();

  int get count => _times.length;

  /// From the first frame kept to the last.
  Duration get span => _times.isEmpty ? Duration.zero : _times.last - _times.first;

  /// The frames per second between the first frame kept and the last; null with fewer than two.
  double? get rate {
    final seconds = span.inMicroseconds / Duration.microsecondsPerSecond;
    return _times.length < 2 || seconds <= 0 ? null : (_times.length - 1) / seconds;
  }
}
