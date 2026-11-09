import 'dart:async';

import 'package:design_system/src/components/haptics.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A large tappable card for a top-level choice. [primary] = solid tint; otherwise a plain cell.
class GPHeroAction extends StatelessWidget {
  const GPHeroAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ink = GPColors.of(context, GPColors.ink);
    final onInk = GPColors.of(context, GPColors.onInk);
    final bg = primary ? ink : GPColors.of(context, GPColors.surface);
    final fg = primary ? onInk : GPColors.of(context, GPColors.label);
    final sub = primary ? onInk.withValues(alpha: 0.72) : GPColors.of(context, GPColors.secondaryLabel);
    final iconBg = primary ? onInk.withValues(alpha: 0.14) : GPColors.of(context, GPColors.fill);
    final iconFg = primary ? onInk : ink;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap == null || busy
            ? null
            : () {
                unawaited(GPHaptics.selection());
                onTap!();
              },
        child: Container(
          padding: const EdgeInsets.all(GPSpace.md),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(GPRadius.large),
            border: primary ? null : Border.all(color: GPColors.of(context, GPColors.separator)),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(GPRadius.button)),
                child: busy ? CupertinoActivityIndicator(color: iconFg) : Icon(icon, size: 28, color: iconFg),
              ),
              const SizedBox(width: GPSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: GPText.headline.copyWith(color: fg)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: GPText.subheadline.copyWith(color: sub, fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_forward, size: 18, color: sub),
            ],
          ),
        ),
      ),
    );
  }
}
