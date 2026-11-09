import 'dart:async';

import 'package:design_system/src/components/haptics.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/motion.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A square-ish choice in a grid (what to play). Selected = inverted to ink.
class GPChoiceTile extends StatelessWidget {
  const GPChoiceTile({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
    super.key,
    this.selected = false,
    this.badge,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback? onTap;
  final bool selected;

  /// Small top-right word ("Setup", "Full").
  final String? badge;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ink = GPColors.of(context, GPColors.ink);
    final onInk = GPColors.of(context, GPColors.onInk);
    final fg = selected ? onInk : GPColors.of(context, GPColors.label);
    final sub = selected ? onInk.withValues(alpha: 0.7) : GPColors.of(context, GPColors.secondaryLabel);
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $caption',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                unawaited(GPHaptics.selection());
                onTap!();
              },
        child: AnimatedContainer(
          duration: GPMotion.of(context, GPMotion.standard),
          curve: GPMotion.curve,
          padding: const EdgeInsets.all(GPSpace.md),
          decoration: BoxDecoration(
            color: selected ? ink : GPColors.of(context, GPColors.surface),
            borderRadius: BorderRadius.circular(GPRadius.large),
            border: Border.all(color: selected ? ink : GPColors.of(context, GPColors.separator), width: selected ? 1 : 0.5),
          ),
          child: Opacity(
            opacity: onTap == null && !selected ? 0.45 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 26, color: fg),
                    const Spacer(),
                    if (busy)
                      CupertinoActivityIndicator(color: fg, radius: 9)
                    else if (badge != null)
                      Text(badge!.toUpperCase(), style: GPText.label.copyWith(color: sub, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: GPSpace.lg),
                Text(title, style: GPText.headline.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(caption, style: GPText.footnote.copyWith(color: sub), maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A speaker in the host's row: a ring with initials, a status dot, the name under it.
class GPAvatar extends StatelessWidget {
  const GPAvatar({required this.name, required this.onTap, super.key, this.tone = GPTone.neutral, this.icon, this.dimmed = false, this.caption});

  final String name;
  final VoidCallback? onTap;
  final GPTone tone;

  /// Replaces the initials (e.g. the "+" of the invite tile).
  final IconData? icon;
  final bool dimmed;

  /// Second line under the name (e.g. "In sync").
  final String? caption;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : (parts.first.characters.length > 1 ? parts.first.characters.elementAt(1) : '');
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final ink = GPColors.of(context, GPColors.ink);
    return Semantics(
      button: onTap != null,
      label: caption == null ? name : '$name, $caption',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                unawaited(GPHaptics.selection());
                onTap!();
              },
        child: Opacity(
          opacity: dimmed ? 0.45 : 1,
          child: SizedBox(
            width: 76,
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: GPColors.of(context, icon != null ? GPColors.background : GPColors.surface),
                        shape: BoxShape.circle,
                        border: Border.all(color: icon != null ? GPColors.of(context, GPColors.tertiaryLabel) : ink, width: icon != null ? 1 : 1.5),
                      ),
                      child: icon != null
                          ? Icon(icon, color: ink, size: 24)
                          : Text(initials(name), style: GPText.headline.copyWith(color: ink, letterSpacing: 0.5)),
                    ),
                    if (icon == null)
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: GPColors.of(context, tone == GPTone.neutral ? GPColors.tertiaryLabel : tone.color),
                            shape: BoxShape.circle,
                            border: Border.all(color: GPColors.of(context, GPColors.background), width: 2.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: GPSpace.xs),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: GPText.caption1.copyWith(color: GPColors.of(context, GPColors.label))),
                if (caption != null)
                  Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: GPText.caption1.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel), fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round ink control (play / stop).
class GPRoundButton extends StatelessWidget {
  const GPRoundButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.size = 56,
    this.busy = false,
    this.inverted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final bool busy;

  /// Paper circle, ink glyph (for use on an ink card).
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final bg = GPColors.of(context, inverted ? GPColors.onInk : GPColors.ink);
    final onInk = GPColors.of(context, inverted ? GPColors.ink : GPColors.onInk);
    return Semantics(
      button: true,
      label: label,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size(size, size),
        onPressed: onPressed == null || busy
            ? null
            : () {
                unawaited(GPHaptics.selection());
                onPressed!();
              },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: busy ? CupertinoActivityIndicator(color: onInk) : Icon(icon, color: onInk, size: size * 0.42),
        ),
      ),
    );
  }
}
