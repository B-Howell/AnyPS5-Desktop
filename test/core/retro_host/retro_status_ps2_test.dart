import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart' show retroHostErrorKey;
import 'package:anyps5_desktop/ui/retro_host/retro_option_sections.dart';
import 'package:test/test.dart';

/// A PS2 game's messages (capability `ps2`) as a real host sent them:
/// test/fixtures/retro_host/ps2_lrps2_and_fake_core.json, from a host built from ps2-design 3cb36d2
/// with the real LRPS2 core and no BIOS, and with its fake core.
void main() {
  final recording = jsonDecode(
    File('test/fixtures/retro_host/ps2_lrps2_and_fake_core.json').readAsStringSync(),
  ) as Map<String, Object?>;

  Map<String, Object?> core(String name) => recording[name]! as Map<String, Object?>;

  Map<String, Object?> reply(String name, String game, String method, [String? when]) {
    final replies = (core(name)['replies']! as List<Object?>).cast<Map<String, Object?>>();
    final found = replies.firstWhere(
      (reply) => reply['game'] == game && reply['method'] == method && (when == null || reply['when'] == when),
    );
    return jsonDecode(found['reply']! as String) as Map<String, Object?>;
  }

  RetroStatus status(String name, String game, String when) => RetroStatus.parse(
    reply(name, game, 'status', when)['result']! as Map<String, Object?>,
    coreIdentity: true,
    gameTiming: true,
    ps2: true,
  );

  test('both hosts list ps2 beside the PS1 capabilities', () {
    for (final name in ['lrps2', 'fake']) {
      final welcome = jsonDecode(core(name)['welcome']! as String) as Map<String, Object?>;
      expect(welcome['capabilities'], containsAll([retroCapabilityPs1, retroCapabilityPs2]), reason: name);
    }
  });

  test('LRPS2 with no BIOS ends the game with bios before a first frame, its core named and identified', () {
    for (final game in ['noBiosFolder', 'notABios']) {
      final first = status('lrps2', game, 'first');
      expect((first.console, first.core, first.ended), (RetroConsole.ps2, null, false), reason: game);
      final ended = status('lrps2', game, 'ended');
      expect(ended.ended, isTrue, reason: game);
      expect(ended.ready, isFalse, reason: game);
      expect(ended.errorCode, RetroErrorCode.bios, reason: game);
      expect(ended.error, 'No PS2 BIOS was found.', reason: game);
      expect(ended.console, RetroConsole.ps2, reason: game);
      expect(ended.timing, isNull, reason: 'the core never loaded the game');
      expect(ended.hardware, isFalse);
      expect(ended.core!.name, 'ParaLLEl PS2');
      expect(ended.core!.identified, isTrue, reason: 'the host build identity, anyps5-1-82851e32...');
      expect(ended.core!.version, startsWith('anyps5-1-82851e32'));
      expect(retroHostErrorKey(ended.errorCode, ps2: true), 'retroHostPs2NoBiosDetail', reason: game);
      expect(retroHostErrorKey(ended.errorCode), 'retroHostBiosDetail', reason: "a PS1 game's words stay");
    }
  });

  test("LRPS2's options are listed even with no BIOS: none is a picture option, and no BIOS is offered", () {
    final options = status('lrps2', 'noBiosFolder', 'ended').options;
    expect(options, hasLength(72));
    expect(options.keys.every((key) => key.startsWith('pcsx2_')), isTrue);
    expect(options.keys, isNot(contains('pcsx2_bios')), reason: 'LRPS2 lists it only once it found a BIOS');
    expect(
      options.keys,
      isNot(containsAll(['pcsx2_shared_memory_cards', 'pcsx2_renderer', 'pcsx2_multitap'])),
      reason: 'the host fixes those itself',
    );
    for (final key in options.keys) {
      expect(retroOptionSection(key), RetroOptionSection.advanced, reason: key);
      expect(retroOptionSent(key, ps2: true), isTrue, reason: key);
      expect(retroOptionSent(key, ps2: false), isFalse, reason: '$key is no PS1 option');
    }
    expect(retroOptionSection('pcsx2_bios'), isNull, reason: 'chosen in Settings › Emulators');
    expect(retroOptionSent('pcsx2_bios', ps2: true), isFalse);
    expect(retroOptionSent('swanstation_GPU_ResolutionScale', ps2: true), isFalse);
    expect(retroOptionSent('swanstation_GPU_ResolutionScale', ps2: false), isTrue);
  });

  test("the fake core's PS2 games: bios, core, a ready game kept out of lockstep and states, and a PS1 game", () {
    expect(status('fake', 'ps2NoBios', 'ended').errorCode, RetroErrorCode.bios);
    final failed = status('fake', 'ps2CoreFailed', 'ended');
    expect((failed.errorCode, failed.console), (RetroErrorCode.core, RetroConsole.ps2));
    expect(retroHostErrorKey(failed.errorCode, ps2: true), 'retroHostCoreDetail');

    final refused = reply('fake', 'ps2Lockstep', 'start')['error']! as Map<String, Object?>;
    expect(refused['code'], RetroCallError.argument);

    final ready = status('fake', 'ps2Ready', 'ready');
    expect((ready.ready, ready.ended, ready.console), (true, false, RetroConsole.ps2));
    expect(reply('fake', 'ps2Ready', 'lockstep')['result'], isFalse);
    expect(reply('fake', 'ps2Ready', 'saveState')['result'], isFalse);
    final stopped = status('fake', 'ps2Ready', 'stopped');
    expect((stopped.ended, stopped.errorCode, stopped.console), (true, RetroErrorCode.none, RetroConsole.ps2));

    expect(status('fake', 'ps1Ready', 'ready').console, RetroConsole.ps1);
  });

  test('a host that lists ps2 must send console as ps1 or ps2; any other host is not read for it', () {
    final ended = reply('lrps2', 'noBiosFolder', 'status', 'ended')['result']! as Map<String, Object?>;
    for (final value in <Object?>['ps3', 2, null, '']) {
      expect(
        () => RetroStatus.parse({...ended, 'console': value}, coreIdentity: true, gameTiming: true, ps2: true),
        throwsA(isA<RetroProtocolError>()),
        reason: '$value',
      );
    }
    expect(
      () => RetroStatus.parse({...ended}..remove('console'), coreIdentity: true, gameTiming: true, ps2: true),
      throwsA(isA<RetroProtocolError>()),
    );
    expect(RetroStatus.parse({...ended, 'console': 'ps3'}, coreIdentity: true, gameTiming: true).console, isNull);
    final parsed = status('lrps2', 'noBiosFolder', 'ended');
    expect(parsed.toJson()['console'], RetroConsole.ps2);
  });
}
