part of 'app_model.dart';

/// The PS menu's Couch Co-op: the running game's player seats. Controllers on this computer take
/// seats by pressing Cross in the lobby; an open seat can go to an online friend instead.
extension CoopLobby on AppModel {
  /// Seats the emulated console has without a Multitap.
  int get coopSeats => switch (running?.$1.retro?.platform) {
    RetroPlatform.ps1 || RetroPlatform.ps2 => 2,
    _ => 1,
  };

  bool get coopAvailable => embeddedGame != null && running?.$1.retro != null && coopSeats > 1;

  String? get _playerOnePad => (controllers.playerOne ?? controllers.pads.firstOrNull)?.id;

  /// Controllers seated as Players 2 and up, in seat order, while they stay connected.
  List<PadState> localSeatStates() => [
    for (final id in localSeatPads) controllers.stateOf(id) ?? PadState.idle,
  ];

  List<PadInfo> get _unseatedPads => [
    for (final pad in controllers.pads)
      if (pad.id != _playerOnePad && !localSeatPads.contains(pad.id)) pad,
  ];

  bool get _seatFree => !together.ps1OnlineActive && 1 + localSeatPads.length < coopSeats;

  /// Cross from another controller in the lobby takes the next seat; Circle from a seated
  /// controller gives it back. The lobby's own navigation stays with Player 1.
  bool coopPadEvent(PadEvent event) {
    if (event is PadGone) {
      if (localSeatPads.remove(event.pad)) _changed();
      return false;
    }
    if (overlay != Layer.coopLobby || event is! PadButtonEvent || event.pad == _playerOnePad) return false;
    if (!event.down) return true;
    final seated = localSeatPads.contains(event.pad);
    if (seated && event.button == PadButton.east) {
      localSeatPads.remove(event.pad);
      sounds.play(Cue.back);
      _seatsChanged();
    } else if (!seated && event.button == PadButton.south && _seatFree) {
      localSeatPads.add(event.pad);
      sounds.play(Cue.select);
      _seatsChanged();
    }
    return true;
  }

  void _seatsChanged() {
    final rows = _currentRows;
    final focusable = [for (var index = 0; index < rows.length; index++) if (rows[index].focusable) index];
    if (focusable.isNotEmpty && !focusable.contains(panelRow)) panelRow = focusable.last;
    _changed();
  }

  String _coopSummary() {
    final online = together.ps1OnlineActive ? 1 : 0;
    final players = 1 + localSeatPads.length + online;
    if (players == 1) return T.text('coopLobbyEntryDetail');
    return online > 0 ? T.format('coopPlayersOnline', [players, online]) : T.format('coopPlayers', [players]);
  }

  PanelRow? coopQuickRow() {
    if (!coopAvailable) return null;
    return PanelRow(
      id: 'coop',
      title: T.text('coopLobbyTitle'),
      detail: _coopSummary(),
      kind: ActionRow(() => open(Layer.coopLobby)),
    );
  }

  List<PlayerSlot> coopSlots() {
    final me = together.user?.displayName ?? currentProfile?.name ?? T.text('coopYou');
    final online = together.ps1OnlineSlot();
    final hosting = online?.hosting ?? true;
    final playerOne = controllers.playerOne ?? controllers.pads.firstOrNull;
    final mine = PlayerSlot(
      player: hosting ? 1 : 2,
      name: me,
      status: [
        T.text(hosting ? 'coopController1' : 'coopController2'),
        if (playerOne != null) playerOne.name,
      ].join(' · '),
      you: true,
    );
    final others = <PlayerSlot>[];
    if (online != null) {
      others.add(PlayerSlot(player: hosting ? 2 : 1, name: online.name, status: online.status));
    }
    for (final id in localSeatPads) {
      others.add(PlayerSlot(
        player: 2 + others.length,
        name: T.text('coopGuest'),
        status: '${T.format('coopControllerN', [2 + others.length])} · ${controllers.roster.pad(id)?.name ?? ''}',
      ));
    }
    final waiting = _unseatedPads;
    final slots = <PlayerSlot>[if (hosting) ...[mine, ...others] else ...[...others, mine]];
    while (slots.length < coopSeats) {
      final player = slots.length + 1;
      final pad = slots.length - 1 - others.length < waiting.length && online == null
          ? waiting[slots.length - 1 - others.length]
          : null;
      slots.add(PlayerSlot(
        player: player,
        status: pad != null ? pad.name : T.text(together.ps1CanHostOnline ? 'coopInviteSeat' : 'coopOpen'),
        name: null,
        joinHint: pad != null,
      ));
    }
    while (slots.length < 4) {
      slots.add(PlayerSlot(player: slots.length + 1, status: T.text('coopTwoPlayers'), available: false));
    }
    return slots;
  }

  List<PanelRow> coopLobbyRows() => [
    PanelRow(
      id: 'coop-players',
      title: running?.$1.name ?? T.text('coopLobbyTitle'),
      kind: InfoRow(T.text(controllers.pads.length > 1 ? 'coopLobbyDetailJoin' : 'coopLobbyDetail')),
      playerSlots: coopSlots(),
    ),
    if (localSeatPads.isEmpty) ...together.ps1LobbyOnlineRows(),
    if (localSeatPads.isNotEmpty)
      PanelRow(
        id: 'coop-local-full',
        title: T.text('coopLocalFull'),
        kind: InfoRow(T.text('coopLocalFullDetail')),
      ),
    PanelRow(id: 'coop-back-to-game', title: T.text('coopBackToGame'), kind: ActionRow(resumeGame)),
  ];
}
