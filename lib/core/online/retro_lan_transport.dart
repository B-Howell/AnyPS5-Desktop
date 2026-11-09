import 'dart:typed_data';

/// Frame routing for one private Ethernet segment. The caller supplies the
/// device's authenticated account ID from its room-bound peer connection.
/// Only virtual NICs attached to this match should receive the result.
final class RetroLanTransport {
  RetroLanTransport({required this.epoch, required this.me, required Map<String, int> addresses})
    : addresses = Map.unmodifiable(addresses) {
    if (epoch <= 0 ||
        epoch > 0xffffffff ||
        !addresses.containsKey(me) ||
        addresses.length < 2 ||
        addresses.length > 16 ||
        addresses.values.toSet().length != addresses.length ||
        addresses.values.any((mac) => mac <= 0 || mac > 0xffffffffffff || _group(mac))) {
      throw ArgumentError('A virtual LAN needs a match epoch and distinct unicast MAC addresses.');
    }
  }

  static const _magic = 0x524c4e01; // RLN followed by wire version 1.
  static const _headerSize = 8;
  static const _minFrame = 14;
  static const _maxFrame = 1514;

  final int epoch;
  final String me;
  final Map<String, int> addresses;
  bool _closed = false;

  /// One encoded Ethernet frame and the room members it should reach.
  ({List<String> recipients, Uint8List packet})? outbound(Uint8List frame) {
    if (_closed || !_validSize(frame.length) || _mac(frame, 6) != addresses[me]) return null;
    final destination = _mac(frame, 0);
    final recipients = [
      for (final entry in addresses.entries)
        if (entry.key != me && (_group(destination) || entry.value == destination)) entry.key,
    ];
    if (recipients.isEmpty) return null;
    final packet = Uint8List(_headerSize + frame.length);
    ByteData.sublistView(packet)
      ..setUint32(0, _magic)
      ..setUint32(4, epoch);
    packet.setRange(_headerSize, packet.length, frame);
    return (recipients: recipients, packet: packet);
  }

  /// Accept only this match's frames from the source MAC assigned to [sender].
  Uint8List? inbound(String sender, Uint8List packet) {
    if (_closed || sender == me || !_validSize(packet.length - _headerSize)) return null;
    final header = ByteData.sublistView(packet);
    if (header.getUint32(0) != _magic || header.getUint32(4) != epoch) return null;
    if (_mac(packet, _headerSize + 6) != addresses[sender]) return null;
    final destination = _mac(packet, _headerSize);
    if (!_group(destination) && destination != addresses[me]) return null;
    return packet.sublist(_headerSize);
  }

  void close() => _closed = true;

  static bool _validSize(int size) => size >= _minFrame && size <= _maxFrame;

  static bool _group(int address) => (address & 0x010000000000) != 0;

  static int _mac(Uint8List bytes, int offset) {
    var value = 0;
    for (var i = offset; i < offset + 6; i++) {
      value = (value << 8) | bytes[i];
    }
    return value;
  }
}
