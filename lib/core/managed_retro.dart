import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'toolkit_download.dart';

enum ManagedPackageProblem { missing, invalid }

class ManagedPackageException extends FormatException {
  const ManagedPackageException(this.problem, String message) : super(message);

  final ManagedPackageProblem problem;
}

class ManagedRetro {
  ManagedRetro(this.root, {this.packageDirectory, this.ps3CoreDigests});

  final String root;
  final String? packageDirectory;
  final String? ps3CoreDigests;
  static const _patchedPs3Archive = '7bc267dc0a9cffdd21087340ab643c52ed91136606e6d33ae05c477adc7db3a4';
  static const _patchedPs3Library = '7ac7504de83acfa2d977345f8c9b48e92f5e71c576abbf026406e667fe7a1370';

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

  Future<void> install(RetroPlatform platform, {void Function(int, int)? progress}) async {
    final name = libraryName(platform);
    final (archiveDigest, libraryDigest) = switch (platform) {
      // Libretro Buildbot Windows x64, SwanStation 1.0.0 631f0fb.
      RetroPlatform.ps1 => (
        'b640a70f660fd0b5ca4adecad5c90281f481a46802a752b9f66e2aa2791474dc',
        '1aaa621dab9f53b130ac29d17e9a12ea4c0df975d4b02b53faec3b52c717fd12',
      ),
      // Libretro Buildbot Windows x64, ParaLLEl PS2 v2.0.0-da5b07e.
      RetroPlatform.ps2 => (
        '1193159038bd8b77bbe099f1b1f46ff3add61ce6b44d6ec5a66611f0cbfe8c10',
        '47ffaedbaa0d488039feda57d9c8e57ffd3fb97626e67af4780f9219e2bd901c',
      ),
      RetroPlatform.ps3 => _ps3Digests(),
    };
    if (isInstalled(platform) && await AssetDownload.sha256Of(p.join(root, name)) == libraryDigest) return;

    final directory = packageDirectory;
    if (directory == null || !p.isAbsolute(directory)) {
      throw const ManagedPackageException(
        ManagedPackageProblem.missing,
        'Configure an absolute directory with verified emulator packages.',
      );
    }
    final archive = File(p.join(directory, '$name.zip'));
    if (!await archive.exists()) {
      throw const ManagedPackageException(ManagedPackageProblem.missing, 'The configured emulator package is missing.');
    }
    if (await AssetDownload.sha256Of(archive.path) != archiveDigest) {
      throw const ManagedPackageException(
        ManagedPackageProblem.invalid,
        'The configured emulator package did not pass verification.',
      );
    }
    final size = await archive.length();
    await _publishCore(
      name,
      archive.path,
      verify: (file) async {
        if (await AssetDownload.sha256Of(file.path) != libraryDigest) {
          throw const ManagedPackageException(
            ManagedPackageProblem.invalid,
            'The installed emulator did not pass verification.',
          );
        }
      },
    );
    progress?.call(size, size);
  }

  (String, String) _ps3Digests() {
    final configured = ps3CoreDigests;
    if (configured == null) return (_patchedPs3Archive, _patchedPs3Library);
    if (!RegExp(r'^[a-fA-F0-9]{64}:[a-fA-F0-9]{64}$').hasMatch(configured) || configured.length != 129) {
      throw const FormatException('Set PS3 core digests to the package and DLL SHA-256 values separated by a colon.');
    }
    return (configured.substring(0, 64).toLowerCase(), configured.substring(65).toLowerCase());
  }

  Future<void> _publishCore(String name, String archive, {required Future<void> Function(File) verify}) async {
    final directory = await Directory(root).create(recursive: true);
    final stage = await directory.createTemp('install-');
    try {
      await SafeUnpack.unpack(archive, stage.path);
      final candidate = File(p.join(stage.path, name));
      if (!_windowsX64Library(candidate)) throw const FormatException('The download contains no Windows x64 core.');
      await verify(candidate);
      await candidate.rename(p.join(root, name));
    } finally {
      await stage.delete(recursive: true);
    }
  }

  String get systemPath => p.join(root, 'system');

  bool get hasPs3Firmware => File(p.join(systemPath, 'rpcs3', 'dev_flash', 'vsh', 'module', 'vsh.self')).existsSync();

  String get _ps3FirmwarePackage => p.join(systemPath, 'PS3UPDAT.PUP');

  bool get hasPs3FirmwarePackage => File(_ps3FirmwarePackage).existsSync();

  /// Stage a user-supplied PUP. RPCS3 validates and installs it on first boot.
  Future<void> importPs3Firmware(String path) async {
    final folder = await Directory(systemPath).create(recursive: true);
    final stage = await folder.createTemp('firmware-');
    try {
      final candidate = await File(path).copy(p.join(stage.path, 'PS3UPDAT.PUP'));
      final file = await candidate.open();
      try {
        final header = await file.read(48);
        if (header.length != 48 || ascii.decode(header.take(8).toList(), allowInvalid: true) != 'SCEUF\x00\x00\x00') {
          throw const FormatException('Invalid PS3 update header');
        }
        final fields = ByteData.sublistView(header);
        final entryCount = fields.getUint64(24);
        final headerSize = fields.getUint64(32);
        final dataSize = fields.getUint64(40);
        final length = await file.length();
        if (entryCount <= 0 ||
            headerSize < 48 ||
            headerSize > length ||
            entryCount > (headerSize - 48) ~/ 64 ||
            dataSize <= 0 ||
            dataSize > length - headerSize) {
          throw const FormatException('Incomplete PS3 update package');
        }
      } finally {
        await file.close();
      }
      await candidate.rename(_ps3FirmwarePackage);
    } finally {
      await stage.delete(recursive: true);
    }
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

  static bool _windowsX64Library(File file) {
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
        return pe.getUint32(0, Endian.little) == 0x4550 &&
            pe.getUint16(4, Endian.little) == 0x8664 &&
            pe.getUint16(22, Endian.little) & 0x2000 != 0;
      } finally {
        source.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }
}
