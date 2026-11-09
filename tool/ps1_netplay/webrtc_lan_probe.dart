import 'dart:async';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/retro_lan_bridge.dart';
import 'package:anyps5_desktop/core/online/retro_lan_transport.dart';
import 'package:anyps5_desktop/ui/online_webrtc.dart';

Future<String> verifyWebRtcLanBridge() async {
  final links = WebRtcGameLinks();
  final host = await links.link([]);
  GameLink? guestLink;
  RetroLanBridge? hostBridge;
  RetroLanBridge? guestBridge;
  try {
    final guest = guestLink = await links.link([]);
    final toHost = _Candidates(guest, host);
    final toGuest = _Candidates(host, guest);
    await host.openChannel();
    final offer = await host.createOffer();
    await host.setLocal(offer);
    await guest.setRemote(offer);
    await toGuest.ready();
    final answer = await guest.createAnswer();
    await guest.setLocal(answer);
    await host.setRemote(answer);
    await toHost.ready();
    await _wait(() async => host.streamOpen && guest.streamOpen);

    const hostMac = 0x020000000001;
    const guestMac = 0x020000000002;
    const addresses = {'host': hostMac, 'guest': guestMac};
    final discovery = _frame(0xffffffffffff, hostMac);
    final reply = _frame(hostMac, guestMac);
    var hostReceived = false;
    var guestReceived = false;
    final left = hostBridge = RetroLanBridge(
      segment: RetroLanTransport(epoch: 83, me: 'host', addresses: addresses),
      links: {'guest': host},
      exchange: (input) async {
        hostReceived |= input.any((frame) => _same(frame, reply));
        return [discovery];
      },
    );
    final right = guestBridge = RetroLanBridge(
      segment: RetroLanTransport(epoch: 83, me: 'guest', addresses: addresses),
      links: {'host': guest},
      exchange: (input) async {
        guestReceived |= input.any((frame) => _same(frame, discovery));
        return guestReceived ? [reply] : [];
      },
    );
    await _wait(() async {
      await left.pump();
      await right.pump();
      return hostReceived && guestReceived;
    });
    return 'Windows WebRTC PS2 LAN bridge passed with matching broadcast and unicast Ethernet frames.';
  } finally {
    hostBridge?.close();
    guestBridge?.close();
    await Future.wait([host.close(), if (guestLink != null) guestLink.close()]);
  }
}

Future<void> _wait(Future<bool> Function() check) async {
  final timer = Stopwatch()..start();
  while (!await check()) {
    if (timer.elapsed > const Duration(seconds: 8)) throw StateError('WebRTC LAN frame exchange timed out.');
    await Future<void>.delayed(const Duration(milliseconds: 12));
  }
}

Uint8List _frame(int destination, int source) => Uint8List.fromList([
  for (final address in [destination, source])
    for (var shift = 40; shift >= 0; shift -= 8) (address >> shift) & 255,
  8,
  6,
  ...List.generate(46, (index) => index),
]);

bool _same(Uint8List actual, Uint8List expected) =>
    actual.length == expected.length && actual.indexed.every((entry) => entry.$2 == expected[entry.$1]);

final class _Candidates {
  _Candidates(GameLink source, this.target) {
    source.onCandidate = (candidate) {
      if (_ready) {
        unawaited(target.addCandidate(candidate).catchError((Object _) {}));
      } else {
        _pending.add(candidate);
      }
    };
  }

  final GameLink target;
  final _pending = <Map<String, dynamic>>[];
  bool _ready = false;

  Future<void> ready() async {
    _ready = true;
    for (final candidate in _pending) {
      await target.addCandidate(candidate).catchError((Object _) {});
    }
    _pending.clear();
  }
}
