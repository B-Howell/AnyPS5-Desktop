import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ps3_disc.dart';

enum Ps3OnlineIssue implements Exception { unqualified, storage, core, update, patch, firmware, account }

enum Ps3Xfloat { accurate, approximate, relaxed, inaccurate }

enum Ps3Dns {
  google('8.8.8.8'),
  cloudflare('1.1.1.1'),
  openDns('208.67.222.222');

  const Ps3Dns(this.address);
  final String address;
}

/// Pins a reviewed provider and game revision to the exact launch artifacts.
/// The application supplies these records from its reviewed release catalog.
final class Ps3OnlineRelease {
  const Ps3OnlineRelease({
    required this.provider,
    required this.titleId,
    required this.updateVersion,
    required this.coreSha256,
    required this.executableSha256,
    required this.patchName,
    required this.patchSha256,
    required this.rpcnHost,
    required this.providerFiles,
    required this.xfloat,
    required this.dns,
    required this.upnp,
  });

  final String provider;
  final String titleId;
  final String updateVersion;
  final String coreSha256;
  final String executableSha256;
  final String patchName;
  final String patchSha256;
  final String rpcnHost;

  /// Relative RPCS3 HDD paths and SHA-256 digests for public provider files.
  final Map<String, String> providerFiles;
  final Ps3Xfloat xfloat;
  final Ps3Dns dns;
  final bool upnp;
}

/// Local launch capability. The account and provider configuration stay in the
/// isolated RPCS3 profile. The method channel receives only network options.
final class Ps3OnlineProfile {
  const Ps3OnlineProfile._(this.release, this.disc, this.core, this.systemRoot, this.saveRoot);

  final Ps3OnlineRelease release;
  final String disc;
  final String core;
  final String systemRoot;
  final String saveRoot;

  Map<String, Object> get networkArguments => {
    'xfloat': release.xfloat.name,
    'dns': release.dns.address,
    'upnp': release.upnp,
  };

  static Future<Ps3OnlineProfile> verify({
    required String provider,
    required String disc,
    required String core,
    required String onlineRoot,
    required String offlineSystemRoot,
    Iterable<Ps3OnlineRelease> releases = const [],
  }) async {
    if (p.basename(disc).toUpperCase() != 'PS3_DISC.SFB') throw Ps3OnlineIssue.unqualified;
    final title = Ps3Disc.metadata(p.dirname(disc))?['TITLE_ID'];
    if (title == null || !RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(title)) {
      throw Ps3OnlineIssue.unqualified;
    }
    final release = releases.where((entry) => entry.provider == provider && entry.titleId == title).firstOrNull;
    if (release == null || !RegExp(r'^[A-Za-z0-9._-]+\.sprx$').hasMatch(release.patchName)) {
      throw Ps3OnlineIssue.unqualified;
    }
    final profileRoot = await _directory(onlineRoot);
    final offlineRoot = await _directory(offlineSystemRoot);
    final systemRoot = p.join(profileRoot, 'system');
    final saveRoot = p.join(profileRoot, 'saves');
    final rpcs3Root = p.join(systemRoot, 'rpcs3');
    final configRoot = Platform.isWindows ? p.join(rpcs3Root, 'config') : rpcs3Root;
    if (_overlap(profileRoot, offlineRoot) ||
        !p.equals(await _directory(systemRoot), systemRoot) ||
        !p.equals(await _directory(rpcs3Root), rpcs3Root) ||
        !p.equals(await _directory(configRoot), configRoot)) {
      throw Ps3OnlineIssue.storage;
    }
    if (await FileSystemEntity.type(saveRoot, followLinks: false) != FileSystemEntityType.notFound &&
        !p.equals(await _directory(saveRoot), saveRoot)) {
      throw Ps3OnlineIssue.storage;
    }
    // A VFS override can redirect game and save files outside the profile.
    if (await File(p.join(configRoot, 'vfs.yml')).exists() || await File(p.join(rpcs3Root, 'vfs.yml')).exists()) {
      throw Ps3OnlineIssue.storage;
    }
    try {
      await for (final item in Directory(profileRoot).list(recursive: true, followLinks: false)) {
        if (item is Link) throw Ps3OnlineIssue.storage;
      }
    } on FileSystemException {
      throw Ps3OnlineIssue.storage;
    }

    await _verifyHash(File(core), release.coreSha256, Ps3OnlineIssue.core);
    final hdd = p.join(rpcs3Root, 'dev_hdd0');
    final update = p.join(hdd, 'game', title);
    final metadata = await _profileFile(profileRoot, p.join(update, 'PARAM.SFO'), Ps3OnlineIssue.update);
    final fields = Ps3Disc.readSfo(metadata);
    if (fields?['TITLE_ID'] != title || fields?['APP_VER'] != release.updateVersion) throw Ps3OnlineIssue.update;
    final executable = await _profileFile(profileRoot, p.join(update, 'USRDIR', 'EBOOT.BIN'), Ps3OnlineIssue.update);
    await _verifyHash(executable, release.executableSha256, Ps3OnlineIssue.update);
    final patch = await _profileFile(profileRoot, p.join(hdd, 'plugins', release.patchName), Ps3OnlineIssue.patch);
    await _verifyHash(patch, release.patchSha256, Ps3OnlineIssue.patch);
    for (final entry in release.providerFiles.entries) {
      final parts = entry.key.split('/');
      if (parts.any((part) => part == '.' || part == '..' || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part))) {
        throw Ps3OnlineIssue.unqualified;
      }
      final file = await _profileFile(profileRoot, p.joinAll([hdd, ...parts]), Ps3OnlineIssue.patch);
      await _verifyHash(file, entry.value, Ps3OnlineIssue.patch);
    }
    await _profileFile(
      profileRoot,
      p.join(rpcs3Root, 'dev_flash', 'vsh', 'module', 'vsh.self'),
      Ps3OnlineIssue.firmware,
    );
    final account = await _profileFile(profileRoot, p.join(configRoot, 'rpcn.yml'), Ps3OnlineIssue.account);
    await _verifyAccount(account, release.rpcnHost);
    return Ps3OnlineProfile._(release, p.absolute(disc), p.absolute(core), systemRoot, saveRoot);
  }

  static bool _overlap(String first, String second) =>
      p.equals(first, second) || p.isWithin(first, second) || p.isWithin(second, first);

  static Future<String> _directory(String path) async {
    try {
      if (p.isAbsolute(path)) return await Directory(path).resolveSymbolicLinks();
    } on FileSystemException {
      throw Ps3OnlineIssue.storage;
    }
    throw Ps3OnlineIssue.storage;
  }

  static Future<File> _profileFile(String root, String path, Ps3OnlineIssue issue) async {
    try {
      final file = File(path);
      if (p.isWithin(root, await file.resolveSymbolicLinks()) && await file.length() > 0) return file;
    } on FileSystemException {
      throw issue;
    }
    throw issue;
  }

  static Future<void> _verifyHash(File file, String expected, Ps3OnlineIssue issue) async {
    try {
      if ((await sha256.bind(file.openRead()).first).toString() == expected) return;
    } on FileSystemException {
      throw issue;
    }
    throw issue;
  }

  static Future<void> _verifyAccount(File file, String host) async {
    try {
      if (await file.length() > 65536) throw Ps3OnlineIssue.account;
      if (loadYaml(await file.readAsString()) case final YamlMap account
          when account['Version'] == 2 &&
              account['Host'] == host &&
              _nonempty(account['NPID']) &&
              _nonempty(account['Password'])) {
        return;
      }
    } on YamlException {
      // Parser diagnostics may contain credential values.
      throw Ps3OnlineIssue.account;
    } on FormatException {
      throw Ps3OnlineIssue.account;
    } on FileSystemException {
      throw Ps3OnlineIssue.account;
    }
    throw Ps3OnlineIssue.account;
  }

  static bool _nonempty(Object? value) => value is String && value.trim().isNotEmpty;
}
