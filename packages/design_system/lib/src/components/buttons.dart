import 'dart:async';

import 'package:design_system/src/components/haptics.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

enum GPButtonStyle {
  /// Ink fill, paper label: the one primary action on a screen.
  filled,

  /// Sunk-grey fill, ink label: secondary actions.
  secondary,

  /// Pale red fill, red label: destructive actions.
  destructive,
}

/// Full-width HIG button with a pressed state and an in-place spinner while [busy].
class GPButton extends StatelessWidget {
  const GPButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.style = GPButtonStyle.filled,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final GPButtonStyle style;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final (bg, fg) = switch (style) {
      GPButtonStyle.filled => (GPColors.of(context, GPColors.ink), GPColors.of(context, GPColors.onInk)),
      GPButtonStyle.secondary => (GPColors.of(context, GPColors.fill), GPColors.of(context, GPColors.ink)),
      GPButtonStyle.destructive => (GPColors.of(context, GPColors.badBg), GPColors.of(context, GPColors.bad)),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(GPSize.minTap, GPSize.button),
        onPressed: enabled
            ? () {
                unawaited(GPHaptics.selection());
                onPressed!();
              }
            : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled || busy ? 1 : 0.4,
          child: Container(
            height: GPSize.button,
            width: double.infinity,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(GPRadius.button)),
            alignment: Alignment.center,
            child: busy
                ? CupertinoActivityIndicator(color: fg)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[Icon(icon, color: fg, size: 20), const SizedBox(width: GPSpace.xs)],
                      Flexible(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: GPText.button.copyWith(color: fg),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Text button for navigation bars ("End", "Done").
class GPBarButton extends StatelessWidget {
  const GPBarButton(this.label, {required this.onPressed, super.key, this.destructive = false, this.bold = false});

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(GPSize.minTap, GPSize.minTap),
      onPressed: onPressed,
      child: Text(
        label,
        style: GPText.body.copyWith(
          color: GPColors.of(context, destructive ? GPColors.bad : GPColors.ink),
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// Icon-only button with an accessible label (nav bar).
class GPIconButton extends StatelessWidget {
  const GPIconButton(this.icon, {required this.label, required this.onPressed, super.key});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(GPSize.minTap, GPSize.minTap),
        onPressed: onPressed,
        child: Icon(icon, size: 24, color: GPColors.of(context, GPColors.ink)),
      ),
    );
  }
}
