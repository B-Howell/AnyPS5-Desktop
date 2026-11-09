part of 'together_model.dart';

final class _Ps3PartyAttempt {
  _Ps3PartyAttempt(this.runningHost);

  final EmbeddedRetroGame? runningHost;
  final cancelled = Completer<void>();
  final done = Completer<void>();
  String? roomId;
  bool roomEnded = false;
  bool disposed = false;
  bool inviteSent = false;

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

extension TogetherPs3Online on TogetherModel {
  void ps3ProviderFailed(Object? party) {
    final attempt = _ps3Party;
    if (attempt != null && identical(attempt, party)) attempt.cancel();
  }

  void ps3WorkerExited(EmbeddedRetroGame worker) {
    final attempt = _ps3Party;
    if (attempt != null && identical(attempt.runningHost, worker)) attempt.cancel();
  }

  bool get _ps3LaunchAvailable =>
      app.managedRetroAvailable &&
      app.running == null &&
      app.starting == null &&
      !app.stopping &&
      app.managedSetupConsole == null;

  bool get _ps3PartyIdle => !_ps2LanBusy && _ps1Match == null && !_verifyingPs1;
  bool get _ps3PartyAvailable => _ps3LaunchAvailable && _ps3PartyIdle;

  bool _canHostPs3FromGame(Game game, EmbeddedRetroGame worker, Ps3OnlineRelease release) =>
      app.managedRetroAvailable &&
      !app.stopping &&
      app.managedSetupConsole == null &&
      identical(app.running?.$1, game) &&
      identical(app.embeddedGame, worker) &&
      worker.startupVisible &&
      worker.ps3ProviderStatus == Ps3ProviderStatus.ready &&
      identical(worker.ps3OnlineRelease, release) &&
      app.services.ps3OnlineReleases.contains(release);

  ({Game game, EmbeddedRetroGame worker, Ps3OnlineRelease release})? get _ps3QuickHost {
    final game = app.running?.$1;
    final worker = app.embeddedGame;
    final release = worker?.ps3OnlineRelease;
    if (!_ps3PartyIdle ||
        game == null ||
        worker == null ||
        release == null ||
        !_canHostPs3FromGame(game, worker, release)) {
      return null;
    }
    return (game: game, worker: worker, release: release);
  }

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
      onPartyReady: (profile) =>
          _startPs3Party(game, release, profile: profile, me: me, friendId: friendId, invite: invite),
    );
  }

  List<PanelRow> ps3PartyRows() {
    final attempt = _ps3Party;
    if (attempt == null) return const [];
    if (attempt.cancelled.isCompleted) {
      return [PanelRow(id: 'ps3-party-leave', title: T.text('ps3PartyClosing'), kind: const InfoRow(''))];
    }
    final playing = app.isPlayingPs3Party(attempt) || attempt.inviteSent && attempt.runningHost != null;
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
    if (attempt != null) {
      return app.isStartingPs3Party(attempt) ||
              app.isPlayingPs3Party(attempt) ||
              (attempt.runningHost != null && identical(app.embeddedGame, attempt.runningHost))
          ? ps3PartyRows()
          : const [];
    }
    return [
      if (_ps3QuickHost != null)
        PanelRow(
          id: 'ps3-party-invite-from-game',
          title: T.text('ps3PartyInviteFromGame'),
          kind: ActionRow(() => app.open(Layer.retroOnlineFriends)),
        ),
    ];
  }

  List<PanelRow> ps3PartyInviteFriendRows() {
    final host = _ps3QuickHost;
    final me = account.user?.id;
    if (host == null) return const [];
    return _retroInviteFriendRows(
      prefix: 'ps3-party-invite',
      title: 'ps3PartyInviteFromGame',
      detail: 'ps3PartyGameMenu',
      unavailable: 'ps3PartyUnavailable',
      invite: (friend) {
        if (me == null) return;
        unawaited(
          _startPs3Party(host.game, host.release, me: me, friendId: friend.person.id, runningHost: host.worker),
        );
      },
    );
  }

  Future<void> _startPs3Party(
    Game game,
    Ps3OnlineRelease release, {
    Ps3OnlineProfile? profile,
    EmbeddedRetroGame? runningHost,
    required String me,
    String? friendId,
    GameInvite? invite,
  }) async {
    assert((profile == null) != (runningHost == null));
    if (account.user?.id != me || hub.socket.status != SocketStatus.ready) {
      return app.show(T.text('ps3PartyUnavailable'));
    }
    bool canStart() => runningHost == null ? _ps3LaunchAvailable : _canHostPs3FromGame(game, runningHost, release);
    if (!_ps3PartyIdle || !canStart()) return app.show(T.text('ps3PartyBusy'));
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
    final owner = app.currentProfile?.id;
    final attempt = _ps3Party = _Ps3PartyAttempt(runningHost)..roomId = invite?.sessionId;
    bool active() => !attempt.cancelled.isCompleted && account.user?.id == me && app.currentProfile?.id == owner;
    RetroRoom? room;
    Future<void>? launch;
    if (runningHost == null) {
      app.returnTo((layer: Layer.friends, category: 'friends', row: 'ps3-party-leave'));
    } else {
      app.resumeGame();
    }
    try {
      room = invite == null
          ? await rooms.host(cancelBeforeAdmission: attempt.cancelled)
          : await rooms.join(invite.sessionId, expectedHost: invite.from?.id, cancelBeforeAdmission: attempt.cancelled);
      attempt.roomId = room.id;
      if (!active()) return;
      if (!canStart()) return app.show(T.text('ps3PartyBusy'));
      if (friendId != null) await rooms.invite(room, friendId);
      if (!active()) return;
      if (runningHost == null) {
        launch = app.playVerifiedPs3Online(game, profile!, canBoot: active, party: attempt);
        await Future.any<void>([launch, attempt.cancelled.future]);
      } else {
        if (!canStart()) return app.show(T.text('ps3PartyBusy'));
        attempt.inviteSent = true;
        app.show(T.text('ps3PartyGameMenu'));
        await attempt.cancelled.future;
      }
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
