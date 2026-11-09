import 'dart:async';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const report = MethodChannel('anyps5/ps1_webrtc_probe');
  try {
    await report.invokeMethod<void>('pass', await _exercise());
  } on Object catch (error, stack) {
    await report.invokeMethod<void>('fail', '$error\n$stack');
  }
}

const _neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);
const _pressed = (buttons: 8, leftX: -234, leftY: 0, rightX: 0, rightY: 0);

Future<String> _exercise() async {
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
    identity: identity,
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

  Ps1PadInput _local(int frame) => (frame + seat).isEven ? _pressed : _neutral;

  @override
  Future<void> prepare(int seat) async {}

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
