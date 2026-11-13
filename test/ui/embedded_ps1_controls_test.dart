import 'package:anyps5_desktop/core/embedded_core_host.dart';

import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_button_map.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

void main() {
  const channel = MethodChannel('anyps5/retro_core');

  testWidgets('embedded face swap leaves Start and analog axes unchanged', (tester) async {
    final fixture = makeFixture();
    final temp = fixture.temp.path;
    final disc = File(p.join(temp, 'one.cue'))..createSync();
    File(p.join(temp, 'swanstation_libretro.dll')).createSync();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final inputs = <List<dynamic>>[];
    var ended = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return 123;
      if (call.method == 'status') return {'presented': true, 'ended': ended};
      if (call.method == 'input') inputs.add(call.arguments as List<dynamic>);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      fixture.model.dispose();
      fixture.dispose();
    });
    var pad = PadState.idle;
    final session = await EmbeddedRetroGame.start(
      temp,
      (platform: RetroPlatform.ps1, path: disc.path),
      coreHost: EmbeddedCoreHost.windowsX64,
      internalResolution: null,
      onResolutionSelected: (_) {},
      graphics: const {},
      onGraphicsSelected: (_, _) {},
      readPad: () => pad,
      changed: () {},
    );
    await tester.pump(const Duration(milliseconds: 150));
    pad = const PadState(pressed: {PadButton.south, PadButton.start}, leftX: 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs.last, [(1 << 0) | (1 << 3), 16384, 0, 0, 0]);
    session.setButtonMap(RetroButtonMap.swapCrossCircle);
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs.last, [0, 0, 0, 0, 0]);
    pad = PadState.idle;
    await tester.pump(const Duration(milliseconds: 16));
    pad = const PadState(pressed: {PadButton.south, PadButton.start}, leftX: 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs.last, [(1 << 8) | (1 << 3), 16384, 0, 0, 0]);
    pad = const PadState(pressed: {PadButton.east});
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs.last, [1 << 0, 0, 0, 0, 0]);
    pad = PadState.idle;
    session.setButtonMap(
      RetroButtonMap.standard.assign(PadButton.l1, PadButton.r1).assign(PadButton.select, null).withSwapSticks(true),
    );
    await tester.pump(const Duration(milliseconds: 16));
    pad = const PadState(pressed: {PadButton.l1, PadButton.select}, leftX: 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs.last, [1 << 11, 0, 0, 16384, 0]);
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await session.exitCode;
  });

  test('an older saved Cross and Circle swap becomes the matching preset', () {
    final preferences = Preferences.fromJson({
      'retroSwapCrossCircle': ['one'],
      'retroButtonMaps': {
        'two': {'l1': 'r1', 'select': ''},
      },
    });
    expect(preferences.retroButtonMaps['one'], RetroButtonMap.swapCrossCircle);
    expect(preferences.retroButtonMaps['two']!.target(PadButton.l1), PadButton.r1);
    expect(preferences.retroButtonMaps['two']!.target(PadButton.select), isNull);
    expect(preferences.retroButtonMaps['two']!.preset, RetroControlPreset.custom);
    final again = Preferences.fromJson(jsonDecode(jsonEncode(preferences.toJson())) as Map<String, dynamic>);
    expect(again.retroButtonMaps, preferences.retroButtonMaps);
  });

  testWidgets('Per-game Controls layout persists for one game and opens from the running game', (tester) async {
    final env = <String, String>{};
    final fixture = makeFixture(environment: env);
    final model = fixture.model;
    env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
    File(p.join(fixture.temp.path, model.embeddedCoreHost.libraryName(RetroPlatform.ps1))).createSync();
    for (final name in ['First', 'Second']) {
      final folder = Directory(p.join(model.root!, name))..createSync();
      File(p.join(folder.path, 'one.cue')).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({
          'platform': 'ps1',
          'titleId': name == 'First' ? 'TEST12345' : 'TEST67890',
          'name': name,
          'disc': 'one.cue',
        }),
      );
    }
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var ended = false;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'start' => 123,
        'status' => {'presented': true, 'ended': ended},
        _ => null,
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      model.dispose();
      fixture.dispose();
    });
    model.rescan();
    final first = model.games.singleWhere((game) => game.name == 'First');
    final second = model.games.singleWhere((game) => game.name == 'Second');
    ChoiceRow presetForCurrent() {
      model.open(Layer.quickMenu);
      final quick = model.panelCategories().single.rows;
      expect(quick.map((row) => row.id), isNot(contains('retroSwapCrossCircle')));
      (quick.singleWhere((row) => row.id == 'retroControls').kind as ActionRow).run();
      expect(model.overlay, Layer.controls);
      final rows = model.panelCategories().single.rows;
      expect(
        rows.where((row) => row.id.startsWith('retroButton-')).length,
        RetroButtonMap.buttons.length,
      );
      expect(rows.map((row) => row.id), containsAll(['retroSwapSticks', 'padTest', 'retroControlsReset']));
      return rows.singleWhere((row) => row.id == 'retroControlsPreset').kind as ChoiceRow;
    }

    final firstPlay = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final firstPreset = presetForCurrent();
    expect(firstPreset.selected, 0);
    firstPreset.set(1);
    expect(
      Preferences.fromJson(model.preferences.toJson()).retroButtonMaps,
      {first.id: RetroButtonMap.swapCrossCircle},
    );
    expect(model.embeddedGame!.buttonMap, RetroButtonMap.swapCrossCircle);
    expect(LauncherProfiles.personalKeys, contains('retroButtonMaps'));
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await firstPlay;

    ended = false;
    final secondPlay = model.play(second);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(presetForCurrent().selected, 0);
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await secondPlay;

    ended = false;
    final replay = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(presetForCurrent().selected, 1);
    expect(model.embeddedGame!.buttonMap, RetroButtonMap.swapCrossCircle);
    ended = true;
    await tester.pump(const Duration(seconds: 5));
    await replay;
  });
  testWidgets('a second controller joins Couch Co-op as Player 2 and drives port 2', (tester) async {
    final env = <String, String>{};
    final fixture = makeFixture(environment: env);
    final model = fixture.model;
    env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
    File(p.join(fixture.temp.path, model.embeddedCoreHost.libraryName(RetroPlatform.ps1))).createSync();
    final folder = Directory(p.join(model.root!, 'Racing'))..createSync();
    File(p.join(folder.path, 'one.cue')).createSync();
    File(p.join(folder.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps1', 'titleId': 'TEST24680', 'name': 'Racing', 'disc': 'one.cue'}),
    );
    const one = PadInfo(id: 'sdl0', name: 'DualSense Wireless Controller', kind: PadKind.dualSense, connection: PadConnection.usb, driver: 'SDL');
    const two = PadInfo(id: 'sdl1', name: 'DualShock 4', kind: PadKind.dualShock4, connection: PadConnection.usb, driver: 'SDL');
    var states = <String, PadState>{};
    model.controllers.preview([one, two], playerOne: one.id, states: states);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final inputs = <List<dynamic>>[];
    var ended = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return 123;
      if (call.method == 'status') return {'presented': true, 'ended': ended};
      if (call.method == 'input') inputs.add(call.arguments as List<dynamic>);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      model.dispose();
      fixture.dispose();
    });
    model.rescan();
    final game = model.games.singleWhere((game) => game.name == 'Racing');
    final play = model.play(game);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await model.openQuickMenu();
    final quick = model.panelCategories().single.rows;
    expect(quick.map((row) => row.title), contains('Couch Co-op'));
    (quick.singleWhere((row) => row.id == 'coop').kind as ActionRow).run();
    expect(model.overlay, Layer.coopLobby);
    PlayerSlot seat(int player) =>
        model.panelCategories().single.rows.singleWhere((row) => row.id == 'coop-players').playerSlots[player - 1];
    expect(seat(2).joinHint, isTrue);
    expect(model.coopPadEvent(const PadButtonEvent('sdl1', PadButton.south, down: true)), isTrue);
    expect(model.localSeatPads, ['sdl1']);
    expect(seat(2).name, 'Guest');
    expect(seat(2).status, contains('DualShock 4'));
    model.resumeGame();
    states = {'sdl1': const PadState(pressed: {PadButton.north})};
    model.controllers.preview([one, two], playerOne: one.id, states: states);
    await tester.pump(const Duration(milliseconds: 48));
    expect(inputs.where((input) => input.length == 6 && input.first == 1).last, [1, 1 << 9, 0, 0, 0, 0]);
    model.open(Layer.coopLobby);
    expect(model.coopPadEvent(const PadButtonEvent('sdl1', PadButton.east, down: true)), isTrue);
    expect(model.localSeatPads, isEmpty);
    ended = true;
    await tester.pump(const Duration(seconds: 5));
    await play;
  });
}
