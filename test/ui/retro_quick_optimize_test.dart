import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_optimizer.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

void main() {
  test('unavailable hardware cannot replace a saved game configuration', () async {
    final fixture = makeFixture();
    final game = Game(
      folder: fixture.temp.path,
      titleId: 'SCUS94426',
      name: 'Crash Team Racing',
      names: const {},
      defaultLanguage: 'en',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: p.join(fixture.temp.path, 'game.chd')),
    );
    final preferences = Preferences()
      ..onboarded = true
      ..retroInternalResolution[game.id] = '3';
    final app = AppModel(
      paths: fixture.model.paths,
      system: HostSystem.windows,
      persist: false,
      preferences: preferences,
      services: LauncherServices(environment: {'ANYPS5_LIBRETRO_HOME': fixture.temp.path}),
    );
    addTearDown(() {
      app.dispose();
      fixture.model.dispose();
      fixture.dispose();
    });
    app.games = [game];
    app.select(0);
    app.open(Layer.gameSettings);
    final optimize = app.panelCategories().single.rows.firstWhere((row) => row.id == 'emulator-auto-optimize');
    (optimize.kind as ActionRow).run();
    await pumpEventQueue();
    final rows = app.panelCategories().single.rows;
    expect((rows.single.kind as InfoRow).text, contains('hardware'));
    expect(preferences.retroInternalResolution[game.id], '3');
  });

  for (final (platform, key, change, saved) in [
    (RetroPlatform.ps1, 'swanstation_GPU_ResolutionScale', '1× → 4×', '4'),
    (RetroPlatform.ps2, 'pcsx2_upscale_multiplier', '1x (Native) → 4x', '4x'),
    (RetroPlatform.ps3, 'rpcs3_resolution_scale', '100% → 150%', '150'),
  ]) {
    test('${platform.name} game settings preview a detected recommendation and write only on Apply', () async {
      final fixture = makeFixture();
      final app = AppModel(
        paths: fixture.model.paths,
        system: HostSystem.windows,
        persist: true,
        preferences: Preferences()..onboarded = true,
        services: LauncherServices(
          environment: {'ANYPS5_LIBRETRO_HOME': fixture.temp.path},
          retroHardware: () async => const RetroHardware(
            displayHeight: 1440,
            logicalProcessors: 12,
            adapters: [RetroAdapter(name: 'Test GPU', dedicatedBytes: 8 << 30)],
          ),
        ),
      );
      addTearDown(() {
        app.dispose();
        fixture.model.dispose();
        fixture.dispose();
      });
      final game = Game(
        folder: fixture.temp.path,
        titleId: '${platform.name}-test',
        name: 'Racing fixture',
        names: const {},
        defaultLanguage: 'en',
        version: '',
        executable: ExecutableKind.disc,
        retro: (platform: platform, path: p.join(fixture.temp.path, 'game')),
      );
      app.games = [game];
      app.select(0);
      app.open(Layer.gameSettings);
      app.savePreferences();
      final preferencesFile = File(app.paths.preferencesFile);
      final before = preferencesFile.readAsStringSync();
      PanelRow row(String id) => app.panelCategories().single.rows.singleWhere((row) => row.id == id);
      void openOptimizer() => (row('emulator-auto-optimize').kind as ActionRow).run();
      openOptimizer();
      await pumpEventQueue();
      expect(row('auto-setting-$key').detail, change);
      expect(row('tuning-preset-preview').detail, contains('Test GPU'));
      expect(app.preferences.retroPs3Graphics, isEmpty);
      expect(app.preferences.retroInternalResolution, isEmpty);
      app.closeOverlay();
      expect(app.preferences.retroInternalResolution, isEmpty);
      expect(preferencesFile.readAsStringSync(), before);
      openOptimizer();
      await pumpEventQueue();
      expect(row('tuning-preset-apply').pinToBottom, isTrue);
      final rows = app.panelCategories().single.rows;
      for (final setting in rows.where((row) => row.id.startsWith('auto-setting-'))) {
        app.handle(Command.down);
        expect(rows[app.panelRow].id, setting.id);
      }
      app.handle(Command.down);
      expect(app.panelCategories().single.rows[app.panelRow].id, 'tuning-preset-apply');
      app.handle(Command.select);
      await pumpEventQueue();
      if (platform == RetroPlatform.ps3) {
        expect(app.preferences.retroPs3Graphics[game.titleId]?[key], saved);
      } else {
        expect(app.preferences.retroInternalResolution, {game.id: saved});
      }
      expect(app.preferences.retroAutoOptimized, {game.id});
      expect(Preferences.load(preferencesFile.path).retroAutoOptimized, {game.id});
      expect(app.running, isNull);
      app.closeOverlay();
      openOptimizer();
      await pumpEventQueue();
      expect(app.panelCategories().single.rows.any((r) => r.id == 'tuning-preset-apply'), isFalse);
    });
  }

  for (final platform in RetroPlatform.ps1AndPs2) {
    test('${platform.name} previews, applies and restores the resolution from the dashboard', () async {
      final fixture = makeFixture();
      final exe = File(p.join(fixture.temp.path, 'emulator.exe'))..createSync();
      final config = RetroSettings.configFile(exe.path, platform);
      config.parent.createSync(recursive: true);
      final (section, key) = switch (platform) {
        RetroPlatform.ps1 => ('GPU', 'ResolutionScale'),
        RetroPlatform.ps2 => ('EmuCore/GS', 'upscale_multiplier'),
        RetroPlatform.ps3 => throw StateError('The standalone optimizer supports PS1 and PS2.'),
      };
      config.writeAsStringSync('[$section]\n$key = 1\nUntouched = yes\n');
      var displayHeight = 1440;
      final app = AppModel(
        paths: fixture.model.paths,
        persist: false,
        preferences: Preferences()..retroEmulators[platform.name] = exe.path,
        services: LauncherServices(
          retroHardware: () async => RetroHardware(
            displayHeight: displayHeight,
            adapters: const [RetroAdapter(name: 'Test GPU', dedicatedBytes: 16 << 30)],
          ),
        ),
      );
      addTearDown(() {
        app.dispose();
        fixture.model.dispose();
        fixture.dispose();
      });

      PanelCategory optimize() => app.retroSettings
          .categories(platform)
          .singleWhere((category) => category.id == 'retro-${platform.name}-optimize');
      ActionRow action(String suffix) =>
          optimize().rows.singleWhere((row) => row.id.endsWith(suffix)).kind as ActionRow;

      action('-preview').run();
      await pumpEventQueue();
      final summary = optimize().rows.singleWhere((row) => row.id.endsWith('-summary'));
      expect(summary.title, contains('1× → 4×'));
      expect(summary.detail, contains('Test GPU'));
      expect(config.readAsStringSync(), contains('$key = 1'));

      action('-apply').run();
      await pumpEventQueue();
      expect(config.readAsStringSync(), contains('$key = 4'));
      expect(config.readAsStringSync(), contains('Untouched = yes'));

      action('-undo').run();
      expect(config.readAsStringSync(), contains('$key = 1'));
      expect(config.readAsStringSync(), contains('Untouched = yes'));

      displayHeight = 720;
      action('-apply').run();
      await pumpEventQueue();
      expect(
        config.readAsStringSync(),
        contains('$key = 1'),
        reason: 'a preview from another display must be refreshed',
      );
      expect(optimize().rows.singleWhere((row) => row.id.endsWith('-summary')).detail, contains('720p'));

      config.writeAsStringSync(
        '[$section]\n$key = 1\n'
        'Renderer = ${platform == RetroPlatform.ps1 ? 'Software' : '13'}\n'
        'Renderer = ${platform == RetroPlatform.ps1 ? 'Automatic' : '-1'}\n',
      );
      expect(optimize().rows.any((row) => row.id.endsWith('-apply')), isFalse);
    });
  }
}
