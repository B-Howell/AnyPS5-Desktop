import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ps1_netplay_identity.dart';
import 'retro_online_rooms.dart';

enum Ps1NetplayMediaProblem { disc, bios, core }

/// A local qualification record. Title hints only choose which files to hash.
/// The full disc digest is the compatibility gate.
final class Ps1NetplayProfile {
  const Ps1NetplayProfile({required this.titleId, required this.title, required this.discPin});

  final String titleId;
  final String title;
  final String discPin;

  RetroRoomSpec get room => (titleId: titleId, gameVersion: '1', mode: RetroOnlineMode.synchronized, capacity: 2);
  RetroRoomSpec get handoffRoom =>
      (titleId: titleId, gameVersion: '2', mode: RetroOnlineMode.synchronized, capacity: 2);

  bool hintsAt({required String serial, required String name}) =>
      serial.toUpperCase().replaceFirst('PS1-', '').replaceAll('-', '') == titleId ||
      name.toLowerCase().contains(title.toLowerCase());

  static const qualified = [
    Ps1NetplayProfile(
      titleId: 'SCUS94426',
      title: 'Crash Team Racing',
      discPin: '7061d0d774c4d73bd3bc90afaa1b6d35a9fcdd797c5d92d973af55423e2ce59f',
    ),
  ];
}

final class Ps1NetplayMediaFailure implements Exception {
  const Ps1NetplayMediaFailure(this.problem);
  final Ps1NetplayMediaProblem problem;
}

/// The exact local media matched against a qualified PS1 profile.
/// Paths stay on this computer. Only [identity] is sent to the other player.
final class Ps1NetplayMedia {
  const Ps1NetplayMedia._(this.disc, this.bios, this.core, this.identity);

  static const biosPin = '71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3';
  static const corePin = '1aaa621dab9f53b130ac29d17e9a12ea4c0df975d4b02b53faec3b52c717fd12';
  static const portableCorePin = '5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb';

  final String disc;
  final String bios;
  final String core;
  final Ps1NetplayIdentity identity;
  bool get supportsHandoff => identity.toJson()['core'] == portableCorePin;

  static final _file = RegExp(r'^FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)\s*$', caseSensitive: false);

  static Future<Ps1NetplayMedia> verify({
    required Ps1NetplayProfile profile,
    required String disc,
    required String bios,
    required String core,
  }) async {
    final cue = await _verify(Ps1NetplayMediaProblem.disc, {profile.discPin}, () => cueDigest(disc));
    final firmware = await _verify(Ps1NetplayMediaProblem.bios, {biosPin}, () => _hashFile(bios));
    final library = await _verify(Ps1NetplayMediaProblem.core, {corePin, portableCorePin}, () => _hashFile(core));
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
        'profile': _hashText(
          'Software;1x;CachedInterpreter;block-linking=0;gpu-thread=0;fast-boot=0;two-digital-pads;delay=2',
        ),
        'card': _hashText('isolated-blank-swanstation-card-v1'),
      })!,
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
