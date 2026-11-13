import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_graphics_catalog.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics_optimizer.dart';
import 'package:anyps5_desktop/core/retro_host/retro_hardware.dart';
import 'package:anyps5_desktop/core/retro_host/retro_vulkan_adapters.dart';
import 'package:anyps5_desktop/ui/launcher_window_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../ui/retro_host/fake_option_session.dart';

Object? _fixture(String name) => jsonDecode(File('test/fixtures/retro_host/$name').readAsStringSync());

/// Devices as the Vulkan reader wrote them on a real computer.
List<VulkanDevice> _devices(String name) => [
  for (final device in _fixture(name)! as List<Object?>) VulkanDevice.fromJson(device)!,
];

const _rtx = RetroAdapter(name: 'NVIDIA GeForce RTX 4080 SUPER', dedicatedBytes: 16824401920);

/// What the Auto Optimizer suggests with these adapters on the PC they were read on: a
/// 5120x1440 display and 16 threads.
RetroOptimizeResult _advise(List<RetroAdapter> adapters) => RetroGraphicsOptimizer.recommend(
  hardware: RetroHardware(displayHeight: 1440, adapters: adapters, logicalProcessors: 16),
  status: swanstationStatus(),
);

void _expectFullTier(RetroOptimizeResult result) {
  expect(result.blocked, isNull);
  expect(result.advice!.adapter, _rtx);
  expect(result.advice!.values, {
    RetroGraphicsCatalog.resolution: '4',
    RetroGraphicsCatalog.textureFilter: 'BilinearBinAlpha',
    RetroGraphicsCatalog.antialiasing: '2',
    RetroGraphicsCatalog.pgxp: 'true',
    RetroGraphicsCatalog.scaledDithering: 'true',
    RetroGraphicsCatalog.chromaSmoothing: 'true',
  });
}

void main() {
  test('the runner\'s DXGI list on a PC with an RTX 4080 SUPER and a Radeon iGPU picks the RTX', () {
    final codec = const StandardMethodCodec();
    final answer = codec.decodeEnvelope(
      codec.encodeSuccessEnvelope(_fixture('dxgi_adapters_rtx4080super_radeon.json')),
    );
    final adapters = parseRetroAdapters(answer);
    expect(adapters, [_rtx, const RetroAdapter(name: 'AMD Radeon(TM) Graphics', dedicatedBytes: 509378560)]);
    _expectFullTier(_advise(adapters));
  });

  test('Vulkan on the same PC gives the RTX the same memory and the iGPU none of its own', () {
    final adapters = RetroVulkanAdapters.adapters(_devices('vulkan_devices_windows_rtx4080super_radeon.json'));
    expect(adapters, [_rtx, const RetroAdapter(name: 'AMD Radeon(TM) Graphics', dedicatedBytes: 0)]);
    _expectFullTier(_advise(adapters));
  });

  test('Linux with only Mesa\'s software device (lavapipe) has no adapter', () {
    final devices = _devices('vulkan_devices_linux_lavapipe.json');
    expect(devices.single.type, 4);
    expect(RetroVulkanAdapters.adapters(devices), isEmpty);
    expect(_advise(const []).blocked, RetroOptimizeBlock.noAdapter);
  });

  test('a device two drivers both list counts once, by its device UUID', () {
    final rtx = _devices('vulkan_devices_windows_rtx4080super_radeon.json').first;
    VulkanDevice twin({String? uuid}) => VulkanDevice(
      name: '${rtx.name} (second driver)',
      type: rtx.type,
      vendorId: rtx.vendorId,
      deviceId: rtx.deviceId,
      heaps: rtx.heaps,
      uuid: uuid,
    );
    expect(RetroVulkanAdapters.adapters([rtx, twin(uuid: rtx.uuid)]), [_rtx]);
    final alike = RetroVulkanAdapters.adapters([rtx, twin(uuid: '${rtx.uuid!.substring(0, 31)}f')]);
    expect(alike, hasLength(2), reason: 'two cards alike stay two');
    expect(_advise(alike).blocked, RetroOptimizeBlock.noAdapter);
    final noUuid = VulkanDevice(
      name: rtx.name,
      type: rtx.type,
      vendorId: rtx.vendorId,
      deviceId: rtx.deviceId,
      heaps: rtx.heaps,
    );
    expect(RetroVulkanAdapters.adapters([noUuid, noUuid]), hasLength(2), reason: 'without a UUID nothing is merged');
  });

  test('a discrete device\'s memory is its largest heap on the device, not their sum', () {
    const device = VulkanDevice(
      name: 'Card',
      type: 2,
      vendorId: 1,
      deviceId: 2,
      heaps: [
        VulkanHeap(size: 8 << 30, flags: 1),
        VulkanHeap(size: 32 << 30, flags: 0),
        VulkanHeap(size: 256 << 20, flags: 1),
      ],
    );
    expect(RetroVulkanAdapters.dedicatedBytes(device), 8 << 30);
  });

  test('a recorded device that is not whole is refused', () {
    expect(VulkanDevice.fromJson({'name': 'Card', 'type': 2, 'vendorId': 1, 'deviceId': 2}), isNull);
    expect(
      VulkanDevice.fromJson({
        'name': 'Card',
        'type': 2,
        'vendorId': 1,
        'deviceId': 2,
        'heaps': [
          {'size': 1},
        ],
      }),
      isNull,
    );
    expect(
      VulkanDevice.fromJson({'name': 'Card', 'type': 2, 'vendorId': 1, 'deviceId': 2, 'heaps': [], 'uuid': 'not hex'}),
      isNull,
    );
  });

  test('this computer\'s Vulkan driver is read without failing, or says it cannot be', () {
    final devices = RetroVulkanAdapters.readDevices();
    if (devices == null) return;
    for (final device in devices) {
      expect(VulkanDevice.fromJson(jsonDecode(jsonEncode(device.toJson()))), isNotNull);
    }
  });
}
