part of 'app_model.dart';

extension _Ps3UpdatePanel on AppModel {
  PanelRow? _ps3UpdateRow(Ps3OnlineReadiness report) {
    if (!embeddedOnlineAvailable) return null;
    final chain = Ps3UpdateChain.forDisc(report.titleId, report.discVersion);
    final managed = _managedRetro;
    if (chain == null || managed.ps3CoreDigests == null || services.pickFolder == null) return null;
    return PanelRow(
      id: 'ps3-update-prepare',
      title: T.text('ps3UpdatePrepare'),
      detail: T.format('ps3UpdateTarget', [chain.version, chain.packages.length]),
      kind: ActionRow(() => _openPs3Update(chain, managed)),
    );
  }

  void _openPs3Update(Ps3UpdateChain chain, ManagedRetro managed) {
    final root = p.join(managed.root, 'OnlineUpdates');
    VerifiedPs3Update? selection;
    String? detail;
    var working = false;
    var installing = false;
    var cancelled = false;
    var prepared = false;
    var interrupted = false;
    late final PanelCategory Function() page;

    bool available() => !_disposed && managedSetupConsole == null && starting == null && running == null && !stopping;
    bool visible() => !_disposed && overlay == Layer.emulatorMenu && identical(_emulatorMenu._page, page);
    bool shouldCancel() => cancelled || !visible();

    Future<void> choose() async {
      if (working || prepared || interrupted || !available()) return;
      working = true;
      detail = T.text('ps3UpdateChecking');
      refresh();
      try {
        if (await managed.verifiedPs3UpdateCore() == null) {
          detail = T.text('ps3UpdateCoreRequired');
          return;
        }
        if (!visible()) return;
        final folder = await services.pickFolder!.call(T.text('ps3UpdateChoose'));
        if (folder == null || !visible()) {
          detail = null;
          return;
        }
        selection = await chain.inspect(folder);
        detail = T.format('ps3UpdateVerified', [chain.packages.length, chain.version]);
      } on Ps3UpdateMissing catch (issue) {
        detail = T.format('ps3UpdateMissing', [issue.versions.join(', ')]);
      } on Object {
        detail = T.text('ps3UpdateReadFailed');
      } finally {
        working = false;
        if (!_disposed) refresh();
      }
    }

    Future<void> install() async {
      final verified = selection;
      if (working || interrupted || !available() || verified == null) return;
      working = installing = true;
      cancelled = false;
      managedSetupConsole = RetroPlatform.ps3;
      detail = T.text('ps3UpdateStaging');
      refresh();
      try {
        await verified.install(root, (stage, count) async {
          final core = await managed.verifiedPs3UpdateCore();
          if (core == null) throw const _Ps3UpdateCoreUnavailable();
          if (shouldCancel()) throw const Ps3UpdateCancelled();
          await installPs3Packages(
            core: core,
            stage: stage,
            count: count,
            cancelled: shouldCancel,
            progress: (done) {
              final next = T.format('ps3UpdateInstalling', [done, count]);
              if (shouldCancel() || detail == next) return;
              detail = next;
              refresh();
            },
          );
        }, cancelled: shouldCancel);
        prepared = true;
        selection = null;
        detail = T.format('ps3UpdateReady', [chain.version]);
        if (!_disposed) show(detail!);
      } on Ps3UpdateRejected catch (issue) {
        final failed = chain.packages.elementAtOrNull(issue.completed)?.version ?? chain.version;
        final previous = issue.completed > 0 ? chain.packages[issue.completed - 1].version : chain.discVersion;
        detail = T.format('ps3UpdateRejected', [failed, previous]);
      } on _Ps3UpdateCoreUnavailable {
        detail = T.text('ps3UpdateCoreRequired');
      } on Ps3UpdateCancelled {
        detail = T.text('ps3UpdateCancelled');
      } on Ps3UpdateWorkerUnconfirmed {
        interrupted = true;
        selection = null;
        detail = T.text('ps3UpdateInterrupted');
      } on Object {
        detail = T.text('ps3UpdateFailed');
      } finally {
        working = installing = false;
        managedSetupConsole = null;
        if (!_disposed) refresh();
      }
    }

    page = () => PanelCategory(
      id: 'ps3-update',
      title: T.text('ps3UpdatePrepare'),
      rows: [
        PanelRow(
          id: 'ps3-update-target',
          title: T.format('ps3UpdateTarget', [chain.version, chain.packages.length]),
          detail: T.text('ps3UpdateScope'),
          kind: const InfoRow(''),
        ),
        PanelRow(id: 'ps3-update-status', title: detail ?? T.text('ps3UpdateChooseDetail'), kind: const InfoRow('')),
        PanelRow(
          id: 'ps3-update-action',
          title: prepared || interrupted
              ? T.text('ps3UpdateDone')
              : installing
              ? T.text(cancelled ? 'ps3UpdateCancelling' : 'ps3UpdateCancel')
              : selection == null
              ? T.text('ps3UpdateChoose')
              : T.text('ps3UpdateInstall'),
          kind: prepared || interrupted
              ? ActionRow(() => _emulatorMenu.back())
              : installing && !cancelled
              ? ActionRow(() {
                  cancelled = true;
                  detail = T.text('ps3UpdateCancelling');
                  refresh();
                })
              : working
              ? const InfoRow('')
              : ActionRow(() => unawaited(selection == null ? choose() : install())),
        ),
        if (selection != null && !working)
          PanelRow(
            id: 'ps3-update-choose-again',
            title: T.text('ps3UpdateChooseAgain'),
            kind: ActionRow(() {
              selection = null;
              panelRow = _emulatorMenu.categories.single.rows.indexWhere((row) => row.id == 'ps3-update-action');
              unawaited(choose());
            }),
          ),
      ],
    );
    _emulatorMenu._push(page);
    unawaited(
      chain.isPrepared(root).then((exists) {
        if (!exists || _disposed || working || selection != null) return;
        prepared = true;
        detail = T.format('ps3UpdateReady', [chain.version]);
        refresh();
      }),
    );
  }
}

final class _Ps3UpdateCoreUnavailable implements Exception {
  const _Ps3UpdateCoreUnavailable();
}
