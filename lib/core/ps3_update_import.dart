import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ps3_disc.dart';

typedef Ps3UpdatePackage = ({String version, int size, String digest});

Future<Directory> _updateHome(String root, {required bool create}) async {
  final directory = Directory(p.normalize(p.absolute(root)));
  final parent = directory.parent;
  if (create) await parent.create(recursive: true);
  final expected = p.join(await parent.resolveSymbolicLinks(), p.basename(directory.path));
  final home = Directory(expected);
  if (create && await FileSystemEntity.type(expected, followLinks: false) == FileSystemEntityType.notFound) {
    await home.create();
  }
  if (!p.equals(await home.resolveSymbolicLinks(), expected)) {
    throw const FormatException('The PS3 update folder is redirected.');
  }
  return home;
}

final class Ps3UpdateMissing implements Exception {
  const Ps3UpdateMissing(this.versions);
  final List<String> versions;
}

final class Ps3UpdateCancelled implements Exception {
  const Ps3UpdateCancelled();
}

/// The native worker may still be using the staging directory.
final class Ps3UpdateWorkerUnconfirmed implements Exception {
  const Ps3UpdateWorkerUnconfirmed();
}

/// A reviewed local update chain. This catalog does not authorize online play.
final class Ps3UpdateChain {
  const Ps3UpdateChain({
    required this.titleId,
    required this.discVersion,
    required this.version,
    required this.executableDigest,
    required this.packages,
  });

  final String titleId;
  final String discVersion;
  final String version;
  final String executableDigest;
  final List<Ps3UpdatePackage> packages;

  static const catalog = [
    Ps3UpdateChain(
      titleId: 'BCUS98208',
      discVersion: '01.18',
      version: '01.30',
      executableDigest: 'df37eced6be40c6a863d5c8994b1072c47dc293e0a1c73c64ff490f10d6d74c5',
      packages: [
        (version: '01.19', size: 32868208, digest: 'bd44cafb76d9852247c9cb9e61b90104dc619dd9d782adc5ca9412935d1e34ee'),
        (version: '01.20', size: 24002816, digest: '0e7f3e656cffd4b97c2b571a3a8d9380b7c3a2e379dc5375a38ff05ab1f571b3'),
        (version: '01.21', size: 54859584, digest: '8b26b0f56b9defd6bd9f655ed27c7b7fa72b484a0b01c8416147c036517c3fc7'),
        (version: '01.22', size: 118431600, digest: '46fafaaa9bc4d4b7745232faca2da954a6eab663f760ee7f29a98f90fb0d693d'),
        (version: '01.23', size: 59861392, digest: '703c5b77b1fa37a04e19a1114c310ae1855dc31fc02315d9cedf3ee315d0215a'),
        (version: '01.24', size: 17144272, digest: '6a5d61b6f2a7c5605f5bdf6aece1937002d0e9276f57b3ffd787b902d126b7df'),
        (version: '01.25', size: 19060224, digest: '22c62a319b28c1b106a2703e11c330eb3c3aac29ddf92e30ebdf58e72b343a32'),
        (version: '01.26', size: 23232608, digest: '35019e9ef1582246ad53cc4fb819c48eface404304ee9dbb8d0da66c316ebe3f'),
        (version: '01.27', size: 25692528, digest: '9daa44c0e40ddcf046195f0f38d336431b3cf56e600f42ef785299fe34cf73cb'),
        (version: '01.28', size: 84964512, digest: '3bb67b12bb2ff3d0bcdfdc329659a72c96b8b4461c1b44e65c98aa64af7331d7'),
        (version: '01.30', size: 6842416, digest: 'a3dbaa8e9efb2dc986181202429dd1d3d6d2dbf5c637ff2a232535720e63b925'),
      ],
    ),
  ];

  static Ps3UpdateChain? forDisc(String? title, String? version) =>
      catalog.where((chain) => chain.titleId == title && chain.discVersion == version).firstOrNull;

  String _destination(String root) {
    if (!RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(titleId) || !RegExp(r'^\d{2}\.\d{2}$').hasMatch(version)) {
      throw const FormatException('Invalid PS3 update target.');
    }
    return p.join(root, titleId, version);
  }

  Future<bool> isPrepared(String root) async {
    try {
      final home = await _updateHome(root, create: false);
      final destination = Directory(_destination(home.path));
      return p.equals(await destination.resolveSymbolicLinks(), destination.path) && await _validTitle(destination);
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<VerifiedPs3Update> inspect(String folder) async {
    final candidates = <int, List<Ps3UpdatePackage>>{};
    for (final package in packages) {
      (candidates[package.size] ??= []).add(package);
    }
    final found = <String, File>{};
    await for (final entry in Directory(folder).list(followLinks: false)) {
      if (entry is! File || p.extension(entry.path).toLowerCase() != '.pkg') continue;
      final size = await entry.length();
      final matches = candidates[size];
      if (matches == null) continue;
      final digest = await sha256.bind(entry.openRead(0, size + 1)).first;
      if (matches.any((package) => package.digest == digest.toString())) {
        found.putIfAbsent(digest.toString(), () => entry);
        if (packages.every((package) => found.containsKey(package.digest))) break;
      }
    }
    final missing = packages.where((package) => !found.containsKey(package.digest));
    if (missing.isNotEmpty) {
      throw Ps3UpdateMissing(List.unmodifiable(missing.map((package) => package.version)));
    }
    return VerifiedPs3Update._(this, [for (final package in packages) found[package.digest]!]);
  }

  Future<bool> _validTitle(Directory directory) async {
    try {
      final title = await directory.resolveSymbolicLinks();
      if (!p.equals(title, p.join(await directory.parent.resolveSymbolicLinks(), p.basename(directory.path)))) {
        return false;
      }
      final sfo = File(p.join(title, 'PARAM.SFO'));
      final executable = File(p.join(title, 'USRDIR', 'EBOOT.BIN'));
      if (!p.equals(await sfo.resolveSymbolicLinks(), sfo.path) ||
          !p.equals(await executable.resolveSymbolicLinks(), executable.path)) {
        return false;
      }
      final fields = Ps3Disc.readSfo(sfo);
      return fields?['TITLE_ID'] == titleId &&
          fields?['APP_VER'] == version &&
          fields?['CATEGORY'] == 'GD' &&
          (await sha256.bind(executable.openRead()).first).toString() == executableDigest;
    } on FileSystemException {
      return false;
    }
  }
}

final class VerifiedPs3Update {
  const VerifiedPs3Update._(this.chain, this._sources);

  final Ps3UpdateChain chain;
  final List<File> _sources;

  /// Only the verified title data is published. The staging profile is disposable.
  Future<String> install(
    String root,
    Future<void> Function(String stage, int count) extract, {
    bool Function()? cancelled,
  }) async {
    void checkCancelled() {
      if (cancelled?.call() == true) throw const Ps3UpdateCancelled();
    }

    final home = await _updateHome(root, create: true);
    final resolved = home.path;
    final destination = Directory(chain._destination(resolved));
    checkCancelled();
    if (await chain.isPrepared(resolved)) return destination.path;
    final stage = await Directory(resolved).createTemp('staging-');
    var cleanup = true;
    try {
      await Directory(p.join(stage.path, 'system')).create();
      await Directory(p.join(stage.path, 'saves')).create();
      final input = await Directory(p.join(stage.path, 'packages')).create();
      for (final (index, source) in _sources.indexed) {
        checkCancelled();
        final package = chain.packages[index];
        final copy = File(p.join(input.path, '$index.pkg'));
        await source.openRead(0, package.size + 1).pipe(copy.openWrite());
        if (await copy.length() != package.size ||
            (await sha256.bind(copy.openRead()).first).toString() != package.digest) {
          throw FormatException('PS3 update ${package.version} changed after verification.');
        }
      }
      checkCancelled();
      await extract(stage.path, _sources.length);
      checkCancelled();
      final title = Directory(p.join(stage.path, 'system', 'rpcs3', 'dev_hdd0', 'game', chain.titleId));
      if (!p.equals(await title.resolveSymbolicLinks(), title.path) || !await chain._validTitle(title)) {
        throw const FormatException('The installed PS3 update did not pass verification.');
      }
      await destination.parent.create();
      if (!p.equals(await destination.parent.resolveSymbolicLinks(), destination.parent.path)) {
        throw const FormatException('The PS3 update destination is redirected.');
      }
      checkCancelled();
      try {
        await title.rename(destination.path);
      } on FileSystemException {
        if (!await chain.isPrepared(resolved)) rethrow;
      }
      return destination.path;
    } on Ps3UpdateWorkerUnconfirmed {
      cleanup = false;
      rethrow;
    } finally {
      if (cleanup) {
        try {
          await stage.delete(recursive: true);
        } on FileSystemException {
          // An OS file lock may leave the disposable stage behind. It must not
          // hide the import result or invalidate a published update.
        }
      }
    }
  }
}
