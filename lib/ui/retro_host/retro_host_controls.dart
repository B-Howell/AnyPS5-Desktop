import 'dart:async';

import '../../core/controllers/pad_info.dart';
import '../../core/controllers/pad_inventory.dart';
import '../../core/gamepad/feel.dart';
import '../../core/retro_host/retro_host_client.dart';
import '../../core/retro_host/retro_pad.dart';
import '../../core/retro_host/retro_seats.dart';
import 'retro_host_game.dart';

/// The launcher's controllers as a game reads them: which are connected, in the launcher's order
/// (Player 1 first), and each one's whole state.
class RetroPadReader {
  const RetroPadReader({required this.pads, required this.state});

  /// The reader's own pads, in the reader's order.
  factory RetroPadReader.inventory(PadInventory inventory) =>
      RetroPadReader(pads: () => [for (final pad in inventory.pads) pad.id], state: inventory.state);

  /// The ids of the controllers connected now.
  final List<String> Function() pads;

  /// Everything a controller holds now; null for one the reader does not know.
  final PadState? Function(String id) state;
}

/// Plays a [RetroHostGame] with the launcher's controllers: their state becomes `input` for the
/// port each one sits at ([RetroSeats]), port 2 is connected while a second controller is there
/// (`connectedPorts`), and the core's vibration goes to the controller at its port.
///
/// The controllers are read every [every], as the launcher's reader polls them. A port's state is
/// sent when it changes, and again in full whenever the game starts taking input (a game that
/// loaded, focus that came back), because the client zeroes both ports when it starts a game or
/// loses focus. While [suspended] (an in-game menu is open) both ports are sent as idle.
class RetroHostControls {
  RetroHostControls(
    this.game, {
    required this.pads,
    this.motors,
    this.every = const Duration(milliseconds: 16),
    this.rumbleHold = const Duration(seconds: 2),
  }) {
    _rumble = game.rumble.listen(_onRumble);
    _poll = Timer.periodic(every, (_) => poll());
    _rumbleRefresh = Timer.periodic(rumbleHold ~/ 2, (_) => _refreshRumble());
  }

  final RetroHostGame game;
  final RetroPadReader pads;

  /// The controllers' motors; null where the reader cannot turn them.
  final PadRumble? motors;

  final Duration every;

  /// How long one rumble order lasts. The protocol's `rumble` holds until the next one, but the
  /// launcher's readers stop the motors after the length they are given (SDL, evdev), so a level
  /// that is not zero is given again every half of this.
  final Duration rumbleHold;

  /// Settings › Controllers › Stick Dead Zone, in percent.
  int deadzonePercent = 0;

  /// Whether the core's vibration reaches the controllers.
  bool get vibration => _vibration;
  bool _vibration = true;
  set vibration(bool on) {
    if (_vibration == on) return;
    _vibration = on;
    if (!on) _stopMotors();
  }

  final RetroSeats seats = RetroSeats();

  late final StreamSubscription<RetroRumble> _rumble;
  late final Timer _poll;
  late final Timer _rumbleRefresh;
  final List<RetroPadInput?> _sent = List.filled(RetroSeats.portCount, null);
  final List<(int, int)> _levels = List.filled(RetroSeats.portCount, (0, 0));
  int _portsSent = 1;
  bool _suspended = false;
  bool _disposed = false;

  /// Whether the controllers' presses are kept from the game (an in-game menu is open): both
  /// ports are sent as idle until it is false again.
  bool get suspended => _suspended;
  set suspended(bool value) {
    if (_suspended == value) return;
    _suspended = value;
    poll();
  }

  /// Reads the controllers and sends what changed (tests drive this; the timer calls it).
  void poll() {
    if (_disposed) return;
    for (final change in seats.sync(pads.pads())) {
      if (!change.joined) _left(change);
    }
    if (!game.acceptsInput) {
      _sent.fillRange(0, _sent.length, null);
      if (!game.loaded) _portsSent = 1;
      return;
    }
    final count = seats.connectedPorts;
    if (count != _portsSent) {
      _portsSent = count;
      unawaited(game.connectedPorts(count));
    }
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final pad = seats.at(port);
      final state = pad == null ? null : pads.state(pad);
      final input = _suspended || state == null
          ? RetroPadInput.idle
          : RetroPadInput.fromPad(state, deadzonePercent: deadzonePercent);
      if (input == _sent[port]) continue;
      _sent[port] = input;
      game.input(
        port,
        input.buttons,
        leftX: input.leftX,
        leftY: input.leftY,
        rightX: input.rightX,
        rightY: input.rightY,
      );
    }
  }

  /// A controller left [change.port]: its motors stop (protocol.md "rumble": "when a controller
  /// leaves its port"), and the port is sent as idle by the next state that is sent.
  void _left(RetroSeatChange change) {
    if (_levels[change.port] != (0, 0)) {
      _levels[change.port] = (0, 0);
      _setMotors(change.pad, 0, 0);
    }
  }

  void _onRumble(RetroRumble event) {
    if (_disposed) return;
    _levels[event.port] = (event.strong, event.weak);
    final pad = seats.at(event.port);
    if (pad != null) _setMotors(pad, event.strong, event.weak);
  }

  void _refreshRumble() {
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final (strong, weak) = _levels[port];
      final pad = seats.at(port);
      if (pad != null && (strong != 0 || weak != 0)) _setMotors(pad, strong, weak);
    }
  }

  void _setMotors(String pad, int strong, int weak) {
    final rumble = motors;
    final on = strong != 0 || weak != 0;
    if (rumble == null || (on && !_vibration) || !rumble.canRumble(pad)) return;
    rumble.rumble(pad, strong / 0xFFFF, weak / 0xFFFF, on ? rumbleHold : Duration.zero);
  }

  void _stopMotors() {
    final rumble = motors;
    if (rumble == null) return;
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final pad = seats.at(port);
      if (pad != null && _levels[port] != (0, 0) && rumble.canRumble(pad)) rumble.rumble(pad, 0, 0, Duration.zero);
    }
  }

  /// Stops reading the controllers and stops any motor the game left running.
  void dispose() {
    if (_disposed) return;
    _poll.cancel();
    _rumbleRefresh.cancel();
    unawaited(_rumble.cancel());
    _stopMotors();
    _disposed = true;
  }
}
