part of 'app_model.dart';

/// A PS1 or PS2 game playing in the launcher's window through the emulator host: the game, its
/// controllers and its in-game menu.
class RetroPlay {
  RetroPlay({
    required this.game,
    required this.host,
    required this.controls,
    required this.menu,
    required this.graphics,
    required this.monitor,
    required this.started,
    required this.program,
    required this.core,
  });

  final Game game;
  final RetroHostGame host;

  /// The host executable the game runs in, so its host is kept only for games of the same one.
  final String program;

  /// The core library the game was started with: SwanStation, or LRPS2 for a PS2 game.
  final String core;
  final RetroHostControls controls;
  final RetroGameMenu menu;

  /// Its Graphics page and the frame counter its speed check uses.
  final RetroGraphics graphics;
  final RetroFrameMonitor monitor;
  final DateTime started;

  /// The player chose Close Game: the end that follows is not an error to show.
  bool closing = false;

  /// When the game stopped being played: it ended on its own, or Close Game began. Play time is
  /// counted to here, not to when an error screen was left.
  DateTime? endedAt;

  /// The game is over (ended, closing or closed), even while its error screen still shows.
  bool get over => endedAt != null;

  /// Its play time went to the family rules ([RetroHostPlaying._countRetroPlay]); once only.
  bool counted = false;

  /// The section of the menu shown, or null for the menu's first page.
  RetroOptionSection? menuSection;

  /// The menu shows the game's lobby (retro_host_online.dart).
  bool lobby = false;

  /// The friend's game of an online match until it plays the match: it runs muted and is not
  /// shown, since the host player's state replaces what it plays first (anyps5-retro-host
  /// docs/netplay.md "Joining a running game", step 4).
  bool joining = false;

  bool _released = false;

  /// Lets go of the controllers, the menu and the host, once, whoever asks first: Close Game, or
  /// the launcher going away while Close Game still waits on the host.
  void release(VoidCallback listener) {
    if (_released) return;
    _released = true;
    host.removeListener(listener);
    controls.dispose();
    graphics.dispose();
    monitor.dispose();
    menu.dispose();
    host.dispose();
  }

  /// The game is starting or loading: the loading screen shows.
  bool get loading => host.phase == RetroHostGamePhase.starting || host.phase == RetroHostGamePhase.loading;

  /// Why the game stopped, as the key of the words to show the player; null while it plays, and
  /// for a game that ended without an error or that the player closed.
  String? get problem => closing ? null : retroHostProblem(host, ps2: game.retro?.platform == RetroPlatform.ps2);
}

/// Why [host]'s game stopped, as the key of the words to show the player; null while it plays or
/// after a clean end. A host that speaks another protocol version "needs updating" (protocol.md
/// "Host failure"), and one that never greeted the launcher could not be started. A game that
/// could not be followed (a refused `status` or `pause`) keeps its last status, which says no
/// error: its [RetroHostGame.failure] makes it one without a known cause. A [ps2] game a host
/// without `ps2` was never given ([RetroHostGame.consoleRefused]) needs a newer host.
String? retroHostProblem(RetroHostGame host, {bool ps2 = false}) {
  if (host.phase != RetroHostGamePhase.ended) return null;
  if (host.hostEnd == RetroHostEnd.unsupported) return 'retroHostOutdatedDetail';
  if (host.consoleRefused) return 'retroHostNoPs2Detail';
  final status = host.endStatus;
  if (status == null) return host.failure == null ? null : 'retroHostNotStartedDetail';
  return retroHostErrorKey(status.errorCode, ps2: ps2) ?? (host.failure == null ? null : 'retroHostOtherDetail');
}

/// The words for a status's `errorCode` (protocol.md "status", its `errorCode` table, and "Host
/// failure"): null for `""`, a game stopped without an error. A code this launcher does not know
/// is "a game that ended with an error" (protocol.md "Compatibility"). A [ps2] game's `bios` (LRPS2
/// found no BIOS in `pcsx2/bios`) sends the player to the PS2 BIOS row in Settings › Emulators.
String? retroHostErrorKey(String errorCode, {bool ps2 = false}) => switch (errorCode) {
  RetroErrorCode.none => null,
  RetroErrorCode.bios => ps2 ? 'retroHostPs2NoBiosDetail' : 'retroHostBiosDetail',
  RetroErrorCode.disc => 'retroHostDiscDetail',
  RetroErrorCode.core => 'retroHostCoreDetail',
  RetroErrorCode.stalled => 'retroHostStalledDetail',
  RetroErrorCode.didNotStart => 'retroHostDidNotStartDetail',
  RetroErrorCode.frameTooLarge => 'retroHostFrameTooLargeDetail',
  RetroErrorCode.hostExited => 'retroHostExitedDetail',
  RetroErrorCode.hostHung => 'retroHostHungDetail',
  _ => 'retroHostOtherDetail',
};

/// Starts one emulator host for PS1 and PS2 games, with the player's volume: [checked] is the check of a
/// signed release's host ([RetroHostInstall.checked]), whose files the host holds until it exits.
typedef RetroHostOpener = RetroHostSession Function(
  RetroHostInstall install, {
  RetroHostChecked? checked,
  required double volume,
  required bool muted,
});

/// What a PS2 BIOS is, in the player's language: its region, version and year, from its `ROMVER`
/// entry, as LRPS2 describes one.
String ps2BiosShown(Ps2Bios bios) => T.format('retroHostPs2BiosVersion', [
  switch (bios.region) {
    'J' => T.text('retroHostPs2RegionJapan'),
    'A' => T.text('retroHostPs2RegionUsa'),
    'E' => T.text('retroHostPs2RegionEurope'),
    'H' => T.text('retroHostPs2RegionAsia'),
    'C' => T.text('retroHostPs2RegionChina'),
    final other => other,
  },
  bios.versionNumber,
  bios.year ?? '?',
]);

/// The words that say why a file is not a PS2 BIOS.
String ps2BiosRefusalKey(Ps2BiosRefusal reason) => switch (reason) {
  Ps2BiosRefusal.size => 'retroHostPs2BiosWrongSize',
  Ps2BiosRefusal.noDirectory => 'retroHostPs2BiosNoTable',
  Ps2BiosRefusal.noVersion => 'retroHostPs2BiosNoVersion',
  Ps2BiosRefusal.unreadable => 'retroHostPs2BiosUnreadable',
};

/// The menu's sections, in the order its first page lists them. Graphics is on the game's
/// Graphics page instead.
const retroMenuSections = [
  RetroOptionSection.audio,
  RetroOptionSection.controller,
  RetroOptionSection.console,
  RetroOptionSection.advanced,
];

/// The words of a section's row and heading, and of the row's detail.
(String, String) retroMenuSectionKeys(RetroOptionSection section) => switch (section) {
  RetroOptionSection.graphics => ('retroMenuGraphics', 'retroMenuGraphicsDetail'),
  RetroOptionSection.audio => ('retroMenuAudio', 'retroMenuAudioDetail'),
  RetroOptionSection.controller => ('retroMenuController', 'retroMenuControllerDetail'),
  RetroOptionSection.console => ('retroMenuConsole', 'retroMenuConsoleDetail'),
  RetroOptionSection.advanced => ('retroMenuAdvanced', 'retroMenuAdvancedDetail'),
};

/// Settings › Emulators › Run PS1 (or PS2) games in the separate host: those discs played in the
/// launcher's window through the emulator host, with the launcher's controllers and keyboard, and
/// the game's menu on PS.
extension RetroHostPlaying on AppModel {
  /// The host this build runs: in a debug or test build ([RetroHostBuild]) the one
  /// `ANYPS5_RETRO_HOST` names, unchecked; otherwise the signed host downloaded in Settings ›
  /// Emulators, checked before each start. Null when neither is there.
  RetroHostInstall? get retroHostInstall => _uncheckedRetroHost ?? retroHostDownload.store.installed();

  /// What this launcher was compiled as: a debug build, a test build, or a release.
  static final retroHostBuild = RetroHostBuild.of(debug: kDebugMode);

  RetroHostInstall? get _uncheckedRetroHost => RetroHostInstall.locate(
    services.environment ?? Platform.environment,
    build: retroHostBuild,
    system: HostSystem.current,
  );

  /// Whether [platform]'s discs play in the emulator host: PS1 with its setting on and a host found,
  /// PS2 with its own setting on and a host that has LRPS2 beside it. Otherwise they go to the
  /// emulator chosen in Settings › Emulators, as before.
  bool playsInHost(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => preferences.retroHostPs1 && retroHostInstall != null,
    RetroPlatform.ps2 => preferences.retroHostPs2 && retroHostInstall?.ps2Core != null,
    RetroPlatform.ps3 => false,
  };

  /// Whether [platform]'s discs can be played now: in the host, or in the emulator chosen.
  bool retroPlayable(RetroPlatform platform) => playsInHost(platform) || standaloneEmulator(platform) != null;

  /// Whether the game's own screen is in front: a game in the host and no layer over it.
  bool get retroInGame => retroPlay != null && overlay == null;

  /// Whether the game's menu, or its Graphics page, is in front.
  bool get retroMenuShown => overlay == Layer.retroMenu || overlay == Layer.retroGraphics;

  /// Shuts down the host kept for the next game and waits until it has exited, so its files are
  /// no longer held: before the host is replaced by a download.
  Future<void> stopKeptRetroHost() => retroHostKeeper.shutdown();

  void setRetroHostPs1(bool enabled) {
    if (preferences.retroHostPs1 == enabled) return;
    preferences.retroHostPs1 = enabled;
    savePreferences();
    _changed();
  }

  void setRetroHostPs2(bool enabled) {
    if (preferences.retroHostPs2 == enabled) return;
    preferences.retroHostPs2 = enabled;
    savePreferences();
    _changed();
  }

  /// The PS2 BIOS the player chose, while its copy is still in LRPS2's folder; null otherwise.
  Ps2Bios? get retroPs2Bios {
    final bios = preferences.retroHostPs2Bios;
    if (bios == null) return null;
    final copy = File(p.join(Ps2Bios.folderIn(paths.retroSystem), bios.fileName));
    return copy.existsSync() ? bios : null;
  }

  /// Settings › Emulators › PS2 BIOS: asks for the player's own BIOS file, checks it as LRPS2 does
  /// and copies it into LRPS2's folder ([Ps2Bios.install]). A file that is not one is refused,
  /// saying why. Its contents never leave the computer and are never logged.
  Future<void> choosePs2Bios() async {
    final String? selected;
    try {
      selected = await services.pickFile?.call(T.text('retroHostPs2BiosPick'), const []);
    } on PlatformException {
      if (!_disposed) show(T.text('retroEmulatorPickerFailed'));
      return;
    }
    if (selected == null || _disposed) return;
    final Ps2Bios bios;
    try {
      bios = await Ps2Bios.install(File(selected), system: paths.retroSystem);
    } on Ps2BiosRefused catch (refused) {
      if (!_disposed) show(T.text(ps2BiosRefusalKey(refused.reason)));
      return;
    } on FileSystemException {
      if (!_disposed) show(T.text('retroHostPs2BiosCopyFailed'));
      return;
    }
    if (_disposed) return;
    preferences.retroHostPs2Bios = bios;
    savePreferences();
    show(T.format('retroHostPs2BiosReady', [ps2BiosShown(bios)]));
    _changed();
  }

  /// Settings › Emulators' rows for the host: its download, or the notice that this build runs an
  /// unchecked host, and where a host is found, the setting and the BIOS folder; where that host
  /// has LRPS2 beside it, the same two for PS2, whose BIOS the player chooses as a file.
  List<PanelRow> _retroHostSettingsRows() {
    final unchecked = _uncheckedRetroHost != null;
    final download = retroHostDownload.rows(uncheckedHost: unchecked);
    final install = retroHostInstall;
    if (install == null) return download;
    final ps2Bios = retroPs2Bios;
    return [
      ...download,
      if (unchecked)
        PanelRow(
          id: 'retro-host-unchecked',
          title: T.text('retroHostUnchecked'),
          kind: InfoRow(T.text('retroHostUncheckedDetail')),
        ),
      PanelRow(
        id: 'retro-host-ps1',
        title: T.text('retroHostPs1'),
        detail: T.text('retroHostPs1Detail'),
        kind: ToggleRow(preferences.retroHostPs1, setRetroHostPs1),
      ),
      if (preferences.retroHostPs1)
        PanelRow(
          id: 'retro-host-bios',
          title: T.text('retroHostBiosFolder'),
          detail: T.text('retroHostBiosFolderDetail'),
          kind: ActionRow(() {
            Directory(paths.retroSystem).createSync(recursive: true);
            services.openFolder?.call(paths.retroSystem);
          }),
        ),
      if (install.ps2Core != null) ...[
        PanelRow(
          id: 'retro-host-ps2',
          title: T.text('retroHostPs2'),
          detail: T.text('retroHostPs2Detail'),
          kind: ToggleRow(preferences.retroHostPs2, setRetroHostPs2),
        ),
        if (preferences.retroHostPs2)
          PanelRow(
            id: 'retro-host-ps2-bios',
            title: T.text('retroHostPs2Bios'),
            detail: ps2Bios == null
                ? T.text('retroHostPs2BiosChoose')
                : T.format('retroHostPs2BiosChosen', [ps2BiosShown(ps2Bios)]),
            kind: ActionRow(() => unawaited(choosePs2Bios())),
          ),
      ],
    ];
  }

  /// Starts [game]'s PS1 or PS2 disc in a new emulator host and shows it in the launcher's window, and
  /// gives its play once `start` was answered (null when it did not start). An online match's
  /// friend gives the host it opened already ([opened]), the host player's core [options] and a
  /// [saves] folder of the match's own, and starts the game [joining]: muted and not shown until it
  /// plays the match (retro_host_online.dart).
  Future<RetroPlay?> _playInHost(
    Game game,
    RetroDisc disc, {
    RetroHostSession? opened,
    Map<String, String>? options,
    String? saves,
    bool joining = false,
  }) async {
    if (starting != null || running != null || retroPlay != null) return null;
    if (retroHostDownload.installing) {
      show(T.text('retroHostUpdating'));
      return null;
    }
    final install = retroHostInstall;
    if (install == null || (disc.platform == RetroPlatform.ps2 && install.ps2Core == null)) return null;
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null || retroPlay != null) {
      return null;
    }
    if (_disposed) return null;
    if (!File(disc.path).existsSync()) {
      show(T.text('retroDiscMoved'));
      return null;
    }
    try {
      Directory(paths.retroSystem).createSync(recursive: true);
    } on FileSystemException catch (error) {
      _padLog?.call('emulator host: no BIOS folder: $error');
    }

    if (!retroHostDownload.holdForStart()) {
      show(T.text('retroHostUpdating'));
      return null;
    }
    try {
      return await _playInHeldHost(
        game,
        disc,
        install,
        opened: opened,
        options: options,
        saves: saves,
        joining: joining,
      );
    } finally {
      retroHostDownload.releaseStart();
    }
  }

  /// [_playInHost] once the installed host is held for the start, so no download replaces it
  /// between its check and the game's play being set.
  Future<RetroPlay?> _playInHeldHost(
    Game game,
    RetroDisc disc,
    RetroHostInstall install, {
    RetroHostSession? opened,
    Map<String, String>? options,
    String? saves,
    required bool joining,
  }) async {
    final ps2 = disc.platform == RetroPlatform.ps2;
    final core = ps2 ? install.ps2Core! : install.core;
    final volume = preferences.retroHostVolume / 100;
    final muted = joining || preferences.retroHostMuted;
    final recheck = opened == null && install.checked && retroHostKeeper.keeps(program: install.host);
    if (recheck && !await _recheckKeptRetroHost(install)) return null;
    final kept = opened ?? retroHostKeeper.take(program: install.host);
    final RetroHostSession session;
    if (kept != null) {
      session = kept;
      _padLog?.call('emulator host: the kept ${install.host} plays the next game');
    } else {
      RetroHostChecked? checked;
      if (install.checked) {
        try {
          checked = await _checkRetroHost(install);
        } on RetroHostReleaseFailure {
          return null;
        }
        if (_disposed || starting != null || running != null || retroPlay != null) {
          checked?.release();
          return null;
        }
      }
      try {
        session = openRetroHost(install, checked: checked, volume: volume, muted: muted);
      } on Object catch (error) {
        checked?.release();
        _padLog?.call('emulator host: ${install.host} did not start: $error');
        show(T.text('retroHostNotStartedDetail'));
        return null;
      }
    }
    final host = RetroHostGame(session, statusEvery: retroStatusEvery, volume: volume, muted: muted);
    if (kept != null) unawaited(host.setVolume(level: volume, muted: muted));
    final settings = currentSettings(game);
    final keyboard = RetroKeyboard(
      settings.controls ?? const {},
      modifierScale: (settings.tuning ?? const InputTuning()).stickModifierScale / 100,
    );
    final controls =
        RetroHostControls(
            host,
            pads: RetroPadReader(pads: () => [for (final pad in controllers.pads) pad.id], state: controllers.stateOf),
            motors: _PadMotors(this),
            keyboard: () =>
                keyboard.state([for (final key in HardwareKeyboard.instance.physicalKeysPressed) key.usbHidUsage]),
          )
          ..deadzonePercent = preferences.stickDeadzone
          ..vibration = preferences.controllerVibration;
    final menu = RetroGameMenu(host, controls: controls);
    final monitor = RetroFrameMonitor(host);
    final graphics = _retroGraphicsFor(game, host, monitor);
    final play = RetroPlay(
      game: game,
      host: host,
      controls: controls,
      menu: menu,
      graphics: graphics,
      monitor: monitor,
      started: DateTime.now(),
      program: install.host,
      core: core,
    )..joining = joining;
    retroPlay = play;
    host.addListener(_retroChanged);
    sounds.play(Cue.select);
    overlay = null;
    preferences.lastPlayed[game.id] = play.started.toIso8601String();
    together.family.followGame();
    savePreferences();
    _changed();
    _padLog?.call('emulator host: ${install.host} plays ${disc.path}');
    final bios = ps2 ? retroPs2Bios : null;
    await host.start(
      RetroHostStartRequest(
        console: ps2 ? RetroConsole.ps2 : null,
        core: core,
        disc: p.normalize(disc.path),
        system: p.normalize(paths.retroSystem),
        saves: p.normalize(saves ?? (ps2 ? paths.retroPs2Saves : paths.retroSaves)),
        options:
            options ??
            {
              for (final MapEntry(:key, :value) in {
                ...preferences.retroHostOptions,
                ...?preferences.retroHostGraphics[game.id]?.options,
              }.entries)
                if (retroOptionSent(key, ps2: ps2)) key: value,
              if (bios != null) Ps2Bios.option: bios.fileName,
            },
      ),
    );
    return play;
  }

  /// The checks before a start of a signed release's host (protocol.md "Finding and checking the
  /// host"), whose files then stay held until that host has exited; null for the debug host. A
  /// host that fails them is not started: the player is told to download it again, and its row in
  /// Settings › Emulators offers it again.
  Future<RetroHostChecked?> _checkRetroHost(RetroHostInstall install) async {
    if (!install.checked) return null;
    try {
      return await retroHostDownload.store.check();
    } on RetroHostReleaseFailure catch (failure) {
      _padLog?.call('emulator host: ${install.host} failed its check: ${failure.message}');
      retroHostDownload.failedCheck(failure.message);
      if (!_disposed) show(T.text('retroHostCheckFailed'));
      rethrow;
    }
  }

  /// The checks again before a kept signed host loads its next game: its files are still held from
  /// its own start on Windows, but on Linux SwanStation was checked by path and is loaded again for
  /// every game, so it is checked again (a second check, let go at once; the host's own stays held).
  /// The start holds the installed host ([RetroHostDownloadModel.holdForStart]) and the host stays
  /// in [retroHostKeeper] meanwhile; it is taken only once the check passed. One that fails is shut
  /// down through the keeper, which a download waits for. False when no game may start.
  Future<bool> _recheckKeptRetroHost(RetroHostInstall install) async {
    try {
      (await _checkRetroHost(install))?.release();
    } on RetroHostReleaseFailure {
      unawaited(retroHostKeeper.shutdown());
      return false;
    }
    return !_disposed && starting == null && running == null && retroPlay == null;
  }

  /// The game moved on: a game that ended without an error, and was not closed by the player,
  /// goes back to the library; one with an error stays on its error screen.
  void _retroChanged() {
    final play = retroPlay;
    if (play == null || _disposed) return;
    if (play.host.phase == RetroHostGamePhase.ended && !play.closing) {
      if (!play.over) {
        play.endedAt = DateTime.now();
        together.family.followGame();
      }
      if (play.menu.isOpen || retroMenuShown) {
        overlay = null;
        play.menuSection = null;
        unawaited(play.menu.close());
      }
      final problem = play.problem;
      _padLog?.call('emulator host: the game ended (${play.host.endStatus?.error ?? play.host.failure ?? 'no error'})');
      if (problem == null) {
        unawaited(closeRetroGame());
        return;
      }
    }
    _changed();
  }

  /// PS in the game: its menu, the game paused and the controllers kept out of it.
  void openRetroMenu() {
    final play = retroPlay;
    if (play == null || play.closing || !play.host.loaded || retroMenuShown) return;
    play.menuSection = null;
    play.lobby = false;
    open(Layer.retroMenu);
    unawaited(play.menu.open());
  }

  /// Any layer over the game (its menu, a family notice) pauses it and keeps the controllers and
  /// keys out of it, as its menu does, since that layer takes them; the game's own screen back in
  /// front gives both back, so the game is never left paused unseen.
  void _syncRetroMenu() {
    final play = retroPlay;
    if (play == null || play.closing) return;
    if (overlay != null && !play.menu.isOpen && play.host.loaded) unawaited(play.menu.open());
    if (overlay == null && play.menu.isOpen) unawaited(play.menu.close());
  }

  /// Back to the game from its menu.
  void resumeRetroGame() {
    final play = retroPlay;
    if (play == null) return;
    play.menuSection = null;
    play.lobby = false;
    if (retroMenuShown) {
      overlay = null;
      sounds.play(Cue.back);
    }
    unawaited(play.menu.close());
    _changed();
  }

  /// Closes the game: it is stopped (its memory cards written) and forgotten in the host, and the
  /// library comes back. The host is kept for the next game ([RetroHostKeeper]) when it is left
  /// with no game loaded; otherwise, or when the launcher went away meanwhile, it is shut down.
  Future<void> closeRetroGame() async {
    final play = retroPlay;
    if (play == null || play.closing) return;
    unawaited(leaveRetroOnline());
    play.closing = true;
    play.menuSection = null;
    _countRetroPlay(play);
    if (retroMenuShown) overlay = null;
    _changed();
    try {
      if (await play.host.detach()) {
        retroHostKeeper.keep(play.host.session, program: play.program);
        if (_disposed) await retroHostKeeper.shutdown();
        _padLog?.call('emulator host: kept for the next game');
      }
    } finally {
      play.release(_retroChanged);
      if (identical(retroPlay, play)) retroPlay = null;
      if (retroMenuShown) overlay = null;
      if (!_disposed) _changed();
    }
  }

  /// What a command does while a game plays in the host; false when it is not the game's to take.
  /// On the game's own screen the controller is the game's: only PS acts (its menu), and Back from
  /// the mouse opens the menu too. Its error screen goes back to the library.
  bool _retroCommand(Command command) {
    final play = retroPlay;
    if (play == null) return false;
    if (overlay == Layer.retroMenu) {
      if (command == Command.back && (play.menuSection != null || play.lobby)) {
        _leaveRetroMenuSection(play);
        return true;
      }
      if (command == Command.home || command == Command.back || command == Command.options) {
        resumeRetroGame();
        return true;
      }
      return command == Command.previousGame || command == Command.nextGame;
    }
    if (overlay == Layer.retroGraphics) return _retroGraphicsCommand(command);
    if (overlay != null) return false;
    if (play.problem != null) {
      if (command == Command.select || command == Command.back || command == Command.home) {
        sounds.play(Cue.back);
        unawaited(closeRetroGame());
      }
      return true;
    }
    if (play.loading && (command == Command.home || (command == Command.back && !_viaPad))) {
      sounds.play(Cue.back);
      unawaited(closeRetroGame());
      return true;
    }
    if (command == Command.home || (command == Command.back && !_viaPad)) openRetroMenu();
    return true;
  }

  /// The game's menu. Its first page: Resume, the discs of a multi-disc game, Graphics (the
  /// game's Graphics page), a row for each section ([retroMenuSections]) that has rows, and Close
  /// Game. A section's page: its options in the order the host lists them, with Volume and Mute
  /// first in Audio. Back on a section's page goes back to the first page.
  List<PanelCategory> _retroMenuCategories() {
    final play = retroPlay;
    if (play == null) return const [];
    if (play.lobby) {
      return [PanelCategory(id: 'retroMenu-lobby', title: T.text('coopLobbyTitle'), rows: retroLobbyRows(play))];
    }
    final section = play.menuSection;
    if (section != null) {
      return [
        PanelCategory(
          id: 'retroMenu-${section.name}',
          title: T.text(retroMenuSectionKeys(section).$1),
          rows: _retroSectionRows(play, section),
        ),
      ];
    }
    final menu = play.menu;
    return [
      PanelCategory(
        id: 'retroMenu',
        title: play.game.name,
        rows: [
          PanelRow(id: 'resume', title: T.text('quickResume'), kind: ActionRow(resumeRetroGame)),
          retroLobbyRow(play),
          for (final disc in menu.rows.whereType<RetroDiscRow>())
            PanelRow(
              id: 'disc-${disc.index}',
              title: disc.label,
              detail: disc.inserted
                  ? T.text(menu.discChangeFailed ? 'retroMenuDiscFailedDetail' : 'retroMenuDiscInsertedDetail')
                  : (disc.enabled ? null : T.text('retroMenuDiscChangingDetail')),
              kind: ActionRow(() => unawaited(menu.chooseDisc(disc))),
            ),
          if (play.graphics.available)
            PanelRow(
              id: 'graphics',
              title: T.text(retroMenuSectionKeys(RetroOptionSection.graphics).$1),
              detail: T.text(retroMenuSectionKeys(RetroOptionSection.graphics).$2),
              kind: ActionRow(openRetroGraphics),
            ),
          for (final section in retroMenuSections)
            if (_retroSectionRows(play, section).isNotEmpty)
              PanelRow(
                id: 'section-${section.name}',
                title: T.text(retroMenuSectionKeys(section).$1),
                detail: T.text(retroMenuSectionKeys(section).$2),
                kind: ActionRow(() => _openRetroMenuSection(play, section)),
              ),
          PanelRow(
            id: 'closeGame',
            title: T.text('quickCloseGame'),
            kind: ActionRow(() => unawaited(closeRetroGame()), destructive: true),
          ),
        ],
      ),
    ];
  }

  /// The rows of one section's page: Volume and Mute first in Audio, then the section's options.
  /// An option that takes effect only when the game starts again says so; a chosen value not yet
  /// in effect says when it will be.
  List<PanelRow> _retroSectionRows(RetroPlay play, RetroOptionSection section) {
    final menu = play.menu;
    return [
      if (section == RetroOptionSection.audio) ...[
        PanelRow(
          id: 'volume',
          title: T.text('retroMenuVolume'),
          kind: StepperRow(
            value: play.joining ? preferences.retroHostVolume : (play.host.volume * 100).round(),
            min: 0,
            max: 100,
            step: 10,
            slider: true,
            format: AppModel._percent,
            set: (value) => unawaited(_setRetroVolume(value)),
          ),
        ),
        PanelRow(
          id: 'mute',
          title: T.text('retroMenuMute'),
          kind: ToggleRow(
            play.joining ? preferences.retroHostMuted : play.host.muted,
            (muted) => unawaited(_setRetroMuted(muted)),
          ),
        ),
      ],
      for (final option in menu.optionsIn(section))
        PanelRow(
          id: 'option-${option.key}',
          title: option.title,
          detail: option.pending
              ? T.text(option.restartNeeded ? 'retroMenuOptionRestartDetail' : 'retroMenuOptionPendingDetail')
              : (option.restartNeeded ? T.text('retroMenuOptionRestartOnlyDetail') : null),
          kind: ChoiceRow(
            option.option.labels,
            option.option.selected,
            (index) => unawaited(_chooseRetroOption(option.option, index)),
          ),
        ),
    ];
  }

  void _openRetroMenuSection(RetroPlay play, RetroOptionSection section) {
    if (!identical(retroPlay, play) || overlay != Layer.retroMenu) return;
    play.menuSection = section;
    panelRow = 0;
    sounds.play(Cue.select);
    _changed();
  }

  /// Back from a section's page, or the lobby, to the first page, on its row.
  void _leaveRetroMenuSection(RetroPlay play) {
    final section = play.menuSection;
    final lobby = play.lobby;
    play.menuSection = null;
    play.lobby = false;
    final rows = _retroMenuCategories().single.rows;
    final index = rows.indexWhere((row) => row.id == (lobby ? 'players' : 'section-${section?.name}'));
    panelRow = index < 0 ? 0 : index;
    sounds.play(Cue.back);
    _changed();
  }

  /// A core option chosen in the menu: sent to the game, and kept for every later one once the
  /// host took it.
  Future<void> _chooseRetroOption(RetroOption option, int index) async {
    final play = retroPlay;
    if (play == null || index == option.selected) return;
    final taken = await play.menu.stepOption(option.key, index - option.selected);
    if (!taken || _disposed) return;
    preferences.retroHostOptions[option.key] = option.values[index];
    savePreferences();
    _changed();
  }

  Future<void> _setRetroVolume(int percent) async {
    final play = retroPlay;
    if (play == null) return;
    if (play.joining) return _keepJoiningVolume(volume: percent);
    final steps = ((percent - play.host.volume * 100) / 10).round();
    if (steps == 0) return;
    await play.menu.stepVolume(steps);
    _keepRetroVolume(play);
  }

  Future<void> _setRetroMuted(bool muted) async {
    final play = retroPlay;
    if (play == null) return;
    if (play.joining) return _keepJoiningVolume(muted: muted);
    if (play.host.muted == muted) return;
    await play.menu.toggleMute();
    _keepRetroVolume(play);
  }

  /// A game joining a match stays muted (RetroPlay.joining): the volume and mute the player
  /// chooses meanwhile are kept, and given to the game once it shows.
  void _keepJoiningVolume({int? volume, bool? muted}) {
    if (_disposed) return;
    preferences
      ..retroHostVolume = volume ?? preferences.retroHostVolume
      ..retroHostMuted = muted ?? preferences.retroHostMuted;
    savePreferences();
    _changed();
  }

  void _keepRetroVolume(RetroPlay play) {
    if (_disposed) return;
    preferences
      ..retroHostVolume = (play.host.volume * 100).round()
      ..retroHostMuted = play.host.muted;
    savePreferences();
    _changed();
  }

  /// The kept host is shut down once the player has left the host's games: the game selected is not
  /// a disc that plays in the host, or another game starts or runs.
  void _letUnwantedRetroHostGo() {
    if (!retroHostKeeper.holding || retroPlay != null) return;
    final platform = selectedGame?.retro?.platform;
    final wanted = running == null && starting == null && platform != null && playsInHost(platform);
    if (!wanted) unawaited(retroHostKeeper.shutdown());
  }

  /// The launcher goes: the game's controllers and menu let go, and its host is shut down.
  void _disposeRetroPlay() {
    final play = retroPlay;
    if (play == null) return;
    _countRetroPlay(play);
    retroPlay = null;
    play.release(_retroChanged);
  }

  /// The game is over: the family play-time watcher lets it go, and its time from start to
  /// [RetroPlay.endedAt] is counted, once, before anything waits on the host, so the launcher
  /// going away mid-close loses none of it.
  void _countRetroPlay(RetroPlay play) {
    play.endedAt ??= DateTime.now();
    if (play.counted) return;
    play.counted = true;
    together.family.followGame();
    together.family.played(play.started, play.endedAt!, reported: false);
  }
}
