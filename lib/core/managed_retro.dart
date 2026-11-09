import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;

import 'binary.dart';
import 'game_library.dart';
import 'online/ps1_netplay_media.dart';
import 'toolkit_download.dart';

class ManagedRetro {
  ManagedRetro(this.root, {this.packageDirectory, this.ps3CoreDigests, this.ps2LanCoreDigests});

  final String root;
  final String? packageDirectory;
  final String? ps3CoreDigests;
  final String? ps2LanCoreDigests;
  static const _patchedPs2Archive = '2df47bc025ff7dfdfce5594b709fa25884667acdff698334ed2d4942a8dc67f7';
  static const _patchedPs2Library = '801af1211407964a4851839c3f4e90607f18353671dd1e427f56e12201d712a4';
  static final _ps2LanChecks = <String, ({FileStat stat, String digest, bool valid})>{};
  static const _ps1NetplayArchive = '86ab673a1a1b4260dc73256955d600dd64a5ee57e78e17696ae3504791a6633e';
  static const _ps1OrdinaryHandoffArchive = 'df69b0ad16984b34240b875fa14bcb6a742daaaf9bbb5815e448510b810de036';
  // This package persists native SPU objects across launches. Keep the old
  // core out of the default pins so a launcher build with the matching ZIP
  // upgrades an already installed legacy core before booting a PS3 title.
  static const _patchedPs3Archive = 'd472de683cb57aba711453e214a6da91420486a5d739e5cba2d492de300f8083';
  static const _patchedPs3Library = '874b90826fccd5eb162fbdbe2e48a970e21a09867d4167c8eee63f4b16ad6d51';

  static String libraryName(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => 'swanstation_libretro.dll',
    RetroPlatform.ps2 => 'pcsx2_libretro.dll',
    RetroPlatform.ps3 => 'rpcs3_libretro.dll',
  };

  static String platformName(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => 'PS1',
    RetroPlatform.ps2 => 'PS2',
    RetroPlatform.ps3 => 'PS3',
  };

  bool isInstalled(RetroPlatform platform) => _windowsX64Library(File(p.join(root, libraryName(platform))));

  Future<String?> verifiedPs1NetplayBios(String? offlinePath) async {
    final home = Directory(root);
    if (await home.exists()) {
      final target = Directory(p.join(await home.resolveSymbolicLinks(), 'PS1-Netplay'));
      final imported = File(p.join(target.path, 'scph1001.bin'));
      if (await target.exists() &&
          p.equals(await target.resolveSymbolicLinks(), target.path) &&
          await imported.exists() &&
          p.equals(await imported.resolveSymbolicLinks(), imported.path) &&
          await _matchesPs1NetplayBios(imported)) {
        return imported.path;
      }
    }
    return offlinePath != null && await _matchesPs1NetplayBios(File(offlinePath)) ? offlinePath : null;
  }

  static Future<bool> _matchesPs1NetplayBios(File file) async {
    try {
      return await file.length() == 512 * 1024 && await AssetDownload.sha256Of(file.path) == Ps1NetplayMedia.biosPin;
    } on FileSystemException {
      return false;
    }
  }

  Future<String> importPs1NetplayBios(String source) async {
    const size = 512 * 1024;
    final file = await File(source).open();
    final Uint8List bytes;
    try {
      bytes = await file.read(size + 1);
    } finally {
      await file.close();
    }
    if (bytes.length != size || sha256.convert(bytes).toString() != Ps1NetplayMedia.biosPin) {
      throw const FormatException('Select the matching SCPH-1001 BIOS dump for PS1 online play.');
    }
    final home = await Directory(root).create(recursive: true);
    final target = await Directory(p.join(await home.resolveSymbolicLinks(), 'PS1-Netplay')).create();
    if (!p.equals(await target.resolveSymbolicLinks(), target.path)) {
      throw const FormatException('The PS1 netplay BIOS directory redirects outside its assigned path.');
    }
    final path = p.join(target.path, 'scph1001.bin');
    final stage = await target.createTemp('bios-');
    try {
      final staged = await File(p.join(stage.path, 'scph1001.bin')).writeAsBytes(bytes, flush: true);
      await staged.rename(path);
    } finally {
      await stage.delete(recursive: true);
    }
    return path;
  }

  /// Checkpoint handoff has its own core. Never upgrade the offline PS1 DLL.
  Future<String> ensurePs1NetplayCore({Ps1NetplayExecution execution = Ps1NetplayExecution.standard}) async {
    final ordinary = execution == Ps1NetplayExecution.ordinaryHandoff;
    final (directory, archiveName, archivePin, corePin) = ordinary
        ? (
            'PS1-Netplay-Ordinary',
            'swanstation-netplay-ordinary.zip',
            _ps1OrdinaryHandoffArchive,
            Ps1NetplayMedia.ordinaryHandoffCorePin,
          )
        : ('PS1-Netplay', 'swanstation-netplay.zip', _ps1NetplayArchive, Ps1NetplayMedia.portableCorePin);
    final home = await Directory(root).create(recursive: true);
    final resolvedHome = await home.resolveSymbolicLinks();
    final target = Directory(p.join(resolvedHome, directory));
    final name = libraryName(RetroPlatform.ps1);
    final installed = File(p.join(target.path, name));
    if (await target.exists() && !p.equals(await target.resolveSymbolicLinks(), target.path)) {
      throw const FormatException('The PS1 netplay core directory redirects outside its assigned path.');
    }
    Future<bool> pinned(File file) async =>
        await file.exists() &&
        p.equals(await file.resolveSymbolicLinks(), file.path) &&
        await AssetDownload.sha256Of(file.path) == corePin;
    if (await pinned(installed)) return installed.path;
    final legacy = File(p.join(resolvedHome, name));
    if (!ordinary && await pinned(legacy)) return legacy.path;

    final packages = packageDirectory;
    if (packages == null || !p.isAbsolute(packages)) {
      throw const FormatException('The PS1 netplay core package is missing.');
    }
    final source = File(p.join(packages, archiveName));
    final info = await source.stat();
    if (info.type != FileSystemEntityType.file || info.size <= 0 || info.size > 32 * 1024 * 1024) {
      throw const FormatException('The PS1 netplay core package is missing or has an unexpected size.');
    }
    final staging = await home.createTemp('ps1-netplay-package-');
    try {
      final archive = File(p.join(staging.path, 'core.zip'));
      await source.openRead(0, info.size).pipe(archive.openWrite());
      if (await AssetDownload.sha256Of(archive.path) != archivePin) {
        throw const FormatException('The PS1 netplay core package did not pass verification.');
      }
      await target.create();
      if (!p.equals(await target.resolveSymbolicLinks(), target.path)) {
        throw const FormatException('The PS1 netplay core directory redirects outside its assigned path.');
      }
      await _publishCore(
        name,
        archive.path,
        destination: target.path,
        verify: (file) async {
          if (!await pinned(file)) throw const FormatException('The PS1 netplay core did not pass verification.');
        },
      );
      return installed.path;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// Imports are enabled only for the explicitly configured reviewer package.
  Future<String?> verifiedPs3UpdateCore() async {
    if (ps3CoreDigests == null) return null;
    try {
      final (_, digest) = _coreDigests(ps3CoreDigests, (_patchedPs3Archive, _patchedPs3Library), 'PS3');
      final expected = p.join(await Directory(root).resolveSymbolicLinks(), libraryName(RetroPlatform.ps3));
      final file = File(expected);
      if (!p.equals(await file.resolveSymbolicLinks(), expected) ||
          !_windowsX64Library(file, requiredExport: 'retro_anyps5_ps3_network_policy_v1')) {
        return null;
      }
      return await AssetDownload.sha256Of(expected) == digest ? expected : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  bool get supportsPs2Lan => _ps2LanLibrary(File(p.join(root, libraryName(RetroPlatform.ps2))));

  static bool _ps2LanLibrary(File library) => _windowsX64Library(library, requiredExport: 'retro_anyps5_dev9_bind_v1');

  String get _ps2LanHome => p.join(root, 'PS2-LAN');

  String? get configuredPs2LanPackage {
    final directory = packageDirectory;
    if (directory == null || !p.isAbsolute(directory)) return null;
    final archive = File(p.join(directory, '${libraryName(RetroPlatform.ps2)}.zip'));
    return archive.existsSync() ? archive.path : null;
  }

  String? get installedPs2LanHome {
    final library = File(p.join(_ps2LanHome, libraryName(RetroPlatform.ps2)));
    final stat = library.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0 || stat.size > 128 * 1024 * 1024) return null;
    try {
      final (_, digest) = _coreDigests(ps2LanCoreDigests, (_patchedPs2Archive, _patchedPs2Library), 'PS2 LAN');
      final key = p.absolute(library.path);
      final cached = _ps2LanChecks[key];
      if (cached != null &&
          cached.digest == digest &&
          cached.stat.modified == stat.modified &&
          cached.stat.changed == stat.changed &&
          cached.stat.size == stat.size) {
        return cached.valid ? _ps2LanHome : null;
      }
      final expected = p.join(Directory(root).resolveSymbolicLinksSync(), p.basename(_ps2LanHome));
      if (!p.equals(Directory(_ps2LanHome).resolveSymbolicLinksSync(), expected)) return null;
      final opened = library.openSync();
      final Uint8List bytes;
      try {
        bytes = opened.readSync(stat.size + 1);
      } finally {
        opened.closeSync();
      }
      final valid = bytes.length == stat.size && sha256.convert(bytes).toString() == digest && _ps2LanLibrary(library);
      _ps2LanChecks[key] = (stat: stat, digest: digest, valid: valid);
      return valid ? _ps2LanHome : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> installPs2Lan(String package) async {
    final (archiveDigest, libraryDigest) = _coreDigests(ps2LanCoreDigests, (
      _patchedPs2Archive,
      _patchedPs2Library,
    ), 'PS2 LAN');
    final source = File(package);
    final info = await source.stat();
    if (info.type != FileSystemEntityType.file || info.size <= 0 || info.size > 16 * 1024 * 1024) {
      throw const FormatException('The PS2 LAN ZIP is missing or has an unexpected size.');
    }
    final directory = await Directory(root).create(recursive: true);
    final stage = await directory.createTemp('ps2-lan-package-');
    try {
      final archive = File(p.join(stage.path, 'core.zip'));
      await source.openRead(0, info.size).pipe(archive.openWrite());
      if (await AssetDownload.sha256Of(archive.path) != archiveDigest) {
        throw const FormatException('The PS2 LAN ZIP did not pass verification.');
      }
      final destination = await Directory(_ps2LanHome).create();
      final expected = p.join(await directory.resolveSymbolicLinks(), p.basename(_ps2LanHome));
      if (!p.equals(await destination.resolveSymbolicLinks(), expected)) {
        throw const FormatException('The PS2 LAN core folder must be separate from the offline emulator.');
      }
      await _publishCore(
        libraryName(RetroPlatform.ps2),
        archive.path,
        destination: destination.path,
        verify: (file) async {
          if (await AssetDownload.sha256Of(file.path) != libraryDigest || !_ps2LanLibrary(file)) {
            throw const FormatException('The PS2 LAN core did not pass verification.');
          }
        },
      );
      _ps2LanChecks.remove(p.absolute(p.join(_ps2LanHome, libraryName(RetroPlatform.ps2))));
    } finally {
      await stage.delete(recursive: true);
    }
  }

  Future<void> install(RetroPlatform platform, {void Function(int, int)? progress}) async {
    final name = libraryName(platform);
    final installed = isInstalled(platform);
    if (platform == RetroPlatform.ps3) {
      final (archiveDigest, libraryDigest) = _coreDigests(ps3CoreDigests, (
        _patchedPs3Archive,
        _patchedPs3Library,
      ), 'PS3');
      if (installed && await AssetDownload.sha256Of(p.join(root, name)) == libraryDigest) return;
      final directory = packageDirectory;
      if (directory == null) {
        throw const FormatException('The PS3 preview requires a verified RPCS3 package.');
      }
      final archive = File(p.join(directory, '$name.zip'));
      if (!p.isAbsolute(directory) || !archive.existsSync()) {
        throw const FormatException('The configured PS3 emulator package is missing.');
      }
      if (await AssetDownload.sha256Of(archive.path) != archiveDigest) {
        throw const FormatException('The configured PS3 emulator package did not pass verification.');
      }
      final size = await archive.length();
      await _publishCore(
        name,
        archive.path,
        verify: (file) async {
          if (await AssetDownload.sha256Of(file.path) != libraryDigest) {
            throw const FormatException('The installed PS3 emulator did not pass verification.');
          }
        },
      );
      progress?.call(size, size);
      return;
    }
    if (installed) return;
    final url = Uri.https('buildbot.libretro.com', '/nightly/windows/x86_64/latest/$name.zip');
    final (size, revision) = await _buildbotPackage(url);
    final digest = switch (revision) {
      0x356fa26d => 'b640a70f660fd0b5ca4adecad5c90281f481a46802a752b9f66e2aa2791474dc',
      0xa7025679 => '1193159038bd8b77bbe099f1b1f46ff3add61ce6b44d6ec5a66611f0cbfe8c10',
      _ => null,
    };
    final zip = p.join(root, 'Downloads', '${revision.toRadixString(16)}-$name.zip');
    await AssetDownload.fetch(
      url,
      zip,
      size: size,
      sha256: digest,
      httpsOnly: true,
      onProgress: (bytes) => progress?.call(bytes, size),
    );
    await _publishCore(
      name,
      zip,
      verify: (candidate) async {
        var checksum = 0;
        await for (final bytes in candidate.openRead()) {
          checksum = getCrc32(bytes, checksum);
        }
        if (checksum != revision) {
          await File(zip).delete();
          throw const FormatException('The core did not match Libretro’s download index. Try again.');
        }
      },
    );
  }

  static (String, String) _coreDigests(String? configured, (String, String) pinned, String label) {
    if (configured == null) return pinned;
    if (!RegExp(r'^[a-fA-F0-9]{64}:[a-fA-F0-9]{64}$').hasMatch(configured) || configured.length != 129) {
      throw FormatException('Set $label core digests to the package and DLL SHA-256 values separated by a colon.');
    }
    return (configured.substring(0, 64).toLowerCase(), configured.substring(65).toLowerCase());
  }

  Future<void> _publishCore(
    String name,
    String archive, {
    String? destination,
    required Future<void> Function(File) verify,
  }) async {
    final directory = await Directory(destination ?? root).create(recursive: true);
    final stage = await directory.createTemp('install-');
    try {
      await SafeUnpack.unpack(archive, stage.path);
      final candidate = File(p.join(stage.path, name));
      if (!_windowsX64Library(candidate)) throw const FormatException('The download contains no Windows x64 core.');
      await verify(candidate);
      await candidate.rename(p.join(directory.path, name));
    } finally {
      await stage.delete(recursive: true);
    }
  }

  static Future<(int, int)> _buildbotPackage(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final listing = await client.getUrl(url.resolve('.index-extended'));
      listing.followRedirects = false;
      final index = await listing.close().timeout(const Duration(seconds: 20));
      if (index.statusCode != HttpStatus.ok) throw const FormatException('Libretro’s download index is unavailable.');
      final text = await utf8.decoder.bind(index).join().timeout(const Duration(seconds: 20));
      final name = url.pathSegments.last;
      for (final line in const LineSplitter().convert(text)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 3 || parts.last != name) continue;
        final revision = int.tryParse(parts[1], radix: 16);
        if (revision == null) break;
        final head = await client.headUrl(url);
        head.followRedirects = false;
        final info = await head.close().timeout(const Duration(seconds: 20));
        final size = info.contentLength;
        await info.drain<void>();
        if (info.statusCode == HttpStatus.ok && size > 0 && size <= 128 * 1024 * 1024) return (size, revision);
        break;
      }
      throw FormatException('Libretro’s download index has no usable package for $name.');
    } finally {
      client.close(force: true);
    }
  }

  String get systemPath => p.join(root, 'system');

  bool get hasPs3Firmware => File(p.join(systemPath, 'rpcs3', 'dev_flash', 'vsh', 'module', 'vsh.self')).existsSync();

  static const ps3FirmwareName = 'PS3UPDAT.PUP';
  static const _ps3FirmwareSize = 206197916;
  static const _ps3FirmwareDigest = '158471fd834f8ea8036136b6aab43cd86c7ba73d79ca30e0af3c0fe0001cf365';

  String get _ps3FirmwarePackage => p.join(systemPath, ps3FirmwareName);

  bool get hasPs3FirmwarePackage => File(_ps3FirmwarePackage).existsSync();

  Future<void> installPs3Firmware({void Function(int, int)? progress}) async {
    if (hasPs3Firmware) return;
    await downloadPs3FirmwarePackage(_ps3FirmwarePackage, progress: progress);
  }

  static Future<bool> isVerifiedPs3FirmwarePackage(File file) async =>
      await file.exists() &&
      await file.length() == _ps3FirmwareSize &&
      await AssetDownload.sha256Of(file.path) == _ps3FirmwareDigest;

  static Future<void> downloadPs3FirmwarePackage(
    String target, {
    void Function(int, int)? progress,
    DownloadCancel? cancel,
  }) async {
    await AssetDownload.fetch(
      Uri.http(
        'dus01.ps3.update.playstation.net',
        '/update/ps3/image/us/2026_0318_a2b60b6ac1d2e49e230144345616927c/PS3UPDAT.PUP',
      ),
      target,
      size: _ps3FirmwareSize,
      sha256: _ps3FirmwareDigest,
      onProgress: (bytes) => progress?.call(bytes, _ps3FirmwareSize),
      cancel: cancel,
    );
  }

  Directory _biosFolder(RetroPlatform platform) =>
      Directory(platform == RetroPlatform.ps1 ? p.join(root, 'system') : p.join(root, 'system', 'pcsx2', 'bios'));

  int _biosSize(RetroPlatform platform) => platform == RetroPlatform.ps1 ? 512 * 1024 : 4 * 1024 * 1024;

  bool hasBios(RetroPlatform platform) => biosPath(platform) != null;

  String? biosPath(RetroPlatform platform) {
    final folder = _biosFolder(platform);
    if (!folder.existsSync()) return null;
    final files = folder.listSync(followLinks: false).whereType<File>();
    final matching = files.where(
      (file) => p.extension(file.path).toLowerCase() == '.bin' && file.lengthSync() == _biosSize(platform),
    );
    return matching.where((file) => p.basename(file.path) == 'anyps5-imported.bin').firstOrNull?.path ??
        matching.firstOrNull?.path;
  }

  Future<void> importBios(RetroPlatform platform, String path) async {
    final file = File(path);
    final size = _biosSize(platform);
    if (await file.length() != size) {
      throw FormatException('Select an extracted ${platformName(platform)} BIOS file of ${size ~/ 1024} KiB.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != size || bytes.every((byte) => byte == bytes.first)) {
      throw const FormatException('The selected BIOS file is incomplete.');
    }
    final folder = await _biosFolder(platform).create(recursive: true);
    final target = File(p.join(folder.path, 'anyps5-imported.bin'));
    final staged = await File('${target.path}.part').writeAsBytes(bytes, flush: true);
    await staged.rename(target.path);
  }

  static bool _windowsX64Library(File file, {String? requiredExport}) {
    try {
      final source = file.openSync();
      try {
        final dos = source.readSync(64);
        if (dos.length != 64 || dos[0] != 0x4d || dos[1] != 0x5a) return false;
        final offset = ByteData.sublistView(dos).getUint32(60, Endian.little);
        if (offset < dos.length || offset + 24 > source.lengthSync()) return false;
        source.setPositionSync(offset);
        final header = source.readSync(24);
        if (header.length != 24) return false;
        final pe = ByteData.sublistView(header);
        final dll =
            pe.getUint32(0, Endian.little) == 0x4550 &&
            pe.getUint16(4, Endian.little) == 0x8664 &&
            pe.getUint16(22, Endian.little) & 0x2000 != 0;
        return dll && (requiredExport == null || _hasExport(source, header, requiredExport));
      } finally {
        source.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  // Read the PE32+ export table without loading or executing the DLL.
  static bool _hasExport(RandomAccessFile file, Uint8List coff, String name) {
    final optionalSize = Binary.u16(coff, 20);
    final sectionCount = Binary.u16(coff, 6);
    if (optionalSize < 120 || sectionCount == 0 || sectionCount > 96) return false;
    final optional = file.readSync(optionalSize);
    if (optional.length != optionalSize || Binary.u16(optional, 0) != 0x20b || Binary.u32(optional, 108) == 0) {
      return false;
    }
    final sections = file.readSync(sectionCount * 40);
    if (sections.length != sectionCount * 40) return false;
    final fileSize = file.lengthSync();
    Uint8List? readRva(int rva, int count, {bool executable = false}) {
      if (rva == 0) return null;
      for (var i = 0; i < sections.length; i += 40) {
        final delta = rva - Binary.u32(sections, i + 12);
        if (delta < 0 || delta + count > Binary.u32(sections, i + 16)) continue;
        if (executable && Binary.u32(sections, i + 36) & 0x20000000 == 0) return null;
        final offset = Binary.u32(sections, i + 20) + delta;
        if (offset + count > fileSize) return null;
        file.setPositionSync(offset);
        final bytes = file.readSync(count);
        return bytes.length == count ? bytes : null;
      }
      return null;
    }

    final exportsRva = Binary.u32(optional, 112);
    final exportsSize = Binary.u32(optional, 116);
    if (exportsSize < 40) return false;
    final exports = readRva(exportsRva, 40);
    if (exports == null) return false;
    final count = Binary.u32(exports, 24);
    if (count == 0 || count > 4096) return false;
    final names = readRva(Binary.u32(exports, 32), count * 4);
    if (names == null) return false;
    final expected = [...name.codeUnits, 0];
    for (var index = 0; index < count; index++) {
      final symbol = readRva(Binary.u32(names, index * 4), expected.length);
      if (symbol == null || !symbol.asMap().entries.every((entry) => entry.value == expected[entry.key])) continue;
      final ordinals = readRva(Binary.u32(exports, 36), count * 2);
      if (ordinals == null) return false;
      final ordinal = Binary.u16(ordinals, index * 2);
      if (ordinal >= Binary.u32(exports, 20)) return false;
      final addressTable = Binary.u32(exports, 28);
      if (addressTable == 0) return false;
      final address = readRva(addressTable + ordinal * 4, 4);
      if (address == null) return false;
      final functionRva = Binary.u32(address, 0);
      return (functionRva < exportsRva || functionRva >= exportsRva + exportsSize) &&
          readRva(functionRva, 1, executable: true) != null;
    }
    return false;
  }
}
