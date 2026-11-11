part of 'together_model.dart';

final class _Ps1InviteVerification {
  _Ps1InviteVerification(this.host);

  final EmbeddedRetroGame? host;
  final canceled = Completer<void>();
}

extension TogetherPs1Netplay on TogetherModel {
  bool get _ps1NetplayEnabled => environment['ANYPS5_PS1_NETPLAY'] == '1' && app.embeddedOnlineRetroAvailable;
  bool get _ps1RollbackEnabled => environment['ANYPS5_PS1_ROLLBACK'] == '1';

  Ps1NetplayRoomMode get _ps1FreshMode => !app.managedRetroAvailable || _ps1RollbackEnabled
      ? Ps1NetplayRoomMode.mixedRollback
      : Ps1NetplayRoomMode.freshAnalog;

  bool _ps1SupportsMode(Ps1NetplayRoomMode mode) => app.managedRetroAvailable
      ? !mode.execution.usesPresentationCore || _ps1RollbackEnabled
      : mode == Ps1NetplayRoomMode.mixedRollback;

  bool get ps1ProgressStalled => _ps1Match?.session?.progressStalled == true;

  void _cancelPs1InviteVerification() {
    final verification = _ps1InviteVerification;
    _ps1InviteVerification = null;
    verification?.canceled.complete();
  }

  List<PanelRow> ps1LocalLaunchRows(Game game) {
    if (!_ps1NetplayEnabled ||
        !app.managedRetroAvailable ||
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
        kind: ActionRow(() => app.open(Layer.retroOnlineFriends)),
      ),
    ];
  }

  Ps1NetplayRoomMode? _ps1HostMode(EmbeddedRetroGame host, Game? game) {
    if (!app.managedRetroAvailable) return null;
    if (host.stagedNetplayMedia != null) return Ps1NetplayRoomMode.staged;
    final disc = game?.retro;
    if (!app.ordinaryPs1RecoveryPending &&
        host.canParkOrdinaryPs1 &&
        disc != null &&
        disc.platform == RetroPlatform.ps1 &&
        p.extension(disc.path).toLowerCase() == '.cue' &&
        Ps1NetplayProfile.tryRead(game?.retroSerial) != null) {
      return _ps1RollbackEnabled ? Ps1NetplayRoomMode.rollbackHandoff : Ps1NetplayRoomMode.ordinary;
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
    return _retroInviteFriendRows(
      prefix: 'ps1-invite',
      title: 'ps1OnlineCouch',
      detail: 'ps1OnlineInviteDetail',
      unavailable: 'ps1OnlineUnavailable',
      invite: (friend) {
        app.resumeGame();
        unawaited(_startPs1Netplay(profile, friendId: friend.person.id, localWorker: host, mode: mode));
      },
    );
  }

  bool _ps1Candidate(Game game, Ps1NetplayProfile profile) {
    final disc = game.retro;
    return disc != null &&
        disc.platform == RetroPlatform.ps1 &&
        p.extension(disc.path).toLowerCase() == '.cue' &&
        game.retroSerial == profile.titleId;
  }

  Iterable<Game> _ps1Candidates(Ps1NetplayProfile profile) => app.games.where((game) => _ps1Candidate(game, profile));

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
      final path = playing && !ps1ProgressStalled ? match.connectionPath : null;
      return [
        if (ending)
          PanelRow(id: 'ps1-netplay-ending', title: T.text('ps1OnlineEnding'), kind: const InfoRow(''))
        else
          PanelRow(
            id: 'ps1-netplay-leave',
            title: T.text(playing ? 'ps1OnlineLeave' : 'ps1OnlineCancel'),
            detail: [
              T.text(
                playing
                    ? (ps1ProgressStalled ? 'ps1OnlineSyncing' : 'ps1OnlinePlaying')
                    : session?.preparingGame == true
                    ? 'ps1OnlinePreparing'
                    : match.hasMatchedPlayer
                    ? 'ps1OnlineConnecting'
                    : 'ps1OnlineWaiting',
              ),
              if (path?.relayed case final relayed?) T.text(relayed ? 'sharePlayRelayed' : 'sharePlayDirect'),
              if (path?.roundTripMs case final roundTrip?) T.format('sharePlayRoundTrip', [roundTrip]),
            ].join(' · '),
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
      for (final mode in [
        _ps1FreshMode,
        if (app.managedRetroAvailable && _ps1RollbackEnabled) Ps1NetplayRoomMode.rollbackPreview,
      ])
        PanelRow(
          id: mode == Ps1NetplayRoomMode.rollbackPreview
              ? 'ps1-netplay-rollback-${profile.titleId}'
              : 'ps1-netplay-host-${profile.titleId}',
          title: T.format(mode == Ps1NetplayRoomMode.rollbackPreview ? 'ps1OnlineRollbackInvite' : 'ps1OnlineInvite', [
            selected.name,
          ]),
          detail: T.text('ps1OnlineInviteDetail'),
          kind: ActionRow(() {
            app.open(Layer.friends);
            unawaited(_startPs1Netplay(profile, friendId: friend.person.id, selectedGame: selected, mode: mode));
          }),
        ),
    ];
  }

  PanelRow? ps1NetplayDashboardLink(Game game, void Function(PanelCategory Function()) open) {
    final profile = Ps1NetplayProfile.tryRead(game.retroSerial);
    if (profile == null || !_ps1Candidate(game, profile)) return null;
    bool available() =>
        _ps1NetplayEnabled &&
        _ps1Match == null &&
        !_ps2LanBusy &&
        !_verifyingPs1 &&
        app.running == null &&
        app.starting == null &&
        !app.stopping &&
        app.managedSetupConsole == null;
    if (!available()) return null;
    return _retroDashboardInviteLink(
      game,
      open,
      prefix: 'ps1-netplay-dashboard',
      title: 'ps1OnlineCouch',
      detail: 'ps1OnlineInviteDetail',
      unavailable: 'ps1OnlineUnavailable',
      available: available,
      invite: (friend) {
        app.open(Layer.friends);
        unawaited(_startPs1Netplay(profile, friendId: friend.person.id, selectedGame: game, mode: _ps1FreshMode));
      },
    );
  }

  Future<void> _unsupportedRetroInvite() async => app.show(T.text('retroOnlineUnavailable'));

  EmbeddedRetroGame? _ps1GuestWorker(GameInvite invite) {
    final game = app.running?.$1;
    final worker = app.embeddedGame;
    final mode = Ps1NetplayRoomMode.tryRead(invite.gameVersion);
    if (!_ps1NetplayEnabled ||
        _verifyingPs1 ||
        _ps1Match != null ||
        _ps2LanBusy ||
        app.stopping ||
        app.starting != null ||
        game?.retroSerial != invite.titleId ||
        worker == null ||
        mode == null ||
        (mode.execution.usesRollback && !mode.handoffFromOrdinary) ||
        !_ps1SupportsMode(mode) ||
        _ps1HostMode(worker, game)?.handoffFromOrdinary != true) {
      return null;
    }
    return worker;
  }

  Future<void> joinPs1Netplay(GameInvite invite) async {
    final profile = Ps1NetplayProfile.tryRead(invite.titleId);
    final mode = Ps1NetplayRoomMode.tryRead(invite.gameVersion);
    if (profile == null || mode == null) {
      await _unsupportedRetroInvite();
      return;
    }
    if (!_ps1NetplayEnabled) return app.show(T.text('ps1OnlineUnavailable'));
    if (!_ps1SupportsMode(mode)) {
      await _unsupportedRetroInvite();
      return;
    }
    final worker = _ps1GuestWorker(invite);
    if (_ps1NetplayEnabled && worker == null && app.running != null && !_verifyingPs1 && _ps1Match == null) {
      return app.show(T.text('closeGameFirst'));
    }
    await _startPs1Netplay(
      profile,
      roomId: invite.sessionId,
      expectedHost: invite.from?.id,
      localWorker: worker,
      mode: mode,
    );
  }

  Future<void> _startPs1Netplay(
    Ps1NetplayProfile profile, {
    String? friendId,
    String? roomId,
    String? expectedHost,
    EmbeddedRetroGame? localWorker,
    Game? selectedGame,
    required Ps1NetplayRoomMode mode,
  }) async {
    final me = account.user?.id;
    final owner = app.currentProfile?.id;
    final candidates = _ps1Candidates(profile).toList();
    if (!_ps1NetplayEnabled || !_ps1SupportsMode(mode) || me == null || hub.socket.status != SocketStatus.ready) {
      app.show(T.text('ps1OnlineUnavailable'));
      return;
    }
    if (localWorker == null && candidates.isEmpty) {
      app.show(T.text('ps1OnlineDisc'));
      return;
    }
    bool hostAvailable() =>
        !app.stopping &&
        app.starting == null &&
        (localWorker == null ? app.running == null : identical(app.embeddedGame, localWorker));
    if (_verifyingPs1 || _ps1Match != null || _ps2LanBusy || !hostAvailable()) return;
    _verifyingPs1 = true;
    final verification = _ps1InviteVerification = _Ps1InviteVerification(localWorker);
    bool active() =>
        identical(_ps1InviteVerification, verification) &&
        account.user?.id == me &&
        app.currentProfile?.id == owner &&
        hostAvailable();
    final timeoutMessage = roomId == null ? 'retroConnectionTimeoutHost' : 'retroConnectionTimeoutGuest';
    Ps1NetplayMatch? opened;
    var holdingTransition = false;
    String? expectedCore;
    RetroOnlineRooms rooms({String? discDigest, String? coreDigest}) => RetroOnlineRooms(
      call: (method, path, [body]) {
        if (account.user?.id != me) throw StateError('The AnyTogether account changed.');
        return account.call(method, path, body);
      },
      me: me,
      spec: profile.roomFor(mode),
      discDigest: discDigest,
      coreDigest: coreDigest,
      signal: (to, device, sessionId, kind, data) {
        if (!hub.socket.send(
          OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data),
        )) {
          throw StateError('The AnyTogether connection closed.');
        }
      },
    );
    try {
      if (localWorker != null && roomId != null) app.resumeGame();
      app.refresh();
      if (!active()) return;
      final invite = roomId == null
          ? null
          : await Future.any<RetroRoomInvite?>([
              rooms().readInvite(roomId, expectedHost: expectedHost),
              verification.canceled.future.then((_) => null),
            ]);
      if (!active()) return;
      final invitedDigest = invite?.disc;
      if (mode.freshFromDisc) expectedCore = invite?.core;
      if (expectedCore != null && !mode.execution.coreDigests.contains(expectedCore)) {
        return app.show(T.text('ps1OnlineMismatchCore'));
      }
      if (roomId != null && invitedDigest == null) return app.show(T.text('ps1OnlineDisc'));
      final ordinaryWorker = roomId != null || mode.handoffFromOrdinary ? localWorker : null;
      final bios = ordinaryWorker != null
          ? await ordinaryWorker.ordinaryMatchBios()
          : localWorker == null
          ? await app.preparePs1NetplayBios(canContinue: active)
          : null;
      if (!active() || (localWorker == null && bios == null)) return;
      if (ordinaryWorker != null && bios == null) return app.show(T.text('ps1OnlineBios'));
      final runningGame = localWorker == null ? null : app.running!.$1;
      final sourceMedia = ordinaryWorker == null
          ? null
          : await Ps1NetplayMedia.verify(
              profile: profile,
              disc: runningGame!.retro!.path,
              bios: bios!,
              resolveCore: () => ordinaryWorker.corePath,
              execution: Ps1NetplayExecution.ordinaryHandoff,
              canContinue: active,
            );
      if (!active()) return;
      if (invitedDigest != null && sourceMedia != null && sourceMedia.discDigest != invitedDigest) {
        return app.show(T.text('ps1OnlineMismatchDisc'));
      }
      final (game, media) = sourceMedia != null
          ? (
              runningGame!,
              mode == Ps1NetplayRoomMode.ordinary
                  ? sourceMedia
                  : await sourceMedia.withVerifiedCore(
                      await app.resolvePs1NetplayCore(
                        mode.execution,
                        requireHandoff: mode.needsCheckpoint,
                        expectedCore: expectedCore,
                      ),
                      mode.execution,
                      canContinue: active,
                    ),
            )
          : localWorker != null
          ? (runningGame!, localWorker.stagedNetplayMedia!)
          : selectedGame != null
          ? (
              selectedGame,
              await app.verifyPs1Netplay(
                selectedGame,
                profile,
                bios: bios!,
                execution: mode.execution,
                requireHandoff: mode.needsCheckpoint,
                preferPortable: mode.freshFromDisc && roomId == null,
                canContinue: active,
              ),
            )
          : await _verifiedPs1(
              profile,
              candidates,
              invitedDigest,
              bios: bios!,
              mode: mode,
              expectedCore: expectedCore,
              canContinue: active,
            );
      if (!active()) return;
      if (invitedDigest != null && media.discDigest != invitedDigest) {
        return app.show(T.text('ps1OnlineMismatchDisc'));
      }
      if (expectedCore != null && media.coreDigest != expectedCore) {
        return app.show(T.text('ps1OnlineMismatchCore'));
      }
      if (mode.needsCheckpoint && !media.supportsHandoff) return app.show(T.text('ps1OnlineHandoffCore'));
      late final Ps1NetplayMatch match;
      var triedContinuation = false;
      var continuedFromMatch = false;
      final owned = EmbeddedPs1NetplayRunner(
        (seat) => app.preparePs1Netplay(game, media, seat, canBoot: () => !match.closed && account.user?.id == me),
      );
      final borrowed = localWorker == null || ordinaryWorker != null
          ? null
          : Ps1LocalHandoff(
              ready: () => localWorker.netplayReady,
              capture: localWorker.captureNetplayCheckpoint,
              hold: localWorker.holdNetplayForCutover,
              read: localWorker.readNetplayHistory,
              resume: localWorker.resumeLocalNetplay,
              begin: localWorker.startNetplayFrames,
              exchange: localWorker.exchangeNetplayFrames,
            );
      final switching = ordinaryWorker == null
          ? null
          : OrdinaryPs1NetplayRunner(
              match: owned,
              park: () => ordinaryWorker.captureOrdinaryNetplayCheckpoint(sourceMedia!, park: true),
              detach: () {
                holdingTransition = true;
                app.setOrdinaryPs1Transition(game);
                return ordinaryWorker.detachOrdinaryCheckpoint();
              },
              unpark: ordinaryWorker.resumeOrdinaryCheckpoint,
              drainWorker: app.waitForRetroWorkerExit,
              importMatch: owned.restoreCheckpoint,
              preserveProgress: roomId == null && mode == Ps1NetplayRoomMode.rollbackHandoff
                  ? (ticket) async {
                      if (app.stopping) return;
                      switch (match.session?.ended) {
                        case Ps1NetplayEnd.left ||
                            Ps1NetplayEnd.peerLeft ||
                            Ps1NetplayEnd.disconnected ||
                            Ps1NetplayEnd.timedOut:
                          triedContinuation = true;
                          await owned.preserveConfirmedProgress(ticket);
                        default:
                          break;
                      }
                    }
                  : null,
              recover: (ticket) async {
                continuedFromMatch = await app.restoreOrdinaryPs1(
                  game,
                  ticket,
                  ordinaryWorker.corePath,
                  ordinaryWorker.sourceHome,
                );
              },
            );
      match = Ps1NetplayMatch(
        rooms: rooms(
          discDigest: roomId == null ? media.discDigest : invitedDigest,
          coreDigest: mode.freshFromDisc && roomId == null ? media.coreDigest : expectedCore,
        ),
        links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
        identity: media.identity,
        runner: switching ?? borrowed ?? owned,
        captureCheckpoint: switching?.capture ?? borrowed?.capture,
        catchupSource: borrowed?.source,
        restoreCheckpoint: mode.needsCheckpoint && roomId != null ? owned.restoreCheckpoint : null,
        catchupReplay: mode == Ps1NetplayRoomMode.staged && roomId != null ? owned.replayHistory : null,
        onStatusChanged: app.refresh,
      );
      _ps1Match = opened = match;
      _ps1InviteVerification = null;
      if (localWorker != null) {
        unawaited(
          localWorker.exitCode.then((_) async {
            if (switching?.detaching != true) await match.leave();
          }),
        );
      }
      app.refresh();
      if (roomId != null) {
        await match.join(roomId, expectedHost: invite!.room.hostId);
        unawaited(hub.games.refresh().catchError((Object _) {}));
      } else {
        await match.host(friendId!);
      }
      await match.done;
      if (switching != null && app.ordinaryPs1RecoveryPending) {
        app.show(T.text('ps1OnlineReturnFailed'));
        return;
      }
      if (triedContinuation && !continuedFromMatch) {
        app.show(T.text('ps1OnlineReturnedToStart'));
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
        case Ps1NetplayEnd.startupTimedOut:
          app.show(T.text(timeoutMessage));
        case Ps1NetplayEnd.desync:
          app.show(T.text('ps1OnlineDesync'));
        case Ps1NetplayEnd.runner || Ps1NetplayEnd.protocol || Ps1NetplayEnd.disconnected || Ps1NetplayEnd.timedOut:
          app.show(T.text('ps1OnlineDisconnected'));
        default:
          break;
      }
    } on Ps1NetplayMediaFailure catch (error) {
      if (opened != null || active()) {
        if (expectedCore != null && error.problem == Ps1NetplayMediaProblem.core) {
          app.show(T.text('ps1OnlineMismatchCore'));
        } else if (mode.execution.usesPresentationCore && error.problem == Ps1NetplayMediaProblem.core) {
          app.show(T.text('ps1OnlineRollbackCore'));
        } else {
          _showPs1MediaError(error, handoff: mode.needsCheckpoint);
        }
      }
    } on RetroRoomHostMismatch {
      if (opened != null || active()) app.show(T.text('retroInviteHostChanged'));
    } on RetroInviteSendTimeout {
      if (opened != null || active()) app.show(T.text('retroInviteSendTimeout'));
    } on RetroRoomStatusTimeout {
      if (opened != null || active()) app.show(T.text('retroRoomStatusTimeout'));
    } on RetroRoomOccupied {
      if (opened != null || active()) app.show(T.text('retroRoomOccupied'));
    } on RetroConnectionTimeout {
      if (opened != null || active()) app.show(T.text(timeoutMessage));
    } on RetroRoomLookupTimeout {
      if (opened != null || active()) app.show(T.text('retroInviteLookupTimeout'));
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

  void _showPs1MediaError(Ps1NetplayMediaFailure error, {required bool handoff}) {
    final message = switch (error.problem) {
      Ps1NetplayMediaProblem.disc => 'ps1OnlineDisc',
      Ps1NetplayMediaProblem.bios => 'ps1OnlineBios',
      Ps1NetplayMediaProblem.core => handoff ? 'ps1OnlineHandoffCore' : 'ps1OnlineCore',
      Ps1NetplayMediaProblem.package => 'ps1OnlinePackageInvalid',
      Ps1NetplayMediaProblem.canceled => null,
    };
    if (message != null) app.show(T.text(message));
  }

  Future<(Game, Ps1NetplayMedia)> _verifiedPs1(
    Ps1NetplayProfile profile,
    List<Game> candidates,
    String? invitedDigest, {
    required String bios,
    required Ps1NetplayRoomMode mode,
    required String? expectedCore,
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
          expectedCore: expectedCore,
          expectedDisc: invitedDigest,
          canContinue: canContinue,
        );
        return (game, media);
      } on Ps1NetplayMediaFailure catch (error) {
        if (error.problem != Ps1NetplayMediaProblem.disc) rethrow;
      }
    }
    throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
  }
}
