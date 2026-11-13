import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_frame_monitor.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRetroHostSession session;
  late RetroHostGame game;
  late RetroFrameMonitor monitor;
  late FakeSlot slot;
  var now = Duration.zero;

  void play(double seconds, double rate, {bool drawn = true}) {
    final step = Duration(microseconds: (1000000 / rate).round());
    final end = now + Duration(microseconds: (seconds * 1000000).round());
    while (now < end) {
      now += step;
      session.send(slot.pin(), drawn: drawn);
    }
  }

  setUp(() async {
    now = Duration.zero;
    slot = FakeSlot(2, 2);
    session = FakeRetroHostSession()..nextStatus = fakeStatus();
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    monitor = RetroFrameMonitor(game, clock: () => now);
    session.readyCompleter.complete();
    await game.start(const RetroHostStartRequest(core: 'c', disc: 'd.cue', system: 's', saves: 'v'));
  });

  tearDown(() async {
    monitor.dispose();
    await game.shutdown();
    game.dispose();
    slot.free();
  });

  test('the steady rate needs two seconds of play, and outlasts a pause', () async {
    play(1, 60);
    expect(monitor.steadyRate, isNull);
    play(1.5, 60);
    expect(monitor.steadyRate, closeTo(60, 0.1));
    await game.pause(true);
    play(2, 30);
    expect(monitor.steadyRate, closeTo(60, 0.1), reason: 'frames while paused do not count');
    await game.pause(false);
    play(0.5, 30);
    expect(monitor.steadyRate, closeTo(60, 0.1), reason: 'the play before the pause, until this one is steady');
    play(2, 30);
    expect(monitor.steadyRate, closeTo(30, 0.1));
  });

  test('a measure skips its warm-up, waits while not ready, and starts again after a pause', () async {
    var ready = false;
    final measured = monitor.measure(
      warmup: const Duration(seconds: 1),
      span: const Duration(seconds: 2),
      ready: () => ready,
    );
    double? result;
    measured.then((rate) => result = rate).ignore();
    play(5, 20);
    await pumpEventQueue();
    expect(result, isNull, reason: 'not ready yet');
    ready = true;
    play(2, 60);
    await game.pause(true);
    await game.pause(false);
    play(1, 10);
    play(2.1, 50);
    await pumpEventQueue();
    expect(result, closeTo(50, 0.5), reason: 'after the pause: a second of warm-up, then two of play');
  });

  test('frames not drawn do not count, and a measure ends with the game', () async {
    play(3, 60, drawn: false);
    expect(monitor.steadyRate, isNull);
    final measured = monitor.measure(warmup: Duration.zero, span: const Duration(seconds: 1));
    await game.stop();
    expect(await measured, isNull);
    expect(await monitor.measure(warmup: Duration.zero, span: const Duration(seconds: 1)), isNull);
  });

  test('a stall while the game runs lowers the measured rate', () async {
    final measured = monitor.measure(warmup: const Duration(seconds: 1), span: const Duration(seconds: 3));
    play(1.5, 60);
    now += const Duration(milliseconds: 4500);
    play(0.05, 60);
    final rate = await measured;
    expect(rate, lessThan(10), reason: 'half a second of frames over five seconds');
  });

  test('a stall across the end of the warm-up counts too', () async {
    final measured = monitor.measure(warmup: const Duration(seconds: 1), span: const Duration(seconds: 3));
    play(0.9, 60);
    now += const Duration(milliseconds: 4500);
    play(0.05, 60);
    expect(await measured, lessThan(1), reason: 'three frames in more than four seconds after the warm-up');
  });
}
