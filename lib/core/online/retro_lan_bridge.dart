import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'retro_lan_dhcp.dart';
import 'retro_lan_transport.dart';

/// Moves frames between one embedded NIC and its room-bound game channels.
/// The match owns signaling, peer lifecycle and pump scheduling.
final class RetroLanBridge {
  RetroLanBridge({required this._segment, required this._send, required this._exchange, this._dhcp});

  // Same bounds as the Windows DEV9 exchange. Drop excess traffic as a NIC
  // would rather than growing an unbounded queue while the core is booting.
  static const _queueSize = 64;
  static const _batchSize = 16;

  final RetroLanTransport _segment;
  final RetroLanDhcp? _dhcp;
  final void Function(String recipient, Uint8List packet) _send;
  final Future<List<Uint8List>?> Function(List<Uint8List> frames) _exchange;
  final _incoming = Queue<Uint8List>();
  bool _closed = false;
  Completer<void>? _pendingExchange;

  Future<void>? get drained => _pendingExchange?.future;

  void receive(String user, Uint8List packet) {
    if (_closed || _incoming.length >= _queueSize) return;
    final frame = _segment.inbound(user, packet);
    if (frame != null && (_dhcp == null || !RetroLanDhcp.isLocalService(frame))) _incoming.addLast(frame);
  }

  Future<void> pump() async {
    if (_closed || _pendingExchange != null) return;
    final pending = _pendingExchange = Completer<void>();
    try {
      final input = _incoming.take(_batchSize).toList(growable: false);
      final output = await _exchange(input);
      if (_closed || output == null) return;
      for (var index = 0; index < input.length; index++) {
        _incoming.removeFirst();
      }
      for (final frame in output) {
        final dhcp = _dhcp;
        if (dhcp != null && RetroLanDhcp.isLocalService(frame)) {
          final reply = dhcp.reply(frame);
          if (reply != null) {
            if (_incoming.length >= _queueSize) _incoming.removeLast();
            _incoming.addFirst(reply);
          }
          continue;
        }
        final routed = _segment.outbound(frame);
        if (routed == null) continue;
        for (final recipient in routed.recipients) {
          _send(recipient, routed.packet);
        }
      }
    } finally {
      _pendingExchange = null;
      pending.complete();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _incoming.clear();
    _segment.close();
  }
}
