import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/ps1_local_handoff.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'webrtc_dualshock_probe.dart';
import 'webrtc_native_worker.dart';
import 'webrtc_lan_probe.dart';
import 'webrtc_live_race.dart';
import 'webrtc_ordinary_probe.dart';
import 'webrtc_room_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const report = MethodChannel('anyps5/ps1_webrtc_probe');
  try {
    final live = Platform.environment['ANYPS5_PS1_WEBRTC_LIVE'];
    if (live != null) {
      final result = await runLivePs1Race(live);
      if (Platform.isLinux) {
        stdout.writeln(result);
        exit(0);
      }
      await report.invokeMethod<void>('pass', result);
      return;
    }
    final config = Platform.environment['ANYPS5_PS1_WEBRTC_NATIVE'] ?? '';
    final lan = Platform.environment['ANYPS5_PS2_WEBRTC_LAN'] == '1';
    final ordinary = Platform.environment['ANYPS5_PS1_WEBRTC_ORDINARY'] == '1';
    final dualShock = Platform.environment['ANYPS5_PS1_WEBRTC_DUALSHOCK'] == '1';
    final tracePath = Platform.environment['ANYPS5_PS1_WEBRTC_RACE_TRACE'] ?? '';
    final raceTrace = tracePath.isEmpty ? null : tracePath;
    final port = Platform.environment['ANYPS5_TEST_TURN_PORT'] ?? '';
    final turnPort = int.tryParse(port);
    final turnAddress = InternetAddress.tryParse(Platform.environment['ANYPS5_TEST_TURN_ADDRESS'] ?? '');
    String? turnUrl;
    if (port.isNotEmpty) {
      if (!(dualShock || lan) ||
          turnPort == null ||
          turnPort < 1024 ||
          turnPort > 65535 ||
          turnAddress?.type != InternetAddressType.IPv4 ||
          turnAddress!.address == '0.0.0.0') {
        throw StateError('A local TURN endpoint requires an IPv4 address, valid port and DualShock or LAN mode.');
      }
      turnUrl = 'turn:${turnAddress.address}:$turnPort?transport=udp';
    }
    if (raceTrace != null && !dualShock) throw StateError('A race trace requires DualShock mode.');
    if ((ordinary || dualShock) && config.isEmpty) throw StateError('This probe requires a native fixture.');
    if ((ordinary && dualShock) || (lan && config.isNotEmpty)) throw StateError('Conflicting WebRTC probe modes.');
    await report.invokeMethod<void>(
      'pass',
      lan
          ? await verifyWebRtcLanBridge(turnUrl: turnUrl)
          : config.isEmpty
          ? '${await _exercise()} ${await _exercise(mismatchedDisc: true)}'
          : ordinary
          ? await verifyOrdinaryWebRtc(config)
          : dualShock
          ? await verifyDualShockWebRtc(config, raceTrace: raceTrace, turnUrl: turnUrl)
          : await _nativeExercise(config),
    );
  } on Object catch (error, stack) {
    if (Platform.isLinux && Platform.environment.containsKey('ANYPS5_PS1_WEBRTC_LIVE')) {
      stderr.writeln('Hosted PS1 probe failed: $error');
      exit(1);
    }
    await report.invokeMethod<void>('fail', '$error\n$stack');
  }
}

Future<String> _nativeExercise(String config) async {
  final args = (jsonDecode(await File(config).readAsString()) as List).cast<String>();
  if (args.length != 5) throw const FormatException('Expected a worker, core, CUE, BIOS and disc serial.');
  final profile = Ps1NetplayProfile.tryRead(args[4]);
  if (profile == null) throw const FormatException('Invalid PS1 disc serial.');
  final media = await Ps1NetplayMedia.verify(
    profile: profile,
    resolveCore: () => args[1],
    disc: args[2],
    bios: args[3],
  );
  if (!media.supportsHandoff) throw StateError('The test needs the portable core.');
  final work = await Directory.systemTemp.createTemp('anyps5-ps1-webrtc-');
  final hostState = File('${work.path}/host.state');
  final guestState = File('${work.path}/guest.state');
  final launch = [args.first, media.core, media.disc, media.bios];
  WebRtcNativeWorker? local;
  WebRtcNativeWorker? remote;
  Ps1NetplayMatch? hostMatch;
  Ps1NetplayMatch? guestMatch;
  try {
    final host = local = await WebRtcNativeWorker.spawn(launch, hostState, 0, local: true);
    await host.waitForPicture(180);
    await host.setPad(8);
    final guest = remote = await WebRtcNativeWorker.spawn(launch, guestState, 1);
    await guest.setPad(256);
    final links = WebRtcGameLinks();
    final gateway = WebRtcRoomFixture(profile.roomFor(Ps1NetplayRoomMode.staged), media.discDigest);
    var held = 0;
    var replayed = 0;
    var stateBytes = 0;
    final handoff = Ps1LocalHandoff(
      ready: () async => true,
      capture: () async {
        final snapshot = await host.capture();
        stateBytes = snapshot.state.length;
        return snapshot;
      },
      hold: () async => held = await host.hold(),
      read: (first) => host.readHistory(first, held),
      resume: host.resume,
      begin: host.start,
      exchange: host.sync,
    );
    final sender = hostMatch = Ps1NetplayMatch(
      rooms: gateway.client(WebRtcRoomFixture.host, expectedDigest: media.discDigest),
      links: links,
      identity: media.identity,
      runner: handoff,
      captureCheckpoint: handoff.capture,
      catchupSource: handoff.source,
    );
    gateway.events[WebRtcRoomFixture.host] = sender.receive;
    final hosting = sender.host(WebRtcRoomFixture.guest);
    final advertised = await Future.any([
      gateway.invited.then((_) => gateway.client(WebRtcRoomFixture.guest).readInvite(WebRtcRoomFixture.roomId)),
      hosting.then((_) => throw StateError('The host closed before inviting its guest.')),
    ]).timeout(const Duration(seconds: 5));
    if (advertised.disc != media.discDigest) throw StateError('The invite did not preserve the disc fingerprint.');
    final receiver = guestMatch = Ps1NetplayMatch(
      rooms: gateway.client(WebRtcRoomFixture.guest, expectedDigest: advertised.disc),
      links: links,
      identity: media.identity,
      runner: guest,
      restoreCheckpoint: (snapshot) async {
        // Keep the local host advancing while the guest is still loading.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await guest.restore(snapshot);
      },
      catchupReplay: (first, batch) async {
        await guest.replay(first, batch);
        replayed += batch.length;
      },
    );
    gateway.events[WebRtcRoomFixture.guest] = receiver.receive;
    await Future.wait([hosting, receiver.join(advertised.room.id, expectedHost: advertised.room.hostId)])
        .timeout(const Duration(seconds: 8));
    final elapsed = Stopwatch()..start();
    while ((sender.session?.confirmedFrame ?? -1) < 359 || (receiver.session?.confirmedFrame ?? -1) < 359) {
      if (elapsed.elapsed > const Duration(seconds: 17) || sender.closed || receiver.closed) {
        throw StateError(
          'Native handoff stalled. Host: ${sender.session?.ended}, guest: ${receiver.session?.ended}, '
          'replayed: $replayed.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (final frame in [119, 239, 359]) {
      if (host.fingerprints[frame] == null || host.fingerprints[frame] != guest.fingerprints[frame]) {
        throw StateError('Native RAM fingerprints differ at frame $frame.');
      }
    }
    if (sender.closed || receiver.closed || sender.session?.ended != null || receiver.session?.ended != null) {
      throw StateError('A peer left before the test completed.');
    }
    if (replayed < 10 || !host.sentButtons.contains(8) || !guest.sentButtons.contains(256)) {
      throw StateError('The test did not exercise catch-up and both controllers.');
    }
    await receiver.leave();
    await sender.done.timeout(const Duration(seconds: 6));
    if (!gateway.released || gateway.signals < 2) throw StateError('The private room lifecycle was incomplete.');
    final picture = await host.picture();
    await host.waitForPicture(picture + 15);
    return 'Native WebRTC loopback passed for ${profile.titleId}: private invite, ${gateway.signals} directed signals, '
        '$stateBytes checkpoint bytes, $replayed replay frames, 360 live frames with three matching RAM fingerprints, '
        'and host resumed local play after room release.';
  } finally {
    try {
      await Future.wait([if (hostMatch != null) hostMatch.leave(), if (guestMatch != null) guestMatch.leave()])
          .timeout(const Duration(seconds: 4));
    } finally {
      try {
        await Future.wait([if (local != null) local.stop(), if (remote != null) remote.stop()]);
      } finally {
        for (final state in [hostState, guestState]) {
          if (await state.exists()) await state.delete();
        }
        await work.delete();
      }
    }
  }
}

const _neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);
const _pressed = (buttons: 8, leftX: -234, leftY: 0, rightX: 0, rightY: 0);

Future<String> _exercise({bool mismatchedDisc = false}) async {
  final links = WebRtcGameLinks();
  final hostLink = await links.link([]);
  final GameLink guestLink;
  try {
    guestLink = await links.link([]);
  } on Object {
    await hostLink.close();
    rethrow;
  }
  final identity = Ps1NetplayIdentity.tryRead({
    'version': 1,
    'title': 'SCUS94426',
    for (final key in ['disc', 'bios', 'core', 'profile', 'card']) key: 'a' * 64,
  })!;
  final checkpoint = Uint8List(3 * 1024 * 1024);
  for (var index = 0; index < checkpoint.length; index++) {
    checkpoint[index] = index % 251;
  }
  final frames = List<Ps1FrameInputs>.generate(180, (index) => (index.isEven ? _pressed : _neutral, _neutral));
  var replayed = 0;
  var restored = false;
  final hosts = _ProbeRunner(0);
  final guests = _ProbeRunner(1);
  late final Ps1NetplayPeer guest;
  final host = Ps1NetplayPeer(
    link: hostLink,
    identity: identity,
    runner: hosts,
    seat: 0,
    hostEpoch: 17,
    sendSignal: (signal) async => guest.receiveSignal(signal),
    captureCheckpoint: () async => (frame: 100, state: checkpoint),
    catchupSource: (
      hold: () async => 280,
      read: (first) async => (nextFrame: 280, frames: frames.skip(first - 100).take(120).toList()),
    ),
  );
  guest = Ps1NetplayPeer(
    link: guestLink,
    identity: mismatchedDisc ? Ps1NetplayIdentity.tryRead({...identity.toJson(), 'disc': 'b' * 64})! : identity,
    runner: guests,
    seat: 1,
    sendSignal: (signal) async => host.receiveSignal(signal),
    restoreCheckpoint: (snapshot) async {
      if (snapshot.frame != 100 || snapshot.state.length != checkpoint.length) {
        throw StateError('The guest received the wrong checkpoint.');
      }
      for (var index = 0; index < checkpoint.length; index++) {
        if (snapshot.state[index] != checkpoint[index]) throw StateError('Checkpoint differs at byte $index.');
      }
      restored = true;
    },
    catchupReplay: (first, batch) async {
      if (!restored || first != 100 + replayed) throw StateError('The guest replay cursor was incorrect.');
      for (final input in batch) {
        if (input != frames[replayed++]) throw StateError('The guest replayed different controller inputs.');
      }
    },
  );
  try {
    final elapsed = Stopwatch()..start();
    await guest.open();
    await host.open();
    if (mismatchedDisc) {
      await Future.wait([host.done, guest.done]).timeout(const Duration(seconds: 8));
      if (host.session.ended != Ps1NetplayEnd.mismatch ||
          guest.session.ended != Ps1NetplayEnd.mismatch ||
          host.session.mismatch != Ps1NetplayMismatch.disc ||
          guest.session.mismatch != Ps1NetplayMismatch.disc ||
          hosts.prepared ||
          guests.prepared) {
        throw StateError(
          'The disc mismatch did not reach both players before preparation. '
          'Host: ${host.session.ended}, ${host.session.mismatch}. '
          'Guest: ${guest.session.ended}, ${guest.session.mismatch}.',
        );
      }
      return 'Both WebRTC peers received the disc mismatch before preparing the game.';
    }
    while (elapsed.elapsed < const Duration(seconds: 18)) {
      if (host.session.ended != null || guest.session.ended != null) break;
      if (host.session.confirmedFrame == 119 &&
          guest.session.confirmedFrame == 119 &&
          hosts.inputs.length == 120 &&
          guests.inputs.length == 120) {
        // Wait for the last fingerprints on the ordered stream.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (host.session.ended != null ||
            guest.session.ended != null ||
            replayed != 180 ||
            host.session.handoffFrame != 280 ||
            guest.session.handoffFrame != 280) {
          break;
        }
        for (var index = 0; index < 120; index++) {
          if (hosts.inputs[index] != guests.inputs[index]) throw StateError('Live inputs differ at $index.');
        }
        return 'Windows WebRTC loopback passed with a 3 MiB checkpoint, $replayed replay frames, and 120 live frames.';
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final hostEnd = (host.session.phase, host.session.ended, host.session.confirmedFrame);
    final guestEnd = (guest.session.phase, guest.session.ended, guest.session.confirmedFrame);
    throw StateError(
      'WebRTC handoff did not complete. '
      'Host: $hostEnd. Guest: $guestEnd. Restored: $restored. Replayed: $replayed.',
    );
  } finally {
    await Future.wait([host.leave(), guest.leave()]);
  }
}

final class _ProbeRunner implements Ps1NetplayRunner {
  _ProbeRunner(this.seat);

  final int seat;
  final inputs = <Ps1FrameInputs>[];
  final _remote = <int, Ps1PadInput>{};
  int? _received;
  bool prepared = false;

  Ps1PadInput _local(int frame) => (frame + seat).isEven ? _pressed : _neutral;

  @override
  Future<void> prepare(int seat) async => prepared = true;

  @override
  Future<void> start() async {}

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async {
    for (final sample in remote) {
      _remote[sample.frame] = sample.input;
    }
    while (_remote.containsKey((_received ?? -1) + 1)) {
      _received = (_received ?? -1) + 1;
    }
    while (inputs.length < 120) {
      final other = _remote[inputs.length];
      if (other == null) break;
      final local = _local(inputs.length);
      inputs.add(seat == 0 ? (local, other) : (other, local));
    }
    final first = (acknowledgedFrame ?? -1) + 1;
    return (
      frame: inputs.length,
      confirmedFrame: inputs.isEmpty ? null : inputs.length - 1,
      receivedFrame: _received,
      waiting: inputs.length < 120,
      local: <Ps1NetplayFrame>[
        for (var frame = first; frame < first + 8 && frame < 120; frame++) (frame: frame, input: _local(frame)),
      ],
      fingerprints: <int, String>{if (inputs.length == 120) 119: '0123456789abcdef'},
    );
  }

  @override
  Future<void> stop() async {}
}
