part of 'app_model.dart';

/// How far an online match of the game in the host has come, before its [Ps1LockstepMatch] runs.
enum RetroOnlineStep {
  /// Reading the disc, the core and the BIOS for the match.
  checking,

  /// The room is made and the friend invited; their launcher has not come in yet.
  invited,

  /// Both launchers are in the room and connect to each other.
  connecting,

  /// The match runs ([RetroOnline.match]).
  match,
}

/// One PS1 online match of the game playing in the host, as its lobby shows it (anyps5-retro-host
/// docs/netplay.md): the host player invites a friend from the lobby of the game they play; the
/// friend accepts from Friends, and their launcher starts the same game and joins it.
class RetroOnline {
  RetroOnline({required this.hosting, required this.friendId, required this.friendName});

  /// Whether this launcher's player invited, holds the game and plays Player 1.
  final bool hosting;
  final String friendId;
  final String friendName;

  RetroOnlineStep step = RetroOnlineStep.checking;
  Ps1LockstepRooms? rooms;
  Ps1LockstepRoom? room;
  Ps1LockstepMember? peer;
  Ps1LockstepPeer? link;
  Ps1LockstepMatch? match;

  /// How the other launcher is reached, once connected.
  PeerPath? path;

  /// The player cancelled before the match ran.
  bool cancelled = false;

  /// Signals that came before the connection to read them was made.
  final early = <Map<String, dynamic>>[];

  /// Whether the other player's pause was said, so it is said once each time.
  bool peerPausedShown = false;

  /// The match's own folder: the state sent, and the friend's memory cards for the match.
  String? folder;
}

/// The game's lobby (its Couch Co-op page) and PS1 online play through the host: seats for Player
/// 1 to 4, inviting a friend, a friend's invite accepted, and the match's state.
extension RetroHostOnline on AppModel {
  /// A PS1 console without the Multitap has two controller ports; the host keeps the Multitap
  /// off (netplay.md "Lobby, seats and controller ports").
  static const ports = 2;

  /// Why this game cannot be played online now, as the key of the words to show; null when a
  /// friend can be invited.
  String? retroOnlineUnavailable(RetroPlay play) {
    if (!together.signedIn || !together.connected) return 'retroOnlineSignIn';
    if (!play.host.session.canLockstep) return 'retroOnlineHostOld';
    if (play.controls.seats.at(1) != null) return 'retroOnlineLocalFull';
    if (play.game.retro == null || play.host.phase != RetroHostGamePhase.playing) return 'retroOnlineNotReady';
    return null;
  }

  /// The first page's row that opens the lobby.
  PanelRow retroLobbyRow(RetroPlay play) => PanelRow(
    id: 'players',
    title: T.text('coopLobbyTitle'),
    detail: _retroLobbySummary(play),
    kind: ActionRow(() => _openRetroLobby(play)),
  );

  String _retroLobbySummary(RetroPlay play) {
    final online = retroOnline;
    if (online != null) return '${online.friendName} · ${_retroOnlineStatus(online)}';
    final players = play.controls.seats.at(1) != null ? 2 : 1;
    return players == 1 ? T.text('coopLobbyEntryDetail') : T.format('coopPlayers', [players]);
  }

  void _openRetroLobby(RetroPlay play) {
    if (!identical(retroPlay, play) || overlay != Layer.retroMenu) return;
    play.lobby = true;
    // The first row that can be chosen and ends nothing: a friend to invite, or Back to game.
    final rows = retroLobbyRows(play);
    final safe = rows.indexWhere((row) => row.focusable && !(row.kind is ActionRow && (row.kind as ActionRow).destructive));
    panelRow = math.max(0, safe);
    sounds.play(Cue.select);
    _changed();
  }

  /// The lobby page: the seats, then inviting a friend or the match, then Back to game.
  List<PanelRow> retroLobbyRows(RetroPlay play) {
    final online = retroOnline;
    final unavailable = retroOnlineUnavailable(play);
    final friends = [
      for (final friend in together.hub.friends.friends)
        if (friend.presence.online) friend,
    ];
    return [
      PanelRow(
        id: 'coop-players',
        title: play.game.name,
        kind: InfoRow(T.text(online == null ? 'retroLobbyDetail' : 'coopLobbyDetail')),
        playerSlots: retroLobbySlots(play),
      ),
      if (online != null)
        ..._retroOnlineRows(online)
      else if (unavailable != null)
        PanelRow(id: 'coop-unavailable', title: T.text('coopInvite'), kind: InfoRow(T.text('${unavailable}Detail')))
      else if (friends.isEmpty)
        PanelRow(id: 'coop-no-friends', title: T.text('coopInvite'), kind: InfoRow(T.text('retroOnlineNoFriends')))
      else
        for (final friend in friends)
          PanelRow(
            id: 'coop-invite-${friend.person.id}',
            title: T.format('partyInvite', [TogetherModel.shown(friend.person).name]),
            detail: T.text('retroOnlineInviteDetail'),
            person: TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
            kind: ActionRow(() => unawaited(inviteRetroFriend(friend))),
          ),
      PanelRow(id: 'coop-back-to-game', title: T.text('coopBackToGame'), kind: ActionRow(resumeRetroGame)),
    ];
  }

  /// Player 1 to 4. Ports 1 and 2 are the console's: this computer's controllers, or the host
  /// player and the friend in a match. Seats 3 and 4 need the Multitap, which stays off.
  List<PlayerSlot> retroLobbySlots(RetroPlay play) {
    final online = retroOnline;
    final me = together.user?.displayName ?? currentProfile?.name ?? T.text('coopYou');
    String pad(int port) => controllers.roster.pad(play.controls.seats.at(port) ?? '')?.name ?? '';
    final slots = <PlayerSlot>[];
    if (online != null) {
      final mine = PlayerSlot(
        player: online.hosting ? 1 : 2,
        name: me,
        status: [
          T.text(online.hosting ? 'coopController1' : 'coopController2'),
          pad(0),
        ].where((part) => part.isNotEmpty).join(' · '),
        you: true,
      );
      final theirs = PlayerSlot(
        player: online.hosting ? 2 : 1,
        name: online.friendName,
        status: '${T.text(online.hosting ? 'coopController2' : 'coopController1')} · ${_retroOnlineStatus(online)}',
      );
      slots.addAll(online.hosting ? [mine, theirs] : [theirs, mine]);
    } else {
      slots.add(
        PlayerSlot(
          player: 1,
          name: me,
          status: [T.text('coopController1'), pad(0)].where((part) => part.isNotEmpty).join(' · '),
          you: true,
        ),
      );
      final second = play.controls.seats.at(1);
      slots.add(
        second != null
            ? PlayerSlot(player: 2, name: T.text('coopGuest'), status: '${T.text('coopController2')} · ${pad(1)}')
            : PlayerSlot(
                player: 2,
                status: T.text(retroOnlineUnavailable(play) == null ? 'coopInviteSeat' : 'retroLobbySecondController'),
              ),
      );
    }
    for (var player = ports + 1; player <= 4; player++) {
      slots.add(
        PlayerSlot(
          player: player,
          name: T.text('coopTwoPlayers'),
          status: T.text('retroLobbyMultitap'),
          available: false,
        ),
      );
    }
    return slots;
  }

  String _retroOnlineStatus(RetroOnline online) {
    final match = online.match;
    return T.text(switch (online.step) {
      RetroOnlineStep.checking => 'coopGettingReady',
      RetroOnlineStep.invited => 'coopInvited',
      RetroOnlineStep.connecting => 'coopJoining',
      RetroOnlineStep.match when match?.peerPaused == true => 'retroOnlinePeerPaused',
      RetroOnlineStep.match => switch (match?.phase) {
        Ps1LockstepPhase.playing => 'coopPlaying',
        Ps1LockstepPhase.ended => 'ps1OnlineEnding',
        _ => 'ps1OnlinePreparing',
      },
    });
  }

  List<PanelRow> _retroOnlineRows(RetroOnline online) {
    final match = online.match;
    final playing = match?.phase == Ps1LockstepPhase.playing;
    final path = online.path;
    return [
      PanelRow(
        id: 'coop-leave',
        title: T.text(playing ? 'ps1OnlineLeave' : 'ps1OnlineCancel'),
        detail: [
          _retroOnlineStatus(online),
          if (playing && path != null && path.route == PeerRoute.direct) T.text('sharePlayDirect'),
          if (playing && path != null && path.route == PeerRoute.relay) T.text('sharePlayRelayed'),
          if (playing && match?.roundTripMs != null) T.format('sharePlayRoundTrip', [match!.roundTripMs!]),
          if (playing && match?.delay != null) T.format('retroOnlineDelay', [match!.delay!]),
        ].join(' · '),
        kind: ActionRow(() => unawaited(leaveRetroOnline()), destructive: true),
      ),
    ];
  }

  /// Leaves the match, or stops the invite on its way.
  Future<void> leaveRetroOnline() async {
    final online = retroOnline;
    if (online == null) return;
    online.cancelled = true;
    _changed();
    final match = online.match;
    if (match != null) {
      await match.leave();
    } else {
      await online.link?.close();
    }
  }

  /// The host player invites [friend] to the game they play: a room for the two, the invite, and
  /// once the friend's launcher is in it, the connection and the match.
  Future<void> inviteRetroFriend(Friend friend) async {
    final play = retroPlay;
    final me = together.user?.id;
    final install = retroHostInstall;
    final disc = play?.game.retro;
    if (play == null || me == null || install == null || disc == null || retroOnline != null) return;
    if (retroOnlineUnavailable(play) case final reason?) return show(T.text('${reason}Detail'));
    final online = retroOnline = RetroOnline(
      hosting: true,
      friendId: friend.person.id,
      friendName: TogetherModel.shown(friend.person).name,
    );
    sounds.play(Cue.select);
    _changed();
    Ps1LockstepRoom? room;
    try {
      final identity = await Ps1LockstepMedia.identify(
        hostVersion: play.host.session.hostVersion,
        core: install.core,
        disc: disc.path,
        files: _retroDiscFiles(play.game),
        system: paths.retroSystem,
      );
      if (!_retroOnlineGoesOn(online, play)) return;
      final rooms = online.rooms = _retroRooms(me);
      room = online.room = await rooms.host(
        disc: identity.disc,
        discBytes: Ps1LockstepMedia.discBytes(_retroDiscFiles(play.game)),
      );
      await rooms.invite(room, friend.person.id);
      online.step = RetroOnlineStep.invited;
      _changed();
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (online.peer == null) {
        if (!_retroOnlineGoesOn(online, play)) return;
        if (DateTime.now().isAfter(deadline)) return show(T.text('retroConnectionTimeoutHost'));
        online.peer = await rooms.peer(room, expectedUser: friend.person.id);
        if (online.peer == null) await Future<void>.delayed(const Duration(seconds: 1));
      }
      online.step = RetroOnlineStep.connecting;
      _changed();
      final link = await _retroConnect(online, offering: true);
      if (link == null || !_retroOnlineGoesOn(online, play)) return;
      final match = online.match = Ps1LockstepMatch(
        hosting: true,
        link: link,
        identity: identity,
        work: Directory(p.join(online.folder!, 'match')),
        localInput: () => play.controls.onlineInput,
        paused: () => play.host.paused,
        host: play.host.session,
        options: {
          for (final option in play.host.status?.options.values ?? const <RetroOption>[])
            option.key: option.activeValue,
        },
        onChanged: () => _retroMatchChanged(online, play),
      );
      online.step = RetroOnlineStep.match;
      _changed();
      await match.run();
      await match.done;
      _retroMatchEnded(match);
    } on Object catch (error) {
      _padLog?.call('online: the invite stopped: $error');
      if (!online.cancelled) show(T.text(_retroOnlineError(error, hosting: true)));
    } finally {
      if (identical(retroPlay, play)) play.controls.onlinePort = null;
      await _retroOnlineDone(online, room);
    }
  }

  /// Whether [invite] is a friend's PS1 online match.
  static bool isRetroOnlineInvite(GameInvite invite) => invite.engineBuild == Ps1LockstepRooms.protocol;

  /// The friend accepts [invite]: their copy of the game is found by its disc, started in a host
  /// with the host player's options and a memory card folder of the match, and joined to the
  /// host player's game. The game ends when the match does.
  Future<void> joinRetroOnline(GameInvite invite) async {
    final me = together.user?.id;
    final from = invite.from;
    final install = retroHostInstall;
    if (me == null || from == null || retroOnline != null) return;
    if (install == null || !preferences.retroHostPs1) return show(T.text('retroOnlineNoHostDetail'));
    if (retroPlay != null || running != null || starting != null) {
      return show(T.format('gameCloseFirst', [retroPlay?.game.name ?? running?.$1.name ?? starting?.name ?? '']));
    }
    final online = retroOnline = RetroOnline(
      hosting: false,
      friendId: from.id,
      friendName: TogetherModel.shown(from).name,
    );
    if (overlay != null) closeOverlay();
    _changed();
    Ps1LockstepRoom? room;
    RetroHostSession? opened;
    RetroPlay? play;
    Future<RetroLockstepHost?>? preparing;
    try {
      final rooms = online.rooms = _retroRooms(me);
      final read = await rooms.readInvite(invite.sessionId, expectedHost: from.id);
      final game = await _retroGameFor(read);
      if (game == null) return show(T.text('retroOnlineNoDiscDetail'));
      final session = opened = openRetroHost(
        install,
        volume: preferences.retroHostVolume / 100,
        muted: preferences.retroHostMuted,
      );
      await session.ready;
      if (!session.canLockstep) return show(T.text('retroOnlineHostOldDetail'));
      final identity = await Ps1LockstepMedia.identify(
        hostVersion: session.hostVersion,
        core: install.core,
        disc: game.retro!.path,
        files: _retroDiscFiles(game),
        system: paths.retroSystem,
      );
      if (online.cancelled) return;
      room = online.room = await rooms.join(read);
      online.step = RetroOnlineStep.connecting;
      _changed();
      online.peer = await rooms.peer(room, expectedUser: from.id);
      if (online.peer == null) throw const Ps1LockstepRoomInvalid('The host player left the room.');
      final link = await _retroConnect(online, offering: false);
      if (link == null || online.cancelled) return;
      final saves = p.join(online.folder!, 'saves');
      final match = online.match = Ps1LockstepMatch(
        hosting: false,
        link: link,
        identity: identity,
        work: Directory(p.join(online.folder!, 'match')),
        localInput: () => play?.controls.onlineInput ?? RetroPadInput.idle,
        paused: () => play?.host.paused ?? false,
        prepareGuest: (hello) => preparing = () async {
          play = await _playInHost(game, game.retro!, opened: session, options: hello.options, saves: saves);
          final started = play;
          if (started == null) return null;
          opened = null;
          while (started.host.phase != RetroHostGamePhase.playing) {
            if (started.host.phase == RetroHostGamePhase.ended || !identical(retroPlay, started)) return null;
            if (online.match?.end != null) return null;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return started.host.session;
        }(),
        onChanged: () {
          if (play case final started?) _retroMatchChanged(online, started);
          _changed();
        },
      );
      online.step = RetroOnlineStep.match;
      _changed();
      await match.run();
      await match.done;
      _retroMatchEnded(match);
    } on Object catch (error) {
      _padLog?.call('online: joining stopped: $error');
      if (!online.cancelled) show(T.text(_retroOnlineError(error, hosting: false)));
    } finally {
      // A match that ended while the game was starting waits for it, so the game is closed too.
      await preparing?.then((_) {}, onError: (Object _) {});
      final started = play;
      if (started != null && identical(retroPlay, started)) {
        started.controls.onlinePort = null;
        await closeRetroGame();
      }
      opened?.shutdown();
      await _retroOnlineDone(online, room);
    }
  }

  /// The friend's game for [invite]: a PS1 disc in the library of the same size and SHA-256.
  Future<Game?> _retroGameFor(Ps1LockstepInvite invite) async {
    for (final game in games) {
      final disc = game.retro;
      if (disc == null || disc.platform != RetroPlatform.ps1) continue;
      final files = _retroDiscFiles(game);
      if (!Ps1LockstepMedia.couldBe(files, invite.discBytes)) continue;
      if (await Isolate.run(() => Ps1LockstepMedia.discDigest(files)) == invite.disc) return game;
    }
    return null;
  }

  /// A disc's files as the library found them: its sheet and tracks, or the disc file alone.
  List<String> _retroDiscFiles(Game game) => game.files ?? [game.retro!.path];

  Ps1LockstepRooms _retroRooms(String me) => Ps1LockstepRooms(
    call: (method, path, [body]) {
      if (together.user?.id != me) throw StateError('The AnyTogether account changed.');
      return together.account.call(method, path, body);
    },
    me: me,
    holds: (id) => retroOnline?.room?.id == id,
    signal: (to, device, sessionId, kind, data) {
      if (!together.hub.socket.send(
        OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data),
      )) {
        throw StateError('The AnyTogether connection closed.');
      }
    },
  );

  /// The peer connection to the other launcher in the room, through AnyTogether's STUN and TURN
  /// servers; null when the player cancelled meanwhile.
  Future<Ps1LockstepPeer?> _retroConnect(RetroOnline online, {required bool offering}) async {
    final rooms = online.rooms!;
    final room = online.room!;
    final peer = online.peer!;
    online.folder = p.join(paths.retroOnline, room.id);
    Directory(online.folder!).createSync(recursive: true);
    final servers = await rooms.iceServers(room);
    final link = await (services.gameLinks?.call() ?? WebRtcGameLinks()).link(servers);
    final connection = online.link = Ps1LockstepPeer(
      link: link,
      offering: offering,
      sendSignal: (signal) async => rooms.send(room, peer, signal.toJson()),
    );
    for (final event in online.early) {
      _retroSignal(online, event);
    }
    online.early.clear();
    await connection.open();
    if (online.cancelled) return null;
    unawaited(
      connection.path().then((path) {
        online.path = path;
        _changed();
      }),
    );
    return connection;
  }

  /// A socket event for the match's room: the other launcher's signals.
  void retroOnlineEvent(TogetherEvent event) {
    final online = retroOnline;
    if (online == null || event.type != 'game_session.signal') return;
    if (online.link == null) {
      if (online.early.length < 128) online.early.add(event.json);
      return;
    }
    _retroSignal(online, event.json);
  }

  void _retroSignal(RetroOnline online, Map<String, dynamic> event) {
    final room = online.room;
    final peer = online.peer;
    final link = online.link;
    if (room == null || peer == null || link == null) return;
    final signal = online.rooms?.receive(room, peer, event);
    final read = Ps1LockstepSignal.tryRead(signal?.data);
    if (read != null) link.receiveSignal(read);
  }

  bool _retroOnlineGoesOn(RetroOnline online, RetroPlay play) =>
      !online.cancelled && identical(retroOnline, online) && identical(retroPlay, play) && !play.over;

  /// The match moved on: once the host is in lockstep the controllers here play this player's
  /// port of the match, not the game.
  void _retroMatchChanged(RetroOnline online, RetroPlay play) {
    final match = online.match;
    final phase = match?.phase;
    final paused = match?.peerPaused ?? false;
    if (paused != online.peerPausedShown) {
      online.peerPausedShown = paused;
      if (paused) show(T.format('retroOnlinePeerPausedToast', [online.friendName]));
    }
    if (identical(retroPlay, play) && (phase == Ps1LockstepPhase.transferring || phase == Ps1LockstepPhase.playing)) {
      play.controls.onlinePort = online.hosting ? 0 : 1;
    }
    _changed();
  }

  void _retroMatchEnded(Ps1LockstepMatch match) {
    final key = switch (match.end) {
      Ps1LockstepEnd.peerLeft => 'retroOnlinePeerLeft',
      Ps1LockstepEnd.disconnected || Ps1LockstepEnd.timedOut => 'ps1OnlineDisconnected',
      Ps1LockstepEnd.desync => 'ps1OnlineDesync',
      Ps1LockstepEnd.tooSlow => 'retroOnlineTooSlow',
      Ps1LockstepEnd.hostFailed || Ps1LockstepEnd.protocol => 'ps1OnlineDisconnected',
      Ps1LockstepEnd.mismatch => switch (match.mismatch) {
        Ps1LockstepMismatch.host => 'retroOnlineMismatchHost',
        Ps1LockstepMismatch.core => 'ps1OnlineMismatchCore',
        Ps1LockstepMismatch.disc => 'ps1OnlineMismatchDisc',
        Ps1LockstepMismatch.discName => 'retroOnlineMismatchDiscName',
        Ps1LockstepMismatch.bios || null => 'retroOnlineMismatchBios',
      },
      Ps1LockstepEnd.left || null => null,
    };
    if (key != null) show(T.text(key));
  }

  String _retroOnlineError(Object error, {required bool hosting}) => switch (error) {
    Ps1LockstepRoomBusy() => 'retroRoomOccupied',
    Ps1LockstepRoomInvalid() => hosting ? 'ps1OnlineDisconnected' : 'retroInviteExpired',
    TimeoutException() => hosting ? 'retroConnectionTimeoutHost' : 'retroConnectionTimeoutGuest',
    _ => 'ps1OnlineDisconnected',
  };

  /// The match is over: its room is ended or left, its folder deleted, and the lobby shows no
  /// match.
  Future<void> _retroOnlineDone(RetroOnline online, Ps1LockstepRoom? room) async {
    await online.link?.close();
    if (room != null) {
      try {
        await online.rooms?.leave(room);
      } on Object catch (error) {
        _padLog?.call('online: the room was not left: $error');
      }
    }
    final folder = online.folder;
    if (folder != null) {
      try {
        Directory(folder).deleteSync(recursive: true);
      } on FileSystemException catch (error) {
        _padLog?.call('online: the match folder stays: $error');
      }
    }
    if (identical(retroOnline, online)) retroOnline = null;
    if (!_disposed) _changed();
  }
}
