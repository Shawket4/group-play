import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A full screen with an iOS large title that collapses on scroll, on the grouped background.
class GPPage extends StatelessWidget {
  const GPPage({
    required this.title,
    required this.slivers,
    super.key,
    this.trailing,
    this.leading,
    this.previousPageTitle,
    this.bottom,
  });

  final String title;
  final List<Widget> slivers;
  final Widget? trailing;
  final Widget? leading;
  final String? previousPageTitle;

  /// Pinned under the scroll view (e.g. a primary action), above the home indicator.
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: GPColors.background,
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                CupertinoSliverNavigationBar(
                  largeTitle: Text(title),
                  trailing: trailing,
                  leading: leading,
                  previousPageTitle: previousPageTitle,
                  border: null,
                  backgroundColor: GPColors.background,
                ),
                ...slivers,
                const SliverToBoxAdapter(child: SizedBox(height: GPSpace.xxl)),
              ],
            ),
          ),
          if (bottom != null)
            Container(
              color: GPColors.of(context, GPColors.background),
              padding: const EdgeInsets.fromLTRB(GPSpace.page, GPSpace.xs, GPSpace.page, GPSpace.xs),
              child: SafeArea(top: false, child: bottom!),
            ),
        ],
      ),
    );
  }
}

/// Plain text block inside a page (intro paragraphs).
class GPParagraph extends StatelessWidget {
  const GPParagraph(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(GPSpace.page, 0, GPSpace.page, GPSpace.xs),
        child: Text(
          text,
          style: (style ?? GPText.subheadline).copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
        ),
      ),
    );
  }
}

/// Centred icon + title + message for empty or waiting states.
class GPEmptyState extends StatelessWidget {
  const GPEmptyState({required this.icon, required this.title, super.key, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: GPSpace.xxl, vertical: GPSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: GPColors.of(context, GPColors.tertiaryLabel)),
          const SizedBox(height: GPSpace.sm),
          Text(title, style: GPText.title3, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: GPSpace.xs),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
            ),
          ],
          if (action != null) ...[const SizedBox(height: GPSpace.lg), action!],
        ],
      ),
    );
  }
}
