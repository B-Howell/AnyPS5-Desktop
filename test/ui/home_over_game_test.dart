import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/gamepad/shortcuts.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:anyps5_desktop/ui/embedded_retro_view.dart';
import 'package:anyps5_desktop/ui/game_action.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

/// PS held in an embedded game, or Home in its quick menu: the launcher's home screen with the
/// game paused behind it, Resume on its tile and in the corner, and Play on another game asked
/// first. An online match cannot pause, so it keeps the game in front and says why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('anyps5/retro_core');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  ({Fixture fixture, AppModel model, FakePads pads, List<MethodCall> calls, Game first, Game second}) embedded() {
    final env = <String, String>{};
    final pads = FakePads();
    final fixture = makeFixture(environment: env, pads: () => pads);
    final model = fixture.model..startPads();
    env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
    File(p.join(fixture.temp.path, model.embeddedCoreHost.libraryName(RetroPlatform.ps1))).createSync();
    for (final (folder, titleId, name) in [
      ('First', 'HOME00001', 'First game'),
      ('Second', 'HOME00002', 'Second game'),
    ]) {
      final directory = Directory(p.join(model.root!, folder))..createSync();
      File(p.join(directory.path, 'game.cue')).createSync();
      File(p.join(directory.path, 'retro.json'))
          .writeAsStringSync(jsonEncode({'platform': 'ps1', 'titleId': titleId, 'name': name, 'disc': 'game.cue'}));
    }
    final calls = <MethodCall>[];
    var ended = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'start':
          ended = false;
          return 123;
        case 'status':
          return {'presented': true, 'ended': ended, 'hardware': true};
        case 'stop':
          ended = true;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      model.dispose();
      fixture.dispose();
    });
    model.rescan();
    return (
      fixture: fixture,
      model: model,
      pads: pads,
      calls: calls,
      first: model.games.singleWhere((game) => game.name == 'First game'),
      second: model.games.singleWhere((game) => game.name == 'Second game'),
    );
  }

  bool? paused(List<MethodCall> calls) => calls.lastWhere((call) => call.method == 'pause').arguments as bool?;

  Future<void> holdGuide(WidgetTester tester, FakePads pads) async {
    pads.hold(PadButton.guide);
    await tester.pump(ShortcutTiming.hold + const Duration(milliseconds: 50));
    pads.release(PadButton.guide);
    await tester.pump();
  }

  Future<void> stop(WidgetTester tester, AppModel model, Future<void> play) async {
    if (model.running != null) model.closeRunningGame();
    await tester.pump(const Duration(milliseconds: 150));
    await play;
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('PS held in the game: Home with the game paused; PS opens its quick menu; Resume returns', (
    tester,
  ) async {
    final (:model, :pads, :calls, :first, fixture: _, second: _) = embedded();
    final play = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(model.embeddedGame, isNotNull);

    await holdGuide(tester, pads);
    expect(model.gameAtHome, isTrue);
    expect(model.overlay, isNull, reason: 'the home screen itself, not Close game?');
    expect(model.running?.$1, first, reason: 'the game keeps its session');
    expect(paused(calls), isTrue);
    expect(model.selectedGame, first, reason: 'its tile is the one selected');
    expect(GameAction.of(model.stateOf(first)).title, 'Resume');

    model.open(Layer.settings);
    expect(paused(calls), isTrue, reason: 'Settings over Home leave the game paused');
    model.handle(Command.back);
    expect(model.overlay, isNull);
    expect(model.gameAtHome, isTrue, reason: 'Back from Settings stays on Home');

    pads.press(PadButton.guide);
    await tester.pump();
    expect(model.overlay, Layer.quickMenu, reason: 'PS on Home: the game\'s quick menu, as a PS5\'s control centre');
    expect(model.panelCategories().single.rows.take(2).map((row) => row.id), ['resume', 'home']);
    pads.press(PadButton.east);
    expect(model.overlay, isNull);
    expect(model.gameAtHome, isTrue, reason: 'Back from that quick menu is Home again');
    expect(paused(calls), isTrue);

    pads.press(PadButton.guide);
    await tester.pump();
    pads.press(PadButton.guide);
    await tester.pump();
    expect(model.gameAtHome, isFalse, reason: 'a second PS goes back to the game');
    expect(paused(calls), isFalse);

    await holdGuide(tester, pads);
    expect(model.gameAtHome, isTrue);
    model.primaryAction(first);
    await tester.pump();
    expect(model.gameAtHome, isFalse, reason: 'Resume on its tile');
    expect(model.overlay, isNull);
    expect(paused(calls), isFalse);
    expect(calls.where((call) => call.method == 'start'), hasLength(1), reason: 'the same session throughout');
    await stop(tester, model, play);
  });

  testWidgets('the quick menu\'s Home row goes Home; its Resume row comes back', (tester) async {
    final (:model, :pads, :calls, :first, fixture: _, second: _) = embedded();
    final play = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    pads.press(PadButton.guide);
    await tester.pump();
    expect(model.overlay, Layer.quickMenu);
    final home = model.panelCategories().single.rows.singleWhere((row) => row.id == 'home');
    expect(home.title, 'Home');
    expect(home.detail, 'Friends, settings and your library. The game waits paused.');
    (home.kind as ActionRow).run();
    await tester.pump();
    expect(model.gameAtHome, isTrue);
    expect(model.overlay, isNull);
    expect(paused(calls), isTrue);

    await model.openQuickMenu();
    final resume = model.panelCategories().single.rows.first;
    expect(resume.id, 'resume');
    (resume.kind as ActionRow).run();
    await tester.pump();
    expect(model.gameAtHome, isFalse);
    expect(paused(calls), isFalse);
    await stop(tester, model, play);
  });

  testWidgets('Play on another game asks first; Cancel keeps Home, Close and play starts it', (tester) async {
    final (:model, :pads, :calls, :first, :second, fixture: _) = embedded();
    final play = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await holdGuide(tester, pads);
    expect(model.gameAtHome, isTrue);

    model.primaryAction(second);
    expect(model.overlay, Layer.switchGame);
    expect(model.twoChoice, isTrue);
    final ask = model.panelCategories().single;
    expect(ask.title, 'Play Second game instead?');
    expect(ask.rows.last.detail, 'First game closes first. Progress since its last save is lost.');
    expect(ask.rows.map((row) => row.id), ['cancel', 'confirmSwitch']);
    expect(calls.where((call) => call.method == 'stop'), isEmpty, reason: 'nothing closes before the answer');
    model.handle(Command.back);
    expect(model.overlay, isNull);
    expect(model.gameAtHome, isTrue);
    expect(model.running?.$1, first);

    model.primaryAction(second);
    (model.panelCategories().single.rows.last.kind as ActionRow).run();
    for (var step = 0; step < 10 && model.running?.$1 != second; step++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await play;
    expect(calls.where((call) => call.method == 'stop'), hasLength(1));
    expect(calls.where((call) => call.method == 'start'), hasLength(2));
    expect(model.running?.$1, second);
    expect(model.gameAtHome, isFalse, reason: 'the new game starts in front');
    model.closeRunningGame();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Escape held is Home from the keyboard; the corner card and the tile resume', (tester) async {
    final (:model, :calls, :first, pads: _, fixture: _, second: _) = embedded();
    final play = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await pumpLauncher(tester, model);
    expect(find.byType(EmbeddedRetroView), findsOneWidget);
    expect(find.byType(RunningGameCard), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(ShortcutTiming.hold + const Duration(milliseconds: 50));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(model.gameAtHome, isTrue);
    expect(model.overlay, isNull);
    expect(paused(calls), isTrue);
    expect(find.byType(EmbeddedRetroView), findsNothing, reason: 'the home screen in its place');
    expect(find.byType(HomeView), findsOneWidget);
    expect(find.byType(RunningGameCard), findsOneWidget);
    expect(model.stateOf(first), isA<Running>().having((state) => state.paused, 'paused', isTrue));
    expect(find.text('Playing'), findsNothing, reason: 'every status of the game says it is paused');
    expect(find.text('Paused'), findsWidgets);
    expect(find.byIcon(Icons.play_circle_rounded), findsNothing);
    expect(find.text('First game'), findsWidgets);

    await tester.tap(find.byType(RunningGameCard));
    await settle(tester);
    expect(model.gameAtHome, isFalse);
    expect(model.stateOf(first), isA<Running>().having((state) => state.paused, 'paused', isFalse));
    expect(paused(calls), isFalse);
    expect(find.byType(EmbeddedRetroView), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(model.overlay, Layer.quickMenu, reason: 'a short Escape is still the quick menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(model.overlay, isNull, reason: 'and a short one in it goes back to the game');
    expect(model.gameAtHome, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(model.overlay, Layer.quickMenu);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(ShortcutTiming.hold + const Duration(milliseconds: 50));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(model.gameAtHome, isTrue, reason: 'held in the quick menu it is Home too');
    expect(model.overlay, isNull);
    model.resumeGame();
    await tester.pump();
    await stop(tester, model, play);
  });

  test('an online match cannot pause: Home keeps the game in front and says why', () async {
    final fixture = makeFixture();
    final model = fixture.model;
    final ended = <bool>[false];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          return 7;
        case 'status':
          return {'presented': true, 'ended': ended.first};
        case 'stop':
          ended.first = true;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      model.dispose();
      fixture.dispose();
    });
    final home = fixture.temp.path;
    File(p.join(home, model.embeddedCoreHost.libraryName(RetroPlatform.ps2))).createSync();
    final disc = File(p.join(home, 'lan.iso'))..createSync();
    final game = Game(
      folder: home,
      titleId: 'PS2-SLUS21148',
      name: 'LAN match',
      names: const {},
      defaultLanguage: 'en',
      version: '1.00',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: disc.path),
    );
    final session = await EmbeddedRetroGame.start(
      home,
      game.retro!,
      coreHost: model.embeddedCoreHost,
      internalResolution: null,
      onResolutionSelected: (_) {},
      graphics: const {},
      onGraphicsSelected: (_, _) {},
      readPad: () => PadState.idle,
      changed: () {},
      ps2Lan: (
        mac: Uint8List.fromList([2, 0, 0, 0, 0, 1]),
        system: p.join(home, 'lan-system'),
        saves: (Directory(p.join(home, 'lan-saves'))..createSync()).path,
      ),
    );
    model.games = [...model.games, game];
    model.running = (game, session);
    expect(model.canGoHome, isFalse);

    model.homeHeld();
    expect(model.gameAtHome, isFalse);
    expect(model.toast, 'Online matches can\'t pause, so Home opens once you leave the match.');

    await model.openQuickMenu();
    final row = model.panelCategories().single.rows.singleWhere((row) => row.id == 'home');
    expect(row.detail, 'Not available in online play, because the match can\'t pause.');
    (row.kind as ActionRow).run();
    expect(model.overlay, Layer.quickMenu, reason: 'the match stays in front');
    expect(model.gameAtHome, isFalse);
    await session.close();
    model.running = null;
  });
}
