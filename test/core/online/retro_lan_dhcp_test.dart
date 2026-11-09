import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/retro_lan_bridge.dart';
import 'package:anyps5_desktop/core/online/retro_lan_dhcp.dart';
import 'package:anyps5_desktop/core/online/retro_lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = 0x020000000001;
const _guest = 0x020000000002;
const _hostIp = 0x0ae70065;
const _guestIp = 0x0ae70066;
const _serverIp = 0x0ae70001;

Uint8List _request(int mac, int type, {int? requested, int? server, int current = 0, bool broadcast = true}) {
  const boot = 42;
  final frame = Uint8List(342)..fillRange(0, 6, 255);
  for (final offset in [6, boot + 28]) {
    for (var i = 0; i < 6; i++) {
      frame[offset + i] = (mac >> ((5 - i) * 8)) & 255;
    }
  }
  ByteData.sublistView(frame)
    ..setUint16(12, 0x0800)
    ..setUint8(14, 0x45)
    ..setUint16(16, frame.length - 14)
    ..setUint8(23, 17)
    ..setUint32(26, current)
    ..setUint32(30, 0xffffffff)
    ..setUint16(34, 68)
    ..setUint16(36, 67)
    ..setUint16(38, frame.length - 34)
    ..setUint8(boot, 1)
    ..setUint8(boot + 1, 1)
    ..setUint8(boot + 2, 6)
    ..setUint32(boot + 4, 0x12345678)
    ..setUint16(boot + 10, broadcast ? 0x8000 : 0)
    ..setUint32(boot + 12, current)
    ..setUint32(boot + 236, 0x63825363);
  frame.setAll(boot + 240, [
    53,
    1,
    type,
    if (requested != null) ...[50, 4, ..._ip(requested)],
    if (server != null) ...[54, 4, ..._ip(server)],
    255,
  ]);
  return frame;
}

List<int> _ip(int address) => [for (var shift = 24; shift >= 0; shift -= 8) (address >> shift) & 255];

void main() {
  test('offers and acknowledges a distinct address for each virtual console', () {
    for (final (mac, address) in [(_host, _hostIp), (_guest, _guestIp)]) {
      final dhcp = RetroLanDhcp(mac: mac, address: address);
      final offer = dhcp.reply(_request(mac, 1))!;
      final data = ByteData.sublistView(offer);
      expect(offer.take(6), List.filled(6, 255));
      expect(data.getUint16(34), 67);
      expect(data.getUint16(36), 68);
      expect(data.getUint32(46), 0x12345678);
      expect(data.getUint32(58), address);
      expect(offer.sublist(282, 291), [53, 1, 2, 54, 4, ..._ip(_serverIp)]);
      var checksum = 0;
      for (var offset = 14; offset < 34; offset += 2) {
        checksum += data.getUint16(offset);
      }
      expect((checksum & 0xffff) + (checksum >> 16), 0xffff);
      final ack = dhcp.reply(_request(mac, 3, requested: address, server: _serverIp))!;
      expect(ack[284], 5);
      expect(ByteData.sublistView(ack).getUint32(58), address);
      final renewRequest = _request(mac, 3, current: address, broadcast: false);
      renewRequest.setAll(0, offer.sublist(6, 12));
      ByteData.sublistView(renewRequest).setUint32(30, _serverIp);
      final renewal = dhcp.reply(renewRequest)!;
      expect(ByteData.sublistView(renewal).getUint32(30), address);
      expect(renewal.take(6), _request(mac, 1).sublist(6, 12));
    }
  });

  test('rejects another seat, truncated options, and another DHCP server', () {
    const dhcp = RetroLanDhcp(mac: _host, address: _hostIp);
    expect(dhcp.reply(_request(_guest, 1)), isNull);
    final malformed = _request(_host, 1)..[283] = 255;
    expect(dhcp.reply(malformed), isNull);
    expect(dhcp.reply(_request(_host, 3, requested: _hostIp, server: 0x01020304)), isNull);
    expect(dhcp.reply(_request(_host, 3, requested: _hostIp, current: _guestIp)), isNull);
    final nak = dhcp.reply(_request(_host, 3, requested: _guestIp))!;
    expect(nak[284], 6);
    expect(ByteData.sublistView(nak).getUint32(58), 0);
  });

  test('resolves the virtual server for unicast renewals and leaves peer ARP alone', () {
    final request = Uint8List(60)..fillRange(0, 6, 255);
    final mac = _request(_host, 1).sublist(6, 12);
    request.setAll(6, mac);
    request.setAll(22, mac);
    final data = ByteData.sublistView(request)
      ..setUint16(12, 0x0806)
      ..setUint16(14, 1)
      ..setUint16(16, 0x0800)
      ..setUint16(18, 0x0604)
      ..setUint16(20, 1)
      ..setUint32(28, _hostIp)
      ..setUint32(38, _serverIp);
    const dhcp = RetroLanDhcp(mac: _host, address: _hostIp);
    expect(RetroLanDhcp.isLocalService(request), isTrue);
    final reply = dhcp.reply(request)!;
    expect(reply.take(6), mac);
    expect(ByteData.sublistView(reply).getUint16(20), 2);
    expect(ByteData.sublistView(reply).getUint32(28), _serverIp);
    expect(ByteData.sublistView(reply).getUint32(38), _hostIp);
    data.setUint32(38, _guestIp);
    expect(RetroLanDhcp.isLocalService(request), isFalse);
    expect(dhcp.reply(request), isNull);
  });

  test('bridge keeps DHCP local and rejects a remote DHCP reply', () async {
    const addresses = {'host': _host, 'guest': _guest};
    final guest = RetroLanTransport(epoch: 1, me: 'guest', addresses: addresses);
    final remote = const RetroLanDhcp(mac: _guest, address: _guestIp).reply(_request(_guest, 1))!;
    remote.setRange(6, 12, _request(_guest, 1), 6);
    final batches = <List<Uint8List>>[];
    final forwarded = <Uint8List>[];
    final bridge = RetroLanBridge(
      segment: RetroLanTransport(epoch: 1, me: 'host', addresses: addresses),
      dhcp: const RetroLanDhcp(mac: _host, address: _hostIp),
      send: (_, data) => forwarded.add(data),
      exchange: (frames) async {
        batches.add(frames);
        return batches.length == 1 ? [_request(_host, 1)] : [];
      },
    );
    addTearDown(bridge.close);
    bridge.receive('guest', guest.outbound(remote)!.packet);
    await bridge.pump();
    await bridge.pump();
    expect(forwarded, isEmpty);
    expect(batches.first, isEmpty);
    expect(batches.last.single[284], 2);
  });

  test('setup bridge offers and acknowledges DHCP without a room', () async {
    final batches = <List<Uint8List>>[];
    final bridge = RetroLanBridge.local(
      dhcp: const RetroLanDhcp(mac: _host, address: _hostIp),
      exchange: (frames) async {
        batches.add(frames);
        return switch (batches.length) {
          1 => [_request(_host, 1), Uint8List(60)],
          2 => [_request(_host, 3, requested: _hostIp, server: _serverIp)],
          _ => [],
        };
      },
    );
    addTearDown(bridge.close);
    await bridge.pump();
    await bridge.pump();
    await bridge.pump();
    expect(batches.map((frames) => frames.map((frame) => frame[284]).toList()), [
      [],
      [2],
      [5],
    ]);
    bridge.close();
    await bridge.pump();
    expect(batches.length, 3);
  });
}
