import 'package:anyps5_desktop/core/embedded_core_host.dart';

import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('anyps5/retro_core');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('an ordinary PS3 launch keeps its offline storage and never requests online mode', () async {
    final root = await Directory.systemTemp.createTemp('ps3-offline-launch-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await File(p.join(root.path, 'rpcs3_libretro.dll')).writeAsBytes([0]);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => 7,
        'status' => {'ended': true},
        _ => null,
      };
    });

    final game = await EmbeddedRetroGame.start(
      root.path,
      (platform: RetroPlatform.ps3, path: p.join(root.path, 'PS3_DISC.SFB')),
      coreHost: EmbeddedCoreHost.windowsX64,
      internalResolution: null,
      graphics: const {},
      onResolutionSelected: (_) {},
      onGraphicsSelected: (_, _) {},
      readPad: () => PadState.idle,
      changed: () {},
    );
    expect(game.ps3ProviderStatus, isNull);
    expect(await game.exitCode.timeout(const Duration(seconds: 2)), 0);
    final launch = calls.singleWhere((call) => call.method == 'start').arguments as Map;
    expect(launch, isNot(contains('ps3Online')));
    expect(launch['system'], p.join(root.path, 'system'));
    expect(launch['saves'], p.join(root.path, 'saves', 'ps3'));
  });
}
