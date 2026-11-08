part of 'app_model.dart';

enum _EmulatorGroup {
  setup('retroMenuSetup'),
  optimize('retroMenuOptimize'),
  graphics('retroPs3Graphics'),
  performance('retroMenuPerformance'),
  controls('retroMenuControls'),
  audio('retroPs3Audio'),
  io('retroMenuIo'),
  storage('retroMenuStorage'),
  advanced('retroMenuAdvanced');

  const _EmulatorGroup(this.textKey);

  final String textKey;

  String get label => T.text(textKey);

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

  PanelCategory get entry => PanelCategory(
    id: 'emulators',
    title: T.text('retroEmulators'),
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
        title: T.text('retroShowFolders'),
        detail: T.text('retroShowFoldersDetail'),
        kind: ToggleRow(app.preferences.showRetroFolders, app.setShowRetroFolders, checkbox: true),
      ),
    ],
  );

  bool get fromGraphics => _origin?.layer == Layer.retroGraphics;

  List<PanelCategory> get categories => [if (_page case final page?) page()];

  Iterable<PanelCategory> searchSections() sync* {
    for (final platform in RetroPlatform.values) {
      for (final group in _groups(platform).entries) {
        for (final section in group.value) {
          final title =
              '${T.text('retroEmulators')} › ${_consoleTitle(platform, null)} › ${group.key.label} › ${_sectionTitle(section)}';
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
        final setup = section.rows.where((row) => row.id != '$prefix-add').toList();
        final custom = section.rows.where((row) => row.id == '$prefix-add').toList();
        if (setup.isNotEmpty) {
          (groups[_EmulatorGroup.setup] ??= []).add(
            PanelCategory(id: section.id, title: T.text('retroMenuSetup'), rows: setup),
          );
        }
        if (custom.isNotEmpty) {
          (groups[_EmulatorGroup.advanced] ??= []).add(
            PanelCategory(id: '$prefix-custom', title: T.text('retroMenuAddSetting'), rows: custom),
          );
        }
        continue;
      }
      final source = section.id.substring(prefix.length + 1);
      (groups[_EmulatorGroup.forSection(source)] ??= []).add(section);
    }
    return groups;
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
                  ? T.text('retroGameSettings')
                  : T.text('retroConsoleSettings'),
              kind: ActionRow(() => _push(() => _group(platform, game, group))),
            ),
      ],
    );
  }

  PanelRow tuningLink(EmbeddedRetroGame session) => PanelRow(
    id: 'emulator-tune-game',
    title: T.text('retroTuneGame'),
    detail: T.text('retroTuneGameDetail'),
    kind: ActionRow(() => openPage(() => _tuningPage(session))),
  );

  PanelCategory _tuningPage(EmbeddedRetroGame session) {
    final playing = app.running;
    if (playing == null || playing.$2 != session) {
      return PanelCategory(
        id: 'emulator-tune-game',
        title: T.text('retroTuneGame'),
        rows: [
          PanelRow(id: 'tuning-closed', title: T.text('retroGameClosed'), kind: InfoRow(T.text('retroStartToSample'))),
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
      openRestartTrials: () => _push(() => app._retroRestartTrials.page(game, session)),
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
          if (session != null)
            PanelRow(
              id: 'emulator-tune-game',
              title: T.text('retroTuneGame'),
              detail: T.text('retroTuneGameDetail'),
              kind: ActionRow(() => _push(() => _tuningPage(session))),
            )
          else
            PanelRow(
              id: 'emulator-tune-game',
              title: T.text('retroTuneGame'),
              kind: InfoRow(T.text('retroOpenGameGraphics')),
            ),
          for (final section in sections)
            PanelRow(
              id: section.id,
              title: T.text('retroQuickOptimize'),
              detail: T.text('retroConsoleSettings'),
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
