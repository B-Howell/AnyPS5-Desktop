import 'package:flutter/services.dart';

import '../core/desktop/launcher_window.dart';
import '../core/retro_host/retro_hardware.dart';

/// The launcher's window through the runner's "anyps5/window" channel (windows/runner/
/// flutter_window.cpp, linux/runner/my_application.cc).
class ChannelLauncherWindow implements LauncherWindow {
  const ChannelLauncherWindow();

  static const _channel = MethodChannel('anyps5/window');

  @override
  Future<bool> setFullscreen(bool on) => _call('setFullscreen', on);

  @override
  Future<bool> minimize() => _call('minimize');

  @override
  Future<bool> restore() => _call('restore');

  @override
  Future<bool> close() => _call('close');

  @override
  Future<bool> removeAfterClose(String path) => _call('removeAfterClose', path);

  /// The graphics adapters Windows reports, without the software ones (the runner's DXGI list);
  /// none when the runner cannot list them or one entry is not as it should be.
  Future<List<RetroAdapter>> retroAdapters() async {
    try {
      return parseRetroAdapters(await _channel.invokeMethod<Object?>('retroAdapters'));
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  void listen({required void Function(bool fullscreen) fullscreenChanged}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullscreenChanged' && call.arguments is bool) fullscreenChanged(call.arguments as bool);
      return null;
    });
  }

  Future<bool> _call(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<bool>(method, argument) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// The runner's `retroAdapters` answer: a list of `{name, dedicatedBytes}`; empty when anything in
/// it is not.
List<RetroAdapter> parseRetroAdapters(Object? result) {
  if (result is! List<Object?>) return const [];
  final adapters = <RetroAdapter>[];
  for (final entry in result) {
    if (entry is! Map<Object?, Object?>) return const [];
    final name = entry['name'];
    final dedicatedBytes = entry['dedicatedBytes'];
    if (name is! String || name.isEmpty || dedicatedBytes is! int || dedicatedBytes < 0) return const [];
    adapters.add(RetroAdapter(name: name, dedicatedBytes: dedicatedBytes));
  }
  return adapters;
}
