import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:feature_host/src/invite_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// The host's control room: what plays, who listens, what to play next.
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
    if (status == null || status.role != 'host') {
      return const CupertinoPageScaffold(backgroundColor: GPColors.background, child: Center(child: CupertinoActivityIndicator()));
    }
    final connected = status.peers.where((p) => p.connected).length;
    return GPPage(
      title: 'Hosting',
      previousPageTitle: 'Home',
      trailing: GPBarButton('End', destructive: true, onPressed: () => _end(context, ref)),
      slivers: [
        GPBlock(child: _NowPlaying(status: status, session: session, speakers: connected)),
        GPBlock(child: _Speakers(status: status, capturing: session.capturing)),
        if (status.peers.isEmpty) GPBlock(child: _InviteInline(ticket: status.ticket ?? '')),
        GPBlock(child: _Sources(session: session, playing: status.source != null)),
        if (session.capturing) GPBlock(child: _Buffer(ms: session.playoutDelayMs)),
        if (AndroidNative.available) _Network(hotspot: session.hotspot, busy: session.pending == SessionAction.hotspot),
      ],
    );
  }
}

/// The big card: what plays right now, and the one control that matters (stop).
class _NowPlaying extends ConsumerWidget {
  const _NowPlaying({required this.status, required this.session, required this.speakers});

  final EngineStatus status;
  final SessionState session;
  final int speakers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = status.source;
    final busy = session.pending == SessionAction.source;
    if (source == null) {
      final secondary = GPColors.of(context, GPColors.secondaryLabel);
      return GPCard(
        padding: const EdgeInsets.all(GPSpace.lg),
        child: Row(
          children: [
            Icon(CupertinoIcons.waveform, size: 30, color: GPColors.of(context, GPColors.tertiaryLabel)),
            const SizedBox(width: GPSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Nothing playing', style: GPText.title3),
                  const SizedBox(height: 2),
                  Text('Choose something below. Every speaker starts on the same beat.', style: GPText.footnote.copyWith(color: secondary)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final onInk = GPColors.of(context, GPColors.onInk);
    final kind = switch (session.source) {
      SourceKind.clicks => 'Sync test',
      SourceKind.file => 'Music file',
      SourceKind.captureFull => 'This phone · full sharing',
      SourceKind.captureBasic => 'This phone · basic sharing',
      SourceKind.none => 'Playing',
    };
    return GPCard(
      inverted: true,
      padding: const EdgeInsets.fromLTRB(GPSpace.lg, GPSpace.lg, GPSpace.md, GPSpace.lg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NOW PLAYING', style: GPText.label.copyWith(color: onInk.withValues(alpha: 0.6))),
                const SizedBox(height: GPSpace.xs),
                Text(source, maxLines: 2, overflow: TextOverflow.ellipsis, style: GPText.title3.copyWith(color: onInk)),
                const SizedBox(height: GPSpace.xxs),
                Text(
                  '$kind · ${speakers == 0 ? 'no speakers yet' : 'on $speakers ${speakers == 1 ? 'speaker' : 'speakers'}'}',
                  style: GPText.footnote.copyWith(color: onInk.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          const SizedBox(width: GPSpace.sm),
          GPRoundButton(
            icon: CupertinoIcons.stop_fill,
            label: 'Stop',
            inverted: true,
            busy: busy,
            onPressed: ref.read(sessionProvider.notifier).stopSource,
          ),
        ],
      ),
    );
  }
}

/// Who is listening: this phone, every speaker, and the invite button.
class _Speakers extends ConsumerWidget {
  const _Speakers({required this.status, required this.capturing});

  final EngineStatus status;
  final bool capturing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    final connected = status.peers.where((p) => p.connected).length;
    final local = status.local;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GPSectionLabel(
          'Speakers',
          trailing: Text(
            connected == 0 ? 'none yet' : '$connected connected',
            style: GPText.caption1.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel)),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GPAvatar(
                name: name,
                caption: capturing ? 'Source' : (local.enabled ? 'This phone' : 'Silent'),
                tone: capturing || !local.enabled ? GPTone.neutral : GPTone.good,
                onTap: () => context.push(Routes.hostSpeaker(Routes.localSpeakerId)),
              ),
              for (final p in status.peers)
                GPAvatar(
                  name: p.name,
                  caption: _short(peerQuality(p).label),
                  tone: peerQuality(p).tone,
                  dimmed: !p.connected,
                  onTap: () => context.push(Routes.hostSpeaker(p.id)),
                ),
              GPAvatar(
                name: 'Invite',
                icon: CupertinoIcons.add,
                onTap: () => showInviteSheet(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _short(String label) => label.startsWith('Settling') ? 'Settling' : label;
}

/// Before the first speaker joins, the code is right on the screen.
class _InviteInline extends StatelessWidget {
  const _InviteInline({required this.ticket});

  final String ticket;

  @override
  Widget build(BuildContext context) {
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return GPCard(
      padding: const EdgeInsets.all(GPSpace.lg),
      child: Column(
        children: [
          GPQrCode(data: Routes.joinLink(ticket), size: 200, semanticLabel: 'Join code'),
          const SizedBox(height: GPSpace.md),
          const Text('Invite your first speaker', style: GPText.headline, textAlign: TextAlign.center),
          const SizedBox(height: 2),
          Text(
            'On another phone, open Group Play and tap Join, or point the Camera app here.',
            textAlign: TextAlign.center,
            style: GPText.footnote.copyWith(color: secondary),
          ),
        ],
      ),
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
    bool on(SourceKind k) => session.source == k && (playing || k == SourceKind.captureFull || k == SourceKind.captureBasic);

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

    final tiles = <Widget>[
      GPChoiceTile(
        icon: CupertinoIcons.metronome,
        title: 'Sync Test',
        caption: 'A click on every beat',
        selected: on(SourceKind.clicks),
        onTap: busy ? null : n.playClicks,
      ),
      GPChoiceTile(
        icon: CupertinoIcons.music_note_2,
        title: 'Music File',
        caption: 'MP3, AAC, FLAC, WAV, OGG',
        selected: on(SourceKind.file),
        onTap: busy ? null : pickFile,
      ),
      if (AndroidNative.available) ...[
        GPChoiceTile(
          icon: CupertinoIcons.antenna_radiowaves_left_right,
          title: 'Phone Audio',
          caption: 'Everything, Spotify included',
          badge: caps.fullCaptureReady ? 'Full' : 'Set up',
          selected: on(SourceKind.captureFull),
          busy: busy && session.source != SourceKind.captureFull,
          onTap: busy ? null : full,
        ),
        GPChoiceTile(
          icon: CupertinoIcons.square_on_square,
          title: 'Allowed Apps',
          caption: 'YouTube, Apple Music…',
          badge: 'Basic',
          selected: on(SourceKind.captureBasic),
          onTap: busy ? null : () => n.playCapture(CaptureMode.playback),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GPSectionLabel('Play'),
        for (var i = 0; i < tiles.length; i += 2) ...[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: GPSpace.sm),
                Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox.shrink()),
              ],
            ),
          ),
          if (i + 2 < tiles.length) const SizedBox(height: GPSpace.sm),
        ],
      ],
    );
  }
}

class _Buffer extends ConsumerWidget {
  const _Buffer({required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(sessionProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GPSectionLabel('Delay behind this phone'),
        GPCard(
          padding: EdgeInsets.zero,
          child: GPSliderCell(
            label: 'Buffer',
            value: ms.toDouble(),
            min: 120,
            max: 1000,
            step: 20,
            format: (v) => '${v.round()} ms',
            hint: 'Raise it if speakers drop out. Applies when sharing starts again.',
            onChanged: (v) => n.setPlayoutDelay(v.round()),
            onChangeEnd: (v) => unawaited(n.applyPlayoutDelay(v.round())),
          ),
        ),
      ],
    );
  }
}

class _Network extends ConsumerWidget {
  const _Network({required this.hotspot, required this.busy});

  final HotspotInfo? hotspot;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(sessionProvider.notifier);
    final h = hotspot;
    return GPSection(
      header: 'Network',
      footer: h == null
          ? 'No Wi-Fi where you are? This phone can make a private hotspot; its details go into the join code.'
          : 'Speakers join “${h.ssid}”. The invite sheet has a Wi-Fi code for iPhones.',
      children: [
        GPSwitchRow(
          leading: const GPIconTile(CupertinoIcons.wifi),
          title: 'Hotspot',
          subtitle: h == null ? null : '${h.ssid} · ${h.passphrase}',
          value: h != null,
          onChanged: busy ? null : (v) => v ? n.startHotspot() : n.stopHotspot(),
        ),
      ],
    );
  }
}
