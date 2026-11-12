part of 'app_model.dart';

extension RetroEmbeddedControls on AppModel {
  static const _buttonKeys = {
    PadButton.south: 'retroButtonCross',
    PadButton.east: 'retroButtonCircle',
    PadButton.west: 'retroButtonSquare',
    PadButton.north: 'retroButtonTriangle',
    PadButton.dpadUp: 'retroButtonUp',
    PadButton.dpadDown: 'retroButtonDown',
    PadButton.dpadLeft: 'retroButtonLeft',
    PadButton.dpadRight: 'retroButtonRight',
    PadButton.l1: 'retroButtonL1',
    PadButton.r1: 'retroButtonR1',
    PadButton.l2: 'retroButtonL2',
    PadButton.r2: 'retroButtonR2',
    PadButton.l3: 'retroButtonL3',
    PadButton.r3: 'retroButtonR3',
    PadButton.select: 'retroButtonSelect',
    PadButton.start: 'retroButtonStart',
  };

  static const _buttonRow = 'retroButton-';

  static PadGlyph? _glyph(PadButton button) => switch (button) {
    PadButton.south => PadGlyph.cross,
    PadButton.east => PadGlyph.circle,
    PadButton.west => PadGlyph.square,
    PadButton.north => PadGlyph.triangle,
    _ => null,
  };

  static String buttonName(PadButton? button) => button == null ? T.text('retroButtonOff') : T.text(_buttonKeys[button]!);

  /// The button that goes back in the launcher's menus: tapped while a label waits, it cancels.
  PadButton get _backButton => preferences.confirmCircle ? PadButton.south : PadButton.east;

  /// The console button a Controls row is about, from the row's id.
  static PadButton? rowButton(String rowId) => rowId.startsWith(_buttonRow)
      ? RetroButtonMap.buttons.where((button) => button.name == rowId.substring(_buttonRow.length)).firstOrNull
      : null;

  /// The layout [player] plays [game] with: the profile or layout chosen on that game's page.
  RetroButtonMap retroLayout(Game game, int player) =>
      game.retro == null ? RetroButtonMap.standard : preferences.retroControls.resolve(game.id, player);

  /// The controller of the player the Controls page shows, or null when that seat has none.
  /// Player 1 is whoever is driving the launcher: the controller that last moved the focus, when
  /// it is not one seated as another player, else the launcher's Player 1.
  String? get retroControlsPadId {
    if (retroControlsPlayer <= 1) {
      // Never a controller seated as another player: using one moves it to the front of the
      // launcher's list, so that list's first is no proof of whose it is.
      final free = [
        for (final pad in controllers.pads)
          if (!localSeatPads.contains(pad.id)) pad.id,
      ];
      final driving = _navigator?.lastPad;
      if (free.contains(driving)) return driving;
      final first = controllers.playerOne?.id;
      return free.contains(first) ? first : free.firstOrNull;
    }
    final index = retroControlsPlayer - 2;
    return index < localSeatPads.length ? localSeatPads[index] : null;
  }

  /// The players [game]'s Controls page sets up: the running game's seats, else two for PS1 and
  /// PS2 and one for PS3. The page never shows a player past them.
  int retroControlsPlayers(Game game) =>
      running?.$1.id == game.id ? coopSeats : (game.retro?.platform == RetroPlatform.ps3 ? 1 : 2);

  String _retroScope(Game game) => RetroControlProfiles.scope(game.id, retroControlsPlayer);

  /// What Player 1 plays [game] with, as the PS menu's Controls row says it. Always Player 1's:
  /// the player the Controls page showed last is not the one this summary is about.
  String _retroControlsSummary(Game game) {
    if (game.retro == null) return T.text('retroControlsStandard');
    final controls = preferences.retroControls;
    final scope = RetroControlProfiles.scope(game.id, 1);
    return controls.profileOf(scope) ??
        switch (controls.layoutOf(scope).preset) {
          RetroControlPreset.standard => T.text('retroControlsStandard'),
          RetroControlPreset.swapCrossCircle => T.text('retroSwapCrossCircle'),
          RetroControlPreset.custom => T.text('retroControlsCustom'),
        };
  }

  /// [change] made to the profiles or layouts: it reaches the game being played, every seat of
  /// it, and is saved. A row can appear or go with it (Save as a profile), so the focus is put
  /// back on the row it was on, or on Profile when that row is gone: never on whatever row
  /// happens to have taken its place.
  void _changeRetroControls(void Function() change) {
    final rows = _currentRows;
    final focused = panelRow >= 0 && panelRow < rows.length ? rows[panelRow].id : null;
    change();
    final after = _currentRows;
    final row = after.indexWhere((row) => row.id == focused);
    final profile = after.indexWhere((row) => row.id == 'retroControlsPreset');
    panelRow = row >= 0 ? row : (profile >= 0 ? profile : 0);
    _retroControlsChanged();
  }

  void _retroControlsChanged() {
    final playing = running?.$1;
    if (playing != null && playing.retro != null) {
      embeddedGame?.setButtonMap(retroLayout(playing, 1));
      for (var player = 2; player <= RetroControlProfiles.players; player++) {
        embeddedGame?.setSeatButtonMap(player, retroLayout(playing, player));
      }
    }
    savePreferences();
    _changed();
  }

  void _editRetroLayout(Game game, RetroButtonMap map) =>
      _changeRetroControls(() => preferences.retroControls.edit(_retroScope(game), map));

  /// The focus put on the label of [function]: a row that is drawn on the controller.
  void _focusRetroLabel(PadButton function) {
    final row = _currentRows.indexWhere((row) => row.id == '$_buttonRow${function.name}');
    if (row < 0) return;
    panelRow = row;
    retroLabelFocus = function;
  }

  /// How far the held button is towards taking the waiting label's input, 0 to 1.
  double get retroCaptureProgress => retroCaptureHeld == null
      ? 0
      : (_retroHoldWatch.elapsedMilliseconds / AppModel.retroCaptureHold.inMilliseconds).clamp(0.0, 1.0);

  /// A label on the controller chosen: it waits for a button to be held, which then takes over
  /// [function]. Choosing the label that is already waiting cancels. With no controller for the
  /// player shown there is nothing to wait for, and it says so.
  void startRetroCapture(PadButton function) {
    if (retroCapture == function) return cancelRetroCapture();
    _endRetroCapture();
    if (retroControlsPadId == null) {
      _focusRetroLabel(function);
      sounds.play(Cue.bump);
      show(T.format('retroControlsNoPad', ['$retroControlsPlayer']));
      _changed();
      return;
    }
    retroCapture = function;
    _focusRetroLabel(function);
    _retroCaptureTimer = Timer(AppModel.retroCaptureWait, _retroCaptureExpired);
    _navigator?.reset();
    sounds.play(Cue.select);
    _changed();
  }

  void cancelRetroCapture() {
    if (retroCapture == null) return;
    _endRetroCapture();
    _navigator?.reset();
    sounds.play(Cue.back);
    _changed();
  }

  void _endRetroCapture() {
    _retroCaptureTimer?.cancel();
    _retroHoldTimer?.cancel();
    _retroHoldWatch
      ..stop()
      ..reset();
    retroCaptureHeld = null;
    retroCaptureHeldPad = null;
    retroCapture = null;
  }

  /// The wait is over. A button being held at that moment gets to finish its hold.
  void _retroCaptureExpired() {
    if (retroCaptureHeld == null) return cancelRetroCapture();
    _retroCaptureTimer = Timer(AppModel.retroCaptureHold, cancelRetroCapture);
  }

  void _releaseRetroHold() {
    _retroHoldTimer?.cancel();
    _retroHoldWatch
      ..stop()
      ..reset();
    retroCaptureHeld = null;
    retroCaptureHeldPad = null;
  }

  /// A controller's button while a label waits. Held for [AppModel.retroCaptureHold] on the
  /// controller of the player being set up, it takes the label's input (RetroButtonMap.give).
  /// Let go sooner it does nothing, except the Back button, whose tap cancels, from any
  /// controller.
  void captureRetroButton(PadButtonEvent event) {
    final function = retroCapture;
    final game = selectedGame;
    if (function == null || game?.retro == null) return cancelRetroCapture();
    if (event.pad != retroControlsPadId) {
      if (!event.down && event.button == _backButton) cancelRetroCapture();
      return;
    }
    if (!RetroButtonMap.buttons.contains(event.button)) {
      if (event.down) cancelRetroCapture();
      return;
    }
    if (!event.down) {
      // Back let go before its own hold was up is a tap, whatever else is being held.
      if (event.button == _backButton) return cancelRetroCapture();
      if (event.button != retroCaptureHeld) return;
      _releaseRetroHold();
      _changed();
      return;
    }
    retroCaptureHeld = event.button;
    retroCaptureHeldPad = event.pad;
    _retroHoldWatch
      ..reset()
      ..start();
    _retroHoldTimer?.cancel();
    _retroHoldTimer = Timer(AppModel.retroCaptureHold, () => _finishRetroCapture(game!, function, event.button));
    _changed();
  }

  void _finishRetroCapture(Game game, PadButton function, PadButton button) {
    final stillHere = overlay == Layer.controls && selectedGame?.id == game.id;
    if (retroCapture != function || retroCaptureHeld != button || !stillHere) return _endRetroCapture();
    _endRetroCapture();
    _navigator?.reset();
    sounds.play(Cue.select);
    show(T.format('retroControlsAssigned', [buttonName(function), buttonName(button)]));
    _editRetroLayout(game, preferences.retroControls.layoutOf(_retroScope(game)).give(function, button));
  }

  /// Where the focus goes from the label of [from]: along its side of the controller, or across
  /// to the label level with it on the other side. Null where there is nothing that way.
  static PadButton? _labelBeside(PadButton from, Command command) {
    const left = RetroButtonMap.leftSide, right = RetroButtonMap.rightSide, top = RetroButtonMap.topSide;
    if (top.contains(from)) {
      final first = from == top.first;
      return switch (command) {
        Command.left => first ? left.first : top.first,
        Command.right => first ? top.last : right.first,
        Command.down => first ? left[1] : right[1],
        _ => null,
      };
    }
    final onLeft = left.contains(from);
    final side = onLeft ? left : right;
    final index = side.indexOf(from);
    return switch (command) {
      Command.up => index > 0 ? side[index - 1] : (onLeft ? top.first : top.last),
      Command.down => index < side.length - 1 ? side[index + 1] : null,
      Command.left => onLeft ? null : left[index],
      Command.right => onLeft ? right[index] : null,
      _ => null,
    };
  }

  /// The Controls page's own moves, so the directions go where the screen shows things.
  ///
  /// The labels are rows after the list's last, drawn on the controller, and the page opens on
  /// one. Among them the directions follow their places. Right from the right-hand labels, or
  /// down from the last label of a side, goes to the list beside the controller. From the list,
  /// left comes back to the label the focus was last on, as does up from the first row.
  ///
  /// A controller changes a row's value only after choosing the row (_padPanelCommand), so with
  /// a controller left is free on every row and always goes back. The keys step a value with
  /// left and right at once, so with them left goes back only from a row that has no value.
  bool _retroLabelCommand(Command command) {
    if (overlay != Layer.controls || selectedGame?.retro == null || editingRow != null) return false;
    // A mirrored screen (Arabic, Urdu) swaps the list and the controller, and [command] comes
    // mirrored with it. The controller itself is drawn as it is, so among its labels the
    // direction pressed is what counts.
    final pressed = T.language.isRightToLeft ? command.mirrored : command;
    final rows = _currentRows;
    bool listed(PanelRow row) => row.focusable && rowButton(row.id) == null;
    final first = rows.indexWhere(listed), last = rows.lastIndexWhere(listed);
    final row = panelRow >= 0 && panelRow < rows.length ? rows[panelRow] : null;
    final current = row == null ? null : rowButton(row.id);
    void focus(int target) {
      if (target < 0 || target == panelRow) return sounds.play(Cue.bump);
      panelRow = target;
      sounds.play(Cue.move);
      _changed();
    }

    void toLabel(PadButton function) {
      final before = panelRow;
      _focusRetroLabel(function);
      if (panelRow == before) return sounds.play(Cue.bump);
      sounds.play(Cue.move);
      _changed();
    }

    if (current == null) {
      // A row being changed with a controller keeps every direction until that is done.
      if (_viaPad && editingValue != null) return false;
      // A name is typed, and a controller cannot type here: choosing the row with one would
      // leave it stuck in the field.
      if (_viaPad && command == Command.select && row?.kind is TextRow) {
        sounds.play(Cue.bump);
        show(T.text('retroProfileRenameKeys'));
        return true;
      }
      final valued = row?.kind is ChoiceRow || row?.kind is StepperRow || row?.kind is ToggleRow;
      final stepped = valued && !_viaPad;
      if ((command == Command.up && panelRow == first) || (command == Command.left && !stepped)) {
        toLabel(retroLabelFocus);
        return true;
      }
      if (command == Command.down && panelRow == last) {
        sounds.play(Cue.bump);
        return true;
      }
      return false;
    }
    if (command != Command.up && command != Command.down && command != Command.left && command != Command.right) {
      return false;
    }
    final next = _labelBeside(current, pressed);
    // The labels beside the list: the right-hand ones, or the left-hand ones on a mirrored screen.
    final outer = (T.language.isRightToLeft ? RetroButtonMap.leftSide : RetroButtonMap.rightSide).contains(current);
    if (next != null && !(command == Command.right && outer)) {
      toLabel(next);
    } else if ((command == Command.right && outer) || command == Command.down) {
      focus(first);
    } else {
      sounds.play(Cue.bump);
    }
    return true;
  }

  List<PanelRow> _retroControlRows(Game game, RetroPlatform platform) {
    final controls = preferences.retroControls;
    final scope = _retroScope(game);
    final map = controls.layoutOf(scope);
    final profile = controls.profileOf(scope);
    final names = controls.names;
    final custom = controls.layouts[scope]?.preset == RetroControlPreset.custom;
    final unsaved = profile == null && custom;
    final players = retroControlsPlayers(game);
    return [
      if (players > 1)
        PanelRow(
          id: 'retroControlsPlayer',
          title: T.text('retroControlsPlayer'),
          detail: T.text('retroControlsPlayerDetail'),
          kind: ChoiceRow(
            [for (var player = 1; player <= players; player++) T.format('coopPlayer', [player])],
            (retroControlsPlayer - 1).clamp(0, players - 1),
            (index) {
              retroControlsPlayer = index + 1;
              retroCapture = null;
              _changed();
            },
          ),
        ),
      PanelRow(
        id: 'retroControlsPreset',
        title: T.text('retroControlsPreset'),
        detail: T.text('retroControlsPresetDetail'),
        kind: ChoiceRow(
          [
            T.text('retroControlsStandard'),
            T.text('retroSwapCrossCircle'),
            ...names,
            if (custom) T.text('retroControlsCustom'),
          ],
          profile != null
              ? 2 + names.indexOf(profile)
              : switch (map.preset) {
                  RetroControlPreset.standard => 0,
                  RetroControlPreset.swapCrossCircle => 1,
                  RetroControlPreset.custom => 2 + names.length,
                },
          (index) => _changeRetroControls(() {
            if (index == 0) {
              controls.useLayout(scope, RetroButtonMap.standard);
            } else if (index == 1) {
              controls.useLayout(scope, RetroButtonMap.swapCrossCircle);
            } else if (index - 2 < names.length) {
              controls.useProfile(scope, names[index - 2]);
            } else {
              controls.useOwnLayout(scope);
            }
          }),
        ),
      ),
      if (unsaved)
        PanelRow(
          id: 'retroProfileSave',
          title: T.text('retroProfileSave'),
          detail: T.text('retroProfileSaveDetail'),
          kind: ActionRow(
            () => _changeRetroControls(() {
              final name = controls.saveAs(scope, controls.freeName((number) => T.format('retroProfileDefaultName', [number])));
              show(T.format('retroProfileSaved', [name]));
            }),
          ),
        ),
      if (profile != null) ...[
        PanelRow(
          id: 'retroProfileRename',
          title: T.text('retroProfileRename'),
          kind: TextRow(profile, (text) {
            if (text.trim() != profile && controls.rename(profile, text)) _retroControlsChanged();
          }, hint: profile),
        ),
        PanelRow(
          id: 'retroProfileDelete',
          title: T.text('retroProfileDelete'),
          detail: T.text('retroProfileDeleteDetail'),
          kind: ActionRow(() => _changeRetroControls(() => controls.delete(profile)), destructive: true),
        ),
      ],
      PanelRow(
        id: 'retroSwapSticks',
        title: T.text('retroSwapSticks'),
        detail: T.text(platform == RetroPlatform.ps1 ? 'retroSwapSticksPs1Detail' : 'retroSwapSticksDetail'),
        kind: ToggleRow(map.swapSticks, (value) => _editRetroLayout(game, map.withSwapSticks(value))),
      ),
      PanelRow(
        id: 'retroControlsReset',
        title: T.text('retroControlsReset'),
        kind: ActionRow(
          () => _changeRetroControls(() => controls.useLayout(scope, RetroButtonMap.standard)),
          destructive: !map.isStandard,
        ),
      ),
      // The controller's labels: not drawn in the list (panels.dart), but rows all the same, so
      // one can hold the focus and choosing it waits for a button (_retroLabelCommand).
      for (final function in [...RetroButtonMap.leftSide, ...RetroButtonMap.topSide, ...RetroButtonMap.rightSide])
        PanelRow(
          id: '$_buttonRow${function.name}',
          title: buttonName(function),
          glyph: _glyph(function),
          kind: ActionRow(() => startRetroCapture(function)),
        ),
    ];
  }
}
