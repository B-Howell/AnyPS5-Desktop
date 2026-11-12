import 'dart:convert';
import 'dart:io';

import '../together/account.dart';
import 'online_peer.dart';

typedef RetroRoomRecord = ({String id, String user, bool hosted});

/// The PS1, PS2 and PS3 rooms this launcher created or joined and has not left, kept on disk.
/// A room is ended by leaving it, which a launcher closed by force or a crash never does, and the
/// service keeps such a room open; the next run ends the ones an earlier run left
/// ([endEarlier]).
final class RetroRoomLedger {
  RetroRoomLedger(this.file, {DateTime? started}) : started = started ?? DateTime.now();

  final File file;

  /// When this run began: a room made before it was made by an earlier run or another device.
  final DateTime started;

  /// The rooms recorded by this run: their own match leaves them.
  final _thisRun = <String>{};

  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);

  void add(RetroRoomRecord record) {
    _thisRun.add(record.id);
    _write([..._read().where((kept) => kept.id != record.id), record]);
  }

  void remove(String id) {
    _thisRun.remove(id);
    final records = _read();
    if (records.any((kept) => kept.id == id)) _write(records.where((kept) => kept.id != id).toList());
  }

  /// What an earlier run of this launcher recorded for [user] and never saw end.
  List<RetroRoomRecord> earlier(String user) => [
    for (final record in _read())
      if (record.user == user && !_thisRun.contains(record.id)) record,
  ];

  /// Ends (as host) or leaves (as guest) each room of [earlier], forgetting the ones the service
  /// says are gone already. A room the service could not be reached about stays for next time.
  Future<void> endEarlier(
    String user,
    OnlineCall call, {
    void Function(String event, Map<String, Object?> fields)? trace,
  }) async {
    for (final record in earlier(user)) {
      final path = 'game-sessions/${record.id}';
      try {
        await call(record.hosted ? 'DELETE' : 'POST', record.hosted ? path : '$path/leave');
        trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': 'ok'});
      } on TogetherProblem catch (problem) {
        trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': problem.status});
        if (problem.status < 400 || problem.status >= 500) continue;
      } on Object {
        continue;
      }
      remove(record.id);
    }
  }

  /// When the room with [id] was created, read from its UUIDv7 ID; null for another kind of ID.
  static DateTime? createdAt(String id) {
    if (!_uuid.hasMatch(id) || id[14] != '7') return null;
    return DateTime.fromMillisecondsSinceEpoch(int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16));
  }

  List<RetroRoomRecord> _read() {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! List) return [];
      return [
        for (final entry in json)
          if (entry is Map &&
              entry['id'] is String &&
              _uuid.hasMatch(entry['id'] as String) &&
              entry['user'] is String &&
              entry['hosted'] is bool)
            (id: entry['id'] as String, user: entry['user'] as String, hosted: entry['hosted'] as bool),
      ];
    } on Object {
      return [];
    }
  }

  void _write(List<RetroRoomRecord> records) {
    try {
      if (records.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.tmp')
        ..writeAsStringSync(
          jsonEncode([
            for (final record in records) {'id': record.id, 'user': record.user, 'hosted': record.hosted},
          ]),
          flush: true,
        );
      temp.renameSync(file.path);
    } on FileSystemException {
      // The room still ends when its match leaves it; only the recovery after a crash is lost.
    }
  }
}
