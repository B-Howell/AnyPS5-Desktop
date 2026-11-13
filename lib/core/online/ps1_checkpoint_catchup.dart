import 'dart:async';
import 'dart:typed_data';

import 'ps1_netplay_wire.dart';

typedef Ps1CatchupSource = ({
  Future<int> Function() hold,
  Future<({int nextFrame, List<Ps1FrameInputs> frames})> Function(int first) read,
});
typedef Ps1CatchupReplay = Future<void> Function(int first, List<Ps1FrameInputs> frames);

/// Replays the gap between a restored checkpoint and the host's held frame.
/// One batch is in flight. The guest acknowledges only after native replay.
final class Ps1CheckpointCatchup {
  Ps1CheckpointCatchup({required this.epoch, required this.send, this.replay});

  static const maxFrames = 1024;
  static const maxBatch = 120;
  static const _magic = 0x41503148; // AP1H
  static const _header = 17;
  static const _frameBytes = 20;
  static const _ready = 1;
  static const _batch = 2;
  static const _acknowledge = 3;
  static const _cutover = 4;
  static const _cutoverAck = 5;

  final int epoch;
  final void Function(Uint8List) send;
  final Ps1CatchupReplay? replay;
  final _guestReady = Completer<int?>();
  final _guestDone = Completer<int?>();
  Completer<bool>? _ack;
  (int, int)? _expectedAck;
  int? _guestFirst;
  int? _guestCursor;
  bool _replaying = false;
  bool _closed = false;

  static bool isCatchupPacket(Uint8List packet) =>
      packet.length >= 4 && ByteData.sublistView(packet).getUint32(0) == _magic;

  Future<int?> deliver(int first, Ps1CatchupSource source) async {
    final ready = await _guestReady.future;
    if (_closed || ready == null) return null;
    if (ready != first) throw const FormatException('Guest restored the wrong frame.');
    final target = await source.hold();
    if (_closed) return null;
    if (target < first || target > Ps1InputWire.maxFrame || target - first > maxFrames) {
      throw StateError('The host checkpoint history expired.');
    }
    var cursor = first;
    while (cursor < target) {
      final batch = await source.read(cursor);
      if (_closed) return null;
      final frames = batch.frames;
      final next = cursor + frames.length;
      if (batch.nextFrame != target || frames.isEmpty || frames.length > maxBatch || next > target) {
        throw StateError('The held host returned inconsistent input history.');
      }
      final packet = _packet(_batch, cursor, frames.length * _frameBytes);
      final data = ByteData.sublistView(packet);
      var offset = _header;
      for (final (first, second) in frames) {
        for (final pad in [first, second]) {
          _writePad(data, offset, pad);
          offset += 10;
        }
      }
      if (!await _sendAndWait(packet, next)) return null;
      cursor = next;
    }
    return await _sendAndWait(_packet(_cutover, target), target, kind: _cutoverAck) ? target : null;
  }

  Future<int?> waitForCutover(int first) {
    if (_closed) return Future.value(null);
    if (replay == null || _guestFirst != null || first < 0 || first > Ps1InputWire.maxFrame) {
      throw StateError('Invalid PS1 catch-up start.');
    }
    _guestFirst = _guestCursor = first;
    send(_packet(_ready, first));
    return _guestDone.future;
  }

  Future<void> receive(Uint8List packet) async {
    if (_closed || packet.length < _header || !isCatchupPacket(packet)) throw const FormatException();
    final data = ByteData.sublistView(packet);
    final kind = data.getUint8(4);
    final cursor = data.getUint32(13);
    if (data.getUint64(5) != epoch || cursor > Ps1InputWire.maxFrame) throw const FormatException();
    final payload = packet.length - _header;
    final guestReplay = replay;
    if (guestReplay == null) {
      if (payload != 0) throw const FormatException();
      if (kind == _ready && !_guestReady.isCompleted) {
        _guestReady.complete(cursor);
      } else if (_ack != null && (kind, cursor) == _expectedAck) {
        final ack = _ack!;
        _ack = null;
        ack.complete(true);
      } else {
        throw const FormatException();
      }
      return;
    }
    if (_guestCursor != cursor || _replaying || _guestDone.isCompleted) throw const FormatException();
    if (kind == _cutover && payload == 0) {
      send(_packet(_cutoverAck, cursor));
      _guestDone.complete(cursor);
      return;
    }
    final count = payload ~/ _frameBytes;
    final end = cursor + count;
    if (kind != _batch ||
        count == 0 ||
        count > maxBatch ||
        payload % _frameBytes != 0 ||
        end > Ps1InputWire.maxFrame ||
        end - _guestFirst! > maxFrames) {
      throw const FormatException();
    }
    final frames = [
      for (var offset = _header; offset < packet.length; offset += _frameBytes)
        (_readPad(data, offset), _readPad(data, offset + 10)),
    ];
    _replaying = true;
    try {
      await guestReplay(cursor, frames);
    } finally {
      _replaying = false;
    }
    if (_closed) return;
    _guestCursor = end;
    send(_packet(_acknowledge, end));
  }

  Future<bool> _sendAndWait(Uint8List packet, int cursor, {int kind = _acknowledge}) {
    if (_closed) return Future.value(false);
    final ack = _ack = Completer<bool>();
    _expectedAck = (kind, cursor);
    send(packet);
    return ack.future;
  }

  Uint8List _packet(int kind, int frame, [int payload = 0]) {
    final packet = Uint8List(_header + payload);
    ByteData.sublistView(packet)
      ..setUint32(0, _magic)
      ..setUint8(4, kind)
      ..setUint64(5, epoch)
      ..setUint32(13, frame);
    return packet;
  }

  static void _writePad(ByteData data, int offset, Ps1PadInput pad) {
    data
      ..setUint16(offset, pad.buttons)
      ..setInt16(offset + 2, pad.leftX)
      ..setInt16(offset + 4, pad.leftY)
      ..setInt16(offset + 6, pad.rightX)
      ..setInt16(offset + 8, pad.rightY);
  }

  static Ps1PadInput _readPad(ByteData data, int offset) => (
    buttons: data.getUint16(offset),
    leftX: data.getInt16(offset + 2),
    leftY: data.getInt16(offset + 4),
    rightX: data.getInt16(offset + 6),
    rightY: data.getInt16(offset + 8),
  );

  void close() {
    _closed = true;
    _ack?.complete(false);
    _ack = null;
    if (!_guestReady.isCompleted) _guestReady.complete(null);
    if (!_guestDone.isCompleted) _guestDone.complete(null);
  }
}
