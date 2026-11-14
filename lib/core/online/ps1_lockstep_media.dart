import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../game_library.dart';

import 'ps1_file_digests.dart';
import 'ps1_lockstep_match.dart';

/// The files a PS1 match is played with, and their digests: two launchers play together only
/// when the digests match (anyps5-retro-host docs/netplay.md "Joining a running game", step 1:
/// "the same disc (by a hash of its tracks)"). The state a friend joins from names its disc by its
/// place in the disc list, not by a path (netplay.md "Determinism"), so neither launcher's file
/// names count: only each disc's layout (its cue sheet's tracks, modes, indexes and gaps) and
/// tracks' contents, disc by disc in the order of the disc list.
abstract final class Ps1LockstepMedia {
  /// The size of a PS1 BIOS image: what SwanStation reads from the system folder.
  static const biosBytes = 512 * 1024;

  /// The files that only name others: a cue sheet names its tracks and a playlist its discs, by
  /// file name. Two copies of the same disc may name them differently.
  static const sheets = {'.cue', '.m3u'};

  /// A disc's tracks among its [files] (the library's list: the playlist, then each disc's sheet and
  /// tracks, in the playlist's order), in that order.
  static List<String> tracks(List<String> files) => [
    for (final file in files)
      if (!sheets.contains(p.extension(file).toLowerCase())) file,
  ];

  /// The bytes of a disc's tracks.
  static int discBytes(List<String> files) {
    var total = 0;
    for (final file in tracks(files)) {
      total += File(file).lengthSync();
    }
    return total;
  }

  /// What this launcher plays a disc of [files] with: its disc digest ([discDigestOf]), the
  /// SHA-256 of the [core] library, and that of the BIOS images in [system] ([biosDigestOf]). Only
  /// files [digests] does not know as they are now are read.
  static Future<Ps1LockstepIdentity> identify({
    required Ps1FileDigests digests,
    required String hostVersion,
    required String core,
    required List<String> files,
    required String system,
  }) async {
    final bios = biosImages(system);
    final known = await digests.of([core, ...tracks(files), ...bios]);
    return Ps1LockstepIdentity(
      hostVersion: hostVersion,
      system: Platform.operatingSystem,
      core: known[core]!,
      disc: discDigestOf(files, known),
      bios: biosDigestOf([for (final image in bios) known[image]!]),
    );
  }

  /// The disc digest of a disc of [files] when [digests] knows every track as it is now; null when
  /// a track would have to be read, or the disc is not whole.
  static String? knownDisc(Ps1FileDigests digests, List<String> files) {
    final disc = tracks(files);
    if (disc.isEmpty) return null;
    final known = digests.knownNow(disc);
    if (known == null) return null;
    try {
      return discDigestOf(files, known);
    } on FileSystemException {
      return null;
    }
  }

  /// The disc digest of a disc of [files], reading the tracks [digests] does not know.
  static Future<String> discDigest(Ps1FileDigests digests, List<String> files) async =>
      discDigestOf(files, await digests.of(tracks(files)));

  /// A cue sheet's `FILE` line: the file's name, quoted or not, and its type.
  static final _fileLine = RegExp(r'^FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)$', caseSensitive: false);

  /// The cue sheet commands that shape what the console reads: the rest (`REM`, `TITLE`,
  /// `PERFORMER`, `CATALOG`, …) is description a copy may differ in.
  static const _layout = {'TRACK', 'INDEX', 'PREGAP', 'POSTGAP', 'FLAGS'};

  /// The SHA-256 of the disc list of [files] (the library's list: a playlist, then each disc's
  /// cue sheet and tracks, or a CHD or PBP, in the playlist's order), given each track's SHA-256 in
  /// [trackDigests]. One line a disc's part, a `DISC` line before each disc: a cue sheet's layout
  /// commands as written (spaces collapsed, upper case), with each `FILE` naming its track by its
  /// digest rather than its name, or `IMAGE` and the digest of a CHD or PBP. So two copies under
  /// other names are the same disc list, and a different layout, a different number of discs or
  /// another playlist order is not. Throws a [FileSystemException] when a cue sheet names a track
  /// that is not among [files].
  static String discDigestOf(List<String> files, Map<String, String> trackDigests) {
    final named = {for (final file in tracks(files)) p.normalize(p.absolute(file)): trackDigests[file]!};
    final inSheets = <String>{};
    final lines = <String>[];
    for (final file in files) {
      switch (p.extension(file).toLowerCase()) {
        case '.m3u':
          continue;
        case '.cue':
          lines.add('DISC');
          final folder = p.dirname(file);
          for (final raw in const LineSplitter().convert(GameLibrary.sheetText(File(file)))) {
            final fileLine = _fileLine.firstMatch(raw.trim());
            final line = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
            if (fileLine != null) {
              final name = (fileLine[1] ?? fileLine[2]!).replaceAll(r'\', '/');
              final track = p.normalize(p.absolute(p.join(folder, p.joinAll(name.split('/')))));
              final digest = named[track];
              if (digest == null) throw FileSystemException('A cue sheet names a track that is not there', track);
              inSheets.add(track);
              lines.add('FILE $digest ${fileLine[3]!.toUpperCase()}');
            } else if (line.isNotEmpty && _layout.contains(line.split(' ').first.toUpperCase())) {
              lines.add(line.toUpperCase());
            }
          }
        default:
          final image = p.normalize(p.absolute(file));
          if (inSheets.contains(image)) continue;
          lines
            ..add('DISC')
            ..add('IMAGE ${named[image]!}');
      }
    }
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  /// The 512 KiB files in [system], the BIOS images SwanStation may choose from.
  static List<String> biosImages(String system) {
    final folder = Directory(system);
    if (!folder.existsSync()) return const [];
    return [
      for (final entry in folder.listSync())
        if (entry is File && entry.lengthSync() == biosBytes) entry.path,
    ];
  }

  /// The SHA-256 of the sorted SHA-256 digests [imageDigests] of the BIOS images; that of no
  /// digests when there is none.
  static String biosDigestOf(List<String> imageDigests) =>
      sha256.convert((List.of(imageDigests)..sort()).join('\n').codeUnits).toString();

  /// Whether [files] could be the disc of an invite of [bytes] bytes, before they are read.
  static bool couldBe(List<String> files, int bytes) {
    try {
      return tracks(files).isNotEmpty && discBytes(files) == bytes;
    } on FileSystemException {
      return false;
    }
  }
}
