import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Reads the boot serial from the first supported data track of a PS1 CUE.
abstract final class Ps1DiscSerial {
  static final _file = RegExp(r'^FILE\s+(?:"([^"]+)"|(\S+))\s+BINARY$', caseSensitive: false);
  static final _fileCommand = RegExp(r'^FILE\s', caseSensitive: false);
  static final _track = RegExp(r'^TRACK\s+\d+\s+(\S+)$', caseSensitive: false);
  static final _index = RegExp(r'^INDEX\s+01\s+(\d{2}):([0-5]\d):([0-7]\d)$', caseSensitive: false);
  static final _boot = RegExp(
    r'^\s*BOOT\s*=\s*cdrom:\s*(?:[^;\r\n]*[\\/])?([A-Z]{4})[_-]([0-9]{3})\.?([0-9]{2})(?:;1)?\s*$',
    caseSensitive: false,
    multiLine: true,
  );
  static const _payload = 2048;

  static String? read(String cuePath) {
    if (p.extension(cuePath).toLowerCase() != '.cue') return null;
    try {
      final cue = File(cuePath);
      if (cue.lengthSync() > 65536) return null;
      final directory = cue.parent.resolveSymbolicLinksSync();
      String? file;
      (int, int)? layout;
      for (final raw in const LineSplitter().convert(cue.readAsStringSync())) {
        final line = raw.trim().replaceFirst('\uFEFF', '');
        if (_fileCommand.hasMatch(line)) {
          final match = _file.firstMatch(line);
          file = match == null ? null : match[1] ?? match[2];
          layout = null;
          continue;
        }
        if (_track.firstMatch(line) case final track?) {
          layout = switch (track[1]!.toUpperCase()) {
            'MODE1/2048' => (2048, 0),
            'MODE1/2352' => (2352, 16),
            'MODE2/2336' => (2336, 8),
            'MODE2/2352' => (2352, 24),
            _ => null,
          };
          continue;
        }
        final index = _index.firstMatch(line);
        if (file == null || layout == null || index == null) continue;
        final name = file.replaceAll(r'\', p.separator);
        if (p.isAbsolute(name) || p.windows.isAbsolute(name) || name.contains(':')) return null;
        final track = File(p.join(directory, name)).resolveSymbolicLinksSync();
        if (!p.isWithin(directory, track)) return null;
        final frames = int.parse(index[3]!);
        if (frames >= 75) return null;
        final start = (int.parse(index[1]!) * 60 + int.parse(index[2]!)) * 75 + frames;
        return _readIso(File(track), start, layout.$1, layout.$2);
      }
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    return null;
  }

  static String? _readIso(File track, int start, int stride, int offset) {
    final file = track.openSync();
    try {
      final fileSize = file.lengthSync();
      Uint8List? sector(int lba) {
        final position = (start + lba) * stride + offset;
        if (position + _payload > fileSize) return null;
        file.setPositionSync(position);
        final data = file.readSync(_payload);
        return data.length == _payload ? data : null;
      }

      final pvd = sector(16);
      if (pvd == null || pvd[0] != 1 || ascii.decode(pvd.sublist(1, 6), allowInvalid: true) != 'CD001') {
        return null;
      }
      final header = ByteData.sublistView(pvd);
      final root = header.getUint32(158, Endian.little);
      final length = header.getUint32(166, Endian.little);
      if (length == 0 || length > 1024 * 1024) return null;
      for (var block = 0; block * _payload < length; block++) {
        final data = sector(root + block);
        if (data == null) return null;
        final bytes = ByteData.sublistView(data);
        final remaining = (length - block * _payload).clamp(0, _payload);
        for (var cursor = 0; cursor + 34 <= remaining && data[cursor] != 0;) {
          final count = data[cursor];
          final nameLength = data[cursor + 32];
          if (count < 34 || cursor + count > remaining || 33 + nameLength > count) return null;
          final name = ascii.decode(data.sublist(cursor + 33, cursor + 33 + nameLength), allowInvalid: true);
          if (name == 'SYSTEM.CNF;1' || name == 'SYSTEM.CNF') {
            final config = bytes.getUint32(cursor + 2, Endian.little);
            final size = bytes.getUint32(cursor + 10, Endian.little);
            if (size == 0 || size > _payload) return null;
            final payload = sector(config);
            if (payload == null) return null;
            final boot = _boot.firstMatch(ascii.decode(payload.sublist(0, size), allowInvalid: true));
            return boot == null ? null : '${boot[1]}${boot[2]}${boot[3]}'.toUpperCase();
          }
          cursor += count;
        }
      }
      return null;
    } finally {
      file.closeSync();
    }
  }
}
