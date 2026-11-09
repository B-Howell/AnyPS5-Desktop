import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_peer.dart';
import 'package:anyps5_desktop/core/online/ps1_netplay_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/online_fakes.dart';

final identity = Ps1NetplayIdentity.tryRead({
  'version': 1,
  'title': 'PS1-SCUS94426',
  'disc': 'a' * 64,
  'bios': 'b' * 64,
  'core': 'c' * 64,
  'profile': 'd' * 64,
  'card': 'e' * 64,
})!;

Ps1NetplaySignal signal(String kind, Map<String, Object?> data) =>
    Ps1NetplaySignal.tryRead({'version': 1, 'kind': kind, 'data': data})!;

class _Runner implements Ps1NetplayRunner {
  int? seat;
  var started = false;
  var stopped = false;
  var sawRemote = false;

  @override
  Future<void> prepare(int seat) async => this.seat = seat;

  @override
  Future<void> start() async => started = true;

  @override
  Future<Ps1NetplayTick> sync(List<Ps1NetplayFrame> remote, int? acknowledgedFrame) async {
    if (remote.isNotEmpty) sawRemote = true;
    return (
      frame: sawRemote ? 1 : 0,
      confirmedFrame: sawRemote ? 0 : null,
      receivedFrame: sawRemote ? 0 : null,
      waiting: !sawRemote,
      fingerprints: const <int, String>{},
      local: [(frame: 0, input: (buttons: seat!, leftX: 0, leftY: 0, rightX: 0, rightY: 0))],
    );
  }

  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  test('signal codec checks version, role-specific descriptions and candidate shape', () {
    final offer = {
      'version': 1,
      'kind': 'offer',
      'data': {'type': 'offer', 'sdp': 'v=0'},
    };
    expect(Ps1NetplaySignal.tryRead(offer)?.toJson(), offer);
    expect(Ps1NetplaySignal.tryRead({...offer, 'version': 2}), isNull);
    expect(Ps1NetplaySignal.tryRead({...offer, 'version': 1.0}), isNull);
    expect(Ps1NetplaySignal.tryRead({...offer, 'kind': 'answer'}), isNull);
    expect(
      Ps1NetplaySignal.tryRead({
        ...offer,
        'data': {'type': 'offer', 'sdp': 'x' * 65537},
      }),
      isNull,
    );
    expect(Ps1NetplaySignal.tryRead({...offer, 'room': 'another room'}), isNull);
    expect(
      signal('candidate', {'candidate': 'candidate:early', 'sdpMid': null, 'sdpMLineIndex': 0}).kind,
      Ps1NetplaySignalKind.candidate,
    );
    expect(
      Ps1NetplaySignal.tryRead({
        'version': 1,
        'kind': 'candidate',
        'data': {'candidate': 'candidate:invalid', 'sdpMid': null, 'sdpMLineIndex': -1},
      }),
      isNull,
    );
  });

  test('two authenticated links negotiate, deliver PS1 frames and close both runners', () async {
    final network = FakeGameNetwork();
    final hostLink = await network.links.link([]);
    final guestLink = await network.links.link([]);
    final hostRunner = _Runner();
    final guestRunner = _Runner();
    late Ps1NetplayPeer host;
    late Ps1NetplayPeer guest;
    host = Ps1NetplayPeer(
      link: hostLink,
      identity: identity,
      runner: hostRunner,
      seat: 0,
      hostEpoch: 42,
      sendSignal: (signal) async => guest.receiveSignal(signal),
    );
    guest = Ps1NetplayPeer(
      link: guestLink,
      identity: identity,
      runner: guestRunner,
      seat: 1,
      sendSignal: (signal) async => host.receiveSignal(signal),
    );
    addTearDown(() async {
      await host.leave();
      await guest.leave();
    });

    final early = signal('candidate', {'candidate': 'candidate:early', 'sdpMid': '0', 'sdpMLineIndex': 0});
    guest.receiveSignal(early);
    guest.receiveSignal(early);
    for (var index = 0; index < 70; index++) {
      guest.receiveSignal(signal('candidate', {'candidate': 'candidate:$index', 'sdpMid': '0', 'sdpMLineIndex': 0}));
    }
    // The guest must ignore an answer or a second offer from a former attempt.
    guest.receiveSignal(signal('answer', {'type': 'answer', 'sdp': 'wrong role'}));
    await host.open();
    await guest.open();
    expect(await eventually(() => hostRunner.sawRemote && guestRunner.sawRemote), isTrue);
    expect(hostRunner.seat, 0);
    expect(guestRunner.seat, 1);
    expect(hostRunner.started, isTrue);
    expect(guestRunner.started, isTrue);
    expect(network.all[1].candidatesIn.where((item) => item['candidate'] == 'candidate:early'), hasLength(1));
    expect(network.all[1].candidatesIn, hasLength(64));
    guest.receiveSignal(signal('offer', {'type': 'offer', 'sdp': 'fake other-link'}));
    expect(network.all[1].partner, network.all[0]);
    expect(network.all.every((link) => link.streamMessages > 0), isTrue);

    await host.leave();
    await guest.done.timeout(const Duration(seconds: 2));
    expect(hostRunner.stopped && guestRunner.stopped, isTrue);
    expect(network.all.every((link) => link.closed), isTrue);
  });

  test('a missing peer closes the connection without starting the runner', () async {
    final network = FakeGameNetwork();
    final runner = _Runner();
    final peer = Ps1NetplayPeer(
      link: await network.links.link([]),
      identity: identity,
      runner: runner,
      seat: 0,
      hostEpoch: 1,
      sendSignal: (_) async {},
      timeout: const Duration(milliseconds: 30),
    );
    await peer.open();
    await peer.done.timeout(const Duration(seconds: 2));
    expect(network.all.single.closed, isTrue);
    expect(runner.seat, isNull);
    expect(peer.session.phase, Ps1NetplayPhase.closed);
  });
}
