import 'package:flutter/material.dart';

import 'theme.dart';

/// The console a game tile's dump is for (PS4), in its top corner: a game that is not the
/// launcher's own console's says so before it is opened. The name is the console's, the same in
/// every language.
class PlatformChip extends StatelessWidget {
  const PlatformChip({super.key, required this.label, required this.size});

  final String label;

  /// The tile's side; the chip scales with it.
  final double size;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: Container(
      margin: EdgeInsets.all(size * 0.045),
      padding: EdgeInsets.symmetric(horizontal: size * 0.045, vertical: size * 0.02),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size),
        color: Colors.black.withValues(alpha: 0.62),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: AppText.display(size * 0.075, weight: FontWeight.w700).copyWith(height: 1, letterSpacing: 0.6),
      ),
    ),
  );
}
