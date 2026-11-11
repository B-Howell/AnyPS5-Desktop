import 'dart:ffi';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

void main() {
  for (final platform in RetroPlatform.values) {
    test('Linux Settings exposes real ${platform.name} installation without enabling online workers', () {
      final fixture = makeFixture(
        system: HostSystem.linux,
        environment: {'ANYPS5_PS1_NETPLAY': '1', 'ANYPS5_PS2_LAN': '1'},
      );
      final model = fixture.model;
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      model.open(Layer.settings);
      expect(model.panelCategories().map((category) => category.id), contains('emulators'));
      expect(model.managedRetroAvailable, isTrue);
      expect(model.together.ps2LanSetupEnabled, isFalse);
      model.openSettingsCategory('emulators');
      final console = model
          .panelCategories()
          .expand((category) => category.rows)
          .singleWhere((row) => row.id == 'emulators-${platform.name}');
      (console.kind as ActionRow).run();
      final setup = model.panelCategories().single.rows.singleWhere((row) => row.id == 'emulator-group-setup');
      (setup.kind as ActionRow).run();
      final install = model.panelCategories().single.rows.singleWhere(
        (row) => row.id == 'retro-${platform.name}-setup',
      );
      expect(install.title, startsWith('Install '));
      expect(install.kind, isA<ActionRow>());
    }, skip: Abi.current() != Abi.linuxX64);
  }
}
