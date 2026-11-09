part of 'together_model.dart';

extension TogetherPs1Netplay on TogetherModel {
  bool get _ps1NetplayEnabled => environment['ANYPS5_PS1_NETPLAY'] == '1' && app.managedRetroAvailable;

  List<PanelRow> ps1LocalLaunchRows(Game game) {
    if (!_ps1NetplayEnabled ||
        app.running != null ||
        app.starting != null ||
        _verifyingPs1 ||
        _ps1Match != null ||
        _ps2Lan != null) {
      return const [];
    }
    final profile = Ps1NetplayProfile.tryRead(game.retroSerial);
    if (profile == null) return const [];
    return [
      PanelRow(
        id: 'ps1-online-ready',
        title: T.text('ps1OnlineReady'),
        detail: T.text('ps1OnlineReadyDetail'),
        kind: ActionRow(() => unawaited(_launchPs1Local(game, profile))),
      ),
    ];
  }

  Future<void> _launchPs1Local(Game game, Ps1NetplayProfile profile) async {
    if (_verifyingPs1 || _ps1Match != null || _ps2Lan != null) return;
    _verifyingPs1 = true;
    app.show(T.text('ps1OnlineVerifying'));
    app.refresh();
    try {
      final media = await app.verifyPs1Netplay(game, profile);
      if (!media.supportsHandoff) return app.show(T.text('ps1OnlineCore'));
      unawaited(app.playStagedPs1(game, media));
    } on Ps1NetplayMediaFailure catch (error) {
      _showPs1MediaError(error);
    } finally {
      _verifyingPs1 = false;
      app.refresh();
    }
  }

  List<PanelRow> ps1QuickRows() {
    if (!_ps1NetplayEnabled || app.embeddedGame?.isNetplay != true) return const [];
    if (_ps1Match != null) return ps1NetplayRows();
    if (app.embeddedGame?.stagedNetplayMedia == null) return const [];
    return [
      PanelRow(
        id: 'ps1-invite-from-game',
        title: T.text('ps1OnlineCouch'),
        kind: ActionRow(() => app.open(Layer.ps1OnlineFriends)),
      ),
    ];
  }

  List<PanelRow> ps1InviteFriendRows() {
    final game = app.running?.$1;
    final host = app.embeddedGame;
    final media = host?.stagedNetplayMedia;
    final titleId = media?.identity.toJson()['title'];
    final profile = titleId is String ? Ps1NetplayProfile.tryRead(titleId) : null;
    if (game == null || host == null || profile == null) return const [];
    final online = hub.friends.friends.where((friend) => friend.presence.online).toList();
    if (account.user == null || hub.socket.status != SocketStatus.ready || online.isEmpty) {
      return [
        PanelRow(
          id: 'ps1-invite-empty',
          title: T.text('ps1OnlineCouch'),
          kind: InfoRow(
            T.text(
              account.user == null || hub.socket.status != SocketStatus.ready
                  ? 'ps1OnlineUnavailable'
                  : 'ps1OnlineNoFriends',
            ),
          ),
        ),
      ];
    }
    return [
      for (final friend in online)
        PanelRow(
          id: 'ps1-invite-${friend.person.id}',
          title: friend.person.displayName,
          detail: T.text('ps1OnlineInviteDetail'),
          kind: ActionRow(() {
            app.resumeGame();
            unawaited(_startPs1Netplay(profile, friendId: friend.person.id, host: host, handoff: true));
          }),
        ),
    ];
  }

  Iterable<Game> _ps1Candidates(Ps1NetplayProfile profile) => app.games.where((game) {
    final disc = game.retro;
    return disc != null &&
        disc.platform == RetroPlatform.ps1 &&
        p.extension(disc.path).toLowerCase() == '.cue' &&
        game.retroSerial == profile.titleId;
  });

  List<PanelRow> ps1NetplayRows() {
    if (!_ps1NetplayEnabled) return const [];
    if (_ps1Match case final match?) {
      final playing = match.session?.phase == Ps1NetplayPhase.running;
      return [
        PanelRow(
          id: 'ps1-netplay-leave',
          title: T.text(playing ? 'ps1OnlineLeave' : 'ps1OnlineCancel'),
          detail: T.text(playing ? 'ps1OnlinePlaying' : 'ps1OnlineWaiting'),
          kind: ActionRow(() => unawaited(match.leave()), destructive: true),
        ),
      ];
    }
    return const [];
  }

  List<PanelRow> ps1NetplayInvites(Friend friend) {
    if (!_ps1NetplayEnabled ||
        !friend.presence.online ||
        _ps1Match != null ||
        _ps2Lan != null ||
        _verifyingPs1 ||
        app.running != null ||
        app.starting != null) {
      return const [];
    }
    final selected = app.selectedGame;
    final profile = Ps1NetplayProfile.tryRead(selected?.retroSerial);
    if (selected == null || profile == null) return const [];
    return [
      PanelRow(
        id: 'ps1-netplay-host-${profile.titleId}',
        title: T.format('ps1OnlineInvite', [selected.name]),
        detail: T.text('ps1OnlineInviteDetail'),
        kind: ActionRow(() {
          app.open(Layer.friends);
          unawaited(_startPs1Netplay(profile, friendId: friend.person.id, selectedGame: selected));
        }),
      ),
    ];
  }

  Future<void> _unsupportedRetroInvite() async => app.show(T.text('retroOnlineUnavailable'));

  Future<void> joinPs1Netplay(GameInvite invite) async {
    final profile = Ps1NetplayProfile.tryRead(invite.titleId);
    if (profile == null ||
        (invite.gameVersion != profile.room.gameVersion && invite.gameVersion != profile.handoffRoom.gameVersion)) {
      await _unsupportedRetroInvite();
      return;
    }
    await _startPs1Netplay(
      profile,
      roomId: invite.sessionId,
      handoff: invite.gameVersion == profile.handoffRoom.gameVersion,
    );
  }

  Future<void> _startPs1Netplay(
    Ps1NetplayProfile profile, {
    String? friendId,
    String? roomId,
    EmbeddedRetroGame? host,
    Game? selectedGame,
    bool handoff = false,
  }) async {
    final me = account.user?.id;
    final candidates = _ps1Candidates(profile).toList();
    if (!_ps1NetplayEnabled || me == null || hub.socket.status != SocketStatus.ready) {
      app.show(T.text('ps1OnlineUnavailable'));
      return;
    }
    if (host == null && candidates.isEmpty) {
      app.show(T.text('ps1OnlineDisc'));
      return;
    }
    bool hostAvailable() =>
        !app.stopping &&
        app.starting == null &&
        (host == null ? app.running == null : identical(app.embeddedGame, host));
    if (_verifyingPs1 || _ps1Match != null || _ps2Lan != null || !hostAvailable()) return;
    _verifyingPs1 = true;
    app.show(T.text('ps1OnlineVerifying'));
    Ps1NetplayMatch? opened;
    RetroOnlineRooms rooms([String? discDigest]) => RetroOnlineRooms(
      call: account.call,
      me: me,
      spec: handoff ? profile.handoffRoom : profile.room,
      discDigest: discDigest,
      signal: (to, device, sessionId, kind, data) {
        if (!hub.socket.send(
          OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data),
        )) {
          throw StateError('The AnyTogether connection closed.');
        }
      },
    );
    try {
      final invitedDigest = roomId == null ? null : await rooms().invitedDiscDigest(roomId);
      if (account.user?.id != me || !hostAvailable()) return;
      final (game, media) = host != null
          ? (app.running!.$1, host.stagedNetplayMedia!)
          : selectedGame != null
          ? (selectedGame, await app.verifyPs1Netplay(selectedGame, profile))
          : await _verifiedPs1(profile, candidates, invitedDigest);
      if (account.user?.id != me || !hostAvailable()) return;
      if (handoff && !media.supportsHandoff) return app.show(T.text('ps1OnlineCore'));
      late final Ps1NetplayMatch match;
      final owned = EmbeddedPs1NetplayRunner(
        (seat) => app.preparePs1Netplay(game, media, seat, canBoot: () => !match.closed && account.user?.id == me),
      );
      final borrowed = host == null
          ? null
          : Ps1LocalHandoff(
              ready: () => host.netplayReady,
              capture: host.captureNetplayCheckpoint,
              hold: host.holdNetplayForCutover,
              read: host.readNetplayHistory,
              resume: host.resumeLocalNetplay,
              begin: host.startNetplayFrames,
              exchange: host.exchangeNetplayFrames,
            );
      match = Ps1NetplayMatch(
        rooms: rooms(roomId == null ? media.discDigest : invitedDigest),
        links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
        identity: media.identity,
        runner: borrowed ?? owned,
        captureCheckpoint: borrowed?.capture,
        catchupSource: borrowed?.source,
        restoreCheckpoint: handoff && host == null ? owned.restoreCheckpoint : null,
        catchupReplay: handoff && host == null ? owned.replayHistory : null,
        onRunning: app.refresh,
      );
      _ps1Match = opened = match;
      if (host != null) unawaited(host.exitCode.then((_) => match.leave()));
      app.refresh();
      if (roomId != null) {
        await match.join(roomId);
        unawaited(hub.games.refresh().catchError((Object _) {}));
      } else {
        await match.host(friendId!);
      }
      await match.done;
      switch (match.session?.ended) {
        case Ps1NetplayEnd.mismatch:
          app.show(T.text('ps1OnlineMismatch'));
        case Ps1NetplayEnd.desync:
          app.show(T.text('ps1OnlineDesync'));
        case Ps1NetplayEnd.runner || Ps1NetplayEnd.protocol || Ps1NetplayEnd.disconnected || Ps1NetplayEnd.timedOut:
          app.show(T.text('ps1OnlineDisconnected'));
        default:
          break;
      }
    } on Ps1NetplayMediaFailure catch (error) {
      _showPs1MediaError(error);
    } on Object {
      app.show(T.text('ps1OnlineDisconnected'));
    } finally {
      if (identical(_ps1Match, opened)) _ps1Match = null;
      _verifyingPs1 = false;
      app.refresh();
    }
  }

  void _showPs1MediaError(Ps1NetplayMediaFailure error) => app.show(
    T.text(switch (error.problem) {
      Ps1NetplayMediaProblem.disc => 'ps1OnlineDisc',
      Ps1NetplayMediaProblem.bios => 'ps1OnlineBios',
      Ps1NetplayMediaProblem.core => 'ps1OnlineCore',
    }),
  );

  Future<(Game, Ps1NetplayMedia)> _verifiedPs1(
    Ps1NetplayProfile profile,
    List<Game> candidates,
    String? invitedDigest,
  ) async {
    for (final game in candidates) {
      try {
        final media = await app.verifyPs1Netplay(game, profile);
        if (invitedDigest == null || media.discDigest == invitedDigest) return (game, media);
      } on Ps1NetplayMediaFailure catch (error) {
        if (error.problem != Ps1NetplayMediaProblem.disc) rethrow;
      }
    }
    throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
  }
}
