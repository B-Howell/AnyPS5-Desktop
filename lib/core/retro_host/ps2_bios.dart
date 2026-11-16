import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Why a file the player picked is not taken as a PS2 BIOS.
enum Ps2BiosRefusal {
  /// It is smaller than 4 MiB or larger than 8 MiB, which LRPS2 never looks at.
  size,

  /// No `RESET` entry of a ROM directory is on a 16-byte boundary in it.
  noDirectory,

  /// Its ROM directory has no `ROMVER` entry whose 14 bytes are in the file.
  noVersion,

  /// It could not be read.
  unreadable,

  /// LRPS2 could not use it under its name: one that starts with a dot, which LRPS2's folder scan
  /// leaves out as hidden, or one that ends in `.nvm` or `.mec`, the names LRPS2 writes the
  /// console's settings and drive version to beside the BIOS, which would overwrite it.
  name,
}

/// A file refused as a PS2 BIOS, and why.
class Ps2BiosRefused implements Exception {
  const Ps2BiosRefused(this.reason);

  final Ps2BiosRefusal reason;

  @override
  String toString() => 'Ps2BiosRefused(${reason.name})';
}

/// The player's own PS2 BIOS, as LRPS2 checks one (anyps5-retro-host docs/ps2.md "The BIOS"): it is
/// never shipped, downloaded, sent to a friend or logged. [check] reads a file the way LRPS2's
/// `IsBIOS` does (`pcsx2/ps2/BiosTools.c` at c0d39a58e), and [install] copies a checked one into
/// the `pcsx2/bios` folder of the host's system directory, where LRPS2 looks for it.
class Ps2Bios {
  const Ps2Bios({required this.fileName, required this.version});

  /// The smallest and largest file LRPS2 takes as a BIOS (`MIN_BIOS_SIZE`, `MAX_BIOS_SIZE`).
  static const minBytes = 4 * 1024 * 1024;
  static const maxBytes = 8 * 1024 * 1024;

  /// A ROM directory entry: a ten-byte name, a two-byte extended size and a four-byte file size.
  static const _entryBytes = 16;

  /// How many entries LRPS2 looks through for `RESET` (`ROMDIR_SCAN_ENTRIES`): 8 MiB of them.
  static const _scanEntries = 512 * 1024;

  /// LRPS2's option that names the BIOS file in its folder it starts with; its values are the
  /// file names of every BIOS it found there, the first one by default.
  static const option = 'pcsx2_bios';

  /// The file's name, kept when it is copied: the [option]'s value names it.
  final String fileName;

  /// The 14 bytes of its `ROMVER` entry, each outside printable ASCII shown as `?`: the version's
  /// two two-digit halves, the region letter, `C` for a console or `D` for a development kit, and
  /// the date as eight digits, year first.
  final String version;

  /// The region letter at the fifth byte of [version] (`J`, `A`, `E`, `H`, `C`, ...).
  String get region => version[4];

  /// The BIOS version, `2.20` for `0220`.
  String get versionNumber {
    final major = int.tryParse(version.substring(0, 2));
    return major == null ? version.substring(0, 4) : '$major.${version.substring(2, 4)}';
  }

  /// The year the BIOS was built, from its date; null when the date is not digits.
  String? get year {
    final digits = version.substring(6, 10);
    return RegExp(r'^\d{4}$').hasMatch(digits) ? digits : null;
  }

  /// The folder of [system] (the host's system directory) LRPS2 looks for a BIOS in.
  static String folderIn(String system) => p.join(system, 'pcsx2', 'bios');

  /// Checks [file] as LRPS2's `IsBIOS` does, with its folder scan's size limits: 4 MiB to 8 MiB; a
  /// `RESET` entry, its ten-byte name `RESET` and a zero, on a 16-byte boundary; then, walking the
  /// table from it, a `ROMVER` entry whose 14 bytes at the offset the entries before it add up to
  /// are in the file. Throws [Ps2BiosRefused] for any other file. It checks the format, not a list
  /// of known dumps.
  static Future<Ps2Bios> check(File file) async {
    final Uint8List bytes;
    try {
      final length = await file.length();
      if (length < minBytes || length > maxBytes) throw const Ps2BiosRefused(Ps2BiosRefusal.size);
      bytes = await file.readAsBytes();
    } on FileSystemException {
      throw const Ps2BiosRefused(Ps2BiosRefusal.unreadable);
    }
    if (bytes.length < minBytes || bytes.length > maxBytes) throw const Ps2BiosRefused(Ps2BiosRefusal.size);
    return Ps2Bios(fileName: p.basename(file.path), version: romVersion(bytes));
  }

  /// The `ROMVER` bytes of a BIOS image, read as `LoadBiosVersion` reads them; throws
  /// [Ps2BiosRefused] when [image] has no ROM directory or no `ROMVER` in it.
  static String romVersion(Uint8List image) {
    final data = ByteData.sublistView(image);
    final entries = image.length ~/ _entryBytes;
    final scanned = entries < _scanEntries ? entries : _scanEntries;
    var reset = -1;
    for (var index = 0; index < scanned; index++) {
      if (_named(image, index * _entryBytes, 'RESET')) {
        reset = index;
        break;
      }
    }
    if (reset < 0) throw const Ps2BiosRefused(Ps2BiosRefusal.noDirectory);

    var entry = reset * _entryBytes;
    var next = reset + 1;
    var offset = 0;
    String? version;
    while (image[entry] != 0 && _terminated(image, entry)) {
      if (_named(image, entry, 'EXTINFO') && offset + 0x10 + 15 > image.length) break;
      if (_named(image, entry, 'ROMVER')) {
        if (offset + 14 > image.length) break;
        version = String.fromCharCodes([
          for (final byte in image.sublist(offset, offset + 14)) byte >= 0x20 && byte < 0x7f ? byte : 0x3f,
        ]);
      }
      final size = data.getUint32(entry + 12, Endian.little);
      offset += size % 0x10 == 0 ? size : (size + 0x10) & 0xfffffff0;
      if ((next + 1) * _entryBytes > image.length) break;
      entry = next++ * _entryBytes;
    }
    if (version == null) throw const Ps2BiosRefused(Ps2BiosRefusal.noVersion);
    return version;
  }

  /// Whether the entry at [at] is named [name]: as `strncmp` over the ten bytes, the name's letters
  /// and then a zero.
  static bool _named(Uint8List image, int at, String name) {
    for (var index = 0; index < name.length; index++) {
      if (image[at + index] != name.codeUnitAt(index)) return false;
    }
    return image[at + name.length] == 0;
  }

  /// Whether the entry at [at] has a zero among its ten name bytes (`strnlen` below ten).
  static bool _terminated(Uint8List image, int at) {
    for (var index = 0; index < 10; index++) {
      if (image[at + index] == 0) return true;
    }
    return false;
  }

  /// Whether LRPS2 can start a BIOS of this file [name] from its folder ([Ps2BiosRefusal.name]).
  static bool usableName(String name) =>
      !name.startsWith('.') && !const {'.nvm', '.mec'}.contains(p.extension(name).toLowerCase());

  /// Copies [source], checked again first, into [folderIn] of [system] under its own name, and
  /// beside it the `.nvm` and `.mec` files of the same name (LRPS2's console settings and drive
  /// version: the BIOS's name with its last extension changed, `cdvdBiosSiblingPath` in
  /// `pcsx2/CDVD/CDVD.c`) when they sit beside [source] and the folder has none of its own yet, so
  /// settings LRPS2 already wrote there are kept. A name LRPS2 could not use is refused
  /// ([usableName]). Every file is first copied into a folder of this install's own, made inside
  /// [folderIn] so no file of the player's can be in its way and a rename moves each file without
  /// copying it again, and the BIOS is checked again there; only when all were copied does
  /// each take its name, the sidecars before the BIOS, and a sidecar placed before a later file
  /// could not take its name is removed again (none was there before), so a copy that fails leaves
  /// no file of it behind.
  /// Returns the BIOS; throws [Ps2BiosRefused] for a file that is not one,
  /// and [FileSystemException] when it cannot be copied.
  static Future<Ps2Bios> install(File source, {required String system}) async {
    final bios = await check(source);
    if (!usableName(bios.fileName)) throw const Ps2BiosRefused(Ps2BiosRefusal.name);
    final folder = Directory(folderIn(system));
    await folder.create(recursive: true);
    final target = File(p.join(folder.path, bios.fileName));
    if (p.equals(p.canonicalize(source.path), p.canonicalize(target.path))) return bios;
    final copies = <(File, File)>[
      for (final extension in const ['.nvm', '.mec'])
        if (File(p.setExtension(source.path, extension)) case final sibling
            when !p.equals(sibling.path, source.path) &&
                sibling.existsSync() &&
                !File(p.join(folder.path, p.basename(sibling.path))).existsSync())
          (sibling, File(p.join(folder.path, p.basename(sibling.path)))),
      (source, target),
    ];
    final staging = await folder.createTemp('.anyps5-staging-');
    final staged = [for (final (_, to) in copies) File(p.join(staging.path, p.basename(to.path)))];
    final placed = <File>[];
    try {
      for (final (index, (from, _)) in copies.indexed) {
        await from.copy(staged[index].path);
      }
      await check(staged.last);
      for (final (index, (_, to)) in copies.indexed) {
        await staged[index].rename(to.path);
        placed.add(to);
      }
    } on Object {
      for (final sidecar in placed.where((file) => !identical(file, target))) {
        if (await sidecar.exists()) await sidecar.delete();
      }
      rethrow;
    } finally {
      await staging.delete(recursive: true);
    }
    return bios;
  }
}
