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
    final name = switch (platform) {
      RetroPlatform.ps1 => 'swanstation_libretro',
      RetroPlatform.ps2 => 'pcsx2_libretro',
      RetroPlatform.ps3 => 'rpcs3_libretro',
    };
    return '$name.${this == windowsX64 ? 'dll' : 'so'}';
  }

  String get buildbotPath => this == windowsX64 ? 'windows/x86_64' : 'linux/x86_64';
}
