part of 'together_model.dart';

final class _Ps2LanAttempt {
  final cancellation = Completer<void>();
  RetroLanMatch? match;
  Game? launchGame;
  bool playing = false;

  bool get cancelled => cancellation.isCompleted;
  bool get closing => cancelled || match?.closed == true;

  void cancel() {
    if (cancelled) return;
    cancellation.complete();
    unawaited(match?.leave());
  }
}

extension TogetherPs2Lan on TogetherModel {
  bool get _ps2LanEnabled => environment['ANYPS5_PS2_LAN'] == '1' && app.managedRetroAvailable;

  bool get _ps2LaunchAvailable =>
      app.running == null && app.starting == null && !app.stopping && app.managedSetupConsole == null;

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

  String ps2LanInviteDetail(GameInvite invite) {
    if (!_ps2LanEnabled) return T.text('retroOnlineUnavailable');
    if (_ps2LanCandidates(_ps2LanInviteSpec(invite)).isEmpty) return T.text('ps2LanDisc');
    return T.text(_ps2LanSetupIssue ?? 'ps2LanInviteDetail');
  }

  List<PanelRow> ps2LanInvites(Friend friend) {
    final game = app.selectedGame;
    final spec = game == null ? null : _ps2LanSpec(game);
    if (!_ps2LanEnabled ||
        !_ps2LaunchAvailable ||
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
        detail: T.text(_ps2LanSetupIssue ?? 'ps2LanInviteDetail'),
        kind: ActionRow(() => unawaited(_startPs2Lan(spec, [game], friendId: friend.person.id))),
      ),
    ];
  }

  List<PanelRow> ps2LanRows() {
    final attempt = _ps2Lan;
    if (attempt == null) return const [];
    if (attempt.closing) {
      return [PanelRow(id: 'ps2-lan-status', title: T.text('ps2LanClosing'), kind: const InfoRow(''))];
    }
    final starting = _ps2LanStarting(attempt);
    final playing = attempt.playing && !starting;
    final recovering = attempt.match?.recovering == true;
    final path = playing && !recovering ? attempt.match?.connectionPath : null;
    return [
      PanelRow(
        id: 'ps2-lan-status',
        title: T.text(playing ? 'ps2LanLeave' : 'ps2LanCancel'),
        detail: [
          T.text(
            playing
                ? (recovering ? 'ps2LanReconnecting' : 'ps2LanUseGameMenu')
                : starting
                ? 'ps2LanStarting'
                : attempt.match == null
                ? 'ps2LanVerifying'
                : 'ps2LanConnecting',
          ),
          if (path?.relayed case final relayed?) T.text(relayed ? 'sharePlayRelayed' : 'sharePlayDirect'),
          if (path?.roundTripMs case final roundTrip?) T.format('sharePlayRoundTrip', [roundTrip]),
        ].join(' · '),
        kind: ActionRow(() {
          if (!identical(_ps2Lan, attempt) || attempt.match?.closed == true || attempt.cancelled) return;
          attempt.cancel();
          app.refresh();
        }, destructive: true),
      ),
    ];
  }

  bool _ps2LanStarting(_Ps2LanAttempt attempt) => app.startingPs2Lan && identical(app.starting, attempt.launchGame);

  List<PanelRow> ps2LanQuickRows() {
    final attempt = _ps2Lan;
    if (attempt == null) return const [];
    final embedded = app.embeddedGame?.isPs2Lan == true && identical(app.running?.$1, attempt.launchGame);
    return _ps2LanStarting(attempt) || embedded ? ps2LanRows() : const [];
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
  }) async {
    final me = account.user?.id;
    if (me == null || hub.socket.status != SocketStatus.ready) return app.show(T.text('ps2LanUnavailable'));
    if (_ps2LanBusy || _ps1Match != null || _verifyingPs1 || !_ps2LaunchAvailable) {
      return app.show(T.text(_ps2Lan?.closing == true ? 'ps2LanClosing' : 'ps2LanBusy'));
    }
    if (candidates.isEmpty) return app.show(T.text('ps2LanDisc'));
    if (_ps2LanSetupIssue != null) {
      final gameIds = candidates.map((game) => game.id).toSet();
      return app.openPs2LanSetup(
        onReady: () {
          app.open(Layer.friends);
          if (account.user?.id != me) return app.show(T.text('ps2LanUnavailable'));
          if (roomId != null &&
              !hub.games.invites.any(
                (invite) =>
                    invite.sessionId == roomId &&
                    (expectedHost == null || invite.from?.id == expectedHost) &&
                    invite.engineBuild == spec.mode.protocol &&
                    _ps2LanInviteSpec(invite) == spec,
              )) {
            return app.show(T.text('ps2LanInviteExpired'));
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
    if (friendId != null) app.open(Layer.friends);

    final attempt = _ps2Lan = _Ps2LanAttempt();
    bool active() => identical(_ps2Lan, attempt) && !attempt.cancelled && account.user?.id == me;
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
      final expected = roomId == null
          ? null
          : await Future.any<String?>([
              rooms().invitedDiscDigest(roomId, expectedHost: expectedHost).timeout(const Duration(seconds: 12)),
              attempt.cancellation.future.then((_) => null),
            ]);
      if (!active()) return;
      if (roomId != null && expected == null) return app.show(T.text('ps2LanDisc'));
      for (final game in candidates) {
        if (!active() || !_ps2LaunchAvailable) return;
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
        if (!active() || !_ps2LaunchAvailable) return;
        if (expected != null && digest != expected) continue;

        final match = attempt.match = RetroLanMatch(
          onPathChanged: app.refresh,
          onRecoveryChanged: (recovering) {
            if (active() && app.running?.$1 == game) {
              app.show(T.text(recovering ? 'ps2LanReconnecting' : 'ps2LanReconnected'));
            }
          },
          rooms: rooms(digest),
          links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
          launch: (mac) async {
            if (!unchanged(await file.stat())) throw StateError('The verified PS2 disc changed before launch.');
            if (!_ps2LaunchAvailable) throw StateError('Another game started before PS2 LAN.');
            attempt.launchGame = game;
            final run = await app.preparePs2Lan(game, mac, canBoot: () => active() && attempt.match?.closed == false);
            if (active()) {
              attempt.playing = true;
              app.show(T.text('ps2LanUseGameMenu'));
              app.refresh();
            }
            return run;
          },
        );
        unawaited(
          match.ending.then((_) {
            if (!active()) return;
            if (match.gameContinues && app.running?.$1 == game) app.show(T.text('ps2LanGameContinues'));
            app.refresh();
          }),
        );
        app.refresh();
        if (roomId == null) {
          await match.host(friendId!);
        } else {
          await match.join(roomId, expectedHost: expectedHost);
          unawaited(hub.games.refresh().catchError((Object _) {}));
        }
        await match.done;
        if (active() && !match.gameContinues) {
          if (match.failure != null) {
            app.show(T.text('ps2LanDisconnected'));
          } else if (match.remoteEnded) {
            app.show(T.text('ps2LanRemoteEnded'));
          }
        }
        return;
      }
      if (active()) app.show(T.text('ps2LanDisc'));
    } on Ps2LanProfileInUse {
      if (active()) app.show(T.text('ps2LanProfileInUse'));
    } on RetroRoomHostMismatch {
      if (active()) app.show(T.text('retroInviteHostChanged'));
    } on Object {
      if (active()) app.show(T.text('ps2LanDisconnected'));
    } finally {
      if (attempt.match case final match? when match.closed) await match.roomCleanupDone;
      if (identical(_ps2Lan, attempt)) _ps2Lan = null;
      app.refresh();
    }
  }
}
