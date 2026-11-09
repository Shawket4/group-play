import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// The host's control room: invite, what plays, and every speaker.
class HostScreen extends ConsumerWidget {
  const HostScreen({super.key});

  Future<void> _end(BuildContext context, WidgetRef ref) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (c) => CupertinoAlertDialog(
        title: const Text('End Session?'),
        content: const Text('Every speaker stops playing.'),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(c, true), child: const Text('End Session')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ref.read(sessionProvider.notifier).leave();
    if (done && context.mounted) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    final session = ref.watch(sessionProvider);
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    if (status == null || status.role != 'host') {
      return const CupertinoPageScaffold(child: Center(child: CupertinoActivityIndicator()));
    }
    final connected = status.peers.where((p) => p.connected).length;
    return GPPage(
      title: 'Hosting',
      previousPageTitle: 'Group Play',
      trailing: GPBarButton('End', destructive: true, onPressed: () => _end(context, ref)),
      slivers: [
        GPSection(
          header: 'Invite',
          footer: connected == 0
              ? 'On another phone open Group Play, tap Join as a Speaker, and scan this code.'
              : '$connected ${connected == 1 ? 'speaker' : 'speakers'} connected. More can join any time.',
          children: [
            GPQrCell(data: status.ticket ?? '', caption: 'Scan with Group Play'),
          ],
        ),
        if (AndroidNative.available) _HotspotSection(hotspot: session.hotspot, busy: session.pending == SessionAction.hotspot),
        if (status.source != null) _NowPlaying(source: status.source!, speakers: connected, busy: session.pending == SessionAction.source),
        _Sources(session: session, playing: status.source != null),
        if (session.capturing) _BufferSection(ms: session.playoutDelayMs),
        GPSection(
          header: 'Speakers',
          footer: status.peers.isEmpty ? 'Speakers appear here as they join. Tap one to fine-tune its timing.' : 'Tap a speaker to fine-tune its timing and volume.',
          children: [
            GPRow(
              leading: const GPIconTile(CupertinoIcons.device_phone_portrait),
              title: '$name (This Phone)',
              subtitle: session.capturing ? 'Quiet while sharing its audio' : (status.local.enabled ? 'Plays along' : 'Silent'),
              onTap: () => context.push(Routes.hostSpeaker(Routes.localSpeakerId)),
            ),
            for (final p in status.peers) _PeerRow(peer: p),
          ],
        ),
      ],
    );
  }
}

class _HotspotSection extends ConsumerWidget {
  const _HotspotSection({required this.hotspot, required this.busy});

  final HotspotInfo? hotspot;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(sessionProvider.notifier);
    final h = hotspot;
    return GPSection(
      header: 'Wi-Fi',
      footer: h == null
          ? 'No Wi-Fi where you are? This phone can make a private hotspot. Its details go into the join code.'
          : 'Android speakers join the hotspot from the join code. iPhones: scan the small code with the Camera app first, then scan the join code in Group Play.',
      children: [
        GPSwitchRow(
          leading: const GPIconTile(CupertinoIcons.wifi),
          title: 'Hotspot',
          value: h != null,
          onChanged: busy ? null : (on) => on ? n.startHotspot() : n.stopHotspot(),
        ),
        if (h != null) ...[
          GPRow(title: 'Network', value: h.ssid),
          GPRow(title: 'Password', value: h.passphrase),
          GPCellContent(
            child: Row(
              children: [
                GPQrCode(
                  data: 'WIFI:T:WPA;S:${_esc(h.ssid)};P:${_esc(h.passphrase)};;',
                  size: 96,
                  semanticLabel: 'Wi-Fi code for the hotspot',
                ),
                const SizedBox(width: GPSpace.md),
                Expanded(
                  child: Text(
                    'Wi-Fi code for iPhones: open the Camera app and point it here.',
                    style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _esc(String s) => s.replaceAllMapped(RegExp(r'([\;,:"])'), (m) => '\\${m[1]}');
}

class _NowPlaying extends ConsumerWidget {
  const _NowPlaying({required this.source, required this.speakers, required this.busy});

  final String source;
  final int speakers;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GPSection(
      header: 'Now playing',
      children: [
        GPRow(
          leading: const GPIconTile(CupertinoIcons.waveform),
          title: source,
          subtitle: speakers == 0 ? 'Waiting for speakers' : 'On $speakers ${speakers == 1 ? 'speaker' : 'speakers'}',
          trailing: busy
              ? const CupertinoActivityIndicator()
              : CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(GPSize.minTap, GPSize.minTap),
                  onPressed: ref.read(sessionProvider.notifier).stopSource,
                  child: Semantics(
                    label: 'Stop',
                    button: true,
                    child: Icon(CupertinoIcons.stop_fill, color: GPColors.of(context, GPColors.ink)),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Sources extends ConsumerWidget {
  const _Sources({required this.session, required this.playing});

  final SessionState session;
  final bool playing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(sessionProvider.notifier);
    final busy = session.pending == SessionAction.source;
    final caps = ref.watch(androidCapsProvider).value ?? AndroidCapabilities.none;

    Widget? mark(SourceKind kind) {
      if (busy) return null;
      final active = session.source == kind && (playing || kind == SourceKind.captureFull || kind == SourceKind.captureBasic);
      return active ? Icon(CupertinoIcons.checkmark_alt, color: GPColors.of(context, GPColors.ink)) : null;
    }

    Future<void> pickFile() async {
      final files = await FilePicker.pickFiles(type: FileType.audio);
      if (files.isEmpty) return;
      final path = files.first.path;
      if (path == null) {
        ref.read(alertsProvider.notifier).error('That file isn’t on this phone. Download it first.');
        return;
      }
      await n.playFile(path);
    }

    Future<void> full() async {
      final r = await n.playCapture(CaptureMode.output);
      if (r == CaptureStart.needsSetup && context.mounted) await context.push(Routes.settingsCapture);
    }

    return GPSection(
      header: 'Play',
      footer: AndroidNative.available
          ? 'Full sharing plays anything, including Spotify and Chrome, and needs a one-time Shizuku setup. Basic sharing works with apps that allow capture.'
          : 'Sync Test clicks on every beat: phones in sync sound like a single click.',
      children: [
        GPRow(
          leading: const GPIconTile(CupertinoIcons.metronome),
          title: 'Sync Test',
          subtitle: 'A click on every beat',
          trailing: mark(SourceKind.clicks),
          chevron: false,
          onTap: busy ? null : n.playClicks,
        ),
        GPRow(
          leading: const GPIconTile(CupertinoIcons.music_note_2),
          title: 'Music File',
          subtitle: 'MP3, AAC, FLAC, WAV or OGG on this phone',
          trailing: mark(SourceKind.file),
          chevron: false,
          onTap: busy ? null : pickFile,
        ),
        if (AndroidNative.available) ...[
          GPRow(
            leading: const GPIconTile(CupertinoIcons.antenna_radiowaves_left_right),
            title: 'Everything This Phone Plays',
            subtitle: caps.fullCaptureReady ? 'Full sharing · ready' : 'Full sharing · needs setup',
            trailing: mark(SourceKind.captureFull),
            chevron: !caps.fullCaptureReady,
            onTap: busy ? null : full,
          ),
          GPRow(
            leading: const GPIconTile(CupertinoIcons.square_on_square),
            title: 'Apps That Allow Capture',
            subtitle: 'Basic sharing · YouTube, YouTube Music, Apple Music…',
            trailing: mark(SourceKind.captureBasic),
            chevron: false,
            onTap: busy ? null : () => n.playCapture(CaptureMode.playback),
          ),
        ],
        if (busy) const GPCellContent(child: Center(child: CupertinoActivityIndicator())),
      ],
    );
  }
}

class _BufferSection extends ConsumerWidget {
  const _BufferSection({required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(sessionProvider.notifier);
    return GPSection(
      header: 'Buffer',
      footer: 'How far behind the phone’s own audio the speakers play. Raise it if speakers drop out; it applies the next time sharing starts.',
      children: [
        GPSliderCell(
          label: 'Buffer',
          value: ms.toDouble(),
          min: 120,
          max: 1000,
          step: 20,
          format: (v) => '${v.round()} ms',
          onChanged: (v) => n.setPlayoutDelay(v.round()),
          onChangeEnd: (v) => unawaited(n.applyPlayoutDelay(v.round())),
        ),
      ],
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({required this.peer});

  final PeerStatus peer;

  @override
  Widget build(BuildContext context) {
    final q = peerQuality(peer);
    return GPRow(
      leading: GPIconTile(
        peer.platform == 'ios' ? CupertinoIcons.device_phone_portrait : CupertinoIcons.speaker_2_fill,
      ),
      title: peer.name,
      subtitle: peer.connected ? linkLabel(peer.path, peer.rttMs) : 'Disconnected',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GPBadge(q.label, tone: q.tone),
          const SizedBox(width: GPSpace.xs),
          const CupertinoListTileChevron(),
        ],
      ),
      onTap: () => context.push(Routes.hostSpeaker(peer.id)),
    );
  }
}
