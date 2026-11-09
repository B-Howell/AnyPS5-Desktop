import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/ps3_online_profile.dart';
import 'package:anyps5_desktop/core/ps3_update_import.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/panels.dart';
import 'package:anyps5_desktop/ui/ps3_settings_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart' show ps3FixtureSfo;
import '../support/ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(T.load);

  test('Play Online verifies setup and launches only the isolated PS3 profile', () async {
    const title = 'BCUS98208';
    const ppu = 'PPU-545c1abbf1c562d60fca7435401f020beab76b53';
    const patch =
        'Version: 1.2\n$ppu:\n  Protection:\n    Games:\n      Fixture:\n'
        '        $title: [01.30]\n    Patch:\n      - [be32, 0x10000, 0x60000000]\n';
    final releases = <Ps3OnlineRelease>[];
    String? selectedPatch;
    final fixture = makeFixture(
      system: HostSystem.windows,
      ps3OnlineReleases: releases,
      pickFile: (_, _) async => selectedPatch,
    );
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    File write(String path, List<int> bytes) => File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    final folder = p.join(fixture.temp.path, 'ps3-online-disc');
    final disc = write(p.join(folder, 'PS3_DISC.SFB'), [0]).path;
    write(p.join(folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN'), [0]);
    write(p.join(folder, 'PS3_GAME', 'PARAM.SFO'), ps3FixtureSfo({'TITLE_ID': title, 'APP_VER': '01.18'}));
    final managed = p.join(p.dirname(model.paths.toolkits), 'Emulators');
    write(p.join(managed, 'rpcs3_libretro.dll'), [1]);
    Directory(p.join(managed, 'system')).createSync();
    final profile = p.join(managed, 'OnlineProfiles', 'fixture', title);
    final rpcs3 = p.join(profile, 'system', 'rpcs3');
    final update = p.join(rpcs3, 'dev_hdd0', 'game', title);
    write(p.join(update, 'PARAM.SFO'), ps3FixtureSfo({'TITLE_ID': title, 'APP_VER': '01.30', 'CATEGORY': 'GD'}));
    write(p.join(update, 'USRDIR', 'EBOOT.BIN'), [2]);
    write(p.join(rpcs3, 'dev_flash', 'vsh', 'module', 'vsh.self'), [3]);
    final installedPatch = write(p.join(rpcs3, 'patches', '${title}_patch.yml'), [1]);
    final invalidPatch = write(p.join(fixture.temp.path, 'invalid.yml'), [2]);
    final reviewedPatch = write(p.join(fixture.temp.path, 'reviewed.yml'), utf8.encode(patch));
    Directory(p.join(rpcs3, 'config')).createSync();
    releases.add(
      Ps3OnlineRelease(
        provider: 'fixture',
        titleId: title,
        updateVersion: '01.30',
        updateTreeDigest: await ps3UpdateTreeDigest(Directory(await Directory(update).resolveSymbolicLinks())),
        coreSha256: sha256.convert([1]).toString(),
        executableSha256: sha256.convert([2]).toString(),
        protection: Ps3YamlProtection(
          sha256: sha256.convert(utf8.encode(patch)).toString(),
          ppuHash: ppu,
          patches: const {'Protection': 1},
        ),
        rpcnHost: 'rpcn.example.invalid',
        providerFiles: const {},
        xfloat: Ps3Xfloat.accurate,
        dns: Ps3Dns.cloudflare,
        upnp: false,
      ),
    );
    final game = Game(
      folder: folder,
      titleId: title,
      name: 'Online fixture',
      names: const {},
      defaultLanguage: 'en',
      version: '01.18',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps3, path: disc),
    );
    model.games = [game];
    model.selected = 0;
    model.open(Layer.gameSettings);
    void activate(String id) {
      final rows = model.panelCategories().single.rows;
      final index = rows.indexWhere((row) => row.id == id);
      expect(index, isNonNegative);
      model.activateRow(index);
    }

    activate('ps3-online-readiness');
    const channel = MethodChannel('anyps5/retro_core');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final start = Completer<Map<Object?, Object?>>();
    final calls = <MethodCall>[];
    var stopped = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        start.complete(call.arguments as Map<Object?, Object?>);
        return 7;
      }
      if (call.method == 'stop') stopped = true;
      return call.method == 'status' ? {'ended': stopped, 'presented': true} : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Future<void> waitFor(bool Function() settled) async {
      await Future.doWhile(() async {
        if (settled()) return false;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return true;
      }).timeout(const Duration(seconds: 5));
    }

    String? patchStatus() =>
        model.panelCategories().single.rows.singleWhere((row) => row.id == 'ps3-online-import-patch').detail;
    String? playStatus() =>
        model.panelCategories().single.rows.singleWhere((row) => row.id == 'ps3-online-play').detail;
    activate('ps3-online-play');
    await waitFor(() => playStatus()?.contains('Import Protection Patch') == true);
    selectedPatch = invalidPatch.path;
    activate('ps3-online-import-patch');
    await waitFor(() => patchStatus()?.contains('does not match') == true);
    expect(installedPatch.readAsBytesSync(), [1]);
    selectedPatch = reviewedPatch.path;
    activate('ps3-online-import-patch');
    await waitFor(() => patchStatus() == 'Reviewed patch installed.');
    expect(installedPatch.readAsStringSync(), patch);
    expect(playStatus(), contains("game's online menu"));
    expect(start.isCompleted, isFalse);

    activate('ps3-online-play');
    await waitFor(() => playStatus()?.contains('Import Provider Account') == true);
    expect(start.isCompleted, isFalse);
    const account = 'Version: 2\nHost: rpcn.example.invalid\nNPID: fixture\nPassword: test-only\nToken: fake-token\n';
    final installedAccount = File(p.join(rpcs3, 'config', 'rpcn.yml'));
    String? accountStatus() =>
        model.panelCategories().single.rows.singleWhere((row) => row.id == 'ps3-online-import-account').detail;
    final wrongAccount = write(
      p.join(fixture.temp.path, 'wrong-provider.yml'),
      utf8.encode(account.replaceFirst('rpcn.example.invalid', 'different.example.invalid')),
    );
    selectedPatch = wrongAccount.path;
    activate('ps3-online-import-account');
    await waitFor(() => accountStatus()?.contains('does not match') == true);
    expect(installedAccount.existsSync(), isFalse);
    selectedPatch = write(
      p.join(fixture.temp.path, 'account-without-token.yml'),
      utf8.encode(account.replaceFirst('Token: fake-token\n', '')),
    ).path;
    activate('ps3-online-import-account');
    await waitFor(() => accountStatus() == 'Provider account imported.');
    expect(jsonDecode(installedAccount.readAsStringSync()), containsPair('Token', ''));
    selectedPatch = write(p.join(fixture.temp.path, 'account.yml'), utf8.encode('${account}Hosts: ignored\n')).path;
    activate('ps3-online-import-account');
    await waitFor(() => accountStatus() == 'Provider account imported.');
    expect(installedAccount.readAsStringSync(), contains('fake-token'));
    expect(installedAccount.readAsStringSync(), isNot(contains('ignored')));
    selectedPatch = wrongAccount.path;
    activate('ps3-online-import-account');
    await waitFor(() => accountStatus()?.contains('does not match') == true);
    expect(installedAccount.readAsStringSync(), contains('fake-token'));
    expect(start.isCompleted, isFalse);
    activate('ps3-online-play');
    final launch = await start.future.timeout(const Duration(seconds: 5));
    expect(launch['system'], await Directory(p.join(profile, 'system')).resolveSymbolicLinks());
    expect(launch['saves'], await Directory(p.join(profile, 'saves')).resolveSymbolicLinks());
    expect(launch['ps3Online'], contains('patchProtection'));
    expect(launch.toString(), isNot(contains('fake-token')));
    expect(launch.toString(), isNot(contains('test-only')));
    expect(Directory(p.join(managed, 'system')).listSync(), isEmpty);
    await waitFor(() => model.embeddedGame?.presented == true);
    try {
      model.open(Layer.quickMenu);
      await Future<void>.delayed(Duration.zero);
      expect(
        model.panelCategories().expand((category) => category.rows).any((row) => row.id == 'retroGraphics'),
        isFalse,
      );
      expect(calls.any((call) => call.method == 'pause'), isFalse);
    } finally {
      await model.stopRunningGame();
      await waitFor(() => model.running == null && model.starting == null);
    }
  }, skip: Abi.current() != Abi.windowsX64);

  testWidgets('PS3 game settings show local online readiness and can recheck an installed update', (tester) async {
    final fixture = makeFixture(
      system: HostSystem.windows,
      environment: {'ANYPS5_PS3_CORE_DIGESTS': '${'0' * 64}:${'1' * 64}'},
      pickFolder: (_) async => null,
    );
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
    expect(model.panelCategories().single.rows.any((item) => item.id == 'ps3-online-play'), isFalse);
    expect(model.running, isNull);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget panel() => MaterialApp(
      home: Scaffold(body: PanelView(model: model)),
    );
    await tester.pumpWidget(panel());
    expect(find.text('No verified provider'), findsOneWidget);
    expect(find.textContaining('You can still play offline'), findsOneWidget);
    expect(find.text('BCUS98208'), findsOneWidget);
    model.activateRow(model.panelCategories().single.rows.indexWhere((item) => item.id == 'ps3-update-prepare'));
    await tester.pumpWidget(panel());
    expect(find.text('Update 01.30 · 11 packages'), findsOneWidget);
    expect(find.text('Choose Update Folder'), findsOneWidget);
    expect(find.text('Install Update'), findsNothing);
    model.panelCommand(Command.back);
    expect(model.spot?.row, 'ps3-update-prepare');
    model.panelCommand(Command.up);
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
