import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final class Ps2LanProfileInUse implements Exception {
  const Ps2LanProfileInUse();
}

/// A launcher's PS2 LAN system and saves, held exclusively until the core exits.
final class Ps2LanProfile {
  Ps2LanProfile._(this.system, this.saves, this._lease);

  final String system;
  final String saves;
  final RandomAccessFile _lease;

  static Future<Ps2LanProfile> open({required String root, required String owner, required String bios}) async {
    final key = sha256.convert(utf8.encode(owner)).toString();
    final folder = await Directory(p.join(root, key)).create(recursive: true);
    final lock = File(p.join(folder.path, 'session.lock'));
    RandomAccessFile? lease;
    try {
      lease = await lock.open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await lease?.close();
      // A Windows sharing or byte-range lock violation means another launch owns this profile.
      if (Platform.isWindows && const {32, 33}.contains(error.osError?.errorCode)) {
        throw const Ps2LanProfileInUse();
      }
      rethrow;
    }

    try {
      final system = p.join(folder.path, 'system');
      final biosFolder = await Directory(p.join(system, 'pcsx2', 'bios')).create(recursive: true);
      await File(bios).copy(p.join(biosFolder.path, 'anyps5-imported.bin'));
      final saves = await Directory(p.join(folder.path, 'saves')).create();
      return Ps2LanProfile._(system, saves.path, lease);
    } on Object {
      await lease.close();
      rethrow;
    }
  }

  Future<void> close() => _lease.close();
}
