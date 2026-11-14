import 'dart:typed_data';

import 'online_wire.dart';

/// Libretro's sixteen joypad buttons and signed left and right stick axes.
typedef Ps1PadInput = ({int buttons, int leftX, int leftY, int rightX, int rightY});
typedef Ps1FrameInputs = (Ps1PadInput, Ps1PadInput);

class Ps1InputPacket {
  const Ps1InputPacket({
    required this.epoch,
    required this.seat,
    required this.sequence,
    required this.acknowledgedFrame,
    required this.firstFrame,
    required this.inputs,
  });

  /// Nonzero 64-bit match epoch. Dart represents its bit pattern as a signed int.
  final int epoch;

  /// The assigned Libretro port, 0 or 1.
  final int seat;
  final int sequence;

  /// Highest contiguous frame received from the other seat, or null before the first.
  final int? acknowledgedFrame;

  final int firstFrame;

  /// Full snapshots in ascending, contiguous frame order, ending with the latest.
  final List<Ps1PadInput> inputs;
  int get lastFrame => firstFrame + inputs.length - 1;
}

/// Unordered PS1 input datagrams. The independent magic separates them from the PS5 protocol.
/// The authenticated channel assigns the peer and supplies the expected epoch, seat and window.
/// Sequence replay protection and acknowledgement advancement belong to that peer's session.
abstract final class Ps1InputWire {
  static const version = 1;
  static const maxInputs = 8;
  static const maxFrameWindow = 512;
  static const maxFrame = 0xFFFFFFFE;
  static const maxPacketSize = _headerSize + maxInputs * _inputSize;

  static const _magic = 0x49315041; // AP1I
  static const _headerSize = 28;
  static const _inputSize = 10;
  static const _noAcknowledgement = 0xFFFFFFFF;
  static const _maxSequence = 0xFFFFFFFF;

  static Uint8List encode(Ps1InputPacket packet) {
    final acknowledged = packet.acknowledgedFrame;
    if (packet.epoch == 0 ||
        !_validSeat(packet.seat) ||
        packet.sequence < 0 ||
        packet.sequence > _maxSequence ||
        (acknowledged != null && !_validFrame(acknowledged)) ||
        !_validFrame(packet.firstFrame) ||
        packet.inputs.isEmpty ||
        packet.inputs.length > maxInputs ||
        !_validFrame(packet.lastFrame)) {
      throw ArgumentError('Invalid PS1 input packet header.');
    }
    final writer = WireWriter()
      ..u32(_magic)
      ..u8(version)
      ..u8(packet.seat)
      ..u8(packet.inputs.length)
      ..u8(0)
      ..u64(packet.epoch)
      ..u32(packet.sequence)
      ..u32(acknowledged ?? _noAcknowledgement)
      ..u32(packet.firstFrame);
    for (final pad in packet.inputs) {
      if (pad.buttons < 0 ||
          pad.buttons > 0xFFFF ||
          !_validAxis(pad.leftX) ||
          !_validAxis(pad.leftY) ||
          !_validAxis(pad.rightX) ||
          !_validAxis(pad.rightY)) {
        throw ArgumentError('Invalid PS1 pad snapshot.');
      }
      writer
        ..u16(pad.buttons)
        ..u16(pad.leftX)
        ..u16(pad.leftY)
        ..u16(pad.rightX)
        ..u16(pad.rightY);
    }
    return writer.data;
  }

  /// Returns null for malformed datagrams or data outside the current peer's bounds.
  ///
  /// Both ends of the inclusive window refer to retained timeline frames. Keep the redundant
  /// prefix inside that window, even if some of its snapshots are already known.
  static Ps1InputPacket? decode(
    Uint8List bytes, {
    required int expectedEpoch,
    required int expectedSeat,
    required int oldestFrame,
    required int newestFrame,
    required int? lastSentFrame,
  }) {
    if (bytes.length < _headerSize + _inputSize ||
        bytes.length > maxPacketSize ||
        expectedEpoch == 0 ||
        !_validSeat(expectedSeat) ||
        !_validFrame(oldestFrame) ||
        !_validFrame(newestFrame) ||
        newestFrame < oldestFrame ||
        newestFrame - oldestFrame >= maxFrameWindow ||
        (lastSentFrame != null && !_validFrame(lastSentFrame))) {
      return null;
    }
    final reader = WireReader(bytes);
    if (reader.u32() != _magic || reader.u8() != version || reader.u8() != expectedSeat) return null;
    final count = reader.u8();
    if (count == 0 ||
        count > maxInputs ||
        bytes.length != _headerSize + count * _inputSize ||
        reader.u8() != 0 ||
        reader.u64() != expectedEpoch) {
      return null;
    }
    final sequence = reader.u32();
    final ack = reader.u32();
    final firstFrame = reader.u32();
    if (firstFrame < oldestFrame ||
        firstFrame + count - 1 > newestFrame ||
        (ack != _noAcknowledgement && (lastSentFrame == null || ack > lastSentFrame))) {
      return null;
    }
    return Ps1InputPacket(
      epoch: expectedEpoch,
      seat: expectedSeat,
      sequence: sequence,
      acknowledgedFrame: ack == _noAcknowledgement ? null : ack,
      firstFrame: firstFrame,
      inputs: List<Ps1PadInput>.unmodifiable([
        for (var index = 0; index < count; index++)
          (
            buttons: reader.u16(),
            leftX: reader.u16().toSigned(16),
            leftY: reader.u16().toSigned(16),
            rightX: reader.u16().toSigned(16),
            rightY: reader.u16().toSigned(16),
          ),
      ]),
    );
  }

  static bool _validSeat(int seat) => seat == 0 || seat == 1;
  static bool _validFrame(int frame) => frame >= 0 && frame <= maxFrame;
  static bool _validAxis(int axis) => axis >= -32768 && axis <= 32767;
}
