import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/retro_lan_bridge.dart';
import 'package:anyps5_desktop/core/online/retro_lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = 0x020000000001;
const _guest = 0x020000000002;
const _third = 0x020000000003;
const _addresses = {'host': _host, 'guest': _guest, 'third': _third};

Uint8List _frame(int destination, int source, {int size = 60}) => Uint8List.fromList([
  for (final mac in [destination, source])
    for (var shift = 40; shift >= 0; shift -= 8) (mac >> shift) & 255,
  8,
  6,
  ...List.filled(size - 14, 0),
]);

final class _GameChannel implements GameLink {
  late void Function(Uint8List) deliver;
  final sent = <Uint8List>[];

  @override
  set onMessage(void Function(Uint8List) handler) => deliver = handler;

  @override
  bool send(Uint8List data) {
    sent.add(data);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late RetroLanTransport host;
  late RetroLanTransport guest;
  late RetroLanTransport third;

  setUp(() {
    host = RetroLanTransport(epoch: 12, me: 'host', addresses: _addresses);
    guest = RetroLanTransport(epoch: 12, me: 'guest', addresses: _addresses);
    third = RetroLanTransport(epoch: 12, me: 'third', addresses: _addresses);
  });

  test('forwards discovery to each invited peer and unicast only to its recipient', () {
    final discovery = _frame(0xffffffffffff, _host);
    final broadcast = host.outbound(discovery)!;
    expect(broadcast.recipients, ['guest', 'third']);
    expect(guest.inbound('host', broadcast.packet), discovery);
    expect(third.inbound('host', broadcast.packet), discovery);

    final reply = _frame(_host, _guest);
    final unicast = guest.outbound(reply)!;
    expect(unicast.recipients, ['host']);
    expect(host.inbound('guest', unicast.packet), reply);
    expect(third.inbound('guest', unicast.packet), isNull);
    expect(guest.outbound(_frame(0x020000000009, _guest)), isNull);
  });

  test('drops stale sessions, unknown senders, spoofed MACs and malformed frames', () {
    final valid = host.outbound(_frame(_guest, _host))!.packet;
    final previousMatch = RetroLanTransport(epoch: 11, me: 'host', addresses: _addresses);
    expect(guest.inbound('host', previousMatch.outbound(_frame(_guest, _host))!.packet), isNull);
    expect(guest.inbound('third', valid), isNull);
    expect(guest.inbound('outsider', valid), isNull);
    expect(host.outbound(_frame(_guest, _third)), isNull);
    expect(host.outbound(_frame(_guest, _host, size: 1515)), isNull);
    expect(guest.inbound('host', Uint8List(21)), isNull);
    valid[0] ^= 1;
    expect(guest.inbound('host', valid), isNull);
  });

  test('teardown makes the old segment unusable in either direction', () {
    final pending = guest.outbound(_frame(_host, _guest))!.packet;
    host.close();
    expect(host.inbound('guest', pending), isNull);
    expect(host.outbound(_frame(_guest, _host)), isNull);
  });

  test('exchanges authenticated game frames with the native queue in bounded batches', () async {
    final guestLink = _GameChannel();
    final thirdLink = _GameChannel();
    final batches = <List<Uint8List>>[];
    var ready = false;
    final reply = _frame(_guest, _host);
    final bridge = RetroLanBridge(
      segment: host,
      links: {'guest': guestLink, 'third': thirdLink},
      exchange: (input) async {
        batches.add(input);
        return ready ? [reply] : null;
      },
    );
    addTearDown(bridge.close);
    final discovery = _frame(0xffffffffffff, _guest);
    final packet = guest.outbound(discovery)!.packet;
    thirdLink.deliver(packet);
    await bridge.pump();
    expect(batches.single, isEmpty, reason: 'A different connection cannot send as the guest');
    for (var index = 0; index < 70; index++) {
      guestLink.deliver(packet);
    }
    await bridge.pump();
    expect(batches.last, hasLength(16));
    expect(guestLink.sent, isEmpty);
    ready = true;
    for (var batch = 0; batch < 4; batch++) {
      await bridge.pump();
      expect(batches.last, hasLength(16));
      expect(batches.last.every((frame) => frame.length == discovery.length), isTrue);
    }
    await bridge.pump();
    expect(batches.last, isEmpty);
    expect(guest.inbound('host', guestLink.sent.first), reply);
    expect(thirdLink.sent, isEmpty);
  });

  test('one exchange runs at a time and late native frames are discarded after close', () async {
    final guestLink = _GameChannel();
    final pending = Completer<List<Uint8List>?>();
    var calls = 0;
    final bridge = RetroLanBridge(
      segment: RetroLanTransport(epoch: 12, me: 'host', addresses: {'host': _host, 'guest': _guest}),
      links: {'guest': guestLink},
      exchange: (_) {
        calls++;
        return pending.future;
      },
    );
    final first = bridge.pump();
    final second = bridge.pump();
    expect(calls, 1);
    bridge.close();
    pending.complete([_frame(_guest, _host)]);
    await Future.wait([first, second]);
    expect(guestLink.sent, isEmpty);
    await bridge.pump();
    expect(calls, 1);
  });
}
