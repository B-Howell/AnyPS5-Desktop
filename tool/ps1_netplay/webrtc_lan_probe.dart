import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';

import 'webrtc_room_fixture.dart';

Future<String> verifyWebRtcLanBridge() async {
  final links = WebRtcGameLinks();
  final digest = 'a' * 64;
  final gateway = WebRtcRoomFixture((
    titleId: 'SLUS21148',
    gameVersion: '1',
    mode: RetroOnlineMode.lan,
    capacity: 2,
  ), digest);
  final host = _FixtureNic(0x020000000001, 0x020000000002, broadcast: true);
  final guest = _FixtureNic(0x020000000002, 0x020000000001, broadcast: false);
  RetroLanMatch match(String user, _FixtureNic nic) {
    final owner = RetroLanMatch(
      rooms: gateway.client(user, expectedDigest: digest),
      links: links,
      launch: nic.launch,
    );
    gateway.events[user] = owner.receive;
    return owner;
  }

  final left = match(WebRtcRoomFixture.host, host);
  final right = match(WebRtcRoomFixture.guest, guest);
  try {
    final hosting = left.host(WebRtcRoomFixture.guest);
    await Future.any([
      gateway.invited,
      hosting.then((_) => throw StateError('The host closed before inviting its guest.')),
    ]).timeout(const Duration(seconds: 5));
    await Future.wait([hosting, right.join(WebRtcRoomFixture.roomId)]).timeout(const Duration(seconds: 10));
    await Future.wait([host.received.future, guest.received.future]).timeout(const Duration(seconds: 8));
    await right.leave();
    await left.done.timeout(const Duration(seconds: 5));
    if (!gateway.released || !host.done.isCompleted || !guest.done.isCompleted) {
      throw StateError('The PS2 LAN room did not release its virtual NICs.');
    }
    return 'Windows WebRTC PS2 LAN room passed with matching broadcast and unicast frames and clean teardown.';
  } finally {
    await Future.wait([left.leave(), right.leave()]).timeout(const Duration(seconds: 4));
  }
}

final class _FixtureNic {
  _FixtureNic(this.mac, this.remoteMac, {required this.broadcast});

  final int mac;
  final int remoteMac;
  final bool broadcast;
  final received = Completer<void>();
  final done = Completer<void>();

  Future<RetroLanGame> launch(Uint8List assigned) async {
    if (!_same(assigned, _address(mac))) throw StateError('The PS2 room supplied the wrong virtual MAC.');
    final outbound = _frame(broadcast ? 0xffffffffffff : remoteMac, mac);
    final expected = _frame(broadcast ? mac : 0xffffffffffff, remoteMac);
    return (
      exchange: (List<Uint8List> input) async {
        if (!received.isCompleted && input.any((frame) => _same(frame, expected))) received.complete();
        return broadcast || received.isCompleted ? [outbound] : <Uint8List>[];
      },
      close: () async => done.complete(),
      done: done.future,
    );
  }
}

Uint8List _address(int value) =>
    Uint8List.fromList([for (var shift = 40; shift >= 0; shift -= 8) (value >> shift) & 255]);

Uint8List _frame(int destination, int source) =>
    Uint8List.fromList([..._address(destination), ..._address(source), 8, 6, ...List.generate(46, (index) => index)]);

bool _same(Uint8List actual, Uint8List expected) =>
    actual.length == expected.length && actual.indexed.every((entry) => entry.$2 == expected[entry.$1]);
