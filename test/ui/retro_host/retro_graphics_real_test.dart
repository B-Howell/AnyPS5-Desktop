import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_graphics_catalog.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_profile.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_frame_monitor.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_graphics.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'real_host_support.dart';

/// The Graphics page against the real emulator host: SwanStation runs the OpenBIOS test program,
/// the Enhanced preset is applied through [RetroGraphics], the host takes every value, and the
/// game's frames still come at close to 60 a second, counted by [RetroFrameMonitor] from the
/// client's frame events.
///
/// ANYPS5_RETRO_HOST_REAL names the JSON file of test/core/retro_host/retro_host_real_test.dart.
/// Without it the test is skipped, so CI skips it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['ANYPS5_RETRO_HOST_REAL'];
  if (configPath == null || configPath.isEmpty) {
    test('Enhanced keeps the game near 60 frames a second', () {}, skip: 'ANYPS5_RETRO_HOST_REAL is not set');
    return;
  }
  final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
  String path(String key) => File(config[key]! as String).absolute.path;
  final environment = (config['environment'] as Map<String, Object?>?)?.cast<String, String>();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('retro-graphics-real-'));
  tearDown(() => work.deleteSync(recursive: true));

  test('Enhanced keeps the game near 60 frames a second', () async {
    final system = Directory(p.join(work.path, 'system'))..createSync();
    File(path('bios')).copySync(p.join(system.path, 'openbios.bin'));
    final disc = p.join(work.path, 'program.cue');
    final built = Process.runSync(pythonPath(), [path('discBuilder'), path('program'), disc]);
    expect(built.exitCode, 0, reason: 'make_test_disc.py: ${built.stderr}');

    final game = RetroHostGame.launch(command: [path('host')], environment: environment, volume: 0, muted: true);
    final monitor = RetroFrameMonitor(game);
    final profile = RetroGraphicsProfile();
    final graphics = RetroGraphics(game, profile: profile, save: () {}, monitor: monitor);
    try {
      await game.start(
        RetroHostStartRequest(
          core: path('core'),
          disc: disc,
          system: system.path,
          saves: p.join(work.path, 'saves'),
          options: const {
            'swanstation_BIOS_PathNTSCU': 'openbios.bin',
            'swanstation_BIOS_PathNTSCJ': 'openbios.bin',
            'swanstation_BIOS_PathPAL': 'openbios.bin',
          },
        ),
      );
      await until(() => game.phase != RetroHostGamePhase.loading, const Duration(seconds: 60));
      expect(game.phase, RetroHostGamePhase.playing, reason: 'status ${game.status?.toJson()} ${game.failure}');
      expect(game.status?.hardware, isTrue, reason: 'the resolution needs the OpenGL renderer');
      expect(graphics.preset, RetroGraphicsPreset.original);

      final before = await monitor.measure(warmup: const Duration(seconds: 1), span: const Duration(seconds: 3));
      stdout.writeln('before: ${before?.toStringAsFixed(2)} frames a second');

      expect(await graphics.choosePreset(RetroGraphicsPreset.enhanced), isTrue);
      await until(() async {
        await game.refresh();
        return !(game.status?.graphicsPending ?? true);
      }, const Duration(seconds: 10));
      final options = game.status!.options;
      final wanted = RetroGraphicsCatalog.presetValues(RetroGraphicsPreset.enhanced, options);
      stdout.writeln('enhanced: $wanted');
      expect(graphics.preset, RetroGraphicsPreset.enhanced);
      for (final MapEntry(:key, :value) in wanted.entries) {
        expect(options[key]!.activeValue, value, reason: '$key is given to the core');
      }
      expect(options[RetroGraphicsCatalog.pgxpTextures], isNotNull, reason: 'the PGXP options showed up');
      expect(profile.options[RetroGraphicsCatalog.resolution], wanted[RetroGraphicsCatalog.resolution]);

      final after = await monitor.measure(
        warmup: const Duration(seconds: 1),
        span: const Duration(seconds: 3),
        ready: () => !(game.status?.graphicsPending ?? false),
      );
      stdout.writeln('after: ${after?.toStringAsFixed(2)} frames a second');
      expect(after, isNotNull);
      expect(after, greaterThan(54), reason: 'the frames still come at close to 60 a second');
      expect(game.phase, RetroHostGamePhase.playing);

      final stopped = await game.stop();
      expect(stopped?.errorCode, RetroErrorCode.none);
    } finally {
      graphics.dispose();
      monitor.dispose();
      await game.shutdown();
      game.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
