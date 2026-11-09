import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:anyps5_desktop/ui/ps1_netplay_runner.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'webrtc_native_worker.dart';
import 'webrtc_room_fixture.dart';

Future<String> verifyOrdinaryWebRtc(String config) async {
  final args = (jsonDecode(await File(config).readAsString()) as List).cast<String>();
  if (args.length != 5) throw const FormatException('Expected a worker, core, CUE, BIOS and disc serial.');
  final profile = Ps1NetplayProfile.tryRead(args[4]);
  if (profile == null) throw const FormatException('Invalid PS1 disc serial.');
  const mode = Ps1NetplayRoomMode.ordinary;
  final media = await Ps1NetplayMedia.verify(
    profile: profile,
    core: args[1],
    disc: args[2],
    bios: args[3],
    execution: mode.execution,
  );
  const report = MethodChannel('anyps5/ps1_webrtc_probe');
  Future<int> pictures() async => (await report.invokeMethod<int>('published'))!;
  final work = await Directory.systemTemp.createTemp('anyps5-ps1-ordinary-webrtc-');
  EmbeddedRetroGame? source;
  EmbeddedRetroGame? matchGame;
  EmbeddedRetroGame? returned;
  var recoveryAccepted = false;
  WebRtcNativeWorker? guest;
  Ps1NetplayMatch? sender;
  Ps1NetplayMatch? receiver;

  Future<EmbeddedRetroGame> open({int? seat, int? recovery}) => EmbeddedRetroGame.start(
    work.path,
    (platform: RetroPlatform.ps1, path: media.disc),
    ordinaryCore: media.core,
    ordinaryRecovery: recovery,
    netplay: seat == null ? null : (media: media, seat: seat),
    internalResolution: null,
    graphics: const {},
    onResolutionSelected: (_) {},
    onGraphicsSelected: (_, _) {},
    readPad: () => PadState.idle,
    changed: () {},
  );

  try {
    final system = await Directory(p.join(work.path, 'system')).create();
    await File(media.bios).copy(p.join(system.path, 'scph1001.bin'));
    final original = source = await open();
    if (!await original.ready.timeout(const Duration(seconds: 12)) ||
        !original.canParkOrdinaryPs1 ||
        !original.hardwareRendering) {
      throw StateError('Ordinary play did not start in the hardware renderer.');
    }
    await _waitUntil(() async => await pictures() >= 180);

    final owned = EmbeddedPs1NetplayRunner((seat) async => matchGame = await open(seat: seat));
    final measured = _MeasuredRunner(owned);
    final handoff = OrdinaryPs1NetplayRunner(
      match: measured,
      park: () => original.captureOrdinaryNetplayCheckpoint(media, park: true),
      detach: original.detachOrdinaryCheckpoint,
      unpark: original.resumeOrdinaryCheckpoint,
      drainWorker: () async {
        await (matchGame ?? original).exitCode;
      },
      importMatch: (snapshot) async {
        await owned.restoreCheckpoint(snapshot);
        matchGame!.key(PadButton.start, true);
      },
      recover: (ticket) async {
        final resumed = returned = await open(recovery: ticket);
        if (!await resumed.ready.timeout(const Duration(seconds: 10)) ||
            !await resumed.acceptOrdinaryRecovery(ticket)) {
          throw StateError('The original game did not accept recovery.');
        }
        recoveryAccepted = true;
      },
    );
    final links = WebRtcProbeLinks();
    final gateway = WebRtcRoomFixture(profile.roomFor(mode), media.discDigest);
    final hostRoom = sender = Ps1NetplayMatch(
      rooms: gateway.client(WebRtcRoomFixture.host, expectedDigest: media.discDigest),
      links: links,
      identity: media.identity,
      runner: handoff,
      captureCheckpoint: handoff.capture,
    );
    gateway.events[WebRtcRoomFixture.host] = hostRoom.receive;
    final hosting = hostRoom.host(WebRtcRoomFixture.guest);
    await Future.any([gateway.invited, hosting.then((_) => throw StateError('The room closed before the invite.'))])
        .timeout(const Duration(seconds: 5));
    final waitStart = await pictures();
    await _waitUntil(() async => await pictures() >= waitStart + 15);
    if (handoff.detaching) throw StateError('The local worker detached before the guest joined.');
    final advertised = await gateway.client(WebRtcRoomFixture.guest).invitedDiscDigest(WebRtcRoomFixture.roomId);
    if (advertised != media.discDigest) throw StateError('The invite did not preserve the disc fingerprint.');

    final guestCore = guest = await WebRtcNativeWorker.spawn(
      [args.first, media.core, media.disc, media.bios],
      File(p.join(work.path, 'guest.state')),
      1,
      recompiler: true,
    );
    await guestCore.setPad(256);
    final guestInputs = _MeasuredRunner(guestCore);
    Object? restoreFailure;
    final guestRoom = receiver = Ps1NetplayMatch(
      rooms: gateway.client(WebRtcRoomFixture.guest, expectedDigest: advertised),
      links: links,
      identity: media.identity,
      runner: guestInputs,
      restoreCheckpoint: (snapshot) async {
        try {
          await guestCore.restore(snapshot, discDigest: media.discDigest);
        } on Object catch (error) {
          restoreFailure = error;
          rethrow;
        }
      },
    );
    gateway.events[WebRtcRoomFixture.guest] = guestRoom.receive;
    await Future.wait([hosting, guestRoom.join(WebRtcRoomFixture.roomId)]).timeout(const Duration(seconds: 8));
    final card = p.join(work.path, 'saves', 'ps1', '${p.basenameWithoutExtension(media.disc)}.srm');
    await _waitUntil(() async => matchGame != null);
    final cardHash = await AssetDownload.sha256Of(card);
    bool confirmedThrough(int frame) {
      if (hostRoom.closed || guestRoom.closed) {
        throw StateError(
          'Match ended early: ${hostRoom.session?.ended}, ${guestRoom.session?.ended}. '
          'Guest restore: ${restoreFailure ?? 'no error'}.',
        );
      }
      return (hostRoom.session?.confirmedFrame ?? -1) >= frame && (guestRoom.session?.confirmedFrame ?? -1) >= frame;
    }

    await _waitUntil(() async => confirmedThrough(119));
    final hostLink = links.opened.singleWhere((link) => link.offerCredentials.isNotEmpty);
    final guestLink = links.opened.singleWhere((link) => !identical(link, hostLink));
    final rejected = {'restart', 'offer', 'answer'};
    gateway.rejectSignal = (_, kind, data) =>
        kind == 'message' && data is Map && data['route'] == 1 && rejected.remove(data['kind']);
    final inputGap = Completer<void>();
    guestInputs.holdSync = inputGap.future;
    guestLink.reportState('failed');
    try {
      await _waitUntil(
        () async =>
            confirmedThrough(119) &&
            hostRoom.session?.progressStalled == true &&
            guestRoom.session?.progressStalled == true,
      );
      await _waitUntil(
        () async =>
            confirmedThrough(119) &&
            hostLink.answersApplied == 2 &&
            await hostLink.routeConnected() &&
            await guestLink.routeConnected(),
      );
    } finally {
      guestInputs.holdSync = null;
      inputGap.complete();
    }
    if (rejected.isNotEmpty ||
        links.opened.length != 2 ||
        hostLink.offerCredentials.length != 2 ||
        hostLink.offerCredentials.first == hostLink.offerCredentials.last) {
      throw StateError('ICE recovery did not retry signaling with fresh credentials on the original links.');
    }
    await _waitUntil(() async => confirmedThrough(359));
    if (hostRoom.session?.progressStalled != false || guestRoom.session?.progressStalled != false) {
      throw StateError('The match did not clear the sync status after inputs resumed.');
    }
    for (final frame in [119, 239, 359]) {
      if (measured.fingerprints[frame] == null || measured.fingerprints[frame] != guestCore.fingerprints[frame]) {
        throw StateError('Native RAM fingerprints differ at frame $frame.');
      }
    }
    if (!measured.sentButtons.contains(8) ||
        !guestCore.sentButtons.contains(256) ||
        await AssetDownload.sha256Of(card) != cardHash) {
      throw StateError('The match did not exercise both pads and preserve the original card.');
    }
    await guestRoom.leave();
    await hostRoom.done.timeout(const Duration(seconds: 12));
    final resumed = returned;
    if (!gateway.released ||
        gateway.signals < 2 ||
        !recoveryAccepted ||
        resumed == null ||
        resumed.textureId == original.textureId ||
        resumed.textureId == matchGame?.textureId ||
        !resumed.hardwareRendering) {
      throw StateError('The room did not close and return to the original renderer.');
    }
    final resumedAt = await pictures();
    await _waitUntil(() async => await pictures() >= resumedAt + 15);
    return 'Ordinary PS1 WebRTC passed for ${profile.titleId}: 360 confirmed frames, three matching RAM fingerprints, '
        'both pads, fresh ICE credentials after failed-route signaling retries, an unchanged local card, '
        'and hardware playback after room release.';
  } finally {
    try {
      await Future.wait([if (receiver != null) receiver.leave(), if (sender != null) sender.leave()])
          .timeout(const Duration(seconds: 13));
    } finally {
      try {
        for (final game in [returned, matchGame, source]) {
          if (game == null) continue;
          await game.close();
          await game.exitCode.timeout(const Duration(seconds: 4));
        }
        await guest?.stop();
      } finally {
        await work.delete(recursive: true);
      }
    }
  }
}

Future<void> _waitUntil(Future<bool> Function() ready) async {
  final timer = Stopwatch()..start();
  while (!await ready()) {
    if (timer.elapsed > const Duration(seconds: 18)) throw StateError('Timed out waiting for the PS1 probe.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _MeasuredRunner implements Ps1NetplayRunner {
  _MeasuredRunner(this.delegate);
  final Ps1NetplayRunner delegate;
  final fingerprints = <int, String>{};
  final sentButtons = <int>{};
  Future<void>? holdSync;

  @override
  Future<void> prepare(int seat) => delegate.prepare(seat);

  @override
  Future<void> start() => delegate.start();

  @override
  Future<void> stop() => delegate.stop();

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async {
    if (holdSync case final gate?) await gate;
    final tick = await delegate.sync(remote, acknowledgedFrame);
    fingerprints.addAll(tick.fingerprints);
    sentButtons.addAll(tick.local.map((sample) => sample.input.buttons));
    return tick;
  }
}
