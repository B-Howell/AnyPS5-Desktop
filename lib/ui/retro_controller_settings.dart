import '../core/game_library.dart';
import '../core/retro_settings.dart';
import 'app_model.dart';
import 'strings.dart';

abstract final class RetroControllerSettings {
  static const _actions = {
    'Up': 'retroPadUp',
    'Right': 'retroPadRight',
    'Down': 'retroPadDown',
    'Left': 'retroPadLeft',
    'Triangle': 'retroPadTriangle',
    'Circle': 'retroPadCircle',
    'Cross': 'retroPadCross',
    'Square': 'retroPadSquare',
    'Select': 'retroPadSelect',
    'Start': 'retroPadStart',
    'L1': 'L1',
    'R1': 'R1',
    'L2': 'L2',
    'R2': 'R2',
    'L3': 'L3',
    'R3': 'R3',
    'LLeft': 'retroPadLLeft',
    'LRight': 'retroPadLRight',
    'LDown': 'retroPadLDown',
    'LUp': 'retroPadLUp',
    'RLeft': 'retroPadRLeft',
    'RRight': 'retroPadRRight',
    'RDown': 'retroPadRDown',
    'RUp': 'retroPadRUp',
    'LargeMotor': 'retroPadStrongVibration',
    'SmallMotor': 'retroPadLightVibration',
  };

  static const _inputs = {
    'DPadUp': 'retroPadUp',
    'DPadRight': 'retroPadRight',
    'DPadDown': 'retroPadDown',
    'DPadLeft': 'retroPadLeft',
    'Back': 'retroPadSelect',
    'Start': 'retroPadStart',
    'LeftShoulder': 'L1',
    'RightShoulder': 'R1',
    '+LeftTrigger': 'L2',
    '+RightTrigger': 'R2',
    'LeftStick': 'L3',
    'RightStick': 'R3',
    '-LeftX': 'retroPadLLeft',
    '+LeftX': 'retroPadLRight',
    '+LeftY': 'retroPadLDown',
    '-LeftY': 'retroPadLUp',
    '-RightX': 'retroPadRLeft',
    '+RightX': 'retroPadRRight',
    '+RightY': 'retroPadRDown',
    '-RightY': 'retroPadRUp',
  };

  static bool handles(String key) => key == 'Type' || _actions.containsKey(key);

  static List<PanelRow> rows({
    required RetroSettings settings,
    required RetroPlatform platform,
    required String section,
    required void Function(void Function()) save,
  }) {
    final options = settings.options.where((option) => option.section == section).toList();
    final types = {
      'None': 'retroPadDisconnected',
      if (platform == RetroPlatform.ps1) ...{
        'AnalogController': 'DualShock',
        'DigitalController': 'retroPadDigital',
      } else
        'DualShock2': 'DualShock 2',
    };
    final port = section.startsWith('Pad') ? section.substring(3) : section;
    final controllerBindings = _bindingChoices(platform, motor: false);
    final vibrationBindings = _bindingChoices(platform, motor: true);
    final rows = <PanelRow>[];
    for (final key in ['Type', ..._actions.keys]) {
      final matches = options.where((option) => option.key == key).toList();
      final entries = matches.isEmpty ? <RetroOption?>[null] : matches;
      for (final option in entries) {
        final value = option?.value ?? (key == 'Type' ? 'None' : '');
        final choices = key == 'Type'
            ? types.map((value, label) => MapEntry(value, T.text(label)))
            : {...(key.endsWith('Motor') ? vibrationBindings : controllerBindings)};
        choices.putIfAbsent(value, () => T.format('retroCustomValue', [value]));
        final values = choices.keys.toList();
        rows.add(
          PanelRow(
            id: 'retro-${platform.name}-$section-$key-${option?.line ?? 'new'}',
            title: key == 'Type' ? T.format('retroPadPort', [port]) : T.text(_actions[key]!),
            detail: key == 'Type' ? T.format('retroPadPortDetail', [port]) : T.text('retroPadUnbindDetail'),
            kind: ChoiceRow(choices.values.toList(), values.indexOf(value), (index) {
              final next = values[index];
              if (next == value) return;
              save(() {
                if (option == null) {
                  settings.add(section, key, next);
                } else {
                  settings.replace(option, next);
                }
              });
            }),
          ),
        );
      }
    }
    return rows;
  }

  static Map<String, String> _bindingChoices(RetroPlatform platform, {required bool motor}) {
    final inputs = motor
        ? {'LargeMotor': 'retroPadStrongVibration', 'SmallMotor': 'retroPadLightVibration'}
        : {
            ..._inputs,
            if (platform == RetroPlatform.ps1) ...{
              'Y': 'retroPadTriangle',
              'B': 'retroPadCircle',
              'A': 'retroPadCross',
              'X': 'retroPadSquare',
            } else ...{
              'FaceNorth': 'retroPadTriangle',
              'FaceEast': 'retroPadCircle',
              'FaceSouth': 'retroPadCross',
              'FaceWest': 'retroPadSquare',
            },
          };
    final arrowSuffix = platform == RetroPlatform.ps1 ? 'Arrow' : '';
    final enter = platform == RetroPlatform.ps1 ? 'Enter' : 'Return';
    return {
      '': T.text('retroPadUnbound'),
      for (var device = 0; device < 4; device++)
        for (final input in inputs.entries)
          'SDL-$device/${input.key}': T.format('retroPadDeviceInput', [device + 1, T.text(input.value)]),
      if (!motor) ...{
        'Keyboard/Up$arrowSuffix': T.format('retroPadKeyboard', [T.text('retroPadArrowUp')]),
        'Keyboard/Right$arrowSuffix': T.format('retroPadKeyboard', [T.text('retroPadArrowRight')]),
        'Keyboard/Down$arrowSuffix': T.format('retroPadKeyboard', [T.text('retroPadArrowDown')]),
        'Keyboard/Left$arrowSuffix': T.format('retroPadKeyboard', [T.text('retroPadArrowLeft')]),
        'Keyboard/$enter': T.format('retroPadKeyboard', [T.text('keyEnter')]),
        'Keyboard/Space': T.format('retroPadKeyboard', [T.text('retroPadKeySpace')]),
        'Keyboard/Backspace': T.format('retroPadKeyboard', [T.text('retroPadKeyBackspace')]),
        'Keyboard/Escape': T.format('retroPadKeyboard', [T.text('retroPadKeyEscape')]),
        for (var key = 65; key <= 90; key++)
          'Keyboard/${String.fromCharCode(key)}': T.format('retroPadKeyboard', [String.fromCharCode(key)]),
        for (var key = 0; key < 10; key++) 'Keyboard/$key': T.format('retroPadKeyboard', [key]),
        for (var key = 1; key <= 12; key++) 'Keyboard/F$key': T.format('retroPadKeyboard', ['F$key']),
      },
    };
  }
}
