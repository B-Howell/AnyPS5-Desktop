import 'dart:io';

import 'package:anyps5_desktop/core/game_archives.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_updates.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// PS4 dumps in the library beside PS5 ones, from the generated param.sfo fixtures: the game
/// with its name, version and art, its update and add-ons in the layouts shadPS4 users keep, and
/// a zipped dump.
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = temporaryFolder('ps4');
    root = p.join(temp.path, 'Games');
    Directory(root).createSync(recursive: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('a PS4 dump is a game: names, version, icon0, pic1, snd0 and its SELF eboot', () {
    final folder = makePs4Dump(root, 'ANPS40001', pictures: ['icon0.png', 'pic1.png', 'pic0.png', 'snd0.at9']);
    final game = GameLibrary.inspect(folder)!;
    expect(game.platform, DumpPlatform.ps4);
    expect(game.titleId, 'ANPS40001');
    expect(game.name, 'Orbis Fixture');
    expect(game.nameFor(['fr-FR']), 'Orbis Exemple');
    expect(game.nameFor(['de-DE']), 'Orbis Fixture');
    expect(game.version, '01.00');
    expect(game.executable, ExecutableKind.container);
    expect(game.icon, p.join(folder, 'sce_sys', 'icon0.png'));
    expect(game.background, p.join(folder, 'sce_sys', 'pic1.png'));
    expect(game.music, p.join(folder, 'sce_sys', 'snd0.at9'));
    expect(game.ageLevels, isNull);
    expect(game.retro, isNull);
  });

  test('PS4 and PS5 dumps are listed together, sorted by name', () {
    makeDump(root, 'PPSA01001', titleId: 'PPSA01001', names: {'en-US': 'Astro'});
    makePs4Dump(root, 'ANPS40001');
    final games = GameLibrary.scan(root);
    expect(games.map((game) => (game.titleId, game.platform)), [
      ('PPSA01001', DumpPlatform.ps5),
      ('ANPS40001', DumpPlatform.ps4),
    ]);
  });

  test('a param.sfo without an eboot.bin is a dump still being copied', () {
    makePs4Dump(root, 'Copying', eboot: null);
    final survey = GameLibrary.survey(root);
    expect(survey.games, isEmpty);
    expect(survey.incomplete, [p.join(root, 'Copying')]);
  });

  test('the update and add-on beside a PS4 game belong to it, not to the library', () {
    final folder = makePs4Dump(root, 'ANPS40001');
    final update = makePs4Dump(root, 'ANPS40001-UPDATE', kind: 'update');
    final addon = makePs4Dump(p.join(root, 'ANPS40001-DLC'), 'EXTRASOUNDTRACK1', kind: 'addon', eboot: null);
    final survey = GameLibrary.survey(root);
    expect(survey.games.map((game) => game.folder), [folder]);
    expect(survey.incomplete, isEmpty);
    final game = survey.games.single;
    expect(game.update?.folder, update);
    expect(game.update?.version, '01.02');
    expect(game.update?.shortVersion, '01.02');
    expect(game.addons.map((found) => (found.label, found.name, found.folder)), [
      ('EXTRASOUNDTRACK1', 'Fixture Soundtrack', addon),
    ]);
  });

  test('an add-on named by its content ID beside the game, and a -patch update', () {
    makePs4Dump(root, 'ANPS40001');
    makePs4Dump(root, 'ANPS40001-patch', kind: 'update');
    makePs4Dump(root, 'IV0000-ANPS40001_00-EXTRASOUNDTRACK1', kind: 'addon', eboot: null);
    final game = GameLibrary.scan(root).single;
    expect(game.update?.version, '01.02');
    expect(game.addons.single.label, 'EXTRASOUNDTRACK1');
  });

  test('a game with its update copied over it is still the game (its param.sfo says gp)', () {
    final merged = makePs4Dump(root, 'ANPS40001', kind: 'update');
    final game = GameLibrary.scan(root).single;
    expect(game.folder, merged);
    expect(game.version, '01.02');
  });

  test('an update dump is checked against the PS4 game it is for', () {
    makePs4Dump(root, 'ANPS40001');
    final game = GameLibrary.scan(root).single;
    final candidate = makePs4Dump(temp.path, 'Downloaded update', kind: 'update');
    final checked = GameUpdates.check(candidate, game);
    expect(checked.problem, isNull);
    expect(checked.update?.titleId, 'ANPS40001');
    expect(checked.update?.version, '01.02');
    final older = makePs4Dump(temp.path, 'Same game', kind: 'game');
    expect(GameUpdates.check(older, game).problem, UpdateProblem.notNewer);
  });

  test('a zipped PS4 dump looks like a game, with its title ID and APP_VER', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('ANPS40001/eboot.bin', [...selfHead, ...List.filled(60, 0)]))
      ..addFile(ArchiveFile.bytes('ANPS40001/sce_sys/param.sfo', ps4ParamSfo('update')));
    final path = p.join(root, 'ANPS40001.zip');
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    final plan = GameArchives.plan(path);
    expect(plan.looksLikeGame, isTrue);
    expect(plan.titleId, 'ANPS40001');
    expect(plan.version, '01.02');
  });

  test('a zip with both parameter files reads param.json first, whatever their order, as a folder does', () {
    const json = '{"titleId": "PPSA07007", "contentVersion": "01.003.000"}';
    for (final (order, broken) in [(true, false), (false, false), (true, true)]) {
      final jsonFile = ArchiveFile.bytes('Game/sce_sys/param.json', broken ? [0x7B] : json.codeUnits);
      final sfoFile = ArchiveFile.bytes('Game/sce_sys/param.sfo', ps4ParamSfo('game'));
      final archive = Archive()..addFile(ArchiveFile.bytes('Game/eboot.bin', [...selfHead, ...List.filled(60, 0)]));
      for (final file in order ? [sfoFile, jsonFile] : [jsonFile, sfoFile]) {
        archive.addFile(file);
      }
      final path = p.join(root, 'Both.zip');
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      final plan = GameArchives.plan(path);
      expect(plan.titleId, broken ? 'ANPS40001' : 'PPSA07007', reason: 'sfo first: $order, broken json: $broken');
    }
  });
}
