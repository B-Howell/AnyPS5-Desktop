import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../ps1_disc_serial.dart';
import 'ps1_netplay_identity.dart';
import 'retro_online_rooms.dart';

enum Ps1NetplayMediaProblem { disc, bios, core }

enum Ps1NetplayExecution {
  standard('CachedInterpreter'),
  ordinaryHandoff('Recompiler');

  const Ps1NetplayExecution(this.cpu);
  final String cpu;

  String get digest => sha256
      .convert(utf8.encode('Software;1x;$cpu;block-linking=0;gpu-thread=0;fast-boot=0;two-digital-pads;delay=2'))
      .toString();

  Set<String> get coreDigests => switch (this) {
    standard => const {Ps1NetplayMedia.corePin, Ps1NetplayMedia.portableCorePin},
    ordinaryHandoff => const {Ps1NetplayMedia.ordinaryHandoffCorePin},
  };
}

enum Ps1NetplayRoomMode {
  fresh('1'),
  staged('2'),
  ordinary('3');

  const Ps1NetplayRoomMode(this.version);
  final String version;

  static Ps1NetplayRoomMode? tryRead(String version) => values.where((mode) => mode.version == version).singleOrNull;

  bool get needsCheckpoint => this != fresh;
  Ps1NetplayExecution get execution =>
      this == ordinary ? Ps1NetplayExecution.ordinaryHandoff : Ps1NetplayExecution.standard;
}

/// Room routing uses the original disc's boot serial. Peers separately verify
/// their full disc digests, firmware, core and deterministic settings.
final class Ps1NetplayProfile {
  const Ps1NetplayProfile._(this.titleId);

  final String titleId;
  static final _serial = RegExp(r'^[A-Z]{4}[0-9]{5}$');
  static Ps1NetplayProfile? tryRead(String? serial) =>
      serial != null && _serial.hasMatch(serial) ? Ps1NetplayProfile._(serial) : null;

  RetroRoomSpec roomFor(Ps1NetplayRoomMode mode) =>
      (titleId: titleId, gameVersion: mode.version, mode: RetroOnlineMode.synchronized, capacity: 2);
}

final class Ps1NetplayMediaFailure implements Exception {
  const Ps1NetplayMediaFailure(this.problem);
  final Ps1NetplayMediaProblem problem;
}

/// The exact local media and deterministic PS1 settings.
/// Paths stay on this computer. Only [identity] is sent to the other player.
final class Ps1NetplayMedia {
  const Ps1NetplayMedia._(this.disc, this.bios, this.core, this.identity, this.execution);

  static const biosPin = '71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3';
  static const corePin = '1aaa621dab9f53b130ac29d17e9a12ea4c0df975d4b02b53faec3b52c717fd12';
  static const portableCorePin = '5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb';
  static const ordinaryHandoffCorePin = 'd1619715fe11db0faa280890c741aff876fd5fd682f3cd00fbcafaa04732b7ac';

  final String disc;
  final String bios;
  final String core;
  final Ps1NetplayIdentity identity;
  final Ps1NetplayExecution execution;
  String get discDigest => identity.toJson()['disc'] as String;
  bool get supportsHandoff =>
      execution == Ps1NetplayExecution.ordinaryHandoff || identity.toJson()['core'] == portableCorePin;

  static final _file = RegExp(r'^FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)\s*$', caseSensitive: false);

  static Future<Ps1NetplayMedia> verify({
    required Ps1NetplayProfile profile,
    required String disc,
    required String bios,
    required String core,
    Ps1NetplayExecution execution = Ps1NetplayExecution.standard,
  }) async {
    final String cue;
    try {
      if (Ps1DiscSerial.read(disc) != profile.titleId) throw const FormatException('Wrong PS1 disc serial.');
      cue = await cueDigest(disc);
    } on FileSystemException {
      throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
    } on FormatException {
      throw const Ps1NetplayMediaFailure(Ps1NetplayMediaProblem.disc);
    }
    final firmware = await _verify(Ps1NetplayMediaProblem.bios, {biosPin}, () => _hashFile(bios));
    final library = await _verify(Ps1NetplayMediaProblem.core, execution.coreDigests, () => _hashFile(core));
    return Ps1NetplayMedia._(
      p.absolute(disc),
      p.absolute(bios),
      p.absolute(core),
      Ps1NetplayIdentity.tryRead({
        'version': 1,
        'title': profile.titleId,
        'disc': cue,
        'bios': firmware,
        'core': library,
        'profile': execution.digest,
        'card': _hashText('isolated-blank-swanstation-card-v1'),
      })!,
      execution,
    );
  }

  static Future<String> _verify(
    Ps1NetplayMediaProblem problem,
    Set<String> pins,
    Future<String> Function() read,
  ) async {
    try {
      final digest = await read();
      if (pins.contains(digest)) return digest;
    } on FileSystemException {
      throw Ps1NetplayMediaFailure(problem);
    } on FormatException {
      throw Ps1NetplayMediaFailure(problem);
    }
    throw Ps1NetplayMediaFailure(problem);
  }

  static String _hashText(String data) => sha256.convert(utf8.encode(data)).toString();
  static Future<String> _hashFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

  /// Mirrors the CTR harness digest. Track content and layout count. Local filenames do not.
  static Future<String> cueDigest(String path) async {
    final cue = File(path);
    if (p.extension(path).toLowerCase() != '.cue' || await cue.length() > 65536) {
      throw const FormatException('Expected a CUE sheet up to 64 KiB.');
    }
    final directory = await cue.parent.resolveSymbolicLinks();
    final lines = <String>[];
    var files = 0;
    for (final raw in const LineSplitter().convert(await cue.readAsString())) {
      final line = raw.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      if (line.isEmpty || line.toUpperCase().startsWith('REM ')) continue;
      final words = line.toUpperCase().split(RegExp(r'\s+'));
      if (words.first != 'FILE') {
        lines.add(words.join(' '));
        continue;
      }
      final match = _file.firstMatch(line);
      if (match == null || ++files > 99) throw const FormatException('Invalid CUE file entry.');
      final name = (match[1] ?? match[2]!).replaceAll('\\', p.separator);
      if (p.isAbsolute(name) || p.windows.isAbsolute(name) || name.contains(':')) {
        throw const FormatException('CUE track must be relative to the game folder.');
      }
      final track = await File(p.normalize(p.join(directory, name))).resolveSymbolicLinks();
      if (!p.isWithin(directory, track)) throw const FormatException('CUE track leaves the game folder.');
      lines.add('FILE ${match[3]!.toUpperCase()} ${await _hashFile(track)}');
    }
    if (files == 0 || !lines.any((line) => line.startsWith('TRACK '))) {
      throw const FormatException('CUE has no tracks.');
    }
    return _hashText(lines.join('\n'));
  }
}
