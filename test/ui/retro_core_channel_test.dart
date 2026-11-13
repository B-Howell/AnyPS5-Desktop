import 'package:anyps5_desktop/ui/retro_core_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('anyps5/retro_core');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('legacy Windows handle preserves native arguments', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    final native = RetroCoreChannel.fromStart(123);
    expect(native.texture, 123);
    expect(await native.invokeMethod<bool>('pause', false), isTrue);
    expect(received!.arguments, false);
  });

  test('reused Linux texture binds calls to the owning session', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final first = RetroCoreChannel.fromStart({'texture': 123, 'session': 1});
    final second = RetroCoreChannel.fromStart({'texture': 123, 'session': 2});
    await first.invokeMethod<bool>('ps2LanReset', 123);
    await second.invokeMethod<bool>('ps2LanReset', 123);
    expect(calls.map((call) => call.arguments), [
      {'owner': 1, 'value': 123},
      {'owner': 2, 'value': 123},
    ]);
  });

  test('invalid native handles cannot become sessions', () {
    for (final value in [
      null,
      -1,
      {'texture': 1},
      {'texture': 1, 'session': 0},
      {'texture': '1', 'session': 1},
    ]) {
      expect(() => RetroCoreChannel.fromStart(value), throwsFormatException);
    }
  });

  test('owned list and map replies preserve typed channel decoding', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'status' ? {'ready': true} : [1, 2]);
    final native = RetroCoreChannel.fromStart({'texture': 123, 'session': 9});
    expect(await native.invokeListMethod<int>('frames'), [1, 2]);
    expect(await native.invokeMapMethod<String, Object?>('status'), {'ready': true});
  });
}
