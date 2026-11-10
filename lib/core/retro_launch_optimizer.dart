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
    final height = hardware?.displayHeight ?? 0;
    final cores = hardware?.logicalProcessors ?? 0;
    final vram = adapter?.dedicatedBytes ?? 0;
    final scale = hardware == null || adapter == null || disc.platform == RetroPlatform.ps3
        ? 1
        : RetroOptimizer.recommend(
                platform: disc.platform,
                mode: RetroOptimizationMode.quality,
                hardware: hardware,
                renderer: null,
                adapter: adapter.name,
              )?.scale.clamp(1, 4) ??
              1;
    RetroLaunchSetting graphics(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'Graphics', baseline: baseline, value: value);
    RetroLaunchSetting cpu(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'CPU', baseline: baseline, value: value);
    RetroLaunchSetting io(String key, String name, String baseline, String value) =>
        (key: key, name: name, group: 'I/O and cache', baseline: baseline, value: value);

    return switch (disc.platform) {
      RetroPlatform.ps1 => [
        if (adapter != null) graphics('swanstation_GPU_Renderer', 'Renderer', 'D3D11', 'D3D11'),
        graphics(ps1Scale, 'Internal resolution', '1', '$scale'),
        graphics(
          'swanstation_GPU_TextureFilter',
          'Texture filtering',
          'Nearest',
          scale > 1 ? 'BilinearBinAlpha' : 'Nearest',
        ),
        cpu('swanstation_CPU_ExecutionMode', 'CPU execution', 'Recompiler', 'Recompiler'),
        io('swanstation_CDROM_ReadThread', 'Disc read thread', 'true', 'true'),
        if (p.extension(disc.path).toLowerCase() == '.chd' && cores >= 8)
          io('swanstation_CDROM_ReadaheadSectors', 'Compressed disc read-ahead', '8', '16'),
      ],
      RetroPlatform.ps2 => [
        if (adapter != null) graphics('pcsx2_renderer', 'Renderer', 'D3D11', 'D3D11'),
        graphics(
          ps2Scale,
          'Internal resolution',
          '1x (Native)',
          scale >= 4
              ? '4x'
              : scale >= 2
              ? '2x'
              : '1x (Native)',
        ),
        graphics(
          'pcsx2_anisotropic_filtering',
          'Anisotropic filtering',
          'disabled',
          scale >= 4
              ? '8x'
              : scale >= 2
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
          height >= 1440 && vram >= (8 << 30) && cores >= 8 ? '150' : '100',
        ),
        graphics(
          'rpcs3_anisotropic_filter',
          'Anisotropic filtering',
          'auto',
          vram >= (8 << 30)
              ? '8'
              : vram >= (4 << 30)
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
