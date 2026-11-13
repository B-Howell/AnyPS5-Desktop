import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_checkpoint_transfer.dart';
import 'package:anyps5_desktop/core/online/ps1_local_handoff.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_wire.dart';
import 'package:test/test.dart';

void main() {
  test('cancelling during capture drains the native ticket before another invite', () async {
    final capture = Completer<Ps1CheckpointSnapshot>();
    final handoff = Ps1LocalHandoff(
      ready: () async => true,
      capture: () => capture.future,
      hold: () async => throw StateError('No hold expected'),
      read: (frame) async => (nextFrame: frame, frames: <Ps1FrameInputs>[]),
      resume: () async => fail('An unheld host should continue local play'),
      begin: () async {},
      exchange: (_, _) async => throw StateError('No live inputs expected'),
    );
    await handoff.prepare(0);
    final snapshot = handoff.capture();
    var drained = false;
    final stopped = handoff.stop().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    capture.complete((frame: 400, state: Uint8List(16)));
    expect((await snapshot).frame, 400);
    await stopped;
  });

  test('cancellation drains the pending hold and resumes exactly once', () async {
    final held = Completer<int>();
    var resumes = 0;
    final handoff = Ps1LocalHandoff(
      ready: () async => true,
      capture: () async => (frame: 400, state: Uint8List(16)),
      hold: () => held.future,
      read: (frame) async => (nextFrame: frame, frames: <Ps1FrameInputs>[]),
      resume: () async => resumes++,
      begin: () async {},
      exchange: (_, _) async => throw StateError('No live inputs expected'),
    );
    await handoff.prepare(0);
    final hold = handoff.source.hold();
    final stopped = handoff.stop();
    expect(resumes, 0);
    held.complete(400);
    expect(await hold, 400);
    await Future.wait([stopped, handoff.stop()]);
    expect(resumes, 1);
  });

  test('leaving online drains a pending input exchange before holding the host again', () async {
    final inputs = Completer<void>();
    final operations = <String>[];
    final handoff = Ps1LocalHandoff(
      ready: () async => true,
      capture: () async => (frame: 400, state: Uint8List(16)),
      hold: () async {
        operations.add('hold');
        return 400;
      },
      read: (frame) async => (nextFrame: frame, frames: <Ps1FrameInputs>[]),
      resume: () async => operations.add('resume'),
      begin: () async => operations.add('begin'),
      exchange: (_, _) async {
        await inputs.future;
        operations.add('exchange');
        return (
          frame: 0,
          confirmedFrame: null,
          receivedFrame: null,
          waiting: true,
          local: <Ps1NetplayFrame>[],
          fingerprints: <int, String>{},
        );
      },
    );
    await handoff.prepare(0);
    await handoff.source.hold();
    await handoff.start();
    final tick = handoff.sync([], null);
    final stopped = handoff.stop();
    expect(operations, ['hold', 'begin']);
    inputs.complete();
    await tick;
    await stopped;
    expect(operations, ['hold', 'begin', 'exchange', 'hold', 'resume']);
  });
}
