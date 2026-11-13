import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The launcher's conformance test (anyps5-retro-host docs/protocol.md "Fixtures"): every session
/// whose `tests` includes `launcher` is played by the host repository's fake host, which the client
/// starts through its real start path as if it were the host. This test does what a launcher's UI
/// would (the calls, `input`, `shutdown`, reading frames and what the client reports) and checks
/// the outcome; the fake checks every message the client sends and writes a report.
///
/// ANYPS5_RETRO_HOST_CHECKOUT names a checkout of anyps5-retro-host that has `fixtures/v1` and
/// `tests/fake_host.py`; without it the test is skipped. Python 3 must be on PATH.
void main() {
  final checkout = Platform.environment['ANYPS5_RETRO_HOST_CHECKOUT'];
  if (checkout == null || checkout.isEmpty) {
    test('fixture sessions', () {}, skip: 'ANYPS5_RETRO_HOST_CHECKOUT is not set');
    return;
  }
  final sessions = Directory(p.join(checkout, 'fixtures', 'v1', 'sessions')).listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final python = _python();
  for (final file in sessions) {
    final session = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    if (!(session['tests']! as List).contains('launcher')) continue;
    final name = p.basenameWithoutExtension(file.path);
    final skip = _runsHere(session['os'] as String?) ? null : 'only on ${session['os']}';
    test(
      name,
      () => _Session(checkout, python, file, session).play(),
      skip: skip,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
  test('a reply with a wrong result still answers its call', () async {
    final directory = Directory.systemTemp.createTempSync('retro-host-own-');
    try {
      final session = <String, Object?>{
        'description': 'The host answers pause with true instead of null.',
        'tests': ['launcher'],
        'outcome': 'protocolError',
        'steps': [
          ..._greeting,
          {
            'from': 'launcher',
            'message': {'type': 'call', 'id': 2, 'method': 'pause', 'args': true},
            'anyValueFor': ['id'],
          },
          {
            'from': 'host',
            'message': {'type': 'reply', 'id': 2, 'result': true},
            'anyValueFor': ['id'],
            'invalid': 'pause returns null',
          },
        ],
      };
      final file = File(p.join(directory.path, 'pause-result-not-null.json'))..writeAsStringSync(jsonEncode(session));
      await _Session(checkout, python, file, session).play();
    } finally {
      directory.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
  test(
    'a call refused before it is sent leaves the next call in order',
    () => _playOwn(
      checkout,
      python,
      'A call too large to send, then a status call that must still be answered in order.',
      'clean',
      [
        {
          'from': 'launcher',
          'message': {'type': 'call', 'id': 2, 'method': 'status', 'args': null},
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'reply', 'id': 2, 'result': null},
          'anyValueFor': ['id'],
        },
      ],
      afterReady: (client) => expectLater(
        client.call('option', {'key': 'k', 'value': 'x' * 1100000}),
        throwsA(isA<RetroCallError>().having((e) => e.code, 'code', RetroCallError.argument)),
      ),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a pause with no game does not silence the rumble of the next game',
    () => _playOwn(
      checkout,
      python,
      'pause with no game loaded, then start, then rumble that must be forwarded.',
      'clean',
      [
        {
          'from': 'launcher',
          'message': {'type': 'call', 'id': 2, 'method': 'pause', 'args': true},
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'reply', 'id': 2, 'result': null},
          'anyValueFor': ['id'],
        },
        {
          'from': 'launcher',
          'message': {
            'type': 'call',
            'id': 3,
            'method': 'start',
            'args': {'core': r'${core}', 'disc': r'${disc}', 'system': r'${system}', 'saves': r'${saves}'},
          },
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {
            'type': 'reply',
            'id': 3,
            'result': {'epoch': 1},
          },
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'rumble', 'port': 0, 'strong': 1000, 'weak': 0},
        },
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) => expect(session.rumbles.any((r) => r.strong == 1000), isTrue, reason: 'rumble forwarded'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _playOwn(
  String checkout,
  String python,
  String name,
  String outcome,
  List<Map<String, Object?>> steps, {
  Future<void> Function(RetroHostClient client)? afterReady,
  void Function(_Session session)? check,
}) async {
  final directory = Directory.systemTemp.createTempSync('retro-host-own-');
  try {
    final session = <String, Object?>{
      'description': name,
      'tests': ['launcher'],
      'outcome': outcome,
      'steps': [..._greeting, ...steps],
    };
    final file = File(p.join(directory.path, 'own.json'))..writeAsStringSync(jsonEncode(session));
    await _Session(checkout, python, file, session, afterReady: afterReady, check: check).play();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

/// The start of a session: hello, welcome and the first volume call.
const _greeting = [
  {
    'from': 'launcher',
    'message': {
      'type': 'hello',
      'minVersion': 1,
      'maxVersion': 1,
      'pixelFormats': ['rgba8', 'bgra8'],
    },
    'anyValueFor': ['pixelFormats'],
  },
  {
    'from': 'host',
    'message': {
      'type': 'welcome',
      'version': 1,
      'pid': 1,
      'hostVersion': '1.0.0',
      'capabilities': ['ps1'],
      'pixelFormat': 'rgba8',
    },
    'anyValueFor': ['pid', 'hostVersion', 'pixelFormat'],
  },
  {
    'from': 'launcher',
    'message': {
      'type': 'call',
      'id': 1,
      'method': 'volume',
      'args': {'level': 1, 'muted': false},
    },
    'anyValueFor': ['id', 'args'],
  },
  {
    'from': 'host',
    'message': {'type': 'reply', 'id': 1, 'result': null},
    'anyValueFor': ['id'],
  },
];

String _python() {
  final name = Platform.isWindows ? 'python' : 'python3';
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [name]);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('$name is not on PATH');
  return path.trim();
}

bool _runsHere(String? os) => switch (os) {
  null => true,
  'windows' => Platform.isWindows,
  'posix' => !Platform.isWindows,
  'linux' => Platform.isLinux,
  'macos' => Platform.isMacOS,
  _ => false,
};

class _Session {
  _Session(this.checkout, this.python, this.file, this.session, {this.afterReady, this.check});

  /// Runs once the first `volume` call is answered, before the session's next call.
  final Future<void> Function(RetroHostClient client)? afterReady;

  /// Runs once the host has exited, before the outcome is checked.
  final void Function(_Session session)? check;
  final rumbles = <RetroRumble>[];

  final String checkout;
  final String python;
  final File file;
  final Map<String, Object?> session;
  late final Directory work;
  late final Map<String, String> paths;
  late final File resume;
  late final RetroHostClient client;
  final calls = <Future<Object?>>[];
  final frames = <RetroFrameEvent>[];
  int frameSteps = 0;

  Future<void> play() async {
    work = Directory.systemTemp.createTempSync('retro-host-session-');
    try {
      paths = _placeholders();
      final pathsFile = File(p.join(work.path, 'paths.json'))..writeAsStringSync(jsonEncode(paths));
      final report = File(p.join(work.path, 'report.json'));
      resume = File(p.join(work.path, 'resume'))..writeAsStringSync('-1');
      client = RetroHostClient.start(
        command: [
          python,
          '-I',
          p.join(checkout, 'tests', 'fake_host.py'),
          '--session',
          file.path,
          '--report',
          report.path,
          '--paths',
          pathsFile.path,
          '--resume',
          resume.path,
        ],
      );
      client.frames.listen(frames.add);
      client.rumble.listen(rumbles.add);
      unawaited(client.ready.then((_) {}, onError: (_) {}));
      await _steps(report);
      final end = await client.ended.timeout(const Duration(seconds: 40));
      await client.exited.timeout(const Duration(seconds: 20));
      check?.call(this);
      expect(end.name, session['outcome'], reason: 'outcome (${client.failureReason ?? 'no reason'})');
      // Nothing else in this test reaps children, so the host's exit code must be known: on Linux
      // that shows the client kept the host's pidfd (docs/RETRO_HOST_CLIENT.md).
      if (session['outcome'] == 'clean') expect(client.exitCode, 0, reason: 'exit code');
      await client.close();
      final result = jsonDecode(report.readAsStringSync()) as Map<String, Object?>;
      expect(result['failures'], isEmpty, reason: 'the fake host\'s report');
      expect(result['passed'], isTrue, reason: 'the fake host\'s report: $result');
    } finally {
      try {
        await client.close();
      } on Object {
        // The client was never started.
      }
      work.deleteSync(recursive: true);
    }
  }

  Map<String, String> _placeholders() {
    final made = <String, String>{};
    for (final name in ['core', 'disc', 'playlist', 'disc1', 'disc2']) {
      final extension = switch (name) {
        'core' => Platform.isWindows ? '.dll' : (Platform.isMacOS ? '.dylib' : '.so'),
        'playlist' => '.m3u',
        _ => '.cue',
      };
      made[name] = (File(p.join(work.path, '$name$extension'))..writeAsStringSync('')).absolute.path;
    }
    for (final name in ['system', 'saves']) {
      made[name] = (Directory(p.join(work.path, name))..createSync()).absolute.path;
    }
    return made;
  }

  Object? _fill(Object? value) => switch (value) {
    final String text => text.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) => paths[m[1]] ?? m[0]!),
    final Map<String, Object?> map => {for (final e in map.entries) e.key: _fill(e.value)},
    final List<Object?> list => [for (final item in list) _fill(item)],
    _ => value,
  };

  Future<void> _steps(File report) async {
    final steps = (session['steps']! as List).cast<Map<String, Object?>>();
    final clean = session['outcome'] == 'clean';
    var welcomed = false;
    var shutdown = false;
    Future<RetroStatus?>? stopping;
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      if (step['invalid'] != null && step['from'] == 'host') {
        await Future.wait([for (final pending in calls) pending.then((_) {}, onError: (_) {})])
            .timeout(const Duration(seconds: 15), onTimeout: () => fail('a call was never answered'));
        return;
      }
      final message = step['message'] as Map<String, Object?>?;
      final from = step['from'];
      if (from == 'launcher' && message != null) {
        switch (message['type']) {
          case 'call':
            final method = message['method']! as String;
            if (method == 'volume' && !welcomed) {
              welcomed = true;
              calls.add(
                client.ready.then((_) async {
                  await afterReady?.call(client);
                  return null;
                }),
              );
            } else if (method == 'stop') {
              stopping = client.stopGame();
              calls.add(Future.value());
            } else if (method == 'status' && stopping != null) {
              final stopped = stopping;
              stopping = null;
              calls.add(stopped.then((status) => status?.toJson()));
            } else {
              calls.add(client.call(method, _fill(message['args'])));
            }
          case 'input':
            client.input(
              message['port']! as int,
              message['buttons']! as int,
              leftX: message['leftX']! as int,
              leftY: message['leftY']! as int,
              rightX: message['rightX']! as int,
              rightY: message['rightY']! as int,
            );
          case 'shutdown':
            shutdown = true;
            client.shutdown();
        }
      } else if (from == 'host' && message != null) {
        switch (message['type']) {
          case 'reply':
            final pending = calls.removeAt(0);
            await _checkReply(pending, message, step['anyValueFor'] as List<Object?>?);
          case 'frame':
            frameSteps++;
            await _until(() => frames.length >= frameSteps, 'frame $frameSteps');
          case 'welcome' || 'unsupported':
            break;
        }
      } else if (step.containsKey('launcherDraws')) {
        await _until(() => frames.length >= frameSteps, 'frame $frameSteps');
        expect(frames[frameSteps - 1].drawn, step['launcherDraws'], reason: 'step $index launcherDraws');
        await _resume(index, report);
      } else if (step.containsKey('launcherReports')) {
        if (!clean) await client.ended.timeout(const Duration(seconds: 30));
        final expected = step['launcherReports']! as Map<String, Object?>;
        final method = expected['method']! as String;
        if (method == 'status') {
          final status = await client.status();
          expect(status?.toFailureJson(), expected['result'], reason: 'step $index launcherReports');
        } else {
          expect(await client.call(method), expected['result'], reason: 'step $index launcherReports');
        }
        await _resume(index, report);
      }
    }
    if (clean && !shutdown) client.shutdown();
  }

  /// Lets the fake host go on past the step at [index], where `--resume` holds it, and waits until
  /// its report shows it has (or it has exited), so the next message the client sends meets the
  /// next step.
  Future<void> _resume(int index, File report) async {
    resume.writeAsStringSync('$index');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (client.exitCode != null) return;
      try {
        final step = (jsonDecode(report.readAsStringSync()) as Map<String, Object?>)['step'];
        if (step is int && step > index) return;
      } on FormatException {
        // The fake is rewriting the report.
      } on FileSystemException {
        // Not written yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('the fake host did not go past step $index');
  }

  Future<void> _checkReply(Future<Object?> pending, Map<String, Object?> reply, List<Object?>? anyValueFor) async {
    final ignore = {for (final key in anyValueFor ?? const []) key as String};
    if (reply.containsKey('error')) {
      final expected = reply['error']! as Map<String, Object?>;
      await expectLater(pending, throwsA(isA<RetroCallError>().having((e) => e.code, 'code', expected['code'])));
      return;
    }
    final Object? result;
    try {
      result = await pending.timeout(const Duration(seconds: 10));
    } on RetroHostGone {
      return;
    }
    if (ignore.contains('result')) return;
    _compare(reply['result'], result, ignore, 'result');
  }

  void _compare(Object? expected, Object? actual, Set<String> ignore, String where) {
    if (ignore.contains(where)) return;
    if (expected is Map<String, Object?> && actual is Map<String, Object?>) {
      for (final key in expected.keys) {
        if (ignore.contains('$where.$key')) continue;
        expect(actual.containsKey(key), isTrue, reason: '$where.$key is missing');
        _compare(expected[key], actual[key], ignore, '$where.$key');
      }
      return;
    }
    expect(actual, _fill(expected), reason: where);
  }

  Future<void> _until(bool Function() done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
      if (await client.ended.then((_) => true).timeout(const Duration(milliseconds: 20), onTimeout: () => false)) {
        if (!done()) fail('the connection ended while waiting for $what');
      }
    }
  }
}
