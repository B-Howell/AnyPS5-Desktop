import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';

import 'fake_retro_host_session.dart';

/// The `status` a real host gave for the OpenBIOS test program with SwanStation on Windows
/// (test/fixtures/retro_host), before and after PGXP geometry correction was turned on, which
/// makes SwanStation list its other PGXP options.
RetroStatus recordedStatus({bool pgxp = false}) => RetroStatus.parse(
  jsonDecode(File('test/fixtures/retro_host/swanstation_status${pgxp ? '_pgxp' : ''}.json').readAsStringSync())
      as Map<String, Object?>,
);

/// A fake host session whose options behave as the recorded host's: `option` takes a value the
/// status offers and selects it, and the PGXP options show only while geometry correction is on.
class FakeOptionSession extends FakeRetroHostSession {
  FakeOptionSession({Map<String, List<String>>? offered, this.hardware = true}) {
    _base = recordedStatus();
    _pgxp = recordedStatus(pgxp: true);
    for (final MapEntry(:key, :value) in (offered ?? const {}).entries) {
      _offered[key] = value;
    }
    for (final option in _pgxp.options.values) {
      _chosen[option.key] = option.values[option.selected];
    }
    _chosen['swanstation_GPU_PGXPEnable'] = 'false';
    callResults['pause'] = null;
  }

  late final RetroStatus _base;
  late final RetroStatus _pgxp;
  final _offered = <String, List<String>>{};
  final _chosen = <String, String>{};

  /// Whether the status says the game draws with the OpenGL renderer.
  bool hardware;

  /// Values the host refuses, by key.
  final refused = <String, Set<String>>{};

  /// Every `option` the launcher sent, in order.
  final options = <(String, String)>[];

  String chosen(String key) => _chosen[key]!;

  RetroStatus get current {
    final source = _chosen['swanstation_GPU_PGXPEnable'] == 'true' ? _pgxp : _base;
    return RetroStatus(
      ready: true,
      ended: false,
      error: '',
      errorCode: '',
      hardware: hardware,
      options: {for (final option in source.options.values) option.key: _shaped(option)},
    );
  }

  RetroOption _shaped(RetroOption option) {
    final values = _offered[option.key] ?? option.values;
    final labels = [for (final value in values) option.labels[option.values.indexOf(value)]];
    final value = _chosen[option.key]!;
    return RetroOption(
      key: option.key,
      title: option.title,
      values: values,
      labels: labels,
      selected: values.indexOf(value),
      activeValue: value,
      restart: option.restart,
    );
  }

  @override
  Future<Object?> call(String method, [Object? args]) async {
    if (method != 'option') return super.call(method, args);
    calls.add((method, args));
    await callGate?.future;
    final request = args! as Map<String, Object?>;
    final key = request['key']! as String;
    final value = request['value']! as String;
    final option = current.options[key];
    if (option == null || !option.values.contains(value) || (refused[key]?.contains(value) ?? false)) return false;
    options.add((key, value));
    _chosen[key] = value;
    return true;
  }

  @override
  Future<RetroStatus?> status() async => current;
}
