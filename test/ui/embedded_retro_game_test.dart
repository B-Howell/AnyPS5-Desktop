import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/ps2_lan_profile.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/console_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('anyps5/retro_core');

  test('PS2 LAN keeps a private network memory card and saves across rooms', () async {
    final environment = <String, String>{};
    final fixture = makeFixture(system: HostSystem.windows, environment: environment);
    addTearDown(fixture.dispose);
    final app = fixture.model;
    final home = fixture.temp.path;
    environment['ANYPS5_LIBRETRO_HOME'] = home;
    final core = File(p.join(home, 'pcsx2_libretro.dll'))..createSync();
    final disc = File(p.join(home, 'test.iso'))..createSync();
    final bios = File(p.join(home, 'system', 'pcsx2', 'bios', 'anyps5-imported.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(4 * 1024 * 1024)..[0] = 7);
    final original = File(p.join(home, 'bios-source.bin'))..writeAsBytesSync([1, 2, 3]);
    app.preferences.retroBiosSources['ps2'] = original.path;
    final game = Game(
      folder: home,
      titleId: 'PS2-SLUS21148',
      name: 'LAN fixture',
      names: const {},
      defaultLanguage: 'en',
      version: '1.00',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: disc.path),
    );
    Map<Object?, Object?>? start;
    var stopped = false;
    Completer<void>? stopRequested;
    final frame = Uint8List(14)..[0] = 255;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          stopped = false;
          start = call.arguments as Map<Object?, Object?>;
          return 7;
        case 'status':
          return {'presented': true, 'ended': stopped};
        case 'ps2LanExchange':
          expect(call.arguments['texture'], 7);
          expect(call.arguments['frames'], [frame]);
          return [frame];
        case 'stop':
          if (stopRequested case final pending?) {
            pending.complete();
          } else {
            stopped = true;
          }
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final offlineCard = File(p.join(home, 'system', 'pcsx2', 'memcards', 'Mcd001.ps2'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
    final mac = Uint8List.fromList([2, 0, 0, 0, 0, 1]);
    final session = await app.preparePs2Lan(game, mac, canBoot: () => true);
    final args = start!;
    final system = args['system']! as String;
    final saves = args['saves']! as String;
    final networkCard = File(p.join(system, 'pcsx2', 'memcards', 'Mcd001.ps2'));
    final gameSave = File(p.join(saves, 'fixture.sav'));
    try {
      expect(args['core'], core.path);
      expect(args['disc'], disc.path);
      expect(args['ps2LanMac'], mac);
      expect(system, isNot(p.join(home, 'system')));
      final isolatedBios = File(p.join(system, 'pcsx2', 'bios', 'anyps5-imported.bin'));
      expect(isolatedBios.readAsBytesSync().first, 7);
      expect(isolatedBios.lengthSync(), bios.lengthSync());
      expect(Directory(saves).listSync(), isEmpty);
      expect(app.embeddedGame?.isPs2Lan, isTrue);
      expect(await session.exchange([frame]), [frame]);
      networkCard.createSync(recursive: true);
      networkCard.writeAsBytesSync([4, 5, 6]);
      gameSave.writeAsBytesSync([8]);
    } finally {
      await session.close();
      await session.done.timeout(const Duration(seconds: 4));
    }
    final nextMac = Uint8List.fromList([2, 0, 0, 0, 0, 2]);
    final rejoined = await app.preparePs2Lan(game, nextMac, canBoot: () => true);
    try {
      expect(start!['system'], system);
      expect(start!['saves'], saves);
      expect(start!['ps2LanMac'], nextMac);
      expect(networkCard.readAsBytesSync(), [4, 5, 6]);
      expect(gameSave.readAsBytesSync(), [8]);
    } finally {
      await rejoined.close();
      await rejoined.done.timeout(const Duration(seconds: 4));
    }
    expect(offlineCard.readAsBytesSync(), [9]);
    expect(bios.readAsBytesSync().first, 7);
    expect(original.readAsBytesSync(), [1, 2, 3]);

    start = null;
    final stopping = stopRequested = Completer<void>();
    final failed = expectLater(
      app.preparePs2Lan(
        game,
        mac,
        canBoot: () {
          if (start != null) throw StateError('Launch interrupted after native startup');
          return true;
        },
      ),
      throwsStateError,
    );
    try {
      await stopping.future.timeout(const Duration(seconds: 3));
      await expectLater(app.preparePs2Lan(game, mac, canBoot: () => true), throwsA(isA<Ps2LanProfileInUse>()));
    } finally {
      stopRequested = null;
      stopped = true;
      await failed;
      await app.embeddedGame?.exitCode.timeout(const Duration(seconds: 3));
    }
    expect(app.embeddedGame, isNull);
    expect(networkCard.readAsBytesSync(), [4, 5, 6]);
  }, skip: !Platform.isWindows);

  test('PS3 graphics preferences keep separate choices for each title', () {
    final temp = Directory.systemTemp.createTempSync('anyps5-ps3-preferences-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = p.join(temp.path, 'preferences.json');
    final choices = {
      'PS3-BCUS98208': {'rpcs3_resolution_scale': '150', 'rpcs3_msaa': 'auto'},
      'PS3-BLES00123': {'rpcs3_resolution_scale': '100'},
    };
    (Preferences()..retroPs3Graphics = choices).save(path);
    expect(Preferences.load(path).retroPs3Graphics, choices);
  });

  testWidgets('PS4 and PS5 title IDs select accessible console badges', (tester) async {
    for (final (titleId, expected) in [('CUSA12345', PlayStationConsole.ps4), ('PPSA12345', PlayStationConsole.ps5)]) {
      final game = Game(
        folder: 'test',
        titleId: titleId,
        name: 'Console badge test',
        names: const {},
        defaultLanguage: 'en-US',
        version: '',
        executable: ExecutableKind.disc,
      );
      expect(PlayStationConsole.forGame(game), expected);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ConsoleBadge(console: expected)),
        ),
      );
      final badge = tester.widget<Image>(find.byType(Image));
      expect(badge.semanticLabel, expected.label);
      expect((badge.image as AssetImage).assetName, 'assets/retro/console-${expected.name}.png');
    }
  });

  testWidgets('embedded boot keeps one progress bar and the same cover through compilation', (tester) async {
    final env = <String, String>{};
    final fixture = makeFixture(environment: env);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final folder = fixture.temp.path;
    env['ANYPS5_LIBRETRO_HOME'] = folder;
    File(p.join(folder, 'swanstation_libretro.dll')).createSync();
    final disc = File(p.join(folder, 'boot.cue'))..createSync();
    final icon = File(p.join(folder, 'cover.png'))..writeAsBytesSync(iconArt(0x102030, 0x304050));
    final game = Game(
      folder: folder,
      titleId: 'BOOT12345',
      name: 'Embedded boot game',
      names: const {'en-US': 'Embedded boot game'},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: disc.path),
      icon: icon.path,
    );
    var status = <String, Object?>{};
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'start' => 42,
        'status' => status,
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await pumpLauncher(tester, model);
    final play = model.play(game);
    await tester.pump();
    final bar = find.byType(LinearProgressIndicator);
    final cover = find.byWidgetPredicate((widget) => widget is ArtworkImage && widget.path == icon.path);
    expect(bar, findsOneWidget);
    expect(cover, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, isNull);
    final coverRect = tester.getRect(cover);
    final barRect = tester.getRect(bar);

    status = {'presented': true, 'startupVisible': false};
    await tester.pump(const Duration(milliseconds: 150));
    expect(model.starting, game);
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, isNull);
    expect(tester.getRect(cover), coverRect);
    expect(tester.getRect(bar), barRect);

    status = {
      'presented': true,
      'startupVisible': false,
      'progressLabel': 'Compiling PPU modules',
      'progressPercent': 43,
    };
    await tester.pump(const Duration(milliseconds: 150));
    expect(model.starting, game);
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.43);
    expect(find.text('43%'), findsOneWidget);
    expect(tester.getRect(cover), coverRect);
    expect(tester.getRect(bar), barRect);

    status = {'presented': true, 'progressLabel': 'Loading shader cache', 'progressPercent': 72};
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('72%'), findsOneWidget);
    expect(tester.getRect(cover), coverRect);

    status = {'presented': true, 'startupVisible': true};
    await tester.pump(const Duration(milliseconds: 150));
    expect(model.starting, isNull);
    expect(cover, findsNothing);
    expect(bar, findsNothing);
    expect(find.byType(Texture), findsOneWidget);

    status = {'presented': true, 'startupVisible': false};
    await tester.pump(const Duration(milliseconds: 150));
    expect(bar, findsNothing);

    status = {'ended': true};
    await tester.pump(const Duration(milliseconds: 150));
    await play;
  });

  for (final platform in RetroPlatform.ps1AndPs2) {
    testWidgets('embedded ${platform.name} Graphics resumes one texture and remembers resolution per title', (
      tester,
    ) async {
      final env = <String, String>{};
      final pads = FakePads();
      final fixture = makeFixture(environment: env, pads: () => pads);
      final model = fixture.model;
      model.startPads();
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
      final core = platform == RetroPlatform.ps1 ? 'swanstation_libretro.dll' : 'pcsx2_libretro.dll';
      File(p.join(fixture.temp.path, core)).createSync();
      final folder = Directory(p.join(model.root!, 'Embedded'))..createSync();
      final disc = platform == RetroPlatform.ps1 ? 'game.cue' : 'game.iso';
      File(p.join(folder.path, disc)).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': platform.name, 'titleId': 'TEST12345', 'name': 'Embedded game', 'disc': disc}),
      );
      final otherFolder = Directory(p.join(model.root!, 'Other'))..createSync();
      File(p.join(otherFolder.path, disc)).createSync();
      File(p.join(otherFolder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': platform.name, 'titleId': 'TEST67890', 'name': 'Other game', 'disc': disc}),
      );
      final calls = <MethodCall>[];
      var ended = false;
      var saveError = '';
      int? progress;
      final isPs1 = platform == RetroPlatform.ps1;
      final resolution = isPs1 ? 'swanstation_GPU_ResolutionScale' : 'pcsx2_upscale_multiplier';
      final scales = isPs1 ? ['1', '2', '3', '4'] : ['1x (Native)', '2x', '4x'];
      var selected = 0;
      var graphicsPending = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'start':
            expect(call.arguments['core'], p.join(fixture.temp.path, core));
            ended = false;
            final saved = call.arguments['internalResolution'] as String?;
            selected = saved == null ? 0 : scales.indexOf(saved);
            return 123;
          case 'status':
            return {
              'presented': true,
              'ended': ended,
              'aspect': 4 / 3,
              'hardware': true,
              'error': ended ? saveError : '',
              if (progress != null) 'progressLabel': 'Compiling modules',
              'progressPercent': ?progress,
              'graphicsPending': graphicsPending,
              'options': {
                resolution: {
                  'values': scales,
                  'selected': selected,
                  'activeValue': scales[graphicsPending ? 0 : selected],
                },
              },
            };
          case 'option':
            expect(call.arguments['key'], resolution);
            if (call.arguments['value'] != scales[1]) return false;
            graphicsPending = true;
            selected = 1;
            return true;
          case 'tuningOptions':
            selected = scales.indexOf(call.arguments['values'][resolution] as String);
            return selected >= 0;
          case 'stop':
            ended = true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      model.rescan();
      final title = model.games.singleWhere((game) => game.name == 'Embedded game');
      final other = model.games.singleWhere((game) => game.name == 'Other game');
      final play = model.play(title);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.textureId, 123);
      expect(model.starting, isNull);

      progress = 43;
      model.setActive(false);
      await tester.pump();
      expect(calls.where((call) => call.method == 'pause'), isEmpty);
      expect(calls.lastWhere((call) => call.method == 'input').arguments, [0, 0, 0, 0, 0]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.progress, (label: 'Compiling modules', percent: 43));
      progress = null;
      pads.press(PadButton.guide);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.progress, isNull);
      expect(model.overlay, Layer.quickMenu);
      expect(calls.where((call) => call.method == 'pause').last.arguments, true);
      model.setActive(true);
      final graphics = model.panelCategories().single.rows.singleWhere((row) => row.id == 'retroGraphics');
      (graphics.kind as ActionRow).run();
      expect(model.panelCategories().single.rows.map((row) => row.title), ['Auto Optimize', 'Advanced']);
      PanelRow row(String id) => model.panelCategories().single.rows.singleWhere((row) => row.id == id);
      void choose(String id) => (row(id).kind as ActionRow).run();
      choose('emulator-auto-optimize');
      await tester.pump();
      expect(row('auto-setting-$resolution').kind, isA<InfoRow>());
      expect(calls.where((call) => call.method == 'tuningOptions'), isEmpty);
      expect(model.preferences.retroInternalResolution, isEmpty);
      model.handle(Command.back);
      if (isPs1) {
        choose('emulator-auto-optimize');
        await tester.pump();
        choose('tuning-preset-apply');
        await tester.pump(const Duration(milliseconds: 150));
        expect(model.preferences.retroInternalResolution[title.id], '3');
        expect(Preferences.fromJson(model.preferences.toJson()).retroAutoOptimized, contains(title.id));
        model.handle(Command.back);
        expect(row('emulator-auto-optimize').title, 'Auto Optimize ✓');
      }
      choose('embedded-graphics-advanced');
      choose('emulator-tune-game');
      model.handle(Command.back);
      expect(row('embedded-apply-advanced').kind, isA<InfoRow>());
      final filter = model.panelCategories().single.rows.first.kind as ChoiceRow;
      filter.set(1);
      expect(model.embeddedGame?.filter, 0);
      final internalResolution = model.panelCategories().single.rows.singleWhere((row) => row.id == resolution);
      expect(internalResolution.title, 'Internal resolution');
      final choice = internalResolution.kind as ChoiceRow;
      expect(choice.options[1], '2x');
      if (isPs1) expect(choice.selected, 2);
      choice.set(1);
      choose('embedded-apply-advanced');
      await tester.pump();
      expect(model.preferences.retroInternalResolution[title.id], isPs1 ? '3' : null);
      graphicsPending = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.options[resolution]?.selected, 1);
      expect(model.embeddedGame?.filter, 1);
      expect(model.preferences.retroInternalResolution, {title.id: scales[1]});
      expect(model.preferences.retroAutoOptimized, isNot(contains(title.id)));
      model.resumeGame();
      await tester.pump();
      expect(model.overlay, isNull);
      expect(calls.where((call) => call.method == 'pause').last.arguments, false);

      await model.openQuickMenu();
      model.resumeGame();
      await tester.pump();
      expect(model.embeddedGame?.textureId, 123);
      expect(calls.where((call) => call.method == 'start'), hasLength(1));

      if (platform == RetroPlatform.ps1) {
        model.closeRunningGame();
        await tester.pump(const Duration(milliseconds: 150));
      } else {
        saveError = 'Could not write the memory card';
        final quit = model.prepareToQuit();
        await tester.pump(const Duration(milliseconds: 150));
        expect(await quit, isFalse);
        expect(model.toast, saveError);
      }
      await play;
      expect(model.running, isNull);
      expect(calls.map((call) => call.method), containsAllInOrder(['stop', 'release']));

      final preferencesFile = p.join(fixture.temp.path, 'preferences.json');
      model.preferences.save(preferencesFile);
      model.preferences.retroInternalResolution = Preferences.load(preferencesFile).retroInternalResolution;
      saveError = '';
      for (final (game, expected) in [(other, null), (title, scales[1])]) {
        final relaunch = model.play(game);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final start = calls.lastWhere((call) => call.method == 'start');
        expect(start.arguments['internalResolution'], expected);
        expect(model.embeddedGame?.options[resolution]?.selected, expected == null ? 0 : 1);
        model.closeRunningGame();
        await tester.pump(const Duration(milliseconds: 150));
        await relaunch;
      }
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
