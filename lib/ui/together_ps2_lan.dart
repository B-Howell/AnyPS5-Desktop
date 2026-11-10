part of 'together_model.dart';

final class _Ps2LanWorker {
  const _Ps2LanWorker(this.game, this.session, this.run, this.digest, this.owner, this.profile, {required this.host});

  final Game game;
  final EmbeddedRetroGame session;
  final RetroLanGame run;
  final String digest;
  final String owner;
  final String? profile;
  final bool host;
}

final class _Ps2LanAttempt {
  _Ps2LanAttempt(this.borrowed, {required this.host});

  final _Ps2LanWorker? borrowed;
  final bool host;
  final cancellation = Completer<void>();
  RetroLanMatch? match;
  Game? launchGame;
  bool disposed = false;

  bool get cancelled => cancellation.isCompleted;
  bool get closing => cancelled || match?.closed == true;

  void cancel({bool keepGame = false}) {
    if (cancelled) return;
    cancellation.complete();
    unawaited(match?.leave(keepGame: keepGame));
  }
}

extension TogetherPs2Lan on TogetherModel {
  bool get _ps2LanEnabled => environment['ANYPS5_PS2_LAN'] == '1' && app.managedRetroAvailable;

  bool get _ps2LaunchAvailable =>
      app.running == null && app.starting == null && !app.stopping && app.managedSetupConsole == null;
  _Ps2LanWorker? _ps2ReusableWorker({required bool host}) {
    final worker = _ps2LanWorker;
    return worker != null &&
            identical(app.embeddedGame, worker.session) &&
            worker.session.startupVisible &&
            worker.host == host &&
            worker.owner == account.user?.id &&
            worker.profile == app.currentProfile?.id &&
            !app.stopping &&
            app.managedSetupConsole == null
        ? worker
        : null;
  }

  bool get _ps2LanBusy => _ps2Lan != null || _ps3Party != null || app.ps2LanSetupActive;

  bool get ps2LanSetupEnabled => _ps2LanEnabled;

  bool get ps2LanSetupAvailable =>
      _ps2LanEnabled && _ps2LaunchAvailable && !_ps2LanBusy && _ps1Match == null && !_verifyingPs1;

  String? get _ps2LanSetupIssue => !app.ps2LanCoreInstalled
      ? 'ps2LanCore'
      : app.ps2LanBiosPath == null
      ? 'ps2LanBios'
      : null;

  RetroRoomSpec? _ps2LanSpec(Game game) {
    final serial = game.retroSerial;
    if (game.retro?.platform != RetroPlatform.ps2 || serial == null || game.version.isEmpty) return null;
    return (titleId: serial, gameVersion: game.version, mode: RetroOnlineMode.lan, capacity: 2);
  }

  RetroRoomSpec _ps2LanInviteSpec(GameInvite invite) =>
      (titleId: invite.titleId, gameVersion: invite.gameVersion, mode: RetroOnlineMode.lan, capacity: 2);

  Iterable<Game> _ps2LanCandidates(RetroRoomSpec spec) => app.games.where((game) => _ps2LanSpec(game) == spec);

  bool _canJoinPs2FromGame(GameInvite invite) {
    if (!_ps2LanEnabled || _ps2LanBusy || _ps1Match != null || _verifyingPs1) return false;
    final worker = _ps2ReusableWorker(host: false);
    return worker != null && _ps2LanCandidates(_ps2LanInviteSpec(invite)).any((game) => game.id == worker.game.id);
  }

  String ps2LanInviteDetail(GameInvite invite) {
    if (!_ps2LanEnabled) return T.text('retroOnlineUnavailable');
    final candidates = _ps2LanCandidates(_ps2LanInviteSpec(invite));
    if (candidates.isEmpty) return T.text('ps2LanDisc');
    if (_canJoinPs2FromGame(invite)) return T.text('ps2LanUseGameMenu');
    return T.text(_ps2LanSetupIssue ?? 'ps2LanInviteDetail');
  }

  List<PanelRow> ps2LanInvites(Friend friend) {
    final game = app.selectedGame;
    final spec = game == null ? null : _ps2LanSpec(game);
    final reuse = _ps2ReusableWorker(host: true);
    if (!_ps2LanEnabled ||
        (!_ps2LaunchAvailable && (reuse == null || reuse.game.id != game?.id)) ||
        _ps2LanBusy ||
        _ps1Match != null ||
        _verifyingPs1 ||
        !friend.presence.online ||
        game == null ||
        spec == null) {
      return const [];
    }
    return [
      PanelRow(
        id: 'ps2-lan-invite',
        title: T.format('ps2LanInvite', [game.name]),
        detail: T.text(reuse == null ? _ps2LanSetupIssue ?? 'ps2LanInviteDetail' : 'ps2LanInviteDetail'),
        kind: ActionRow(() => unawaited(_startPs2Lan(spec, [game], friendId: friend.person.id))),
      ),
    ];
  }

  PanelRow? ps2LanDashboardLink(Game game, void Function(PanelCategory Function()) open) {
    final spec = _ps2LanSpec(game);
    if (!ps2LanSetupAvailable || spec == null) return null;
    return _retroDashboardInviteLink(
      game,
      open,
      prefix: 'ps2-lan-dashboard',
      title: 'ps2LanInviteFromGame',
      detail: _ps2LanSetupIssue ?? 'ps2LanInviteDetail',
      unavailable: 'ps2LanUnavailable',
      available: () => ps2LanSetupAvailable,
      invite: (friend) => unawaited(_startPs2Lan(spec, [game], friendId: friend.person.id)),
    );
  }

  List<PanelRow> ps2LanRows() {
    final attempt = _ps2Lan;
    if (attempt == null) return const [];
    if (attempt.closing) {
      return [PanelRow(id: 'ps2-lan-status', title: T.text('ps2LanClosing'), kind: const InfoRow(''))];
    }
    final starting = _ps2LanStarting(attempt);
    final playing = attempt.match?.attached == true && !starting;
    final recovering = attempt.match?.recovering == true;
    final path = playing && !recovering ? attempt.match?.connectionPath : null;
    final detail = playing
        ? (recovering ? 'ps2LanReconnecting' : _ps2LanGameMenu(attempt.host))
        : switch (attempt.match?.startupPhase) {
            null => 'ps2LanVerifying',
            RetroLanStartupPhase.openingRoom => 'ps2LanOpeningRoom',
            RetroLanStartupPhase.waitingForPlayer => attempt.host ? 'ps2LanWaitingForFriend' : 'ps2LanWaitingForHost',
            RetroLanStartupPhase.connecting => 'ps2LanConnecting',
            RetroLanStartupPhase.startingGame => 'ps2LanStarting',
          };
    return [
      PanelRow(
        id: 'ps2-lan-status',
        title: T.text(playing ? 'ps2LanLeave' : 'ps2LanCancel'),
        detail: [
          T.text(detail),
          if (path?.relayed case final relayed?) T.text(relayed ? 'sharePlayRelayed' : 'sharePlayDirect'),
          if (path?.roundTripMs case final roundTrip?) T.format('sharePlayRoundTrip', [roundTrip]),
        ].join(' · '),
        kind: ActionRow(() {
          if (!identical(_ps2Lan, attempt) || attempt.match?.closed == true || attempt.cancelled) return;
          attempt.cancel(keepGame: playing);
          app.refresh();
        }, destructive: true),
      ),
    ];
  }

  String _ps2LanGameMenu(bool host) => host ? 'ps2LanHostGameMenu' : 'ps2LanJoinGameMenu';

  bool _ps2LanStarting(_Ps2LanAttempt attempt) => app.startingPs2Lan && identical(app.starting, attempt.launchGame);

  _Ps2LanWorker? get _ps2LanQuickHost =>
      !_ps2LanEnabled || _ps2LanBusy || _ps1Match != null || _verifyingPs1 ? null : _ps2ReusableWorker(host: true);

  List<PanelRow> ps2LanQuickRows() {
    final attempt = _ps2Lan;
    if (attempt == null) {
      return [
        if (_ps2LanQuickHost != null)
          PanelRow(
            id: 'ps2-lan-invite-from-game',
            title: T.text('ps2LanInviteFromGame'),
            kind: ActionRow(() => app.open(Layer.retroOnlineFriends)),
          ),
      ];
    }
    final embedded = app.embeddedGame?.isPs2Lan == true && identical(app.running?.$1, attempt.launchGame);
    return _ps2LanStarting(attempt) || embedded ? ps2LanRows() : const [];
  }

  List<PanelRow> ps2LanInviteFriendRows() {
    final worker = _ps2LanQuickHost;
    final spec = worker == null ? null : _ps2LanSpec(worker.game);
    if (worker == null || spec == null) return const [];
    return _retroInviteFriendRows(
      prefix: 'ps2-lan-invite',
      title: 'ps2LanInviteFromGame',
      detail: 'ps2LanInviteDetail',
      unavailable: 'ps2LanUnavailable',
      invite: (friend) => unawaited(_startPs2Lan(spec, [worker.game], friendId: friend.person.id, fromGame: worker)),
    );
  }

  Future<void> joinPs2Lan(GameInvite invite) async {
    if (!_ps2LanEnabled) return _unsupportedRetroInvite();
    final spec = _ps2LanInviteSpec(invite);
    await _startPs2Lan(spec, _ps2LanCandidates(spec), roomId: invite.sessionId, expectedHost: invite.from?.id);
  }

  Future<void> _startPs2Lan(
    RetroRoomSpec spec,
    Iterable<Game> candidates, {
    String? friendId,
    String? roomId,
    String? expectedHost,
    _Ps2LanWorker? fromGame,
  }) async {
    final me = account.user?.id;
    if (me == null || hub.socket.status != SocketStatus.ready) return app.show(T.text('ps2LanUnavailable'));
    final profile = app.currentProfile?.id;
    final host = roomId == null;
    final worker = _ps2ReusableWorker(host: host);
    final reuse = worker != null && candidates.any((game) => game.id == worker.game.id) ? worker : null;
    if (fromGame != null && !identical(reuse, fromGame)) return app.show(T.text('ps2LanBusy'));
    bool canLaunch() => reuse == null ? _ps2LaunchAvailable : identical(_ps2ReusableWorker(host: host), reuse);
    if (_ps2LanBusy || _ps1Match != null || _verifyingPs1 || !canLaunch()) {
      return app.show(T.text(_ps2Lan?.closing == true ? 'ps2LanClosing' : 'ps2LanBusy'));
    }
    if (candidates.isEmpty) return app.show(T.text('ps2LanDisc'));
    if (reuse == null && _ps2LanSetupIssue != null) {
      final gameIds = candidates.map((game) => game.id).toSet();
      return app.openPs2LanSetup(
        onReady: () {
          app.open(Layer.friends);
          if (account.user?.id != me || app.currentProfile?.id != profile) {
            return app.show(T.text('ps2LanUnavailable'));
          }
          if (roomId != null &&
              !hub.games.invites.any(
                (invite) =>
                    invite.sessionId == roomId &&
                    (expectedHost == null || invite.from?.id == expectedHost) &&
                    invite.engineBuild == spec.mode.protocol &&
                    _ps2LanInviteSpec(invite) == spec,
              )) {
            return app.show(T.text('retroInviteExpired'));
          }
          unawaited(
            _startPs2Lan(
              spec,
              _ps2LanCandidates(spec).where((game) => gameIds.contains(game.id)),
              friendId: friendId,
              roomId: roomId,
              expectedHost: expectedHost,
            ),
          );
        },
      );
    }
    final quickJoin = roomId != null && reuse != null && app.overlay == Layer.quickMenu;
    if (fromGame != null) {
      app.resumeGame();
    } else if (friendId != null) {
      app.open(Layer.friends);
    }

    final attempt = _ps2Lan = _Ps2LanAttempt(reuse, host: host)..launchGame = reuse?.game;
    bool owned() =>
        !attempt.disposed && identical(_ps2Lan, attempt) && account.user?.id == me && app.currentProfile?.id == profile;
    bool active() => owned() && !attempt.cancelled;
    RetroOnlineRooms rooms([String? digest]) => RetroOnlineRooms(
      call: (method, path, [body]) {
        if (account.user?.id != me) throw StateError('The AnyTogether account changed.');
        return account.call(method, path, body);
      },
      me: me,
      spec: spec,
      discDigest: digest,
      signal: (to, device, id, kind, data) {
        if (!hub.socket.send(OnlinePeerSignal.frame(to: to, device: device, sessionId: id, kind: kind, data: data))) {
          throw StateError('The AnyTogether connection closed.');
        }
      },
    );
    app.refresh();
    try {
      final invite = roomId == null
          ? null
          : await Future.any<RetroRoomInvite?>([
              rooms().readInvite(roomId, expectedHost: expectedHost),
              attempt.cancellation.future.then((_) => null),
            ]);
      if (!active()) return;
      final expected = invite?.disc;
      if (roomId != null && expected == null) return app.show(T.text('ps2LanDisc'));
      for (final game in candidates) {
        if (!active() || !canLaunch()) return;
        if (reuse != null && game.id != reuse.game.id) continue;
        final disc = game.retro!.path;
        final String digest;
        final file = File(disc);
        late final FileStat before;
        bool unchanged(FileStat stat) =>
            stat.size == before.size && stat.modified == before.modified && stat.type == FileSystemEntityType.file;
        try {
          before = await file.stat();
          final identity = GameLibrary.ps2DiscIdentity(disc);
          if (identity?.serial != spec.titleId || identity?.revision != spec.gameVersion) continue;
          digest = (await sha256.bind(file.openRead().takeWhile((_) => active())).first).toString();
          if (!unchanged(await file.stat())) continue;
        } on FileSystemException {
          continue;
        }
        if (!active() || !canLaunch()) return;
        if (reuse != null && digest != reuse.digest) continue;
        if (expected != null && digest != expected) continue;

        final match = attempt.match = RetroLanMatch(
          ownsGame: reuse == null,
          onStartupChanged: () {
            if (active()) app.refresh();
          },
          onPathChanged: () {
            if (active()) app.refresh();
          },
          onRecoveryChanged: (recovering) {
            if (active() && identical(app.running?.$1, attempt.launchGame)) {
              app.show(T.text(recovering ? 'ps2LanReconnecting' : 'ps2LanReconnected'));
            }
          },
          rooms: rooms(digest),
          links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
          launch: (mac) async {
            if (!unchanged(await file.stat())) throw StateError('The verified PS2 disc changed before launch.');
            if (!active() || !canLaunch()) throw StateError('The PS2 game changed before LAN attached.');
            if (reuse != null) {
              if (!await reuse.session.resetPs2LanFrames() || !active() || !canLaunch()) {
                throw StateError('The running PS2 LAN adapter could not be reused.');
              }
              return reuse.run;
            }
            attempt.launchGame = game;
            final run = await app.preparePs2Lan(game, mac, canBoot: () => active() && attempt.match?.closed == false);
            if (app.embeddedGame case final session? when active() && identical(app.running?.$1, game)) {
              final started = _ps2LanWorker = _Ps2LanWorker(game, session, run, digest, me, profile, host: host);
              void forgetWorker() {
                if (!identical(_ps2LanWorker, started)) return;
                _ps2LanWorker = null;
                final current = _ps2Lan;
                if (current != null && identical(current.borrowed, started)) current.cancel();
              }

              unawaited(run.done.then<void>((_) => forgetWorker(), onError: (Object _) => forgetWorker()));
            }
            return run;
          },
        );
        unawaited(
          match.ending.then((_) {
            if (!owned()) return;
            if (match.gameContinues && identical(app.running?.$1, attempt.launchGame)) {
              final message = match.remoteEnded
                  ? 'ps2LanRemoteGameContinues'
                  : match.failure != null
                  ? 'ps2LanConnectionGameContinues'
                  : 'ps2LanGameContinues';
              app.show(T.text(message));
            }
            app.refresh();
          }),
        );
        app.refresh();
        if (roomId == null) {
          await match.host(friendId!);
        } else {
          await match.join(roomId, expectedHost: invite!.room.hostId);
          if (owned()) unawaited(hub.games.refresh().catchError((Object _) {}));
        }
        var visible = false;
        if (app.embeddedGame case final session? when active() && match.attached) {
          visible = session.startupVisible || await Future.any([session.ready, match.ending.then((_) => false)]);
        }
        if (visible && active() && match.attached) {
          if (reuse != null && canLaunch() && app.overlay == (quickJoin ? Layer.quickMenu : Layer.friends)) {
            app.resumeGame();
          }
          app.show(T.text(_ps2LanGameMenu(host)));
        }
        await match.done;
        if (active() && !match.gameContinues) {
          if (match.remoteEnded) {
            app.show(T.text('ps2LanRemoteEnded'));
          } else if (!visible && match.startupPhase == RetroLanStartupPhase.startingGame) {
            app.show(T.text('ps2LanLaunchFailed'));
          } else if (match.failure != null) {
            app.show(T.text('ps2LanDisconnected'));
          }
        }
        return;
      }
      if (active()) app.show(T.text('ps2LanDisc'));
    } on Ps2LanProfileInUse {
      if (active()) app.show(T.text('ps2LanProfileInUse'));
    } on RetroRoomHostMismatch {
      if (active()) app.show(T.text('retroInviteHostChanged'));
    } on RetroInviteSendTimeout {
      if (active()) app.show(T.text('retroInviteSendTimeout'));
    } on RetroRoomStatusTimeout {
      if (active()) app.show(T.text('retroRoomStatusTimeout'));
    } on RetroRoomOccupied {
      if (active()) app.show(T.text('retroRoomOccupied'));
    } on RetroConnectionTimeout {
      if (active()) app.show(T.text(host ? 'retroConnectionTimeoutHost' : 'retroConnectionTimeoutGuest'));
    } on RetroRoomLookupTimeout {
      if (active()) app.show(T.text('retroInviteLookupTimeout'));
    } on Object {
      if (active()) {
        app.show(
          T.text(switch (attempt.match?.startupPhase) {
            null || RetroLanStartupPhase.openingRoom => 'ps2LanRoomFailed',
            RetroLanStartupPhase.waitingForPlayer => 'ps2LanPlayerUnavailable',
            RetroLanStartupPhase.connecting => 'ps2LanConnectionFailed',
            RetroLanStartupPhase.startingGame => 'ps2LanLaunchFailed',
          }),
        );
      }
    } finally {
      if (attempt.match case final match? when match.closed) await match.roomCleanupDone;
      if (identical(_ps2Lan, attempt)) _ps2Lan = null;
      if (!attempt.disposed) app.refresh();
    }
  }
}
