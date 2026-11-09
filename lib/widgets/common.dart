import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/theme.dart';

/// Rounded card with an optional title row.
class Section extends StatelessWidget {
  const Section({super.key, this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(18)});
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(title!.toUpperCase(),
                        style: const TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: TuttiColors.muted)),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 14),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => TuttiColors.accent.createShader(r),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}

/// Small rounded label, e.g. "direct · 3 ms".
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = TuttiColors.muted, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 5)],
        Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// How well this device is locked to the shared timeline.
({String label, Color color}) syncQuality({required bool synced, required bool playing, required double errMs}) {
  if (!synced) return (label: 'Syncing clock…', color: TuttiColors.warn);
  if (!playing) return (label: 'Clock synced', color: TuttiColors.good);
  final e = errMs.abs();
  if (e < 1.5) return (label: 'In sync', color: TuttiColors.good);
  if (e < 8) return (label: 'Settling ${e.toStringAsFixed(1)} ms', color: TuttiColors.warn);
  return (label: 'Off by ${e.toStringAsFixed(0)} ms', color: TuttiColors.bad);
}

/// Calibration: −200…+200 ms with fine ±1 ms steps.
class DelayControl extends StatelessWidget {
  const DelayControl({super.key, required this.value, required this.onChanged, this.label = 'Timing'});
  final double value;
  final ValueChanged<double> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(-200.0, 200.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(color: TuttiColors.muted)),
        const Spacer(),
        Text('${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)} ms', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600)),
      ]),
      Row(children: [
        _Step(icon: Icons.remove, onTap: () => onChanged((v - 1).clamp(-200, 200))),
        Expanded(
          child: Slider(value: v, min: -200, max: 200, divisions: 400, onChanged: onChanged),
        ),
        _Step(icon: Icons.add, onTap: () => onChanged((v + 1).clamp(-200, 200))),
      ]),
      const Text('Sounds early? Move right. Late? Move left.', style: TextStyle(fontSize: 12, color: TuttiColors.muted)),
    ]);
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: TuttiColors.outline)),
        child: Icon(icon, size: 18),
      ),
    );
  }
}

class VolumeControl extends StatelessWidget {
  const VolumeControl({super.key, required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Icon(Icons.volume_down_rounded, color: TuttiColors.muted),
      Expanded(child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged)),
      const Icon(Icons.volume_up_rounded, color: TuttiColors.muted),
    ]);
  }
}

/// Key/value grid for diagnostics.
class StatGrid extends StatelessWidget {
  const StatGrid(this.items, {super.key});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 18,
      runSpacing: 10,
      children: [
        for (final (k, v) in items)
          SizedBox(
            width: 132,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k, style: const TextStyle(fontSize: 11, color: TuttiColors.muted)),
              const SizedBox(height: 2),
              Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
      ],
    );
  }
}

/// Shows the controller's one-shot messages as snackbars.
class MessageListener extends StatefulWidget {
  const MessageListener({super.key, required this.controller, required this.child});
  final TuttiController controller;
  final Widget child;

  @override
  State<MessageListener> createState() => _MessageListenerState();
}

class _MessageListenerState extends State<MessageListener> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final m = widget.controller.takeMessage();
    if (m != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String fmtMs(double v, {int digits = 1}) => '${v.toStringAsFixed(digits)} ms';

IconData platformIcon(String p) => switch (p) {
      'ios' => Icons.phone_iphone_rounded,
      'android' => Icons.phone_android_rounded,
      _ => Icons.devices_other_rounded,
    };
