import 'retro_host_protocol.dart';

/// One SwanStation picture setting the Graphics page shows: its core option key and the keys of
/// its plain name and one-line description in the launcher's languages.
class RetroGraphicsSetting {
  const RetroGraphicsSetting(this.key, this.name, this.detail);

  final String key;
  final String name;
  final String detail;
}

/// The three ready-made looks of the Graphics page.
enum RetroGraphicsPreset { original, enhanced, maximum }

/// SwanStation's picture settings (src/libretro/libretro_core_options.h) as the Graphics page
/// shows them, the values each preset asks for, and how a wanted value is matched to one the host
/// offers (protocol.md "status": an option's `values`).
abstract final class RetroGraphicsCatalog {
  static const resolution = 'swanstation_GPU_ResolutionScale';
  static const textureFilter = 'swanstation_GPU_TextureFilter';
  static const antialiasing = 'swanstation_GPU_MSAA';
  static const trueColor = 'swanstation_GPU_TrueColor';
  static const scaledDithering = 'swanstation_GPU_ScaledDithering';
  static const chromaSmoothing = 'swanstation_GPU_ChromaSmoothing24Bit';
  static const disableInterlacing = 'swanstation_GPU_DisableInterlacing';
  static const downsample = 'swanstation_GPU_DownsampleMode';
  static const widescreen = 'swanstation_GPU_WidescreenHack';
  static const pgxp = 'swanstation_GPU_PGXPEnable';
  static const pgxpTextures = 'swanstation_GPU_PGXPTextureCorrection';
  static const pgxpCulling = 'swanstation_GPU_PGXPCulling';
  static const pgxpColors = 'swanstation_GPU_PGXPColorCorrection';
  static const pgxpDepth = 'swanstation_GPU_PGXPDepthBuffer';

  /// In the order the page lists them. SwanStation lists the PGXP options after the first only
  /// while geometry correction is on, so the host offers them only then.
  static const settings = [
    RetroGraphicsSetting(resolution, 'retroGfxResolution', 'retroGfxResolutionDetail'),
    RetroGraphicsSetting(textureFilter, 'retroGfxTextures', 'retroGfxTexturesDetail'),
    RetroGraphicsSetting(antialiasing, 'retroGfxEdges', 'retroGfxEdgesDetail'),
    RetroGraphicsSetting(pgxp, 'retroGfxGeometry', 'retroGfxGeometryDetail'),
    RetroGraphicsSetting(pgxpTextures, 'retroGfxStraightTextures', 'retroGfxStraightTexturesDetail'),
    RetroGraphicsSetting(pgxpCulling, 'retroGfxGaps', 'retroGfxGapsDetail'),
    RetroGraphicsSetting(pgxpColors, 'retroGfxShading', 'retroGfxShadingDetail'),
    RetroGraphicsSetting(pgxpDepth, 'retroGfxDepth', 'retroGfxDepthDetail'),
    RetroGraphicsSetting(trueColor, 'retroGfxTrueColor', 'retroGfxTrueColorDetail'),
    RetroGraphicsSetting(scaledDithering, 'retroGfxDithering', 'retroGfxDitheringDetail'),
    RetroGraphicsSetting(chromaSmoothing, 'retroGfxVideos', 'retroGfxVideosDetail'),
    RetroGraphicsSetting(disableInterlacing, 'retroGfxProgressive', 'retroGfxProgressiveDetail'),
    RetroGraphicsSetting(downsample, 'retroGfxDownsample', 'retroGfxDownsampleDetail'),
    RetroGraphicsSetting(widescreen, 'retroGfxWidescreen', 'retroGfxWidescreenDetail'),
  ];

  static final _keys = {for (final setting in settings) setting.key};

  /// Whether [key] is one of the Graphics page's settings.
  static bool covers(String key) => _keys.contains(key);

  /// The page's settings that [options] lists, in the page's order.
  static List<(RetroGraphicsSetting, RetroOption)> present(Map<String, RetroOption> options) => [
    for (final setting in settings)
      if (options[setting.key] case final RetroOption option) (setting, option),
  ];

  /// What each preset asks for. Original is SwanStation's own defaults; the widescreen hack is
  /// left to the player, since it breaks 2D games and pre-rendered backgrounds. PGXP's other
  /// options are SwanStation's defaults when geometry correction is turned on.
  static const _presets = {
    RetroGraphicsPreset.original: {
      resolution: '1',
      textureFilter: 'Nearest',
      antialiasing: '1',
      pgxp: 'false',
      trueColor: 'false',
      scaledDithering: 'true',
      chromaSmoothing: 'false',
      disableInterlacing: 'true',
      downsample: 'Disabled',
    },
    RetroGraphicsPreset.enhanced: {
      resolution: '4',
      textureFilter: 'Bilinear',
      antialiasing: '1',
      pgxp: 'true',
      pgxpTextures: 'true',
      pgxpCulling: 'true',
      trueColor: 'false',
      scaledDithering: 'true',
      chromaSmoothing: 'true',
      disableInterlacing: 'true',
      downsample: 'Disabled',
    },
    RetroGraphicsPreset.maximum: {
      resolution: '8',
      textureFilter: 'xBR',
      antialiasing: '4',
      pgxp: 'true',
      pgxpTextures: 'true',
      pgxpCulling: 'true',
      trueColor: 'true',
      scaledDithering: 'true',
      chromaSmoothing: 'true',
      disableInterlacing: 'true',
      downsample: 'Disabled',
    },
  };

  /// [preset]'s values, each matched to one [options] offers; a setting the host does not list,
  /// or none of whose values fits, is left out.
  static Map<String, String> presetValues(RetroGraphicsPreset preset, Map<String, RetroOption> options) =>
      fitAll(_presets[preset]!, options);

  /// The preset whose values [options] has chosen, or null for a look of the player's own.
  static RetroGraphicsPreset? matching(Map<String, RetroOption> options) {
    for (final preset in RetroGraphicsPreset.values) {
      final values = presetValues(preset, options);
      if (values.isNotEmpty && values.entries.every((entry) => selectedValue(options[entry.key]!) == entry.value)) {
        return preset;
      }
    }
    return null;
  }

  /// [wanted] matched to [options], as [fit] does each one.
  static Map<String, String> fitAll(Map<String, String> wanted, Map<String, RetroOption> options) => {
    for (final MapEntry(:key, :value) in wanted.entries)
      if (options[key] case final RetroOption option)
        if (fit(option, value) case final String fitted) key: fitted,
  };

  /// The value of [option] to use for [wanted]: [wanted] itself when the host offers it. For a
  /// number (an internal resolution, a multisample count), the largest whole number offered that
  /// is not above it, since the host lists only the resolutions its frames can carry. Otherwise
  /// null.
  static String? fit(RetroOption option, String wanted) {
    if (option.values.contains(wanted)) return wanted;
    final limit = int.tryParse(wanted);
    if (limit == null) return null;
    int? best;
    for (final value in option.values) {
      final number = int.tryParse(value);
      if (number != null && number <= limit && (best == null || number > best)) best = number;
    }
    return best?.toString();
  }

  /// The value [option] has chosen.
  static String selectedValue(RetroOption option) => option.values[option.selected];

  /// The label the host gives [value] of [option], or [value] itself.
  static String label(RetroOption option, String value) {
    final index = option.values.indexOf(value);
    return index < 0 ? value : option.labels[index];
  }
}
