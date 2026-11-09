import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/ps1_netplay/webrtc_room_fixture.dart';
import '../../support/online_fakes.dart';

void main() {
  test('leaving a private PS2 room keeps the other player’s game open', () async {
    final digest = 'a' * 64;
    final gateway = WebRtcRoomFixture((
      titleId: 'SLUS21148',
      gameVersion: '1',
      mode: RetroOnlineMode.lan,
      capacity: 2,
    ), digest);
    final network = FakeGameNetwork()..gameChannelReady = false;
    final attached = <String, Uint8List>{};
    final received = Completer<Uint8List>();
    final resumedTraffic = Completer<void>();
    final release = Completer<void>();
    final exchangeStarted = Completer<void>();
    final exchangeFinished = Completer<List<Uint8List>?>();
    var afterRenegotiate = false;
    var holdExchange = false;
    final closed = <String>[];
    final exits = {
      for (final id in [WebRtcRoomFixture.host, WebRtcRoomFixture.guest]) id: Completer<void>(),
    };
    RetroLanMatch match(String id) {
      final owner = RetroLanMatch(
        rooms: gateway.client(id, expectedDigest: digest),
        links: network.links,
        launch: (mac) async {
          attached[id] = mac;
          return (
            exchange: (List<Uint8List> input) async {
              if (id == WebRtcRoomFixture.guest && input.isNotEmpty && !received.isCompleted) {
                received.complete(input.first);
              }
              if (id == WebRtcRoomFixture.guest &&
                  input.isNotEmpty &&
                  afterRenegotiate &&
                  !resumedTraffic.isCompleted) {
                resumedTraffic.complete();
              }
              if (id != WebRtcRoomFixture.host) return <Uint8List>[];
              if (holdExchange) {
                exchangeStarted.complete();
                return exchangeFinished.future;
              }
              return [
                Uint8List.fromList([255, 255, 255, 255, 255, 255, ...mac, 8, 6]),
              ];
            },
            close: () async {
              closed.add(id);
              exits[id]!.complete();
            },
            done: exits[id]!.future,
          );
        },
      );
      gateway.events[id] = owner.receive;
      addTearDown(owner.leave);
      addTearDown(() {
        if (!exits[id]!.isCompleted) exits[id]!.complete();
      });
      return owner;
    }

    final host = match(WebRtcRoomFixture.host);
    final guest = match(WebRtcRoomFixture.guest);
    final opening = host.host(WebRtcRoomFixture.guest);
    await gateway.invited;
    expect(attached, isEmpty);
    final joining = guest.join(WebRtcRoomFixture.roomId);
    Future<void> waitForStream() async {
      while (!network.all.any((link) => link.streamOpen) && !host.closed) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    void requestOffer() => gateway
        .client(WebRtcRoomFixture.guest)
        .signal(WebRtcRoomFixture.host, WebRtcRoomFixture.hostDevice, WebRtcRoomFixture.roomId, 'renegotiate', null);

    await waitForStream().timeout(const Duration(seconds: 5));
    expect(attached, isEmpty);
    requestOffer();
    await Future<void>.delayed(Duration.zero);
    expect(network.all, hasLength(2));
    network.gameChannelReady = true;
    await Future.wait([opening, joining]).timeout(const Duration(seconds: 5));
    final frame = await received.future.timeout(const Duration(seconds: 2));
    expect(attached[WebRtcRoomFixture.host], isNot(attached[WebRtcRoomFixture.guest]));
    expect(frame.sublist(6, 12), attached[WebRtcRoomFixture.host]);
    requestOffer();
    afterRenegotiate = true;
    await resumedTraffic.future.timeout(const Duration(seconds: 2));
    expect(host.closed, isFalse);
    expect(network.all, hasLength(2));

    holdExchange = true;
    await exchangeStarted.future.timeout(const Duration(seconds: 2));
    gateway.hostReleaseGate = release.future;
    final leaving = host.leave();
    try {
      await guest.done.timeout(const Duration(seconds: 2));
      expect(guest.gameContinues, isTrue);
      expect(host.gameContinues, isFalse);
      expect(exits[WebRtcRoomFixture.guest]!.isCompleted, isFalse);
      expect(exits[WebRtcRoomFixture.host]!.isCompleted, isFalse);
      exchangeFinished.complete(<Uint8List>[]);
      await exits[WebRtcRoomFixture.host]!.future.timeout(const Duration(seconds: 2));
      expect(gateway.released, isFalse);
    } finally {
      if (!exchangeFinished.isCompleted) exchangeFinished.complete(<Uint8List>[]);
      release.complete();
    }
    await Future.wait([leaving, guest.done]).timeout(const Duration(seconds: 2));
    expect(closed, [WebRtcRoomFixture.host]);
    expect(gateway.released, isTrue);
  });

  test('losing the game channel ends the room and keeps both games open', () async {
    final digest = 'c' * 64;
    final gateway = WebRtcRoomFixture((
      titleId: 'SLUS21148',
      gameVersion: '1',
      mode: RetroOnlineMode.lan,
      capacity: 2,
    ), digest);
    final network = FakeGameNetwork();
    final stopped = <Completer<void>>[];
    RetroLanMatch match(String id) {
      final done = Completer<void>();
      stopped.add(done);
      final match = RetroLanMatch(
        rooms: gateway.client(id, expectedDigest: digest),
        links: network.links,
        launch: (_) async =>
            (exchange: (_) async => <Uint8List>[], close: () async => done.complete(), done: done.future),
      );
      gateway.events[id] = match.receive;
      addTearDown(match.leave);
      addTearDown(() {
        if (!done.isCompleted) done.complete();
      });
      return match;
    }

    final host = match(WebRtcRoomFixture.host);
    final guest = match(WebRtcRoomFixture.guest);
    final hosting = host.host(WebRtcRoomFixture.guest);
    await gateway.invited.timeout(const Duration(seconds: 5));
    await Future.wait([hosting, guest.join(WebRtcRoomFixture.roomId)]).timeout(const Duration(seconds: 5));
    network.gameChannelReady = false;
    await Future.wait([host.done, guest.done]).timeout(const Duration(seconds: 2));

    expect(host.gameContinues, isTrue);
    expect(guest.gameContinues, isTrue);
    expect(stopped.any((game) => game.isCompleted), isFalse);
    expect(gateway.released, isTrue);
  });

  test('cancelling during emulator startup releases the room and closes the late game', () async {
    final digest = 'b' * 64;
    final gateway = WebRtcRoomFixture((
      titleId: 'SLUS21148',
      gameVersion: '1',
      mode: RetroOnlineMode.lan,
      capacity: 2,
    ), digest);
    final network = FakeGameNetwork();
    final booting = Completer<void>();
    final pending = Completer<RetroLanGame>();
    final stopped = Completer<void>();
    RetroLanGame game(Completer<void> done) =>
        (exchange: (_) async => <Uint8List>[], close: () async => done.complete(), done: done.future);
    final host = RetroLanMatch(
      rooms: gateway.client(WebRtcRoomFixture.host, expectedDigest: digest),
      links: network.links,
      launch: (_) {
        booting.complete();
        return pending.future;
      },
    );
    final guest = RetroLanMatch(
      rooms: gateway.client(WebRtcRoomFixture.guest, expectedDigest: digest),
      links: network.links,
      launch: (_) async => game(Completer<void>()),
    );
    gateway.events[WebRtcRoomFixture.host] = host.receive;
    gateway.events[WebRtcRoomFixture.guest] = guest.receive;
    final opening = host.host(WebRtcRoomFixture.guest);
    try {
      await gateway.invited.timeout(const Duration(seconds: 2));
      final joining = guest.join(WebRtcRoomFixture.roomId);
      await booting.future.timeout(const Duration(seconds: 3));
      final leaving = host.leave();
      await guest.done.timeout(const Duration(seconds: 2));
      expect(gateway.released, isTrue);
      expect(stopped.isCompleted, isFalse);
      pending.complete(game(stopped));
      await Future.wait([leaving, opening, joining]).timeout(const Duration(seconds: 2));
      expect(stopped.isCompleted, isTrue);
    } finally {
      if (!pending.isCompleted) pending.complete(game(stopped));
      await Future.wait([host.leave(), guest.leave()]);
    }
  });
}
