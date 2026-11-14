import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The SHA-256 of files a PS1 match is played with (the disc's tracks, the core, the BIOS images),
/// kept while each file is unchanged, as the library's scan keeps what it read of a disc
/// (`RetroScanCache`): a file whose size and modification time are those it was read with is not
/// read again. So inviting a friend, or answering an invite, reads a disc only the first time.
/// What it knows is kept in [file], so it outlives the launcher's run. Files are read on an
/// isolate of their own.
class Ps1FileDigests {
  Ps1FileDigests(this.file);

  /// Where the digests are kept: a JSON object whose `version` is 1 and whose `files` holds, by
  /// path, each file's `bytes`, `modified` (microseconds since the epoch) and `sha256`.
  final String file;

  /// The most files kept; the ones read longest ago go first.
  static const maxFiles = 4096;

  static const _version = 1;
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  Map<String, _Known>? _known;

  /// The digest of each of [paths], reading only the files not known as they are now. Throws a
  /// [FileSystemException] when one is not a file.
  Future<Map<String, String>> of(List<String> paths) async {
    final known = _load();
    final now = {for (final path in paths) path: _stat(path)};
    final missing = [
      for (final MapEntry(key: path, value: stat) in now.entries)
        if (!_fresh(known[path], stat)) path,
    ];
    if (missing.isNotEmpty) {
      final read = await Isolate.run(() => {for (final path in missing) path: fileDigest(path)});
      for (final path in missing) {
        known.remove(path);
        known[path] = _Known(now[path]!.size, now[path]!.modified.microsecondsSinceEpoch, read[path]!);
      }
      _save(known);
    }
    return {for (final path in paths) path: known[path]!.sha256};
  }

  /// The digest of each of [paths] when every one is known as it is now; null when one would have
  /// to be read. Reads no file.
  Map<String, String>? knownNow(List<String> paths) {
    final known = _load();
    final found = <String, String>{};
    for (final path in paths) {
      final FileStat stat;
      try {
        stat = _stat(path);
      } on FileSystemException {
        return null;
      }
      final entry = known[path];
      if (entry == null || !_fresh(entry, stat)) return null;
      found[path] = entry.sha256;
    }
    return found;
  }

  /// The SHA-256 of the file at [path], as 64 lowercase hexadecimal digits.
  static String fileDigest(String path) {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    final file = File(path).openSync();
    try {
      final buffer = Uint8List(1 << 20);
      while (true) {
        final read = file.readIntoSync(buffer);
        if (read == 0) break;
        input.add(Uint8List.sublistView(buffer, 0, read));
      }
    } finally {
      file.closeSync();
    }
    input.close();
    return sink.value.toString();
  }

  static FileStat _stat(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) throw FileSystemException('Not a file', path);
    return stat;
  }

  static bool _fresh(_Known? known, FileStat stat) =>
      known != null && known.bytes == stat.size && known.modified == stat.modified.microsecondsSinceEpoch;

  Map<String, _Known> _load() {
    final loaded = _known;
    if (loaded != null) return loaded;
    final known = <String, _Known>{};
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      if (json is Map<String, Object?> && json['version'] == _version && json['files'] is Map<String, Object?>) {
        for (final MapEntry(key: path, :value) in (json['files']! as Map<String, Object?>).entries) {
          if (value case {'bytes': final int bytes, 'modified': final int modified, 'sha256': final String digest}
              when bytes >= 0 && _digest.hasMatch(digest)) {
            known[path] = _Known(bytes, modified, digest);
          }
        }
      }
    } on FileSystemException {
      // Nothing kept yet.
    } on FormatException {
      // A damaged file is replaced at the next save.
    }
    return _known = known;
  }

  void _save(Map<String, _Known> known) {
    while (known.length > maxFiles) {
      known.remove(known.keys.first);
    }
    final json = jsonEncode({
      'version': _version,
      'files': {
        for (final MapEntry(key: path, value: entry) in known.entries)
          path: {'bytes': entry.bytes, 'modified': entry.modified, 'sha256': entry.sha256},
      },
    });
    try {
      final target = File(file)..parent.createSync(recursive: true);
      final temporary = File('$file.tmp')..writeAsStringSync(json, flush: true);
      temporary.renameSync(target.path);
    } on FileSystemException {
      // Kept in memory for this run; read again in the next one.
    }
  }
}

class _Known {
  const _Known(this.bytes, this.modified, this.sha256);

  final int bytes;
  final int modified;
  final String sha256;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
