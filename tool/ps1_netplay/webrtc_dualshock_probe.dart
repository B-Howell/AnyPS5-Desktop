import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';

import 'webrtc_native_worker.dart';
import 'webrtc_room_fixture.dart';

Future<String> verifyDualShockWebRtc(String config) async {
  final args = (jsonDecode(await File(config).readAsString()) as List).cast<String>();
  if (args.length != 5) throw const FormatException('Expected a worker, core, CUE, BIOS and disc serial.');
  final profile = Ps1NetplayProfile.tryRead(args[4]);
  if (profile == null) throw const FormatException('Invalid PS1 disc serial.');
  const mode = Ps1NetplayRoomMode.freshAnalog;
  final media = await Ps1NetplayMedia.verify(
    profile: profile,
    core: args[1],
    disc: args[2],
    bios: args[3],
    execution: mode.execution,
  );
  if (!media.supportsHandoff) throw StateError('The test needs the portable core to read confirmed input history.');

  final work = await Directory.systemTemp.createTemp('anyps5-ps1-dualshock-');
  final workers = <WebRtcNativeWorker>[];
  final matches = <Ps1NetplayMatch>[];
  try {
    const hostPad = (buttons: 8, leftX: -19000, leftY: 14000, rightX: 24000, rightY: -12000);
    const guestPad = (buttons: 256, leftX: 21000, leftY: -16000, rightX: -25000, rightY: 13000);
    final launch = [args.first, media.core, media.disc, media.bios];
    for (final (seat, pad) in <(int, Ps1PadInput)>[(0, hostPad), (1, guestPad)]) {
      final worker = await WebRtcNativeWorker.spawn(
        launch,
        File('${work.path}/seat-$seat.state'),
        seat,
        dualShock: true,
      );
      workers.add(worker);
      await worker.setInput(pad);
    }

    final gateway = WebRtcRoomFixture(profile.roomFor(mode), media.discDigest);
    final links = WebRtcGameLinks();
    Ps1NetplayMatch match(String user, WebRtcNativeWorker worker) {
      final match = Ps1NetplayMatch(
        rooms: gateway.client(user, expectedDigest: media.discDigest, expectedCore: media.coreDigest),
        links: links,
        identity: media.identity,
        runner: worker,
      );
      matches.add(match);
      gateway.events[user] = match.receive;
      return match;
    }

    final host = match(WebRtcRoomFixture.host, workers.first);
    final hosting = host.host(WebRtcRoomFixture.guest);
    await Future.any([
      gateway.invited,
      hosting.then((_) => throw StateError('The DualShock room closed before the invite.')),
    ]).timeout(const Duration(seconds: 5));
    final invite = await gateway.client(WebRtcRoomFixture.guest).readInvite(WebRtcRoomFixture.roomId);
    if (invite.disc != media.discDigest || invite.core != media.coreDigest) {
      throw StateError('The DualShock room did not advertise the verified game and core.');
    }
    final guest = match(WebRtcRoomFixture.guest, workers.last);
    await Future.wait([hosting, guest.join(invite.room.id, expectedHost: invite.room.hostId)])
        .timeout(const Duration(seconds: 8));

    final deadline = Stopwatch()..start();
    while (workers.any((worker) => worker.confirmedPads == null) ||
        matches.any((match) => (match.session?.confirmedFrame ?? -1) < 359)) {
      if (deadline.elapsed > const Duration(seconds: 16) || matches.any((match) => match.closed)) {
        throw StateError('DualShock match stalled before recording confirmed input history.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (final worker in workers) {
      final pads = worker.confirmedPads!;
      if (pads.length != 16 || pads.any((pair) => pair != (hostPad, guestPad))) {
        throw StateError('Confirmed input history did not preserve both signed DualShock snapshots.');
      }
    }
    for (final frame in [119, 239, 359]) {
      final hash = workers.first.fingerprints[frame];
      if (hash == null || hash != workers.last.fingerprints[frame]) {
        throw StateError('DualShock RAM fingerprints differ at frame $frame.');
      }
    }
    await guest.leave();
    await host.done.timeout(const Duration(seconds: 6));
    if (!gateway.released || gateway.signals < 2) throw StateError('The DualShock room did not release.');
    return 'DualShock WebRTC passed for ${profile.titleId}: 360 confirmed frames, three matching RAM '
        'fingerprints, and 16 exact two-port signed snapshots in each native history.';
  } finally {
    try {
      await Future.wait(matches.map((match) => match.leave())).timeout(const Duration(seconds: 4));
    } finally {
      try {
        await Future.wait(workers.map((worker) => worker.stop()));
      } finally {
        await work.delete();
      }
    }
  }
}
