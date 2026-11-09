import 'dart:async';

import 'package:design_system/src/components/haptics.dart';
import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// Label + live value + slider, with −/+ steppers so the value can be set without dragging
/// (and with VoiceOver).
class GPSliderCell extends StatelessWidget {
  const GPSliderCell({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.key,
    this.step,
    this.onChangeEnd,
    this.hint,
    this.minIcon,
    this.maxIcon,
  });

  final String label;
  final double value;
  final double min;
  final double max;

  /// Steppers move by this much; also the slider's division size.
  final double? step;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String? hint;
  final IconData? minIcon;
  final IconData? maxIcon;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max);
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    final divisions = step == null ? null : ((max - min) / step!).round();
    void nudge(double by) {
      final next = (v + by).clamp(min, max);
      unawaited(GPHaptics.selection());
      onChanged(next);
      onChangeEnd?.call(next);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(GPSpace.md, GPSpace.sm, GPSpace.md, GPSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: GPText.body)),
              Text(format(v), style: GPText.numMd.copyWith(color: GPColors.of(context, GPColors.label))),
            ],
          ),
          Row(
            children: [
              if (step != null)
                _Stepper(icon: CupertinoIcons.minus, label: 'Decrease $label', onTap: () => nudge(-step!))
              else if (minIcon != null)
                Icon(minIcon, size: 18, color: secondary),
              Expanded(
                child: Semantics(
                  label: label,
                  value: format(v),
                  child: CupertinoSlider(
                    value: v,
                    min: min,
                    max: max,
                    divisions: divisions,
                    activeColor: GPColors.of(context, GPColors.ink),
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                  ),
                ),
              ),
              if (step != null)
                _Stepper(icon: CupertinoIcons.plus, label: 'Increase $label', onTap: () => nudge(step!))
              else if (maxIcon != null)
                Icon(maxIcon, size: 18, color: secondary),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: GPSpace.xxs),
              child: Text(hint!, style: GPText.footnote.copyWith(color: secondary)),
            ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(GPSize.minTap, GPSize.minTap),
        onPressed: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: GPColors.of(context, GPColors.fill), shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: GPColors.of(context, GPColors.ink)),
        ),
      ),
    );
  }
}
