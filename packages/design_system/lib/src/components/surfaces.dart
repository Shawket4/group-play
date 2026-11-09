import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A white (dark: slate) card with a hairline edge. The basic unit of every screen.
class GPCard extends StatelessWidget {
  const GPCard({required this.child, super.key, this.padding = const EdgeInsets.all(GPSpace.md), this.inverted = false});

  final Widget child;
  final EdgeInsets padding;

  /// Ink card with paper content: the one thing on a screen that matters most.
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: GPColors.of(context, inverted ? GPColors.ink : GPColors.surface),
        borderRadius: BorderRadius.circular(GPRadius.large),
        border: inverted ? null : Border.all(color: GPColors.of(context, GPColors.separator), width: 0.5),
      ),
      child: child,
    );
  }
}

/// Uppercase tracked label above a block (Madar's section label).
class GPSectionLabel extends StatelessWidget {
  const GPSectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: GPSpace.xxs, bottom: GPSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(text.toUpperCase(), style: GPText.label.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel))),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A sliver of free content with the page's side margins.
class GPBlock extends StatelessWidget {
  const GPBlock({required this.child, super.key, this.bottom = GPSpace.xl});

  final Widget child;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(GPSpace.page, 0, GPSpace.page, bottom),
        child: child,
      ),
    );
  }
}

/// A hairline rule.
class GPRule extends StatelessWidget {
  const GPRule({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(left: indent),
      height: 0.5,
      color: GPColors.of(context, GPColors.separator),
    );
  }
}
