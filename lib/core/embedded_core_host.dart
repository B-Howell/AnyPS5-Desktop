import 'dart:ffi' show Abi;

import 'game_library.dart';

enum EmbeddedCoreHost {
  windowsX64,
  linuxX64;

  static EmbeddedCoreHost? get current => switch (Abi.current()) {
    Abi.windowsX64 => windowsX64,
    Abi.linuxX64 => linuxX64,
    _ => null,
  };

  String libraryName(RetroPlatform platform) {
    final base = switch (platform) {
      RetroPlatform.ps1 => 'swanstation_libretro',
      RetroPlatform.ps2 => 'pcsx2_libretro',
      RetroPlatform.ps3 => 'rpcs3_libretro',
    };
    return '$base.${this == linuxX64 ? 'so' : 'dll'}';
  }

  String get buildbotPlatform => this == linuxX64 ? 'linux' : 'windows';
}
