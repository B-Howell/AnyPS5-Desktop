import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'retro_hardware.dart';

/// One memory heap of a Vulkan device (`VkMemoryHeap`): its size and its flags.
class VulkanHeap {
  const VulkanHeap({required this.size, required this.flags});

  final int size;
  final int flags;

  /// `VK_MEMORY_HEAP_DEVICE_LOCAL_BIT`: memory on the device itself.
  bool get deviceLocal => flags & 1 != 0;
}

/// One physical device as the Vulkan driver describes it (`VkPhysicalDeviceProperties` and
/// `VkPhysicalDeviceMemoryProperties`), before the Auto Optimizer's rules.
class VulkanDevice {
  const VulkanDevice({
    required this.name,
    required this.type,
    required this.vendorId,
    required this.deviceId,
    required this.heaps,
  });

  /// A device as [toJson] writes it; null when anything in it is not as it should be.
  static VulkanDevice? fromJson(Object? json) {
    if (json case {
      'name': final String name,
      'type': final int type,
      'vendorId': final int vendorId,
      'deviceId': final int deviceId,
      'heaps': final List<Object?> entries,
    }) {
      final heaps = <VulkanHeap>[];
      for (final entry in entries) {
        if (entry case {'size': final int size, 'flags': final int flags}) {
          heaps.add(VulkanHeap(size: size, flags: flags));
        } else {
          return null;
        }
      }
      return VulkanDevice(name: name, type: type, vendorId: vendorId, deviceId: deviceId, heaps: heaps);
    }
    return null;
  }

  final String name;

  /// `VkPhysicalDeviceType`: 1 integrated, 2 discrete, 3 virtual, 4 the CPU.
  final int type;
  final int vendorId;
  final int deviceId;
  final List<VulkanHeap> heaps;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'vendorId': vendorId,
    'deviceId': deviceId,
    'heaps': [
      for (final heap in heaps) {'size': heap.size, 'flags': heap.flags},
    ],
  };
}

/// The graphics adapters of a computer without DXGI (Linux, and a Mac with a Vulkan loader or
/// MoltenVK), read as games and emulators read them: the devices the Vulkan driver lists, each
/// one's name and type, and the memory heaps on the device. The kernel has no one place for this:
/// /sys/class/drm gives AMD's video memory (`mem_info_vram_total`) but not NVIDIA's own driver's,
/// and no names.
abstract final class RetroVulkanAdapters {
  static const _discrete = 2;
  static const _cpu = 4;

  /// The adapters as the Auto Optimizer reads them, as Windows' DXGI list has them: without the
  /// CPU's (software) devices, each with its video memory of its own (a discrete device's largest
  /// heap on the device, 0 for any other, which shares the system's memory), and a device two
  /// drivers both list (RADV and AMDVLK) once.
  static List<RetroAdapter> adapters(List<VulkanDevice> devices) {
    final seen = <(int, int, int)>{};
    return [
      for (final device in devices)
        if (device.type != _cpu && device.name.trim().isNotEmpty)
          if (RetroAdapter(name: device.name.trim(), dedicatedBytes: dedicatedBytes(device)) case final adapter
              when seen.add((device.vendorId, device.deviceId, adapter.dedicatedBytes)))
            adapter,
    ];
  }

  /// A discrete device's largest heap on the device; 0 for an integrated, virtual or other one.
  static int dedicatedBytes(VulkanDevice device) {
    if (device.type != _discrete) return 0;
    return device.heaps.where((heap) => heap.deviceLocal).fold(0, (largest, heap) => math.max(largest, heap.size));
  }

  /// The adapters this computer's Vulkan driver lists, read on an isolate of their own (loading
  /// the drivers takes a moment); none when it cannot be read whole.
  static Future<List<RetroAdapter>> read() async => adapters(await Isolate.run(readDevices) ?? const []);

  /// The devices the Vulkan driver lists; null when there is no Vulkan loader here or the list
  /// cannot be read whole. No device is opened.
  static List<VulkanDevice>? readDevices() {
    final library = _open();
    return library == null ? null : _VulkanList(library).devices();
  }

  static List<String> get _libraries {
    if (Platform.isWindows) return const ['vulkan-1.dll'];
    if (Platform.isMacOS) return const ['libvulkan.1.dylib', 'libMoltenVK.dylib'];
    return const ['libvulkan.so.1', 'libvulkan.so'];
  }

  static DynamicLibrary? _open() {
    for (final name in _libraries) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }
}

final class _InstanceCreateInfo extends Struct {
  @Int32()
  external int sType;
  external Pointer<Void> next;
  @Uint32()
  external int flags;
  external Pointer<Void> applicationInfo;
  @Uint32()
  external int layerCount;
  external Pointer<Pointer<Utf8>> layers;
  @Uint32()
  external int extensionCount;
  external Pointer<Pointer<Utf8>> extensions;
}

final class _ExtensionProperties extends Struct {
  @Array(256)
  external Array<Uint8> name;
  @Uint32()
  external int specVersion;
}

/// The start of `VkPhysicalDeviceProperties`, up to its name. The whole struct (824 bytes, its
/// limits after the name) is written by the driver into [_VulkanList._propertiesBytes].
final class _DeviceProperties extends Struct {
  @Uint32()
  external int apiVersion;
  @Uint32()
  external int driverVersion;
  @Uint32()
  external int vendorId;
  @Uint32()
  external int deviceId;
  @Int32()
  external int deviceType;
  @Array(256)
  external Array<Uint8> deviceName;
}

final class _MemoryType extends Struct {
  @Uint32()
  external int propertyFlags;
  @Uint32()
  external int heapIndex;
}

final class _MemoryHeap extends Struct {
  @Uint64()
  external int size;
  @Uint32()
  external int flags;
}

final class _MemoryProperties extends Struct {
  @Uint32()
  external int typeCount;
  @Array(32)
  external Array<_MemoryType> types;
  @Uint32()
  external int heapCount;
  @Array(16)
  external Array<_MemoryHeap> heaps;
}

typedef _EnumerateExtensionsC = Int32 Function(Pointer<Utf8>, Pointer<Uint32>, Pointer<_ExtensionProperties>);
typedef _EnumerateExtensions = int Function(Pointer<Utf8>, Pointer<Uint32>, Pointer<_ExtensionProperties>);
typedef _CreateInstanceC = Int32 Function(Pointer<_InstanceCreateInfo>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CreateInstance = int Function(Pointer<_InstanceCreateInfo>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DestroyInstanceC = Void Function(Pointer<Void>, Pointer<Void>);
typedef _DestroyInstance = void Function(Pointer<Void>, Pointer<Void>);
typedef _EnumerateDevicesC = Int32 Function(Pointer<Void>, Pointer<Uint32>, Pointer<Pointer<Void>>);
typedef _EnumerateDevices = int Function(Pointer<Void>, Pointer<Uint32>, Pointer<Pointer<Void>>);
typedef _DevicePropertiesC = Void Function(Pointer<Void>, Pointer<Uint8>);
typedef _DeviceQuery = void Function(Pointer<Void>, Pointer<Uint8>);

/// Vulkan 1.0's own calls, which every loader (and MoltenVK) exports by name.
class _VulkanList {
  _VulkanList(DynamicLibrary library)
    : _enumerateExtensions = library.lookupFunction<_EnumerateExtensionsC, _EnumerateExtensions>(
        'vkEnumerateInstanceExtensionProperties',
      ),
      _createInstance = library.lookupFunction<_CreateInstanceC, _CreateInstance>('vkCreateInstance'),
      _destroyInstance = library.lookupFunction<_DestroyInstanceC, _DestroyInstance>('vkDestroyInstance'),
      _enumerateDevices = library.lookupFunction<_EnumerateDevicesC, _EnumerateDevices>('vkEnumeratePhysicalDevices'),
      _properties = library.lookupFunction<_DevicePropertiesC, _DeviceQuery>('vkGetPhysicalDeviceProperties'),
      _memory = library.lookupFunction<_DevicePropertiesC, _DeviceQuery>('vkGetPhysicalDeviceMemoryProperties');

  static const _success = 0;
  static const _incompatibleDriver = -9;
  static const _instanceCreateInfo = 1;
  static const _portabilityEnumeration = 'VK_KHR_portability_enumeration';
  static const _enumeratePortability = 1;
  static const _propertiesBytes = 1024;

  final _EnumerateExtensions _enumerateExtensions;
  final _CreateInstance _createInstance;
  final _DestroyInstance _destroyInstance;
  final _EnumerateDevices _enumerateDevices;
  final _DeviceQuery _properties;
  final _DeviceQuery _memory;

  List<VulkanDevice>? devices() => using((arena) {
    final portability = _hasExtension(arena, _portabilityEnumeration);
    if (portability == null) return null;
    final info = arena<_InstanceCreateInfo>()
      ..ref.sType = _instanceCreateInfo
      ..ref.next = nullptr
      ..ref.flags = portability ? _enumeratePortability : 0
      ..ref.applicationInfo = nullptr
      ..ref.layerCount = 0
      ..ref.layers = nullptr
      ..ref.extensionCount = portability ? 1 : 0
      ..ref.extensions = portability
          ? (arena<Pointer<Utf8>>()..value = _portabilityEnumeration.toNativeUtf8(allocator: arena))
          : nullptr;
    final instance = arena<Pointer<Void>>();
    final created = _createInstance(info, nullptr, instance);
    if (created == _incompatibleDriver) return const <VulkanDevice>[];
    if (created != _success) return null;
    try {
      return _list(arena, instance.value);
    } finally {
      _destroyInstance(instance.value, nullptr);
    }
  });

  bool? _hasExtension(Arena arena, String wanted) {
    final count = arena<Uint32>();
    if (_enumerateExtensions(nullptr, count, nullptr) != _success) return null;
    if (count.value == 0) return false;
    final properties = arena<_ExtensionProperties>(count.value);
    if (_enumerateExtensions(nullptr, count, properties) != _success) return null;
    for (var index = 0; index < count.value; index++) {
      if (_text(properties[index].name, 256) == wanted) return true;
    }
    return false;
  }

  List<VulkanDevice>? _list(Arena arena, Pointer<Void> instance) {
    final count = arena<Uint32>();
    if (_enumerateDevices(instance, count, nullptr) != _success) return null;
    if (count.value == 0) return const [];
    final handles = arena<Pointer<Void>>(count.value);
    if (_enumerateDevices(instance, count, handles) != _success) return null;
    final bytes = arena<Uint8>(_propertiesBytes);
    final memory = arena<_MemoryProperties>();
    return [for (var index = 0; index < count.value; index++) _device(handles[index], bytes, memory)];
  }

  VulkanDevice _device(Pointer<Void> handle, Pointer<Uint8> bytes, Pointer<_MemoryProperties> memory) {
    _properties(handle, bytes);
    _memory(handle, memory.cast());
    final properties = bytes.cast<_DeviceProperties>().ref;
    final heaps = memory.ref.heaps;
    return VulkanDevice(
      name: _text(properties.deviceName, 256),
      type: properties.deviceType,
      vendorId: properties.vendorId,
      deviceId: properties.deviceId,
      heaps: [
        for (var index = 0; index < math.min(memory.ref.heapCount, 16); index++)
          VulkanHeap(size: heaps[index].size, flags: heaps[index].flags),
      ],
    );
  }

  static String _text(Array<Uint8> characters, int length) {
    final bytes = <int>[];
    for (var index = 0; index < length && characters[index] != 0; index++) {
      bytes.add(characters[index]);
    }
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }
}
