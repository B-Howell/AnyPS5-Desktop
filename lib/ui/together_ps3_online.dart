part of 'together_model.dart';

enum _Ps3PartyMembership { checking, waiting, present, unavailable }

final class _Ps3PartyAttempt {
  _Ps3PartyAttempt(this.runningWorker);

  final EmbeddedRetroGame? runningWorker;
  final cancelled = Completer<void>();
  final done = Completer<void>();
  String? roomId;
  bool roomEnded = false;
  bool disposed = false;
  bool attached = false;
  _Ps3PartyMembership membership = _Ps3PartyMembership.checking;
  Future<void> Function()? refreshMembership;
  int membershipRequest = 0;

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

extension TogetherPs3Online on TogetherModel {
  void _ps3PartyEvent(TogetherEvent event) {
    final attempt = _ps3Party;
    final roomId = attempt?.roomId;
    if (attempt == null || roomId == null) return;
    final data = event.json;
    switch (event.type) {
      case 'game_session.ended' when data['sessionId'] == roomId:
        attempt.roomEnded = true;
        attempt.cancel();
        app.refresh();
      case 'game_session.member_joined' || 'game_session.member_left' when data['sessionId'] == roomId:
      case 'game_session.updated' when data['id'] == roomId:
      case 'live.ready':
        final refresh = attempt.refreshMembership;
        if (refresh != null && !attempt.cancelled.isCompleted) unawaited(refresh());
    }
  }

  String _ps3PartyHandoffKey(_Ps3PartyAttempt attempt, Ps3ProviderStatus provider) {
    if (provider != Ps3ProviderStatus.ready) return provider.detailKey;
    if (hub.socket.status != SocketStatus.ready) return 'ps3PartyMembershipUnavailable';
    return switch (attempt.membership) {
      _Ps3PartyMembership.checking => 'ps3PartyCheckingMembership',
      _Ps3PartyMembership.waiting => 'ps3PartyWaitingForFriend',
      _Ps3PartyMembership.present => 'ps3PartyGameMenu',
      _Ps3PartyMembership.unavailable => 'ps3PartyMembershipUnavailable',
    };
  }

  void ps3ProviderFailed(Object? party) {
    final attempt = _ps3Party;
    if (attempt != null && identical(attempt, party)) attempt.cancel();
  }

  void ps3WorkerExited(EmbeddedRetroGame worker) {
    final attempt = _ps3Party;
    if (attempt != null && identical(attempt.runningWorker, worker)) attempt.cancel();
  }

  bool get _ps3LaunchAvailable =>
      app.managedRetroAvailable &&
      app.running == null &&
      app.starting == null &&
      !app.stopping &&
      app.managedSetupConsole == null;

  bool get _ps3PartyIdle => !_ps2LanBusy && _ps1Match == null && !_verifyingPs1;
  bool get _ps3PartyAvailable => _ps3LaunchAvailable && _ps3PartyIdle;

  bool _canReusePs3Game(Game game, EmbeddedRetroGame worker, Ps3OnlineRelease release) =>
      app.managedRetroAvailable &&
      !app.stopping &&
      app.managedSetupConsole == null &&
      identical(app.running?.$1, game) &&
      identical(app.embeddedGame, worker) &&
      worker.startupVisible &&
      worker.ps3ProviderStatus == Ps3ProviderStatus.ready &&
      identical(worker.ps3OnlineRelease, release) &&
      app.services.ps3OnlineReleases.contains(release);

  ({Game game, EmbeddedRetroGame worker, Ps3OnlineRelease release})? _ps3ReadyGame({GameInvite? invite}) {
    final game = app.running?.$1;
    final worker = app.embeddedGame;
    final release = worker?.ps3OnlineRelease;
    if (!_ps3PartyIdle ||
        game == null ||
        worker == null ||
        release == null ||
        !_canReusePs3Game(game, worker, release)) {
      return null;
    }
    if (invite != null && (invite.titleId != release.titleId || invite.gameVersion != release.updateVersion)) {
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

  String ps3PartyInviteDetail(GameInvite invite) {
    if (_ps3ReadyGame(invite: invite) != null) return T.text('ps3PartyContinueInGame');
    return T.text(
      !app.managedRetroAvailable || _ps3PartyGame(invite) == null ? 'ps3PartyCompatibility' : 'ps3PartyInviteDetail',
    );
  }

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

  PanelRow? ps3PartyDashboardLink(Game game, void Function(PanelCategory Function()) open) {
    final release = _ps3PartyRelease(game);
    if (!_ps3PartyAvailable || release == null) return null;
    return _retroDashboardInviteLink(
      game,
      open,
      prefix: 'ps3-party-dashboard',
      title: 'ps3PartyInviteFromGame',
      detail: 'ps3PartyInviteDetail',
      unavailable: 'ps3PartyUnavailable',
      available: () => _ps3PartyAvailable && _ps3PartyRelease(game) == release,
      invite: (friend) => _openPs3PartySetup(game, release, friendId: friend.person.id),
    );
  }

  Future<void> joinPs3Party(GameInvite invite) async {
    if (_ps3ReadyGame(invite: invite) case final ready?) {
      final me = account.user?.id;
      if (me == null) return app.show(T.text('ps3PartyUnavailable'));
      await _startPs3Party(ready.game, ready.release, me: me, invite: invite, runningWorker: ready.worker);
      return;
    }
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
    final playing = app.isPlayingPs3Party(attempt) || attempt.attached && attempt.runningWorker != null;
    final worker = attempt.runningWorker ?? app.embeddedGame;
    final provider = worker?.ps3ProviderStatus ?? Ps3ProviderStatus.unavailable;
    bool canRefresh() =>
        identical(_ps3Party, attempt) &&
        !attempt.cancelled.isCompleted &&
        worker?.ps3ProviderStatus == Ps3ProviderStatus.ready &&
        hub.socket.status == SocketStatus.ready &&
        attempt.membership != _Ps3PartyMembership.checking;
    return [
      PanelRow(
        id: 'ps3-party-leave',
        title: T.text(playing ? 'ps3PartyLeave' : 'ps3PartyCancel'),
        detail: T.text(
          playing
              ? _ps3PartyHandoffKey(attempt, provider)
              : app.isStartingPs3Party(attempt)
              ? 'ps3PartyBooting'
              : 'ps3PartyStarting',
        ),
        kind: ActionRow(() {
          attempt.cancel();
          app.refresh();
        }, destructive: true),
      ),
      if (playing)
        if (attempt.refreshMembership case final refresh?)
          PanelRow(
            id: 'ps3-party-refresh',
            title: T.text('ps3PartyRefreshRoom'),
            kind: canRefresh()
                ? ActionRow(() {
                    if (canRefresh()) unawaited(refresh());
                  })
                : const InfoRow('', navigable: true),
          ),
    ];
  }

  List<PanelRow> ps3PartyQuickRows() {
    final attempt = _ps3Party;
    if (attempt != null) {
      return app.isStartingPs3Party(attempt) ||
              app.isPlayingPs3Party(attempt) ||
              (attempt.runningWorker != null && identical(app.embeddedGame, attempt.runningWorker))
          ? ps3PartyRows()
          : const [];
    }
    return [
      if (_ps3ReadyGame() != null)
        PanelRow(
          id: 'ps3-party-invite-from-game',
          title: T.text('ps3PartyInviteFromGame'),
          kind: ActionRow(() => app.open(Layer.retroOnlineFriends)),
        ),
    ];
  }

  List<PanelRow> ps3PartyInviteFriendRows() {
    final host = _ps3ReadyGame();
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
          _startPs3Party(host.game, host.release, me: me, friendId: friend.person.id, runningWorker: host.worker),
        );
      },
    );
  }

  Future<void> _startPs3Party(
    Game game,
    Ps3OnlineRelease release, {
    Ps3OnlineProfile? profile,
    EmbeddedRetroGame? runningWorker,
    required String me,
    String? friendId,
    GameInvite? invite,
  }) async {
    assert((profile == null) != (runningWorker == null));
    if (account.user?.id != me || hub.socket.status != SocketStatus.ready) {
      return app.show(T.text('ps3PartyUnavailable'));
    }
    bool canStart() => runningWorker == null ? _ps3LaunchAvailable : _canReusePs3Game(game, runningWorker, release);
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
    final attempt = _ps3Party = _Ps3PartyAttempt(runningWorker)..roomId = invite?.sessionId;
    bool active() =>
        identical(_ps3Party, attempt) &&
        !attempt.cancelled.isCompleted &&
        account.user?.id == me &&
        app.currentProfile?.id == owner;
    Future<void> refreshMembership(RetroRoom room) async {
      if (!active()) return;
      final request = ++attempt.membershipRequest;
      if (attempt.membership != _Ps3PartyMembership.checking) {
        attempt.membership = _Ps3PartyMembership.checking;
        app.refresh();
      }
      var membership = _Ps3PartyMembership.unavailable;
      try {
        final present = await rooms
            .hasInvitedMember(room, friendId ?? room.hostId)
            .timeout(const Duration(seconds: 12));
        membership = present ? _Ps3PartyMembership.present : _Ps3PartyMembership.waiting;
      } on Object {
        // A failed refresh is not evidence of who is in the room.
      }
      if (!active() || request != attempt.membershipRequest) return;
      attempt.membership = membership;
      app.refresh();
    }

    RetroRoom? room;
    Future<void>? launch;
    final quickJoin = runningWorker != null && invite != null && app.overlay == Layer.quickMenu;
    if (quickJoin) {
      app.refresh();
    } else if (runningWorker == null || invite != null) {
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
      final admitted = room;
      attempt.refreshMembership = () => refreshMembership(admitted);
      unawaited(refreshMembership(admitted));
      if (runningWorker == null) {
        launch = app.playVerifiedPs3Online(game, profile!, canBoot: active, party: attempt);
        await Future.any<void>([launch, attempt.cancelled.future]);
      } else {
        if (!canStart()) return app.show(T.text('ps3PartyBusy'));
        attempt.attached = true;
        if (invite != null && app.overlay == (quickJoin ? Layer.quickMenu : Layer.friends)) app.resumeGame();
        app.show(T.text(_ps3PartyHandoffKey(attempt, Ps3ProviderStatus.ready)));
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
