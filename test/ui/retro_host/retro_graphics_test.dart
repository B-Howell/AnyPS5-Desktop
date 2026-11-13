import 'package:anyps5_desktop/core/retro_host/retro_graphics_catalog.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_optimizer.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_profile.dart';
import 'package:anyps5_desktop/core/retro_host/retro_hardware.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_frame_monitor.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_graphics.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_option_session.dart';
import 'fake_retro_host_session.dart';

const _gib = 1 << 30;
const _pc = RetroHardware(
  displayHeight: 1440,
  adapters: [RetroAdapter(name: 'GeForce RTX 3070', dedicatedBytes: 8 * _gib)],
  logicalProcessors: 16,
);

/// A game playing in a fake host with the recorded host's options, its frames sent by hand on a
/// clock the test moves.
class _Playing {
  _Playing({Map<String, List<String>>? offered, RetroHardware? hardware = _pc})
    : session = FakeOptionSession(offered: offered) {
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    monitor = RetroFrameMonitor(game, clock: () => now);
    graphics = RetroGraphics(
      game,
      profile: profile,
      save: () => saves++,
      readHardware: () async => hardware,
      monitor: monitor,
    );
  }

  final FakeOptionSession session;
  late final RetroHostGame game;
  late final RetroFrameMonitor monitor;
  late final RetroGraphics graphics;
  final profile = RetroGraphicsProfile();
  final slot = FakeSlot(4, 4);
  var saves = 0;
  var now = Duration.zero;

  Future<void> start() async {
    session.readyCompleter.complete();
    await game.start(const RetroHostStartRequest(core: 'core', disc: 'disc.cue', system: 'system', saves: 'saves'));
    expect(game.phase, RetroHostGamePhase.playing);
  }

  /// [seconds] of frames at [rate] a second.
  void play(double seconds, double rate) {
    final step = Duration(microseconds: (1000000 / rate).round());
    final end = now + Duration(microseconds: (seconds * 1000000).round());
    while (now < end) {
      now += step;
      session.send(slot.pin());
    }
  }

  Future<void> dispose() async {
    graphics.dispose();
    monitor.dispose();
    await game.shutdown();
    game.dispose();
    slot.free();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the settings the host offers, in the page\'s order, starting on Original', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    final graphics = playing.graphics;
    expect(graphics.available, isTrue);
    expect(graphics.settings.first.$1.key, RetroGraphicsCatalog.resolution);
    expect(graphics.preset, RetroGraphicsPreset.original);
  });

  test('a preset sends each value the host offers, then the PGXP options that showed up', () async {
    final playing = _Playing(
      offered: {
        RetroGraphicsCatalog.resolution: ['1', '2', '3'],
      },
    );
    addTearDown(playing.dispose);
    await playing.start();
    expect(await playing.graphics.choosePreset(RetroGraphicsPreset.maximum), isTrue);
    final session = playing.session;
    expect(session.chosen(RetroGraphicsCatalog.resolution), '3', reason: 'the largest the host offers');
    expect(session.chosen(RetroGraphicsCatalog.textureFilter), 'xBR');
    expect(session.chosen(RetroGraphicsCatalog.antialiasing), '4');
    expect(session.chosen(RetroGraphicsCatalog.pgxp), 'true');
    expect(session.chosen(RetroGraphicsCatalog.pgxpTextures), 'true');
    expect(playing.graphics.preset, RetroGraphicsPreset.maximum);
    expect(playing.profile.options[RetroGraphicsCatalog.resolution], '3');
    expect(playing.profile.options, isNot(contains(RetroGraphicsCatalog.widescreen)));
    expect(playing.saves, greaterThan(0));

    expect(await playing.graphics.choosePreset(RetroGraphicsPreset.original), isTrue);
    expect(session.chosen(RetroGraphicsCatalog.pgxp), 'false');
    expect(playing.graphics.preset, RetroGraphicsPreset.original);
  });

  test('a value the host refuses is not kept', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    playing.session.refused[RetroGraphicsCatalog.trueColor] = {'true'};
    expect(await playing.graphics.choose(RetroGraphicsCatalog.trueColor, 'true'), isFalse);
    expect(playing.profile.options, isEmpty);
    expect(await playing.graphics.choose(RetroGraphicsCatalog.widescreen, 'true'), isTrue);
    expect(playing.profile.options, {RetroGraphicsCatalog.widescreen: 'true'});
    expect(playing.graphics.preset, RetroGraphicsPreset.original, reason: 'the presets leave widescreen to the player');
    expect(await playing.graphics.choose(RetroGraphicsCatalog.antialiasing, '2'), isTrue);
    expect(playing.graphics.preset, isNull);
  });

  test('preview, Apply and Undo: only values offered, the player\'s saved values put back', () async {
    final playing = _Playing(
      offered: {
        RetroGraphicsCatalog.resolution: ['1', '2', '3'],
      },
    );
    addTearDown(playing.dispose);
    await playing.start();
    final graphics = playing.graphics;
    expect(await graphics.choose(RetroGraphicsCatalog.resolution, '2'), isTrue);
    expect(graphics.canUndo, isFalse);

    await graphics.preview();
    expect(graphics.result?.advice?.adapter.name, 'GeForce RTX 3070');
    expect(graphics.proposed, {
      RetroGraphicsCatalog.resolution: '3',
      RetroGraphicsCatalog.textureFilter: 'BilinearBinAlpha',
      RetroGraphicsCatalog.antialiasing: '2',
      RetroGraphicsCatalog.pgxp: 'true',
      RetroGraphicsCatalog.chromaSmoothing: 'true',
    });
    expect(await graphics.apply(), isTrue);
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '3');
    expect(graphics.proposed, isEmpty);
    expect(graphics.canUndo, isTrue);
    expect(playing.profile.optimized?[RetroGraphicsCatalog.resolution], (before: '2', saved: '2', applied: '3'));
    expect(playing.profile.optimized?[RetroGraphicsCatalog.pgxp], (before: 'false', saved: null, applied: 'true'));

    expect(await graphics.undo(), isTrue);
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '2');
    expect(playing.session.chosen(RetroGraphicsCatalog.pgxp), 'false');
    expect(playing.profile.options, {RetroGraphicsCatalog.resolution: '2'});
    expect(playing.profile.optimized, isNull);
    expect(graphics.canUndo, isFalse);
  });

  test('a change by hand forgets Undo', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    final graphics = playing.graphics;
    await graphics.preview();
    await graphics.apply();
    expect(graphics.canUndo, isTrue);
    await graphics.choose(RetroGraphicsCatalog.trueColor, 'true');
    expect(graphics.canUndo, isFalse);
    expect(playing.profile.optimized, isNull);
    expect(await graphics.undo(), isFalse);

    await graphics.apply();
    await graphics.preview();
    await graphics.apply();
    expect(graphics.canUndo, isFalse, reason: 'nothing left to change');
    await graphics.choosePreset(RetroGraphicsPreset.enhanced);
    expect(graphics.canUndo, isFalse);
  });

  test('Undo is forgotten when a setting it gave was changed elsewhere', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    await playing.graphics.preview();
    await playing.graphics.apply();
    await playing.game.setOption(RetroGraphicsCatalog.resolution, '2');
    expect(await playing.graphics.undo(), isFalse);
    expect(playing.graphics.canUndo, isFalse);
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '2');
  });

  test('nothing to apply when the computer cannot be read or the game draws in software', () async {
    final playing = _Playing(hardware: null);
    addTearDown(playing.dispose);
    await playing.start();
    await playing.graphics.preview();
    expect(playing.graphics.result?.blocked, RetroOptimizeBlock.noHardware);
    expect(await playing.graphics.apply(), isFalse);

    final software = _Playing()..session.hardware = false;
    addTearDown(software.dispose);
    await software.start();
    await software.graphics.preview();
    expect(software.graphics.result?.blocked, RetroOptimizeBlock.software);
  });

  test('after Apply the game holding its rate is told, measured once it plays again', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    final checks = <RetroSpeedCheck>[];
    playing.graphics.onChecked = checks.add;
    playing.play(3, 59.94);
    await playing.game.pause(true);
    await playing.graphics.preview();
    expect(await playing.graphics.apply(), isTrue);
    expect(playing.graphics.checking, isTrue);
    playing.play(10, 59.94);
    expect(checks, isEmpty, reason: 'frames that come while paused do not count');
    await playing.game.pause(false);
    playing.play(4.2, 59.5);
    await pumpEventQueue();
    expect(checks, hasLength(1));
    expect(checks.single.held, isTrue);
    expect(checks.single.target, closeTo(59.94, 0.1), reason: 'the rate before Apply');
    expect(checks.single.rate, closeTo(59.5, 0.2));
    expect(playing.graphics.checking, isFalse);
    expect(playing.graphics.lastCheck, same(checks.single));
  });

  test('a game that cannot keep its rate is stepped down one resolution and told', () async {
    final playing = _Playing(
      offered: {
        RetroGraphicsCatalog.resolution: ['1', '2', '3', '4'],
      },
    );
    addTearDown(playing.dispose);
    await playing.start();
    final checks = <RetroSpeedCheck>[];
    playing.graphics.onChecked = checks.add;
    playing.play(3, 59.94);
    await playing.graphics.preview();
    await playing.graphics.apply();
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '4');
    playing.play(4.2, 41);
    await pumpEventQueue();
    expect(checks.single.held, isFalse);
    expect(checks.single.lowered, (key: RetroGraphicsCatalog.resolution, label: '3x (for 720p)'));
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '3');
    expect(playing.profile.options[RetroGraphicsCatalog.resolution], '3');
    expect(playing.profile.optimized?[RetroGraphicsCatalog.resolution], (before: '1', saved: null, applied: '3'));
    expect(await playing.graphics.undo(), isTrue, reason: 'Undo still puts back what the game had');
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '1');
  });

  test('with no rate before Apply the PS1\'s own rate is the target; a change by hand stops the check', () async {
    expect(RetroGraphics.standardRate(59), 59.94);
    expect(RetroGraphics.standardRate(49.7), 50);
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    final checks = <RetroSpeedCheck>[];
    playing.graphics.onChecked = checks.add;
    await playing.graphics.preview();
    await playing.graphics.apply();
    playing.play(2, 59.94);
    await playing.graphics.choose(RetroGraphicsCatalog.widescreen, 'true');
    expect(playing.graphics.checking, isFalse);
    playing.play(4, 30);
    await pumpEventQueue();
    expect(checks, isEmpty);
    expect(playing.session.chosen(RetroGraphicsCatalog.resolution), '4');
  });

  test('a speed check ends without a result when the game ends', () async {
    final playing = _Playing();
    addTearDown(playing.dispose);
    await playing.start();
    await playing.graphics.preview();
    await playing.graphics.apply();
    await playing.game.stop();
    await pumpEventQueue();
    expect(playing.graphics.checking, isFalse);
    expect(playing.graphics.lastCheck, isNull);
  });
}
