import 'dart:io';

import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/invite_log.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// The invite log on both sides: what arrived and what was shown on the friend's launcher, and
/// why a send stopped on the host's, each with a toast the player sees.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  const friendId = '12345678-1234-4234-8234-123456789ab2';
  const roomId = '12345678-1234-4234-8234-123456789abc';

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  List<String> lines() {
    final file = File(model.together.inviteLog.file);
    return file.existsSync() ? file.readAsLinesSync() : const [];
  }

  Future<void> signIn() async {
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.socket.status.name == 'ready');
  }

  setUp(() async {
    server = await FakeTogether.start();
    server.friend(friendId, 'remote', 'Remote', presence: {'state': 'online'});
    fixture = makeFixture(together: server.base, environment: {'ANYPS5_PS1_NETPLAY': '1'});
    model = fixture.model;
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    fixture.dispose();
  });

  test('the log is in the launcher logs folder', () {
    expect(model.together.inviteLog.file, endsWith(InviteLog.fileName));
    expect(File(model.together.inviteLog.file).parent.path, model.paths.logs);
  });

  test('a received invite logs the event, then the toast and where it can be answered', () async {
    await signIn();
    final invite = {
      'sessionId': roomId,
      'from': FakeTogether.card(friendId, 'remote', 'Remote'),
      'titleId': 'SCUS94426',
      'gameVersion': '8',
      'engineBuild': 'anyps5-ps1-netplay-v1',
    };
    server.gameInvites.add(invite);
    server.push('game_session.invite', invite);
    await until(() => lines().any((line) => line.contains(' invite.shown ')));
    final event = lines().singleWhere((line) => line.contains(' event '));
    expect(event, contains('type=game_session.invite'));
    expect(event, contains('session=$roomId'));
    expect(event, contains('from=${InviteLog.hash(friendId)}'));
    expect(event, contains('mode=8'));
    expect(event, isNot(contains(friendId)));
    final shown = lines().singleWhere((line) => line.contains(' invite.shown '));
    expect(shown, contains('toast=gameInvitedYou '));
    expect(shown, contains('row=friends'));
    expect(shown, contains('notice='));
    expect(model.toast, isNotNull);
    expect(shown, contains(model.toast!.split(' ').first));
  });

  test('every game_session event is logged as it arrives', () async {
    await signIn();
    server.push('game_session.ended', {'sessionId': roomId});
    await until(() => lines().any((line) => line.contains('type=game_session.ended')));
    expect(lines().single, contains('session=$roomId'));
  });

  test('a send that cannot start says so and logs why', () async {
    await model.together.joinPs1Netplay(
      const GameInvite(sessionId: roomId, titleId: 'SCUS94426', gameVersion: '7', engineBuild: 'anyps5-ps1-netplay-v1'),
    );
    final logged = lines();
    if (!model.embeddedOnlineRetroAvailable) {
      expect(model.toast, isNotNull);
      return;
    }
    expect(logged.where((line) => line.contains(' join.chosen ')).single, contains('room=$roomId'));
    expect(logged.where((line) => line.contains(' send.stopped ')).single, contains('reason=unavailable'));
    expect(model.toast, T.text('ps1OnlineUnavailable'));
  });
}
