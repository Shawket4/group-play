import 'dart:math' as math;

import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/motion.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// A ruler from −[range] to +[range] ms with a needle at [errorMs]: how far this phone is from
/// the shared timeline. Ink on paper, like a measuring instrument. The needle glides.
class GPSyncGauge extends StatelessWidget {
  const GPSyncGauge({required this.errorMs, required this.active, super.key, this.range = 20});

  final double errorMs;

  /// False while syncing / idle: the needle rests in the middle, faded.
  final bool active;
  final double range;

  @override
  Widget build(BuildContext context) {
    final ink = GPColors.of(context, GPColors.ink);
    final muted = GPColors.of(context, GPColors.tertiaryLabel);
    final target = active ? errorMs.clamp(-range, range) / range : 0.0;
    return Semantics(
      label: active ? 'Timing error ${errorMs.toStringAsFixed(1)} milliseconds' : 'Not playing',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: target),
        duration: GPMotion.of(context, GPMotion.slow),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          size: const Size(double.infinity, 64),
          painter: _GaugePainter(position: v, ink: ink, muted: muted, active: active, label: GPText.num.copyWith(color: muted, fontSize: 10)),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.position, required this.ink, required this.muted, required this.active, required this.label});

  final double position; // -1..1
  final Color ink;
  final Color muted;
  final bool active;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final base = size.height - 18;
    final thin = Paint()
      ..color = muted
      ..strokeWidth = 1;
    final strong = Paint()
      ..color = ink
      ..strokeWidth = 1.5;
    // baseline
    canvas.drawLine(Offset(0, base), Offset(w, base), thin);
    // ticks: 41 (every 1/20 of the range), major every 5
    const n = 40;
    for (var i = 0; i <= n; i++) {
      final x = w * i / n;
      final major = i % 10 == 0;
      final mid = i % 5 == 0;
      final h = major ? 16.0 : (mid ? 10.0 : 5.0);
      canvas.drawLine(Offset(x, base - h), Offset(x, base), i == n ~/ 2 ? strong : thin);
    }
    // labels under major ticks
    for (final (i, t) in const [(0, '−20'), (10, '−10'), (20, '0'), (30, '+10'), (40, '+20')]) {
      final tp = TextPainter(text: TextSpan(text: t, style: label), textDirection: TextDirection.ltr)..layout();
      final x = (w * i / n - tp.width / 2).clamp(0.0, w - tp.width);
      tp.paint(canvas, Offset(x, base + 4));
    }
    // needle
    final nx = w / 2 + position * w / 2;
    final needle = Paint()
      ..color = active ? ink : muted
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawLine(Offset(nx, 4), Offset(nx, base), needle)
      ..drawCircle(Offset(nx, 4), 5, Paint()..color = active ? ink : muted);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.position != position || old.ink != ink || old.active != active;
}

/// Concentric ink rings around a centre dot: phones in a room, one sound. Pure illustration.
class GPRings extends StatelessWidget {
  const GPRings({super.key, this.size = 220});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _RingsPainter(ink: GPColors.of(context, GPColors.ink), muted: GPColors.of(context, GPColors.separator)),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.ink, required this.muted});

  final Color ink;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(
        c,
        r * i / 4.4,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = i == 2 ? ink : muted
          ..strokeWidth = i == 2 ? 1.6 : 1,
      );
    }
    canvas.drawCircle(c, r * 0.07, Paint()..color = ink);
    // "phones" on the second ring and the outer ring: small ink capsules
    final phone = Paint()..color = ink;
    for (final (ring, angles) in [(2, [-90.0, 30.0, 150.0]), (4, [-30.0, 90.0, 210.0])]) {
      final rr = r * ring / 4.4;
      for (final a in angles) {
        final rad = a * math.pi / 180;
        final p = c + Offset(math.cos(rad), math.sin(rad)) * rr;
        final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: r * 0.09, height: r * 0.16), Radius.circular(r * 0.025));
        canvas.drawRRect(rect, phone);
      }
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.ink != ink || old.muted != muted;
}
