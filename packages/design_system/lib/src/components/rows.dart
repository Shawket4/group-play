import 'dart:async';

import 'package:design_system/src/components/haptics.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// An inset-grouped section (iOS Settings style) as a sliver.
class GPSection extends StatelessWidget {
  const GPSection({required this.children, super.key, this.header, this.footer});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return SliverToBoxAdapter(
      child: CupertinoListSection.insetGrouped(
        backgroundColor: GPColors.of(context, GPColors.background),
        decoration: BoxDecoration(
          color: GPColors.of(context, GPColors.surface),
          borderRadius: BorderRadius.circular(GPRadius.card),
        ),
        margin: const EdgeInsets.fromLTRB(GPSpace.page, 0, GPSpace.page, GPSpace.md),
        header: header == null ? null : Text(header!.toUpperCase(), style: GPText.label.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel))),
        footer: footer == null ? null : Text(footer!, style: GPText.footnote.copyWith(color: secondary)),
        children: children,
      ),
    );
  }
}

/// A list row: optional icon tile, title, subtitle, trailing value/accessory.
/// With [onTap] it shows the pressed state and (unless [chevron] is false) a chevron.
class GPRow extends StatelessWidget {
  const GPRow({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.value,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.titleColor,
    this.semanticsLabel,
    this.figure = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Grey value text on the right (e.g. "4 ms").
  final String? value;

  /// Custom accessory (switch, badge, spinner, checkmark). Replaces the chevron.
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final CupertinoDynamicColor? titleColor;
  final String? semanticsLabel;

  /// [value] is a figure (ms, ppm, count): set in Plex Mono.
  final bool figure;

  @override
  Widget build(BuildContext context) {
    final tile = CupertinoListTile(
      leading: leading,
      leadingSize: GPSize.tile,
      title: Text(
        title,
        style: GPText.body.copyWith(color: titleColor == null ? null : GPColors.of(context, titleColor!)),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 3,
              style: GPText.footnote.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
            ),
      additionalInfo: value == null
          ? null
          : Text(
              value!,
              style: (figure ? GPText.numMd : GPText.body).copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
            ),
      trailing: trailing ?? (onTap != null && chevron ? Icon(CupertinoIcons.chevron_forward, size: 16, color: GPColors.of(context, GPColors.tertiaryLabel)) : null),
      onTap: onTap == null
          ? null
          : () {
              unawaited(GPHaptics.selection());
              onTap!();
            },
    );
    return semanticsLabel == null ? tile : Semantics(label: semanticsLabel, child: tile);
  }
}

/// A row with a switch.
class GPSwitchRow extends StatelessWidget {
  const GPSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return GPRow(
      title: title,
      subtitle: subtitle,
      leading: leading,
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: GPColors.of(context, GPColors.ink),
        onChanged: onChanged == null
            ? null
            : (v) {
                unawaited(GPHaptics.selection());
                onChanged!(v);
              },
      ),
    );
  }
}

/// Free content inside a section, padded like a row.
class GPCellContent extends StatelessWidget {
  const GPCellContent({required this.child, super.key, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: GPSpace.md, vertical: GPSpace.sm),
      child: child,
    );
  }
}
