import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'retro_optimizer.dart';

typedef RetroLaunchSetting = ({String key, String name, String group, String baseline, String value});

/// Boot settings accepted by the embedded Windows cores. Keep timing-sensitive
/// overrides out of hardware recommendations unless the media warrants them.
abstract final class RetroLaunchOptimizer {
  static const ps1Scale = 'swanstation_GPU_ResolutionScale';
  static const ps2Scale = 'pcsx2_upscale_multiplier';

  static List<RetroLaunchSetting> recommend(RetroDisc disc, RetroHardware? hardware) {
    final adapter = RetroOptimizer.detectedAdapter(disc.platform, hardware);
    if (hardware == null ||
        hardware.displayHeight <= 0 ||
        adapter == null ||
        adapter.name.trim().isEmpty ||
        adapter.dedicatedBytes <= 0) {
      return const [];
    }
    final height = hardware.displayHeight;
    final threads = hardware.logicalProcessors;
    final memory = adapter.dedicatedBytes;
    const gib = 1 << 30;
    final ps1Scale = disc.platform == RetroPlatform.ps1 ? _ps1ScaleFor(height, memory) : 1;
    RetroLaunchSetting graphics(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'Graphics', baseline: baseline, value: value);
    RetroLaunchSetting cpu(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'CPU', baseline: baseline, value: value);
    RetroLaunchSetting io(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'I/O and cache', baseline: baseline, value: value);

    return switch (disc.platform) {
      RetroPlatform.ps1 => [
        graphics('swanstation_GPU_Renderer', 'Renderer', 'D3D11', 'D3D11'),
        graphics(RetroLaunchOptimizer.ps1Scale, 'Internal resolution', '1', '$ps1Scale'),
        graphics(
          'swanstation_GPU_TextureFilter',
          'Texture filtering',
          'Nearest',
          ps1Scale > 1 ? 'BilinearBinAlpha' : 'Nearest',
        ),
        cpu('swanstation_CPU_ExecutionMode', 'CPU execution', 'Recompiler', 'Recompiler'),
        io('swanstation_CDROM_ReadThread', 'Disc read thread', 'true', 'true'),
        if (threads >= 8 && _hasCompressedPs1Disc(disc.path))
          io('swanstation_CDROM_ReadaheadSectors', 'Compressed disc read-ahead', '8', '16'),
      ],
      RetroPlatform.ps2 => [
        graphics('pcsx2_renderer', 'Renderer', 'D3D11', 'D3D11'),
        graphics(
          ps2Scale,
          'Internal resolution',
          '1x (Native)',
          height >= 1440 && memory >= 8 * gib && threads >= 6
              ? '4x'
              : height >= 720 && memory >= 2 * gib
              ? '2x'
              : '1x (Native)',
        ),
        graphics(
          'pcsx2_anisotropic_filtering',
          'Anisotropic filtering',
          'disabled',
          memory >= 8 * gib
              ? '8x'
              : memory >= 2 * gib
              ? '4x'
              : 'disabled',
        ),
        graphics('pcsx2_trilinear_filtering', 'Trilinear filtering', 'Automatic', 'Automatic'),
        // Leave MTVU and fast CD/DVD at the existing title configuration.
        io('pcsx2_disable_shader_cache', 'Disable shader cache', 'disabled', 'disabled'),
      ],
      RetroPlatform.ps3 => [
        graphics(
          'rpcs3_resolution_scale',
          'Internal resolution',
          '100',
          height >= 1440 && memory >= 12 * gib && threads >= 12
              ? '200'
              : height >= 1080 && memory >= 8 * gib && threads >= 8
              ? '150'
              : '100',
        ),
        graphics(
          'rpcs3_anisotropic_filter',
          'Anisotropic filtering',
          'auto',
          memory >= 8 * gib
              ? '8'
              : memory >= 4 * gib
              ? '4'
              : 'auto',
        ),
        cpu('rpcs3_ppu_decoder', 'PPU decoder', 'llvm', 'llvm'),
        cpu('rpcs3_spu_decoder', 'SPU decoder', 'llvm', 'llvm'),
        io('rpcs3_llvm_precompilation', 'LLVM precompilation', 'enabled', 'enabled'),
        io('rpcs3_spu_cache', 'SPU cache', 'enabled', 'enabled'),
      ],
    };
  }

  static bool _hasCompressedPs1Disc(String path) {
    final extension = p.extension(path).toLowerCase();
    if (extension == '.chd') return true;
    if (extension != '.m3u') return false;
    try {
      return GameLibrary.ps1PlaylistDiscs(path).any((disc) => p.extension(disc).toLowerCase() == '.chd');
    } on FileSystemException {
      return false;
    }
  }

  static int _ps1ScaleFor(int height, int memory) {
    const gib = 1 << 30;
    final memoryLimit = memory >= 8 * gib
        ? 4
        : memory >= 4 * gib
        ? 3
        : memory >= 2 * gib
        ? 2
        : 1;
    return ((height + 239) ~/ 240).clamp(1, memoryLimit);
  }

  static String label(String key, String value) => switch ((key, value)) {
    (ps1Scale, _) => '$value×',
    ('rpcs3_resolution_scale', _) => '$value%',
    ('rpcs3_anisotropic_filter', 'auto') => 'Auto',
    ('rpcs3_anisotropic_filter', _) => '$value×',
    ('swanstation_GPU_TextureFilter', 'BilinearBinAlpha') => 'Bilinear (sharp alpha edges)',
    (_, 'true' || 'enabled') => 'On',
    (_, 'false' || 'disabled') => 'Off',
    (_, 'llvm') => 'LLVM recompiler',
    _ => value,
  };
}
