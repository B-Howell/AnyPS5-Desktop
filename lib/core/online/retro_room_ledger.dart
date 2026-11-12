import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../together/account.dart';
import 'online_peer.dart';

typedef RetroRoomRecord = ({String id, String user, bool hosted});

/// The PS1, PS2 and PS3 rooms each launcher run created or joined and has not left, kept on
/// disk. A room is ended by leaving it, which a launcher closed by force or a crash never does,
/// and the service keeps such a room open; a later run ends what a run that is gone left
/// ([endEarlier]).
///
/// Each run writes only its own file, `<run>.json` in [folder], and holds an exclusive lock on
/// `<run>.lock` from its first record until it exits; the system lets go of the lock when the
/// process ends, however it ends. Another run's records are read and ended only while holding
/// that run's lock, so a launcher still running keeps its rooms and two launchers never end the
/// same run's rooms at once.
final class RetroRoomLedger {
  RetroRoomLedger(this.folder, {String? run}) : run = run ?? _newRun();

  final Directory folder;

  /// This run's name: its record and lock files'.
  final String run;

  RandomAccessFile? _lock;
  Future<void> _sweeping = Future.value();
  final _records = <RetroRoomRecord>[];

  /// Rooms with an end or leave sent and not yet answered: not joined, nor sent another, until
  /// it is.
  final _unresolved = <String>{};

  /// The runs that are gone whose locks this run holds while ending their rooms.
  final _sweepLocks = <String>{};

  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);
  static final _runName = RegExp(r'^[0-9a-f]{16}$');

  /// How long a sweep waits for the service about each room before going on to the next.
  static const callDeadline = Duration(seconds: 6);

  static String _newRun() {
    final random = Random.secure();
    return [for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  File _recordsOf(String run) => File(p.join(folder.path, '$run.json'));

  File _lockOf(String run) => File(p.join(folder.path, '$run.lock'));

  void add(String id, {required String user, required bool hosted}) {
    _holdLock();
    _records
      ..removeWhere((record) => record.id == id)
      ..add((id: id, user: user, hosted: hosted));
    _save(run, _records);
  }

  void remove(String id) {
    final before = _records.length;
    _records.removeWhere((record) => record.id == id);
    if (_records.length != before) _save(run, _records);
  }

  /// Whether an end or leave for room [id] is still on its way: joining it now could be undone.
  bool unresolved(String id) => _unresolved.contains(id);

  /// Whether a launcher run still going, this one or another, recorded room [id].
  bool liveOwned(String id) {
    if (_records.any((record) => record.id == id)) return true;
    for (final other in _otherRuns()) {
      if (_read(other).any((record) => record.id == id) && !_gone(other)) return true;
    }
    return false;
  }

  /// Lets go of this run's lock: its records may now be ended by another run.
  void close() {
    try {
      _lock?.closeSync();
    } on FileSystemException {
      // The system lets go of it when the process ends.
    }
    _lock = null;
  }

  /// Ends (as host) or leaves (as guest) each room [user] was in under a run that is gone, one
  /// sweep at a time. A room is forgotten once it was ended or the service says it is gone; one
  /// the service could not be asked about, or refused for another reason, stays for next time.
  Future<void> endEarlier(
    String user,
    OnlineCall call, {
    void Function(String event, Map<String, Object?> fields)? trace,
  }) {
    final sweep = _sweeping.then((_) => _endEarlier(user, call, trace));
    _sweeping = sweep.catchError((Object _) {});
    return sweep;
  }

  Future<void> _endEarlier(
    String user,
    OnlineCall call,
    void Function(String event, Map<String, Object?> fields)? trace,
  ) async {
    for (final other in _otherRuns()) {
      final lock = _take(other);
      if (lock == null) continue;
      _sweepLocks.add(other);
      try {
        final records = _read(other);
        final kept = <RetroRoomRecord>[];
        for (final record in records) {
          if (record.user != user || !await _end(record, call, trace)) kept.add(record);
        }
        _save(other, kept);
      } finally {
        _sweepLocks.remove(other);
        try {
          lock.closeSync();
          final temp = File('${_recordsOf(other).path}.tmp');
          if (temp.existsSync()) temp.deleteSync();
          if (!_recordsOf(other).existsSync()) _lockOf(other).deleteSync();
        } on FileSystemException {
          // Tried again next time.
        }
      }
    }
  }

  /// Ends or leaves [record]'s room; whether it is gone now.
  Future<bool> _end(
    RetroRoomRecord record,
    OnlineCall call,
    void Function(String event, Map<String, Object?> fields)? trace,
  ) async {
    if (unresolved(record.id)) {
      trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': 'still-waiting'});
      return false;
    }
    final path = 'game-sessions/${record.id}';
    _unresolved.add(record.id);
    final request = call(record.hosted ? 'DELETE' : 'POST', record.hosted ? path : '$path/leave');
    unawaited(request.then<void>((_) {}, onError: (Object _) {}).whenComplete(() => _unresolved.remove(record.id)));
    Object result;
    var gone = false;
    try {
      await request.timeout(callDeadline);
      result = 'ok';
      gone = true;
    } on TogetherProblem catch (problem) {
      result = problem.status;
      gone = isGone(problem);
    } on TimeoutException {
      result = 'no-answer';
    } on Object {
      result = 'unreachable';
    }
    trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': result});
    return gone;
  }

  /// Whether the service's answer says the room is no longer there to end or leave.
  static bool isGone(TogetherProblem problem) => problem.status == 404 || problem.status == 410;

  /// When the room with [id] was created, read from its UUIDv7 ID; null for another kind of ID.
  static DateTime? createdAt(String id) {
    if (!_uuid.hasMatch(id) || id[14] != '7') return null;
    return DateTime.fromMillisecondsSinceEpoch(int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16));
  }

  Iterable<String> _otherRuns() {
    try {
      if (!folder.existsSync()) return const [];
      return {
        for (final entry in folder.listSync().whereType<File>())
          if (p.extension(entry.path) == '.json' || p.extension(entry.path) == '.lock')
            p.basenameWithoutExtension(entry.path),
      }.where((name) => name != run && _runName.hasMatch(name)).toList();
    } on FileSystemException {
      return const [];
    }
  }

  void _holdLock() {
    if (_lock != null) return;
    try {
      folder.createSync(recursive: true);
      _lock = _lockOf(run).openSync(mode: FileMode.write)..lockSync(FileLock.exclusive);
    } on FileSystemException {
      _lock = null;
    }
  }

  /// [other]'s lock, taken here, when that run has ended; null while it still runs.
  RandomAccessFile? _take(String other) {
    RandomAccessFile? opened;
    try {
      opened = _lockOf(other).openSync(mode: FileMode.append);
      opened.lockSync(FileLock.exclusive);
      return opened;
    } on FileSystemException {
      opened?.closeSync();
      return null;
    }
  }

  bool _gone(String other) {
    if (_sweepLocks.contains(other)) return false;
    final lock = _take(other);
    lock?.closeSync();
    return lock != null;
  }

  List<RetroRoomRecord> _read(String run) {
    try {
      final json = jsonDecode(_recordsOf(run).readAsStringSync());
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

  void _save(String run, List<RetroRoomRecord> records) {
    final file = _recordsOf(run);
    try {
      if (records.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      folder.createSync(recursive: true);
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
