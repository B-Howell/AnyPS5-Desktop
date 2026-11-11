import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

void main() {
  const channel = MethodChannel('anyps5/retro_core');

  testWidgets('embedded game binds every Linux command to its run, even when the texture is reused', (tester) async {
    final fixture = makeFixture();
    final folder = fixture.temp.path;
    final disc = File(p.join(folder, 'one.cue'))..createSync();
    File(p.join(folder, 'swanstation_libretro.dll')).createSync();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var owner = 0;
    var ended = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') return {'texture': 123, 'session': ++owner};
      final arguments = call.arguments as Map;
      expectSync(arguments.keys, unorderedEquals(['owner', 'value']));
      expectSync(arguments['owner'], owner);
      if (call.method == 'status') return {'presented': true, 'ended': ended};
      if (call.method == 'stop') ended = true;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      fixture.model.dispose();
      fixture.dispose();
    });
    for (var run = 1; run <= 2; run++) {
      ended = false;
      calls.clear();
      final game = await EmbeddedRetroGame.start(
        folder,
        (platform: RetroPlatform.ps1, path: disc.path),
        internalResolution: null,
        onResolutionSelected: (_) {},
        graphics: const {},
        onGraphicsSelected: (_, _) {},
        readPad: () => PadState.idle,
        changed: () {},
      );
      expect(game.textureId, 123);
      await tester.pump(const Duration(milliseconds: 150));
      expect(await game.ready, isTrue);
      game.playback(playing: false, focused: true);
      await tester.pump();
      await game.close();
      await tester.pump(const Duration(milliseconds: 150));
      await game.exitCode;
      expect(calls.map((call) => call.method), containsAll(['start', 'status', 'input', 'pause', 'stop', 'release']));
      for (final call in calls.where((call) => call.method != 'start')) {
        expect((call.arguments as Map)['owner'], run);
      }
    }
  });
}
