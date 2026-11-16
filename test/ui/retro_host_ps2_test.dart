import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_host/ps2_bios.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ps1_launcher.dart';

/// A made-up image of a BIOS's shape, never a real one: 4 MiB of zeros with a ROM directory of
/// RESET, ROMDIR, EXTINFO and ROMVER at 0x2700, as LRPS2's `IsBIOS` reads one.
Uint8List biosShaped({String romver = '0220AC20060210'}) {
  final image = Uint8List(Ps2Bios.minBytes);
  final data = ByteData.sublistView(image);
  var entry = 0x2700;
  for (final (name, size) in [('RESET', 0x2700), ('ROMDIR', 0x50), ('EXTINFO', 0x20), ('ROMVER', 14)]) {
    image.setRange(entry, entry + name.length, ascii.encode(name));
    data.setUint32(entry + 12, size, Endian.little);
    entry += 16;
  }
  image.setRange(0x2770, 0x2770 + 14, ascii.encode(romver));
  return image;
}

/// The status the real LRPS2 sent when it found no BIOS
/// (test/fixtures/retro_host/ps2_lrps2_and_fake_core.json).
RetroStatus recordedNoBios() {
  final file = jsonDecode(File('test/fixtures/retro_host/ps2_lrps2_and_fake_core.json').readAsStringSync()) as Map;
  final replies = ((file['lrps2'] as Map)['replies'] as List).cast<Map<String, Object?>>();
  final ended = replies.firstWhere((reply) => reply['game'] == 'noBiosFolder' && reply['when'] == 'ended');
  return RetroStatus.parse(
    (jsonDecode(ended['reply']! as String) as Map<String, Object?>)['result']! as Map<String, Object?>,
    coreIdentity: true,
    gameTiming: true,
    ps2: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ps1Launcher launcher;
  tearDown(() => launcher.dispose());

  List<String> rowIds() => launcher.emulatorSettings().rows.map((row) => row.id).toList();

  test('the PS2 row shows only where the host has LRPS2 beside it, off until turned on', () {
    launcher = Ps1Launcher();
    expect(rowIds(), isNot(contains('retro-host-ps2')));
    launcher.model.setRetroHostPs2(true);
    expect(launcher.model.playsInHost(RetroPlatform.ps2), isFalse, reason: 'no LRPS2 beside the host');
    launcher.dispose();

    launcher = Ps1Launcher(ps2Core: true);
    final model = launcher.model;
    expect(model.retroHostInstall!.ps2Core, launcher.ps2CorePath);
    expect(model.preferences.retroHostPs2, isFalse);
    expect(model.playsInHost(RetroPlatform.ps2), isFalse);
    final ids = rowIds();
    expect(ids, containsAllInOrder(['retro-host-ps1', 'retro-host-ps2']));
    expect(ids, isNot(contains('retro-host-ps2-bios')));
    model.closeOverlay();

    model.setRetroHostPs2(true);
    expect(model.playsInHost(RetroPlatform.ps2), isTrue);
    expect(model.playsInHost(RetroPlatform.ps1), isFalse, reason: 'each console has its own setting');
    final bios = launcher.emulatorSettings().rows.singleWhere((row) => row.id == 'retro-host-ps2-bios');
    expect(bios.title, T.text('retroHostPs2Bios'));
    expect(bios.detail, T.text('retroHostPs2BiosChoose'));
    expect(model.preferences.toJson()['retroHostPs2'], isTrue);
  });

  test('the BIOS picked is checked, copied into pcsx2/bios, kept by name and shown by its version', () async {
    String? picked;
    final labels = <String>[];
    launcher = Ps1Launcher(
      ps2Core: true,
      pickFile: (label, extensions) async {
        labels.add(label);
        return picked;
      },
    );
    final model = launcher.model..setRetroHostPs2(true);
    final own = Directory(p.join(launcher.folders.single.path, 'dumps'))..createSync();

    picked = (File(p.join(own.path, 'not-a-bios.bin'))..writeAsBytesSync(Uint8List(Ps2Bios.minBytes))).path;
    await model.choosePs2Bios();
    expect(labels, [T.text('retroHostPs2BiosPick')]);
    expect(model.toast, T.text('retroHostPs2BiosNoTable'));
    expect(Directory(Ps2Bios.folderIn(model.paths.retroSystem)).existsSync(), isFalse);
    expect(model.preferences.retroHostPs2Bios, isNull);

    picked = (File(p.join(own.path, 'tiny.bin'))..writeAsBytesSync([1, 2, 3])).path;
    await model.choosePs2Bios();
    expect(model.toast, T.text('retroHostPs2BiosWrongSize'));

    picked = (File(p.join(own.path, 'my-console.bin'))..writeAsBytesSync(biosShaped())).path;
    File(p.join(own.path, 'my-console.nvm')).writeAsBytesSync([7]);
    await model.choosePs2Bios();
    final shown = T.format('retroHostPs2BiosVersion', [T.text('retroHostPs2RegionUsa'), '2.20', '2006']);
    expect(model.toast, T.format('retroHostPs2BiosReady', [shown]));
    final folder = Ps2Bios.folderIn(model.paths.retroSystem);
    expect(File(p.join(folder, 'my-console.bin')).readAsBytesSync(), biosShaped());
    expect(File(p.join(folder, 'my-console.nvm')).readAsBytesSync(), [7]);
    expect(model.preferences.toJson()['retroHostPs2Bios'], {'file': 'my-console.bin', 'version': '0220AC20060210'});
    final row = launcher.emulatorSettings().rows.singleWhere((row) => row.id == 'retro-host-ps2-bios');
    expect(row.detail, T.format('retroHostPs2BiosChosen', [shown]));
    final kept = jsonEncode(model.preferences.toJson());
    expect(kept, isNot(contains(own.path.replaceAll(r'\', r'\\'))), reason: 'only the name is kept');

    picked = null;
    await model.choosePs2Bios();
    expect(model.preferences.retroHostPs2Bios?.fileName, 'my-console.bin', reason: 'a cancelled pick keeps it');
    File(p.join(folder, 'my-console.bin')).deleteSync();
    expect(model.retroPs2Bios, isNull, reason: 'a BIOS taken out of the folder is not shown as chosen');
  });

  test('a failed file picker says so and keeps the BIOS chosen', () async {
    launcher = Ps1Launcher(
      ps2Core: true,
      pickFile: (_, _) async => throw PlatformException(code: 'picker-unavailable'),
    );
    final model = launcher.model..setRetroHostPs2(true);
    await model.choosePs2Bios();
    expect(model.toast, T.text('retroEmulatorPickerFailed'));
    expect(model.preferences.retroHostPs2Bios, isNull);
  });

  test("a PS2 disc starts on LRPS2 with console ps2, its own saves, LRPS2's options and the BIOS chosen", () async {
    launcher = Ps1Launcher(ps2Core: true);
    final model = launcher.model
      ..setRetroHostPs2(true)
      ..preferences.retroHostOptions.addAll({
        'swanstation_GPU_ResolutionScale': '4',
        'pcsx2_fastboot': 'disabled',
        'pcsx2_bios': 'another.bin',
      });
    final folder = Directory(Ps2Bios.folderIn(model.paths.retroSystem))..createSync(recursive: true);
    File(p.join(folder.path, 'mine.bin')).writeAsBytesSync(biosShaped());
    model.preferences.retroHostPs2Bios = const Ps2Bios(fileName: 'mine.bin', version: '0220AC20060210');
    final game = launcher.ps2Game;
    expect(model.stateOf(game), isA<Installed>(), reason: 'no PCSX2 needed');

    final playing = model.play(game);
    await pumpEventQueue();
    launcher.session.nextStatus = recordedNoBios();
    launcher.session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
    expect(launcher.opened.single.$1.ps2Core, launcher.ps2CorePath);
    expect(launcher.play.core, launcher.ps2CorePath);
    expect(launcher.session.startArgs, {
      'console': RetroConsole.ps2,
      'core': launcher.ps2CorePath,
      'disc': p.normalize(launcher.ps2Disc!),
      'system': p.normalize(model.paths.retroSystem),
      'saves': p.normalize(model.paths.retroPs2Saves),
      'options': {'pcsx2_fastboot': 'disabled', Ps2Bios.option: 'mine.bin'},
    });

    expect(launcher.play.host.phase, RetroHostGamePhase.ended);
    expect(launcher.play.problem, 'retroHostPs2NoBiosDetail', reason: "the host's bios in plain words");
    expect(T.text(launcher.play.problem!), contains('Settings'));
  });

  test('a PS1 disc on the same host still starts as before, given no PS2 options', () async {
    launcher = Ps1Launcher(ps2Core: true);
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..setRetroHostPs2(true)
      ..preferences.retroHostOptions.addAll({'pcsx2_fastboot': 'disabled', 'swanstation_GPU_ResolutionScale': '2'});
    await launcher.start();
    expect(launcher.session.startArgs, {
      'core': launcher.core,
      'disc': p.normalize(launcher.disc),
      'system': p.normalize(model.paths.retroSystem),
      'saves': p.normalize(model.paths.retroSaves),
      'options': {'swanstation_GPU_ResolutionScale': '2'},
    });
  });

  test('a PS2 game on a host without ps2 is never sent, and says the host needs updating', () async {
    launcher = Ps1Launcher(ps2Core: true);
    final model = launcher.model..setRetroHostPs2(true);
    launcher.session.canPlayPs2 = false;
    final playing = model.play(launcher.ps2Game);
    await pumpEventQueue();
    launcher.session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
    expect(launcher.session.startArgs, isNull);
    expect(launcher.play.host.consoleRefused, isTrue);
    expect(launcher.play.problem, 'retroHostNoPs2Detail');
  });

  test('a PS2 game is kept out of online play, saying why', () async {
    launcher = Ps1Launcher(ps2Core: true);
    final model = launcher.model..setRetroHostPs2(true);
    final playing = model.play(launcher.ps2Game);
    await pumpEventQueue();
    launcher.session.nextStatus = RetroStatus(
      ready: true,
      ended: false,
      error: '',
      errorCode: '',
      console: RetroConsole.ps2,
      core: recordedNoBios().core,
    );
    launcher.session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
    expect(model.retroOnlineUnavailable(launcher.play), 'retroOnlinePs1Only');
    final reason = model.retroLobbyRows(launcher.play).singleWhere((row) => row.id == 'coop-unavailable');
    expect((reason.kind as InfoRow).text, T.text('retroOnlinePs1OnlyDetail'));
  });
}
