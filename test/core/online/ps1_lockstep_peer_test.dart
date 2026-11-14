import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/ps1_lockstep_peer.dart';
import 'package:test/test.dart';

/// Two ends of a peer connection in memory: the channels open once each side has both
/// descriptions, and a candidate is gathered after each local description.
class _Link implements GameLink {
  late _Link other;
  Map<String, dynamic>? local;
  Map<String, dynamic>? remote;
  final candidates = <Map<String, dynamic>>[];
  void Function(Uint8List)? _message;
  void Function(Uint8List)? _stream;
  void Function(Map<String, dynamic>)? _candidate;
  void Function(String)? _state;
  bool closed = false;
  bool opened = false;

  @override
  Future<Map<String, dynamic>> createOffer() async => {'type': 'offer', 'sdp': 'v=0 offer'};

  @override
  Future<Map<String, dynamic>> createAnswer() async => {'type': 'answer', 'sdp': 'v=0 answer'};

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    local = description;
    _candidate?.call({'candidate': 'candidate:1 1 udp 1 192.0.2.1 9 typ host', 'sdpMid': '0', 'sdpMLineIndex': 0});
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async => remote = description;

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);

  @override
  Future<void> openChannel() async => opened = true;

  @override
  bool get streamOpen => local != null && remote != null && other.local != null && other.remote != null && !closed;

  @override
  bool send(Uint8List data) {
    if (!streamOpen) return false;
    other._message?.call(data);
    return true;
  }

  @override
  bool sendStream(Uint8List data) {
    if (!streamOpen) return false;
    other._stream?.call(data);
    return true;
  }

  @override
  set onMessage(void Function(Uint8List data) handler) => _message = handler;

  @override
  set onStreamMessage(void Function(Uint8List data) handler) => _stream = handler;

  @override
  set onCandidate(void Function(Map<String, dynamic> candidate) handler) => _candidate = handler;

  @override
  set onState(void Function(String state) handler) => _state = handler;

  void fail() => _state?.call('failed');

  @override
  Future<List<GameLinkStat>> stats() async => const [
    GameLinkStat('t', 'transport', {'selectedCandidatePairId': 'p'}),
    GameLinkStat('p', 'candidate-pair', {
      'localCandidateId': 'l',
      'remoteCandidateId': 'r',
      'currentRoundTripTime': '0.042',
    }),
    GameLinkStat('l', 'local-candidate', {'candidateType': 'relay'}),
    GameLinkStat('r', 'remote-candidate', {'candidateType': 'srflx'}),
  ];

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test('the inviting launcher offers, the friend answers, and both channels carry their messages', () async {
    final a = _Link();
    final b = _Link();
    a.other = b;
    b.other = a;
    late Ps1LockstepPeer host;
    late Ps1LockstepPeer guest;
    final sent = <(String, Map<String, Object?>)>[];
    host = Ps1LockstepPeer(
      link: a,
      offering: true,
      sendSignal: (signal) async {
        sent.add(('host', signal.toJson()));
        scheduleMicrotask(() => guest.receiveSignal(Ps1LockstepSignal.tryRead(signal.toJson())!));
      },
    );
    guest = Ps1LockstepPeer(
      link: b,
      offering: false,
      sendSignal: (signal) async {
        sent.add(('guest', signal.toJson()));
        scheduleMicrotask(() => host.receiveSignal(Ps1LockstepSignal.tryRead(signal.toJson())!));
      },
    );
    await Future.wait([host.open(), guest.open()]);
    expect(a.opened, isTrue, reason: 'the offerer opens the channels');
    expect(b.opened, isFalse);
    expect([for (final (who, json) in sent) '$who ${json['kind']}'], containsAll(['host offer', 'guest answer']));
    expect(b.candidates, hasLength(1), reason: "the host's candidate reached the friend's connection");
    expect(host.sendControl(Uint8List.fromList([1, 2])), isTrue, reason: 'before the match took the connection');
    final controls = <Uint8List>[];
    final inputs = <Uint8List>[];
    guest
      ..onControl = controls.add
      ..onInput = inputs.add;
    expect(host.sendInput(Uint8List.fromList([3])), isTrue);
    expect(controls.single, [1, 2]);
    expect(inputs.single, [3]);
    final path = await host.path();
    expect(path.route, PeerRoute.relay);
    expect(path.rttMs, 42);

    var closed = 0;
    host.onClosed = () => closed++;
    a.fail();
    expect(closed, 1, reason: 'a failed connection ends the match');
    await host.close();
    await guest.close();
    expect(host.sendControl(Uint8List(1)), isFalse);
  });

  test('a connection that never opens times out', () async {
    final a = _Link();
    final b = _Link();
    a.other = b;
    b.other = a;
    final peer = Ps1LockstepPeer(
      link: a,
      offering: true,
      sendSignal: (_) async {},
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(peer.open(), throwsA(isA<TimeoutException>()));
    await peer.close();
  });

  test('signals of another shape are not read', () {
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 1,
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': 'v=0'},
      }),
      isNotNull,
    );
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 2,
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': 'v=0'},
      }),
      isNull,
    );
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 1,
        'kind': 'offer',
        'data': {'type': 'answer', 'sdp': 'v=0'},
      }),
      isNull,
    );
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 1,
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': ''},
      }),
      isNull,
    );
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 1,
        'kind': 'candidate',
        'data': {'candidate': 'c', 'sdpMid': null, 'sdpMLineIndex': null},
      }),
      isNull,
    );
    expect(Ps1LockstepSignal.tryRead({'version': 1, 'kind': 'restart', 'data': <String, Object?>{}}), isNull);
    expect(
      Ps1LockstepSignal.tryRead({
        'version': 1,
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': 'v=0'},
        'x': 1,
      }),
      isNull,
    );
  });
}
