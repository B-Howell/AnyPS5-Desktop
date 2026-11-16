import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/ps2_bios.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixtures.dart';

/// A made-up image of a BIOS's shape, never a real one (anyps5-retro-host docs/ps2.md "The BIOS":
/// no BIOS is put in a test): [length] bytes of zeros with a ROM directory at [table], as LRPS2's
/// `IsBIOS` reads one. Its first entry is RESET, whose file covers everything before the table, then
/// ROMDIR (the table itself), EXTINFO and ROMVER, each file following the last on a 16-byte
/// boundary, and an empty entry that ends the table. [romver] is ROMVER's 14 bytes.
Uint8List biosShaped({
  int length = Ps2Bios.minBytes,
  int table = 0x2700,
  String romver = '0220AC20060210',
  bool withRomver = true,
  int extinfoBytes = 0x20,
}) {
  final image = Uint8List(length);
  final data = ByteData.sublistView(image);
  var entry = table;
  void add(String name, int size) {
    image.setRange(entry, entry + name.length, ascii.encode(name));
    data.setUint32(entry + 12, size, Endian.little);
    entry += 16;
  }

  add('RESET', table);
  add('ROMDIR', 0x50);
  add('EXTINFO', extinfoBytes);
  if (withRomver) add('ROMVER', 14);
  final romverAt = table + 0x50 + ((extinfoBytes + 15) & ~15);
  if (withRomver && romverAt + 14 <= length) image.setRange(romverAt, romverAt + 14, ascii.encode(romver));
  return image;
}

void main() {
  late Directory temp;
  setUp(() => temp = temporaryFolder('ps2-bios'));
  tearDown(() => temp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File(p.join(temp.path, name))..writeAsBytesSync(bytes);

  Future<Ps2BiosRefusal> refusal(File file) async {
    try {
      await Ps2Bios.check(file);
    } on Ps2BiosRefused catch (refused) {
      return refused.reason;
    }
    fail('${p.basename(file.path)} was taken as a BIOS');
  }

  test('an image of the shape LRPS2 takes gives its ROMVER: region, version and year', () async {
    final bios = await Ps2Bios.check(write('scph-shape.bin', biosShaped()));
    expect(bios.fileName, 'scph-shape.bin');
    expect(bios.version, '0220AC20060210');
    expect((bios.region, bios.versionNumber, bios.year), ('A', '2.20', '2006'));

    final japan = await Ps2Bios.check(write('j.bin', biosShaped(length: Ps2Bios.maxBytes, romver: '0100JC20000117')));
    expect((japan.region, japan.versionNumber, japan.year), ('J', '1.00', '2000'));
  });

  test('a file of another size is refused before it is read, as LRPS2 never looks at it', () async {
    expect(await refusal(write('small.bin', biosShaped(length: Ps2Bios.minBytes - 16))), Ps2BiosRefusal.size);
    expect(await refusal(write('large.bin', biosShaped(length: Ps2Bios.maxBytes + 16))), Ps2BiosRefusal.size);
    expect(await refusal(write('empty.bin', const [])), Ps2BiosRefusal.size);
    expect(await refusal(File(p.join(temp.path, 'missing.bin'))), Ps2BiosRefusal.unreadable);
  });

  test('RESET counts only as a whole name on a 16-byte boundary', () async {
    expect(await refusal(write('zeros.bin', Uint8List(Ps2Bios.minBytes))), Ps2BiosRefusal.noDirectory);
    final shifted = Uint8List(Ps2Bios.minBytes)..setRange(8, 8 + 0x80, biosShaped().sublist(0x2700, 0x2780));
    expect(await refusal(write('shifted.bin', shifted)), Ps2BiosRefusal.noDirectory);
    final longer = biosShaped()..[0x2700 + 5] = 0x53;
    expect(await refusal(write('resets.bin', longer)), Ps2BiosRefusal.noDirectory, reason: '"RESETS" is not RESET');
    final last = Uint8List(Ps2Bios.minBytes);
    last.setRange(last.length - 16, last.length - 11, ascii.encode('RESET'));
    expect(await refusal(write('last.bin', last)), Ps2BiosRefusal.noVersion, reason: 'found, but no entry after it');
  });

  test('a table without ROMVER, or whose ROMVER lies past the end, is not a BIOS', () async {
    expect(await refusal(write('no-romver.bin', biosShaped(withRomver: false))), Ps2BiosRefusal.noVersion);
    expect(
      await refusal(write('past-end.bin', biosShaped(extinfoBytes: Ps2Bios.minBytes - 0x2750))),
      Ps2BiosRefusal.noVersion,
      reason: "ROMVER's bytes would start at the end of the file",
    );
    expect(
      await refusal(write('extinfo.bin', biosShaped(table: Ps2Bios.minBytes - 0x60))),
      Ps2BiosRefusal.noVersion,
      reason: "EXTINFO's serial is past the end, which ends the table before ROMVER",
    );
  });

  test("a file size that overflows LRPS2's 32-bit rounding moves the offset as LRPS2 does", () async {
    final wrapped = await Ps2Bios.check(write('wrap.bin', biosShaped(extinfoBytes: 0xfffffff8)));
    expect(
      wrapped.version,
      '?' * 14,
      reason: '(size + 16) & ~15 wraps to 0, so ROMVER is read at the zeros after the table',
    );
  });

  test('an entry name without a zero in its ten bytes ends the table, as strnlen does', () async {
    final image = biosShaped();
    image.setRange(0x2700 + 32, 0x2700 + 42, ascii.encode('EXTINFOXYZ'));
    expect(await refusal(write('unterminated.bin', image)), Ps2BiosRefusal.noVersion);
  });

  group('install', () {
    late String system;
    setUp(() => system = p.join(temp.path, 'system'));

    test('copies the BIOS into pcsx2/bios under its name, with its .nvm and .mec beside it', () async {
      final source = write('SCPH-test.bin', biosShaped());
      write('SCPH-test.nvm', [1, 2, 3]);
      write('SCPH-test.mec', [4]);
      final bios = await Ps2Bios.install(source, system: system);
      final folder = Ps2Bios.folderIn(system);
      expect(folder, p.join(system, 'pcsx2', 'bios'));
      expect(bios.fileName, 'SCPH-test.bin');
      expect(File(p.join(folder, 'SCPH-test.bin')).readAsBytesSync(), source.readAsBytesSync());
      expect(File(p.join(folder, 'SCPH-test.nvm')).readAsBytesSync(), [1, 2, 3]);
      expect(File(p.join(folder, 'SCPH-test.mec')).readAsBytesSync(), [4]);
      expect(Directory(folder).listSync().map((entry) => p.basename(entry.path)).toSet(), {
        'SCPH-test.bin',
        'SCPH-test.nvm',
        'SCPH-test.mec',
      }, reason: 'no partial copy is left');
    });

    test('keeps the console settings LRPS2 already wrote beside the BIOS in its folder', () async {
      final folder = Directory(Ps2Bios.folderIn(system))..createSync(recursive: true);
      File(p.join(folder.path, 'bios.nvm')).writeAsBytesSync([9]);
      final source = write('bios.bin', biosShaped());
      write('bios.nvm', [1]);
      await Ps2Bios.install(source, system: system);
      expect(File(p.join(folder.path, 'bios.nvm')).readAsBytesSync(), [9]);
      expect(File(p.join(folder.path, 'bios.mec')).existsSync(), isFalse, reason: 'none beside the source');
    });

    test('a file that is not a BIOS is not copied, and the folder keeps what it had', () async {
      final folder = Directory(Ps2Bios.folderIn(system))..createSync(recursive: true);
      final kept = File(p.join(folder.path, 'other.bin'))..writeAsBytesSync(biosShaped());
      final wrong = write('other.bin', Uint8List(Ps2Bios.minBytes));
      await expectLater(Ps2Bios.install(wrong, system: system), throwsA(isA<Ps2BiosRefused>()));
      expect(kept.readAsBytesSync(), biosShaped());
      expect(folder.listSync(), hasLength(1));
    });

    test("a name of several dots keeps all but its last extension, as LRPS2 names the BIOS's files", () async {
      final source = write('SCPH-39001.v7.bin', biosShaped());
      write('SCPH-39001.v7.nvm', [1]);
      write('SCPH-39001.nvm', [2]);
      await Ps2Bios.install(source, system: system);
      final folder = Ps2Bios.folderIn(system);
      expect(File(p.join(folder, 'SCPH-39001.v7.nvm')).readAsBytesSync(), [1]);
      expect(File(p.join(folder, 'SCPH-39001.nvm')).existsSync(), isFalse);
    });

    test('a copy that fails part way leaves nothing behind, so the next try copies everything', () async {
      final source = write('bios.bin', biosShaped());
      write('bios.nvm', [1]);
      write('bios.mec', [2]);
      final folder = Directory(Ps2Bios.folderIn(system))..createSync(recursive: true);
      final blocker = Directory(p.join(folder.path, 'bios.mec.partial'))..createSync();
      await expectLater(Ps2Bios.install(source, system: system), throwsA(isA<FileSystemException>()));
      expect(folder.listSync().map((entry) => p.basename(entry.path)), ['bios.mec.partial']);
      blocker.deleteSync();
      await Ps2Bios.install(source, system: system);
      expect(folder.listSync().map((entry) => p.basename(entry.path)).toSet(), {'bios.bin', 'bios.nvm', 'bios.mec'});
    });

    test('the BIOS already in the folder is taken where it is', () async {
      final folder = Directory(Ps2Bios.folderIn(system))..createSync(recursive: true);
      final inside = File(p.join(folder.path, 'inside.bin'))..writeAsBytesSync(biosShaped());
      final bios = await Ps2Bios.install(inside, system: system);
      expect(bios.fileName, 'inside.bin');
      expect(folder.listSync(), hasLength(1));
    });
  });
}
