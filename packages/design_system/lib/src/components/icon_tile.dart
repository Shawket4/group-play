import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:flutter/cupertino.dart';

/// A row's icon: an ink glyph in a sunk-grey well. [inverted] = paper glyph on ink, for the
/// one thing on a screen that should stand out.
class GPIconTile extends StatelessWidget {
  const GPIconTile(this.icon, {super.key, this.size = GPSize.tile, this.inverted = false});

  final IconData icon;
  final double size;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: GPColors.of(context, inverted ? GPColors.ink : GPColors.fill),
          borderRadius: BorderRadius.circular(GPRadius.tile * size / GPSize.tile),
        ),
        child: Icon(icon, color: GPColors.of(context, inverted ? GPColors.onInk : GPColors.ink), size: size * 0.6),
      ),
    );
  }
}
