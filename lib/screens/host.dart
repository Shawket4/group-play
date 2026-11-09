import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../platform/android_native.dart';
import '../src/rust/api/engine.dart' as rust;
import '../widgets/common.dart';
import 'logs.dart';
import 'setup.dart';

class HostScreen extends StatelessWidget {
  const HostScreen({super.key, required this.controller});
  final TuttiController controller;

  Future<void> _end(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End the session?'),
        content: const Text('Every speaker stops playing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('End')),
        ],
      ),
    );
    if (ok != true) return;
    await controller.leave();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return MessageListener(
      controller: controller,
      child: PopScope(
        canPop: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Hosting'),
            actions: [
              IconButton(icon: const Icon(Icons.receipt_long_rounded), tooltip: 'Logs', onPressed: () => showLogs(context, controller)),
              TextButton(onPressed: () => _end(context), child: const Text('End', style: TextStyle(color: TuttiColors.bad))),
              const SizedBox(width: 6),
            ],
          ),
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final s = controller.status;
              if (s == null || s.role != 'host') {
                return const Center(child: Text('Not hosting', style: TextStyle(color: TuttiColors.muted)));
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _InviteCard(controller: controller, status: s),
                  const SizedBox(height: 14),
                  _PlayCard(controller: controller, status: s),
                  const SizedBox(height: 14),
                  _SpeakersCard(controller: controller, status: s),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.controller, required this.status});
  final TuttiController controller;
  final rust.EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final ticket = status.ticket ?? '';
    final connected = status.peers.where((p) => p.connected).length;
    final hs = controller.hotspot;
    return Section(
      title: 'Invite speakers',
      trailing: Pill('$connected connected', color: connected > 0 ? TuttiColors.good : TuttiColors.muted, icon: Icons.speaker_group_rounded),
      child: Column(children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: QrImageView(data: ticket, size: 240, errorCorrectionLevel: QrErrorCorrectLevel.L, gapless: true),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Open Tutti on another phone → Join → scan.', textAlign: TextAlign.center, style: TextStyle(color: TuttiColors.muted)),
        if (AndroidNative.available) ...[
          const SizedBox(height: 14),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Make a Wi-Fi hotspot'),
            subtitle: Text(hs == null ? 'For places without Wi-Fi. Speakers join it from the QR code.' : '${hs.ssid}  ·  ${hs.passphrase}'),
            value: hs != null,
            onChanged: controller.busy ? null : (on) => on ? controller.startHotspot() : controller.stopHotspot(),
          ),
          if (hs != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(data: 'WIFI:T:WPA;S:${_esc(hs.ssid)};P:${_esc(hs.passphrase)};;', size: 96, gapless: true),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text('iPhones: scan this one with the Camera app to join the hotspot first, then scan the big code in Tutti.',
                      style: TextStyle(fontSize: 13, color: TuttiColors.muted)),
                ),
              ]),
            ),
        ],
      ]),
    );
  }

  static String _esc(String s) => s.replaceAllMapped(RegExp(r'([\;,:"])'), (m) => '\\${m[1]}');
}

class _PlayCard extends StatelessWidget {
  const _PlayCard({required this.controller, required this.status});
  final TuttiController controller;
  final rust.EngineStatus status;

  Future<void> _pickFile(BuildContext context) async {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null) {
      controller.logs.add('  app picked file has no local path');
      return;
    }
    await controller.playFile(path);
  }

  Future<void> _capture(BuildContext context, CaptureMode mode) async {
    if (mode == CaptureMode.output) {
      await controller.refreshCaps();
      if (!controller.caps.fullCaptureReady && context.mounted) {
        final ready = await showShizukuSetup(context, controller);
        if (ready != true) return;
      }
    }
    await controller.playCapture(mode);
  }

  @override
  Widget build(BuildContext context) {
    final playing = status.source;
    final busy = controller.busy;
    return Section(
      title: 'Play',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (playing != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: TuttiColors.surfaceHigh, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              const _Equalizer(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Now playing', style: TextStyle(fontSize: 12, color: TuttiColors.muted)),
                  const SizedBox(height: 2),
                  Text(playing, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              IconButton.filledTonal(onPressed: busy ? null : controller.stopSource, icon: const Icon(Icons.stop_rounded)),
            ]),
          ),
          const SizedBox(height: 14),
        ],
        _SourceTile(
          icon: Icons.graphic_eq_rounded,
          title: 'Sync test',
          subtitle: 'Clicks on every beat. Phones in sync sound like one click.',
          active: controller.source == SourceKind.clicks && playing != null,
          onTap: busy ? null : controller.playClicks,
        ),
        _SourceTile(
          icon: Icons.library_music_rounded,
          title: 'Music file',
          subtitle: 'MP3, AAC/M4A, FLAC, WAV, OGG from this phone.',
          active: controller.source == SourceKind.file && playing != null,
          onTap: busy ? null : () => _pickFile(context),
        ),
        if (AndroidNative.available) ...[
          _SourceTile(
            icon: Icons.cast_rounded,
            title: 'Everything this phone plays',
            subtitle: controller.caps.fullCaptureReady
                ? 'Spotify, YouTube, Chrome, games… via Shizuku. This phone goes quiet; the speakers play.'
                : 'Needs Shizuku (one-time setup). Works with Spotify and Chrome too.',
            badge: 'Full',
            active: controller.source == SourceKind.captureFull,
            onTap: busy ? null : () => _capture(context, CaptureMode.output),
          ),
          _SourceTile(
            icon: Icons.screen_share_rounded,
            title: 'Apps that allow capture',
            subtitle: 'No setup. YouTube, YouTube Music, Apple Music… (not Spotify or Chrome).',
            badge: 'Basic',
            active: controller.source == SourceKind.captureBasic,
            onTap: busy ? null : () => _capture(context, CaptureMode.playback),
          ),
        ],
        if (controller.capturing) ...[
          const SizedBox(height: 6),
          _PlayoutDelay(controller: controller),
        ],
      ]),
    );
  }
}

class _PlayoutDelay extends StatefulWidget {
  const _PlayoutDelay({required this.controller});
  final TuttiController controller;

  @override
  State<_PlayoutDelay> createState() => _PlayoutDelayState();
}

class _PlayoutDelayState extends State<_PlayoutDelay> {
  double _ms = 300;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Buffer', style: TextStyle(color: TuttiColors.muted)),
        const Spacer(),
        Text('${_ms.round()} ms'),
      ]),
      Slider(
        value: _ms,
        min: 120,
        max: 1000,
        divisions: 22,
        onChanged: (v) => setState(() => _ms = v),
        onChangeEnd: (v) => widget.controller.setPlayoutDelay(v.round()),
      ),
      const Text('Raise it if speakers drop out. Applies the next time you start sharing.',
          style: TextStyle(fontSize: 12, color: TuttiColors.muted)),
    ]);
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.icon, required this.title, required this.subtitle, required this.onTap, this.active = false, this.badge});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool active;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: active ? TuttiColors.cyan : TuttiColors.outline, width: active ? 1.5 : 1),
            color: active ? TuttiColors.cyan.withValues(alpha: 0.06) : null,
          ),
          child: Row(children: [
            Icon(icon, color: active ? TuttiColors.cyan : TuttiColors.text),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (badge != null) ...[const SizedBox(width: 8), Pill(badge!, color: TuttiColors.violet)],
                ]),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(fontSize: 12.5, color: TuttiColors.muted)),
              ]),
            ),
            if (active) const Icon(Icons.check_circle_rounded, color: TuttiColors.cyan),
          ]),
        ),
      ),
    );
  }
}

class _SpeakersCard extends StatelessWidget {
  const _SpeakersCard({required this.controller, required this.status});
  final TuttiController controller;
  final rust.EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final l = status.local;
    return Section(
      title: 'Speakers',
      child: Column(children: [
        _LocalTile(controller: controller, local: l),
        for (final p in status.peers) ...[const Divider(), _PeerTile(controller: controller, peer: p)],
        if (status.peers.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('No speakers yet. They appear here as they join.', style: TextStyle(color: TuttiColors.muted)),
          ),
      ]),
    );
  }
}

class _LocalTile extends StatelessWidget {
  const _LocalTile({required this.controller, required this.local});
  final TuttiController controller;
  final rust.LocalStatus local;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      leading: Icon(platformIcon(controller.platform)),
      title: Text('${controller.deviceName} (this phone)'),
      subtitle: Text(
        controller.capturing ? 'Sharing its audio — the speakers play it' : (local.enabled ? 'Plays along' : 'Silent'),
        style: const TextStyle(color: TuttiColors.muted, fontSize: 12.5),
      ),
      trailing: Switch(value: local.enabled && !controller.capturing, onChanged: (v) => controller.setHostLocal(v)),
      children: [
        DelayControl(value: local.delayMs, onChanged: controller.setDelay),
        VolumeControl(value: local.volume, onChanged: controller.setVolume),
        const SizedBox(height: 6),
        StatGrid([
          ('Output', local.output.isEmpty ? '—' : local.output),
          ('Output latency', fmtMs(local.latencyMs)),
          ('Underruns', fmtMs(local.underrunMs, digits: 0)),
        ]),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.controller, required this.peer});
  final TuttiController controller;
  final rust.PeerStatus peer;

  @override
  Widget build(BuildContext context) {
    final q = syncQuality(synced: peer.connected && peer.rttMs > 0, playing: peer.playing, errMs: peer.errMs);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      leading: Icon(platformIcon(peer.platform), color: peer.connected ? TuttiColors.text : TuttiColors.muted),
      title: Text(peer.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 6, runSpacing: 4, children: [
          if (!peer.connected)
            const Pill('left', color: TuttiColors.bad)
          else ...[
            Pill(q.label, color: q.color),
            Pill('${peer.path.isEmpty ? 'link' : peer.path} · ${peer.rttMs.toStringAsFixed(0)} ms'),
          ],
        ]),
      ),
      children: [
        DelayControl(value: peer.delayMs, onChanged: (v) => controller.setPeerDelay(peer.id, v)),
        VolumeControl(value: peer.volume, onChanged: (v) => controller.setPeerVolume(peer.id, v)),
        const SizedBox(height: 6),
        StatGrid([
          ('Clock offset', fmtMs(peer.syncOffsetMs, digits: 2)),
          ('Clock drift', '${peer.skewPpm.toStringAsFixed(1)} ppm'),
          ('Buffered', fmtMs(peer.bufferMs, digits: 0)),
          ('Output latency', fmtMs(peer.latencyMs)),
          ('Underruns', fmtMs(peer.underrunMs, digits: 0)),
          ('Resyncs', '${peer.jumps}'),
          ('Output', peer.output.isEmpty ? '—' : peer.output),
        ]),
        const SizedBox(height: 10),
      ],
    );
  }
}

/// Three bouncing bars.
class _Equalizer extends StatefulWidget {
  const _Equalizer();

  @override
  State<_Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<_Equalizer> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

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
        return SizedBox(
          width: 26,
          height: 24,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6 + 18 * (0.5 + 0.5 * _wave(_a.value + i * 0.27)),
                decoration: BoxDecoration(gradient: TuttiColors.accent, borderRadius: BorderRadius.circular(3)),
              ),
          ]),
        );
      },
    );
  }

  double _wave(double t) {
    final x = (t % 1.0) * 2 - 1;
    return 1 - x * x * 2 + (x.abs() * 0.4);
  }
}
