import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/panels.dart';
import 'package:anyps5_desktop/ui/ps3_settings_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart' show ps3FixtureSfo;
import '../support/ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(T.load);

  testWidgets('PS3 game settings show local online readiness and can recheck an installed update', (tester) async {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final folder = p.join(fixture.temp.path, 'PS3 fixture');
    File write(String relative, List<int> bytes) => File(p.join(folder, relative))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    final disc = write('PS3_DISC.SFB', [0]);
    write('PS3_GAME/USRDIR/EBOOT.BIN', [0]);
    write('PS3_GAME/PARAM.SFO', ps3FixtureSfo({'TITLE_ID': 'BCUS98208', 'APP_VER': '01.18'}));
    final game = Game(
      folder: folder,
      titleId: 'BCUS98208',
      name: 'LittleBigPlanet fixture',
      names: const {},
      defaultLanguage: 'en',
      version: '99.99',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps3, path: disc.path),
    );
    model.games = [game];
    model.selected = 0;
    model.open(Layer.gameSettings);
    final gameRows = model.panelCategories().single.rows;
    final entry = gameRows.indexWhere((row) => row.id == 'ps3-online-readiness');
    expect(entry, isNonNegative);
    expect(gameRows[entry].title, 'Online Readiness');
    model.activateRow(entry);
    PanelRow row(String id) => model.panelCategories().single.rows.singleWhere((row) => row.id == id);
    String info(String id) => (row(id).kind as InfoRow).text;
    expect(info('ps3-online-title-id'), 'BCUS98208');
    expect(info('ps3-online-disc-version'), '01.18');
    expect(info('ps3-online-managed-update'), 'None detected');
    expect(row('ps3-online-status').title, 'No verified provider');
    expect(row('ps3-online-status').detail, contains('play offline'));
    expect(model.running, isNull);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PanelView(model: model)),
      ),
    );
    expect(find.text('No verified provider'), findsOneWidget);
    expect(find.textContaining('You can still play offline'), findsOneWidget);
    expect(find.text('BCUS98208'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    final update = p.join(
      p.dirname(model.paths.toolkits),
      'Emulators',
      'system',
      'rpcs3',
      'dev_hdd0',
      'game',
      'BCUS98208',
    );
    File(p.join(update, 'PARAM.SFO'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(ps3FixtureSfo({'TITLE_ID': 'BCUS98208', 'APP_VER': '01.30'}));
    File(p.join(update, 'USRDIR', 'EBOOT.BIN'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    expect(model.spot?.row, 'ps3-online-recheck');
    model.panelCommand(Command.select);
    expect(info('ps3-online-managed-update'), '01.30');
    expect(row('ps3-online-status').title, 'No verified provider');
    disc.deleteSync();
    model.panelCommand(Command.select);
    expect(row('ps3-online-status').title, 'Disc unavailable');
    expect(model.running, isNull);
    expect(model.spot?.row, 'ps3-online-recheck');
    write('PS3_DISC.SFB', [0]);
    model.panelCommand(Command.select);
    expect(row('ps3-online-status').title, 'No verified provider');
    expect(model.spot?.row, 'ps3-online-recheck');
    model.panelCommand(Command.back);
    expect(model.overlay, Layer.gameSettings);
    expect(model.selectedGame, game);
    expect(model.spot?.row, 'ps3-online-readiness');
  }, skip: Abi.current() != Abi.windowsX64);

  test('PS3 exposes validated graphics, CPU, I/O and audio options before first Play', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    final panels = model.retroSettings.categories(RetroPlatform.ps3);
    expect(
      panels.map((panel) => panel.id),
      containsAll(['retro-ps3', 'retro-ps3-graphics', 'retro-ps3-cpu', 'retro-ps3-io', 'retro-ps3-audio']),
    );
    final rows = panels.expand((panel) => panel.rows).toList();
    expect(rows.singleWhere((row) => row.title == 'Renderer').kind, isA<InfoRow>());
    final decoder = rows.singleWhere((row) => row.title == 'SPU Decoder');
    expect(decoder.detail, contains('next launch'));
    expect((decoder.kind as ChoiceRow).options, contains('Recompiler (LLVM)'));
    final diskCache = rows.singleWhere((row) => row.title == 'Disk Cache Size').kind as ChoiceRow;
    expect(diskCache.options, isNot(contains('Wipe on Exit')));

    model.openSettingsCategory('emulators');
    model.panelRow = 2;
    model.panelCommand(Command.select);
    expect(
      model.panelCategories().single.rows.map((row) => row.title),
      containsAll(['Setup', 'Graphics', 'Performance & Compatibility', 'I/O', 'Audio', 'Advanced']),
    );
  });

  test('PS3 game settings inherit shared defaults and isolate overrides by title', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Game game(String titleId) => Game(
      folder: titleId,
      titleId: titleId,
      name: titleId,
      names: const {},
      defaultLanguage: 'en',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps3, path: '$titleId/PS3_DISC.SFB'),
    );

    ChoiceRow decoder({Game? game}) {
      final panels = model.retroSettings.categories(RetroPlatform.ps3, game: game);
      return panels.expand((panel) => panel.rows).singleWhere((row) => row.id == 'rpcs3_spu_decoder').kind as ChoiceRow;
    }

    final first = game('PS3-TEST00001');
    final second = game('PS3-TEST00002');
    final shared = decoder();
    shared.set(shared.options.indexOf('Recompiler (ASMJIT)'));
    expect(model.preferences.retroPs3Defaults['rpcs3_spu_decoder'], 'asmjit');
    final gameChoice = decoder(game: first);
    expect(gameChoice.options[gameChoice.selected], 'Use shared default (Recompiler (ASMJIT))');
    gameChoice.set(gameChoice.options.indexOf('Recompiler (LLVM)'));
    expect(decoder(game: first).selected, greaterThan(0));
    expect(decoder(game: second).selected, 0);
    expect(model.preferences.retroPs3Graphics[first.titleId], {'rpcs3_spu_decoder': 'llvm'});
    final reloaded = Preferences.fromJson(model.preferences.toJson());
    expect(reloaded.retroPs3Defaults['rpcs3_spu_decoder'], 'asmjit');
    expect(reloaded.retroPs3Graphics[first.titleId], {'rpcs3_spu_decoder': 'llvm'});
    decoder(game: first).set(0);
    expect(model.preferences.retroPs3Graphics.containsKey(first.titleId), isFalse);
    expect(decoder(game: first).selected, 0);
  });

  test('only GPU choices are listed as in-game graphics keys', () {
    expect(Ps3SettingsModel.graphicsKeys, contains('rpcs3_resolution_scale'));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_renderer')));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_spu_decoder')));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_disk_cache_size')));
  });
}
