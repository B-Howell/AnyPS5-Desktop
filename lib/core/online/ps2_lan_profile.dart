import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final class Ps2LanProfileInUse implements Exception {
  const Ps2LanProfileInUse();
}

/// A launcher's PS2 LAN system and saves, held exclusively until the core exits.
final class Ps2LanProfile {
  Ps2LanProfile._(this.system, this.saves, this._lease, this._lockPath);

  // POSIX byte-range locks belong to the process, so another open in the
  // same launcher must be rejected before it opens or closes the lock file.
  static final _openProfiles = <String>{};

  final String system;
  final String saves;
  final RandomAccessFile _lease;
  final String _lockPath;
  Future<void>? _closing;

  static Future<Ps2LanProfile> open({required String root, required String owner, required String bios}) async {
    final key = sha256.convert(utf8.encode(owner)).toString();
    final folder = await Directory(p.join(root, key)).create(recursive: true);
    final path = await folder.resolveSymbolicLinks();
    final lockPath = p.join(path, 'session.lock');
    if (!_openProfiles.add(lockPath)) throw const Ps2LanProfileInUse();

    RandomAccessFile? lease;
    try {
      try {
        lease = await File(lockPath).open(mode: FileMode.append);
        await lease.lock(FileLock.exclusive);
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if ((Platform.isWindows && const {32, 33}.contains(code)) ||
            (lease != null && Platform.isLinux && const {11, 13}.contains(code))) {
          throw const Ps2LanProfileInUse();
        }
        rethrow;
      }

      final system = p.join(path, 'system');
      final biosFolder = await Directory(p.join(system, 'pcsx2', 'bios')).create(recursive: true);
      await File(bios).copy(p.join(biosFolder.path, 'anyps5-imported.bin'));
      final saves = await Directory(p.join(path, 'saves')).create();
      return Ps2LanProfile._(system, saves.path, lease, lockPath);
    } on Object {
      try {
        await lease?.close();
      } finally {
        _openProfiles.remove(lockPath);
      }
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _release();

  Future<void> _release() async {
    try {
      await _lease.close();
    } finally {
      _openProfiles.remove(_lockPath);
    }
  }
}
