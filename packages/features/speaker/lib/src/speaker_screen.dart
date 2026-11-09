import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// This phone as a speaker: how well it is locked to the host, its calibration, diagnostics.
class SpeakerScreen extends ConsumerWidget {
  const SpeakerScreen({super.key});

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (c) => CupertinoAlertDialog(
        title: const Text('Leave Session?'),
        content: const Text('This phone stops playing.'),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sessionProvider.notifier).leave();
    if (context.mounted) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    final settings = ref.watch(deviceSettingsProvider);
    final s = ref.read(deviceSettingsProvider.notifier);
    final leaving = ref.watch(sessionProvider.select((x) => x.pending == SessionAction.leaving));

    if (status == null || status.role != 'guest' || status.state == 'ended') {
      return GPPage(
        title: 'Speaker',
        slivers: [
          SliverToBoxAdapter(
            child: GPEmptyState(
              icon: CupertinoIcons.speaker_2_fill,
              title: 'Session ended',
              message: status?.endedReason ?? 'The host ended the session.',
              action: GPButton(
                label: 'Done',
                onPressed: () async {
                  await ref.read(sessionProvider.notifier).leave();
                  if (context.mounted) context.go(Routes.home);
                },
              ),
            ),
          ),
        ],
      );
    }

    final l = status.local;
    return GPPage(
      title: 'Speaker',
      previousPageTitle: 'Group Play',
      bottom: GPButton(
        label: 'Leave Session',
        style: GPButtonStyle.destructive,
        busy: leaving,
        onPressed: () => _leave(context, ref),
      ),
      slivers: [
        SliverToBoxAdapter(child: _SyncHeader(status: status)),
        GPSection(
          header: 'This phone',
          footer: 'Sounds early compared with the others? Add delay. Late? Take some away.',
          children: [
            GPSliderCell(
              label: 'Timing',
              value: settings.delayMs,
              min: -200,
              max: 200,
              step: 1,
              format: formatSignedMs,
              onChanged: (v) => unawaited(s.setDelay(v)),
            ),
            GPSliderCell(
              label: 'Volume',
              value: settings.volume,
              min: 0,
              max: 1,
              format: formatPercent,
              minIcon: CupertinoIcons.speaker_fill,
              maxIcon: CupertinoIcons.speaker_3_fill,
              onChanged: (v) => unawaited(s.setVolumeLevel(v)),
            ),
          ],
        ),
        GPSection(
          header: 'Details',
          children: [
            GPRow(title: 'Sync accuracy', figure: true, value: '±${formatMs(l.syncRttMs / 2, digits: 2)}'),
            GPRow(title: 'Clock drift', figure: true, value: '${l.skewPpm.toStringAsFixed(1)} ppm'),
            GPRow(title: 'Lock error', figure: true, value: formatMs(l.errMs, digits: 2)),
            GPRow(title: 'Buffered', figure: true, value: formatMs(l.bufferMs, digits: 0)),
            GPRow(title: 'Output latency', figure: true, value: formatMs(l.latencyMs)),
            GPRow(title: 'Dropouts', figure: true, value: formatMs(l.underrunMs, digits: 0)),
            GPRow(title: 'Resyncs', figure: true, value: '${l.jumps}'),
            GPRow(title: 'Output', subtitle: l.output.isEmpty ? '—' : l.output),
            if (l.outputError != null) GPRow(title: 'Output error', subtitle: l.outputError),
          ],
        ),
      ],
    );
  }
}

/// Big, calm status: a glyph, one sentence, what plays, the link.
class _SyncHeader extends StatelessWidget {
  const _SyncHeader({required this.status});

  final EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final l = status.local;
    final connected = status.state == 'connected';
    final q = connected
        ? syncQuality(synced: l.syncValid, playing: l.playing, errMs: l.errMs)
        : (label: status.state == 'reconnecting' ? 'Reconnecting' : 'Connecting', tone: GPTone.warn);
    final ink = GPColors.of(context, GPColors.ink);
    final icon = switch (q.tone) {
      GPTone.good => CupertinoIcons.checkmark_alt,
      GPTone.bad => CupertinoIcons.exclamationmark,
      _ => CupertinoIcons.clock,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(GPSpace.page, GPSpace.xs, GPSpace.page, GPSpace.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: GPSpace.xl, horizontal: GPSpace.md),
        decoration: BoxDecoration(
          color: GPColors.of(context, GPColors.surface),
          borderRadius: BorderRadius.circular(GPRadius.large),
          border: Border.all(color: GPColors.of(context, GPColors.separator)),
        ),
        child: Column(
          children: [
            AnimatedContainer(
              duration: GPMotion.of(context, GPMotion.standard),
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: GPColors.of(context, GPColors.fill), shape: BoxShape.circle),
              child: AnimatedSwitcher(
                duration: GPMotion.of(context, GPMotion.fast),
                child: Icon(icon, key: ValueKey(icon), color: ink, size: 34),
              ),
            ),
            const SizedBox(height: GPSpace.md),
            Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: GPColors.of(context, q.tone.color), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: GPSpace.xs),
                  Text(q.label, style: GPText.title2),
                ],
              ),
            ),
            const SizedBox(height: GPSpace.xxs),
            Text(
              status.source ?? 'Waiting for ${status.hostName} to play something',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
            ),
            const SizedBox(height: GPSpace.md),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: GPSpace.xs,
              runSpacing: GPSpace.xs,
              children: [
                GPBadge(status.hostName, tone: GPTone.ink, icon: CupertinoIcons.dot_radiowaves_left_right),
                if (connected) GPBadge(linkLabel(status.path, status.pathRttMs), icon: CupertinoIcons.wifi),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
