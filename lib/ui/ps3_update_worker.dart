import 'package:flutter/services.dart';

import '../core/ps3_update_import.dart';

/// Owns the native lease until the worker has stopped touching the stage.
Future<void> installPs3Packages({
  required String core,
  required String stage,
  required int count,
  required bool Function() cancelled,
  required void Function(int) progress,
}) async {
  const channel = MethodChannel('anyps5/retro_core');
  try {
    if (await channel.invokeMethod<bool>('installPs3Packages', {'core': core, 'stage': stage, 'count': count}) !=
        true) {
      throw const Ps3UpdateWorkerUnconfirmed();
    }
  } on PlatformException catch (error) {
    if (const {'busy', 'argument', 'install'}.contains(error.code)) rethrow;
    throw const Ps3UpdateWorkerUnconfirmed();
  }

  const pollDelay = Duration(milliseconds: 125);
  Future<({bool ended, int completed, bool rejected, String error})> readStatus() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final status = await channel.invokeMapMethod<String, Object?>('ps3PackageStatus');
        final ended = status?['ended'];
        final completed = status?['completed'];
        final error = status?['error'];
        if (ended is bool && completed is int && completed >= 0 && completed <= count && error is String) {
          return (ended: ended, completed: completed, rejected: status?['rejected'] == true, error: error);
        }
      } on Object {
        // Retry a temporary status error before asking the worker to stop.
      }
      await Future<void>.delayed(pollDelay);
    }
    throw const Ps3UpdateWorkerUnconfirmed();
  }

  Future<void> release() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await channel.invokeMethod<void>('release');
        return;
      } on Object {
        await Future<void>.delayed(pollDelay);
      }
    }
    throw const Ps3UpdateWorkerUnconfirmed();
  }

  var ended = false;
  var stopSent = false;
  try {
    while (true) {
      if (cancelled() && !stopSent) {
        await channel.invokeMethod<void>('stop');
        stopSent = true;
      }
      final status = await readStatus();
      ended = status.ended;
      progress(status.completed);
      if (ended) {
        if (stopSent || cancelled()) throw const Ps3UpdateCancelled();
        if (status.rejected) throw Ps3UpdateRejected(status.completed);
        if (status.completed != count || status.error.isNotEmpty) {
          throw const FormatException('RPCS3 could not run the update installer.');
        }
        return;
      }
      await Future<void>.delayed(pollDelay);
    }
  } catch (_) {
    if (ended) rethrow;
    try {
      await channel.invokeMethod<void>('stop');
    } on Object {
      // Poll anyway. A transient channel error can arrive after stop was sent.
    }
    try {
      do {
        await Future<void>.delayed(pollDelay);
        ended = (await readStatus()).ended;
      } while (!ended);
    } on Object {
      throw const Ps3UpdateWorkerUnconfirmed();
    }
    throw const FormatException('The PS3 update worker stopped after a status error.');
  } finally {
    if (ended) await release();
  }
}

final class Ps3UpdateRejected implements Exception {
  const Ps3UpdateRejected(this.completed);
  final int completed;
}
