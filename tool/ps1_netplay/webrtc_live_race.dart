import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/online_peer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_match.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_media.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/server.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:path/path.dart' as p;

import 'webrtc_ctr_race.dart';
import 'webrtc_native_worker.dart';

/// An acceptance peer for the hosted service. Each machine uses its own
/// dedicated device session and runs a local, windowless core worker.
Future<String> runLivePs1Race(String config) async {
  final args = (jsonDecode(await File(config).readAsString()) as List).cast<String>();
  final [role, friend, executable, core, disc, bios, trace, sessionDirectory, receiptPath, releasePath] = args;
  final receiptFile = File(receiptPath);
  final releaseFile = File(releasePath);
  if (await receiptFile.exists() || await releaseFile.exists() || p.equals(receiptPath, releasePath)) {
    throw ArgumentError('The race requires fresh receipt and release paths.');
  }
  if (role != 'host' && role != 'guest') throw ArgumentError('Expected host or guest.');
  final seat = role == 'host' ? 0 : 1;
  final system = HostSystem.current;
  final store = FileTokenStore(
    p.join(sessionDirectory, 'live-session'),
    sealer: Platform.isWindows ? DpapiSealer() : null,
  );
  final account = TogetherAccount(
    base: TogetherServer.standard,
    store: store,
    clientName: TogetherModel.clientName(system),
  );
  final socket = TogetherSocket(account: account);
  final work = await Directory.systemTemp.createTemp('anyps5-ps1-live-');
  WebRtcNativeWorker? worker;
  Ps1NetplayMatch? match;
  StreamSubscription<TogetherEvent>? events;
  try {
    await account.restore();
    final me = account.user;
    if (me == null) throw StateError('Authorize this isolated device session before running the match.');
    final friends = await account.call('GET', 'me/friends');
    final other = (friends['friends'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['handle']?.toString().toLowerCase() == friend.toLowerCase())
        .singleOrNull?['userId'];
    if (other is! String || other == me.id) {
      throw StateError('The requested peer must be a distinct AnyTogether friend.');
    }

    final profile = Ps1NetplayProfile.tryRead('SCUS94426')!;
    const mode = Ps1NetplayRoomMode.mixedRollback;
    final media = await Ps1NetplayMedia.verify(
      profile: profile,
      disc: disc,
      bios: bios,
      resolveCore: () => core,
      execution: mode.execution,
    );
    final race = await WebRtcCtrRace.load(trace, media.discDigest, analog: false);
    final finishFrame = race.frames.length - 1;
    String? placements;
    final activeWorker = worker = await WebRtcNativeWorker.spawn(
      [executable, core, disc, bios],
      File(p.join(work.path, 'unused.state')),
      seat,
      rollback: true,
      trace: await race.writeSeat(work, seat, digital: true),
      onSync: (worker, frame) async {
        if (placements == null && frame > finishFrame && await worker.confirmedFrame() >= finishFrame) {
          placements = await race.receipt().readFinish(worker);
        }
      },
    );
    final rooms = RetroOnlineRooms(
      call: account.call,
      me: me.id,
      spec: profile.roomFor(mode),
      discDigest: media.discDigest,
      coreDigest: media.coreDigest,
      signal: (to, device, id, kind, data) {
        if (!socket.send(OnlinePeerSignal.frame(to: to, device: device, sessionId: id, kind: kind, data: data))) {
          throw StateError('The hosted gateway is unavailable.');
        }
      },
    );
    final activeMatch = match = Ps1NetplayMatch(
      rooms: rooms,
      links: WebRtcGameLinks(),
      identity: media.identity,
      runner: activeWorker,
    );
    final invitation = Completer<GameInvite>();
    events = socket.events.listen((event) {
      if (seat == 1 && event.type == 'game_session.invite' && !invitation.isCompleted) {
        final invite = GameInvite.fromJson(event.json);
        if (invite.from?.id == other &&
            invite.titleId == profile.titleId &&
            invite.gameVersion == mode.version &&
            invite.engineBuild == rooms.protocol) {
          invitation.complete(invite);
        }
      }
      activeMatch.receive(event.type, event.json);
    });
    socket.start();
    await _waitFor(() => socket.status == SocketStatus.ready, const Duration(seconds: 20));
    stdout.writeln('Hosted gateway ready for $role.');
    if (seat == 0) {
      await activeMatch.host(other);
    } else {
      final invite = await invitation.future.timeout(const Duration(minutes: 2));
      await rooms.readInvite(invite.sessionId, expectedHost: other);
      await activeMatch.join(invite.sessionId, expectedHost: other);
    }
    final clock = Stopwatch()..start();
    var nextReport = 1800;
    final lastExpectedHash = (race.frames.length ~/ 120) * 120 - 1;
    while ((activeMatch.session?.confirmedFrame ?? -1) < finishFrame ||
        (activeMatch.session?.lastMatchingFingerprint ?? -1) < lastExpectedHash ||
        placements == null) {
      if (activeMatch.closed || clock.elapsed > const Duration(minutes: 7)) {
        throw StateError('The hosted race ended before the confirmed finish.');
      }
      final confirmed = activeMatch.session?.confirmedFrame ?? -1;
      if (confirmed >= nextReport) {
        stdout.writeln('Hosted $role confirmed $confirmed frames.');
        nextReport += 1800;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final fingerprints = activeWorker.fingerprints;
    for (var frame = 119; frame <= finishFrame; frame += 120) {
      if (!fingerprints.containsKey(frame)) throw StateError('Missing confirmed RAM fingerprint $frame.');
    }
    final receipt = jsonEncode({
      'role': role,
      'frames': race.frames.length,
      'placements': placements,
      'matchedThrough': lastExpectedHash,
      'fingerprints': fingerprints.map((frame, hash) => MapEntry('$frame', hash)),
      'relayed': activeMatch.connectionPath?.relayed,
    });
    if (activeMatch.closed || activeMatch.session?.ended != null) {
      throw StateError('The hosted match ended before its receipt was published.');
    }
    final partial = await File('${receiptFile.path}.part').create(exclusive: true);
    try {
      await partial.writeAsString(receipt, flush: true);
      if (await receiptFile.exists() || activeMatch.closed || activeMatch.session?.ended != null) {
        throw StateError('The hosted receipt became stale before publication.');
      }
      await partial.rename(receiptFile.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    final coordination = Stopwatch()..start();
    while (true) {
      // One peer can close after the coordinator releases it while the other
      // is still waiting for its own release file.
      final released = await releaseFile.exists();
      final end = activeMatch.session?.ended;
      if (end != null && end != Ps1NetplayEnd.left && end != Ps1NetplayEnd.peerLeft) {
        throw StateError('The hosted match ended during receipt coordination: $end.');
      }
      if (released) break;
      if (coordination.elapsed > const Duration(seconds: 20)) {
        throw StateError('The peers did not agree on both race receipts before closing.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return receipt;
  } finally {
    try {
      await match?.leave();
    } finally {
      await events?.cancel();
      socket.dispose();
      account.close();
      await worker?.stop();
      await work.delete(recursive: true);
    }
  }
}

Future<void> _waitFor(bool Function() ready, Duration timeout) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed >= timeout) throw StateError('The hosted gateway did not become ready.');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
