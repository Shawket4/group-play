import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:feature_host/src/drafts.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// One speaker, seen from the host: timing, volume, link and sync details.
/// `id == Routes.localSpeakerId` is the host phone itself.
class SpeakerDetailScreen extends ConsumerWidget {
  const SpeakerDetailScreen({required this.id, super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    if (status == null) return const CupertinoPageScaffold(child: Center(child: CupertinoActivityIndicator()));
    if (id == Routes.localSpeakerId) return _LocalDetail(status: status);
    final peer = status.peers.where((p) => p.id == id).firstOrNull;
    if (peer == null) {
      return const GPPage(
        title: 'Speaker',
        previousPageTitle: 'Hosting',
        slivers: [SliverToBoxAdapter(child: GPEmptyState(icon: CupertinoIcons.speaker_2_fill, title: 'This speaker left'))],
      );
    }
    return _PeerDetail(peer: peer);
  }
}

class _PeerDetail extends ConsumerWidget {
  const _PeerDetail({required this.peer});

  final PeerStatus peer;

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
        GPSection(
          children: [
            GPRow(title: 'Status', trailing: GPBadge(q.label, tone: q.tone)),
            GPRow(title: 'Link', value: peer.connected ? linkLabel(peer.path, peer.rttMs) : 'Disconnected'),
          ],
        ),
        GPSection(
          header: 'Calibration',
          footer: 'Sounds early compared with the others? Add delay. Late? Take some away.',
          children: [
            GPSliderCell(
              label: 'Timing',
              value: drafts[delayKey] ?? peer.delayMs,
              min: -200,
              max: 200,
              step: 1,
              format: formatSignedMs,
              onChanged: (v) {
                d.set(delayKey, v);
                unawaited(n.setPeerDelay(peer.id, v));
              },
              onChangeEnd: (_) => d.release(delayKey),
            ),
            GPSliderCell(
              label: 'Volume',
              value: drafts[volKey] ?? peer.volume,
              min: 0,
              max: 1,
              format: formatPercent,
              minIcon: CupertinoIcons.speaker_fill,
              maxIcon: CupertinoIcons.speaker_3_fill,
              onChanged: (v) {
                d.set(volKey, v);
                unawaited(n.setPeerVolume(peer.id, v));
              },
              onChangeEnd: (_) => d.release(volKey),
            ),
          ],
        ),
        GPSection(
          header: 'Details',
          children: [
            GPRow(title: 'Sync accuracy', figure: true, value: '±${formatMs(peer.rttMs / 2, digits: 2)}'),
            GPRow(title: 'Clock drift', figure: true, value: '${peer.skewPpm.toStringAsFixed(1)} ppm'),
            GPRow(title: 'Lock error', figure: true, value: formatMs(peer.errMs, digits: 2)),
            GPRow(title: 'Buffered', figure: true, value: formatMs(peer.bufferMs, digits: 0)),
            GPRow(title: 'Output latency', figure: true, value: formatMs(peer.latencyMs)),
            GPRow(title: 'Dropouts', figure: true, value: formatMs(peer.underrunMs, digits: 0)),
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
    final capturing = ref.watch(sessionProvider.select((x) => x.capturing));
    final l = status.local;
    return GPPage(
      title: 'This Phone',
      previousPageTitle: 'Hosting',
      slivers: [
        GPSection(
          footer: capturing
              ? 'While this phone shares its own audio it stays quiet: the speakers play it.'
              : 'Turn off to use this phone only as the remote.',
          children: [
            GPSwitchRow(
              leading: const GPIconTile(CupertinoIcons.speaker_2_fill),
              title: 'Play Along',
              value: l.enabled && !capturing,
              onChanged: capturing ? null : (v) => ref.read(sessionProvider.notifier).setHostLocal(v),
            ),
          ],
        ),
        GPSection(
          header: 'Calibration',
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
