/// One graphics adapter Windows reports (DXGI), without the software ones.
class RetroAdapter {
  const RetroAdapter({required this.name, required this.dedicatedBytes});

  final String name;

  /// Video memory of its own; 0 for an adapter that shares the system's.
  final int dedicatedBytes;

  @override
  bool operator ==(Object other) =>
      other is RetroAdapter && other.name == name && other.dedicatedBytes == dedicatedBytes;

  @override
  int get hashCode => Object.hash(name, dedicatedBytes);
}

/// What the Auto Optimizer reads of the computer: the height of the display the launcher is on,
/// the graphics adapters and the CPU's threads.
class RetroHardware {
  const RetroHardware({required this.displayHeight, required this.adapters, this.logicalProcessors = 0});

  final int displayHeight;
  final List<RetroAdapter> adapters;
  final int logicalProcessors;
}
