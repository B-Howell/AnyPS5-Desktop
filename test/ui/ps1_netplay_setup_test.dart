import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/online/retro_online_rooms.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

void main() {
  test('PS1 handoff invite prompts for a compatible BIOS before joining', () async {
    final server = await FakeTogether.start();
    addTearDown(server.close);
    const host = '12345678-1234-4234-8234-123456789ab1';
    const roomId = '12345678-1234-4234-8234-123456789abc';
    const protocol = RetroOnlineMode.synchronized;
    const invite = GameInvite(
      sessionId: roomId,
      titleId: 'SCUS94426',
      gameVersion: '2',
      engineBuild: 'anyps5-ps1-netplay-v1',
    );
    server.answers['GET game-sessions/$roomId'] = (
      200,
      {
        'id': roomId,
        'host': {'userId': host},
        'kind': 'online',
        'titleId': invite.titleId,
        'gameVersion': invite.gameVersion,
        'engineBuild': protocol.protocol,
        'capacity': 2,
        'joinable': false,
        'properties': {'protocol': protocol.protocol, 'discSha256': 'a' * 64},
      },
    );

    var chosen = Completer<String?>();
    var picking = Completer<void>();
    final fixture = makeFixture(
      together: server.base,
      system: HostSystem.windows,
      environment: {'ANYPS5_PS1_NETPLAY': '1'},
      pickFile: (label, extensions) {
        expect(label, contains('SCPH-1001'));
        expect(extensions, contains('bin'));
        picking.complete();
        return chosen.future;
      },
    );
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    model.together.email = 'fixture@example.invalid';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await Future.doWhile(() async {
      if (model.together.hub.socket.status.name == 'ready') return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return true;
    }).timeout(const Duration(seconds: 5));

    final folder = fixture.temp.path;
    final cue = File(p.join(folder, 'game.cue'))..createSync();
    model.games.add(
      Game(
        folder: folder,
        titleId: 'PS1-fixture',
        name: 'CTR fixture',
        names: const {},
        defaultLanguage: 'en',
        version: '',
        executable: ExecutableKind.disc,
        retro: (platform: RetroPlatform.ps1, path: cue.path),
        retroSerial: invite.titleId,
      ),
    );
    final incompatible = Uint8List(512 * 1024)..[0] = 3;
    final offline = File(p.join(folder, 'offline.bin'))..writeAsBytesSync(incompatible);
    model.preferences.retroBiosSources['ps1'] = offline.path;

    var joining = model.together.joinPs1Netplay(invite);
    await picking.future.timeout(const Duration(seconds: 5));
    chosen.complete(offline.path);
    await joining;
    expect(model.toast, contains('matching SCPH-1001'));

    chosen = Completer<String?>();
    picking = Completer<void>();
    joining = model.together.joinPs1Netplay(invite);
    await picking.future.timeout(const Duration(seconds: 5));
    chosen.complete(null);
    await joining;

    chosen = Completer<String?>();
    picking = Completer<void>();
    joining = model.together.joinPs1Netplay(invite);
    await picking.future.timeout(const Duration(seconds: 5));
    await model.together.signOut();
    final signedOutNotice = model.toast;
    chosen.complete(offline.path);
    await joining;
    expect(model.toast, signedOutNotice);

    expect(server.callsTo('game-sessions/$roomId/join'), isEmpty);
    expect(model.running, isNull);
    expect(model.preferences.retroBiosSources['ps1'], offline.path);
    expect(offline.readAsBytesSync(), incompatible);
    expect(
      File(p.join(p.dirname(model.paths.toolkits), 'Emulators', 'PS1-Netplay', 'scph1001.bin')).existsSync(),
      isFalse,
    );
  }, skip: Abi.current() != Abi.windowsX64);
}
