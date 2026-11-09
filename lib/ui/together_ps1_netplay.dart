part of 'together_model.dart';

extension TogetherPs1Netplay on TogetherModel {
  bool get _ps1NetplayEnabled => environment['ANYPS5_PS1_NETPLAY'] == '1' && app.managedRetroAvailable;

  Iterable<Game> _ps1Candidates(Ps1NetplayProfile profile) => app.games.where((game) {
    final disc = game.retro;
    return disc != null &&
        disc.platform == RetroPlatform.ps1 &&
        p.extension(disc.path).toLowerCase() == '.cue' &&
        profile.hintsAt(serial: game.titleId, name: game.name);
  });

  List<PanelRow> ps1NetplayRows() {
    if (!_ps1NetplayEnabled) return const [];
    if (_ps1Match case final match?) {
      return [
        PanelRow(
          id: 'ps1-netplay-leave',
          title: T.text('ps1OnlineLeave'),
          detail: T.text(match.session?.phase == Ps1NetplayPhase.running ? 'ps1OnlinePlaying' : 'ps1OnlineWaiting'),
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
        _verifyingPs1 ||
        app.running != null ||
        app.starting != null) {
      return const [];
    }
    return [
      for (final profile in Ps1NetplayProfile.qualified)
        if (_ps1Candidates(profile).isNotEmpty)
          PanelRow(
            id: 'ps1-netplay-host-${profile.titleId}',
            title: T.format('ps1OnlineInvite', [profile.title]),
            detail: T.text('ps1OnlineInviteDetail'),
            kind: ActionRow(() {
              app.open(Layer.friends);
              unawaited(_startPs1Netplay(profile, friendId: friend.person.id));
            }),
          ),
    ];
  }

  Future<void> _unsupportedRetroInvite() async => app.show(T.text('retroOnlineUnavailable'));

  Future<void> joinPs1Netplay(GameInvite invite) async {
    final profile = Ps1NetplayProfile.qualified.where((item) => item.titleId == invite.titleId).firstOrNull;
    if (profile == null || invite.gameVersion != profile.room.gameVersion) {
      await _unsupportedRetroInvite();
      return;
    }
    await _startPs1Netplay(profile, roomId: invite.sessionId);
  }

  Future<void> _startPs1Netplay(Ps1NetplayProfile profile, {String? friendId, String? roomId}) async {
    final me = account.user?.id;
    final candidates = _ps1Candidates(profile).toList();
    if (!_ps1NetplayEnabled || me == null || hub.socket.status != SocketStatus.ready) {
      app.show(T.text('ps1OnlineUnavailable'));
      return;
    }
    if (candidates.isEmpty) {
      app.show(T.text('ps1OnlineDisc'));
      return;
    }
    if (_verifyingPs1 || _ps1Match != null || app.starting != null || app.running != null) return;
    _verifyingPs1 = true;
    app.show(T.text('ps1OnlineVerifying'));
    Ps1NetplayMatch? opened;
    try {
      final (game, media) = await _verifiedPs1(profile, candidates);
      if (account.user?.id != me || app.starting != null || app.running != null) return;
      late final Ps1NetplayMatch match;
      match = Ps1NetplayMatch(
        rooms: RetroOnlineRooms(
          call: account.call,
          me: me,
          spec: profile.room,
          signal: (to, device, sessionId, kind, data) {
            if (!hub.socket.send(
              OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data),
            )) {
              throw StateError('The AnyTogether connection closed.');
            }
          },
        ),
        links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
        identity: media.identity,
        runner: EmbeddedPs1NetplayRunner(
          (seat) => app.preparePs1Netplay(game, media, seat, canBoot: () => !match.closed && account.user?.id == me),
        ),
      );
      _ps1Match = opened = match;
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
      app.show(
        T.text(switch (error.problem) {
          Ps1NetplayMediaProblem.disc => 'ps1OnlineDisc',
          Ps1NetplayMediaProblem.bios => 'ps1OnlineBios',
          Ps1NetplayMediaProblem.core => 'ps1OnlineCore',
        }),
      );
    } on Object {
      app.show(T.text('ps1OnlineDisconnected'));
    } finally {
      if (identical(_ps1Match, opened)) _ps1Match = null;
      _verifyingPs1 = false;
      app.refresh();
    }
  }

  Future<(Game, Ps1NetplayMedia)> _verifiedPs1(Ps1NetplayProfile profile, List<Game> candidates) async {
    for (final game in candidates) {
      try {
        return (game, await app.verifyPs1Netplay(game, profile));
      } on Ps1NetplayMediaFailure catch (error) {
        if (error.problem != Ps1NetplayMediaProblem.disc) rethrow;
      }
    }
    throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
  }
}
