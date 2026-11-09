import 'package:design_system/src/components/badge.dart';
import 'package:design_system/src/components/instruments.dart';
import 'package:design_system/src/components/surfaces.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/motion.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// How well a speaker is locked to the host: a sentence, what plays, the gauge, the link.
class GPSyncCard extends StatelessWidget {
  const GPSyncCard({
    required this.label,
    required this.tone,
    required this.caption,
    required this.errorMs,
    required this.active,
    super.key,
    this.badges = const [],
  });

  final String label;
  final GPTone tone;
  final String caption;
  final double errorMs;
  final bool active;
  final List<GPBadge> badges;

  @override
  Widget build(BuildContext context) {
    return GPCard(
      padding: const EdgeInsets.fromLTRB(GPSpace.lg, GPSpace.lg, GPSpace.lg, GPSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: GPMotion.of(context, GPMotion.standard),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: GPColors.of(context, tone == GPTone.neutral ? GPColors.tertiaryLabel : tone.color),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: GPSpace.xs),
                Expanded(child: Text(label, style: GPText.title2)),
              ],
            ),
          ),
          const SizedBox(height: GPSpace.xxs),
          Text(
            caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
          ),
          const SizedBox(height: GPSpace.lg),
          GPSyncGauge(errorMs: errorMs, active: active),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: GPSpace.sm),
            Wrap(spacing: GPSpace.xs, runSpacing: GPSpace.xs, children: badges),
          ],
        ],
      ),
    );
  }
}
