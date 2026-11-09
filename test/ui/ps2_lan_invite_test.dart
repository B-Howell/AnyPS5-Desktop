import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/fixtures.dart' show writePs2IdentityIso;
import '../support/ui_support.dart';

void main() {
  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  test('a PS2 LAN invite opens missing setup and Back restores the same invite', () async {
    final lanServer = await FakeTogether.start();
    addTearDown(lanServer.close);
    lanServer.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    final lanFixture = makeFixture(
      together: lanServer.base,
      system: HostSystem.windows,
      environment: {'ANYPS5_PS2_LAN': '1'},
    );
    final lan = lanFixture.model;
    addTearDown(() {
      lan.dispose();
      lanFixture.dispose();
    });
    lan.together.email = 'fixture@example.invalid';
    await lan.together.sendCode();
    lan.together.code = '123456';
    await lan.together.verify();
    await until(() => lan.together.hub.friends.loaded);
    final disc = File(p.join(lanFixture.temp.path, 'game.iso'));
    writePs2IdentityIso(disc, bootSerial: 'SLUS_211.48', revision: '1.00');
    final game = Game(
      folder: lanFixture.temp.path,
      titleId: 'PS2-TIMESPLITTERS',
      name: 'TimeSplitters: Future Perfect',
      names: const {},
      defaultLanguage: 'en',
      version: '1.00',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: disc.path),
      retroSerial: 'SLUS21148',
    );
    const roomId = '12345678-1234-4234-8234-123456789abc';
    final invite = {
      'sessionId': roomId,
      'from': lanServer.person('u-ana', 'ana', 'Ana'),
      'titleId': 'SLUS21148',
      'gameVersion': '1.00',
      'engineBuild': RetroOnlineMode.lan.protocol,
    };
    lanServer.gameInvites.add(invite);
    lanServer.push('game_session.invite', invite);
    await until(() => lan.together.hub.games.invites.isNotEmpty);
    lan.open(Layer.friends);
    final origin = (layer: Layer.friends, category: lan.panelCategories().single.id, row: 'game-accept-$roomId');
    lan.returnTo(origin);
    PanelRow accept() => lan.panelCategories().single.rows.singleWhere((row) => row.id == origin.row);
    expect(accept().detail, 'This room needs a matching PS2 disc ISO in your library.');
    (accept().kind as ActionRow).run();
    expect(lan.overlay, Layer.friends);
    lan.games.add(game);
    expect(accept().detail, 'Install the LAN-enabled PS2 emulator before starting.');
    (accept().kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    expect(lan.panelCategories().single.rows.map((row) => row.id), contains('ps2-lan-setup-install'));
    await lan.together.hub.games.refresh();
    expect(lanServer.callsTo('game-sessions/$roomId'), isEmpty);
    expect(lanServer.callsTo('game-sessions/$roomId/join'), isEmpty);
    expect(lanServer.callsTo('game-sessions/$roomId/decline'), isEmpty);
    expect(lan.running, isNull);
    lan.handle(Command.back);
    expect(lan.spot, origin);
    expect(lan.together.hub.games.invites.single.sessionId, roomId);

    lan.selected = lan.games.indexOf(game);
    lan.together.openFriend(lan.together.hub.friends.friends.single);
    final outgoing = lan.panelCategories().single.rows.singleWhere((row) => row.id == 'ps2-lan-invite');
    final friendOrigin = (layer: lan.overlay!, category: lan.panelCategories().single.id, row: outgoing.id);
    lan.returnTo(friendOrigin);
    expect(outgoing.detail, 'Install the LAN-enabled PS2 emulator before starting.');
    (outgoing.kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    await lan.together.hub.games.refresh();
    expect(lanServer.callsTo('game-sessions', method: 'POST'), isEmpty);
    lan.handle(Command.back);
    expect(lan.spot, friendOrigin);
    (outgoing.kind as ActionRow).run();
    expect(lan.overlay, Layer.emulatorMenu);
    await lan.together.signOut();
    lan.handle(Command.back);
    expect(lan.overlay, Layer.friends);
  }, skip: Abi.current() != Abi.windowsX64);
}
