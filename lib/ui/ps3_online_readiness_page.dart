part of 'app_model.dart';

const _ps3OnlineRecheck = 'ps3-online-recheck';

enum _Ps3ProfileFile {
  patch('Patch', 'ps3OnlinePatchMismatch', 'ps3OnlinePatchInstalled'),
  account('Account', 'ps3OnlineAccountMismatch', 'ps3OnlineAccountInstalled');

  const _Ps3ProfileFile(this.key, this.invalidKey, this.installedKey);
  final String key;
  final String invalidKey;
  final String installedKey;
}

String _ps3OnlineIssueText(Ps3OnlineIssue issue) => T.text(switch (issue) {
  Ps3OnlineIssue.unqualified => 'ps3OnlineNoProviderDetail',
  Ps3OnlineIssue.storage => 'ps3OnlineStorageRequired',
  Ps3OnlineIssue.core => 'ps3UpdateCoreRequired',
  Ps3OnlineIssue.update => 'ps3OnlineUpdateRequired',
  Ps3OnlineIssue.patch => 'ps3OnlinePatchRequired',
  Ps3OnlineIssue.firmware => 'ps3OnlineFirmwareRequired',
  Ps3OnlineIssue.account => 'ps3OnlineAccountRequired',
});

extension Ps3OnlineReadinessPage on AppModel {
  PanelRow? _ps3ProviderQuickRow(Game game) {
    final session = embeddedGame;
    final status = session?.ps3ProviderStatus;
    if (session == null || status == null) return null;
    final canReview = status.failed && session.startupVisible && !stopping;
    return PanelRow(
      id: 'ps3ProviderStatus',
      title: T.text(canReview ? 'ps3ProviderReviewSetup' : 'ps3ProviderConnection'),
      detail: canReview ? T.text(status.detailKey) : null,
      kind: canReview
          ? ActionRow(() {
              if (identical(embeddedGame, session) && !stopping) {
                openPs3OnlineReadiness(game, partyRelease: session.ps3OnlineRelease, repairSession: session);
              }
            })
          : InfoRow(T.text(status.detailKey)),
    );
  }

  void _watchPs3ProviderFailure(EmbeddedRetroGame session, Object? party) {
    unawaited(
      session.initialProviderFailure.then((failure) {
        if (failure == null || _disposed || _quitting || stopping || !identical(running?.$2, session)) return;
        together.ps3ProviderFailed(party);
        show(T.text(failure.detailKey));
      }),
    );
  }

  PanelRow _ps3OnlineReadinessRow(Game game) => PanelRow(
    id: 'ps3-online-readiness',
    title: T.text('ps3OnlineReadiness'),
    detail: T.text('ps3OnlineReadinessDetail'),
    kind: ActionRow(() => openPs3OnlineReadiness(game)),
  );

  void openPs3OnlineReadiness(
    Game game, {
    Ps3OnlineRelease? partyRelease,
    String? partyAction,
    Future<void> Function(Ps3OnlineProfile)? onPartyReady,
    EmbeddedRetroGame? repairSession,
  }) {
    final disc = game.retro!;
    final managed = _managedRetro;
    final releases = services.ps3OnlineReleases
        .where(
          (release) =>
              release.hasManagedProfile &&
              release.coreSha256For(embeddedCoreHost) != null &&
              (partyRelease == null || release == partyRelease),
        )
        .toList();
    Ps3OnlineReadiness inspect() =>
        Ps3OnlineReadiness.inspect(disc: disc.path, managedSystem: managed.systemPath, releases: releases);
    var report = inspect();
    var checking = false;
    var preparingFirmware = false;
    var closingForRepair = false;
    String? firmwareDetail;
    _Ps3ProfileFile? importing;
    String? failure;
    final importDetails = <_Ps3ProfileFile, String>{};
    late final PanelCategory Function() page;
    bool visible() => !_disposed && overlay == Layer.emulatorMenu && identical(_emulatorMenu._page, page);
    bool available() =>
        !_disposed &&
        !_quitting &&
        managedSetupConsole == null &&
        starting == null &&
        running == null &&
        !stopping &&
        !closingForRepair;
    bool busy() => checking || importing != null || preparingFirmware;

    Future<void> closeForRepair() async {
      if (!visible() || closingForRepair || stopping || !identical(embeddedGame, repairSession)) return;
      closingForRepair = true;
      final settled = waitForRetroWorkerExit();
      try {
        await stopRunningGame();
        await settled;
      } finally {
        closingForRepair = false;
        if (visible()) {
          final rows = page().rows;
          final preferred = repairSession?.ps3ProviderStatus == Ps3ProviderStatus.loginRejected
              ? 'ps3-online-import-account'
              : _ps3OnlineRecheck;
          final index = rows.indexWhere((row) => row.id == preferred);
          panelRow = index < 0 ? rows.indexWhere((row) => row.id == _ps3OnlineRecheck) : index;
          if (panelRow < 0) panelRow = 0;
          _skipToFocusable();
          refresh();
        }
      }
    }

    Future<void> prepareFirmware(Ps3OnlineRelease release) async {
      if (busy() || !visible() || !available()) return;
      preparingFirmware = true;
      firmwareDetail = T.text('ps3OnlineFirmwareChecking');
      refresh();
      try {
        if (await Ps3OnlineProfile.prepareFirmware(
          managed,
          release,
          canPublish: () => visible() && available(),
          progress: (received, total) {
            final detail = T.format('ps3OnlineFirmwareProgress', [received * 100 ~/ total]);
            if (detail == firmwareDetail) return;
            firmwareDetail = detail;
            refresh();
          },
        )) {
          failure = null;
          firmwareDetail = T.text('ps3OnlineFirmwareReady');
        }
      } on Ps3OnlineIssue catch (issue) {
        firmwareDetail = issue == Ps3OnlineIssue.firmware
            ? T.text('ps3OnlineFirmwareFailed')
            : _ps3OnlineIssueText(issue);
      } on ToolkitFailure {
        firmwareDetail = T.text('ps3OnlineFirmwareFailed');
      } on FileSystemException {
        firmwareDetail = _ps3OnlineIssueText(Ps3OnlineIssue.storage);
      } finally {
        preparingFirmware = false;
        if (visible()) refresh();
      }
    }

    Future<void> importFile(Ps3OnlineRelease release, _Ps3ProfileFile kind) async {
      if (busy() || !visible() || !available()) return;
      importing = kind;
      importDetails.remove(kind);
      refresh();
      try {
        final path = await services.pickFile?.call(T.text('ps3OnlineImport${kind.key}'), const ['yml', 'yaml']);
        if (path == null || !visible() || !available()) return;
        final publish = kind == _Ps3ProfileFile.patch
            ? Ps3OnlineProfile.importProtection
            : Ps3OnlineProfile.importAccount;
        final installed = await publish(managed.root, release, path, canPublish: () => visible() && available());
        if (installed) {
          failure = null;
          importDetails[kind] = T.text(kind.installedKey);
        }
      } on Ps3OnlineIssue catch (issue) {
        importDetails[kind] = issue == Ps3OnlineIssue.patch || issue == Ps3OnlineIssue.account
            ? T.text(kind.invalidKey)
            : _ps3OnlineIssueText(issue);
      } on FileSystemException {
        importDetails[kind] = _ps3OnlineIssueText(Ps3OnlineIssue.storage);
      } on PlatformException {
        importDetails[kind] = T.text('ps3OnlinePatchPickerFailed');
      } finally {
        importing = null;
        if (visible()) refresh();
      }
    }

    Future<void> playOnline(Ps3OnlineRelease release) async {
      if (busy() || !visible() || !available()) return;
      checking = true;
      failure = null;
      refresh();
      Ps3OnlineProfile? profile;
      try {
        final chain = Ps3UpdateChain.forDisc(report.titleId, report.discVersion);
        final managedRoot = await Directory(managed.root).resolveSymbolicLinks();
        final onlineRoot = await Ps3OnlineProfile.managedProfileRoot(managedRoot, release);
        profile = await Ps3OnlineProfile.verify(
          provider: release.provider,
          disc: disc.path,
          core: p.join(managedRoot, managed.libraryName(RetroPlatform.ps3)),
          coreHost: embeddedCoreHost,
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
      if (onPartyReady != null) {
        await onPartyReady(profile);
      } else {
        await playVerifiedPs3Online(game, profile, canBoot: () => true);
      }
    }

    page = () {
      if (closingForRepair || (repairSession != null && identical(embeddedGame, repairSession))) {
        return PanelCategory(
          id: 'ps3-online-check',
          title: T.text('ps3OnlineReadiness'),
          rows: [
            if (repairSession?.ps3ProviderStatus case final status?)
              PanelRow(
                id: 'ps3-online-provider-issue',
                title: T.text('ps3ProviderConnection'),
                kind: InfoRow(T.text(status.detailKey)),
              ),
            PanelRow(
              id: 'ps3-online-close-for-repair',
              title: T.text(closingForRepair || stopping ? 'ps3ProviderClosing' : 'ps3ProviderCloseForSetup'),
              detail: closingForRepair || stopping ? null : T.text('closeGameDetail'),
              kind: closingForRepair || stopping
                  ? const InfoRow('')
                  : ActionRow(() => unawaited(closeForRepair()), destructive: true),
            ),
          ],
        );
      }
      final eligible = releases.where((release) => release.titleId == report.titleId);
      final release = eligible.length == 1 ? eligible.single : null;
      return _ps3OnlineReadinessPanel(
        report,
        _ps3UpdateRow(report),
        () {
          if (busy()) return;
          report = inspect();
          failure = null;
          panelRow = _emulatorMenu.categories.single.rows.indexWhere((row) => row.id == _ps3OnlineRecheck);
          refresh();
        },
        imports: [
          if (release != null)
            PanelRow(
              id: 'ps3-online-firmware',
              title: T.text('ps3OnlinePrepareFirmware'),
              detail: firmwareDetail ?? T.text('ps3OnlinePrepareFirmwareDetail'),
              kind: ActionRow(() => unawaited(prepareFirmware(release))),
            ),
          if (release != null && services.pickFile != null)
            for (final kind in _Ps3ProfileFile.values)
              PanelRow(
                id: 'ps3-online-import-${kind.name}',
                title: T.text('ps3OnlineImport${kind.key}'),
                detail: importing == kind
                    ? T.text('ps3Online${kind.key}Importing')
                    : importDetails[kind] ?? T.text('ps3OnlineImport${kind.key}Detail'),
                kind: ActionRow(() => unawaited(importFile(release, kind))),
              ),
        ],
        play: release == null
            ? null
            : PanelRow(
                id: 'ps3-online-play',
                title: T.text(partyAction ?? 'ps3OnlinePlay'),
                detail: checking ? T.text('ps3OnlineChecking') : failure ?? T.text('ps3OnlinePlayDetail'),
                kind: ActionRow(() => unawaited(playOnline(release))),
              ),
      );
    };
    _emulatorMenu.openChild(page);
  }

  Future<void> playVerifiedPs3Online(
    Game game,
    Ps3OnlineProfile profile, {
    required bool Function() canBoot,
    Object? party,
  }) => _playRetro(
    game,
    game.retro!,
    onlineProfile: profile,
    ps3Party: party,
    canBoot: () => !_disposed && !_quitting && canBoot(),
  );
}

PanelCategory _ps3OnlineReadinessPanel(
  Ps3OnlineReadiness report,
  PanelRow? update,
  void Function() recheck, {
  required List<PanelRow> imports,
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
      ...imports,
      ?play,
    ],
  );
}
