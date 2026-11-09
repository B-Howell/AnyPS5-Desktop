part of 'together_model.dart';

final class _Ps3PartyAttempt {
  final cancelled = Completer<void>();
  final done = Completer<void>();
  String? roomId;
  bool roomEnded = false;
  bool disposed = false;

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

extension TogetherPs3Online on TogetherModel {
  void ps3ProviderFailed(Object? party) {
    final attempt = _ps3Party;
    if (attempt != null && identical(attempt, party)) attempt.cancel();
  }

  bool get _ps3LaunchAvailable =>
      app.managedRetroAvailable &&
      app.running == null &&
      app.starting == null &&
      !app.stopping &&
      app.managedSetupConsole == null;

  bool get _ps3PartyAvailable => _ps3LaunchAvailable && !_ps2LanBusy && _ps1Match == null && !_verifyingPs1;

  Ps3OnlineRelease? _ps3PartyRelease(Game game, {String? version}) {
    if (game.retro?.platform != RetroPlatform.ps3) return null;
    return app.services.ps3OnlineReleases
        .where(
          (release) =>
              release.hasManagedProfile &&
              game.titleId == 'PS3-${release.titleId}' &&
              (version == null || release.updateVersion == version),
        )
        .singleOrNull;
  }

  Game? _ps3PartyGame(GameInvite invite) => app.games
      .where(
        (game) =>
            game.titleId == 'PS3-${invite.titleId}' && _ps3PartyRelease(game, version: invite.gameVersion) != null,
      )
      .firstOrNull;

  String ps3PartyInviteDetail(GameInvite invite) => T.text(
    !app.managedRetroAvailable || _ps3PartyGame(invite) == null ? 'ps3PartyCompatibility' : 'ps3PartyInviteDetail',
  );

  List<PanelRow> ps3PartyInvites(Friend friend) {
    final game = app.selectedGame;
    final release = game == null ? null : _ps3PartyRelease(game);
    if (!_ps3PartyAvailable || game == null || release == null || !friend.presence.online) return const [];
    return [
      PanelRow(
        id: 'ps3-party-invite',
        title: T.format('ps3PartyInvite', [game.name]),
        detail: T.text('ps3PartyInviteDetail'),
        kind: ActionRow(() => _openPs3PartySetup(game, release, friendId: friend.person.id)),
      ),
    ];
  }

  Future<void> joinPs3Party(GameInvite invite) async {
    final game = _ps3PartyGame(invite);
    final release = game == null ? null : _ps3PartyRelease(game, version: invite.gameVersion);
    if (!app.managedRetroAvailable || game == null || release == null) return app.show(T.text('ps3PartyCompatibility'));
    if (!_ps3PartyAvailable) return app.show(T.text('ps3PartyBusy'));
    _openPs3PartySetup(game, release, invite: invite);
  }

  void _openPs3PartySetup(Game game, Ps3OnlineRelease release, {String? friendId, GameInvite? invite}) {
    final me = account.user?.id;
    if (me == null || hub.socket.status != SocketStatus.ready) {
      app.show(T.text('ps3PartyUnavailable'));
      return;
    }
    app.openPs3OnlineReadiness(
      game,
      partyRelease: release,
      partyAction: invite == null ? 'ps3PartyHost' : 'ps3PartyJoin',
      onPartyReady: (profile) => _startPs3Party(game, release, profile, me: me, friendId: friendId, invite: invite),
    );
  }

  List<PanelRow> ps3PartyRows() {
    final attempt = _ps3Party;
    if (attempt == null) return const [];
    if (attempt.cancelled.isCompleted) {
      return [PanelRow(id: 'ps3-party-leave', title: T.text('ps3PartyClosing'), kind: const InfoRow(''))];
    }
    final playing = app.isPlayingPs3Party(attempt);
    return [
      PanelRow(
        id: 'ps3-party-leave',
        title: T.text(playing ? 'ps3PartyLeave' : 'ps3PartyCancel'),
        detail: T.text(
          playing
              ? 'ps3PartyGameMenu'
              : app.isStartingPs3Party(attempt)
              ? 'ps3PartyBooting'
              : 'ps3PartyStarting',
        ),
        kind: ActionRow(() {
          attempt.cancel();
          app.refresh();
        }, destructive: true),
      ),
    ];
  }

  List<PanelRow> ps3PartyQuickRows() {
    final attempt = _ps3Party;
    if (attempt == null || (!app.isStartingPs3Party(attempt) && !app.isPlayingPs3Party(attempt))) return const [];
    return ps3PartyRows();
  }

  Future<void> _startPs3Party(
    Game game,
    Ps3OnlineRelease release,
    Ps3OnlineProfile profile, {
    required String me,
    String? friendId,
    GameInvite? invite,
  }) async {
    if (account.user?.id != me || hub.socket.status != SocketStatus.ready) {
      return app.show(T.text('ps3PartyUnavailable'));
    }
    if (!_ps3PartyAvailable) return app.show(T.text('ps3PartyBusy'));
    final rooms = RetroOnlineRooms(
      call: (method, path, [body]) {
        if (account.user?.id != me) throw StateError('The AnyTogether account changed.');
        return account.call(method, path, body);
      },
      signal: (_, _, _, _, _) {},
      me: me,
      spec: (
        titleId: release.titleId,
        gameVersion: release.updateVersion,
        mode: RetroOnlineMode.nativeOnline,
        capacity: 2,
      ),
      profileDigest: release.partyFingerprint,
    );
    final attempt = _ps3Party = _Ps3PartyAttempt()..roomId = invite?.sessionId;
    bool active() => !attempt.cancelled.isCompleted && account.user?.id == me;
    RetroRoom? room;
    Future<void>? launch;
    app.returnTo((layer: Layer.friends, category: 'friends', row: 'ps3-party-leave'));
    try {
      room = invite == null
          ? await rooms.host(cancelBeforeAdmission: attempt.cancelled)
          : await rooms.join(invite.sessionId, expectedHost: invite.from?.id, cancelBeforeAdmission: attempt.cancelled);
      attempt.roomId = room.id;
      if (!active()) return;
      if (!_ps3LaunchAvailable) return app.show(T.text('ps3PartyBusy'));
      if (friendId != null) await rooms.invite(room, friendId);
      if (!active()) return;
      launch = app.playVerifiedPs3Online(game, profile, canBoot: active, party: attempt);
      await Future.any<void>([launch, attempt.cancelled.future]);
    } on RetroRoomHostMismatch {
      if (active()) app.show(T.text('retroInviteHostChanged'));
    } on Object {
      if (active()) app.show(T.text('ps3PartyFailed'));
    } finally {
      final pendingBoot = app.isStartingPs3Party(attempt) ? launch : null;
      if (pendingBoot != null && app.running != null) unawaited(app.stopRunningGame());
      if (room != null && !attempt.roomEnded && account.user?.id == me) {
        try {
          await rooms.leave(room);
        } on Object {
          // The room can already have ended on the other device.
        }
      }
      await pendingBoot?.catchError((Object _) {});
      if (identical(_ps3Party, attempt)) _ps3Party = null;
      attempt.done.complete();
      if (!attempt.disposed) {
        if (account.user?.id == me) unawaited(hub.games.refresh().catchError((Object _) {}));
        app.refresh();
      }
    }
  }
}
