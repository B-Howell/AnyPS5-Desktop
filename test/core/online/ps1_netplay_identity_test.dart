import 'package:anyps5_desktop/core/online/ps1_netplay_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = <String, Object>{
    'version': 1,
    'title': 'PS1-SCUS94426',
    'disc': 'a' * 64,
    'bios': 'b' * 64,
    'core': 'c' * 64,
    'profile': 'd' * 64,
    'card': 'e' * 64,
  };

  test('matching compatibility fields round trip without local data', () {
    final host = Ps1NetplayIdentity.tryRead(fixture)!;
    expect(host.toJson(), fixture);
    final guest = Ps1NetplayIdentity.tryRead(host.toJson())!;
    expect(host.mismatchWith(guest), isNull);
  });

  test('each mismatch identifies the failed prerequisite', () {
    final host = Ps1NetplayIdentity.tryRead(fixture)!;
    for (final (key, replacement, mismatch) in [
      ('version', 2, Ps1NetplayMismatch.version),
      ('title', 'PS1-SCUS94999', Ps1NetplayMismatch.title),
      ('disc', '1' * 64, Ps1NetplayMismatch.disc),
      ('bios', '2' * 64, Ps1NetplayMismatch.bios),
      ('core', '3' * 64, Ps1NetplayMismatch.core),
      ('profile', '4' * 64, Ps1NetplayMismatch.profile),
      ('card', '5' * 64, Ps1NetplayMismatch.card),
    ]) {
      final guest = Ps1NetplayIdentity.tryRead({...fixture, key: replacement})!;
      expect(host.mismatchWith(guest), mismatch);
    }
  });

  test('rejects incomplete or malformed metadata and local file paths', () {
    for (final bad in [
      {...fixture}..remove('card'),
      {...fixture, 'version': 0},
      {...fixture, 'version': 65536},
      {...fixture, 'version': '1'},
      {...fixture, 'disc': 'c' * 65},
      {...fixture, 'core': 'g' * 64},
      {...fixture, 'bios': r'C:\Games\bios.bin'},
      {...fixture, 'title': '../CTR'},
      {...fixture, 'path': 'local/CTR.cue'},
    ]) {
      expect(Ps1NetplayIdentity.tryRead(bad), isNull);
    }
  });
}
