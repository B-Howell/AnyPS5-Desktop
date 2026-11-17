import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A PlayStation parameter file (PS3 PARAM.SFO, PS4 sce_sys/param.sfo): a little-endian table of
/// keys and values behind the "\0PSF" magic. Each 16-byte entry names its key's offset, its
/// format (0x0204 UTF-8 text ending in a zero byte, 0x0404 a 32-bit integer, 0x0004 bytes), its
/// length and its value's offset. The text and integer values are kept; an entry outside the
/// file is skipped, so what reads of a damaged file is still there.
class ParamSfo {
  const ParamSfo({this.texts = const {}, this.integers = const {}});

  /// The text values (TITLE, TITLE_ID, APP_VER, CATEGORY, CONTENT_ID...).
  final Map<String, String> texts;

  /// The integer values (ATTRIBUTE, PARENTAL_LEVEL, SYSTEM_VER...).
  final Map<String, int> integers;

  /// A parameter file is a few kilobytes; a larger file is not one.
  static const maxSize = 1024 * 1024;

  static const textFormat = 0x0204;
  static const integerFormat = 0x0404;

  /// The file at [path], null when it is not there, is too large or is no parameter file.
  static ParamSfo? read(String path) {
    try {
      final file = File(path);
      if (file.lengthSync() > maxSize) return null;
      return parse(file.readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  /// The values in [bytes], null when they do not start with the magic and a whole header.
  static ParamSfo? parse(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    if (data.length < 20 || view.getUint32(0) != 0x00505346) return null;
    final keyStart = view.getUint32(8, Endian.little);
    final valueStart = view.getUint32(12, Endian.little);
    final count = view.getUint32(16, Endian.little);
    if (20 + count * 16 > keyStart || keyStart > valueStart || valueStart > data.length) return null;
    final texts = <String, String>{};
    final integers = <String, int>{};
    for (var i = 0; i < count; i++) {
      final entry = 20 + i * 16;
      final format = view.getUint16(entry + 2, Endian.little);
      final key = keyStart + view.getUint16(entry, Endian.little);
      final size = view.getUint32(entry + 4, Endian.little);
      final value = valueStart + view.getUint32(entry + 12, Endian.little);
      if (key >= valueStart || value + size > data.length) continue;
      final name = _text(data, key, valueStart);
      if (format == textFormat) {
        texts[name] = _text(data, value, value + size);
      } else if (format == integerFormat && size == 4) {
        integers[name] = view.getInt32(value, Endian.little);
      }
    }
    return ParamSfo(texts: texts, integers: integers);
  }

  static String _text(Uint8List bytes, int start, int limit) {
    final end = bytes.indexOf(0, start);
    return utf8.decode(bytes.sublist(start, end < 0 || end > limit ? limit : end), allowMalformed: true);
  }
}
