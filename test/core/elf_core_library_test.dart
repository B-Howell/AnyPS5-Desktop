import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/binary.dart';
import 'package:anyps5_desktop/core/elf_core_library.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List core() {
  final bytes = Uint8List(0x400);
  bytes.setRange(0, 7, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  Binary.put16(bytes, 16, 3); // ET_DYN
  Binary.put16(bytes, 18, 62); // EM_X86_64
  Binary.put32(bytes, 20, 1);
  Binary.put64(bytes, 32, 0x280);
  Binary.put16(bytes, 54, 56);
  Binary.put16(bytes, 56, 2);
  Binary.put64(bytes, 40, 0x100);
  Binary.put16(bytes, 52, 64);
  Binary.put16(bytes, 58, 64);
  Binary.put16(bytes, 60, 4);
  // Dynamic symbol table linked to the string table.
  Binary.put32(bytes, 0x144, 11);
  Binary.put64(bytes, 0x150, 0x200);
  Binary.put64(bytes, 0x158, 0x200);
  Binary.put64(bytes, 0x160, 48);
  Binary.put32(bytes, 0x168, 2);
  Binary.put64(bytes, 0x178, 24);
  Binary.put32(bytes, 0x184, 3);
  Binary.put64(bytes, 0x190, 0x240);
  Binary.put64(bytes, 0x198, 0x240);
  Binary.put64(bytes, 0x1a0, 64);
  // Executable allocated section and one exported function.
  Binary.put32(bytes, 0x1c4, 1);
  Binary.put64(bytes, 0x1c8, 6);
  Binary.put64(bytes, 0x1d0, 0x300);
  Binary.put64(bytes, 0x1d8, 0x300);
  Binary.put64(bytes, 0x1e0, 16);
  Binary.put32(bytes, 0x218, 1);
  bytes[0x21c] = 0x12; // STB_GLOBAL, STT_FUNC
  Binary.put16(bytes, 0x21e, 3);
  Binary.put64(bytes, 0x220, 0x300);
  Binary.put64(bytes, 0x228, 1);
  bytes.setRange(0x241, 0x241 + 'retro_anyps5_dev9_bind_v1'.length, 'retro_anyps5_dev9_bind_v1'.codeUnits);
  // Loader mappings and runtime dynamic table, independently of section flags.
  Binary.put32(bytes, 0x280, 1); // PT_LOAD
  Binary.put32(bytes, 0x284, 5); // PF_R | PF_X
  Binary.put64(bytes, 0x2a0, bytes.length);
  Binary.put64(bytes, 0x2a8, bytes.length);
  Binary.put32(bytes, 0x2b8, 2); // PT_DYNAMIC
  Binary.put64(bytes, 0x2c0, 0x80);
  Binary.put64(bytes, 0x2c8, 0x80);
  Binary.put64(bytes, 0x2d8, 0x50);
  Binary.put64(bytes, 0x2e0, 0x50);
  for (final (at, tag, value) in [(0x80, 6, 0x200), (0x90, 11, 24), (0xa0, 5, 0x240), (0xb0, 10, 64)]) {
    Binary.put64(bytes, at, tag);
    Binary.put64(bytes, at + 8, value);
  }
  return bytes;
}

void main() {
  late Directory temp;
  late File file;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('elf-core-');
    file = File('${temp.path}/pcsx2_libretro.so');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('Linux x64 core validates a defined executable dynamic export without loading it', () {
    file.writeAsBytesSync(core());
    expect(ElfCoreLibrary.isX64(file), isTrue);
    expect(ElfCoreLibrary.isX64(file, requiredExport: 'retro_anyps5_dev9_bind_v1'), isTrue);
    expect(ElfCoreLibrary.isX64(file, requiredExport: 'missing'), isFalse);
  });

  test('managed Linux setup recognizes SO hooks and never substitutes a Windows DLL', () {
    file.writeAsBytesSync(core());
    final linux = ManagedRetro(temp.path, host: EmbeddedCoreHost.linuxX64);
    final windows = ManagedRetro(temp.path, host: EmbeddedCoreHost.windowsX64);
    expect(linux.host.libraryName(RetroPlatform.ps2), 'pcsx2_libretro.so');
    expect(linux.isInstalled(RetroPlatform.ps2), isTrue);
    expect(linux.supportsPs2Lan, isTrue);
    expect(windows.isInstalled(RetroPlatform.ps2), isFalse);
    File('${temp.path}/pcsx2_libretro.dll').writeAsBytesSync(core());
    expect(windows.isInstalled(RetroPlatform.ps2), isFalse);
    final bytes = core()..[0x21c] = 0x11;
    file.writeAsBytesSync(bytes);
    expect(linux.supportsPs2Lan, isFalse);
  });

  test('Linux online setup cannot reuse unqualified Windows core pins', () async {
    final linux = ManagedRetro(temp.path, host: EmbeddedCoreHost.linuxX64);
    await expectLater(linux.ensurePs1NetplayCore(), throwsFormatException);
    final wrongPackage = File('${temp.path}/pcsx2_libretro.dll.zip')..writeAsBytesSync([0, 1, 2, 3]);
    await expectLater(linux.installPs2Lan(wrongPackage.path), throwsFormatException);
    expect(linux.installedPs2LanHome, isNull);
    await expectLater(linux.install(RetroPlatform.ps3), throwsFormatException);
    expect(await linux.verifiedPs3UpdateCore(), isNull);
  });

  test('verified Linux LAN package installs its SO in isolated storage and preserves offline files', () async {
    final offline = file..writeAsBytesSync([1, 2, 3]);
    final library = core();
    final archive = ZipEncoder().encode(Archive()..addFile(ArchiveFile('pcsx2_libretro.so', library.length, library)));
    final package = File('${temp.path}/linux.zip')..writeAsBytesSync(archive);
    final managed = ManagedRetro(
      temp.path,
      host: EmbeddedCoreHost.linuxX64,
      ps2LanCoreDigests: '${sha256.convert(archive)}:${sha256.convert(library)}',
    );
    await managed.installPs2Lan(package.path);
    final destination = managed.installedPs2LanHome;
    expect(destination, isNotNull);
    expect(File('$destination/pcsx2_libretro.so').readAsBytesSync(), library);
    expect(offline.readAsBytesSync(), [1, 2, 3]);
    expect(File('$destination/pcsx2_libretro.dll').existsSync(), isFalse);
    expect(temp.listSync().whereType<Directory>().map((directory) => directory.path), [destination]);
  });

  final realCore = Platform.environment['ANYPS5_TEST_ELF_CORE'];
  test('validates the compiled Linux private NIC fixture as a real ELF library', () {
    expect(ElfCoreLibrary.isX64(File(realCore!), requiredExport: 'retro_anyps5_dev9_bind_v1'), isTrue);
    expect(ElfCoreLibrary.isX64(File(realCore), requiredExport: 'missing'), isFalse);
  }, skip: realCore == null ? 'Set ANYPS5_TEST_ELF_CORE to the Linux native LAN fixture' : false);

  test('rejects foreign architecture, executable, byte order, and truncated tables', () {
    for (final mutate in <void Function(Uint8List)>[
      (b) => b[0] = 0,
      (b) => b[4] = 1,
      (b) => b[5] = 2,
      (b) => Binary.put16(b, 16, 2),
      (b) => Binary.put16(b, 18, 183),
      (b) {
        Binary.put64(b, 32, 0x280);
        Binary.put16(b, 54, 56);
        Binary.put16(b, 56, 1);
        Binary.put32(b, 0x280, 3); // PT_INTERP means a PIE executable, not a core.
      },
      (b) => Binary.put64(b, 40, 0x3ff),
      (b) => Binary.put16(b, 60, 0xffff),
    ]) {
      final bytes = core();
      mutate(bytes);
      file.writeAsBytesSync(bytes);
      expect(ElfCoreLibrary.isX64(file, requiredExport: 'retro_anyps5_dev9_bind_v1'), isFalse);
    }
    file.writeAsBytesSync(core().sublist(0, 30));
    expect(ElfCoreLibrary.isX64(file), isFalse);
  });

  test('a name in bytes, undefined symbol, local/hidden symbol, or data symbol is not an export', () {
    for (final mutate in <void Function(Uint8List)>[
      (b) => Binary.put32(b, 0x144, 2), // static symbol table
      (b) => Binary.put16(b, 0x21e, 0), // undefined
      (b) => b[0x21c] = 2, // local
      (b) => b[0x21c] = 0x11, // data
      (b) => b[0x21d] = 2, // hidden
      (b) => Binary.put64(b, 0x1c8, 2), // non-executable section
      (b) => Binary.put64(b, 0x220, 0x1010), // function outside section
      (b) => Binary.put32(b, 0x168, 99), // bad string table link
      (b) => Binary.put64(b, 0x178, 1), // bad symbol stride
      (b) => Binary.put64(b, 0x198, 0x3ff), // truncated strings
      (b) => Binary.put16(b, 56, 0), // no loader mappings
      (b) => Binary.put32(b, 0x284, 4), // loader mapping is not executable
      (b) => Binary.put64(b, 0x290, 0x2000), // section lies outside the load mapping
      (b) => Binary.put32(b, 0x2b8, 0), // no runtime dynamic table
      (b) => Binary.put64(b, 0x88, 0x210), // runtime symtab differs from section
    ]) {
      final bytes = core();
      mutate(bytes);
      file.writeAsBytesSync(bytes);
      expect(ElfCoreLibrary.isX64(file, requiredExport: 'retro_anyps5_dev9_bind_v1'), isFalse);
    }
    file.deleteSync();
    expect(ElfCoreLibrary.isX64(file), isFalse);
  });
}
