import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ps1_lockstep_match.dart';

/// The files a PS1 match is played with, and their digests: two launchers play together only
/// when the digests match (anyps5-retro-host docs/netplay.md "Joining a running game", step 1).
/// Reading a whole disc takes seconds, so it runs on its own isolate.
abstract final class Ps1LockstepMedia {
  /// The size of a PS1 BIOS image: what SwanStation reads from the system folder.
  static const biosBytes = 512 * 1024;

  /// The bytes of a disc's [files] (its sheet and tracks, as the library found them).
  static int discBytes(List<String> files) {
    var total = 0;
    for (final file in files) {
      total += File(file).lengthSync();
    }
    return total;
  }

  /// What this launcher plays [disc] with: the SHA-256 of the disc's [files] (each file's digest,
  /// sorted, so neither the folder nor the order the library found them in counts), the disc's
  /// file name, the SHA-256 of the [core] library, and the SHA-256 of the BIOS images in [system]
  /// (each 512 KiB file's digest, sorted).
  static Future<Ps1LockstepIdentity> identify({
    required String hostVersion,
    required String core,
    required String disc,
    required List<String> files,
    required String system,
  }) => Isolate.run(
    () => Ps1LockstepIdentity(
      hostVersion: hostVersion,
      system: Platform.operatingSystem,
      core: _fileDigest(core),
      disc: discDigest(files),
      discName: p.basename(disc),
      bios: biosDigest(system),
    ),
  );

  /// The SHA-256 of the sorted SHA-256 digests of [files], as lowercase hexadecimal.
  static String discDigest(List<String> files) => _ofDigests([for (final file in files) _fileDigest(file)]);

  /// The SHA-256 of the sorted SHA-256 digests of the BIOS images in [system]; that of no digests
  /// when there is none.
  static String biosDigest(String system) {
    final folder = Directory(system);
    if (!folder.existsSync()) return _ofDigests(const []);
    return _ofDigests([
      for (final entry in folder.listSync())
        if (entry is File && entry.lengthSync() == biosBytes) _fileDigest(entry.path),
    ]);
  }

  /// Whether [files] could be the disc of an invite of [bytes] bytes, before they are read.
  static bool couldBe(List<String> files, int bytes) {
    try {
      return discBytes(files) == bytes;
    } on FileSystemException {
      return false;
    }
  }

  static String _ofDigests(List<String> digests) =>
      sha256.convert((List.of(digests)..sort()).join('\n').codeUnits).toString();

  static String _fileDigest(String path) {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    final file = File(path).openSync();
    try {
      final buffer = Uint8List(1 << 20);
      while (true) {
        final read = file.readIntoSync(buffer);
        if (read == 0) break;
        input.add(buffer.sublist(0, read));
      }
    } finally {
      file.closeSync();
    }
    input.close();
    return sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
