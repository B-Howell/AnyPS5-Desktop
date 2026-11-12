import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'account.dart';

/// `Invites.log` in the launcher's logs folder: one line for each step of a game invite, sent or
/// received, so a lost invite can be followed from the friend chosen to the row shown. It holds
/// session ids, short hashes of account ids, display names and the words shown, never a token,
/// key or message. A log past [limit] becomes `Invites.previous.log`; the one before is dropped.
class InviteLog {
  InviteLog(this.file, {this.limit = 512 << 10, DateTime Function()? now}) : _now = now ?? DateTime.now;

  InviteLog.inFolder(String logs, {int limit = 512 << 10, DateTime Function()? now})
    : this(p.join(logs, fileName), limit: limit, now: now);

  static const fileName = 'Invites.log';
  static String previousFile(String file) => '${p.withoutExtension(file)}.previous.log';

  final String file;
  final int limit;
  final DateTime Function() _now;

  /// The first 12 hex digits of the id's SHA-256: the same account reads the same on both
  /// computers' logs without the id itself.
  static String hash(String? id) =>
      id == null || id.isEmpty ? '-' : sha256.convert(utf8.encode(id)).toString().substring(0, 12);

  /// An error as the log keeps it: its type, and for an AnyTogether reply its status and code.
  static Map<String, Object?> error(Object error) => {
    'error': error.runtimeType.toString(),
    if (error is TogetherProblem) ...{'status': error.status, 'code': error.code},
  };

  /// One line: the time, [event], then each field as key=value (null fields left out).
  void write(String event, [Map<String, Object?> fields = const {}]) {
    final parts = [
      _now().toIso8601String(),
      event,
      for (final entry in fields.entries)
        if (entry.value != null) '${entry.key}=${_value(entry.value!)}',
    ];
    try {
      final log = File(file);
      log.parent.createSync(recursive: true);
      if (log.existsSync() && log.lengthSync() > limit) {
        final previous = File(previousFile(file));
        if (previous.existsSync()) previous.deleteSync();
        log.renameSync(previous.path);
      }
      File(file).writeAsStringSync('${parts.join(' ')}\n', mode: FileMode.append, flush: true);
    } on FileSystemException {
      // The log is a help, never a reason to stop.
    }
  }

  static String _value(Object value) {
    final text = value.toString().replaceAll(RegExp(r'\s+'), ' ');
    return text.contains(' ') || text.contains('=') || text.isEmpty ? jsonEncode(text) : text;
  }
}
