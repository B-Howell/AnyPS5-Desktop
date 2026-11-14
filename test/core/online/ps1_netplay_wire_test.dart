import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:test/test.dart';

const _epoch = 0x8877665544332211;
const _neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);
const _pad = (buttons: 0x8041, leftX: -32768, leftY: 32767, rightX: -1, rightY: 1);

Ps1InputPacket _packet({
  int epoch = _epoch,
  int seat = 1,
  int sequence = 0x12345678,
  int? acknowledgedFrame = 9,
  int firstFrame = 10,
  List<Ps1PadInput> inputs = const [_pad, _neutral],
}) => Ps1InputPacket(
  epoch: epoch,
  seat: seat,
  sequence: sequence,
  acknowledgedFrame: acknowledgedFrame,
  firstFrame: firstFrame,
  inputs: inputs,
);

Ps1InputPacket? _read(
  Uint8List bytes, {
  int epoch = _epoch,
  int seat = 1,
  int oldest = 8,
  int newest = 18,
  int? lastSent = 10,
}) => Ps1InputWire.decode(
  bytes,
  expectedEpoch: epoch,
  expectedSeat: seat,
  oldestFrame: oldest,
  newestFrame: newest,
  lastSentFrame: lastSent,
);

void main() {
  test('locks packet bytes and round-trips complete signed snapshots', () {
    final bytes = Ps1InputWire.encode(_packet());
    expect(
      OnlineWire.hex(bytes),
      '4150314901010200'
      '1122334455667788'
      '78563412090000000a000000'
      '41800080ff7fffff0100'
      '00000000000000000000',
    );
    final parsed = _read(bytes)!;
    expect(parsed.epoch, _epoch);
    expect(parsed.seat, 1);
    expect(parsed.sequence, 0x12345678);
    expect(parsed.acknowledgedFrame, 9);
    expect(parsed.firstFrame, 10);
    expect(parsed.lastFrame, 11);
    expect(parsed.inputs, [_pad, _neutral]);
    expect(() => parsed.inputs[0] = _neutral, throwsUnsupportedError);
    expect(Ps1InputWire.encode(parsed), bytes);
  });

  test('carries redundant inputs after loss and accepts out-of-order delivery', () {
    final older = _packet(sequence: 1, firstFrame: 10, inputs: const [_pad]);
    final newer = _packet(sequence: 2, firstFrame: 10, inputs: const [_pad, _neutral]);
    final recovered = _read(Ps1InputWire.encode(newer))!;
    expect(recovered.inputs[10 - recovered.firstFrame], _pad);
    expect(recovered.inputs[11 - recovered.firstFrame], _neutral);
    expect(_read(Ps1InputWire.encode(older))!.sequence, 1, reason: 'deduplication belongs to the session');
  });

  test('distinguishes no acknowledgement from acknowledging frame zero', () {
    final none = Ps1InputWire.encode(_packet(acknowledgedFrame: null, firstFrame: 0));
    expect(OnlineWire.hex(none.sublist(20, 24)), 'ffffffff');
    expect(_read(none, oldest: 0, lastSent: null)!.acknowledgedFrame, isNull);
    final zero = Ps1InputWire.encode(_packet(acknowledgedFrame: 0));
    expect(_read(zero, lastSent: 0)!.acknowledgedFrame, 0);
    expect(_read(zero, lastSent: null), isNull);
  });

  test('rejects a different epoch, seat, frame window or unsent acknowledgement', () {
    final bytes = Ps1InputWire.encode(_packet());
    expect(_read(bytes, epoch: 42), isNull);
    expect(_read(bytes, seat: 0), isNull);
    expect(_read(bytes, oldest: 11), isNull);
    expect(_read(bytes, newest: 10), isNull);
    expect(_read(bytes, lastSent: 8), isNull);
    expect(_read(bytes, oldest: 0, newest: Ps1InputWire.maxFrameWindow), isNull);
    expect(_read(bytes, oldest: 10, newest: 11, lastSent: 9), isNotNull);
  });

  test('rejects wrong magic/version, reserved bytes, invalid count, and malformed lengths', () {
    final valid = Ps1InputWire.encode(_packet());
    for (final (offset, value) in [(0, 0), (4, 2), (5, 2), (6, 0), (6, 9), (7, 1)]) {
      expect(_read(Uint8List.fromList(valid)..[offset] = value), isNull, reason: 'byte $offset value $value');
    }
    for (var length = 0; length < valid.length; length++) {
      expect(_read(Uint8List.sublistView(valid, 0, length)), isNull, reason: 'truncated to $length');
    }
    expect(_read(Uint8List.fromList([...valid, 0])), isNull);
    expect(_read(Uint8List(Ps1InputWire.maxPacketSize + 1)), isNull);
    final overflow = Uint8List.fromList(valid);
    ByteData.sublistView(overflow).setUint32(24, Ps1InputWire.maxFrame, Endian.little);
    expect(_read(overflow, oldest: Ps1InputWire.maxFrame, newest: Ps1InputWire.maxFrame), isNull);
  });

  test('bounds the full batch and keeps encoded fields from silently wrapping', () {
    final batch = List<Ps1PadInput>.filled(Ps1InputWire.maxInputs, _neutral);
    final bytes = Ps1InputWire.encode(_packet(firstFrame: 0, inputs: batch));
    expect(bytes.length, Ps1InputWire.maxPacketSize);
    expect(_read(bytes, oldest: 0)!.inputs, hasLength(Ps1InputWire.maxInputs));
    for (final invalid in [
      _packet(epoch: 0),
      _packet(seat: -1),
      _packet(seat: 2),
      _packet(sequence: -1),
      _packet(sequence: 0x100000000),
      _packet(acknowledgedFrame: -1),
      _packet(acknowledgedFrame: Ps1InputWire.maxFrame + 1),
      _packet(firstFrame: -1),
      _packet(firstFrame: Ps1InputWire.maxFrame),
      _packet(inputs: []),
      _packet(inputs: [...batch, _pad]),
      _packet(inputs: const [(buttons: 65536, leftX: 0, leftY: 0, rightX: 0, rightY: 0)]),
      _packet(inputs: const [(buttons: -1, leftX: 0, leftY: 0, rightX: 0, rightY: 0)]),
      _packet(inputs: const [(buttons: 0, leftX: -32769, leftY: 0, rightX: 0, rightY: 0)]),
      _packet(inputs: const [(buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 32768)]),
    ]) {
      expect(() => Ps1InputWire.encode(invalid), throwsArgumentError);
    }
  });
}
