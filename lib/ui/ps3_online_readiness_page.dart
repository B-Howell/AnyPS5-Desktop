part of 'app_model.dart';

const _ps3OnlineRecheck = 'ps3-online-recheck';

extension _Ps3OnlineReadinessPage on AppModel {
  PanelRow _ps3OnlineReadinessRow(Game game) => PanelRow(
    id: 'ps3-online-readiness',
    title: T.text('ps3OnlineReadiness'),
    detail: T.text('ps3OnlineReadinessDetail'),
    kind: ActionRow(() => _openPs3OnlineReadiness(game)),
  );

  void _openPs3OnlineReadiness(Game game) {
    Ps3OnlineReadiness inspect() =>
        Ps3OnlineReadiness.inspect(disc: game.retro!.path, managedSystem: _managedRetro.systemPath);
    var report = inspect();
    _emulatorMenu.openPage(
      () => _ps3OnlineReadinessPanel(report, () {
        report = inspect();
        panelRow = _emulatorMenu.categories.single.rows.indexWhere((row) => row.id == _ps3OnlineRecheck);
        refresh();
      }),
    );
  }
}

PanelCategory _ps3OnlineReadinessPanel(Ps3OnlineReadiness report, void Function() recheck) {
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
    ],
  );
}
