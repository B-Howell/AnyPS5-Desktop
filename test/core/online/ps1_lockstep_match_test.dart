import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_lockstep_control.dart';
import 'package:anyps5_desktop/core/online/ps1_lockstep_match.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'lockstep_test_support.dart';

const _identity = Ps1LockstepIdentity(
  hostVersion: '1.0.0',
  system: 'linux',
  core: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  disc: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  bios: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
);

/// The same, with a host that can roll back.
const _rollbackIdentity = Ps1LockstepIdentity(
  hostVersion: '1.0.0',
  system: 'linux',
  core: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  disc: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  bios: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  rollback: true,
);

/// A player's controller: a different input every time it is read, so every frame's input is
/// seen to reach both hosts in the same place.
RetroPadInput Function() _pad(int seed) {
  final random = Random(seed);
  return () => RetroPadInput(buttons: random.nextInt(0x10000), leftX: random.nextInt(65536) - 32768);
}

class _Pair {
  _Pair({
    Duration latency = const Duration(milliseconds: 20),
    Duration jitter = Duration.zero,
    double loss = 0,
    Ps1LockstepIdentity hostIdentity = _identity,
    Ps1LockstepIdentity guestIdentity = _identity,
    int guestSalt = 0,
    bool hostRolls = true,
    bool guestRolls = true,
    Future<LockstepHost?> Function(Ps1LockstepHello hello)? prepare,
  }) : work = Directory.systemTemp.createTempSync('lockstep-match-') {
    final (a, b) = TestLink.pair(latency, jitter: jitter, loss: loss);
    hostLink = a;
    guestLink = b;
    hostGame = LockstepHost(ram: 1234, canRollback: hostRolls)..next = null;
    guestGame = LockstepHost(salt: guestSalt, canRollback: guestRolls);
    hostMatch = Ps1LockstepMatch(
      hosting: true,
      link: a,
      identity: hostIdentity,
      work: Directory(p.join(work.path, 'host')),
      localInput: _pad(1),
      paused: () => hostPaused,
      host: hostGame,
      options: const {'swanstation_GPU_ResolutionScale': '4'},
    );
    guestMatch = Ps1LockstepMatch(
      hosting: false,
      link: b,
      identity: guestIdentity,
      work: Directory(p.join(work.path, 'guest')),
      localInput: _pad(2),
      paused: () => false,
      prepareGuest: (hello) async {
        guestOptions = hello.options;
        return prepare == null ? guestGame : await prepare(hello);
      },
    );
  }

  final Directory work;
  late final TestLink hostLink;
  late final TestLink guestLink;
  late final LockstepHost hostGame;
  late final LockstepHost guestGame;
  late final Ps1LockstepMatch hostMatch;
  late final Ps1LockstepMatch guestMatch;
  Map<String, String>? guestOptions;
  bool hostPaused = false;

  void run() {
    unawaited(hostMatch.run());
    unawaited(guestMatch.run());
  }

  Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(limit);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> close() async {
    await hostMatch.leave();
    await guestMatch.done;
    await hostGame.close();
    await guestGame.close();
    if (work.existsSync()) work.deleteSync(recursive: true);
  }
}

void main() {
  test('two launchers join a running game and step the same input frame for frame', () async {
    final pair = _Pair(latency: const Duration(milliseconds: 20), jitter: const Duration(milliseconds: 10), loss: 0.15);
    pair.hostGame.next = null;
    pair.run();
    await pair.until(() => pair.hostGame.steps.length >= 400 && pair.guestGame.steps.length >= 400);

    expect(pair.guestOptions, {
      'swanstation_GPU_ResolutionScale': '4',
    }, reason: "the friend boots with the host's options");
    expect(pair.hostMatch.delay, inInclusiveRange(2, 4));
    expect(pair.guestMatch.delay, pair.hostMatch.delay);
    final count = min(pair.hostGame.steps.length, pair.guestGame.steps.length);
    for (var index = 0; index < count; index++) {
      final ours = pair.hostGame.steps[index];
      final theirs = pair.guestGame.steps[index];
      expect(theirs.frame, ours.frame);
      expect(theirs.ports, ours.ports, reason: 'frame ${ours.frame}');
      expect(ours.ports, hasLength(2));
    }
    final delay = pair.hostMatch.delay!;
    expect(
      pair.hostGame.steps.take(delay).every((step) => step.ports.every((port) => port == RetroPadInput.idle)),
      isTrue,
    );
    expect(pair.hostGame.steps[delay].ports[0], isNot(RetroPadInput.idle), reason: "port 1 is the host player's");
    expect(pair.hostGame.steps[delay].ports[1], isNot(RetroPadInput.idle), reason: "port 2 is the friend's");
    expect(pair.hostMatch.lastMatched, greaterThanOrEqualTo(240), reason: 'RAM compared every 60 frames');
    expect(pair.guestMatch.lastMatched, greaterThanOrEqualTo(240));
    expect(pair.hostMatch.phase, Ps1LockstepPhase.playing);

    await pair.hostMatch.leave();
    await pair.guestMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.left);
    expect(pair.guestMatch.end, Ps1LockstepEnd.peerLeft);
    expect(pair.hostGame.leaves, 1, reason: "the host player's game goes on alone");
    expect(pair.guestGame.leaves, 1);
    expect(Directory(p.join(pair.work.path, 'host')).existsSync(), isFalse);
    expect(Directory(p.join(pair.work.path, 'guest')).existsSync(), isFalse);
    await pair.close();
  });

  test(
    'two launchers whose hosts can roll back predict the late input, correct it, and confirm the same frames',
    () async {
      final pair = _Pair(
        latency: const Duration(milliseconds: 50),
        jitter: const Duration(milliseconds: 20),
        loss: 0.1,
        hostIdentity: _rollbackIdentity,
        guestIdentity: _rollbackIdentity,
      );
      pair.run();
      await pair.until(
        () => (pair.hostMatch.lastMatched ?? 0) >= 300 && (pair.guestMatch.lastMatched ?? 0) >= 300,
        limit: const Duration(seconds: 30),
      );

      expect(pair.hostMatch.lockstepOnly, isFalse);
      expect(pair.hostMatch.delay, Ps1LockstepMatch.rollbackDelay, reason: 'rollback lowers the delay to 2 frames');
      expect(pair.hostMatch.window, inInclusiveRange(3, 8));
      expect(pair.guestMatch.delay, pair.hostMatch.delay);
      expect(pair.guestMatch.window, pair.hostMatch.window);
      expect(pair.hostGame.window, pair.hostMatch.window, reason: 'the host plays in rollback with the window');
      expect(pair.guestGame.window, pair.hostMatch.window);
      for (final game in [pair.hostGame, pair.guestGame]) {
        expect(game.steps.where((step) => step.ports.contains(null)), isNotEmpty, reason: 'late input is predicted');
        expect(game.corrections, isNotEmpty, reason: 'and corrected when it comes');
        expect(game.reports, isNotEmpty, reason: 'a wrong guess is run again');
        expect(game.steps.every((step) => step.ports.length == 2), isTrue);
      }
      expect(
        pair.hostGame.steps.every((step) => step.ports[0] != null),
        isTrue,
        reason: "the host player's own port is always known",
      );
      expect(pair.guestGame.steps.every((step) => step.ports[1] != null), isTrue);
      final host = _played(pair.hostGame);
      final guest = _played(pair.guestGame);
      final frames =
          host.keys
              .where(
                (frame) => guest.containsKey(frame) && !host[frame]!.contains(null) && !guest[frame]!.contains(null),
              )
              .toList()
            ..sort();
      expect(frames.length, greaterThanOrEqualTo(300));
      for (final frame in frames) {
        expect(guest[frame], host[frame], reason: 'both hosts end with the same input in frame $frame');
      }
      final health = pair.hostMatch.rollbackHealth!;
      expect(health.window, pair.hostMatch.window);
      expect(health.rollbacks, greaterThan(0));
      expect(health.millisEach, 2, reason: 'the test host reports 2 ms a rollback');
      expect(health.slow, isFalse);
      expect(pair.hostMatch.end, isNull);
      await pair.close();
    },
  );

  test('a host that cannot roll back makes the match play in plain lockstep', () async {
    for (final (hostRolls, guestRolls) in [(false, true), (true, false)]) {
      final pair = _Pair(
        hostIdentity: hostRolls ? _rollbackIdentity : _identity,
        guestIdentity: guestRolls ? _rollbackIdentity : _identity,
        hostRolls: hostRolls,
        guestRolls: guestRolls,
      );
      pair.run();
      await pair.until(() => (pair.hostMatch.lastMatched ?? 0) >= 120 && (pair.guestMatch.lastMatched ?? 0) >= 120);
      expect(pair.hostMatch.lockstepOnly, isTrue);
      expect(pair.guestMatch.lockstepOnly, isTrue);
      expect(pair.hostMatch.window, isNull);
      expect(pair.guestMatch.window, isNull);
      expect(pair.hostMatch.rollbackHealth, isNull);
      expect(pair.hostGame.window, isNull);
      expect(pair.guestGame.window, isNull);
      expect(pair.hostGame.steps.any((step) => step.ports.contains(null)), isFalse);
      expect(pair.guestGame.corrections, isEmpty);
      await pair.close();
    }
  });

  test('a launcher that starts ahead waits, as GGPO time sync does, until both are level', () async {
    final pair = _Pair(
      latency: const Duration(milliseconds: 60),
      hostIdentity: _rollbackIdentity,
      guestIdentity: _rollbackIdentity,
    );
    pair.run();
    await pair.until(
      () => (pair.guestMatch.rollbackHealth?.waited ?? 0) > 0 && (pair.hostMatch.lastMatched ?? 0) >= 240,
      limit: const Duration(seconds: 30),
    );
    expect(
      pair.hostMatch.rollbackHealth!.waited,
      lessThan(pair.guestMatch.rollbackHealth!.waited),
      reason: 'the friend starts a half round trip before the host player, so it is the one ahead',
    );
    await pair.close();
  });

  test("a friend whose disc is not the host player's is told so, and nothing is held", () async {
    final pair = _Pair(
      guestIdentity: const Ps1LockstepIdentity(
        hostVersion: '1.0.0',
        system: 'linux',
        core: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        disc: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        bios: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      ),
    );
    pair.run();
    await pair.hostMatch.done;
    await pair.guestMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.mismatch);
    expect(pair.hostMatch.mismatch, Ps1LockstepMismatch.disc);
    expect(pair.guestMatch.mismatch, Ps1LockstepMismatch.disc);
    expect(pair.hostGame.next, isNull, reason: "the host player's game never entered lockstep");
    await pair.close();
  });

  test('a round trip above the most delay is refused before the game is held', () async {
    final pair = _Pair(latency: const Duration(milliseconds: 160));
    pair.run();
    await pair.hostMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.tooSlow);
    expect(pair.hostGame.steps, isEmpty);
    await pair.guestMatch.done;
    expect(pair.guestMatch.end, Ps1LockstepEnd.disconnected);
    await pair.close();
  });

  test('games whose RAM stops matching end the match on both sides', () async {
    final pair = _Pair(guestSalt: 1);
    pair.run();
    await pair.hostMatch.done;
    await pair.guestMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.desync);
    expect(pair.guestMatch.end, Ps1LockstepEnd.desync);
    await pair.close();
  });

  test('a paused player holds both games, and the other is told', () async {
    final pair = _Pair();
    pair.run();
    await pair.until(() => pair.guestGame.steps.length > 100);
    pair.hostPaused = true;
    pair.hostGame.paused = true;
    await pair.until(() => pair.guestMatch.peerPaused);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final held = pair.guestGame.steps.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pair.guestGame.steps.length, held, reason: 'no input comes from a paused game');
    pair.hostPaused = false;
    pair.hostGame
      ..paused = false
      ..run();
    await pair.until(() => !pair.guestMatch.peerPaused && pair.guestGame.steps.length > held + 60);
    await pair.close();
  });

  test('a broken connection ends the match', () async {
    final pair = _Pair();
    pair.run();
    await pair.until(() => pair.guestGame.steps.length > 30);
    pair.guestLink.drop();
    await pair.hostMatch.done;
    await pair.guestMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.disconnected);
    expect(pair.guestMatch.end, Ps1LockstepEnd.disconnected);
    expect(pair.hostGame.leaves, 1);
    await pair.close();
  });

  test('in rollback the delay is 2 frames and the window covers the rest of the round trip, as GGPO plays', () {
    Ps1LockstepTiming? rollback(int milliseconds) =>
        Ps1LockstepMatch.timingFor(Duration(milliseconds: milliseconds), rollback: true);
    expect(rollback(0), (delay: 1, window: 2));
    expect(rollback(20), (delay: 2, window: 2));
    expect(rollback(100), (delay: 2, window: 4));
    expect(rollback(200), (delay: 2, window: 7));
    expect(rollback(220), (delay: 2, window: 8));
    expect(rollback(250), (delay: 3, window: 8), reason: 'past a full window the delay rises instead');
    expect(Ps1LockstepMatch.timingFor(const Duration(milliseconds: 250), rollback: false), isNull);
    expect(rollback(430), (delay: 8, window: 8));
    expect(rollback(470), isNull);
    expect(Ps1LockstepMatch.timingFor(const Duration(milliseconds: 100), rollback: false), (delay: 4, window: null));
  });

  test('input delay follows the round trip, as netplay.md gives it', () {
    expect(Ps1LockstepMatch.delayFor(Duration.zero), 1);
    expect(Ps1LockstepMatch.delayFor(const Duration(milliseconds: 30)), 2);
    expect(Ps1LockstepMatch.delayFor(const Duration(milliseconds: 100)), 4);
    expect(Ps1LockstepMatch.delayFor(const Duration(milliseconds: 233)), 8);
    expect(Ps1LockstepMatch.delayFor(const Duration(milliseconds: 270)), isNull);
  });

  test('a control message of another shape is refused', () {
    Uint8List bytes(Object value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));
    expect(Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'pause', 'paused': true})), isA<Ps1LockstepPause>());
    expect(
      () => Ps1LockstepMessage.decode(bytes({'v': 1, 'type': 'leave'})),
      throwsFormatException,
      reason: 'version 1 named the disc by its file name',
    );
    expect(
      () => Ps1LockstepMessage.decode(bytes({'v': 2, 'type': 'leave'})),
      throwsFormatException,
      reason: 'version 2 had no rollback',
    );
    expect(() => Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'leave', 'extra': 1})), throwsFormatException);
    expect(
      () => Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'hash', 'frame': 0, 'ram': 'ABC'})),
      throwsFormatException,
    );
    expect(() => Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'what'})), throwsFormatException);
    expect(
      (Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'advantage', 'frames': -4})) as Ps1LockstepAdvantage).frames,
      -4,
    );
    expect(() => Ps1LockstepMessage.decode(bytes({'v': 3, 'type': 'advantage', 'frames': 601})), throwsFormatException);
    final hello = _identity.hello(const {'swanstation_GPU_ResolutionScale': '4'});
    expect(jsonDecode(utf8.decode(hello.encode())), isNot(contains('discName')));
    expect((Ps1LockstepMessage.decode(hello.encode()) as Ps1LockstepHello).disc, _identity.disc);
    expect((Ps1LockstepMessage.decode(hello.encode()) as Ps1LockstepHello).rollback, isFalse);
    expect(
      (Ps1LockstepMessage.decode(_rollbackIdentity.hello(const {}).encode()) as Ps1LockstepHello).rollback,
      isTrue,
    );
    final start = Ps1LockstepStart(
      frame: 600,
      delay: 3,
      epoch: -0x7766554433221100,
      bytes: 11534384,
      sha256: 'e' * 64,
      chunks: 20,
      window: 4,
    );
    final read = Ps1LockstepMessage.decode(start.encode()) as Ps1LockstepStart;
    expect(read.epoch, start.epoch);
    expect(read.bytes, 11534384);
    expect(read.window, 4);
    final body = jsonDecode(utf8.decode(start.encode())) as Map<String, Object?>;
    expect(() => Ps1LockstepMessage.decode(bytes({...body, 'window': 9})), throwsFormatException);
    final chunk = Ps1LockstepChunk(3, Uint8List.fromList(List.filled(Ps1LockstepChunk.maxBytes, 7)));
    expect(chunk.encode().length, lessThan(Ps1LockstepMessage.maxBytes));
    expect((Ps1LockstepMessage.decode(chunk.encode()) as Ps1LockstepChunk).data, chunk.data);
  });

  test('cores are compared on the same system only, since builds for two systems are different files', () {
    Ps1LockstepHello theirs(String system, String core) => Ps1LockstepIdentity(
      hostVersion: '1.0.0',
      system: system,
      core: core,
      disc: _identity.disc,
      bios: _identity.bios,
    ).hello(const {});
    expect(_identity.against(theirs('linux', _identity.core)), isNull);
    expect(_identity.against(theirs('linux', 'd' * 64)), Ps1LockstepMismatch.core);
    expect(_identity.against(theirs('windows', 'd' * 64)), isNull);
  });

  test('the state is inflated only up to the size announced', () {
    final state = Uint8List.fromList(List.filled(100000, 3));
    final packed = Uint8List.fromList(gzip.encode(state));
    expect(Ps1LockstepMatch.inflate(packed, state.length), state);
    expect(Ps1LockstepMatch.inflate(packed, state.length - 1), isNull, reason: 'more than announced');
    expect(Ps1LockstepMatch.inflate(packed, state.length + 1), isNull, reason: 'less than announced');
    expect(Ps1LockstepMatch.inflate(Uint8List.fromList([1, 2, 3]), 3), isNull, reason: 'not gzip');
  });

  test("a host player's state that names a path is never sent", () async {
    final pair = _Pair();
    pair.hostGame.netplaySafe = false;
    pair.run();
    await pair.hostMatch.done;
    await pair.guestMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.hostOld);
    expect(pair.hostLink.controlBytes, lessThan(4096), reason: 'no chunk of the state went out');
    expect(pair.guestGame.loads, 0, reason: 'the friend loaded nothing');
    expect(pair.hostGame.leaves, 1, reason: "the host player's game goes on alone");
    await pair.close();
  });

  test('a state that names a path is not loaded by the friend', () async {
    final pair = _Pair();
    Uint8List encode(Map<String, Object?> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));
    pair.hostLink.rewrite = (message) {
      final json = jsonDecode(utf8.decode(message)) as Map<String, Object?>;
      final unsafe = stateFile(0, utf8.encode('{"frame":0,"ram":0}'), pathless: false);
      return switch (json['type']) {
        'start' => encode({...json, 'bytes': unsafe.length, 'sha256': sha256.convert(unsafe).toString(), 'chunks': 1}),
        'chunk' when json['index'] == 0 => encode({...json, 'data': base64.encode(gzip.encode(unsafe))}),
        'chunk' => null,
        _ => message,
      };
    };
    pair.run();
    await pair.guestMatch.done;
    expect(pair.guestMatch.end, Ps1LockstepEnd.protocol);
    expect(pair.guestGame.loads, 0, reason: 'the friend loaded nothing');
    await pair.close();
  });

  test('a friend whose game is still starting when the match ends is let go', () async {
    final started = Completer<LockstepHost?>();
    final pair = _Pair(prepare: (_) => started.future);
    pair.run();
    await pair.until(() => pair.guestMatch.phase == Ps1LockstepPhase.preparing);
    await pair.until(() => pair.hostMatch.phase == Ps1LockstepPhase.transferring);
    pair.hostLink.drop();
    await pair.guestMatch.done;
    started.complete(pair.guestGame);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pair.guestMatch.end, Ps1LockstepEnd.disconnected);
    expect(pair.guestGame.steps, isEmpty, reason: 'nothing is sent to a game that came too late');
    expect(pair.guestGame.next, isNull, reason: 'it never entered lockstep');
    await pair.close();
  });

  test('a launcher that keeps its RAM hashes back while it plays on is not followed', () async {
    final pair = _Pair();
    pair.guestLink.withhold = (message) => utf8.decode(message).contains('"type":"hash"');
    pair.run();
    await pair.hostMatch.done;
    expect(pair.hostMatch.end, Ps1LockstepEnd.protocol);
    expect(pair.hostGame.steps.length, lessThan(60 * 10), reason: 'a few comparisons wait, no more');
    await pair.close();
  });
}

/// Each frame's input as a host [game] has it in the end: its step, with the ports it left unknown
/// filled in by their corrections.
Map<int, List<RetroPadInput?>> _played(LockstepHost game) {
  final played = {for (final step in game.steps) step.frame: List.of(step.ports)};
  for (final correct in game.corrections) {
    played[correct.frame]![correct.port] = correct.input;
  }
  return played;
}
