part of 'together_model.dart';

final class _Ps1InviteVerification {
  _Ps1InviteVerification(this.host);

  final EmbeddedRetroGame? host;
  final canceled = Completer<void>();
}

extension TogetherPs1Netplay on TogetherModel {
  bool get _ps1NetplayEnabled => environment['ANYPS5_PS1_NETPLAY'] == '1' && app.managedRetroAvailable;

  bool get ps1ProgressStalled => _ps1Match?.session?.progressStalled == true;

  void _cancelPs1InviteVerification() {
    final verification = _ps1InviteVerification;
    _ps1InviteVerification = null;
    verification?.canceled.complete();
  }

  List<PanelRow> ps1LocalLaunchRows(Game game) {
    if (!_ps1NetplayEnabled ||
        app.running != null ||
        app.starting != null ||
        _verifyingPs1 ||
        _ps1Match != null ||
        _ps2LanBusy) {
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
    if (_verifyingPs1 || _ps1Match != null || _ps2LanBusy) return;
    _verifyingPs1 = true;
    app.show(T.text('ps1OnlineVerifying'));
    app.refresh();
    bool idle() => app.running == null && app.starting == null && !app.stopping && app.managedSetupConsole == null;
    try {
      final bios = await app.preparePs1NetplayBios(canContinue: idle);
      if (bios == null || !idle()) return;
      final media = await app.verifyPs1Netplay(game, profile, bios: bios, requireHandoff: true);
      if (idle()) unawaited(app.playStagedPs1(game, media));
    } on Ps1NetplayMediaFailure catch (error) {
      _showPs1MediaError(error, handoff: true);
    } finally {
      _verifyingPs1 = false;
      app.refresh();
    }
  }

  List<PanelRow> ps1QuickRows() {
    if (!_ps1NetplayEnabled) return const [];
    if (_ps1Match != null) return ps1NetplayRows();
    final host = app.embeddedGame;
    if (host != null && identical(_ps1InviteVerification?.host, host)) return ps1NetplayRows();
    if (_verifyingPs1) return const [];
    if (host == null || _ps1HostMode(host, app.running?.$1) == null) return const [];
    return [
      PanelRow(
        id: 'ps1-invite-from-game',
        title: T.text('ps1OnlineCouch'),
        kind: ActionRow(() => app.open(Layer.ps1OnlineFriends)),
      ),
    ];
  }

  Ps1NetplayRoomMode? _ps1HostMode(EmbeddedRetroGame host, Game? game) {
    if (host.stagedNetplayMedia != null) return Ps1NetplayRoomMode.staged;
    final disc = game?.retro;
    if (!app.ordinaryPs1RecoveryPending &&
        host.canParkOrdinaryPs1 &&
        disc != null &&
        disc.platform == RetroPlatform.ps1 &&
        p.extension(disc.path).toLowerCase() == '.cue' &&
        Ps1NetplayProfile.tryRead(game?.retroSerial) != null) {
      return Ps1NetplayRoomMode.ordinary;
    }
    return null;
  }

  List<PanelRow> ps1InviteFriendRows() {
    final game = app.running?.$1;
    final host = app.embeddedGame;
    if (game == null || host == null) return const [];
    final mode = _ps1HostMode(host, game);
    final profile = Ps1NetplayProfile.tryRead(game.retroSerial);
    if (mode == null || profile == null) return const [];
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
            unawaited(_startPs1Netplay(profile, friendId: friend.person.id, host: host, mode: mode));
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
    if (_ps1InviteVerification case final verification?) {
      return [
        PanelRow(
          id: 'ps1-netplay-cancel-verification',
          title: T.text('ps1OnlineCancel'),
          detail: T.text('ps1OnlineVerifying'),
          kind: ActionRow(() {
            if (!identical(_ps1InviteVerification, verification)) return;
            _cancelPs1InviteVerification();
            app.refresh();
          }),
        ),
      ];
    }
    if (_ps1Match case final match?) {
      final session = match.session;
      final playing = session?.phase == Ps1NetplayPhase.running;
      final ending = match.closed || session?.phase == Ps1NetplayPhase.closed;
      return [
        if (ending)
          PanelRow(id: 'ps1-netplay-ending', title: T.text('ps1OnlineEnding'), kind: const InfoRow(''))
        else
          PanelRow(
            id: 'ps1-netplay-leave',
            title: T.text(playing ? 'ps1OnlineLeave' : 'ps1OnlineCancel'),
            detail: T.text(
              playing
                  ? (ps1ProgressStalled ? 'ps1OnlineSyncing' : 'ps1OnlinePlaying')
                  : session?.preparingGame == true
                  ? 'ps1OnlinePreparing'
                  : 'ps1OnlineWaiting',
            ),
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
        _ps2LanBusy ||
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
    final mode = Ps1NetplayRoomMode.tryRead(invite.gameVersion);
    if (profile == null || mode == null) {
      await _unsupportedRetroInvite();
      return;
    }
    await _startPs1Netplay(profile, roomId: invite.sessionId, mode: mode);
  }

  Future<void> _startPs1Netplay(
    Ps1NetplayProfile profile, {
    String? friendId,
    String? roomId,
    EmbeddedRetroGame? host,
    Game? selectedGame,
    Ps1NetplayRoomMode mode = Ps1NetplayRoomMode.fresh,
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
    if (_verifyingPs1 || _ps1Match != null || _ps2LanBusy || !hostAvailable()) return;
    _verifyingPs1 = true;
    final verification = _ps1InviteVerification = _Ps1InviteVerification(host);
    bool active() => identical(_ps1InviteVerification, verification) && account.user?.id == me && hostAvailable();
    Ps1NetplayMatch? opened;
    var holdingTransition = false;
    RetroOnlineRooms rooms([String? discDigest]) => RetroOnlineRooms(
      call: (method, path, [body]) {
        if (account.user?.id != me) throw StateError('The AnyTogether account changed.');
        return account.call(method, path, body);
      },
      me: me,
      spec: profile.roomFor(mode),
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
      app.refresh();
      if (!active()) return;
      final invitedDigest = roomId == null
          ? null
          : await Future.any<String?>([
              rooms().invitedDiscDigest(roomId),
              verification.canceled.future.then((_) => null),
            ]);
      if (!active()) return;
      if (roomId != null && invitedDigest == null) return app.show(T.text('ps1OnlineDisc'));
      final ordinaryHost = mode == Ps1NetplayRoomMode.ordinary ? host : null;
      final bios = ordinaryHost != null
          ? await ordinaryHost.ordinaryMatchBios()
          : host == null
          ? await app.preparePs1NetplayBios(canContinue: active)
          : null;
      if (!active() || (host == null && bios == null)) return;
      if (ordinaryHost != null && bios == null) return app.show(T.text('ps1OnlineBios'));
      final (game, media) = ordinaryHost != null
          ? (
              app.running!.$1,
              await Ps1NetplayMedia.verify(
                profile: profile,
                disc: app.running!.$1.retro!.path,
                bios: bios!,
                core: ordinaryHost.corePath,
                execution: mode.execution,
                canContinue: active,
              ),
            )
          : host != null
          ? (app.running!.$1, host.stagedNetplayMedia!)
          : selectedGame != null
          ? (selectedGame, await app.verifyPs1Netplay(selectedGame, profile, bios: bios!, canContinue: active))
          : await _verifiedPs1(profile, candidates, invitedDigest, bios: bios!, mode: mode, canContinue: active);
      if (!active()) return;
      if (mode.needsCheckpoint && !media.supportsHandoff) return app.show(T.text('ps1OnlineHandoffCore'));
      late final Ps1NetplayMatch match;
      final owned = EmbeddedPs1NetplayRunner(
        (seat) => app.preparePs1Netplay(game, media, seat, canBoot: () => !match.closed && account.user?.id == me),
      );
      final borrowed = host == null || ordinaryHost != null
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
      final switching = ordinaryHost == null
          ? null
          : OrdinaryPs1NetplayRunner(
              match: owned,
              park: () => ordinaryHost.captureOrdinaryNetplayCheckpoint(media, park: true),
              detach: () {
                holdingTransition = true;
                app.setOrdinaryPs1Transition(game);
                return ordinaryHost.detachOrdinaryCheckpoint();
              },
              unpark: ordinaryHost.resumeOrdinaryCheckpoint,
              drainWorker: app.waitForRetroWorkerExit,
              importMatch: owned.restoreCheckpoint,
              recover: (ticket) => app.restoreOrdinaryPs1(game, ticket, ordinaryHost.corePath, ordinaryHost.sourceHome),
            );
      match = Ps1NetplayMatch(
        rooms: rooms(roomId == null ? media.discDigest : invitedDigest),
        links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
        identity: media.identity,
        runner: switching ?? borrowed ?? owned,
        captureCheckpoint: switching?.capture ?? borrowed?.capture,
        catchupSource: borrowed?.source,
        restoreCheckpoint: mode.needsCheckpoint && host == null ? owned.restoreCheckpoint : null,
        catchupReplay: mode == Ps1NetplayRoomMode.staged && host == null ? owned.replayHistory : null,
        onStatusChanged: app.refresh,
      );
      _ps1Match = opened = match;
      _ps1InviteVerification = null;
      if (host != null) {
        unawaited(
          host.exitCode.then((_) async {
            if (switching?.detaching != true) await match.leave();
          }),
        );
      }
      app.refresh();
      if (roomId != null) {
        await match.join(roomId);
        unawaited(hub.games.refresh().catchError((Object _) {}));
      } else {
        await match.host(friendId!);
      }
      await match.done;
      if (switching != null && app.ordinaryPs1RecoveryPending) {
        app.show(T.text('ps1OnlineReturnFailed'));
        return;
      }
      final session = match.session;
      switch (session?.ended) {
        case Ps1NetplayEnd.mismatch:
          app.show(
            T.text(switch (session?.mismatch) {
              Ps1NetplayMismatch.version => 'ps1OnlineMismatchVersion',
              Ps1NetplayMismatch.title => 'ps1OnlineMismatchTitle',
              Ps1NetplayMismatch.disc => 'ps1OnlineMismatchDisc',
              Ps1NetplayMismatch.bios => 'ps1OnlineBios',
              Ps1NetplayMismatch.core => 'ps1OnlineMismatchCore',
              Ps1NetplayMismatch.profile => 'ps1OnlineMismatchProfile',
              Ps1NetplayMismatch.card => 'ps1OnlineMismatchCard',
              null => 'ps1OnlineMismatch',
            }),
          );
        case Ps1NetplayEnd.desync:
          app.show(T.text('ps1OnlineDesync'));
        case Ps1NetplayEnd.runner || Ps1NetplayEnd.protocol || Ps1NetplayEnd.disconnected || Ps1NetplayEnd.timedOut:
          app.show(T.text('ps1OnlineDisconnected'));
        default:
          break;
      }
    } on Ps1NetplayMediaFailure catch (error) {
      if (opened != null || active()) _showPs1MediaError(error, handoff: mode.needsCheckpoint);
    } on Object {
      if (opened != null || active()) app.show(T.text('ps1OnlineDisconnected'));
    } finally {
      if (holdingTransition) app.setOrdinaryPs1Transition(null);
      if (identical(_ps1Match, opened)) _ps1Match = null;
      if (identical(_ps1InviteVerification, verification)) _ps1InviteVerification = null;
      _verifyingPs1 = false;
      app.refresh();
    }
  }

  void _showPs1MediaError(Ps1NetplayMediaFailure error, {required bool handoff}) => app.show(
    T.text(switch (error.problem) {
      Ps1NetplayMediaProblem.disc => 'ps1OnlineDisc',
      Ps1NetplayMediaProblem.bios => 'ps1OnlineBios',
      Ps1NetplayMediaProblem.core => handoff ? 'ps1OnlineHandoffCore' : 'ps1OnlineCore',
    }),
  );

  Future<(Game, Ps1NetplayMedia)> _verifiedPs1(
    Ps1NetplayProfile profile,
    List<Game> candidates,
    String? invitedDigest, {
    required String bios,
    required Ps1NetplayRoomMode mode,
    required bool Function() canContinue,
  }) async {
    for (final game in candidates) {
      try {
        final media = await app.verifyPs1Netplay(
          game,
          profile,
          bios: bios,
          requireHandoff: mode.needsCheckpoint,
          execution: mode.execution,
          canContinue: canContinue,
        );
        if (invitedDigest == null || media.discDigest == invitedDigest) return (game, media);
      } on Ps1NetplayMediaFailure catch (error) {
        if (error.problem != Ps1NetplayMediaProblem.disc) rethrow;
      }
    }
    throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
  }
}
