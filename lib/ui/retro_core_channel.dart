import 'package:flutter/services.dart';

/// Native command ownership is separate from the surface: Linux keeps a
/// texture registered while the view lives, including across game sessions.
class RetroCoreChannel {
  RetroCoreChannel._(this.texture, this._owner);

  factory RetroCoreChannel.fromStart(Object? result) {
    if (result is int && result >= 0) return RetroCoreChannel._(result, null);
    if (result is Map && result.length == 2) {
      final texture = result['texture'];
      final owner = result['session'];
      if (texture is int && texture >= 0 && owner is int && owner > 0) {
        return RetroCoreChannel._(texture, owner);
      }
    }
    throw const FormatException('The native game surface returned an invalid session handle.');
  }

  static const _channel = MethodChannel('anyps5/retro_core');
  final int texture;
  final int? _owner;

  Object? _arguments(Object? value) => _owner == null ? value : {'owner': _owner, 'value': value};

  Future<T?> invokeMethod<T>(String method, [Object? arguments]) =>
      _channel.invokeMethod<T>(method, _arguments(arguments));

  Future<List<T>?> invokeListMethod<T>(String method, [Object? arguments]) =>
      _channel.invokeListMethod<T>(method, _arguments(arguments));

  Future<Map<K, V>?> invokeMapMethod<K, V>(String method, [Object? arguments]) =>
      _channel.invokeMapMethod<K, V>(method, _arguments(arguments));
}
