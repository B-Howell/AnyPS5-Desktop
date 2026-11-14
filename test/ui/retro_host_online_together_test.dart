import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/online/ps1_file_digests.dart';
import 'package:anyps5_desktop/core/online/ps1_lockstep_media.dart';
import 'package:anyps5_desktop/core/online/ps1_lockstep_rooms.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ps1_launcher.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _ana = '22222222-2222-4222-8222-222222222222';
const _ben = '66666666-6666-4666-8666-666666666666';
const _room = '33333333-3333-4333-8333-333333333333';

/// The game's lobby signed in to AnyTogether (lib/ui/retro_host_online.dart): friends to invite, a
/// friend invited through a private room for the disc, a friend's PS1 invite in Friends and as a
/// notice, and the friend's launcher finding the disc by its tracks and starting its host muted. No
/// widget test is in this file. The game's keyboard needs Flutter's binding, whose test binding
/// answers every HTTP call with a 400, so its stand-in for HTTP is taken away again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Ps1Launcher launcher;
  FakeTogether? server;

  tearDown(() async {
    T.language = Language.english;
    launcher.dispose();
    await server?.close();
    server = null;
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// The launcher's disc made a data disc: its cue sheet and one track of [bytes] bytes.
  String track(int bytes) {
    File(launcher.disc)
        .writeAsStringSync(['FILE "game.bin" BINARY', '  TRACK 01 MODE2/2352', '    INDEX 01 00:00:00', ''].join('\n'));
    return (File(p.join(p.dirname(launcher.disc), 'game.bin'))..writeAsBytesSync(List.filled(bytes, 5))).path;
  }

  /// Signed in to AnyTogether with Ana and Ben online and Cleo offline; no game plays.
  Future<void> signedIn({void Function(FakeTogether)? serve}) async {
    final fake = server = await FakeTogether.start();
    fake.me = {'id': _me, 'handle': 'player1', 'displayName': 'Player One'};
    fake.friend(_ana, 'ana', 'Ana', presence: {'state': 'online'});
    fake.friend(_ben, 'ben', 'Ben', presence: {'state': 'online'});
    fake.friend('77777777-7777-4777-8777-777777777777', 'cleo', 'Cleo');
    serve?.call(fake);
    launcher = Ps1Launcher(together: fake.base);
    final model = launcher.model;
    model.setRetroHostPs1(true);
    model.together.email = 'player1@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.connected && model.together.hub.friends.friends.length == 3);
  }

  /// The game plays; with [friends], the player is signed in to AnyTogether with Ana and Ben
  /// online and Cleo offline.
  Future<void> playing({bool friends = false, void Function(FakeTogether)? serve}) async {
    if (friends) {
      final fake = server = await FakeTogether.start();
      fake.me = {'id': _me, 'handle': 'player1', 'displayName': 'Player One'};
      fake.friend(_ana, 'ana', 'Ana', presence: {'state': 'online'});
      fake.friend(_ben, 'ben', 'Ben', presence: {'state': 'online'});
      fake.friend('77777777-7777-4777-8777-777777777777', 'cleo', 'Cleo');
      serve?.call(fake);
    }
    launcher = Ps1Launcher(together: server?.base);
    final model = launcher.model;
    model.setRetroHostPs1(true);
    await launcher.start();
    if (friends) {
      model.together.email = 'player1@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.connected && model.together.hub.friends.friends.length == 3);
    }
    await launcher.play.host.refresh();
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
  }

  void openLobby() {
    launcher.model.openRetroMenu();
    final row = launcher.row('players');
    expect(row.title, T.text('coopLobbyTitle'));
    (row.kind as ActionRow).run();
  }

  List<PanelRow> lobby() => launcher.model.panelCategories().single.rows;

  test('signed in, the friends online now are offered; an old host is said to be one', () async {
    await playing(friends: true);
    openLobby();
    expect(
      [for (final row in lobby()) row.id],
      ['coop-players', 'coop-invite-$_ana', 'coop-invite-$_ben', 'coop-back-to-game'],
    );
    expect(lobby().first.playerSlots[1].status, T.text('coopInviteSeat'));
    launcher.session.canLockstep = false;
    expect((lobby()[1].kind as InfoRow).text, T.text('retroOnlineHostOldDetail'));
  });

  test('inviting a friend makes a private room for the disc, invites them and shows them as invited', () async {
    Map<String, dynamic>? made;
    final invited = <Object?>[];
    var ended = false;
    Map<String, dynamic> room(Map<String, dynamic> body) => {
      'id': _room,
      ...body,
      'host': {'userId': _me},
      'endedAt': null,
      'members': [
        {
          'userId': _me,
          'device': null,
          'properties': {'protocol': Ps1LockstepRooms.protocol},
        },
      ],
    };
    await playing(
      friends: true,
      serve: (fake) => fake.handlers.add((call) {
        switch ((call.method, call.path)) {
          case ('POST', 'game-sessions') when call.body['engineBuild'] == Ps1LockstepRooms.protocol:
            made = call.body;
            return (201, room(call.body));
          case ('PUT', 'game-sessions/$_room/members/me') || ('GET', 'game-sessions/$_room'):
            return (200, room(made!));
          case ('POST', 'game-sessions/$_room/invites'):
            invited.add(call.body['userIds']);
            return (204, null);
          case ('DELETE', 'game-sessions/$_room'):
            ended = true;
            return (204, null);
        }
        return null;
      }),
    );
    track(4096);
    openLobby();
    final invite = lobby().singleWhere((row) => row.id == 'coop-invite-$_ana');
    expect(invite.title, T.format('partyInvite', ['Ana']));
    (invite.kind as ActionRow).run();
    await until(() => invited.isNotEmpty);
    expect(made?['properties'], {
      'protocol': 'anyps5-ps1-lockstep-v2',
      'discSha256': matches(RegExp(r'^[0-9a-f]{64}$')),
      'discBytes': 4096,
    });
    expect(made?['capacity'], 2);
    expect(made?['joinable'], isFalse);
    expect(invited.single, [_ana]);
    await until(() => launcher.model.retroOnline?.step == RetroOnlineStep.invited);
    final ana = lobby().first.playerSlots[1];
    expect(ana.name, 'Ana');
    expect(ana.status, '${T.text('coopController2')} · ${T.text('coopInvited')}');

    (lobby()[1].kind as ActionRow).run();
    await until(() => launcher.model.retroOnline == null);
    expect(ended, isTrue, reason: 'the room is ended when the invite is cancelled');
    expect(lobby()[1].id, 'coop-invite-$_ana');
  });

  test("a friend's PS1 invite shows in Friends as an online game to join", () async {
    await playing(
      friends: true,
      serve: (fake) => fake.gameInvites.add({
        'sessionId': _room,
        'titleId': 'PS1-ABABABABABABABAB',
        'gameVersion': '1',
        'engineBuild': Ps1LockstepRooms.protocol,
        'from': FakeTogether.card(_ana, 'ana', 'Ana'),
      }),
    );
    await until(() => launcher.model.together.hub.games.invites.isNotEmpty);
    final row = launcher.model.together.gameRows().singleWhere((row) => row.id == 'game-accept-$_room');
    expect(row.title, T.format('retroOnlineJoin', ['Ana']));
    expect(row.detail, T.text('retroOnlineJoinDetail'));
  });

  test("a friend's PS1 invite is a notice; joining finds the disc by its tracks, once, and starts muted", () async {
    late String digest;
    late int bytes;
    Map<String, dynamic> room() => {
      'id': _room,
      'kind': 'online',
      'titleId': Ps1LockstepRooms.titleFor(digest),
      'gameVersion': Ps1LockstepRooms.gameVersion,
      'engineBuild': Ps1LockstepRooms.protocol,
      'capacity': 2,
      'joinable': false,
      'endedAt': null,
      'host': {'userId': _ana},
      'properties': {'protocol': Ps1LockstepRooms.protocol, 'discSha256': digest, 'discBytes': bytes},
      'members': const [],
    };
    final joins = <Object?>[];
    await signedIn(
      serve: (fake) => fake.handlers.add((call) {
        switch ((call.method, call.path)) {
          case ('GET', 'game-sessions/$_room'):
            return (200, room());
          case ('POST', 'game-sessions/$_room/join'):
            joins.add(call.body);
            return (404, {'status': 404, 'code': 'not_found', 'title': 'The game ended'});
        }
        return null;
      }),
    );
    final bin = track(8192);
    bytes = 8192;
    digest = Ps1LockstepMedia.discDigestOf(GameLibrary.discFiles(launcher.disc), {bin: Ps1FileDigests.fileDigest(bin)});
    final model = launcher.model;
    Map<String, Object?> invite() => {
      'sessionId': _room,
      'titleId': Ps1LockstepRooms.titleFor(digest),
      'gameVersion': Ps1LockstepRooms.gameVersion,
      'engineBuild': Ps1LockstepRooms.protocol,
      'from': FakeTogether.card(_ana, 'ana', 'Ana'),
    };

    server!.push('game_session.invite', invite());
    await until(() => model.together.hub.games.invites.isNotEmpty);
    expect(model.toast, T.format('retroOnlineJoin', ['Ana']), reason: 'no disc here is known to be it yet');

    final joining = model.joinRetroOnline(model.together.hub.games.invites.single);
    await until(() => launcher.opened.isNotEmpty);
    expect(launcher.opened.single.$3, isTrue, reason: "the friend's host starts muted");
    launcher.session.readyCompleter.complete();
    await joining;
    expect(joins, hasLength(1), reason: 'the disc in the library was found by its tracks and the room joined');
    expect(launcher.session.shutdownAsked, isTrue, reason: 'the host opened for the match is let go');
    expect(model.retroOnline, isNull);
    expect(Ps1FileDigests(model.paths.retroDigests).knownNow([bin]), {
      bin: Ps1FileDigests.fileDigest(bin),
    }, reason: 'the disc is not read again for the next invite');

    server!.push('game_session.invite', {...invite()});
    await until(() => model.toast == T.format('gameInvitedYou', ['Ana', 'Night Racer']));
  });
}
