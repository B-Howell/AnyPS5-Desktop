import 'package:anyps5_desktop/core/retro_host/retro_graphics_catalog.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_optimizer.dart';
import 'package:anyps5_desktop/core/retro_host/retro_hardware.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../ui/retro_host/fake_option_session.dart';

const _gib = 1 << 30;

RetroHardware _pc({int height = 1440, int memory = 8 * _gib, int threads = 16, List<RetroAdapter>? adapters}) =>
    RetroHardware(
      displayHeight: height,
      adapters: adapters ?? [RetroAdapter(name: 'GeForce RTX 3070', dedicatedBytes: memory)],
      logicalProcessors: threads,
    );

RetroStatus _status({bool hardware = true, List<String>? scales}) {
  final recorded = recordedStatus();
  final options = {...recorded.options};
  if (scales != null) {
    final scale = options[RetroGraphicsCatalog.resolution]!;
    options[RetroGraphicsCatalog.resolution] = RetroOption(
      key: scale.key,
      title: scale.title,
      values: scales,
      labels: [for (final value in scales) '${value}x'],
      selected: 0,
      activeValue: scales.first,
      restart: false,
    );
  }
  return RetroStatus(ready: true, ended: false, error: '', errorCode: '', hardware: hardware, options: options);
}

void main() {
  test('a 1440p display with an 8 GB card: 4x, smooth textures, 2x MSAA, steady 3D, smooth videos', () {
    final result = RetroGraphicsOptimizer.recommend(hardware: _pc(), status: _status());
    expect(result.blocked, isNull);
    final advice = result.advice!;
    expect(advice.adapter.name, 'GeForce RTX 3070');
    expect(advice.values, {
      RetroGraphicsCatalog.resolution: '4',
      RetroGraphicsCatalog.textureFilter: 'BilinearBinAlpha',
      RetroGraphicsCatalog.antialiasing: '2',
      RetroGraphicsCatalog.pgxp: 'true',
      RetroGraphicsCatalog.scaledDithering: 'true',
      RetroGraphicsCatalog.chromaSmoothing: 'true',
    });
    expect(advice.changesFrom(_status().options).keys, isNot(contains(RetroGraphicsCatalog.scaledDithering)));
  });

  test('the resolution follows the display and the card\'s memory', () {
    String scale(RetroHardware pc) => RetroGraphicsOptimizer.recommend(
      hardware: pc,
      status: _status(),
    ).advice!.values[RetroGraphicsCatalog.resolution]!;
    expect(scale(_pc(height: 720)), '3');
    expect(scale(_pc(height: 1080, memory: 2 * _gib)), '2');
    expect(scale(_pc(height: 2160, memory: 16 * _gib)), '4', reason: 'no more than 4x');
    expect(scale(_pc(height: 1080, memory: 1 * _gib)), '1');
    final low = RetroGraphicsOptimizer.recommend(
      hardware: _pc(height: 1080, memory: _gib, threads: 2),
      status: _status(),
    );
    expect(low.advice!.values[RetroGraphicsCatalog.textureFilter], 'Nearest');
    expect(low.advice!.values[RetroGraphicsCatalog.pgxp], 'false');
    expect(low.advice!.values[RetroGraphicsCatalog.antialiasing], '1');
  });

  test('only a resolution the host offers is suggested', () {
    final result = RetroGraphicsOptimizer.recommend(
      hardware: _pc(height: 2160, memory: 16 * _gib),
      status: _status(scales: ['1', '2', '3']),
    );
    expect(result.advice!.values[RetroGraphicsCatalog.resolution], '3');
  });

  test('nothing to suggest without the computer, a single card, or the OpenGL renderer', () {
    expect(RetroGraphicsOptimizer.recommend(hardware: null, status: _status()).blocked, RetroOptimizeBlock.noHardware);
    expect(
      RetroGraphicsOptimizer.recommend(hardware: _pc(height: 0), status: _status()).blocked,
      RetroOptimizeBlock.noHardware,
    );
    final two = _pc(
      adapters: const [
        RetroAdapter(name: 'GeForce RTX 3070', dedicatedBytes: 8 * _gib),
        RetroAdapter(name: 'Radeon RX 6800', dedicatedBytes: 16 * _gib),
      ],
    );
    expect(RetroGraphicsOptimizer.recommend(hardware: two, status: _status()).blocked, RetroOptimizeBlock.noAdapter);
    expect(
      RetroGraphicsOptimizer.recommend(hardware: _pc(), status: _status(hardware: false)).blocked,
      RetroOptimizeBlock.software,
    );
  });

  test('a laptop\'s built-in graphics beside its own card: the card', () {
    const adapters = [
      RetroAdapter(name: 'Intel UHD Graphics', dedicatedBytes: 128 << 20),
      RetroAdapter(name: 'GeForce RTX 4060 Laptop GPU', dedicatedBytes: 8 * _gib),
    ];
    expect(RetroGraphicsOptimizer.selectAdapter(adapters)?.name, 'GeForce RTX 4060 Laptop GPU');
    expect(RetroGraphicsOptimizer.selectAdapter(const [RetroAdapter(name: '', dedicatedBytes: _gib)]), isNull);
  });

  test('one notch down: the next resolution offered, then multisampling', () {
    RetroOption option(String key, List<String> values, String selected) => RetroOption(
      key: key,
      title: key,
      values: values,
      labels: values,
      selected: values.indexOf(selected),
      activeValue: selected,
      restart: false,
    );
    final scales = ['1', '2', '4'];
    final msaa = ['1', '2', '4', '2-ssaa'];
    expect(
      RetroGraphicsOptimizer.stepDown({
        RetroGraphicsCatalog.resolution: option(RetroGraphicsCatalog.resolution, scales, '4'),
        RetroGraphicsCatalog.antialiasing: option(RetroGraphicsCatalog.antialiasing, msaa, '4'),
      }),
      (key: RetroGraphicsCatalog.resolution, value: '2'),
    );
    expect(
      RetroGraphicsOptimizer.stepDown({
        RetroGraphicsCatalog.resolution: option(RetroGraphicsCatalog.resolution, scales, '1'),
        RetroGraphicsCatalog.antialiasing: option(RetroGraphicsCatalog.antialiasing, msaa, '4'),
      }),
      (key: RetroGraphicsCatalog.antialiasing, value: '2'),
    );
    expect(
      RetroGraphicsOptimizer.stepDown({
        RetroGraphicsCatalog.resolution: option(RetroGraphicsCatalog.resolution, scales, '1'),
        RetroGraphicsCatalog.antialiasing: option(RetroGraphicsCatalog.antialiasing, msaa, '2-ssaa'),
      }),
      isNull,
    );
  });
}
