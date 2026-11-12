import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/online_fakes.dart' show eventually;
import '../support/ui_support.dart';

const _room = '01a1cc22-8fc6-7cc6-93e5-e19493f61743';

void main() {
  for (final ends in [true, false]) {
    test(
      'an online game in the way of an invite is ended only on the player\'s word (${ends ? 'yes' : 'no'})',
      () async {
        final server = await FakeTogether.start();
        addTearDown(server.close);
        server.answers['DELETE game-sessions/$_room'] = (204, null);
        final fixture = makeFixture(together: server.base);
        final model = fixture.model;
        addTearDown(() {
          model.dispose();
          fixture.dispose();
        });
        final together = model.together;
        together.email = 'fixture@example.invalid';
        await together.sendCode();
        together.code = '123456';
        await together.verify();
        expect(await eventually(() => together.hub.socket.status.name == 'ready'), isTrue);
        final me = together.account.user!.id;
        var retried = 0;
        final rooms = RetroOnlineRooms(
          spec: (titleId: 'SCUS94426', gameVersion: '1', mode: RetroOnlineMode.synchronized, capacity: 2),
          me: me,
          call: together.account.call,
          signal: (_, _, _, _, _) {},
        );
        model.open(Layer.coopLobby);
        together.otherOnlineGame = (
          game: (id: _room, hosted: true, titleId: 'SCUS94426', since: DateTime.now(), others: 0),
          rooms: rooms,
          retry: () async => retried++,
          back: Layer.coopLobby,
        );
        model.open(Layer.otherOnlineGame);
        final rows = model.panelCategories().single.rows;
        expect(model.twoChoice, isTrue);
        expect(rows.map((row) => row.id), ['cancel', 'endOtherOnlineGame']);
        expect(model.panelCategories().single.title, T.text('otherOnlineGameTitle'));
        model.activateRow(ends ? 1 : 0);
        if (ends) {
          expect(await eventually(() => retried == 1), isTrue);
          expect(server.callsTo('game-sessions/$_room', method: 'DELETE'), hasLength(1));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(retried, 0);
          expect(server.callsTo('game-sessions/$_room', method: 'DELETE'), isEmpty);
        }
        expect(together.otherOnlineGame, isNull);
      },
    );
  }
}
