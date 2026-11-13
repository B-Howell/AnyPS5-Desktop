import 'dart:math' as math;

import 'retro_graphics_catalog.dart';
import 'retro_hardware.dart';
import 'retro_host_protocol.dart';

/// Why the Auto Optimizer has nothing to suggest.
enum RetroOptimizeBlock {
  /// The computer could not be read (neither Windows nor Linux, or no display).
  noHardware,

  /// No single graphics adapter with memory of its own could be told apart.
  noAdapter,

  /// The game draws with SwanStation's software renderer (`status.hardware` is false), where the
  /// internal resolution and smoothing do nothing.
  software,
}

/// What the Auto Optimizer suggests for one game on this computer: the values, each one the host
/// offers, and what it read to choose them.
class RetroGraphicsAdvice {
  const RetroGraphicsAdvice({
    required this.adapter,
    required this.displayHeight,
    required this.threads,
    required this.values,
  });

  final RetroAdapter adapter;
  final int displayHeight;
  final int threads;

  /// By option key, in the Graphics page's order.
  final Map<String, String> values;

  /// The values that differ from what [options] has chosen.
  Map<String, String> changesFrom(Map<String, RetroOption> options) => {
    for (final MapEntry(:key, :value) in RetroGraphicsCatalog.fitAll(values, options).entries)
      if (RetroGraphicsCatalog.selectedValue(options[key]!) != value) key: value,
  };
}

/// The Auto Optimizer's answer: advice, or why there is none.
typedef RetroOptimizeResult = ({RetroGraphicsAdvice? advice, RetroOptimizeBlock? blocked});

/// The launcher's Auto Optimizer (claude/integrated-0.1.22 `RetroOptimizer` and
/// `RetroLaunchOptimizer`) for a PS1 game in the emulator host: the internal resolution from the
/// display's height and the adapter's memory, and the smoothing settings from the adapter's memory
/// and the CPU's threads. It picks only values the host's `status` offers.
abstract final class RetroGraphicsOptimizer {
  static const _gib = 1 << 30;

  /// The PS1's usual picture height, which one step of internal resolution adds.
  static const nativeHeight = 240;

  /// The highest internal resolution it suggests, as the launcher's Balanced profile did.
  static const maxScale = 4;

  static RetroOptimizeResult recommend({required RetroHardware? hardware, required RetroStatus status}) {
    if (hardware == null || hardware.displayHeight <= 0) return (advice: null, blocked: RetroOptimizeBlock.noHardware);
    final adapter = selectAdapter(hardware.adapters);
    if (adapter == null) return (advice: null, blocked: RetroOptimizeBlock.noAdapter);
    if (!status.hardware) return (advice: null, blocked: RetroOptimizeBlock.software);
    final memory = adapter.dedicatedBytes;
    final displayScale = (hardware.displayHeight + nativeHeight - 1) ~/ nativeHeight;
    final scale = math.max(1, math.min(displayScale, math.min(maxScale, memoryCap(memory))));
    final wanted = {
      RetroGraphicsCatalog.resolution: '$scale',
      RetroGraphicsCatalog.textureFilter: scale > 1 ? 'BilinearBinAlpha' : 'Nearest',
      RetroGraphicsCatalog.antialiasing: memory >= 8 * _gib ? '2' : '1',
      RetroGraphicsCatalog.pgxp: hardware.logicalProcessors >= 4 ? 'true' : 'false',
      RetroGraphicsCatalog.chromaSmoothing: scale > 1 ? 'true' : 'false',
      RetroGraphicsCatalog.scaledDithering: 'true',
    };
    final values = RetroGraphicsCatalog.fitAll(wanted, status.options);
    return (
      advice: RetroGraphicsAdvice(
        adapter: adapter,
        displayHeight: hardware.displayHeight,
        threads: hardware.logicalProcessors,
        values: {
          for (final setting in RetroGraphicsCatalog.settings)
            if (values[setting.key] case final String value) setting.key: value,
        },
      ),
      blocked: null,
    );
  }

  /// The adapter the game most likely draws on: the only usable one, or the only one with at
  /// least 2 GiB of its own memory.
  static RetroAdapter? selectAdapter(List<RetroAdapter> adapters) {
    final usable = adapters.where((adapter) => adapter.name.trim().isNotEmpty && adapter.dedicatedBytes > 0).toList();
    if (usable.length == 1) return usable.single;
    final discrete = usable.where((adapter) => adapter.dedicatedBytes >= 2 * _gib).toList();
    return discrete.length == 1 ? discrete.single : null;
  }

  /// The highest internal resolution an adapter's own memory is trusted with.
  static int memoryCap(int dedicatedBytes) {
    if (dedicatedBytes >= 12 * _gib) return 6;
    if (dedicatedBytes >= 8 * _gib) return 4;
    if (dedicatedBytes >= 4 * _gib) return 3;
    if (dedicatedBytes >= 2 * _gib) return 2;
    return 1;
  }

  /// One notch less work for the GPU: the next lower internal resolution the host offers, or at
  /// the lowest, the next lower multisample count. Null when both are at their lowest.
  static ({String key, String value})? stepDown(Map<String, RetroOption> options) {
    for (final key in const [RetroGraphicsCatalog.resolution, RetroGraphicsCatalog.antialiasing]) {
      final option = options[key];
      if (option == null) continue;
      final current = int.tryParse(RetroGraphicsCatalog.selectedValue(option));
      if (current == null || current <= 1) continue;
      final lower = RetroGraphicsCatalog.fit(option, '${current - 1}');
      if (lower != null && int.parse(lower) < current) return (key: key, value: lower);
    }
    return null;
  }
}
