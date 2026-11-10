import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/online/retro_lan_match.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'webrtc_room_fixture.dart';

const _native = MethodChannel('anyps5/retro_core');
const _report = MethodChannel('anyps5/ps1_webrtc_probe');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _report.invokeMethod<void>('pass', jsonEncode(await verifyNativeReset()));
  } on Object catch (error, stack) {
    await _report.invokeMethod<void>('fail', '$error\n$stack');
  }
}

Future<String> _digest(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

Future<void> _until(Future<bool> Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!await ready()) {
    if (elapsed.elapsed > const Duration(seconds: 20)) throw TimeoutException('Native reset probe did not advance.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// One native game and a synthetic peer. This proves native queue reset and
/// continued presentation, not a two-console LAN match or a native game join.
Future<Map<String, Object?>> verifyNativeReset() async {
  final configPath = Platform.environment['ANYPS5_PS2_NATIVE_RESET'];
  if (configPath == null) throw const FormatException('Expected ANYPS5_PS2_NATIVE_RESET fixture JSON.');
  final config = jsonDecode(await File(configPath).readAsString()) as Map<String, dynamic>;
  String field(String key) {
    final value = config[key];
    if (value is! String || value.isEmpty) throw FormatException('Missing fixture $key.');
    return value;
  }

  final core = field('core'), disc = field('disc'), bios = field('bios'), card = field('card');
  final hashes = <String, String>{};
  for (final entry in {'core': core, 'disc': disc, 'bios': bios, 'card': card}.entries) {
    final hash = hashes[entry.key] = await _digest(entry.value);
    if (hash != field('${entry.key}Sha256')) throw StateError('Fixture ${entry.key} digest changed.');
  }
  final identity = GameLibrary.ps2DiscIdentity(disc);
  if (identity == null) throw StateError('The fixture needs a recognized PS2 disc.');
  final work = Directory(field('work'));
  if (!p.isAbsolute(work.path) || await work.exists()) throw StateError('Use a fresh absolute scratch directory.');
  final system = p.join(work.path, 'system');
  final saves = p.join(work.path, 'saves');
  await Directory(p.join(system, 'pcsx2', 'bios')).create(recursive: true);
  await Directory(p.join(system, 'pcsx2', 'memcards')).create();
  await Directory(saves).create();
  await File(bios).copy(p.join(system, 'pcsx2', 'bios', 'fixture.bin'));
  await File(card).copy(p.join(system, 'pcsx2', 'memcards', 'Mcd001.ps2'));

  final links = WebRtcProbeLinks();
  final gateway = WebRtcRoomFixture((
    titleId: identity.serial,
    gameVersion: identity.revision,
    mode: RetroOnlineMode.lan,
    capacity: 2,
  ), hashes['disc']!);
  final stopped = Completer<void>();
  final peerStopped = Completer<void>();
  int? texture;
  var resets = 0;
  var recovering = false;
  Future<int> published() async => await _report.invokeMethod<int>('published') ?? 0;
  Future<Map<Object?, Object?>> status() async => await _native.invokeMapMethod('status') ?? {};
  final host = RetroLanMatch(
    rooms: gateway.client(WebRtcRoomFixture.host, expectedDigest: hashes['disc']),
    links: links,
    ownsGame: false,
    onRecoveryChanged: (value) => recovering = value,
    resetPeerFrames: () async {
      final reset = await _native.invokeMethod<bool>('ps2LanReset', texture) == true;
      if (reset) resets++;
      return reset;
    },
    launch: (mac) async {
      texture = await _native.invokeMethod<int>('start', {
        'core': core,
        'disc': disc,
        'system': system,
        'saves': saves,
        'ps2LanMac': mac,
        'graphics': {'pcsx2_renderer': 'D3D11'},
      });
      if (texture == null) throw StateError('The native game did not start.');
      return (
        exchange: (List<Uint8List> input) =>
            _native.invokeListMethod<Uint8List>('ps2LanExchange', {'texture': texture, 'frames': input}),
        close: () async {},
        done: stopped.future,
      );
    },
  );
  final guest = RetroLanMatch(
    rooms: gateway.client(WebRtcRoomFixture.guest, expectedDigest: hashes['disc']),
    links: links,
    launch: (_) async => (
      exchange: (_) async => <Uint8List>[],
      close: () async {
        if (!peerStopped.isCompleted) peerStopped.complete();
      },
      done: peerStopped.future,
    ),
  );
  gateway.events[WebRtcRoomFixture.host] = host.receive;
  gateway.events[WebRtcRoomFixture.guest] = guest.receive;
  try {
    final opening = host.host(WebRtcRoomFixture.guest);
    await Future.any([gateway.invited, opening.then((_) => throw StateError('Host closed before invite.'))]);
    await Future.wait([opening, guest.join(WebRtcRoomFixture.roomId)]);
    await _until(() async => (await status())['presented'] == true);
    final before = await published();
    final beforeResets = resets;
    links.opened.first.reportState('disconnected');
    await _until(() async => recovering && resets > beforeResets);
    final interrupted = resets;
    links.opened.first.reportState('connected');
    await _until(() async => !recovering && resets > interrupted && await published() >= before + 20);
    if (host.closed || guest.closed || (await status())['ended'] == true) throw StateError('Game or room closed.');
    final after = await published();
    await host.leave(keepGame: true);
    await guest.done;
    await _until(() async => await published() >= after + 10);
    if (!gateway.released || (await status())['ended'] == true) throw StateError('Game did not survive room exit.');
    if (await _digest(card) != hashes['card']) throw StateError('The original card seed changed.');
    return {
      'nativeTexture': texture,
      'nativeResets': resets,
      'framesBefore': before,
      'framesAfter': after,
      'framesAfterLeave': await published(),
      'roomReleased': gateway.released,
      'fixtureSha256': hashes,
    };
  } finally {
    await Future.wait([host.leave(keepGame: true), guest.leave()]);
    if (texture != null) await _native.invokeMethod<void>('stop');
    if (!stopped.isCompleted) stopped.complete();
    if (!peerStopped.isCompleted) peerStopped.complete();
    await _until(() async => (await status())['ended'] == true);
  }
}
