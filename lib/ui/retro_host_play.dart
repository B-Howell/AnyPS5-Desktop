part of 'app_model.dart';

/// A PS1 game playing in the launcher's window through the emulator host: the game, its
/// controllers and its in-game menu.
class RetroPlay {
  RetroPlay({
    required this.game,
    required this.host,
    required this.controls,
    required this.menu,
    required this.started,
  });

  final Game game;
  final RetroHostGame host;
  final RetroHostControls controls;
  final RetroGameMenu menu;
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

  bool _released = false;

  /// Lets go of the controllers, the menu and the host, once, whoever asks first: Close Game, or
  /// the launcher going away while Close Game still waits on the host.
  void release(VoidCallback listener) {
    if (_released) return;
    _released = true;
    host.removeListener(listener);
    controls.dispose();
    menu.dispose();
    host.dispose();
  }

  /// The game is starting or loading: the loading screen shows.
  bool get loading => host.phase == RetroHostGamePhase.starting || host.phase == RetroHostGamePhase.loading;

  /// Why the game stopped, as the key of the words to show the player; null while it plays, and
  /// for a game that ended without an error or that the player closed.
  String? get problem => closing ? null : retroHostProblem(host);
}

/// Why [host]'s game stopped, as the key of the words to show the player; null while it plays or
/// after a clean end. A host that speaks another protocol version "needs updating" (protocol.md
/// "Host failure"), and one that never greeted the launcher could not be started. A game that
/// could not be followed (a refused `status` or `pause`) keeps its last status, which says no
/// error: its [RetroHostGame.failure] makes it one without a known cause.
String? retroHostProblem(RetroHostGame host) {
  if (host.phase != RetroHostGamePhase.ended) return null;
  if (host.hostEnd == RetroHostEnd.unsupported) return 'retroHostOutdatedDetail';
  final status = host.endStatus;
  if (status == null) return host.failure == null ? null : 'retroHostNotStartedDetail';
  return retroHostErrorKey(status.errorCode) ?? (host.failure == null ? null : 'retroHostOtherDetail');
}

/// The words for a status's `errorCode` (protocol.md "status", its `errorCode` table, and "Host
/// failure"): null for `""`, a game stopped without an error. A code this launcher does not know
/// is "a game that ended with an error" (protocol.md "Compatibility").
String? retroHostErrorKey(String errorCode) => switch (errorCode) {
  RetroErrorCode.none => null,
  RetroErrorCode.bios => 'retroHostBiosDetail',
  RetroErrorCode.disc => 'retroHostDiscDetail',
  RetroErrorCode.core => 'retroHostCoreDetail',
  RetroErrorCode.stalled => 'retroHostStalledDetail',
  RetroErrorCode.didNotStart => 'retroHostDidNotStartDetail',
  RetroErrorCode.frameTooLarge => 'retroHostFrameTooLargeDetail',
  RetroErrorCode.hostExited => 'retroHostExitedDetail',
  RetroErrorCode.hostHung => 'retroHostHungDetail',
  _ => 'retroHostOtherDetail',
};

/// Opens one emulator host for a PS1 game, with the player's volume.
typedef RetroHostOpener = RetroHostGame Function(
  RetroHostInstall install, {
  required double volume,
  required bool muted,
});

/// Settings › Emulators › Run PS1 games in the separate host: PS1 discs played in the launcher's
/// window through the emulator host, with the launcher's controllers and keyboard, and the game's
/// menu on PS.
extension RetroHostPlaying on AppModel {
  /// The host this build may run, where one is found (only debug builds, for now).
  RetroHostInstall? get retroHostInstall => RetroHostInstall.locate(
    services.environment ?? Platform.environment,
    debug: kDebugMode,
    system: HostSystem.current,
  );

  /// Whether [platform]'s discs play in the emulator host: PS1, with the setting on and a host
  /// found. Otherwise they go to the emulator chosen in Settings › Emulators, as before.
  bool playsInHost(RetroPlatform platform) =>
      platform == RetroPlatform.ps1 && preferences.retroHostPs1 && retroHostInstall != null;

  /// Whether [platform]'s discs can be played now: in the host, or in the emulator chosen.
  bool retroPlayable(RetroPlatform platform) => playsInHost(platform) || standaloneEmulator(platform) != null;

  /// Whether the game's own screen is in front: a game in the host and no layer over it.
  bool get retroInGame => retroPlay != null && overlay == null;

  void setRetroHostPs1(bool enabled) {
    if (preferences.retroHostPs1 == enabled) return;
    preferences.retroHostPs1 = enabled;
    savePreferences();
    _changed();
  }

  /// Settings › Emulators' rows for the host, shown where a host is found.
  List<PanelRow> _retroHostSettingsRows() {
    if (retroHostInstall == null) return const [];
    return [
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
    ];
  }

  /// Starts [game]'s PS1 disc in a new emulator host and shows it in the launcher's window.
  Future<void> _playInHost(Game game, RetroDisc disc) async {
    if (starting != null || running != null || retroPlay != null) return;
    final install = retroHostInstall;
    if (install == null) return;
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null || retroPlay != null) {
      return;
    }
    if (_disposed) return;
    if (!File(disc.path).existsSync()) {
      show(T.text('retroDiscMoved'));
      return;
    }
    try {
      Directory(paths.retroSystem).createSync(recursive: true);
    } on FileSystemException catch (error) {
      _padLog?.call('emulator host: no BIOS folder: $error');
    }

    final RetroHostGame host;
    try {
      host = openRetroHost(install, volume: preferences.retroHostVolume / 100, muted: preferences.retroHostMuted);
    } on Object catch (error) {
      _padLog?.call('emulator host: ${install.host} did not start: $error');
      show(T.text('retroHostNotStartedDetail'));
      return;
    }
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
    final play = RetroPlay(game: game, host: host, controls: controls, menu: menu, started: DateTime.now());
    retroPlay = play;
    host.addListener(_retroChanged);
    sounds.play(Cue.select);
    overlay = null;
    preferences.lastPlayed[game.id] = play.started.toIso8601String();
    together.family.followGame();
    savePreferences();
    _changed();
    _padLog?.call('emulator host: ${install.host} plays ${disc.path}');
    await host.start(
      RetroHostStartRequest(
        core: install.core,
        disc: p.normalize(disc.path),
        system: p.normalize(paths.retroSystem),
        saves: p.normalize(paths.retroSaves),
        options: Map.of(preferences.retroHostOptions),
      ),
    );
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
      if (play.menu.isOpen || overlay == Layer.retroMenu) {
        overlay = null;
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
    if (play == null || play.closing || !play.host.loaded || overlay == Layer.retroMenu) return;
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
    if (overlay == Layer.retroMenu) {
      overlay = null;
      sounds.play(Cue.back);
    }
    unawaited(play.menu.close());
    _changed();
  }

  /// Closes the game: it is stopped (its memory cards written), the host shut down, and the
  /// library comes back.
  Future<void> closeRetroGame() async {
    final play = retroPlay;
    if (play == null || play.closing) return;
    play.closing = true;
    _countRetroPlay(play);
    if (overlay == Layer.retroMenu) overlay = null;
    _changed();
    try {
      await play.host.stop();
    } finally {
      await play.host.shutdown();
      play.release(_retroChanged);
      if (identical(retroPlay, play)) retroPlay = null;
      if (overlay == Layer.retroMenu) overlay = null;
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
      if (command == Command.home || command == Command.back || command == Command.options) {
        resumeRetroGame();
        return true;
      }
      return command == Command.previousGame || command == Command.nextGame;
    }
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

  /// The game's menu: Resume, the discs of a multi-disc game, the core's options, the volume,
  /// Close Game.
  List<PanelCategory> _retroMenuCategories() {
    final play = retroPlay;
    if (play == null) return const [];
    final menu = play.menu;
    final rows = menu.rows;
    final volume = rows.whereType<RetroVolumeRow>().first;
    return [
      PanelCategory(
        id: 'retroMenu',
        title: play.game.name,
        rows: [
          PanelRow(id: 'resume', title: T.text('quickResume'), kind: ActionRow(resumeRetroGame)),
          for (final disc in rows.whereType<RetroDiscRow>())
            PanelRow(
              id: 'disc-${disc.index}',
              title: disc.label,
              detail: disc.inserted
                  ? T.text(menu.discChangeFailed ? 'retroMenuDiscFailedDetail' : 'retroMenuDiscInsertedDetail')
                  : (disc.enabled ? null : T.text('retroMenuDiscChangingDetail')),
              kind: ActionRow(() => unawaited(menu.chooseDisc(disc))),
            ),
          for (final option in rows.whereType<RetroOptionRow>())
            PanelRow(
              id: 'option-${option.key}',
              title: option.title,
              detail: option.pending
                  ? T.text(option.restartNeeded ? 'retroMenuOptionRestartDetail' : 'retroMenuOptionPendingDetail')
                  : null,
              kind: ChoiceRow(
                option.option.labels,
                option.option.selected,
                (index) => unawaited(_chooseRetroOption(option.option, index)),
              ),
            ),
          PanelRow(
            id: 'volume',
            title: T.text('retroMenuVolume'),
            kind: StepperRow(
              value: (volume.level * 100).round(),
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
            kind: ToggleRow(volume.muted, (muted) => unawaited(_setRetroMuted(muted))),
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
    final steps = ((percent - play.host.volume * 100) / 10).round();
    if (steps == 0) return;
    await play.menu.stepVolume(steps);
    _keepRetroVolume(play);
  }

  Future<void> _setRetroMuted(bool muted) async {
    final play = retroPlay;
    if (play == null || play.host.muted == muted) return;
    await play.menu.toggleMute();
    _keepRetroVolume(play);
  }

  void _keepRetroVolume(RetroPlay play) {
    if (_disposed) return;
    preferences
      ..retroHostVolume = (play.host.volume * 100).round()
      ..retroHostMuted = play.host.muted;
    savePreferences();
    _changed();
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
