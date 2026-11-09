import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// This phone as a speaker: is it in sync, and its volume. Timing belongs to the host, which
/// tunes every phone by ear.
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
      return CupertinoPageScaffold(
        backgroundColor: GPColors.background,
        child: Center(
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
      );
    }

    final l = status.local;
    final connected = status.state == 'connected';
    final waiting = status.state == 'waiting';
    final q = connected
        ? syncQuality(synced: l.syncValid, playing: l.playing, errMs: l.errMs)
        : (label: waiting ? 'Waiting for host' : (status.state == 'reconnecting' ? 'Reconnecting' : 'Connecting'), tone: GPTone.warn);
    return GPPage(
      title: status.hostName,
      previousPageTitle: 'Home',
      bottom: GPButton(label: 'Leave Session', style: GPButtonStyle.destructive, busy: leaving, onPressed: () => _leave(context, ref)),
      slivers: [
        GPBlock(
          child: GPSyncCard(
            label: q.label,
            tone: q.tone,
            caption: waiting
                ? 'Open Group Play on ${status.hostName}: this phone rejoins by itself.'
                : (status.source ?? 'Waiting for ${status.hostName} to play something'),
            errorMs: l.errMs,
            active: connected && l.playing && l.syncValid,
            badges: [
              if (connected) GPBadge(linkLabel(status.path, status.pathRttMs), icon: CupertinoIcons.wifi),
              if (l.syncValid) GPBadge('±${formatMs(l.syncRttMs / 2)}', icon: CupertinoIcons.clock),
            ],
          ),
        ),
        GPBlock(
          child: _Calibration(
            delayMs: l.delayMs,
            hostName: status.hostName,
            eqActive: l.eqActive,
            volume: settings.volume,
            onVolume: (v) => unawaited(s.setVolumeLevel(v)),
          ),
        ),
        GPSection(
          children: [
            GPRow(
              leading: const GPIconTile(CupertinoIcons.chart_bar_alt_fill),
              title: 'Details',
              value: l.underrunMs > 0 ? 'Dropouts ${formatMs(l.underrunMs, digits: 0)}' : null,
              onTap: () => context.push(Routes.speakerDetails),
            ),
          ],
        ),
      ],
    );
  }
}

class _Calibration extends StatelessWidget {
  const _Calibration({required this.delayMs, required this.hostName, required this.eqActive, required this.volume, required this.onVolume});

  final double delayMs;
  final String hostName;
  final bool eqActive;
  final double volume;
  final ValueChanged<double> onVolume;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GPSectionLabel('This phone'),
        GPCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              GPSliderCell(
                label: 'Volume',
                value: volume,
                min: 0,
                max: 1,
                format: formatPercent,
                minIcon: CupertinoIcons.speaker_fill,
                maxIcon: CupertinoIcons.speaker_3_fill,
                onChanged: onVolume,
              ),
              const GPRule(indent: GPSpace.md),
              GPRow(
                title: 'Timing',
                subtitle: 'Set by $hostName when it tunes',
                value: formatSignedMs(delayMs),
                figure: true,
                chevron: false,
              ),
              if (eqActive) ...[
                const GPRule(indent: GPSpace.md),
                GPRow(title: 'Sound', subtitle: 'EQ & boost set by $hostName', value: 'On', chevron: false),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Everything the engine knows about this speaker's lock, for when something sounds off.
class SpeakerDetailsScreen extends ConsumerWidget {
  const SpeakerDetailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    final l = status?.local;
    return GPPage(
      title: 'Details',
      previousPageTitle: 'Back',
      slivers: [
        if (l == null || status == null)
          const SliverToBoxAdapter(
            child: GPEmptyState(icon: CupertinoIcons.speaker_2_fill, title: 'Not connected'),
          )
        else ...[
          GPSection(
            header: 'Clock',
            footer: 'Accuracy is half the fastest round trip to the host. Drift is how fast this phone’s crystal runs against the host’s.',
            children: [
              GPRow(title: 'Sync accuracy', figure: true, value: '±${formatMs(l.syncRttMs / 2, digits: 2)}'),
              GPRow(title: 'Clock drift', figure: true, value: '${l.skewPpm.toStringAsFixed(1)} ppm'),
              GPRow(title: 'Samples', figure: true, value: '${l.syncSamples}'),
            ],
          ),
          GPSection(
            header: 'Playback',
            children: [
              GPRow(title: 'Lock error', figure: true, value: formatMs(l.errMs, digits: 2)),
              GPRow(title: 'Buffered', figure: true, value: formatMs(l.bufferMs, digits: 0)),
              GPRow(title: 'Output latency', figure: true, value: formatMs(l.latencyMs)),
              GPRow(title: 'Dropouts', figure: true, value: formatMs(l.underrunMs, digits: 0)),
              GPRow(title: 'Late audio', figure: true, value: formatMs(l.lateMs, digits: 0)),
              GPRow(title: 'Resyncs', figure: true, value: '${l.jumps}'),
            ],
          ),
          GPSection(
            header: 'Link',
            children: [
              GPRow(title: 'Host', value: status.hostName),
              GPRow(title: 'Path', value: linkLabel(status.path, status.pathRttMs)),
              GPRow(title: 'Output', subtitle: l.output.isEmpty ? '—' : l.output),
              if (l.outputError != null) GPRow(title: 'Output error', subtitle: l.outputError),
            ],
          ),
        ],
      ],
    );
  }
}
