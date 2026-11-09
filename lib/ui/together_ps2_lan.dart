part of 'together_model.dart';

final class _Ps2LanAttempt {
  RetroLanMatch? match;
  bool cancelled = false;
  bool playing = false;

  void cancel() {
    cancelled = true;
    unawaited(match?.leave());
  }
}

extension TogetherPs2Lan on TogetherModel {
  bool get _ps2LanEnabled => environment['ANYPS5_PS2_LAN'] == '1' && app.managedRetroAvailable;

  bool get _ps2LaunchAvailable => app.running == null && app.starting == null && !app.stopping;

  RetroRoomSpec? _ps2LanSpec(Game game) {
    final serial = game.retroSerial;
    if (game.retro?.platform != RetroPlatform.ps2 || serial == null || game.version.isEmpty) return null;
    return (titleId: serial, gameVersion: game.version, mode: RetroOnlineMode.lan, capacity: 2);
  }

  List<PanelRow> ps2LanInvites(Friend friend) {
    final game = app.selectedGame;
    final spec = game == null ? null : _ps2LanSpec(game);
    if (!_ps2LanEnabled ||
        !_ps2LaunchAvailable ||
        _ps2Lan != null ||
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
        detail: T.text('ps2LanInviteDetail'),
        kind: ActionRow(() {
          app.open(Layer.friends);
          unawaited(_startPs2Lan(spec, [game], friendId: friend.person.id));
        }),
      ),
    ];
  }

  List<PanelRow> ps2LanRows() {
    final attempt = _ps2Lan;
    if (attempt == null) return const [];
    return [
      PanelRow(
        id: 'ps2-lan-status',
        title: T.text(attempt.playing ? 'ps2LanLeave' : 'ps2LanCancel'),
        detail: T.text(
          attempt.cancelled
              ? 'ps2LanClosing'
              : attempt.playing
              ? 'ps2LanUseGameMenu'
              : attempt.match == null
              ? 'ps2LanVerifying'
              : 'ps2LanConnecting',
        ),
        kind: ActionRow(() {
          attempt.cancel();
          app.refresh();
        }, destructive: true),
      ),
    ];
  }

  List<PanelRow> ps2LanQuickRows() => _ps2Lan?.playing == true ? ps2LanRows() : const [];

  Future<void> joinPs2Lan(GameInvite invite) async {
    if (!_ps2LanEnabled) return _unsupportedRetroInvite();
    final spec = (titleId: invite.titleId, gameVersion: invite.gameVersion, mode: RetroOnlineMode.lan, capacity: 2);
    final candidates = app.games.where((game) => _ps2LanSpec(game) == spec);
    await _startPs2Lan(spec, candidates, roomId: invite.sessionId);
  }

  Future<void> _startPs2Lan(RetroRoomSpec spec, Iterable<Game> candidates, {String? friendId, String? roomId}) async {
    final me = account.user?.id;
    if (me == null || hub.socket.status != SocketStatus.ready) return app.show(T.text('ps2LanUnavailable'));
    if (_ps2Lan != null || _ps1Match != null || _verifyingPs1 || !_ps2LaunchAvailable) {
      return app.show(T.text('ps2LanBusy'));
    }
    if (candidates.isEmpty) return app.show(T.text('ps2LanDisc'));
    if (!app.ps2LanCoreInstalled) return app.show(T.text('ps2LanCore'));
    if (app.ps2LanBiosPath == null) return app.show(T.text('ps2LanBios'));

    final attempt = _ps2Lan = _Ps2LanAttempt();
    bool active() => identical(_ps2Lan, attempt) && !attempt.cancelled && account.user?.id == me;
    RetroOnlineRooms rooms([String? digest]) => RetroOnlineRooms(
      call: account.call,
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
          : await rooms().invitedDiscDigest(roomId).timeout(const Duration(seconds: 12));
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
          rooms: rooms(digest),
          links: app.services.gameLinks?.call() ?? WebRtcGameLinks(),
          launch: (mac) async {
            if (!unchanged(await file.stat())) throw StateError('The verified PS2 disc changed before launch.');
            if (!_ps2LaunchAvailable) throw StateError('Another game started before PS2 LAN.');
            final run = await app.preparePs2Lan(game, mac, canBoot: () => active() && attempt.match?.closed == false);
            if (active()) {
              attempt.playing = true;
              app.show(T.text('ps2LanUseGameMenu'));
              app.refresh();
            }
            return run;
          },
        );
        app.refresh();
        if (roomId == null) {
          await match.host(friendId!);
        } else {
          await match.join(roomId);
          unawaited(hub.games.refresh().catchError((Object _) {}));
        }
        await match.done;
        if (active() && match.failure != null) {
          app.show(T.text('ps2LanDisconnected'));
        } else if (active() && match.remoteEnded) {
          app.show(T.text('ps2LanRemoteEnded'));
        }
        return;
      }
      if (active()) app.show(T.text('ps2LanDisc'));
    } on Ps2LanProfileInUse {
      if (active()) app.show(T.text('ps2LanProfileInUse'));
    } on Object {
      if (active()) app.show(T.text('ps2LanDisconnected'));
    } finally {
      if (identical(_ps2Lan, attempt)) _ps2Lan = null;
      app.refresh();
    }
  }
}
