import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/motion.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// One message for [GPToastLayer].
class GPToastData {
  const GPToastData({required this.id, required this.message, this.tone = GPTone.neutral});

  final int id;
  final String message;
  final GPTone tone;
}

/// Shows the given toasts at the top of the screen over [child]. Stateless: the list and its
/// lifetime are owned by the caller (app_core's alerts notifier).
class GPToastLayer extends StatelessWidget {
  const GPToastLayer({required this.toasts, required this.onDismiss, required this.child, super.key});

  final List<GPToastData> toasts;
  final ValueChanged<int> onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          left: GPSpace.md,
          right: GPSpace.md,
          top: MediaQuery.paddingOf(context).top + GPSpace.xs,
          child: AnimatedSwitcher(
            duration: GPMotion.of(context, GPMotion.standard),
            switchInCurve: GPMotion.curve,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, -0.3), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            child: toasts.isEmpty
                ? const SizedBox.shrink()
                : _Toast(key: ValueKey(toasts.last.id), data: toasts.last, onDismiss: onDismiss),
          ),
        ),
      ],
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.data, required this.onDismiss, super.key});

  final GPToastData data;
  final ValueChanged<int> onDismiss;

  @override
  Widget build(BuildContext context) {
    final icon = switch (data.tone) {
      GPTone.bad => CupertinoIcons.exclamationmark_circle_fill,
      GPTone.warn => CupertinoIcons.exclamationmark_triangle_fill,
      GPTone.good => CupertinoIcons.checkmark_circle_fill,
      _ => CupertinoIcons.info_circle_fill,
    };
    return Semantics(
      liveRegion: true,
      child: GestureDetector(
        onTap: () => onDismiss(data.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: GPSpace.md, vertical: GPSpace.sm),
          decoration: BoxDecoration(
            color: GPColors.of(context, GPColors.surface),
            borderRadius: BorderRadius.circular(GPRadius.large),
            border: Border.all(color: GPColors.of(context, GPColors.separator)),
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: Row(
            children: [
              Icon(icon, color: GPColors.of(context, data.tone == GPTone.neutral ? GPColors.ink : data.tone.color), size: 22),
              const SizedBox(width: GPSpace.sm),
              Expanded(child: Text(data.message, style: GPText.subheadline)),
            ],
          ),
        ),
      ),
    );
  }
}
