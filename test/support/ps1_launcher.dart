import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ui/retro_host/fake_retro_host_session.dart';
import 'fixtures.dart';
import 'ui_support.dart';

/// A launcher with one PS1 disc in its games folder, a host where ANYPS5_RETRO_HOST says, and a
/// fake host session for every game opened in it.
class Ps1Launcher {
  Ps1Launcher({bool hostFound = true}) {
    final temp = temporaryFolder('ps1-host');
    final hostFolder = Directory(p.join(temp.path, 'host'))..createSync();
    host = (File(p.join(hostFolder.path, 'anyps5-retro-host'))..createSync()).path;
    core = (File(p.join(hostFolder.path, RetroHostInstall.coreName(HostSystem.current)))..createSync()).path;
    fixture = makeFixture(withToolkit: false, environment: {if (hostFound) RetroHostInstall.variable: host});
    folders.add(temp);
    final folder = Directory(p.join(model.root!, 'Night Racer'))..createSync();
    disc = (File(p.join(folder.path, 'game.cue'))..createSync()).path;
    File(p.join(folder.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps1', 'titleId': 'SLUS00001', 'name': 'Night Racer', 'disc': 'game.cue'}),
    );
    model.setRetroLibrary(true);
    game = model.games.singleWhere((game) => game.retro != null);
    model.openRetroHost = (install, {required volume, required muted}) {
      opened.add((install, volume, muted));
      return RetroHostGame(session, statusEvery: const Duration(hours: 1), volume: volume, muted: muted);
    };
  }

  late final Fixture fixture;
  late final String host;
  late final String core;
  late final String disc;
  late final Game game;
  final folders = <Directory>[];
  final session = FakeRetroHostSession();
  final opened = <(RetroHostInstall, double, bool)>[];

  AppModel get model => fixture.model;
  RetroPlay get play => model.retroPlay!;

  /// Plays the game, the host greets the launcher and the game loads.
  Future<void> start({RetroStatus? status}) async {
    session.nextStatus = status ?? fakeStatus();
    final playing = model.play(game);
    session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
  }

  /// Settings › Emulators, opened.
  PanelCategory emulatorSettings() {
    model.open(Layer.settings);
    return model.panelCategories().singleWhere((category) => category.id == 'emulators');
  }

  PanelRow row(String id) => model.panelCategories().single.rows.singleWhere((row) => row.id == id);

  bool _modelDisposed = false;

  /// The launcher goes away now (as when it quits), before the test ends.
  void disposeModel() {
    _modelDisposed = true;
    model.dispose();
  }

  void dispose() {
    if (!_modelDisposed) model.dispose();
    fixture.dispose();
    for (final folder in folders) {
      folder.deleteSync(recursive: true);
    }
  }
}

/// A two-disc game's status with the internal resolution option, as protocol.md "status" shows.
RetroStatus menuStatus({int selected = 0, bool busy = false, bool failed = false}) => RetroStatus(
  ready: true,
  ended: false,
  error: '',
  errorCode: '',
  options: {
    'swanstation_GPU_ResolutionScale': RetroOption(
      key: 'swanstation_GPU_ResolutionScale',
      title: 'Internal Resolution',
      values: const ['1', '2', '4'],
      labels: const ['1x', '2x', '4x'],
      selected: selected,
      activeValue: const ['1', '2', '4'][selected],
      restart: false,
    ),
  },
  discs: RetroDiscs(
    labels: const ['Disc 1', 'Disc 2'],
    inserted: 0,
    insertedDiscPath: null,
    playedDiscPath: '',
    busy: busy,
    failed: failed,
  ),
);
