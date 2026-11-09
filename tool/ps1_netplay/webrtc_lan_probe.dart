import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';

import 'webrtc_room_fixture.dart';

Future<String> verifyWebRtcLanBridge() async {
  final links = _InterruptibleLinks();
  var reconnecting = Completer<void>();
  var reconnected = Completer<void>();
  var recoveryUser = WebRtcRoomFixture.host;
  final digest = 'a' * 64;
  final gateway = WebRtcRoomFixture((
    titleId: 'SLUS21148',
    gameVersion: '1',
    mode: RetroOnlineMode.lan,
    capacity: 2,
  ), digest);
  final host = _FixtureNic(0x020000000001, 0x020000000002, 0x0ae70065, broadcast: true);
  final guest = _FixtureNic(0x020000000002, 0x020000000001, 0x0ae70066, broadcast: false);
  RetroLanMatch match(String user, _FixtureNic nic) {
    final owner = RetroLanMatch(
      rooms: gateway.client(user, expectedDigest: digest),
      links: links,
      launch: nic.launch,
      onRecoveryChanged: (recovering) {
        if (user == recoveryUser) (recovering ? reconnecting : reconnected).complete();
      },
    );
    gateway.events[user] = owner.receive;
    return owner;
  }

  final left = match(WebRtcRoomFixture.host, host);
  final right = match(WebRtcRoomFixture.guest, guest);
  final releaseHost = Completer<void>();
  try {
    final hosting = left.host(WebRtcRoomFixture.guest);
    await Future.any([
      gateway.invited,
      hosting.then((_) => throw StateError('The host closed before inviting its guest.')),
    ]).timeout(const Duration(seconds: 5));
    await Future.wait([hosting, right.join(WebRtcRoomFixture.roomId)]).timeout(const Duration(seconds: 10));
    await Future.wait([host.received.future, guest.received.future]).timeout(const Duration(seconds: 8));
    for (final link in links.opened) {
      link.reportState('disconnected');
    }
    await reconnecting.future.timeout(const Duration(seconds: 4));
    final before = guest.framesReceived;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (guest.framesReceived != before || left.closed || right.closed) {
      throw StateError('The interruption did not suspend forwarding while keeping the room open.');
    }
    for (final link in links.opened) {
      link.reportState('connected');
    }
    await reconnected.future.timeout(const Duration(seconds: 4));
    final resumed = Stopwatch()..start();
    while (guest.framesReceived == before && resumed.elapsed < const Duration(seconds: 4)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (guest.framesReceived == before || links.opened.length != 2) {
      throw StateError('LAN traffic did not resume on the original WebRTC links.');
    }
    reconnecting = Completer<void>();
    reconnected = Completer<void>();
    recoveryUser = WebRtcRoomFixture.guest;
    final unavailable = {'renegotiate', 'offer', 'answer'};
    gateway.rejectSignal = (_, kind, data) => data is Map && data['iceRoute'] == 1 && unavailable.remove(kind);
    links.opened.last.reportState('failed');
    await reconnecting.future.timeout(const Duration(seconds: 4));
    final beforeRestart = guest.framesReceived;
    await reconnected.future.timeout(const Duration(seconds: 8));
    final restart = Stopwatch()..start();
    while (guest.framesReceived == beforeRestart && !right.closed && restart.elapsed < const Duration(seconds: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final offers = links.opened.first.offerCredentials;
    if (left.closed ||
        right.closed ||
        guest.framesReceived == beforeRestart ||
        links.opened.length != 2 ||
        unavailable.isNotEmpty ||
        offers.length != 2 ||
        offers.first == offers.last) {
      throw StateError(
        'ICE restart: ${offers.length} offers, ${guest.framesReceived - beforeRestart} resumed frames, '
        'room closed ${left.closed || right.closed}.',
      );
    }
    gateway.hostReleaseGate = releaseHost.future;
    final guestLeaving = right.leave();
    await left.ending.timeout(const Duration(seconds: 5));
    if (!left.gameContinues || host.done.isCompleted || gateway.released) {
      throw StateError('The host game did not stay open during room release.');
    }
    final repeatedLeave = left.leave();
    releaseHost.complete();
    await Future.wait([guestLeaving, repeatedLeave]).timeout(const Duration(seconds: 5));
    await left.done.timeout(const Duration(seconds: 5));
    if (!gateway.released || !left.gameContinues || host.done.isCompleted || !guest.done.isCompleted) {
      throw StateError('The PS2 LAN room did not close while keeping the host game open.');
    }
    return 'Windows WebRTC PS2 LAN passed with DHCP, signaling retries, fresh ICE credentials and resumed frames.';
  } finally {
    if (!releaseHost.isCompleted) releaseHost.complete();
    await Future.wait([left.leave(), right.leave()]).timeout(const Duration(seconds: 4));
    if (!host.done.isCompleted) host.done.complete();
  }
}

// Injects only connection-state notifications. The data channels and frame
// exchange still use the real Windows WebRTC plugin.
final class _InterruptibleLinks implements GameLinks {
  final _delegate = WebRtcGameLinks();
  final opened = <_InterruptibleLink>[];

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async {
    final link = _InterruptibleLink(await _delegate.link(iceServers));
    opened.add(link);
    return link;
  }
}

final class _InterruptibleLink implements GameLink, RestartableGameLink {
  _InterruptibleLink(this._link);

  final GameLink _link;
  final offerCredentials = <String>[];
  void Function(String)? _onState;
  void reportState(String state) => _onState?.call(state);

  @override
  set onState(void Function(String) handler) => _link.onState = _onState = handler;
  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => _link.onCandidate = handler;
  @override
  set onMessage(void Function(Uint8List) handler) => _link.onMessage = handler;
  @override
  set onStreamMessage(void Function(Uint8List) handler) => _link.onStreamMessage = handler;
  @override
  Future<Map<String, dynamic>> createOffer() async {
    final offer = await _link.createOffer();
    final credential = RegExp(r'^a=ice-ufrag:([^\r\n]+)', multiLine: true).firstMatch(offer['sdp'] as String);
    if (credential == null) throw StateError('WebRTC offer had no ICE credentials.');
    offerCredentials.add(credential.group(1)!);
    return offer;
  }

  @override
  Future<void> restartIce() => (_link as RestartableGameLink).restartIce();
  @override
  Future<bool> routeConnected() => (_link as RestartableGameLink).routeConnected();
  @override
  Future<Map<String, dynamic>> createAnswer() => _link.createAnswer();
  @override
  Future<void> setLocal(Map<String, dynamic> description) => _link.setLocal(description);
  @override
  Future<void> setRemote(Map<String, dynamic> description) => _link.setRemote(description);
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => _link.addCandidate(candidate);
  @override
  Future<void> openChannel() => _link.openChannel();
  @override
  bool get gameOpen => _link.gameOpen;
  @override
  bool get streamOpen => _link.streamOpen;
  @override
  bool send(Uint8List data) => _link.send(data);
  @override
  bool sendStream(Uint8List data) => _link.sendStream(data);
  @override
  Future<void> close() => _link.close();
}

final class _FixtureNic {
  _FixtureNic(this.mac, this.remoteMac, this.expectedIp, {required this.broadcast});

  final int mac;
  final int remoteMac;
  final int expectedIp;
  final bool broadcast;
  final received = Completer<void>();
  final done = Completer<void>();
  int framesReceived = 0;

  Future<RetroLanGame> launch(Uint8List assigned) async {
    if (!_same(assigned, _address(mac))) throw StateError('The PS2 room supplied the wrong virtual MAC.');
    final outbound = _frame(broadcast ? 0xffffffffffff : remoteMac, mac);
    final expected = _frame(broadcast ? mac : 0xffffffffffff, remoteMac);
    var leased = false;
    int? offered;
    return (
      exchange: (List<Uint8List> input) async {
        for (final frame in input) {
          if (frame.length < 291 || frame[284] != (offered == null ? 2 : 5)) continue;
          final reply = ByteData.sublistView(frame);
          if (reply.getUint16(34) != 67 || reply.getUint16(36) != 68 || reply.getUint32(46) != (mac & 255)) continue;
          final address = reply.getUint32(58);
          if (address != expectedIp || reply.getUint32(30) != expectedIp || !_same(frame.sublist(0, 6), assigned)) {
            throw StateError('Wrong address offered to the PS2 console.');
          }
          leased = offered == address;
          offered = address;
        }
        if (!leased) return [_dhcpRequest(assigned, mac & 255, offered)];
        framesReceived += input.where((frame) => _same(frame, expected)).length;
        if (!received.isCompleted && framesReceived > 0) received.complete();
        return broadcast || received.isCompleted ? [outbound] : <Uint8List>[];
      },
      close: () async => done.complete(),
      done: done.future,
    );
  }
}

Uint8List _dhcpRequest(Uint8List mac, int transaction, int? offered) {
  const boot = 42;
  final frame = Uint8List(342)
    ..fillRange(0, 6, 255)
    ..setAll(6, mac)
    ..setAll(boot + 28, mac);
  ByteData.sublistView(frame)
    ..setUint16(12, 0x0800)
    ..setUint8(14, 0x45)
    ..setUint16(16, frame.length - 14)
    ..setUint8(23, 17)
    ..setUint32(30, 0xffffffff)
    ..setUint16(34, 68)
    ..setUint16(36, 67)
    ..setUint16(38, frame.length - 34)
    ..setUint8(boot, 1)
    ..setUint8(boot + 1, 1)
    ..setUint8(boot + 2, 6)
    ..setUint32(boot + 4, transaction)
    ..setUint32(boot + 236, 0x63825363);
  frame.setAll(boot + 240, [
    53,
    1,
    offered == null ? 1 : 3,
    if (offered != null) ...[50, 4, for (var shift = 24; shift >= 0; shift -= 8) (offered >> shift) & 255],
    if (offered != null) ...[54, 4, 10, 231, 0, 1, 55, 4, 1, 3, 15, 6],
    61,
    7,
    1,
    ...mac,
    255,
  ]);
  return frame;
}

Uint8List _address(int value) =>
    Uint8List.fromList([for (var shift = 40; shift >= 0; shift -= 8) (value >> shift) & 255]);

Uint8List _frame(int destination, int source) =>
    Uint8List.fromList([..._address(destination), ..._address(source), 8, 6, ...List.generate(46, (index) => index)]);

bool _same(Uint8List actual, Uint8List expected) =>
    actual.length == expected.length && actual.indexed.every((entry) => entry.$2 == expected[entry.$1]);
