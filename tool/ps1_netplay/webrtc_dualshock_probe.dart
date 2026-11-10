import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';

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
    final drivers = [_DualShockTrace(hostPad), _DualShockTrace(guestPad)];
    final launch = [args.first, media.core, media.disc, media.bios];
    for (final (seat, driver) in drivers.indexed) {
      final worker = await WebRtcNativeWorker.spawn(
        launch,
        File('${work.path}/seat-$seat.state'),
        seat,
        dualShock: true,
        onSync: driver.record,
      );
      workers.add(worker);
      await worker.setInput(driver.initial);
    }

    final gateway = WebRtcRoomFixture(profile.roomFor(mode), media.discDigest);
    final links = WebRtcProbeLinks(dropGamePacket: (packetNumber) => packetNumber % 5 == 0);
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
    while (drivers.any((driver) => driver.history == null) ||
        matches.any((match) => (match.session?.confirmedFrame ?? -1) < 359)) {
      if (deadline.elapsed > const Duration(seconds: 16) || matches.any((match) => match.closed)) {
        throw StateError('DualShock match stalled before recording confirmed input history.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final hostHistory = drivers.first.history!;
    final guestHistory = drivers.last.history!;
    for (var frame = 0; frame < hostHistory.length; frame++) {
      if (hostHistory[frame] != guestHistory[frame]) {
        throw StateError('Confirmed DualShock snapshots differ at frame $frame.');
      }
    }
    for (final (seat, driver) in drivers.indexed) {
      driver.verify(hostHistory.map((pair) => seat == 0 ? pair.$1 : pair.$2).toList());
    }
    if (links.opened.length != 2 || links.opened.any((link) => link.droppedGamePackets == 0)) {
      throw StateError('The probe did not drop input packets from both peers.');
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
    final drops = links.opened.map((link) => link.droppedGamePackets).join('/');
    return 'DualShock WebRTC passed for ${profile.titleId}: 360 matching two-port inputs, '
        'both stick reversals and releases, three matching RAM fingerprints, and $drops dropped input packets.';
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

final class _DualShockTrace {
  _DualShockTrace(this.initial);

  static const _neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);
  final Ps1PadInput initial;
  int _phase = 0;
  List<Ps1FrameInputs>? history;

  Ps1PadInput get _reversed => (
    buttons: initial.buttons,
    leftX: -initial.leftX,
    leftY: -initial.leftY,
    rightX: -initial.rightX,
    rightY: -initial.rightY,
  );

  Future<void> record(WebRtcNativeWorker worker, int frame) async {
    if (_phase == 0 && frame >= 100) {
      await worker.setInput(_reversed);
      _phase++;
    }
    if (_phase == 1 && frame >= 230) {
      await worker.setInput(_neutral);
      _phase++;
    }
    if (frame < 360 || history != null) return;
    history = [
      for (final first in [0, 120, 240]) ...(await worker.readHistory(first, frame)).frames.take(120),
    ];
    if (history!.length != 360) throw StateError('The native worker returned an incomplete input history.');
  }

  void verify(List<Ps1PadInput> pads) {
    final changes = <Ps1PadInput>[];
    for (final pad in pads.skip(16)) {
      if (changes.lastOrNull != pad) changes.add(pad);
    }
    if (changes.length != 3 || changes[0] != initial || changes[1] != _reversed || changes[2] != _neutral) {
      throw StateError('The DualShock snapshots did not change in the expected order.');
    }
    // The native two-tick sampler chooses the exact change frame. Compare
    // the complete histories across peers and verify stable windows on
    // either side of each change, leaving room for the sampling boundary.
    for (final (first, expected) in [(64, initial), (164, _reversed), (344, _neutral)]) {
      for (var frame = first; frame < first + 16; frame++) {
        if (pads[frame] != expected) throw StateError('Unexpected DualShock snapshot at frame $frame.');
      }
    }
  }
}
