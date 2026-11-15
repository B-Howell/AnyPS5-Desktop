import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/ps1_launcher.dart';
import '../support/retro_host_release_fixture.dart';
import 'retro_host/real_host_support.dart' show until;

/// A release build's PS1 host: downloaded in Settings › Emulators from the host repository's signed
/// releases (the recorded release of test/fixtures/retro_host_release on a fake GitHub), checked
/// before every start and started through the checked files, with no ANYPS5_RETRO_HOST.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ps1Launcher launcher;
  // The test binding answers every HTTP request with 400; these talk to a fake GitHub on loopback.
  setUp(() => HttpOverrides.global = null);
  tearDown(() => launcher.dispose());

  PanelRow? row(String id) => launcher.emulatorSettings().rows.where((row) => row.id == id).firstOrNull;

  test('the installed release plays through its checked files, held for the host', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    final install = model.retroHostInstall!;
    expect(install.checked, isTrue);
    expect(p.isWithin(model.paths.retroHost, install.host), isTrue, reason: "the launcher's own storage");
    expect(row('retro-host-download')!.title, T.format('retroHostInstalled', ['1.0.0']));
    expect(row('retro-host-ps1'), isNotNull);
    model.closeOverlay();
    expect(model.stateOf(launcher.game), isA<Installed>());

    final playing = model.play(launcher.game);
    await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
    final checked = launcher.checked.single!;
    expect(checked.held, isTrue);
    expect((checked.executable, checked.core), (install.host, install.core));
    launcher.session.readyCompleter.complete();
    await playing;
    expect(launcher.session.startArgs?['core'], install.core);
    expect(launcher.play.core, install.core);
  });

  test('a host whose files changed is not started, and its row offers it again', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    File(model.retroHostInstall!.core).writeAsStringSync('changed\n');
    model.closeOverlay();
    await model.play(launcher.game);
    expect(launcher.opened, isEmpty);
    expect(model.retroPlay, isNull);
    expect(model.toast, T.text('retroHostCheckFailed'));
    final download = row('retro-host-download')!;
    expect((download.title, download.detail), (T.text('retroHostDownload'), T.text('retroHostBrokenDetail')));
  });

  group('downloading', () {
    late FakeGitHub github;
    setUp(() async => github = await FakeGitHub.start(repository: RetroHostStore.repository));
    tearDown(() async => github.close());

    test('offered in Settings, then checked, installed, turned on and played', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      expect(model.retroHostInstall, isNull);
      expect(row('retro-host-ps1'), isNull);
      final offer = row('retro-host-download')!;
      expect((offer.title, offer.detail), (T.text('retroHostDownload'), T.text('retroHostDownloadDetail')));
      expect(github.requests, isEmpty, reason: 'nothing is asked of GitHub before the player presses');

      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostReady', ['1.0.0']));
      expect(model.retroHostInstall?.checked, isTrue);
      expect(model.preferences.retroHostPs1, isTrue, reason: 'the first host turns the setting on');
      expect(row('retro-host-download')!.title, T.format('retroHostInstalled', ['1.0.0']));
      expect(row('retro-host-ps1'), isNotNull);

      final asked = github.downloads.length;
      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostUpToDate', ['1.0.0']));
      expect(github.downloads, hasLength(asked), reason: 'nothing newer: nothing downloaded');

      model.closeOverlay();
      final playing = model.play(launcher.game);
      await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
      expect(launcher.checked.single?.held, isTrue);
      launcher.session.readyCompleter.complete();
      await playing;
    });

    test('a broken host is downloaded again, even at the same version', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      await model.retroHostDownload.download();
      File(model.retroHostInstall!.host).writeAsStringSync('changed\n');
      model.closeOverlay();
      await model.play(launcher.game);
      expect(model.toast, T.text('retroHostCheckFailed'));
      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostReady', ['1.0.0']));
      expect(model.retroHostDownload.broken, isNull);
      final checked = await model.retroHostDownload.store.check();
      checked.release();
    });

    test('with no signed release yet, the row says so', () async {
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      await model.retroHostDownload.download();
      expect(model.toast, T.text('retroHostNotYet'));
      expect(row('retro-host-download')!.detail, T.text('retroHostNotYet'));
      expect(model.retroHostInstall, isNull);
    });

    test('not while a PS1 game plays', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(retroHostApi: github.api);
      final model = launcher.model..setRetroHostPs1(true);
      await launcher.start();
      expect(model.retroPlay, isNotNull);
      await model.retroHostDownload.download();
      expect(model.toast, T.text('retroHostDownloadCloseGame'));
      expect(github.requests, isEmpty);
    });

    test('a debug build running ANYPS5_RETRO_HOST offers no download', () async {
      launcher = Ps1Launcher(retroHostApi: github.api);
      expect(row('retro-host-download'), isNull);
      expect(row('retro-host-ps1'), isNotNull);
      expect(launcher.model.retroHostInstall?.checked, isFalse);
    });
  });
}
