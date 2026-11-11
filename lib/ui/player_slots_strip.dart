import 'package:flutter/material.dart';

import 'app_model.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// Player 1 to 4 side by side, as a console's co-op lobby shows them: the controller, the
/// player's number, who holds that seat and how they are connected.
class PlayerSlotsStrip extends StatelessWidget {
  const PlayerSlotsStrip({super.key, required this.slots, required this.accent});

  static const controllerAsset = 'assets/retro/coop-controller.png';

  final List<PlayerSlot> slots;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Row(
      children: [
        for (final (index, slot) in slots.indexed) ...[
          if (index > 0) SizedBox(width: 12 * scale),
          Expanded(child: _SlotCard(slot: slot, accent: accent, scale: scale)),
        ],
      ],
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({required this.slot, required this.accent, required this.scale});

  final PlayerSlot slot;
  final Color accent;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final taken = slot.name != null;
    final dim = !slot.available;
    final ink = Colors.white.withValues(alpha: dim ? 0.32 : (taken ? 1 : 0.6));
    return Semantics(
      label: [T.format('coopPlayer', [slot.player]), slot.name ?? '', slot.status].join(', '),
      child: Container(
        height: 176 * scale,
        padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 14 * scale),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16 * scale),
          color: Colors.white.withValues(alpha: taken ? 0.10 : 0.04),
          border: Border.all(
            color: slot.you ? accent : Colors.white.withValues(alpha: taken ? 0.22 : 0.12),
            width: slot.you ? 2 * scale : 1 * scale,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              T.format('coopPlayer', [slot.player]),
              style: AppText.display(13 * scale, weight: FontWeight.w600, color: slot.you ? accent : ink),
            ),
            SizedBox(height: 10 * scale),
            Image.asset(
              PlayerSlotsStrip.controllerAsset,
              height: 40 * scale,
              color: taken ? (slot.you ? accent : Colors.white) : ink,
              colorBlendMode: BlendMode.srcIn,
              filterQuality: FilterQuality.medium,
            ),
            SizedBox(height: 12 * scale),
            Text(
              slot.name ?? T.text('coopOpen'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
            ),
            SizedBox(height: 4 * scale),
            Text(
              slot.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: dim ? 0.32 : 0.62)),
            ),
          ],
        ),
      ),
    );
  }
}
