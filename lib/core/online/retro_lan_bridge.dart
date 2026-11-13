import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'retro_lan_dhcp.dart';
import 'retro_lan_transport.dart';

/// Moves frames between one embedded NIC and its room-bound game channels.
/// The match owns signaling, peer lifecycle and pump scheduling.
final class RetroLanBridge {
  RetroLanBridge({
    required RetroLanTransport this._segment,
    required void Function(String recipient, Uint8List packet) this._send,
    required this._exchange,
    required Object? Function() this._peerRoute,
    this._resetPeerFrames,
    this.resetRetryWindow = const Duration(seconds: 8),
    this._dhcp,
  });

  /// Runs the guest's local network setup without a room or peer transport.
  RetroLanBridge.local({required this._exchange, required RetroLanDhcp this._dhcp})
    : _segment = null,
      _send = null,
      _peerRoute = null,
      _resetPeerFrames = null,
      resetRetryWindow = Duration.zero;

  // Same bounds as the Windows DEV9 exchange. Drop excess traffic as a NIC
  // would rather than growing an unbounded queue while the core is booting.
  static const _queueSize = 64;
  static const _batchSize = 16;

  final RetroLanTransport? _segment;
  final RetroLanDhcp? _dhcp;
  final void Function(String recipient, Uint8List packet)? _send;
  final Future<List<Uint8List>?> Function(List<Uint8List> frames) _exchange;
  final Object? Function()? _peerRoute;
  final Future<bool> Function()? _resetPeerFrames;
  final Duration resetRetryWindow;
  final _incoming = Queue<Uint8List>();
  Object? _activePeerRoute;
  int _peerRevision = 0;
  bool _peerRouteObserved = false;
  bool _peerResetPending = false;
  Stopwatch? _resetWait;
  bool _closed = false;
  Completer<void>? _pendingExchange;

  Future<void>? get drained => _pendingExchange?.future;

  void receive(String user, Uint8List packet) {
    if (_closed || _refreshPeerRoute() == null || _incoming.length >= _queueSize) return;
    final frame = _segment?.inbound(user, packet);
    if (frame != null && (_dhcp == null || !RetroLanDhcp.isLocalService(frame))) _incoming.addLast(frame);
  }

  Future<void> pump() async {
    if (_closed || _pendingExchange != null) return;
    final pending = _pendingExchange = Completer<void>();
    try {
      _refreshPeerRoute();
      if (_peerResetPending) {
        final revision = _peerRevision;
        final reset = _resetPeerFrames;
        if (reset != null) {
          final waiting = _resetWait ??= Stopwatch()..start();
          if (!await reset()) {
            if (waiting.elapsed >= resetRetryWindow) {
              throw TimeoutException('The PS2 native network queues did not become ready.', resetRetryWindow);
            }
            return;
          }
        }
        if (_closed) return;
        _refreshPeerRoute();
        if (revision != _peerRevision) return;
        _peerResetPending = false;
        _resetWait = null;
      }
      final route = _refreshPeerRoute();
      final revision = _peerRevision;
      final input = _incoming.take(_batchSize).toList(growable: false);
      final output = await _exchange(input);
      if (_closed || output == null) return;
      _refreshPeerRoute();
      final sameRoute = revision == _peerRevision;
      for (final frame in input) {
        if (sameRoute) {
          _incoming.removeFirst();
        } else {
          // Some original inputs may have been dropped while the worker was
          // busy. Retire delivered local replies without touching new frames.
          _incoming.remove(frame);
        }
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
        if (!sameRoute || route == null) continue;
        final routed = _segment?.outbound(frame);
        if (routed == null) continue;
        for (final recipient in routed.recipients) {
          _send?.call(recipient, routed.packet);
        }
      }
    } finally {
      _pendingExchange = null;
      pending.complete();
    }
  }

  Object? _refreshPeerRoute() {
    final route = _peerRoute?.call();
    if (route != _activePeerRoute) {
      if (_peerRouteObserved) _peerResetPending = true;
      _activePeerRoute = route;
      _peerRevision++;
      // DHCP replies belong to the local NIC, regardless of the peer route.
      _incoming.removeWhere((frame) => _dhcp == null || !RetroLanDhcp.isLocalService(frame));
    }
    _peerRouteObserved = true;
    return route;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _incoming.clear();
    _segment?.close();
  }
}
