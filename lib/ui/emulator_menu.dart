part of 'app_model.dart';

enum _EmulatorGroup {
  setup('Setup'),
  optimize('Optimize'),
  graphics('Graphics'),
  performance('Performance & Compatibility'),
  controls('Controls'),
  audio('Audio'),
  io('I/O'),
  storage('Saves & Storage'),
  advanced('Advanced');

  const _EmulatorGroup(this.label);

  final String label;

  static _EmulatorGroup forSection(String section) {
    final key = section.toLowerCase();
    if (key == 'optimize') return optimize;
    if (key.startsWith('graphics-') ||
        key == 'graphics' ||
        const {'gpu', 'display', 'emucore/gs', 'texturereplacements', 'framerate', 'borderoverlay'}.contains(key)) {
      return graphics;
    }
    if (const {'console', 'cpu', 'cdrom', 'hacks', 'emucore'}.contains(key) ||
        key.startsWith('emucore/cpu') ||
        key == 'emucore/gamefixes' ||
        key == 'emucore/speedhacks') {
      return performance;
    }
    if (key.startsWith('pad') ||
        key.startsWith('usb') ||
        const {'controllerports', 'inputsources', 'hotkeys'}.contains(key)) {
      return controls;
    }
    if (key == 'io') return io;
    if (key == 'scheduling') return performance;
    if (key == 'audio' || key.startsWith('spu2/output')) return audio;
    if (const {'memorycards', 'folders', 'filenames', 'dev9/hdd'}.contains(key)) return storage;
    return advanced;
  }
}

class _EmulatorMenu {
  _EmulatorMenu(this.app);

  static const _pageSize = 24;

  final AppModel app;
  PanelSpot? _origin;
  String? _originGameId;
  final _parents = <({PanelCategory Function() page, String? row})>[];
  PanelCategory Function()? _page;

  final _advancedDraft = <String, int>{};
  bool _applyingAdvanced = false;

  void openAdvanced(PanelCategory Function() page) {
    _advancedDraft.clear();
    openPage(page);
  }

  ChoiceRow advancedChoice(String key, List<String> labels, int current) =>
      ChoiceRow(labels, _advancedDraft[key] ?? current, (index) {
        if (_applyingAdvanced) return;
        if (index == current) {
          _advancedDraft.remove(key);
        } else {
          _advancedDraft[key] = index;
        }
        app._changed();
      });

  List<PanelRow> advancedActions(EmbeddedRetroGame session) => [
    PanelRow(
      id: 'embedded-apply-advanced',
      title: 'Apply changes',
      pinToBottom: true,
      kind: _advancedDraft.isEmpty || _applyingAdvanced
          ? InfoRow(_applyingAdvanced ? 'Applying…' : 'Choose a setting to change.')
          : ActionRow(() => unawaited(_applyAdvanced(session))),
    ),
    if (_advancedDraft.isNotEmpty && !_applyingAdvanced)
      PanelRow(
        id: 'embedded-discard-advanced',
        title: 'Discard changes',
        kind: ActionRow(() {
          _advancedDraft.clear();
          app._changed();
        }),
      ),
  ];

  Future<void> _applyAdvanced(EmbeddedRetroGame session) async {
    if (_applyingAdvanced || app.embeddedGame != session) return;
    _applyingAdvanced = true;
    app._changed();
    try {
      for (final entry in _advancedDraft.entries.toList()) {
        if (app.embeddedGame != session) break;
        final key = entry.key;
        final index = entry.value;
        if (key == 'embedded-filter' || key == 'embedded-framing') {
          if (key == 'embedded-filter') {
            session.filter = index;
          } else {
            session.framing = index;
          }
          if (app.running case (final game, _)) app._clearRetroAutoOptimize(game.id);
          _advancedDraft.remove(key);
          continue;
        }
        final option = session.options[key];
        if (option == null || index >= option.values.length || !await session.setOption(key, option.values[index])) {
          app.show('A graphics setting could not be applied. Review the remaining changes.');
          break;
        }
        _advancedDraft.remove(key);
      }
      if (_advancedDraft.isEmpty) app.show('Graphics changes applied.');
    } finally {
      _applyingAdvanced = false;
      if (!app._disposed) app._changed();
    }
  }

  PanelCategory get entry => PanelCategory(
    id: 'emulators',
    title: 'Emulators',
    rows: [
      for (final platform in RetroPlatform.values)
        PanelRow(
          id: 'emulators-${platform.name}',
          title: ManagedRetro.platformName(platform),
          detail: switch (platform) {
            RetroPlatform.ps1 => app.retroSettings.program(platform) == null ? 'SwanStation' : platform.emulator,
            RetroPlatform.ps2 => app.retroSettings.program(platform) == null ? 'LRPS2' : platform.emulator,
            RetroPlatform.ps3 => 'RPCS3',
          },
          kind: ActionRow(() => openConsole(platform)),
        ),
      PanelRow(
        id: 'emulators-show-folders',
        title: 'Show as folders',
        detail: 'Group PS1, PS2 and PS3 games into console folders on Home.',
        kind: ToggleRow(app.preferences.showRetroFolders, app.setShowRetroFolders, checkbox: true),
      ),
    ],
  );

  bool get fromGraphics => _origin?.layer == Layer.retroGraphics;
  bool get fromQuickMenu => _origin?.layer == Layer.quickMenu;

  List<PanelCategory> get categories => [if (_page case final page?) page()];

  Iterable<PanelCategory> searchSections() sync* {
    for (final platform in RetroPlatform.values) {
      for (final group in _groups(platform).entries) {
        for (final section in group.value) {
          final title = 'Emulators › ${_consoleTitle(platform, null)} › ${group.key.label} › ${_sectionTitle(section)}';
          yield PanelCategory(
            id: section.id,
            title: title,
            rows: [
              for (final (index, row) in section.rows.indexed)
                if (row.focusable)
                  PanelRow(
                    id: row.id,
                    title: row.title,
                    detail: row.detail,
                    kind: ActionRow(() => _openSearchResult(platform, group.key, section, index, row.id)),
                  ),
            ],
          );
        }
      }
    }
  }

  void _openSearchResult(RetroPlatform platform, _EmulatorGroup group, PanelCategory section, int index, String row) {
    final sections = _groups(platform)[group] ?? const [];
    _origin = (layer: Layer.settings, category: 'emulators', row: 'emulators-${platform.name}');
    _originGameId = null;
    _parents.clear();
    _parents.add((page: () => _console(platform, null), row: 'emulator-group-${group.name}'));
    _page = () => _group(platform, null, group);
    if (sections.length != 1 || section.rows.length > _pageSize) {
      _parents.add((page: _page!, row: section.id));
      _page = () => _section(platform, null, group, section.id);
    }
    if (section.rows.length > _pageSize) {
      final first = index ~/ _pageSize * _pageSize;
      _parents.add((page: _page!, row: '${section.id}-$first'));
      _page = () => _section(platform, null, group, section.id, page: first);
    }
    app.returnTo((layer: Layer.emulatorMenu, category: _page!().id, row: row));
  }

  void openConsole(RetroPlatform platform, {Game? game}) {
    openPage(() => _console(platform, game));
  }

  void openPage(PanelCategory Function() page) {
    _origin = app.spot;
    _originGameId = app.overlay == Layer.gameSettings ? app.selectedGame?.id : null;
    _parents.clear();
    _page = page;
    app.open(Layer.emulatorMenu);
  }

  void _push(PanelCategory Function() page) {
    _parents.add((page: _page!, row: app.spot?.row));
    _page = page;
    app.open(Layer.emulatorMenu);
  }

  bool back() {
    if (_parents.isEmpty) {
      final origin = _origin;
      final gameId = _originGameId;
      _origin = null;
      _originGameId = null;
      _page = null;
      if (origin == null) return false;
      if (origin.layer == Layer.quickMenu && app.running == null && app.starting == null) return false;
      if (origin.layer == Layer.friendOptions && app.together.chosen == null) {
        app.open(Layer.friends, cue: Cue.back);
        return true;
      }
      if (gameId != null) {
        final index = app.games.indexWhere((game) => game.id == gameId);
        if (index < 0) return false;
        app.selected = index;
      }
      app.returnTo(origin);
      return true;
    }
    final parent = _parents.removeLast();
    _page = parent.page;
    app.returnTo((layer: Layer.emulatorMenu, category: parent.page().id, row: parent.row));
    return true;
  }

  Map<_EmulatorGroup, List<PanelCategory>> _groups(RetroPlatform platform, {Game? game}) {
    final prefix = 'retro-${platform.name}';
    final groups = <_EmulatorGroup, List<PanelCategory>>{};
    for (final section in app.retroSettings.categories(platform, game: game)) {
      if (section.id == prefix) {
        final setup = [
          ...section.rows.where((row) => row.id != '$prefix-add'),
          if (platform == RetroPlatform.ps2 && game == null && app.together.ps2LanSetupEnabled)
            PanelRow(
              id: 'ps2-lan-setup',
              title: T.text('ps2LanSetupTitle'),
              detail: T.text('ps2LanSetupDetail'),
              kind: ActionRow(() => _push(_ps2LanSetupPage)),
            ),
        ];
        final custom = section.rows.where((row) => row.id == '$prefix-add').toList();
        if (setup.isNotEmpty) {
          (groups[_EmulatorGroup.setup] ??= []).add(PanelCategory(id: section.id, title: 'Setup', rows: setup));
        }
        if (custom.isNotEmpty) {
          (groups[_EmulatorGroup.advanced] ??= []).add(
            PanelCategory(id: '$prefix-custom', title: 'Add emulator setting', rows: custom),
          );
        }
        continue;
      }
      final source = section.id.substring(prefix.length + 1);
      (groups[_EmulatorGroup.forSection(source)] ??= []).add(section);
    }
    return groups;
  }

  PanelCategory _ps2LanSetupPage({VoidCallback? onReady}) {
    final game = app._ps2LanSetupTitle;
    final available = app.together.ps2LanSetupAvailable;
    final installed = app.ps2LanCoreInstalled;
    final hasBios = app.ps2LanBiosPath != null;
    final blocker = !available
        ? 'ps2LanBusy'
        : !installed
        ? 'ps2LanCore'
        : !hasBios
        ? 'ps2LanBios'
        : null;
    return PanelCategory(
      id: 'ps2-lan-network-setup',
      title: T.text('ps2LanSetupTitle'),
      rows: [
        if (!installed)
          PanelRow(
            id: 'ps2-lan-setup-install',
            title: T.text('ps2LanPackageInstall'),
            detail: T.text(app._ps2LanPackageAvailable ? 'ps2LanBundledPackageDetail' : 'ps2LanPackageDetail'),
            kind: available
                ? ActionRow(() => unawaited(app._preparePs2LanMedia(bios: false)))
                : InfoRow(T.text('ps2LanBusy')),
          ),
        if (!hasBios)
          PanelRow(
            id: 'ps2-lan-setup-bios',
            title: T.text('ps2LanBiosImport'),
            kind: available
                ? ActionRow(() => unawaited(app._preparePs2LanMedia(bios: true)))
                : InfoRow(T.text('ps2LanBusy')),
          ),
        if (game == null)
          PanelRow(
            id: 'ps2-lan-setup-media',
            title: T.text('ps2LanSetupMediaTitle'),
            detail: T.text('ps2LanSetupMedia'),
            kind: const InfoRow(''),
          )
        else
          PanelRow(
            id: 'ps2-lan-setup-launch',
            title: T.format('ps2LanSetupOpen', [game.name]),
            detail: T.text('ps2LanSetupInstructions'),
            kind: blocker == null ? ActionRow(() => unawaited(app._configurePs2Lan(game))) : InfoRow(T.text(blocker)),
          ),
        if (onReady != null)
          PanelRow(
            id: 'ps2-lan-setup-continue',
            title: T.text('ps2LanSetupContinue'),
            detail: T.text('ps2LanUseGameMenu'),
            kind: blocker == null ? ActionRow(onReady) : InfoRow(T.text(blocker)),
          ),
      ],
    );
  }

  String _consoleTitle(RetroPlatform platform, Game? game) {
    final name = ManagedRetro.platformName(platform);
    return game == null ? name : '$name › ${game.name}';
  }

  PanelCategory _console(RetroPlatform platform, Game? game) {
    final groups = _groups(platform, game: game);
    final title = _consoleTitle(platform, game);
    return PanelCategory(
      id: 'emulator-console',
      title: title,
      rows: [
        for (final group in _EmulatorGroup.values)
          if (groups.containsKey(group) || (group == _EmulatorGroup.optimize && game != null))
            PanelRow(
              id: 'emulator-group-${group.name}',
              title: group.label,
              detail: game == null || group == _EmulatorGroup.optimize
                  ? null
                  : platform == RetroPlatform.ps3 && group != _EmulatorGroup.setup
                  ? 'Settings for this game'
                  : 'Shared console settings',
              kind: ActionRow(() => _push(() => _group(platform, game, group))),
            ),
      ],
    );
  }

  void openChild(PanelCategory Function() page) {
    if (app.overlay == Layer.emulatorMenu && _page != null) {
      _push(page);
    } else {
      openPage(page);
    }
  }

  PanelRow autoOptimizeLink(Game game, [EmbeddedRetroGame? session]) => PanelRow(
    id: 'emulator-auto-optimize',
    title: 'Auto Optimize${app.preferences.retroAutoOptimized.contains(game.id) ? ' ✓' : ''}',
    detail: session == null
        ? 'Detect your PC and review settings for the next launch.'
        : 'Review recommended settings for this game and your PC.',
    kind: session != null && (session.isPs2Lan || session.isNetplay || session.isPs3Online)
        ? const InfoRow('Available outside an online session.')
        : ActionRow(() {
            final panel = RetroAutoOptimizePanel(
              gameName: game.name,
              platform: game.retro!.platform,
              readHardware: app.services.retroHardware,
              prepare: (hardware) => session == null
                  ? app._prepareLaunchOptimization(game, hardware)
                  : liveRetroOptimizePlan(session, game.retro!, hardware),
              refresh: () {
                if (!app._disposed) app._changed();
              },
            );
            openChild(panel.build);
            unawaited(panel.detect());
          }),
  );

  PanelRow tuningLink(EmbeddedRetroGame session) => PanelRow(
    id: 'emulator-tune-game',
    title: 'Compare gameplay performance',
    detail: 'Compare two samples of the same gameplay segment.',
    kind: ActionRow(() => openChild(() => _tuningPage(session))),
  );

  PanelCategory _tuningPage(EmbeddedRetroGame session) {
    final playing = app.running;
    if (playing == null || playing.$2 != session) {
      return const PanelCategory(
        id: 'emulator-tune-game',
        title: 'Tune This Game',
        rows: [
          PanelRow(id: 'tuning-closed', title: 'Game closed', kind: InfoRow('Start the game to record a sample.')),
        ],
      );
    }
    final game = playing.$1;
    if (app._retroRestartTrials.isTrial(session)) return app._retroRestartTrials.page(game, session);
    return retroTuningPanel(
      session,
      resume: () {
        if (app.embeddedGame == session && app.spot?.category == 'emulator-tune-game') app.resumeGame();
      },
      openRestartTrials: session.isPs2Lan || session.isPs3Online
          ? null
          : () => _push(() => app._retroRestartTrials.page(game, session)),
    );
  }

  PanelCategory _group(RetroPlatform platform, Game? game, _EmulatorGroup group) {
    final title = '${_consoleTitle(platform, game)} › ${group.label}';
    final sections = _groups(platform, game: game)[group] ?? const [];
    if (group == _EmulatorGroup.optimize && game != null) {
      final session = app.running?.$1.id == game.id ? app.embeddedGame : null;
      return PanelCategory(
        id: 'emulator-group',
        title: title,
        rows: [
          if (session != null || app._canOptimizeBeforeLaunch(game))
            autoOptimizeLink(game, session)
          else
            const PanelRow(
              id: 'emulator-auto-optimize',
              title: 'Auto Optimize',
              kind: InfoRow('Start the game and open Graphics from the Quick Menu.'),
            ),
          for (final section in sections)
            PanelRow(
              id: section.id,
              title: 'Optimize standalone emulator',
              detail: 'Shared console settings',
              kind: ActionRow(() => _push(() => _section(platform, game, group, section.id))),
            ),
        ],
      );
    }
    if (sections.length == 1 && sections.single.rows.length <= _pageSize) {
      return PanelCategory(id: 'emulator-group', title: title, rows: sections.single.rows);
    }
    return PanelCategory(
      id: 'emulator-group',
      title: title,
      rows: [
        for (final section in sections)
          PanelRow(
            id: section.id,
            title: _sectionTitle(section),
            kind: ActionRow(() => _push(() => _section(platform, game, group, section.id))),
          ),
      ],
    );
  }

  String _sectionTitle(PanelCategory section) => section.title.split(' · ').last;

  PanelCategory _section(RetroPlatform platform, Game? game, _EmulatorGroup group, String id, {int? page}) {
    final section = _groups(platform, game: game)[group]?.where((section) => section.id == id).firstOrNull;
    final rows = section?.rows ?? const <PanelRow>[];
    final title =
        '${_consoleTitle(platform, game)} › ${group.label} › ${section == null ? '' : _sectionTitle(section)}';
    return PanelCategory(
      id: 'emulator-section',
      title: title,
      rows: rows.length <= _pageSize
          ? rows
          : page != null
          ? rows.skip(page).take(_pageSize).toList()
          : [for (var i = 0; i < rows.length; i += _pageSize) _rangeRow(platform, game, group, id, rows, i, _pageSize)],
    );
  }

  PanelRow _rangeRow(
    RetroPlatform platform,
    Game? game,
    _EmulatorGroup group,
    String id,
    List<PanelRow> rows,
    int first,
    int count,
  ) {
    final last = (first + count - 1).clamp(0, rows.length - 1);
    return PanelRow(
      id: '$id-$first',
      title: '${rows[first].title} – ${rows[last].title}',
      kind: ActionRow(() => _push(() => _section(platform, game, group, id, page: first))),
    );
  }
}
