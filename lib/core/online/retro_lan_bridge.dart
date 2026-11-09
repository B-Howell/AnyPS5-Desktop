import 'dart:collection';
import 'dart:typed_data';

import 'online_peer_mesh.dart';
import 'retro_lan_transport.dart';

/// Moves frames between one embedded NIC and its room-bound game channels.
/// The match owns signaling, peer lifecycle and pump scheduling.
final class RetroLanBridge {
  RetroLanBridge({required this._segment, required Map<String, GameLink> links, required this._exchange})
    : _links = Map.unmodifiable(links) {
    if (_links.length != _segment.addresses.length - 1 ||
        _links.keys.any((user) => user == _segment.me || !_segment.addresses.containsKey(user)) ||
        _links.values.toSet().length != _links.length) {
      throw ArgumentError('The virtual LAN needs one game channel per remote member.');
    }
    for (final entry in _links.entries) {
      entry.value.onMessage = (packet) => _receive(entry.key, packet);
    }
  }

  // Same bounds as the Windows DEV9 exchange. Drop excess traffic as a NIC
  // would rather than growing an unbounded queue while the core is booting.
  static const _queueSize = 64;
  static const _batchSize = 16;

  final RetroLanTransport _segment;
  final Map<String, GameLink> _links;
  final Future<List<Uint8List>?> Function(List<Uint8List> frames) _exchange;
  final _incoming = Queue<Uint8List>();
  bool _closed = false;
  bool _pumping = false;

  void _receive(String user, Uint8List packet) {
    if (_closed || _incoming.length >= _queueSize) return;
    final frame = _segment.inbound(user, packet);
    if (frame != null) _incoming.addLast(frame);
  }

  Future<void> pump() async {
    if (_closed || _pumping) return;
    _pumping = true;
    try {
      final input = _incoming.take(_batchSize).toList(growable: false);
      final output = await _exchange(input);
      if (_closed || output == null) return;
      for (var index = 0; index < input.length; index++) {
        _incoming.removeFirst();
      }
      for (final frame in output) {
        final routed = _segment.outbound(frame);
        if (routed == null) continue;
        for (final recipient in routed.recipients) {
          _links[recipient]!.send(routed.packet);
        }
      }
    } finally {
      _pumping = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _incoming.clear();
    _segment.close();
    for (final link in _links.values) {
      link.onMessage = (_) {};
    }
  }
}
