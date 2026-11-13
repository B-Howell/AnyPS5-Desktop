import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ps1_netplay_wire.dart';

typedef Ps1CheckpointSnapshot = ({int frame, Uint8List state});

/// Single-use transfer over the authenticated, reliable ordered match channel.
/// Acknowledgements bound the number of bytes queued in the data channel.
final class Ps1CheckpointTransfer {
  Ps1CheckpointTransfer({required this.host, required this.epoch, required this.send});

  static const maxStateBytes = 12 * 1024 * 1024;
  static const _chunkBytes = 8 * 1024;
  static const _windowBytes = 8 * _chunkBytes;
  static const _magic = 0x41503143; // AP1C
  static const _header = 13;
  static const _manifest = 40;
  static const _begin = 1;
  static const _chunk = 2;
  static const _ack = 3;

  final bool host;
  final int epoch;
  final void Function(Uint8List) send;
  final _received = Completer<Ps1CheckpointSnapshot?>();
  final _delivered = Completer<bool>();
  Uint8List? _outgoing;
  Uint8List? _incoming;
  List<int>? _digest;
  int _frame = 0;
  int _offset = 0;
  int _acknowledged = 0;
  bool _sending = false;
  bool _closed = false;

  Future<Ps1CheckpointSnapshot?> get received => _received.future;

  static bool isCheckpointPacket(Uint8List packet) =>
      packet.length >= 4 && ByteData.sublistView(packet).getUint32(0) == _magic;

  Future<bool> deliver(Ps1CheckpointSnapshot snapshot) async {
    if (!host || _outgoing != null || _closed || _delivered.isCompleted) {
      throw StateError('The PS1 checkpoint transfer is unavailable.');
    }
    final bytes = snapshot.state;
    if (bytes.isEmpty || bytes.length > maxStateBytes || snapshot.frame < 0 || snapshot.frame > Ps1InputWire.maxFrame) {
      throw ArgumentError('The PS1 checkpoint has an invalid frame or size.');
    }
    _outgoing = Uint8List.fromList(bytes);
    final packet = _packet(_begin, _manifest);
    ByteData.sublistView(packet)
      ..setUint32(_header, snapshot.frame)
      ..setUint32(_header + 4, bytes.length);
    packet.setRange(_header + 8, packet.length, sha256.convert(_outgoing!).bytes);
    send(packet);
    _sendWindow();
    return _delivered.future;
  }

  void receive(Uint8List packet) {
    if (_closed || packet.length < _header || !isCheckpointPacket(packet)) throw const FormatException();
    final view = ByteData.sublistView(packet);
    if (view.getUint64(5) != epoch) throw const FormatException();
    switch (packet[4]) {
      case _begin when !host:
        if (_incoming != null || _received.isCompleted || packet.length != _header + _manifest) {
          throw const FormatException();
        }
        final size = view.getUint32(_header + 4);
        _frame = view.getUint32(_header);
        if (size == 0 || size > maxStateBytes || _frame > Ps1InputWire.maxFrame) throw const FormatException();
        _digest = packet.sublist(_header + 8);
        _incoming = Uint8List(size);
      case _chunk when !host:
        _readChunk(packet, view);
      case _ack when host:
        final bytes = _outgoing;
        if (bytes == null ||
            packet.length != _header + 4 ||
            _offset <= _acknowledged ||
            (_offset != bytes.length && _offset % _windowBytes != 0) ||
            view.getUint32(_header) != _offset) {
          throw const FormatException();
        }
        _acknowledged = _offset;
        if (_offset == bytes.length) {
          _outgoing = null;
          _delivered.complete(true);
        } else {
          _sendWindow();
        }
      default:
        throw const FormatException();
    }
  }

  void _readChunk(Uint8List packet, ByteData view) {
    final bytes = _incoming;
    final length = packet.length - _header - 4;
    if (bytes == null ||
        length <= 0 ||
        length != math.min(_chunkBytes, bytes.length - _offset) ||
        view.getUint32(_header) != _offset) {
      throw const FormatException();
    }
    bytes.setRange(_offset, _offset + length, packet, _header + 4);
    _offset += length;
    if (_offset == bytes.length) {
      final actual = sha256.convert(bytes).bytes;
      if (actual.indexed.any((entry) => entry.$2 != _digest![entry.$1])) throw const FormatException();
      _incoming = null;
      _received.complete((frame: _frame, state: bytes));
    }
    if (_offset == bytes.length || _offset % _windowBytes == 0) {
      final ack = _packet(_ack, 4);
      ByteData.sublistView(ack).setUint32(_header, _offset);
      send(ack);
    }
  }

  void _sendWindow() {
    if (_sending) return;
    _sending = true;
    try {
      while (!_closed && _outgoing != null && _offset == _acknowledged) {
        final bytes = _outgoing!;
        final end = math.min(bytes.length, _offset + _windowBytes);
        while (!_closed && _offset < end) {
          final next = math.min(end, _offset + _chunkBytes);
          final packet = _packet(_chunk, 4 + next - _offset);
          ByteData.sublistView(packet).setUint32(_header, _offset);
          packet.setRange(_header + 4, packet.length, bytes, _offset);
          _offset = next;
          send(packet);
        }
      }
    } finally {
      _sending = false;
    }
  }

  Uint8List _packet(int kind, int length) {
    final packet = Uint8List(_header + length);
    ByteData.sublistView(packet)
      ..setUint32(0, _magic)
      ..setUint8(4, kind)
      ..setUint64(5, epoch);
    return packet;
  }

  void close() {
    _closed = true;
    _incoming = null;
    _outgoing = null;
    if (!_received.isCompleted) _received.complete(null);
    if (!_delivered.isCompleted) _delivered.complete(false);
  }
}
