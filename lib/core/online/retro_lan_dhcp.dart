import 'dart:typed_data';

/// Supplies one fixed IPv4 lease to the local console on a private room LAN.
/// The virtual server never sends packets to the host network or other peers.
final class RetroLanDhcp {
  const RetroLanDhcp({required this.mac, required this.address});

  static const _ethernet = 14;
  static const _ipv4Header = 20;
  static const _udpHeader = 8;
  static const _cookie = 0x63825363;
  static const _options = 240;
  static const _broadcastMac = 0xffffffffffff;
  static const _broadcastIp = 0xffffffff;
  static const _serverIp = 0x0ae70001;
  static const _serverMac = 0x0200000000fe;

  final int mac;
  final int address;

  /// DHCP and ARP for the virtual server stay off the peer link.
  static bool isLocalService(Uint8List frame) {
    if (_isArp(frame)) {
      final data = ByteData.sublistView(frame);
      return data.getUint32(28) == _serverIp || data.getUint32(38) == _serverIp;
    }
    final udp = _udpOffset(frame);
    if (udp == null) return false;
    final data = ByteData.sublistView(frame);
    final ports = (data.getUint16(udp), data.getUint16(udp + 2));
    return ports == (68, 67) || ports == (67, 68);
  }

  static int? _udpOffset(Uint8List frame) {
    if (frame.length < _ethernet + _ipv4Header + _udpHeader || frame[14] >> 4 != 4 || frame[23] != 17) return null;
    final data = ByteData.sublistView(frame);
    if (data.getUint16(12) != 0x0800 || data.getUint16(20) & 0x1fff != 0) return null;
    final headerLength = (frame[14] & 15) * 4;
    if (headerLength < _ipv4Header || _ethernet + headerLength + _udpHeader > frame.length) return null;
    return _ethernet + headerLength;
  }

  Uint8List? reply(Uint8List frame) {
    if (_isArp(frame)) return _arpReply(frame);
    final udp = _udpOffset(frame);
    if (udp == null || frame.length > 1514) return null;
    final data = ByteData.sublistView(frame);
    final boot = udp + _udpHeader;
    final end = udp + data.getUint16(udp + 4);
    final destination = _readMac(frame, 0);
    if (data.getUint16(udp) != 68 ||
        data.getUint16(udp + 2) != 67 ||
        data.getUint16(20) & 0x2000 != 0 ||
        end <= boot + _options ||
        end > _ethernet + data.getUint16(16) ||
        _ethernet + data.getUint16(16) > frame.length ||
        (destination != _broadcastMac && destination != _serverMac) ||
        _readMac(frame, 6) != mac ||
        frame[boot] != 1 ||
        frame[boot + 1] != 1 ||
        frame[boot + 2] != 6 ||
        data.getUint32(boot + 24) != 0 ||
        _readMac(frame, boot + 28) != mac ||
        data.getUint32(boot + 236) != _cookie) {
      return null;
    }

    int? type, requested, server;
    for (var index = boot + _options; index < end;) {
      final code = frame[index++];
      if (code == 0) continue;
      if (code == 255) {
        final current = data.getUint32(boot + 12);
        if (data.getUint32(26) != current) return null;
        if (server != null && server != _serverIp) return null;
        if (type == 3 && current != 0 && (requested != null || server != null)) return null;
        final response = switch (type) {
          1 when current == 0 => 2, // DISCOVER → OFFER.
          3 when (requested ?? current) == address => 5, // REQUEST → ACK.
          3 when (requested ?? current) != 0 => 6, // The requested lease belongs elsewhere.
          _ => null,
        };
        return response == null ? null : _response(data, boot, response, current);
      }
      if (index >= end) return null;
      final length = frame[index++];
      if (index + length > end) return null;
      switch (code) {
        case 53:
          if (length != 1 || type != null) return null;
          type = frame[index];
        case 50:
          if (length != 4 || requested != null) return null;
          requested = data.getUint32(index);
        case 54:
          if (length != 4 || server != null) return null;
          server = data.getUint32(index);
      }
      index += length;
    }
    return null;
  }

  static bool _isArp(Uint8List frame) => frame.length >= 42 && frame[12] == 8 && frame[13] == 6;

  Uint8List? _arpReply(Uint8List request) {
    final data = ByteData.sublistView(request);
    // Ethernet/IPv4 ARP with a request for the local DHCP server's address.
    if (data.getUint16(14) != 1 ||
        data.getUint16(16) != 0x0800 ||
        data.getUint16(18) != 0x0604 ||
        data.getUint16(20) != 1 ||
        data.getUint32(28) != address ||
        data.getUint32(38) != _serverIp ||
        _readMac(request, 6) != mac ||
        _readMac(request, 22) != mac) {
      return null;
    }
    final frame = Uint8List(60)..setRange(12, 20, request, 12);
    _writeMac(frame, 0, mac);
    _writeMac(frame, 6, _serverMac);
    _writeMac(frame, 22, _serverMac);
    _writeMac(frame, 32, mac);
    ByteData.sublistView(frame)
      ..setUint16(20, 2)
      ..setUint32(28, _serverIp)
      ..setUint32(38, address);
    return frame;
  }

  Uint8List _response(ByteData request, int start, int type, int current) {
    const udp = _ethernet + _ipv4Header;
    const boot = udp + _udpHeader;
    final frame = Uint8List(boot + 300);
    final data = ByteData.sublistView(frame);
    final flags = request.getUint16(start + 10);
    final broadcast = type == 6 || (current == 0 && flags & 0x8000 != 0);
    _writeMac(frame, 0, broadcast ? _broadcastMac : mac);
    _writeMac(frame, 6, _serverMac);
    data
      ..setUint16(12, 0x0800)
      ..setUint8(14, 0x45)
      ..setUint16(16, frame.length - _ethernet)
      ..setUint8(22, 64)
      ..setUint8(23, 17)
      ..setUint32(26, _serverIp)
      ..setUint32(30, broadcast ? _broadcastIp : address)
      ..setUint16(udp, 67)
      ..setUint16(udp + 2, 68)
      ..setUint16(udp + 4, frame.length - udp)
      ..setUint8(boot, 2)
      ..setUint8(boot + 1, 1)
      ..setUint8(boot + 2, 6)
      ..setUint32(boot + 4, request.getUint32(start + 4))
      ..setUint16(boot + 10, flags)
      ..setUint32(boot + 12, type == 5 ? current : 0)
      ..setUint32(boot + 16, type == 6 ? 0 : address)
      ..setUint32(boot + 236, _cookie);
    _writeMac(frame, boot + 28, mac);
    frame.setAll(boot + _options, [53, 1, type, 54, 4]);
    data.setUint32(boot + _options + 5, _serverIp);
    frame.setAll(boot + _options + 9, [
      if (type != 6) ...[1, 4, 255, 255, 255, 0, 51, 4, 0, 0, 14, 16], // /24, one hour.
      255,
    ]);
    var checksum = 0;
    for (var offset = _ethernet; offset < udp; offset += 2) {
      checksum += data.getUint16(offset);
    }
    while (checksum > 0xffff) {
      checksum = (checksum & 0xffff) + (checksum >> 16);
    }
    data.setUint16(24, checksum ^ 0xffff);
    return frame;
  }

  static int _readMac(Uint8List frame, int offset) {
    var value = 0;
    for (var i = offset; i < offset + 6; i++) {
      value = (value << 8) | frame[i];
    }
    return value;
  }

  static void _writeMac(Uint8List frame, int offset, int value) {
    for (var i = 0; i < 6; i++) {
      frame[offset + i] = (value >> ((5 - i) * 8)) & 255;
    }
  }
}
