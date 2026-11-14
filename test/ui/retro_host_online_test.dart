import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ps1_launcher.dart';
import '../support/ui_support.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _ana = '22222222-2222-4222-8222-222222222222';
const _ben = '66666666-6666-4666-8666-666666666666';

/// The game's lobby in the host's menu (lib/ui/retro_host_online.dart) as it looks: Player 1 to 4
/// with the Multitap's seats said to be off, signed out and with a friend invited. The lobby signed
/// in to AnyTogether is in retro_host_online_together_test.dart, since widget tests answer every
/// HTTP call with 400.
void main() {
  late Ps1Launcher launcher;
  FakeTogether? server;
  final shell = find.byType(LauncherShell);

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

  /// The game plays; with [friends], the player is signed in to AnyTogether with Ana and Ben
  /// online and Cleo offline.
  Future<void> playing({bool friends = false, void Function(FakeTogether)? serve}) async {
    if (friends) {
      final fake = server = await FakeTogether.start();
      fake.me = {'id': _me, 'handle': 'brett', 'displayName': 'Brett'};
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
      model.together.email = 'brett@example.com';
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

  void expectMultitapSeats(List<PlayerSlot> slots) {
    expect([for (final slot in slots) slot.player], [1, 2, 3, 4]);
    for (final slot in slots.skip(2)) {
      expect(slot.available, isFalse);
      expect(slot.name, T.text('coopTwoPlayers'));
      expect(slot.status, T.text('retroLobbyMultitap'));
    }
  }

  testWidgets("the lobby signed out: four seats, the Multitap's two said to be off, and why no friend", (tester) async {
    await tester.runAsync(() => playing());
    await pumpLauncher(tester, launcher.model);
    openLobby();
    await settle(tester);
    await settle(tester);
    final slots = lobby().first.playerSlots;
    expectMultitapSeats(slots);
    expect(slots[0].you, isTrue);
    expect(launcher.model.panelRow, 2, reason: 'on Back to game, the first row that can be chosen');
    expect(slots[1].name, isNull);
    expect(slots[1].status, T.text('retroLobbySecondController'));
    expect(lobby()[1].id, 'coop-unavailable');
    expect((lobby()[1].kind as InfoRow).text, T.text('retroOnlineSignInDetail'));
    expect(find.text(T.text('retroLobbyMultitap')), findsNWidgets(2));
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_lobby_en.png'));

    launcher.play.controls.seats.sync(['pad-1', 'pad-2']);
    final couch = lobby().first.playerSlots;
    expect(couch[1].name, T.text('coopGuest'));
    expect(couch[1].status, startsWith(T.text('coopController2')));
  });

  testWidgets('the lobby with a friend invited: Player 2 is theirs, and the invite can be cancelled', (tester) async {
    await tester.runAsync(() => playing());
    await pumpLauncher(tester, launcher.model);
    launcher.model.retroOnline = RetroOnline(hosting: true, friendId: _ana, friendName: 'Ana')
      ..step = RetroOnlineStep.invited;
    openLobby();
    await settle(tester);
    final slots = lobby().first.playerSlots;
    expectMultitapSeats(slots);
    expect(slots[1].name, 'Ana');
    expect(slots[1].status, '${T.text('coopController2')} · ${T.text('coopInvited')}');
    expect(lobby()[1].id, 'coop-leave');
    expect(lobby()[1].title, T.text('ps1OnlineCancel'));
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_lobby_invited_en.png'));
    launcher.model.retroOnline = null;
  });
}
