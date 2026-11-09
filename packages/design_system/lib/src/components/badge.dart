import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A small capsule: a status dot (or glyph) and ink text on the sunk grey. The words carry the
/// meaning; the dot's colour only supports them.
class GPBadge extends StatelessWidget {
  const GPBadge(this.text, {super.key, this.tone = GPTone.neutral, this.icon});

  final String text;
  final GPTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final mark = GPColors.of(context, tone == GPTone.neutral ? GPColors.tertiaryLabel : tone.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: GPSpace.xs, vertical: 3),
      decoration: BoxDecoration(color: GPColors.of(context, GPColors.fill), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 12, color: GPColors.of(context, GPColors.ink))
          else
            Container(width: 7, height: 7, decoration: BoxDecoration(color: mark, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text, style: GPText.caption1.copyWith(color: GPColors.of(context, GPColors.label))),
        ],
      ),
    );
  }
}
