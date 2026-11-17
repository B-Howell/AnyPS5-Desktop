import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/game_action.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:anyps5_desktop/ui/platform_chip.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/ui_support.dart';

/// A PS4 dump in the library: shown with its name and a PS4 chip, and never unlocked while the
/// engine does not run PS4 games, with the reason said instead of a made-up start.
void main() {
  late Fixture fixture;
  late AppModel model;
  late Game game;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    makePs4Dump(model.root!, 'ANPS40001');
    model.rescan();
    game = model.games.singleWhere((found) => found.titleId == 'ANPS40001');
  });

  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  test('a PS4 game is listed but not playable yet, and its button says why', () async {
    expect(game.platform, DumpPlatform.ps4);
    expect(model.stateOf(game), isA<NotPlayableYet>());
    expect(GameAction.of(model.stateOf(game)).title, T.text('notPlayableYet'));
    model.primaryAction(game);
    expect(model.toast, T.format('notPlayableYetDetail', ['PS4']));
    expect(model.queue, isNot(contains(game.id)));
    expect(model.progress.containsKey(game.id), isFalse);
    model.unlock(game);
    expect(model.queue, isNot(contains(game.id)));
  });

  testWidgets('its tile carries the PS4 chip; a PS5 tile has none', (tester) async {
    final ps5 = model.games.firstWhere((found) => found.platform == DumpPlatform.ps5 && found.retro == null);
    for (final (shown, chips) in [(game, 1), (ps5, 0)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 200,
              child: GameTile(model: model, game: shown, size: 200, focused: false),
            ),
          ),
        ),
      );
      expect(find.byType(PlatformChip), findsNWidgets(chips));
      if (chips == 1) expect(find.text('PS4'), findsOneWidget);
    }
  });
}
