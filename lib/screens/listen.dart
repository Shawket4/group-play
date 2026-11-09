import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../src/rust/api/engine.dart' as rust;
import '../widgets/common.dart';
import 'logs.dart';

/// A speaker: shows the link, sync quality and this phone's calibration.
class ListenScreen extends StatelessWidget {
  const ListenScreen({super.key, required this.controller});
  final TuttiController controller;

  Future<void> _leave(BuildContext context) async {
    await controller.leave();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return MessageListener(
      controller: controller,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Speaker'),
          actions: [
            IconButton(icon: const Icon(Icons.receipt_long_rounded), tooltip: 'Logs', onPressed: () => showLogs(context, controller)),
            TextButton(onPressed: () => _leave(context), child: const Text('Leave', style: TextStyle(color: TuttiColors.bad))),
            const SizedBox(width: 6),
          ],
        ),
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final s = controller.status;
            if (s == null || s.role != 'guest') {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(s?.endedReason ?? 'Session ended', style: const TextStyle(color: TuttiColors.muted)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
                ]),
              );
            }
            final l = s.local;
            final q = syncQuality(synced: l.syncValid, playing: l.playing, errMs: l.errMs);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                Section(
                  child: Column(children: [
                    const SizedBox(height: 6),
                    _SyncOrb(color: q.color, active: l.playing),
                    const SizedBox(height: 18),
                    Text(q.label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: q.color)),
                    const SizedBox(height: 6),
                    Text(
                      s.source != null ? s.source! : 'Waiting for ${s.hostName} to play something',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: TuttiColors.muted),
                    ),
                    const SizedBox(height: 14),
                    Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                      Pill(s.hostName, icon: Icons.podcasts_rounded, color: TuttiColors.cyan),
                      Pill(_linkLabel(s), color: s.state == 'connected' ? TuttiColors.good : TuttiColors.warn, icon: Icons.wifi_rounded),
                    ]),
                    const SizedBox(height: 6),
                  ]),
                ),
                const SizedBox(height: 14),
                Section(
                  title: 'This phone',
                  child: Column(children: [
                    DelayControl(value: l.delayMs, onChanged: controller.setDelay),
                    const SizedBox(height: 8),
                    VolumeControl(value: l.volume, onChanged: controller.setVolume),
                  ]),
                ),
                const SizedBox(height: 14),
                Section(
                  title: 'Details',
                  child: StatGrid([
                    ('Clock offset', fmtMs(l.syncOffsetMs, digits: 2)),
                    ('Best round trip', fmtMs(l.syncRttMs, digits: 2)),
                    ('Clock drift', '${l.skewPpm.toStringAsFixed(1)} ppm'),
                    ('Sync samples', '${l.syncSamples}'),
                    ('Lock error', fmtMs(l.errMs, digits: 2)),
                    ('Buffered', fmtMs(l.bufferMs, digits: 0)),
                    ('Output latency', fmtMs(l.latencyMs)),
                    ('Underruns', fmtMs(l.underrunMs, digits: 0)),
                    ('Resyncs', '${l.jumps}'),
                    ('Output', l.output.isEmpty ? '—' : l.output),
                    if (l.outputError != null) ('Output error', l.outputError!),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _linkLabel(rust.EngineStatus s) {
    if (s.state != 'connected') return s.state;
    final path = s.path.isEmpty ? 'connected' : s.path;
    return s.pathRttMs > 0 ? '$path · ${s.pathRttMs.toStringAsFixed(0)} ms' : path;
  }
}

/// A softly pulsing orb in the sync colour.
class _SyncOrb extends StatefulWidget {
  const _SyncOrb({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  State<_SyncOrb> createState() => _SyncOrbState();
}

class _SyncOrbState extends State<_SyncOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (context, _) {
        final t = widget.active ? _a.value : 0.0;
        final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
        return SizedBox(
          width: 150,
          height: 150,
          child: Stack(alignment: Alignment.center, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 90 + 60 * ((t + i / 3) % 1.0),
                height: 90 + 60 * ((t + i / 3) % 1.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: widget.color.withValues(alpha: widget.active ? 0.35 * (1 - ((t + i / 3) % 1.0)) : 0.0), width: 2),
                ),
              ),
            Container(
              width: 84 + 6 * pulse,
              height: 84 + 6 * pulse,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [widget.color, widget.color.withValues(alpha: 0.35)]),
                boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.45), blurRadius: 30, spreadRadius: 2)],
              ),
              child: const Icon(Icons.speaker_rounded, size: 38, color: Colors.black87),
            ),
          ]),
        );
      },
    );
  }
}
