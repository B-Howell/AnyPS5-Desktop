import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/dump_parameters.dart';
import 'package:anyps5_desktop/core/param_sfo.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// A dump's parameter file, read the same way for both consoles: param.json for a PS5 dump,
/// param.sfo for a PS4 one, from the generated fixtures of test/fixtures/ps4_param_sfo.
void main() {
  late Directory root;

  setUp(() => root = temporaryFolder('parameters'));
  tearDown(() => root.deleteSync(recursive: true));

  test('param.sfo keeps its text and integer values', () {
    final sfo = ParamSfo.parse(ps4ParamSfo('game'))!;
    expect(sfo.texts['TITLE_ID'], 'ANPS40001');
    expect(sfo.texts['CATEGORY'], 'gd');
    expect(sfo.texts['APP_VER'], '01.00');
    expect(sfo.texts['TITLE'], 'Orbis Fixture');
    expect(sfo.integers['PARENTAL_LEVEL'], 1);
    expect(sfo.integers['APP_TYPE'], 0);
    expect(sfo.texts.containsKey('PARENTAL_LEVEL'), isFalse);
  });

  test('a file without the PSF magic, or cut short, is none', () {
    expect(ParamSfo.parse(utf8.encode('{"titleId": "PPSA00001"}')), isNull);
    expect(ParamSfo.parse(ps4ParamSfo('game').sublist(0, 12)), isNull);
  });

  test('an entry past the end of a cut file is left out, the others stay', () {
    final bytes = ps4ParamSfo('game');
    final cut = ParamSfo.parse(bytes.sublist(0, bytes.length - 40))!;
    expect(cut.texts['TITLE_ID'], isNull);
    expect(cut.texts['TITLE'], 'Orbis Fixture');
  });

  test('a PS4 dump: title ID, APP_VER, content ID and each language TITLE_nn names', () {
    final parameters = DumpParameters.read(makePs4Dump(root.path, 'Game'))!;
    expect(parameters.platform, DumpPlatform.ps4);
    expect(parameters.titleId, 'ANPS40001');
    expect(parameters.version, '01.00');
    expect(parameters.contentId, 'IV0000-ANPS40001_00-ANYPS5FIXTURE001');
    expect(parameters.title, 'Orbis Fixture');
    expect(parameters.names, {'en-US': 'Orbis Fixture', 'fr-FR': 'Orbis Exemple'});
    expect(parameters.defaultLanguage, 'en-US');
    expect(parameters.ageLevel, isNull);
  });

  test('param.json comes first when a dump has both, as the engine reads them', () {
    final folder = makeDump(root.path, 'Both', titleId: 'PPSA00001', names: {'en-US': 'Five'});
    File(p.join(folder, 'sce_sys', 'param.sfo')).writeAsBytesSync(ps4ParamSfo('game'));
    final parameters = DumpParameters.read(folder)!;
    expect(parameters.platform, DumpPlatform.ps5);
    expect(parameters.titleId, 'PPSA00001');
    expect(parameters.title, 'Five');
  });

  test('a parameter file is told by its name inside an archive', () {
    expect(DumpParameters.parse('Game/sce_sys/param.sfo', ps4ParamSfo('update'))?.version, '01.02');
    expect(
      DumpParameters.parse('Game/sce_sys/param.json', utf8.encode('{"titleId": "PPSA00002"}'))?.titleId,
      'PPSA00002',
    );
    expect(DumpParameters.parse('Game/sce_sys/param.sfo', utf8.encode('{}')), isNull);
    expect(DumpParameters.parse('Game/sce_sys/other.bin', ps4ParamSfo('game')), isNull);
  });

  test('only the PS5 runs with the engine the launcher downloads', () {
    expect(DumpPlatform.ps5.runs, isTrue);
    expect(DumpPlatform.ps4.runs, isFalse);
    expect(DumpPlatform.ps4.label, 'PS4');
  });
}
