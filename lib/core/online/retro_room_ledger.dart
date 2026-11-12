import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../together/account.dart';
import 'online_peer.dart';

typedef RetroRoomRecord = ({String id, String user, bool hosted, String run});

/// The PS1, PS2 and PS3 rooms launchers created or joined and have not left, kept on disk.
/// A room is ended by leaving it, which a launcher closed by force or a crash never does, and the
/// service keeps such a room open; a later run ends the ones a run that is gone left
/// ([endEarlier]).
///
/// Each run holds a lock on its own file in the ledger's folder from its first record until it
/// exits; the system lets go of it when the process ends, however it ends. A record is ended only
/// when its run's lock can be taken, so a launcher still running beside this one keeps its rooms.
final class RetroRoomLedger {
  RetroRoomLedger(this.file, {DateTime? started, String? run})
    : started = started ?? DateTime.now(),
      run = run ?? _newRun();

  final File file;

  /// When this run began: a room made before it was made by an earlier run or another device.
  final DateTime started;

  /// This run's name in the records and its lock file's.
  final String run;

  RandomAccessFile? _lock;
  Future<void> _sweeping = Future.value();

  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);
  static final _runName = RegExp(r'^[0-9a-f]{16}$');

  /// How long the service is given for each room it is asked to end.
  static const callDeadline = Duration(seconds: 6);

  static String _newRun() {
    final random = Random.secure();
    return [for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  Directory get _locks => Directory(p.join(file.parent.path, 'retro-room-runs'));

  File _lockOf(String run) => File(p.join(_locks.path, '$run.lock'));

  void add(String id, {required String user, required bool hosted}) {
    _holdLock();
    _write([..._read().where((kept) => kept.id != id), (id: id, user: user, hosted: hosted, run: run)]);
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

  void remove(String id) {
    final records = _read();
    if (records.any((kept) => kept.id == id)) _write(records.where((kept) => kept.id != id).toList());
  }

  /// The rooms recorded for [user] by runs that are gone.
  List<RetroRoomRecord> earlier(String user) => [
    for (final record in _read())
      if (record.user == user && record.run != run && _gone(record.run)) record,
  ];

  /// Ends (as host) or leaves (as guest) each room of [earlier], one sweep at a time, forgetting
  /// the ones the service ended or says are gone. A room the service could not be asked about,
  /// or refused for another reason, stays for next time.
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
    for (final record in earlier(user)) {
      if (!_stillEarlier(record)) continue;
      final path = 'game-sessions/${record.id}';
      Object result;
      try {
        await call(record.hosted ? 'DELETE' : 'POST', record.hosted ? path : '$path/leave').timeout(callDeadline);
        result = 'ok';
      } on TogetherProblem catch (problem) {
        result = problem.status;
        if (!isGone(problem)) {
          trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': result});
          continue;
        }
      } on Object {
        trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': 'unreachable'});
        continue;
      }
      trace?.call('room.recorded', {'room': record.id, 'hosted': record.hosted, 'result': result});
      if (_stillEarlier(record)) remove(record.id);
    }
    _forgetDeadRuns();
  }

  /// Whether the service's answer says the room is no longer there to end or leave.
  static bool isGone(TogetherProblem problem) => problem.status == 404 || problem.status == 410;

  /// When the room with [id] was created, read from its UUIDv7 ID; null for another kind of ID.
  static DateTime? createdAt(String id) {
    if (!_uuid.hasMatch(id) || id[14] != '7') return null;
    return DateTime.fromMillisecondsSinceEpoch(int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16));
  }

  /// The same record is still on disk: this run did not take the room up again meanwhile.
  bool _stillEarlier(RetroRoomRecord record) => _read().contains(record);

  void _holdLock() {
    if (_lock != null) return;
    try {
      _locks.createSync(recursive: true);
      _lock = _lockOf(run).openSync(mode: FileMode.write)..lockSync(FileLock.exclusive);
    } on FileSystemException {
      _lock = null;
    }
  }

  /// Whether the run named [other] has ended: its lock file is missing or can be locked here.
  bool _gone(String other) {
    final lock = _lockOf(other);
    if (!lock.existsSync()) return true;
    RandomAccessFile? opened;
    try {
      opened = lock.openSync(mode: FileMode.append);
      opened.lockSync(FileLock.exclusive);
      opened.unlockSync();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      opened?.closeSync();
    }
  }

  void _forgetDeadRuns() {
    try {
      if (!_locks.existsSync()) return;
      final recorded = {for (final record in _read()) record.run};
      for (final entry in _locks.listSync().whereType<File>()) {
        final name = p.basenameWithoutExtension(entry.path);
        if (name == run || recorded.contains(name) || !_gone(name)) continue;
        entry.deleteSync();
      }
    } on FileSystemException {
      // A lock file left behind is retried next time.
    }
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
              entry['hosted'] is bool &&
              entry['run'] is String &&
              _runName.hasMatch(entry['run'] as String))
            (
              id: entry['id'] as String,
              user: entry['user'] as String,
              hosted: entry['hosted'] as bool,
              run: entry['run'] as String,
            ),
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
      final temp = File('${file.path}.$run.tmp')
        ..writeAsStringSync(
          jsonEncode([
            for (final record in records)
              {'id': record.id, 'user': record.user, 'hosted': record.hosted, 'run': record.run},
          ]),
          flush: true,
        );
      temp.renameSync(file.path);
    } on FileSystemException {
      // The room still ends when its match leaves it; only the recovery after a crash is lost.
    }
  }
}
