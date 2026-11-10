import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/ps1_netplay/webrtc_room_fixture.dart';
import '../../support/online_fakes.dart';

void main() {
  test('cancel while rechecking a PS2 room never admits the player', () async {
    const id = WebRtcRoomFixture.roomId;
    const spec = (titleId: 'SLUS21148', gameVersion: '1', mode: RetroOnlineMode.lan, capacity: 2);
    final requested = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final calls = <(String, String)>[];
    final rooms = RetroOnlineRooms(
      me: WebRtcRoomFixture.guest,
      spec: spec,
      discDigest: 'a' * 64,
      call: (method, path, [body]) async {
        calls.add((method, path));
        if (path == 'me/game-session') return {'session': null};
        if (method == 'GET' && path == 'game-sessions/$id') {
          requested.complete();
          return reply.future;
        }
        throw StateError('Unexpected fixture request: $method $path');
      },
      signal: (_, _, _, _, _) {},
    );
    final match = RetroLanMatch(
      rooms: rooms,
      links: FakeGameNetwork().links,
      launch: (_) async => throw StateError('The canceled match must not launch.'),
    );
    final opening = match.join(id);
    await requested.future.timeout(const Duration(seconds: 2));
    try {
      await Future.wait([opening, match.leave(), match.done]).timeout(const Duration(seconds: 2));
      expect(calls, [('GET', 'me/game-session'), ('GET', 'game-sessions/$id')]);
    } finally {
      reply.complete({
        'id': id,
        'host': {'userId': WebRtcRoomFixture.host},
        'kind': 'online',
        'titleId': spec.titleId,
        'gameVersion': spec.gameVersion,
        'engineBuild': spec.mode.protocol,
        'capacity': spec.capacity,
        'joinable': false,
        'properties': {'protocol': spec.mode.protocol, 'discSha256': 'a' * 64},
      });
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls, [('GET', 'me/game-session'), ('GET', 'game-sessions/$id')]);
  });

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
    final trafficAfterReconnect = Completer<void>();
    final trafficAfterRouteRestart = Completer<void>();
    final reconnecting = Completer<void>();
    final reconnected = Completer<void>();
    final release = Completer<void>();
    final exchangeStarted = Completer<void>();
    final exchangeFinished = Completer<List<Uint8List>?>();
    var afterRenegotiate = false;
    var holdExchange = false;
    var expectRecovery = false;
    var expectRouteRestart = false;
    var guestFrames = 0;
    final closed = <String>[];
    final exits = {
      for (final id in [WebRtcRoomFixture.host, WebRtcRoomFixture.guest]) id: Completer<void>(),
    };
    RetroLanMatch match(String id) {
      final owner = RetroLanMatch(
        rooms: gateway.client(id, expectedDigest: digest),
        links: network.links,
        onRecoveryChanged: (recovering) {
          if (id != WebRtcRoomFixture.host) return;
          final event = recovering ? reconnecting : reconnected;
          if (!event.isCompleted) event.complete();
        },
        launch: (mac) async {
          attached[id] = mac;
          return (
            exchange: (List<Uint8List> input) async {
              if (id == WebRtcRoomFixture.guest && input.isNotEmpty) {
                guestFrames += input.length;
                if (expectRecovery && !trafficAfterReconnect.isCompleted) trafficAfterReconnect.complete();
                if (expectRouteRestart && !trafficAfterRouteRestart.isCompleted) trafficAfterRouteRestart.complete();
              }
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

    for (final link in network.all) {
      expect(link.gameOpen, isTrue);
      link.reportState('disconnected');
    }
    // The delayed status also lets the last native batch finish.
    await reconnecting.future.timeout(const Duration(seconds: 2));
    final beforeRecovery = guestFrames;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(guestFrames, beforeRecovery);
    expect(host.closed || guest.closed, isFalse);
    expect(attached, hasLength(2));
    expectRecovery = true;
    for (final link in network.all) {
      link.reportState('connected');
    }
    await trafficAfterReconnect.future.timeout(const Duration(seconds: 2));
    await reconnected.future.timeout(const Duration(seconds: 2));
    expect(network.all, hasLength(2));

    final beforeRestart = gateway.signals;
    var rejectedOffer = false;
    var rejectedAnswer = false;
    String? rejectedCandidate;
    final firstRestartOffer = Completer<void>();
    final replayedRestartOffer = Completer<void>();
    gateway.rejectSignal = (from, kind, data) {
      if (data is! Map || data['iceRoute'] != 1) return false;
      if (kind == 'offer') {
        if (!rejectedOffer) {
          firstRestartOffer.complete();
          return rejectedOffer = true;
        }
        if (!replayedRestartOffer.isCompleted) replayedRestartOffer.complete();
      }
      if (kind == 'answer' && !rejectedAnswer) return rejectedAnswer = true;
      if (from == WebRtcRoomFixture.host && kind == 'candidate' && rejectedCandidate == null) {
        rejectedCandidate = data['candidate'] as String;
        return true;
      }
      return false;
    };
    final restartAnswer = Completer<void>();
    final replayedCandidate = Completer<void>();
    gateway.events[WebRtcRoomFixture.guest] = (type, event) {
      final data = event['data'];
      if (event['kind'] == 'candidate' &&
          data is Map &&
          data['iceRoute'] == 1 &&
          rejectedCandidate != null &&
          data['candidate'] == rejectedCandidate &&
          !replayedCandidate.isCompleted) {
        replayedCandidate.complete();
      }
      guest.receive(type, event);
    };
    gateway.events[WebRtcRoomFixture.host] = (type, event) {
      final data = event['data'];
      if (event['kind'] == 'answer' && data is Map && data['iceRoute'] == 1 && !restartAnswer.isCompleted) {
        restartAnswer.complete();
      }
      host.receive(type, event);
    };
    for (final link in network.all) {
      link.reportState('failed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.closed || guest.closed, isFalse);
    expectRouteRestart = true;
    // Bound the retry delay separately from the fake link's handshake.
    await firstRestartOffer.future.timeout(const Duration(milliseconds: 1350));
    await replayedRestartOffer.future.timeout(const Duration(milliseconds: 1300));
    await trafficAfterRouteRestart.future.timeout(const Duration(seconds: 4));
    await restartAnswer.future.timeout(const Duration(seconds: 2));
    await replayedCandidate.future.timeout(const Duration(seconds: 2));
    expect(gateway.signals, greaterThan(beforeRestart));
    expect(network.all, hasLength(2));
    expect(rejectedOffer && rejectedAnswer, isTrue);
    expect(network.all.map((link) => link.routeRestarts), [1, 0]);
    final guestClient = gateway.client(WebRtcRoomFixture.guest);
    guestClient.signal(WebRtcRoomFixture.host, WebRtcRoomFixture.hostDevice, WebRtcRoomFixture.roomId, 'candidate', {
      'candidate': 'stale original candidate',
    });
    guestClient.signal(WebRtcRoomFixture.host, WebRtcRoomFixture.hostDevice, WebRtcRoomFixture.roomId, 'renegotiate', {
      'iceRoute': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      network.all.first.candidatesIn.map((candidate) => candidate['candidate']),
      isNot(contains('stale original candidate')),
    );
    expect(network.all.map((link) => link.routeRestarts), [1, 0]);

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

  for (final (end, description) in [
    ('channel', 'a closed data channel ends the room immediately'),
    ('timeout', 'an expired recovery window ends the room'),
    ('bye', 'only a goodbye from the bound peer ends the room'),
  ]) {
    test('$description and keeps both games open', () async {
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
          recoveryWindow: end == 'timeout' ? const Duration(milliseconds: 200) : const Duration(seconds: 5),
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
      if (end == 'channel') {
        network.all.first.reportState('game-closed');
      } else if (end == 'bye') {
        host.receive('game_session.signal', {
          'sessionId': WebRtcRoomFixture.roomId,
          'from': WebRtcRoomFixture.guest,
          'device': WebRtcRoomFixture.hostDevice,
          'kind': 'bye',
        });
        expect(host.closed, isFalse);
        gateway
            .client(WebRtcRoomFixture.guest)
            .signal(WebRtcRoomFixture.host, WebRtcRoomFixture.hostDevice, WebRtcRoomFixture.roomId, 'bye', null);
      } else {
        network.gameChannelReady = false;
        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(host.closed || guest.closed, isFalse);
      }
      await Future.wait([host.done, guest.done]).timeout(const Duration(seconds: 2));

      expect(host.gameContinues, isTrue);
      expect(guest.gameContinues, isTrue);
      if (end == 'bye') {
        expect(host.remoteEnded, isTrue);
        expect(host.failure, isNull);
      } else {
        expect([host, guest].any((match) => match.failure != null && !match.remoteEnded), isTrue);
      }
      expect(stopped.any((game) => game.isCompleted), isFalse);
      expect(gateway.released, isTrue);
    });
  }

  Future<void> cancelStartup({required bool fromNotification}) async {
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
    late final RetroLanMatch host;
    host = RetroLanMatch(
      rooms: gateway.client(WebRtcRoomFixture.host, expectedDigest: digest),
      links: network.links,
      onStartupChanged: () {
        if (fromNotification && host.startupPhase == RetroLanStartupPhase.startingGame) {
          unawaited(host.leave());
        }
      },
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
      if (fromNotification) {
        await Future.wait([opening, joining, host.done, guest.done]).timeout(const Duration(seconds: 5));
        expect(booting.isCompleted, isFalse);
        expect(gateway.released, isTrue);
        return;
      }
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
  }

  test(
    'cancelling during emulator startup releases the room and closes the late game',
    () => cancelStartup(fromNotification: false),
  );
  test(
    'cancelling synchronously from the PS2 startup notification never launches the game',
    () => cancelStartup(fromNotification: true),
  );
}
