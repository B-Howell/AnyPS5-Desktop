import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/main.dart' as app;
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// The real launcher on a real display, driven through its own screens: first start, Settings ›
/// Game Library › Emulator games, Settings › Emulators' host switches and BIOS folder rows, the
/// library's PS1 and PS2 tiles, a game started from its tile and seen in the window, the PS menu,
/// Close game, and Quit. Configured only through the environment:
///
/// - `UI_GAMES`: the games folder, with a PS1 game and a PS2 game under a `PS2` folder.
/// - `UI_PS1_BIOS`, `UI_PS2_BIOS`: BIOS files copied into the folders the BIOS rows open.
/// - `UI_PS1_NAME`, `UI_PS2_NAME`: the two games' names in the library.
/// - `UI_PICK_FOLDER`: a program run with the games folder while the folder dialog is open, to
///   choose it in the system's dialog (the test cannot reach that dialog itself).
/// - `UI_SHOT`: a program run with a file name to save a picture of the screen.
/// - `UI_OUT`: the folder the pictures and `steps.json` go in.
/// - `ANYPS5_RETRO_HOST`: the host this debug or test build runs, with its cores beside it.
/// - `UI_PS2_SECONDS`: how long the PS2 game is watched (75 s when unset); software rendering
///   plays PS2 slowly, so its first lit picture can take over a minute.
///
/// Each game's host frame times, picture times and lit share every 10 s go to `<console>-frames.json`
/// in `UI_OUT`, so a recording of the game's sound can be lined up with its frame rate. The host plays
/// sound itself: run this with `PULSE_SERVER` pointing at a server whose only sink is a null sink.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final env = Platform.environment;
  final out = env['UI_OUT']!;
  final steps = <Map<String, Object?>>[];

  void record(String step, bool pass, String shot, String note) {
    steps.add({
      'step': step,
      'pass': pass,
      'shot': shot,
      'note': note,
      'at': DateTime.now().millisecondsSinceEpoch / 1000,
    });
    stdout.writeln('STEP ${pass ? 'PASS' : 'FAIL'} $step [$shot] $note');
    File(p.join(out, 'steps.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(steps));
  }

  testWidgets('the launcher plays a PS1 and a PS2 disc through its own screens', (tester) async {
    Future<void> settle(Duration time) async {
      final end = DateTime.now().add(time);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    Future<bool> waitFor(bool Function() done, Duration limit) async {
      final end = DateTime.now().add(limit);
      while (!done()) {
        if (DateTime.now().isAfter(end)) return false;
        await settle(const Duration(milliseconds: 200));
      }
      return true;
    }

    Future<String> shot(String name) async {
      await settle(const Duration(milliseconds: 600));
      final result = await Process.run(env['UI_SHOT']!, [p.join(out, '$name.png')]);
      stdout.writeln('shot $name: ${result.stdout}${result.stderr}'.trim());
      return '$name.png';
    }

    Future<void> key(LogicalKeyboardKey key, {int times = 1}) async {
      for (var i = 0; i < times; i++) {
        await tester.sendKeyEvent(key);
        await settle(const Duration(milliseconds: 250));
      }
    }

    Future<bool> tapText(String text) async {
      final found = find.text(text, findRichText: true);
      if (found.evaluate().isEmpty) {
        stdout.writeln('no "$text" on screen');
        return false;
      }
      await tester.ensureVisible(found.first);
      await settle(const Duration(milliseconds: 400));
      await tester.tap(found.first, warnIfMissed: false);
      await settle(const Duration(milliseconds: 500));
      return true;
    }

    final testOnError = FlutterError.onError;
    unawaited(app.main([]));
    await settle(const Duration(seconds: 6));
    FlutterError.onError = testOnError;
    final model = tester.widget<app.AnyPS5App>(find.byType(app.AnyPS5App)).model;

    // First start: language, theme, the games folder through the system's folder dialog, no
    // engine, an offline profile.
    var name = await shot('01-first-start');
    record('First start shows the welcome step', !model.preferences.onboarded, name, 'step ${model.onboardingStep}');
    await key(LogicalKeyboardKey.enter);
    await key(LogicalKeyboardKey.enter);
    final games = env['UI_GAMES']!;
    final picker = Process.start(env['UI_PICK_FOLDER']!, [games, p.join(out, 'folder-dialog.png')]);
    await key(LogicalKeyboardKey.enter);
    final picked = await waitFor(() => model.preferences.gamesFolders.isNotEmpty, const Duration(seconds: 400));
    final pickerLog = await (await picker).stdout.transform(utf8.decoder).join();
    stdout.writeln('picker: $pickerLog');
    record(
      'Games folder chosen in the folder dialog',
      picked && model.preferences.gamesFolders.first == games,
      'folder-dialog.png',
      'folders ${model.preferences.gamesFolders}; picker: ${pickerLog.trim().replaceAll('\n', ' | ')}',
    );
    name = await shot('02-folder-step');
    if (!picked) {
      record('First start', false, name, 'stopped: no games folder');
      return;
    }
    await key(LogicalKeyboardKey.enter);
    await settle(const Duration(seconds: 2));
    await key(LogicalKeyboardKey.arrowRight, times: 2);
    await key(LogicalKeyboardKey.enter);
    await settle(const Duration(seconds: 1));
    await key(LogicalKeyboardKey.enter);
    final onboarded = await waitFor(() => model.preferences.onboarded, const Duration(seconds: 20));
    await settle(const Duration(seconds: 4));
    name = await shot('03-home-before');
    record(
      'First start finished (no engine, offline profile)',
      onboarded,
      name,
      'step ${model.onboardingStep}, overlay ${model.overlay}, games ${model.games.length}',
    );
    final retroBefore = model.games.where((game) => game.retro != null).length;
    stdout.writeln(
      'volumes: launcher ${model.launcherVolume}, host ${model.preferences.retroHostVolume}, music ${model.musicVolume}',
    );

    // Settings › Game Library › Emulator games.
    await tester.tap(find.byIcon(Icons.settings_rounded).first, warnIfMissed: false);
    await settle(const Duration(seconds: 1));
    final opened = model.overlay == Layer.settings;
    await tapText(T.text('library'));
    final rowFound = await tapText(T.text('retroLibrary'));
    final libraryOn = await waitFor(() => model.preferences.retroLibrary, const Duration(seconds: 3));
    name = await shot('04-settings-emulator-games');
    record(
      'Settings › Game library › Emulator games turned on',
      opened && rowFound && libraryOn,
      name,
      'settings open $opened, row found $rowFound, retroLibrary ${model.preferences.retroLibrary}; emulator games listed before: $retroBefore',
    );

    // Settings › Emulators: the unchecked host's notice, the PS1 and PS2 switches, the BIOS rows.
    var sections = 0;
    while (find.text(T.text('retroHostPs1')).evaluate().isEmpty && sections < 30) {
      await key(LogicalKeyboardKey.keyE);
      sections++;
    }
    stdout.writeln('Emulators reached after $sections presses of E');
    name = await shot('05-settings-emulators-off');
    final unchecked = find.text(T.text('retroHostUnchecked')).evaluate().isNotEmpty;
    final ps1Row = await tapText(T.text('retroHostPs1'));
    final ps1On = await waitFor(() => model.preferences.retroHostPs1, const Duration(seconds: 3));
    final ps2Row = await tapText(T.text('retroHostPs2'));
    final ps2On = await waitFor(() => model.preferences.retroHostPs2, const Duration(seconds: 3));
    name = await shot('06-settings-emulators-on');
    final install = model.retroHostInstall;
    record(
      'Settings › Emulators: PS1 and PS2 host switches on',
      ps1Row && ps1On && ps2Row && ps2On,
      name,
      'unchecked notice $unchecked; host ${install?.host}; ps1 core ${install?.core}; ps2 core ${install?.ps2Core}',
    );

    final opens = File(p.join(env['HOME']!, 'xdg-open.log'));
    if (opens.existsSync()) opens.deleteSync();
    final ps1Bios = await tapText(T.text('retroHostBiosFolder'));
    await settle(const Duration(seconds: 1));
    final ps2Bios = await tapText(T.text('retroHostPs2BiosFolder'));
    await settle(const Duration(seconds: 1));
    final opened2 = opens.existsSync() ? opens.readAsLinesSync() : <String>[];
    final rightFolders =
        opened2.length == 2 &&
        p.equals(opened2[0], model.paths.retroSystem) &&
        p.equals(opened2[1], model.paths.retroPs2Bios) &&
        Directory(model.paths.retroSystem).existsSync() &&
        Directory(model.paths.retroPs2Bios).existsSync();
    record(
      'BIOS folder rows open the folders the host reads',
      ps1Bios && ps2Bios && rightFolders,
      name,
      'opened $opened2; expected ${model.paths.retroSystem} and ${model.paths.retroPs2Bios}',
    );
    for (final (bios, folder) in [
      (env['UI_PS1_BIOS']!, model.paths.retroSystem),
      (env['UI_PS2_BIOS']!, model.paths.retroPs2Bios),
    ]) {
      Directory(folder).createSync(recursive: true);
      File(bios).copySync(p.join(folder, p.basename(bios)));
    }

    // The library: both discs as tiles.
    for (var i = 0; i < 3 && model.overlay == Layer.settings; i++) {
      await key(LogicalKeyboardKey.escape);
    }
    await settle(const Duration(seconds: 3));
    final ps1Name = env['UI_PS1_NAME']!;
    final ps2Name = env['UI_PS2_NAME']!;
    final listed = await waitFor(
      () =>
          model.games.any((game) => game.retro?.platform == RetroPlatform.ps1 && game.name == ps1Name) &&
          model.games.any((game) => game.retro?.platform == RetroPlatform.ps2 && game.name == ps2Name),
      const Duration(seconds: 30),
    );
    name = await shot('07-library-tiles');
    record(
      'Library lists the PS1 and PS2 discs',
      listed && model.overlay == null,
      name,
      'overlay ${model.overlay}; games ${[for (final game in model.games) '${game.name} (${game.retro?.platform.name ?? 'ps5'}, ${model.stateOf(game).runtimeType})']}',
    );

    Future<void> playGame(String title, RetroPlatform platform, String tag, int first, Duration boot) async {
      final index = model.games.indexWhere((game) => game.name == title && game.retro?.platform == platform);
      if (index < 0) {
        record('$tag: start from its tile', false, '', 'not in the library');
        return;
      }
      var moves = 0;
      final focusedIndex = model.games.indexOf(model.selectedGame ?? model.games.first);
      final direction = index >= focusedIndex ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
      while (model.selectedGame?.name != title && moves < model.games.length + 2) {
        await key(direction);
        moves++;
      }
      final selected = model.selectedGame?.name == title;
      name = await shot('${first.toString().padLeft(2, '0')}-$tag-tile');
      await key(LogicalKeyboardKey.enter);
      final started = await waitFor(() => model.retroPlay != null, const Duration(seconds: 10));
      if (!started && model.overlay != null) {
        stdout.writeln('after Enter: overlay ${model.overlay}');
        await key(LogicalKeyboardKey.enter);
      }
      final play = model.retroPlay;
      record(
        '$tag: started from its tile',
        selected && play != null,
        name,
        'selected $selected after $moves moves; overlay ${model.overlay}; retroPlay ${play != null}',
      );
      if (play == null) return;
      final loaded = await waitFor(() => play.host.phase != RetroHostGamePhase.loading, const Duration(seconds: 60));
      var pictures = 0;
      var lit = 0;
      Uint8List? last;
      final frameTimes = <double>[];
      final pictureTimes = <double>[];
      void count() {
        pictures++;
        pictureTimes.add(DateTime.now().millisecondsSinceEpoch / 1000);
      }

      final frameWatch = play.host.session.frames.listen(
        (_) => frameTimes.add(DateTime.now().microsecondsSinceEpoch / 1e6),
      );
      play.host.picture.addListener(count);
      final watched = DateTime.now();
      final litLog = <String>[];
      final bootEnd = watched.add(boot);
      while (DateTime.now().isBefore(bootEnd)) {
        await settle(const Duration(seconds: 10));
        final pixels = await _pixels(play.host.picture.value);
        litLog.add(
          '${DateTime.now().difference(watched).inSeconds}s:${pixels == null ? 'none' : _litPercent(pixels)}%',
        );
      }
      stdout.writeln('$tag lit over time: $litLog');
      final seconds = DateTime.now().difference(watched).inMilliseconds / 1000;
      play.host.picture.removeListener(count);
      await frameWatch.cancel();
      File(p.join(out, '$tag-frames.json')).writeAsStringSync(
        jsonEncode({
          'watched_from': watched.millisecondsSinceEpoch / 1000,
          'seconds': seconds,
          'host_frames': frameTimes,
          'pictures': pictureTimes,
          'lit': litLog,
          'volume': play.host.volume,
          'muted': play.host.muted,
        }),
      );
      stdout.writeln(
        '$tag: ${frameTimes.length} host frames and $pictures pictures in ${seconds.toStringAsFixed(1)} s',
      );
      for (var i = 0; i < 5; i++) {
        final pixels = await _pixels(play.host.picture.value);
        if (pixels != null && _lit(pixels) && (last == null || !_same(last, pixels))) lit++;
        last = pixels ?? last;
        await settle(const Duration(milliseconds: 300));
      }
      final image = play.host.picture.value;
      name = await shot('${(first + 1).toString().padLeft(2, '0')}-$tag-in-game');
      record(
        '$tag: frames in the launcher window',
        loaded && play.host.phase == RetroHostGamePhase.playing && lit >= 2,
        name,
        'phase ${play.host.phase}, failure ${play.host.failure}, problem ${play.problem}; '
            '${(pictures / seconds).toStringAsFixed(1)} picture updates/s over ${seconds.toStringAsFixed(0)} s '
            '(debug launcher, llvmpipe); ${(frameTimes.length / seconds).toStringAsFixed(1)} host frames/s; '
            'host volume ${play.host.volume} muted ${play.host.muted}; ${image?.width}x${image?.height}; $lit of 5 samples lit and changing; '
            'lit share every 10 s: $litLog',
      );
      if (play.host.phase != RetroHostGamePhase.playing) return;

      model.padCommand(PadCommand.home);
      final menu = await waitFor(() => model.overlay == Layer.retroMenu, const Duration(seconds: 3));
      await settle(const Duration(seconds: 1));
      final paused = play.host.paused;
      name = await shot('${(first + 2).toString().padLeft(2, '0')}-$tag-ps-menu');
      final rows = menu ? [for (final row in model.panelCategories().single.rows) row.id] : const <String>[];
      record('$tag: PS menu over the game', menu && paused, name, 'paused $paused; rows $rows');

      final closeRow = await tapText(T.text('quickCloseGame'));
      final closed = await waitFor(() => model.retroPlay == null, const Duration(seconds: 30));
      await settle(const Duration(seconds: 2));
      name = await shot('${(first + 3).toString().padLeft(2, '0')}-$tag-closed');
      record(
        '$tag: Close game back to the library',
        closeRow && closed && model.overlay == null,
        name,
        'phase ${play.host.phase}; overlay ${model.overlay}; host kept ${model.retroHostKeeper.holding}',
      );
    }

    await playGame(ps1Name, RetroPlatform.ps1, 'ps1', 8, const Duration(seconds: 60));
    await playGame(
      ps2Name,
      RetroPlatform.ps2,
      'ps2',
      12,
      Duration(seconds: int.tryParse(env['UI_PS2_SECONDS'] ?? '') ?? 75),
    );

    // Quit: Esc on the home screen asks, Quit answers.
    await key(LogicalKeyboardKey.escape);
    final asked = model.overlay == Layer.confirmQuit;
    name = await shot('16-quit-question');
    record('Esc on the home screen asks Quit AnyPS5?', asked, name, 'overlay ${model.overlay}');
    File(p.join(out, 'quit-requested')).writeAsStringSync(DateTime.now().toIso8601String());
    final quit = await tapText(T.text('quit'));
    if (!quit) await key(LogicalKeyboardKey.enter);
    await settle(const Duration(seconds: 20));
    record('Quit closes the launcher', false, '', 'still running 20 s after Quit');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<Uint8List?> _pixels(ui.Image? image) async {
  if (image == null) return null;
  final clone = image.clone();
  try {
    return (await clone.toByteData(format: ui.ImageByteFormat.rawRgba))?.buffer.asUint8List();
  } finally {
    clone.dispose();
  }
}

bool _lit(Uint8List pixels) {
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] > 16 || pixels[i + 1] > 16 || pixels[i + 2] > 16) return true;
  }
  return false;
}

int _litPercent(Uint8List pixels) {
  var lit = 0;
  var all = 0;
  for (var i = 0; i < pixels.length; i += 64) {
    all++;
    if (pixels[i] > 16 || pixels[i + 1] > 16 || pixels[i + 2] > 16) lit++;
  }
  return all == 0 ? 0 : lit * 100 ~/ all;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 64) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
