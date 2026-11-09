import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:feature_host/src/drafts.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// One speaker, seen from the host: its lock, its calibration, its details.
/// `id == Routes.localSpeakerId` is the host phone itself.
class SpeakerDetailScreen extends ConsumerWidget {
  const SpeakerDetailScreen({required this.id, super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    if (status == null) {
      return const CupertinoPageScaffold(
        backgroundColor: GPColors.background,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (id == Routes.localSpeakerId) return _LocalDetail(status: status);
    final peer = status.peers.where((p) => p.id == id).firstOrNull;
    if (peer == null) {
      return const GPPage(
        title: 'Speaker',
        previousPageTitle: 'Hosting',
        slivers: [
          SliverToBoxAdapter(
            child: GPEmptyState(icon: CupertinoIcons.speaker_2_fill, title: 'This speaker left'),
          ),
        ],
      );
    }
    return _PeerDetail(peer: peer, source: status.source);
  }
}

class _CalibrationCard extends StatelessWidget {
  const _CalibrationCard({
    required this.label,
    required this.delayMs,
    required this.tuned,
    required this.volume,
    required this.onDelay,
    required this.onVolume,
    this.onDelayEnd,
    this.onVolumeEnd,
  });

  final String label;
  final double delayMs;
  final bool tuned;
  final double volume;
  final ValueChanged<double> onDelay;
  final ValueChanged<double> onVolume;
  final ValueChanged<double>? onDelayEnd;
  final ValueChanged<double>? onVolumeEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GPSectionLabel(label),
        GPCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              GPSliderCell(
                label: 'Timing',
                value: delayMs,
                min: -200,
                max: 200,
                step: 1,
                format: formatSignedMs,
                hint: tuned
                    ? 'Set by tuning. Still early compared with the others? Add delay. Late? Take some away.'
                    : 'Tune sets this by ear. Or by hand: early compared with the others? Add delay. Late? Take some away.',
                onChanged: onDelay,
                onChangeEnd: onDelayEnd,
              ),
              const GPRule(indent: GPSpace.md),
              GPSliderCell(
                label: 'Volume',
                value: volume,
                min: 0,
                max: 1,
                format: formatPercent,
                minIcon: CupertinoIcons.speaker_fill,
                maxIcon: CupertinoIcons.speaker_3_fill,
                onChanged: onVolume,
                onChangeEnd: onVolumeEnd,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PeerDetail extends ConsumerWidget {
  const _PeerDetail({required this.peer, required this.source});

  final PeerStatus peer;
  final String? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = ref.watch(sliderDraftsProvider);
    final d = ref.read(sliderDraftsProvider.notifier);
    final n = ref.read(sessionProvider.notifier);
    final delayKey = '${peer.id}:delay';
    final volKey = '${peer.id}:volume';
    final q = peerQuality(peer);
    return GPPage(
      title: peer.name,
      previousPageTitle: 'Hosting',
      slivers: [
        GPBlock(
          child: GPSyncCard(
            label: q.label,
            tone: q.tone,
            caption: peer.connected ? (source ?? 'Nothing playing') : 'Disconnected',
            errorMs: peer.errMs,
            active: peer.connected && peer.playing,
            badges: [
              if (peer.connected) GPBadge(linkLabel(peer.path, peer.rttMs), icon: CupertinoIcons.wifi),
              if (peer.tuned) const GPBadge('Tuned', icon: CupertinoIcons.tuningfork),
              GPBadge(
                peer.platform == 'ios' ? 'iPhone' : (peer.platform == 'android' ? 'Android' : peer.platform),
                icon: CupertinoIcons.device_phone_portrait,
              ),
            ],
          ),
        ),
        GPBlock(
          child: _CalibrationCard(
            label: 'Calibration',
            delayMs: drafts[delayKey] ?? peer.delayMs,
            tuned: peer.tuned,
            volume: drafts[volKey] ?? peer.volume,
            // sent when the finger lifts: each timing change is applied at once (a short fade)
            onDelay: (v) => d.set(delayKey, v),
            onDelayEnd: (v) {
              unawaited(n.setPeerDelay(peer.id, v));
              d.release(delayKey);
            },
            onVolume: (v) {
              d.set(volKey, v);
              unawaited(n.setPeerVolume(peer.id, v));
            },
            onVolumeEnd: (_) => d.release(volKey),
          ),
        ),
        GPSection(
          header: 'Details',
          children: [
            GPRow(title: 'Sync accuracy', figure: true, value: '±${formatMs(peer.syncRttMs / 2, digits: 2)}'),
            GPRow(title: 'Clock drift', figure: true, value: '${peer.skewPpm.toStringAsFixed(1)} ppm'),
            GPRow(title: 'Lock error', figure: true, value: formatMs(peer.errMs, digits: 2)),
            GPRow(title: 'Buffered', figure: true, value: formatMs(peer.bufferMs, digits: 0)),
            GPRow(title: 'Output latency', figure: true, value: formatMs(peer.latencyMs)),
            GPRow(title: 'Dropouts', figure: true, value: formatMs(peer.underrunMs, digits: 0)),
            GPRow(title: 'Late audio', figure: true, value: formatMs(peer.lateMs, digits: 0)),
            GPRow(title: 'Resyncs', figure: true, value: '${peer.jumps}'),
            GPRow(title: 'Output', subtitle: peer.output.isEmpty ? '—' : peer.output),
          ],
        ),
      ],
    );
  }
}

class _LocalDetail extends ConsumerWidget {
  const _LocalDetail({required this.status});

  final EngineStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(deviceSettingsProvider);
    final s = ref.read(deviceSettingsProvider.notifier);
    final basic = ref.watch(sessionProvider.select((x) => x.source == SourceKind.captureBasic));
    final drafts = ref.watch(sliderDraftsProvider);
    final d = ref.read(sliderDraftsProvider.notifier);
    final n = ref.read(sessionProvider.notifier);
    const delayKey = 'local:delay';
    final l = status.local;
    return GPPage(
      title: settings.name,
      previousPageTitle: 'Hosting',
      slivers: [
        GPSection(
          footer: basic
              ? 'With basic sharing the app plays here directly, ahead of the speakers. Full sharing keeps this phone in step.'
              : 'Turn off to use this phone only as the remote.',
          children: [
            GPSwitchRow(
              leading: const GPIconTile(CupertinoIcons.speaker_2_fill),
              title: 'Play Along',
              value: l.enabled && !basic,
              onChanged: basic ? null : n.setHostLocal,
            ),
          ],
        ),
        GPBlock(
          child: _CalibrationCard(
            label: 'This phone',
            delayMs: drafts[delayKey] ?? l.delayMs,
            tuned: l.tuned,
            volume: settings.volume,
            onDelay: (v) => d.set(delayKey, v),
            onDelayEnd: (v) {
              unawaited(n.setHostDelay(v));
              d.release(delayKey);
            },
            onVolume: (v) => unawaited(s.setVolumeLevel(v)),
          ),
        ),
        GPSection(
          header: 'Details',
          children: [
            GPRow(title: 'Output latency', figure: true, value: formatMs(l.latencyMs)),
            GPRow(title: 'Dropouts', figure: true, value: formatMs(l.underrunMs, digits: 0)),
            GPRow(title: 'Output', subtitle: l.output.isEmpty ? '—' : l.output),
            if (l.outputError != null) GPRow(title: 'Output error', subtitle: l.outputError),
          ],
        ),
      ],
    );
  }
}
