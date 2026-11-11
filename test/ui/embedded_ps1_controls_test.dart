import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
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
    File(p.join(temp, ManagedRetro.libraryName(RetroPlatform.ps1))).createSync();
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
    session.setSwapCrossCircle(true);
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
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await session.exitCode;
  });

  testWidgets('Quick Menu face swap persists for one game and is restored on launch', (tester) async {
    final env = <String, String>{};
    final fixture = makeFixture(environment: env);
    final model = fixture.model;
    env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
    File(p.join(fixture.temp.path, ManagedRetro.libraryName(RetroPlatform.ps1))).createSync();
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
    ToggleRow toggleForCurrent() {
      model.open(Layer.quickMenu);
      return model.panelCategories().single.rows.singleWhere((row) => row.id == 'retroSwapCrossCircle').kind
          as ToggleRow;
    }

    final firstPlay = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final firstToggle = toggleForCurrent();
    expect(firstToggle.value, isFalse);
    firstToggle.set(true);
    expect(Preferences.fromJson(model.preferences.toJson()).retroSwapCrossCircle, {first.id});
    expect(LauncherProfiles.personalKeys, contains('retroSwapCrossCircle'));
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await firstPlay;

    ended = false;
    final secondPlay = model.play(second);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(toggleForCurrent().value, isFalse);
    ended = true;
    await tester.pump(const Duration(milliseconds: 150));
    await secondPlay;

    ended = false;
    final replay = model.play(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(toggleForCurrent().value, isTrue);
    ended = true;
    await tester.pump(const Duration(seconds: 5));
    await replay;
  });
}
