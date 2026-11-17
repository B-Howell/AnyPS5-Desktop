import 'dart:io';

import 'package:path/path.dart' as p;

import 'dump_parameters.dart';

/// An add-on (DLC) the player dumped beside a game: a folder the engine mounts as /addcontN.
class GameAddon {
  const GameAddon({required this.folder, required this.label, required this.name});

  final String folder;

  /// The entitlement label the game asks for (16 letters and digits at most).
  final String label;

  /// The name in the add-on's param.json or param.sfo, else its label.
  final String name;

  @override
  bool operator ==(Object other) => other is GameAddon && other.folder == folder && other.label == label && other.name == name;

  @override
  int get hashCode => Object.hash(folder, label, name);

  @override
  String toString() => 'GameAddon($label, $folder)';
}

/// A game update the player dumped beside a game: its files take the place of the game's.
class GameUpdate {
  const GameUpdate({required this.folder, required this.version});

  final String folder;

  /// param.json's contentVersion, such as 01.004.000, or param.sfo's APP_VER, such as 01.09.
  final String version;

  /// The version as the game page shows it: 01.004.000 is 01.004.
  String get shortVersion => GameAddons.shortVersion(version);

  @override
  bool operator ==(Object other) => other is GameUpdate && other.folder == folder && other.version == version;

  @override
  int get hashCode => Object.hash(folder, version);
}

/// Finds the updates and add-ons beside each game, in the layouts shadPS4 users already keep:
///
///     PPSA01234/                     the game
///     PPSA01234-UPDATE/ (or -patch)  its update, a dump of the patch package
///     PPSA01234-DLC/<label>/         one folder per add-on, named by its label or content ID
///     UP0000-PPSA01234_00-<label>/   an add-on in a folder named by its content ID
///
/// The same for a PS4 game (CUSA01234), whose dumps have param.sfo for param.json. The game's own
/// folder name or its title ID both work before the suffix. Only what is on the disk is reported.
abstract final class GameAddons {
  static const updateSuffixes = ['-update', '-patch'];
  static const addonSuffixes = ['-dlc'];

  /// The environment the engine reads them from (ANYPS5_UPDATE_DIR, ANYPS5_ADDCONT_DIRS); the
  /// folders are separated like PATH, with ; on Windows.
  static Map<String, String> environment({GameUpdate? update, List<GameAddon> addons = const [], bool? windows}) {
    final separator = (windows ?? Platform.isWindows) ? ';' : ':';
    return {
      if (update != null) 'ANYPS5_UPDATE_DIR': update.folder,
      if (addons.isNotEmpty) 'ANYPS5_ADDCONT_DIRS': addons.map((addon) => addon.folder).join(separator),
    };
  }

  /// The folders the updates and add-ons of [games] take up: not games of their own, nor dumps
  /// still being copied.
  static List<String> claimed(Iterable<({GameUpdate? update, List<GameAddon> addons})> games) {
    final folders = <String>[];
    for (final game in games) {
      for (final addon in game.addons) {
        folders.add(p.normalize(addon.folder));
        final parent = p.dirname(addon.folder);
        if (addonSuffixes.any((suffix) => p.basename(parent).toLowerCase().endsWith(suffix))) folders.add(p.normalize(parent));
      }
      if (game.update != null) folders.add(p.normalize(game.update!.folder));
    }
    return folders;
  }

  static bool isClaimed(String folder, List<String> claimed) {
    final path = p.normalize(folder);
    return claimed.any((other) => path == other || p.isWithin(other, path));
  }

  /// The update and add-ons beside the game in [folder].
  static ({GameUpdate? update, List<GameAddon> addons}) look(String folder, String titleId) {
    final parent = p.dirname(folder);
    List<Directory> directories;
    try {
      directories = Directory(parent)
          .listSync(followLinks: true)
          .whereType<Directory>()
          .where((entry) => !p.basename(entry.path).startsWith('.') && !p.equals(entry.path, folder))
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    } on FileSystemException {
      return (update: null, addons: const []);
    }
    final stems = {p.basename(folder).toLowerCase(), titleId.toLowerCase()};
    List<Directory> named(List<String> suffixes) {
      final names = {for (final stem in stems) for (final suffix in suffixes) stem + suffix};
      return directories.where((entry) => names.contains(p.basename(entry.path).toLowerCase())).toList();
    }

    GameUpdate? update;
    for (final candidate in named(updateSuffixes)) {
      final parameters = DumpParameters.read(candidate.path);
      if (parameters == null) continue;
      update = GameUpdate(folder: candidate.path, version: parameters.version ?? '');
      break;
    }
    final addons = <GameAddon>[];
    void add(String candidate) {
      final found = addon(candidate);
      if (found == null || addons.any((other) => other.label == found.label)) return;
      addons.add(found);
    }

    for (final root in named(addonSuffixes)) {
      List<Directory> entries;
      try {
        entries = root.listSync(followLinks: true).whereType<Directory>().where((entry) => !p.basename(entry.path).startsWith('.')).toList()
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        add(entry.path);
      }
    }
    for (final candidate in directories) {
      final name = p.basename(candidate.path);
      if (labelOfContentId(name) == null || contentIdTitle(name)?.toLowerCase() != titleId.toLowerCase()) continue;
      if (File(p.join(candidate.path, 'eboot.bin')).existsSync()) continue;
      add(candidate.path);
    }
    return (update: update, addons: addons);
  }

  /// The add-on in [folder], null when no entitlement label can be told from it.
  static GameAddon? addon(String folder) {
    final parameters = DumpParameters.read(folder);
    final fromId = labelOfContentId(parameters?.contentId ?? '');
    final label = fromId ?? labelOfFolderNamed(p.basename(folder));
    if (label == null) return null;
    return GameAddon(folder: folder, label: label, name: parameters?.title ?? label);
  }

  /// The label of a folder named by its content ID or by the label itself.
  static String? labelOfFolderNamed(String name) => labelOfContentId(name) ?? (validLabel(name) ? name : null);

  /// "UP0000-PPSA01234_00-ABCDEFGHIJKLMNOP": the entitlement label is the part after the last dash.
  static String? labelOfContentId(String id) {
    if (id.length != 36 || id[6] != '-' || id[16] != '_' || id[19] != '-') return null;
    final label = id.substring(20);
    return validLabel(label) ? label : null;
  }

  static String? contentIdTitle(String id) => id.length == 36 ? id.substring(7, 16) : null;

  static bool validLabel(String label) => RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(label);

  /// 01.004.000 is 01.004; a version without a trailing .000 stays as it is.
  static String shortVersion(String version) =>
      version.endsWith('.000') && '.'.allMatches(version).length == 2 ? version.substring(0, version.length - 4) : version;
}
