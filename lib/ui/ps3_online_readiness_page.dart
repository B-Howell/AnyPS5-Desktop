part of 'app_model.dart';

const _ps3OnlineRecheck = 'ps3-online-recheck';
final _ps3ProviderId = RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$');

String _ps3OnlineIssueText(Ps3OnlineIssue issue) => T.text(switch (issue) {
  Ps3OnlineIssue.unqualified => 'ps3OnlineNoProviderDetail',
  Ps3OnlineIssue.storage => 'ps3OnlineStorageRequired',
  Ps3OnlineIssue.core => 'ps3UpdateCoreRequired',
  Ps3OnlineIssue.update => 'ps3OnlineUpdateRequired',
  Ps3OnlineIssue.patch => 'ps3OnlinePatchRequired',
  Ps3OnlineIssue.firmware => 'ps3OnlineFirmwareRequired',
  Ps3OnlineIssue.account => 'ps3OnlineAccountRequired',
});

extension _Ps3OnlineReadinessPage on AppModel {
  PanelRow _ps3OnlineReadinessRow(Game game) => PanelRow(
    id: 'ps3-online-readiness',
    title: T.text('ps3OnlineReadiness'),
    detail: T.text('ps3OnlineReadinessDetail'),
    kind: ActionRow(() => _openPs3OnlineReadiness(game)),
  );

  void _openPs3OnlineReadiness(Game game) {
    final disc = game.retro!;
    final managed = _managedRetro;
    final releases = services.ps3OnlineReleases
        .where(
          (release) =>
              release.updateTreeDigest != null &&
              release.protection is Ps3YamlProtection &&
              _ps3ProviderId.hasMatch(release.provider),
        )
        .toList();
    Ps3OnlineReadiness inspect() =>
        Ps3OnlineReadiness.inspect(disc: disc.path, managedSystem: managed.systemPath, releases: releases);
    var report = inspect();
    var checking = false;
    String? failure;
    late final PanelCategory Function() page;
    bool visible() => !_disposed && overlay == Layer.emulatorMenu && identical(_emulatorMenu._page, page);
    bool available() =>
        !_disposed && !_quitting && managedSetupConsole == null && starting == null && running == null && !stopping;

    Future<void> playOnline(Ps3OnlineRelease release) async {
      if (checking || !visible() || !available()) return;
      checking = true;
      failure = null;
      refresh();
      Ps3OnlineProfile? profile;
      try {
        final chain = Ps3UpdateChain.forDisc(report.titleId, report.discVersion);
        final managedRoot = await Directory(managed.root).resolveSymbolicLinks();
        final onlineRoot = p.join(managedRoot, 'OnlineProfiles', release.provider, release.titleId);
        if (!p.equals(await Directory(onlineRoot).resolveSymbolicLinks(), onlineRoot)) {
          throw Ps3OnlineIssue.storage;
        }
        profile = await Ps3OnlineProfile.verify(
          provider: release.provider,
          disc: disc.path,
          core: p.join(managedRoot, ManagedRetro.libraryName(RetroPlatform.ps3)),
          onlineRoot: onlineRoot,
          offlineSystemRoot: managed.systemPath,
          releases: [release],
          preparedUpdate: chain == null ? null : (chain: chain, root: p.join(managed.root, 'OnlineUpdates')),
        );
      } on Ps3OnlineIssue catch (issue) {
        failure = _ps3OnlineIssueText(issue);
      } on FileSystemException {
        failure = _ps3OnlineIssueText(Ps3OnlineIssue.storage);
      } finally {
        checking = false;
        if (visible()) refresh();
      }
      if (profile == null || !visible() || !available()) return;
      _dismissOverlay();
      await _playRetro(game, disc, onlineProfile: profile, canBoot: () => !_disposed && !_quitting);
    }

    page = () {
      final eligible = releases.where((release) => release.titleId == report.titleId);
      final release = eligible.length == 1 ? eligible.single : null;
      return _ps3OnlineReadinessPanel(
        report,
        _ps3UpdateRow(report),
        () {
          if (checking) return;
          report = inspect();
          failure = null;
          panelRow = _emulatorMenu.categories.single.rows.indexWhere((row) => row.id == _ps3OnlineRecheck);
          refresh();
        },
        play: release == null
            ? null
            : PanelRow(
                id: 'ps3-online-play',
                title: T.text('ps3OnlinePlay'),
                detail: checking ? T.text('ps3OnlineChecking') : failure ?? T.text('ps3OnlinePlayDetail'),
                kind: ActionRow(() => unawaited(playOnline(release))),
              ),
      );
    };
    _emulatorMenu.openPage(page);
  }
}

PanelCategory _ps3OnlineReadinessPanel(
  Ps3OnlineReadiness report,
  PanelRow? update,
  void Function() recheck, {
  PanelRow? play,
}) {
  final (status, explanation) = switch (report.state) {
    Ps3OnlineReadinessState.discUnavailable => ('ps3OnlineDiscUnavailable', 'ps3OnlineDiscUnavailableDetail'),
    Ps3OnlineReadinessState.noProvider => ('ps3OnlineNoProvider', 'ps3OnlineNoProviderDetail'),
    Ps3OnlineReadinessState.profileRequired => ('ps3OnlineProfileRequired', 'ps3OnlineProfileRequiredDetail'),
  };
  return PanelCategory(
    id: 'ps3-online-check',
    title: T.text('ps3OnlineReadiness'),
    rows: [
      PanelRow(id: 'ps3-online-status', title: T.text(status), detail: T.text(explanation), kind: const InfoRow('')),
      if (report.titleId case final title?) ...[
        PanelRow(id: 'ps3-online-title-id', title: T.text('ps3OnlineTitleId'), kind: InfoRow(title)),
        PanelRow(
          id: 'ps3-online-disc-version',
          title: T.text('ps3OnlineDiscVersion'),
          kind: InfoRow(report.discVersion ?? T.text('ps3OnlineUnknownVersion')),
        ),
        PanelRow(
          id: 'ps3-online-managed-update',
          title: T.text('ps3OnlineManagedUpdate'),
          kind: InfoRow(report.managedUpdate ?? T.text('ps3OnlineNoUpdate')),
        ),
      ],
      PanelRow(id: _ps3OnlineRecheck, title: T.text('ps3OnlineRecheck'), kind: ActionRow(recheck)),
      ?update,
      ?play,
    ],
  );
}
