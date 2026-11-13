import 'package:anyps5_desktop/core/retro_host/retro_graphics_catalog.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../ui/retro_host/fake_option_session.dart';

RetroOption _option(String key, List<String> values, {int selected = 0}) => RetroOption(
  key: key,
  title: key,
  values: values,
  labels: values,
  selected: selected,
  activeValue: values[selected],
  restart: false,
);

void main() {
  test('the page lists the settings the recorded host offers, in its own order', () {
    final keys = [for (final (setting, _) in RetroGraphicsCatalog.present(recordedStatus().options)) setting.key];
    expect(keys, [
      RetroGraphicsCatalog.resolution,
      RetroGraphicsCatalog.textureFilter,
      RetroGraphicsCatalog.antialiasing,
      RetroGraphicsCatalog.pgxp,
      RetroGraphicsCatalog.trueColor,
      RetroGraphicsCatalog.scaledDithering,
      RetroGraphicsCatalog.chromaSmoothing,
      RetroGraphicsCatalog.disableInterlacing,
      RetroGraphicsCatalog.downsample,
      RetroGraphicsCatalog.widescreen,
    ]);
    final withPgxp = [
      for (final (setting, _) in RetroGraphicsCatalog.present(recordedStatus(pgxp: true).options)) setting.key,
    ];
    expect(
      withPgxp,
      containsAllInOrder([
        RetroGraphicsCatalog.pgxp,
        RetroGraphicsCatalog.pgxpTextures,
        RetroGraphicsCatalog.pgxpCulling,
        RetroGraphicsCatalog.pgxpColors,
        RetroGraphicsCatalog.pgxpDepth,
      ]),
    );
    expect(
      RetroGraphicsCatalog.covers('swanstation_GPU_PGXPCPU'),
      isFalse,
      reason: 'the PGXP tuning stays in the menu',
    );
    expect(RetroGraphicsCatalog.covers('swanstation_GPU_UseSoftwareRendererForReadbacks'), isFalse);
  });

  test('every value a preset asks for is one SwanStation has', () {
    final options = recordedStatus(pgxp: true).options;
    for (final preset in RetroGraphicsPreset.values) {
      final values = RetroGraphicsCatalog.presetValues(preset, options);
      expect(values.keys, containsAll([RetroGraphicsCatalog.resolution, RetroGraphicsCatalog.textureFilter]));
      for (final MapEntry(:key, :value) in values.entries) {
        expect(options[key]!.values, contains(value), reason: '$preset $key');
      }
    }
    expect(
      RetroGraphicsCatalog.presetValues(RetroGraphicsPreset.maximum, options)[RetroGraphicsCatalog.resolution],
      '8',
    );
    expect(
      RetroGraphicsCatalog.presetValues(RetroGraphicsPreset.enhanced, options),
      isNot(contains(RetroGraphicsCatalog.widescreen)),
    );
  });

  test('the recorded host starts on Original, and a changed setting is the player\'s own look', () {
    final options = recordedStatus().options;
    expect(RetroGraphicsCatalog.matching(options), RetroGraphicsPreset.original);
    final changed = {
      ...options,
      RetroGraphicsCatalog.trueColor: _option(RetroGraphicsCatalog.trueColor, ['true', 'false']),
    };
    expect(RetroGraphicsCatalog.matching(changed), isNull);
  });

  test('a number the host does not offer becomes the largest one below it; any other value is left out', () {
    final scale = _option(RetroGraphicsCatalog.resolution, ['1', '2', '3']);
    expect(RetroGraphicsCatalog.fit(scale, '8'), '3');
    expect(RetroGraphicsCatalog.fit(scale, '2'), '2');
    expect(RetroGraphicsCatalog.fit(_option(RetroGraphicsCatalog.resolution, ['2', '4']), '1'), isNull);
    final msaa = _option(RetroGraphicsCatalog.antialiasing, ['1', '2', '2-ssaa']);
    expect(RetroGraphicsCatalog.fit(msaa, '4'), '2', reason: 'SSAA is not a smaller multisample count');
    expect(RetroGraphicsCatalog.fit(_option(RetroGraphicsCatalog.textureFilter, ['Nearest']), 'xBR'), isNull);

    final limited = {...recordedStatus().options, RetroGraphicsCatalog.resolution: scale};
    expect(
      RetroGraphicsCatalog.presetValues(RetroGraphicsPreset.maximum, limited)[RetroGraphicsCatalog.resolution],
      '3',
    );
  });

  test('a value\'s label is the host\'s', () {
    final options = recordedStatus().options;
    expect(RetroGraphicsCatalog.label(options[RetroGraphicsCatalog.resolution]!, '5'), '5x (for 1080p)');
    expect(RetroGraphicsCatalog.label(options[RetroGraphicsCatalog.antialiasing]!, '4-ssaa'), '4x SSAA');
    expect(RetroGraphicsCatalog.label(options[RetroGraphicsCatalog.antialiasing]!, 'nine'), 'nine');
  });
}
