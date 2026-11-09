import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// Tuning: one tap that lines every phone up by ear. The primary action until every
/// connected speaker is tuned; a quiet "tune again" after.
class TuneCard extends ConsumerWidget {
  const TuneCard({required this.status, super.key});

  final EngineStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final busy = session.pending == SessionAction.tuning || status.tuning;
    final connected = status.peers.where((p) => p.connected).toList();
    final untuned = connected.where((p) => !p.tuned).length;
    final report = session.lastTune;
    final secondary = GPColors.of(context, GPColors.secondaryLabel);

    final (String title, String caption) = switch (()) {
      _ when busy => ('Listening…', 'Each phone chirps in turn while this one listens. Keep the room quiet.'),
      _ when report != null && report.devices.every((d) => d.heard) => (
        'Lined up',
        report.spreadBeforeMs >= 1
            ? 'They were ${formatMs(report.spreadBeforeMs)} apart; now they play together. Tune again after switching to headphones or Bluetooth.'
            : 'They already played together. Tune again after switching to headphones or Bluetooth.',
      ),
      _ when report != null => (
        'Partly tuned',
        'Couldn’t hear ${report.devices.where((d) => !d.heard).map((d) => d.name).join(', ')}. Bring it next to this phone, turn it up, and tune again.',
      ),
      _ when untuned > 0 => (
        untuned == connected.length ? 'Tune the speakers' : 'Tune the new speaker',
        'Put the phones side by side and tap Tune. Takes about five seconds, with a few chirps.',
      ),
      _ => ('Tuned', 'Remembered from last time. Tune again after switching to headphones or Bluetooth.'),
    };

    return GPCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const GPIconTile(CupertinoIcons.tuningfork),
              const SizedBox(width: GPSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: GPText.headline),
                    const SizedBox(height: 2),
                    Text(caption, style: GPText.footnote.copyWith(color: secondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: GPSpace.sm),
          GPButton(
            label: untuned > 0 ? 'Tune' : 'Tune Again',
            icon: CupertinoIcons.ear,
            style: untuned > 0 ? GPButtonStyle.filled : GPButtonStyle.secondary,
            busy: busy,
            onPressed: connected.isEmpty ? null : () => unawaited(ref.read(sessionProvider.notifier).tune()),
          ),
        ],
      ),
    );
  }
}
