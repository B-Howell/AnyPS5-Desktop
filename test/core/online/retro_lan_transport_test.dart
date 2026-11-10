import 'dart:async';
import 'dart:typed_data';

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
    final sent = <(String, Uint8List)>[];
    final batches = <List<Uint8List>>[];
    var ready = false;
    final reply = _frame(_guest, _host);
    final bridge = RetroLanBridge(
      peerRoute: () => 1,
      segment: host,
      send: (recipient, packet) => sent.add((recipient, packet)),
      exchange: (input) async {
        batches.add(input);
        return ready ? [reply] : null;
      },
    );
    addTearDown(bridge.close);
    final discovery = _frame(0xffffffffffff, _guest);
    final packet = guest.outbound(discovery)!.packet;
    bridge.receive('third', packet);
    await bridge.pump();
    expect(batches.single, isEmpty, reason: 'A different connection cannot send as the guest');
    for (var index = 0; index < 70; index++) {
      bridge.receive('guest', packet);
    }
    await bridge.pump();
    expect(batches.last, hasLength(16));
    expect(sent, isEmpty);
    ready = true;
    for (var batch = 0; batch < 4; batch++) {
      await bridge.pump();
      expect(batches.last, hasLength(16));
      expect(batches.last.every((frame) => frame.length == discovery.length), isTrue);
    }
    await bridge.pump();
    expect(batches.last, isEmpty);
    expect(guest.inbound('host', sent.first.$2), reply);
    expect(sent.map((entry) => entry.$1).toSet(), {'guest'});
  });

  test('one exchange runs at a time and late native frames are discarded after close', () async {
    final sent = <Uint8List>[];
    final pending = Completer<List<Uint8List>?>();
    var calls = 0;
    final bridge = RetroLanBridge(
      peerRoute: () => 1,
      segment: RetroLanTransport(epoch: 12, me: 'host', addresses: {'host': _host, 'guest': _guest}),
      send: (_, packet) => sent.add(packet),
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
    expect(sent, isEmpty);
    await bridge.pump();
    expect(calls, 1);
  });

  test('a pending exchange cannot consume queued frames from the next route', () async {
    final sent = <Uint8List>[];
    final batches = <List<Uint8List>>[];
    final pending = Completer<List<Uint8List>?>();
    var route = 1;
    final reply = _frame(_guest, _host);
    final bridge = RetroLanBridge(
      peerRoute: () => route,
      segment: host,
      send: (_, packet) => sent.add(packet),
      exchange: (frames) async {
        batches.add(frames);
        return batches.length == 1 ? pending.future : [reply];
      },
    );
    addTearDown(bridge.close);
    final old = _frame(0xffffffffffff, _guest);
    final fresh = _frame(_host, _guest);
    bridge.receive('guest', guest.outbound(old)!.packet);
    final exchange = bridge.pump();
    bridge.receive('guest', guest.outbound(old)!.packet);
    route++;
    bridge.receive('guest', guest.outbound(fresh)!.packet);
    pending.complete([reply]);
    await exchange;
    expect(sent, isEmpty);
    await bridge.pump();
    expect(batches, [
      [old],
      [fresh],
    ]);
    expect(guest.inbound('host', sent.single), reply);
  });
}
