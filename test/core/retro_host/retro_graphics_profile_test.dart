import 'dart:convert';

import 'package:anyps5_desktop/core/retro_host/retro_frame_rate.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_profile.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a game\'s graphics are kept as JSON and read back', () {
    final profile = RetroGraphicsProfile(
      options: {'swanstation_GPU_ResolutionScale': '4'},
      optimized: {
        'swanstation_GPU_ResolutionScale': (before: '1', saved: null, applied: '4'),
        'swanstation_GPU_MSAA': (before: '1', saved: '1', applied: '2'),
      },
    );
    final read = RetroGraphicsProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())));
    expect(read.options, profile.options);
    expect(read.optimized, profile.optimized);
    expect(RetroGraphicsProfile().isEmpty, isTrue);
    expect(RetroGraphicsProfile().toJson(), isEmpty);
  });

  test('whatever is not as it is written is left out', () {
    expect(RetroGraphicsProfile.fromJson('nonsense').isEmpty, isTrue);
    final read = RetroGraphicsProfile.fromJson({
      'options': {'a': '1', 'b': 2},
      'optimized': {
        'a': {'before': '1'},
        'c': {'before': '1', 'saved': 3, 'applied': '2'},
      },
    });
    expect(read.options, {'a': '1'});
    expect(read.optimized, {'c': (before: '1', saved: null, applied: '2')});
    expect(
      RetroGraphicsProfile.fromJson({
        'optimized': {'a': 1},
      }).optimized,
      isNull,
    );
  });

  test('the frame rate counts the frames in its window', () {
    final rate = RetroFrameRate(window: const Duration(seconds: 1));
    expect(rate.rate, isNull);
    for (var frame = 0; frame <= 120; frame++) {
      rate.add(Duration(microseconds: frame * 16667));
    }
    expect(rate.span, lessThanOrEqualTo(const Duration(seconds: 1)));
    expect(rate.rate, closeTo(60, 0.1));
    rate.reset();
    expect((rate.count, rate.rate), (0, null));
    rate
      ..add(Duration.zero)
      ..add(Duration.zero);
    expect(rate.rate, isNull, reason: 'no time between them');
  });

  test('each game\'s graphics are kept in the preferences file, without games that have none', () {
    final preferences = Preferences()
      ..retroHostGraphics['retro:ps1:a'] = RetroGraphicsProfile(
        options: {'swanstation_GPU_ResolutionScale': '4'},
        optimized: {'swanstation_GPU_ResolutionScale': (before: '1', saved: null, applied: '4')},
      )
      ..retroHostGraphics['retro:ps1:b'] = RetroGraphicsProfile();
    final json = jsonDecode(jsonEncode(preferences.toJson())) as Map<String, dynamic>;
    expect((json['retroHostGraphics'] as Map).keys, ['retro:ps1:a']);
    final read = Preferences.fromJson(json).retroHostGraphics;
    expect(read.keys, ['retro:ps1:a']);
    expect(read['retro:ps1:a']!.options, {'swanstation_GPU_ResolutionScale': '4'});
    expect(read['retro:ps1:a']!.optimized, {
      'swanstation_GPU_ResolutionScale': (before: '1', saved: null, applied: '4'),
    });
    expect(Preferences().toJson(), isNot(contains('retroHostGraphics')));
  });
}
