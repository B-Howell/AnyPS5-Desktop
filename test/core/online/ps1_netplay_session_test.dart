import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:test/test.dart';

const _epoch = 42;
const _neutral = (buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0);

Ps1NetplayIdentity _identity({String disc = 'a'}) => Ps1NetplayIdentity.tryRead({
  'version': 1,
  'title': 'SCUS-94426',
  'disc': disc * 64,
  'bios': 'b' * 64,
  'core': 'c' * 64,
  'profile': 'd' * 64,
  'card': 'e' * 64,
})!;

class _Runner implements Ps1NetplayRunner {
  final local = <int, Ps1PadInput>{};
  final remote = <int, Ps1PadInput>{};
  final raced = <(Ps1PadInput, Ps1PadInput)>[];
  Completer<void>? boot;
  Completer<void>? inSync;
  var prepareCalls = 0;
  var startCalls = 0;
  var stopCalls = 0;
  var syncCalls = 0;
  var frame = 0;
  var frameLimit = 32;
  var fingerprint = '0123456789abcdef';
  int? highestReceived;
  int? ack;
  late int seat;

  @override
  Future<void> prepare(int seat) async {
    prepareCalls++;
    this.seat = seat;
    await boot?.future;
  }

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> samples, int? acknowledgedFrame) async {
    syncCalls++;
    await inSync?.future;
    ack = acknowledgedFrame;
    for (final sample in samples) {
      expect(remote.containsKey(sample.frame), isFalse, reason: 'only new frames reach the native queue');
      remote[sample.frame] = sample.input;
    }
    while (remote.containsKey((highestReceived ?? -1) + 1)) {
      highestReceived = (highestReceived ?? -1) + 1;
    }
    if (local.length < frameLimit) {
      final number = local.length;
      local[number] = (
        buttons: ((number + 1) << seat) & 0xFFFF,
        leftX: (number + 1) * (seat == 0 ? 100 : -100),
        leftY: 0,
        rightX: 0,
        rightY: 0,
      );
    }
    while (local.containsKey(frame) && remote.containsKey(frame)) {
      raced.add(seat == 0 ? (local[frame]!, remote[frame]!) : (remote[frame]!, local[frame]!));
      frame++;
    }
    final pending = local.entries.where((entry) => entry.key > (ack ?? -1)).take(8).toList();
    if (pending.isEmpty && local.isNotEmpty) pending.add(local.entries.last);
    return (
      frame: frame,
      confirmedFrame: frame == 0 ? null : frame - 1,
      receivedFrame: highestReceived,
      waiting: !remote.containsKey(frame),
      fingerprints: {for (var checkpoint = 119; checkpoint < frame; checkpoint += 120) checkpoint: fingerprint},
      local: [for (final item in pending) (frame: item.key, input: item.value)],
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (boot?.isCompleted == false) boot!.complete();
    if (inSync?.isCompleted == false) inSync!.complete();
  }
}

class _Peers {
  _Peers({Ps1NetplayIdentity? guestIdentity, Duration timeout = const Duration(seconds: 5)}) {
    host = Ps1NetplaySession(
      seat: 0,
      hostEpoch: _epoch,
      identity: _identity(),
      runner: h,
      sendControl: (message) => toGuestControl.add(message),
      sendInput: (message) => toGuestInput.add(message),
      timeout: timeout,
    );
    guest = Ps1NetplaySession(
      seat: 1,
      identity: guestIdentity ?? _identity(),
      runner: g,
      sendControl: (message) => toHostControl.add(message),
      sendInput: (message) => toHostInput.add(message),
      timeout: timeout,
    );
  }

  final h = _Runner();
  final g = _Runner();
  final toGuestControl = <Uint8List>[];
  final toHostControl = <Uint8List>[];
  final toGuestInput = <Uint8List>[];
  final toHostInput = <Uint8List>[];
  late final Ps1NetplaySession host;
  late final Ps1NetplaySession guest;

  Future<void> controls({bool duplicate = false}) async {
    for (var iteration = 0; iteration < 12; iteration++) {
      for (final message in toGuestControl.toList()) {
        toGuestControl.remove(message);
        guest.receiveControl(message);
        if (duplicate) guest.receiveControl(message);
      }
      for (final message in toHostControl.toList()) {
        toHostControl.remove(message);
        host.receiveControl(message);
        if (duplicate) host.receiveControl(message);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> open({bool duplicate = false}) async {
    guest.open();
    host.open();
    await controls(duplicate: duplicate);
  }

  void inputs({bool loss = false, bool reorder = false}) {
    for (final (queue, peer) in [(toGuestInput, guest), (toHostInput, host)]) {
      if (loss && queue.length > 1) queue.removeAt(0);
      for (final packet in (reorder ? queue.reversed : queue)) {
        peer.receiveInput(packet);
        peer.receiveInput(packet);
      }
      queue.clear();
    }
  }

  Future<void> close() async {
    host.leave();
    guest.leave();
    await Future.wait([host.done, guest.done]);
  }
}

Uint8List _fingerprintControl(int frame, String hash) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'protocol': 'anyps5-ps1',
      'version': Ps1InputWire.version,
      'seat': 1,
      'epoch': '42',
      'kind': 'fingerprint',
      'data': [frame, hash],
    }),
  ),
);

void main() {
  test('matches the identity, waits for both native peers and starts each runner once', () async {
    final p = _Peers();
    addTearDown(p.close);
    p.g.boot = Completer<void>();
    await p.open(duplicate: true);
    expect(p.h.prepareCalls, 1);
    expect(p.g.prepareCalls, 1);
    expect(p.h.startCalls, 0);
    expect(p.g.startCalls, 0);
    p.g.boot!.complete();
    await p.controls(duplicate: true);
    expect(p.host.phase, Ps1NetplayPhase.running);
    expect(p.guest.phase, Ps1NetplayPhase.running);
    expect(p.h.startCalls, 1);
    expect(p.g.startCalls, 1);
  });

  test('exchanges ordered native inputs under loss, reorder and duplicates', () async {
    final p = _Peers();
    addTearDown(p.close);
    await p.open();
    for (var tick = 0; tick < 48; tick++) {
      await Future.wait([p.host.pump(), p.guest.pump()]);
      if (tick.isOdd) p.inputs(loss: tick % 6 == 3, reorder: true);
    }
    expect(p.h.raced, hasLength(32));
    expect(p.h.raced, p.g.raced);
    expect(p.h.raced.first.$1.leftX, 100);
    expect(p.h.raced.first.$2.leftX, -100);
    expect(p.host.confirmedFrame, 31);
    expect(p.guest.confirmedFrame, 31);
    expect(p.h.ack, 31);
    expect(p.g.ack, 31);
  });

  for (final mismatch in [false, true]) {
    test('periodic fingerprints ${mismatch ? 'stop on the first divergence' : 'match without stopping'}', () async {
      final p = _Peers();
      addTearDown(p.close);
      p.h.frameLimit = p.g.frameLimit = 245;
      if (mismatch) p.g.fingerprint = 'fedcba9876543210';
      await p.open();
      var sent = 0;
      for (var tick = 0; tick < 260; tick++) {
        await Future.wait([p.host.pump(), p.guest.pump()]);
        sent += p.toGuestControl.length + p.toHostControl.length;
        // Deliver after both peers pump so each comparison is against a locally confirmed frame.
        await p.controls(duplicate: true);
        p.inputs();
        if (p.host.ended != null || p.guest.ended != null) break;
      }
      if (mismatch) {
        expect(p.host.ended, Ps1NetplayEnd.desync);
        expect(p.guest.ended, Ps1NetplayEnd.desync);
        expect(p.host.desyncFrame, 119);
        expect(p.guest.desyncFrame, 119);
        expect(p.h.stopCalls, 1);
        expect(p.g.stopCalls, 1);
        expect(sent, 2);
      } else {
        expect(p.host.phase, Ps1NetplayPhase.running);
        expect(p.guest.phase, Ps1NetplayPhase.running);
        expect(p.host.confirmedFrame, 244);
        expect(p.guest.confirmedFrame, 244);
        expect(sent, 4, reason: 'each peer announces each checkpoint once');
      }
    });
  }

  test('buffers an early peer fingerprint until that frame is locally confirmed', () async {
    final p = _Peers();
    addTearDown(p.close);
    p.h.frameLimit = p.g.frameLimit = 121;
    await p.open();
    p.host.receiveControl(_fingerprintControl(119, p.h.fingerprint));
    expect(p.host.ended, isNull);
    for (var tick = 0; tick < 124; tick++) {
      await Future.wait([p.host.pump(), p.guest.pump()]);
      await p.controls();
      p.inputs();
    }
    expect(p.host.confirmedFrame, 120);
    expect(p.host.ended, isNull);
  });

  test('rejects malformed and out-of-order peer fingerprints', () async {
    for (final invalid in [
      _fingerprintControl(118, '0123456789abcdef'),
      _fingerprintControl(119, '0123456789ABCDEF'),
      _fingerprintControl(239, '0123456789abcdef'),
    ]) {
      final p = _Peers();
      addTearDown(p.close);
      await p.open();
      p.host.receiveControl(invalid);
      await p.host.done;
      expect(p.host.ended, Ps1NetplayEnd.protocol);
    }
  });

  test('honors a fresh acknowledgement on a retried batch older than eight frames', () async {
    final p = _Peers();
    addTearDown(p.close);
    await p.open();
    Uint8List packet(int first, int seq, {int? ack, int count = 1}) => Ps1InputWire.encode(
      Ps1InputPacket(
        epoch: _epoch,
        seat: 1,
        sequence: seq,
        acknowledgedFrame: ack,
        firstFrame: first,
        inputs: List.filled(count, _neutral),
      ),
    );
    for (var frame = 0; frame < 17; frame++) {
      p.host.receiveInput(packet(frame, frame));
      await p.host.pump();
    }
    expect(p.h.highestReceived, 16);
    expect(p.h.ack, isNull);

    // The peer hasn't seen our cumulative ACK yet and retries its oldest batch.
    // Its new ACK still has to release our locally buffered samples.
    p.host.receiveInput(packet(0, 17, ack: 7, count: 8));
    await p.host.pump();
    expect(p.h.ack, 7);
    expect(p.h.remote.length, 17, reason: 'the retried input was already received');

    // The native timeline rejects inputs more than 64 ahead. Drop these at the wire
    // boundary before they can invalidate a sync call with otherwise legitimate data.
    p.host.receiveInput(packet(p.h.frame + 65, 18));
    await p.host.pump();
    expect(p.h.remote.length, 17);
    expect(p.host.phase, Ps1NetplayPhase.running);
  });

  test('both peers see a specific content mismatch before native preparation', () async {
    final p = _Peers(guestIdentity: _identity(disc: 'f'));
    addTearDown(p.close);
    await p.open();
    expect(p.host.ended, Ps1NetplayEnd.mismatch);
    expect(p.guest.ended, Ps1NetplayEnd.mismatch);
    expect(p.host.mismatch, Ps1NetplayMismatch.disc);
    expect(p.guest.mismatch, Ps1NetplayMismatch.disc);
    expect(p.h.prepareCalls, 0);
    expect(p.g.prepareCalls, 0);
  });

  test('drops stale epochs and detects conflicting retransmissions', () async {
    final p = _Peers();
    addTearDown(p.close);
    await p.open();
    Uint8List packet(int epoch, int seq, Ps1PadInput input) => Ps1InputWire.encode(
      Ps1InputPacket(epoch: epoch, seat: 1, sequence: seq, acknowledgedFrame: null, firstFrame: 0, inputs: [input]),
    );
    p.host.receiveInput(packet(41, 10, _neutral));
    p.host.receiveInput(packet(_epoch, 11, _neutral));
    p.host.receiveInput(packet(_epoch, 12, (buttons: 1, leftX: 0, leftY: 0, rightX: 0, rightY: 0)));
    await p.host.done;
    expect(p.host.ended, Ps1NetplayEnd.protocol);
    expect(p.h.stopCalls, 1);
  });

  test('leave cancels pending preparation and notifies the other peer once', () async {
    final p = _Peers();
    addTearDown(p.close);
    p.g.boot = Completer<void>();
    await p.open();
    p.host.leave();
    await p.controls();
    await Future.wait([p.host.done, p.guest.done]);
    expect(p.host.ended, Ps1NetplayEnd.left);
    expect(p.guest.ended, Ps1NetplayEnd.peerLeft);
    expect(p.h.stopCalls, 1);
    expect(p.g.stopCalls, 1);
    expect(p.g.startCalls, 0);
  });

  test('times out waiting for the peer and never restarts a closed match', () async {
    final p = _Peers(timeout: const Duration(milliseconds: 25));
    addTearDown(p.close);
    p.host.open();
    await p.host.done.timeout(const Duration(seconds: 1));
    expect(p.host.ended, Ps1NetplayEnd.timedOut);
    expect(p.h.prepareCalls, 0);
    expect(p.host.open, throwsStateError);
  });

  test('rejects oversized and invalid reliable control before boot', () async {
    final p = _Peers();
    addTearDown(p.close);
    p.guest.open();
    p.guest.receiveControl(Uint8List.fromList(utf8.encode('{"bad":true}')));
    await p.guest.done;
    expect(p.guest.ended, Ps1NetplayEnd.protocol);
    expect(p.g.prepareCalls, 0);

    p.host.open();
    p.host.receiveControl(Uint8List(1025));
    await p.host.done;
    expect(p.host.ended, Ps1NetplayEnd.protocol);
  });

  test('a peer retransmitting unchanged snapshots cannot keep a stalled match alive', () async {
    final p = _Peers(timeout: const Duration(milliseconds: 80));
    addTearDown(p.close);
    await p.open();
    expect(p.host.phase, Ps1NetplayPhase.running);
    var sequence = 0;
    final repeats = Timer.periodic(const Duration(milliseconds: 5), (_) {
      p.host.receiveInput(
        Ps1InputWire.encode(
          Ps1InputPacket(
            epoch: _epoch,
            seat: 1,
            sequence: sequence++,
            acknowledgedFrame: null,
            firstFrame: 0,
            inputs: const [_neutral],
          ),
        ),
      );
    });
    addTearDown(repeats.cancel);
    await p.host.done.timeout(const Duration(seconds: 1));
    expect(p.host.ended, Ps1NetplayEnd.timedOut);
    expect(p.h.stopCalls, 1);
  });

  test('only one native sync may run at a time and disconnect cancels it', () async {
    final p = _Peers();
    addTearDown(p.close);
    await p.open();
    p.h.inSync = Completer<void>();
    final first = p.host.pump();
    await p.host.pump();
    expect(p.h.syncCalls, 1);
    p.host.disconnect();
    await p.host.done;
    await first;
    expect(p.host.ended, Ps1NetplayEnd.disconnected);
    expect(p.h.stopCalls, 1);
    expect(p.toGuestInput, isEmpty);
  });
}
