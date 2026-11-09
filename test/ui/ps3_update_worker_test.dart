import 'package:anyps5_desktop/core/ps3_update_import.dart';
import 'package:anyps5_desktop/ui/ps3_update_worker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('anyps5/retro_core');
  final calls = <String>[];
  final progress = <int>[];

  void worker(Map<String, Object?>? status) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'installPs3Packages' => true,
        'ps3PackageStatus' => status,
        _ => null,
      };
    });
  }

  Future<void> run({bool cancel = false}) => installPs3Packages(
    core: 'fixture.dll',
    stage: 'staging',
    count: 2,
    cancelled: () => cancel,
    progress: progress.add,
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
    progress.clear();
  });

  test('releases the lease after the worker confirms the complete chain', () async {
    worker({'ended': true, 'completed': 2, 'error': ''});
    await run();
    expect(progress, [2]);
    expect(calls, ['installPs3Packages', 'ps3PackageStatus', 'release']);
  });

  test('reports the rejected package index and releases the ended worker', () async {
    worker({'ended': true, 'completed': 1, 'rejected': true, 'error': 'Rejected'});
    await expectLater(run(), throwsA(isA<Ps3UpdateRejected>().having((issue) => issue.completed, 'completed', 1)));
    expect(calls.last, 'release');
  });

  test('a core initialization error does not claim a package was rejected', () async {
    worker({'ended': true, 'completed': 0, 'rejected': false, 'error': 'Core unavailable'});
    await expectLater(run(), throwsFormatException);
    expect(calls.last, 'release');
  });

  test('sends stop and waits for worker exit before releasing', () async {
    worker({'ended': true, 'completed': 1, 'error': 'Cancelled'});
    await expectLater(run(cancel: true), throwsA(isA<Ps3UpdateCancelled>()));
    expect(calls, ['installPs3Packages', 'stop', 'ps3PackageStatus', 'release']);
  });

  test('unconfirmed worker status requests stop but never releases a live lease', () async {
    worker(null);
    await expectLater(run(), throwsA(isA<Ps3UpdateWorkerUnconfirmed>()));
    expect(calls, [
      'installPs3Packages',
      ...List.filled(6, 'ps3PackageStatus'),
      'stop',
      ...List.filled(6, 'ps3PackageStatus'),
    ]);
  });

  test('retries a transient status error without stopping the install', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'installPs3Packages') return true;
      if (call.method == 'ps3PackageStatus' && calls.length > 2) {
        return {'ended': true, 'completed': 2, 'error': ''};
      }
      return null;
    });
    await run();
    expect(calls, ['installPs3Packages', 'ps3PackageStatus', 'ps3PackageStatus', 'release']);
  });

  test('retries releasing an ended lease after a temporary channel error', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'installPs3Packages') return true;
      if (call.method == 'ps3PackageStatus') return {'ended': true, 'completed': 2, 'error': ''};
      if (call.method == 'release' && attempts++ == 0) throw PlatformException(code: 'temporary');
      return null;
    });
    await run();
    expect(calls, ['installPs3Packages', 'ps3PackageStatus', 'release', 'release']);
  });
}
