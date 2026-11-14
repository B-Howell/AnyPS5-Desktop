import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/ps1_netplay_state.dart';
import 'package:anyps5_desktop/core/retro_host/retro_lockstep.dart';
import 'package:test/test.dart';

import 'lockstep_test_support.dart';

/// The state a real host saved for a friend to join from (test/fixtures/retro_host/
/// lockstep_join_state.gz, recorded with lockstep_swanstation.json from the host repository's
/// `netplay-design` with its SwanStation patches) is fit for netplay; the same state with any of
/// what the patches leave out put back is not.
void main() {
  final state = recordedJoinState();
  final recorded = jsonDecode(File('test/fixtures/retro_host/lockstep_swanstation.json').readAsStringSync()) as Map;
  final saved = (recorded['replies'] as List).cast<Map<String, Object?>>().firstWhere(
    (reply) => reply['method'] == 'saveState',
  );
  final result = (jsonDecode(saved['reply']! as String) as Map)['result'] as Map<String, Object?>;

  Uint8List changed(void Function(ByteData file) change) {
    final copy = Uint8List.fromList(state);
    change(ByteData.sublistView(copy));
    return copy;
  }

  const core = RetroStateFile.headerBytes;
  final trailer = () {
    final data = ByteData.sublistView(state, core);
    return core + data.getUint32(212, Endian.little) + data.getUint32(208, Endian.little);
  }();

  test("the recorded state's header is the one its saveState reply gave", () {
    expect(state.length, result['bytes']);
    final file = RetroStateFile.read(state)!;
    expect(file.frame, result['frame']);
    expect(file.ports, 2);
    expect(file.core.length, state.length - RetroStateFile.headerBytes);
  });

  test('the recorded state is fit for netplay', () {
    expect(Ps1NetplayState.problem(state), isNull);
  });

  test('a state file of another version or size is not read', () {
    expect(RetroStateFile.read(changed((file) => file.setUint32(8, 1, Endian.little))), isNull);
    expect(RetroStateFile.read(changed((file) => file.setUint8(0, 0x41 + 1))), isNull);
    expect(RetroStateFile.read(Uint8List.sublistView(state, 0, state.length - 1)), isNull);
    expect(RetroStateFile.read(changed((file) => file.setUint32(40, 3, Endian.little))), isNull);
  });

  test('a state that names the title, the disc, or a path, or that lacks the input patch, is not', () {
    expect(
      Ps1NetplayState.problem(changed((file) => file.setUint32(core + 4, 57, Endian.little))),
      contains('older than ${Ps1NetplayState.minimumVersion}'),
      reason: "stock SwanStation's state keeps the analog-mode combination outside it",
    );
    expect(Ps1NetplayState.problem(changed((file) => file.setUint8(core + 8, 0x41))), contains('title'));
    expect(Ps1NetplayState.problem(changed((file) => file.setUint32(core + 168, 12, Endian.little))), contains('file'));
    expect(
      Ps1NetplayState.problem(changed((file) => file.setUint32(trailer + 12, 0, Endian.little))),
      contains('not pathless'),
    );
    expect(
      Ps1NetplayState.problem(changed((file) => file.setUint32(trailer + 20, 9, Endian.little))),
      contains('names a path'),
    );
    expect(Ps1NetplayState.problem(changed((file) => file.setUint32(trailer, 0, Endian.little))), contains('trailer'));
    expect(Ps1NetplayState.problem(changed((file) => file.setUint32(core, 0, Endian.little))), contains('SwanStation'));
  });

  test("a test host's state in the recorded form is fit, and with the stock trailer is not", () {
    expect(Ps1NetplayState.problem(stateFile(12, utf8.encode('{}'))), isNull);
    expect(Ps1NetplayState.problem(stateFile(12, utf8.encode('{}'), pathless: false)), isNotNull);
    expect(utf8.decode(stateBody(stateFile(12, utf8.encode('{"ram":1}')))), '{"ram":1}');
  });
}
