import 'dart:async';

import 'package:app_core/src/alerts.dart';
import 'package:app_core/src/android_caps.dart';
import 'package:app_core/src/engine.dart';
import 'package:app_core/src/platform/android_native.dart';
import 'package:app_core/src/platform/ios_native.dart';
import 'package:app_core/src/routes.dart';
import 'package:app_core/src/session_memory.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart' as rust;
import 'package:wakelock_plus/wakelock_plus.dart';

enum SourceKind { none, clicks, file, captureFull, captureBasic }

enum SessionAction { hosting, joining, leaving, source, hotspot, tuning }

class SessionState {
  const SessionState({this.pending, this.source = SourceKind.none, this.hotspot, this.playoutDelayMs = 300, this.lastTune});

  /// The action in flight (its button shows a spinner).
  final SessionAction? pending;

  /// What this phone last started playing as host.
  final SourceKind source;
  final HotspotInfo? hotspot;

  /// Capture buffer for the next capture start.
  final int playoutDelayMs;

  /// What the last tuning run found (this session).
  final rust.TuneReport? lastTune;

  bool get capturing => source == SourceKind.captureFull || source == SourceKind.captureBasic;

  SessionState copyWith({
    SessionAction? pending,
    bool clearPending = false,
    SourceKind? source,
    HotspotInfo? hotspot,
    bool clearHotspot = false,
    int? playoutDelayMs,
    rust.TuneReport? lastTune,
    bool clearLastTune = false,
  }) => SessionState(
    pending: clearPending ? null : (pending ?? this.pending),
    source: source ?? this.source,
    hotspot: clearHotspot ? null : (hotspot ?? this.hotspot),
    playoutDelayMs: playoutDelayMs ?? this.playoutDelayMs,
    lastTune: clearLastTune ? null : (lastTune ?? this.lastTune),
  );
}

/// Why full capture cannot start yet (the setup screen walks through these).
enum CaptureBlocker { oldAndroid, noShizuku, shizukuStopped, noPermission }

/// A refusal with a message meant for the person.
class SessionError implements Exception {
  const SessionError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Outcome of starting a capture.
enum CaptureStart { started, failed, needsSetup }

/// Every session action. Screens call these and navigate on the returned success flag; errors
/// become alerts here, so screens never catch.
final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  bool _hostLocalBeforeCapture = true;
  bool _draggingDelay = false;

  @override
  SessionState build() {
    if (AndroidNative.available) {
      final sub = AndroidNative.events.listen(_onAndroidEvent);
      ref.onDispose(sub.cancel);
    }
    ref.listen(engineStatusProvider, (_, next) {
      final s = next.value;
      if (s == null) return;
      unawaited(_remember(s));
      // the engine raises the live buffer by itself when speakers lose audio: follow it
      if (s.role == 'host' && !_draggingDelay && s.playoutDelayMs != 0 && s.playoutDelayMs != state.playoutDelayMs) {
        state = state.copyWith(playoutDelayMs: s.playoutDelayMs);
      }
    });
    return const SessionState();
  }

  Alerts get _alerts => ref.read(alertsProvider.notifier);
  SessionMemory get _memory => ref.read(sessionMemoryProvider);

  /// Keeps the session memory current: the host's newest ticket (guest), every speaker's
  /// timing and this phone's own (host).
  Future<void> _remember(rust.EngineStatus s) async {
    if (s.role == 'guest') {
      final t = s.ticket;
      if (t != null && s.state == 'connected') await _memory.updateTicket(t, s.hostName);
    } else if (s.role == 'host' && s.state == 'hosting') {
      await _memory.saveTimings([
        for (final p in s.peers)
          if (p.tuned || p.delayMs != 0) (id: p.id, delayMs: p.delayMs, tuned: p.tuned),
      ]);
      await _memory.saveSelfDelay(s.local.delayMs, tuned: s.local.tuned);
    }
  }

  void _onAndroidEvent(AndroidEvent e) {
    switch (e.type) {
      case 'captureStopped':
        if (state.capturing) {
          state = state.copyWith(source: SourceKind.none);
          unawaited(_restoreHostLocal());
          _alerts.show('Sharing stopped: ${e.data['reason'] ?? 'unknown reason'}', tone: GPTone.warn);
        }
      case 'hotspotStopped':
        state = state.copyWith(clearHotspot: true);
        unawaited(rust.setHostWifi());
        _alerts.show('The hotspot stopped', tone: GPTone.warn);
      case 'wifiLost':
        _alerts.show('Lost the host’s Wi-Fi', tone: GPTone.warn);
    }
  }

  // ------------------------------------------------------------------ session

  Future<bool> host() => _run(SessionAction.hosting, () async {
    await rust.startHost();
    // phones this host tuned before get their timing back as soon as they join
    await rust.setKnownTimings(timings: _memory.timings);
    final self = _memory.selfDelay;
    await rust.setHostDelayMs(ms: self.ms, tuned: self.tuned);
    await _memory.rememberHost();
    state = state.copyWith(source: SourceKind.none, clearLastTune: true);
    await _keepAlive(on: true, text: 'Hosting a Group Play session');
    unawaited(GPHaptics.success());
  });

  /// Joins [ticket]. When it names a hotspot, [wifiHandled] says the caller already joined it.
  Future<bool> join(String ticket, {bool wifiHandled = false}) => _run(SessionAction.joining, () async {
    final info = rust.parseTicket(ticket: ticket);
    final ssid = info.wifiSsid;
    if (!wifiHandled && ssid != null && ssid.isNotEmpty) {
      await joinWifi(ssid, info.wifiPassphrase ?? '');
    }
    await rust.join(ticket: ticket, wait: false);
    await _memory.rememberGuest(ticket, info.hostName);
    await _keepAlive(on: true, text: 'Playing with ${info.hostName}');
    unawaited(GPHaptics.success());
  });

  /// At launch: picks up the session this phone was in (hosting again, or rejoining the host,
  /// waiting for it if it is not up yet). Returns where to go, or null to stay home.
  Future<String?> resume() async {
    final s = _memory.session;
    if (s == null || ref.read(sessionRoleProvider) != SessionRole.idle) return null;
    if (s.isHost) return await host() ? Routes.host : null;
    final ok = await _run(SessionAction.joining, () async {
      await rust.join(ticket: s.ticket!, wait: true);
      await _keepAlive(on: true, text: 'Playing with ${s.hostName}');
    });
    return ok ? Routes.speaker : null;
  }

  /// Tries to join the host's hotspot. False = the person has to do it in Settings.
  Future<bool> joinWifi(String ssid, String passphrase) async {
    try {
      if (AndroidNative.available) return await AndroidNative.joinWifi(ssid, passphrase);
      if (IosNative.available) return await IosNative.joinWifi(ssid, passphrase);
    } on Object catch (e) {
      ref.read(logsProvider.notifier).add('  app joinWifi: ${describeError(e)}');
    }
    return false;
  }

  Future<bool> leave() => _run(SessionAction.leaving, () async {
    await _stopCapture();
    if (state.hotspot != null) {
      await _quietly(AndroidNative.stopLocalHotspot);
    }
    await rust.leave();
    await _memory.forget();
    state = state.copyWith(source: SourceKind.none, clearHotspot: true, clearLastTune: true);
    await _keepAlive(on: false, text: '');
    if (AndroidNative.available) await _quietly(AndroidNative.leaveWifi);
  });

  // ------------------------------------------------------------------ host sources

  Future<bool> playClicks() => _run(SessionAction.source, () async {
    await _stopCapture();
    await rust.playClicks(bpm: 120);
    state = state.copyWith(source: SourceKind.clicks);
  });

  Future<bool> playFile(String path) => _run(SessionAction.source, () async {
    await _stopCapture();
    await rust.playFile(path: path);
    state = state.copyWith(source: SourceKind.file);
  });

  /// What stands between this phone and full capture right now (null = ready).
  Future<CaptureBlocker?> fullCaptureBlocker() async {
    final caps = await ref.read(androidCapsProvider.notifier).refresh();
    if (!caps.outputCaptureSupported) return CaptureBlocker.oldAndroid;
    if (!caps.shizukuInstalled) return CaptureBlocker.noShizuku;
    if (!caps.shizukuRunning) return CaptureBlocker.shizukuStopped;
    if (!caps.shizukuPermission) return CaptureBlocker.noPermission;
    return null;
  }

  /// Shares what this phone plays. Full = everything (Shizuku); basic = apps that allow it.
  /// `needsSetup`: full capture is not ready (the caller opens the setup guide).
  Future<CaptureStart> playCapture(CaptureMode mode) async {
    if (mode == CaptureMode.output && await fullCaptureBlocker() != null) return CaptureStart.needsSetup;
    final ok = await _startCapture(mode);
    return ok ? CaptureStart.started : CaptureStart.failed;
  }

  Future<bool> _startCapture(CaptureMode mode) => _run(SessionAction.source, () => _startCaptureNow(mode));

  Future<void> _startCaptureNow(CaptureMode mode) async {
    await _stopCapture();
    if (mode == CaptureMode.playback) {
      final p = await AndroidNative.requestPermissions(['audio']);
      if (p['audio'] != true) throw const SessionError('Basic sharing needs the audio recording permission.');
    }
    final local = ref.read(engineStatusProvider).value?.local.enabled ?? true;
    _hostLocalBeforeCapture = local;
    if (mode == CaptureMode.output) {
      // Full sharing records everything sent to the default output. This phone keeps
      // playing the synced copy, routed straight to its speaker, so it stays in step with
      // the others instead of going quiet.
      await rust.setHostExplicitRoute(enabled: true);
    } else {
      // Basic sharing: the app still plays here directly; a synced copy would double it.
      await rust.setHostLocalPlayback(enabled: false);
    }
    await rust.setPlayoutDelayMs(ms: state.playoutDelayMs);
    final h = await AndroidNative.startCapture(mode);
    final label = mode == CaptureMode.output ? 'This phone’s audio' : 'This phone’s audio (basic)';
    await rust.playFd(fd: h.fd, sampleRate: h.sampleRate, channels: h.channels, label: label);
    state = state.copyWith(source: mode == CaptureMode.output ? SourceKind.captureFull : SourceKind.captureBasic);
    unawaited(GPHaptics.success());
  }

  Future<bool> stopSource() => _run(SessionAction.source, () async {
    await _stopCapture();
    await rust.stopSource();
    state = state.copyWith(source: SourceKind.none);
  });

  Future<void> _stopCapture() async {
    if (!state.capturing) return;
    await _quietly(AndroidNative.stopCapture);
    await _restoreHostLocal();
    state = state.copyWith(source: SourceKind.none);
  }

  Future<void> _restoreHostLocal() async {
    await _quietly(() => rust.setHostExplicitRoute(enabled: false));
    await _quietly(() => rust.setHostLocalPlayback(enabled: _hostLocalBeforeCapture));
  }

  Future<void> setHostLocal(bool on) async {
    if (state.source == SourceKind.captureBasic && on) {
      _alerts.show('With basic sharing the app already plays here; a second copy would echo.');
      return;
    }
    await rust.setHostLocalPlayback(enabled: on);
  }

  // ------------------------------------------------------------------ tuning

  /// Tunes every speaker by ear: the phones chirp in turn while this phone listens, then
  /// each one gets the delay that lines it up. Sharing pauses for those seconds and resumes;
  /// a sync test restarts; a music file stops (tap it again).
  Future<bool> tune() => _run(SessionAction.tuning, () async {
        final before = state.source;
        if (AndroidNative.available) {
          final p = await AndroidNative.requestPermissions(['audio']);
          if (p['audio'] != true) throw const SessionError('Tuning listens with the microphone. Allow it to tune.');
        }
        // full sharing sends this phone's sound into the recording; pause it while we listen
        await _stopCapture();
        rust.TuneReport? report;
        try {
          final mic = AndroidNative.available ? await AndroidNative.startMic() : await IosNative.startMic();
          try {
            // let the audio route settle (iOS switches the session to play-and-record)
            await Future<void>.delayed(const Duration(milliseconds: 400));
            report = await rust.tuneSpeakers(micFd: mic.fd, micRate: mic.sampleRate, micChannels: mic.channels);
          } finally {
            await _quietly(AndroidNative.available ? AndroidNative.stopMic : IosNative.stopMic);
          }
        } finally {
          // whatever happened, what was playing comes back
          state = state.copyWith(source: SourceKind.none, lastTune: report);
          await _restore(before);
        }
        final missed = report.devices.where((d) => !d.heard).map((d) => d.name).toList();
        if (missed.isEmpty) {
          unawaited(GPHaptics.success());
          _alerts.show('Tuned. Every speaker is lined up.', tone: GPTone.good);
        } else {
          _alerts.show('Couldn’t hear ${missed.join(', ')}. Bring it closer, turn it up, and tune again.', tone: GPTone.warn);
        }
      });

  /// Restarts what played before tuning: sharing and the sync test come back; a music file
  /// would start over, so it stays stopped (tap it again).
  Future<void> _restore(SourceKind before) async {
    try {
      switch (before) {
        case SourceKind.captureFull:
          await _startCaptureNow(CaptureMode.output);
        case SourceKind.clicks:
          await rust.playClicks(bpm: 120);
          state = state.copyWith(source: SourceKind.clicks);
        case SourceKind.captureBasic:
          _alerts.show('Tap Allowed Apps to share again (Android asks each time).');
        case SourceKind.file:
          _alerts.show('Tap Music File to play it again.');
        case SourceKind.none:
          break;
      }
    } on Object catch (e) {
      _alerts.error('Sharing didn’t restart after tuning: ${describeError(e)}');
    }
  }

  /// The host's fine adjustment of its own timing.
  Future<void> setHostDelay(double ms) => _quietly(() => rust.setHostDelayMs(ms: ms));

  void setPlayoutDelay(int ms) {
    _draggingDelay = true;
    state = state.copyWith(playoutDelayMs: ms);
  }

  Future<void> applyPlayoutDelay(int ms) async {
    state = state.copyWith(playoutDelayMs: ms);
    await _quietly(() => rust.setPlayoutDelayMs(ms: ms));
    _draggingDelay = false;
  }

  Future<bool> startHotspot() => _run(SessionAction.hotspot, () async {
    final p = await AndroidNative.requestPermissions(['nearbyWifi', 'location']);
    if (p.values.every((v) => !v)) throw const SessionError('A hotspot needs the Nearby Wi-Fi permission.');
    final h = await AndroidNative.startLocalHotspot();
    await rust.setHostWifi(ssid: h.ssid, passphrase: h.passphrase);
    state = state.copyWith(hotspot: h);
  });

  Future<bool> stopHotspot() => _run(SessionAction.hotspot, () async {
    await AndroidNative.stopLocalHotspot();
    await rust.setHostWifi();
    state = state.copyWith(clearHotspot: true);
  });

  Future<void> setPeerDelay(String id, double ms) => rust.setPeerDelayMs(peerId: id, ms: ms);
  Future<void> setPeerVolume(String id, double v) => rust.setPeerVolume(peerId: id, volume: v);

  // ------------------------------------------------------------------ helpers

  Future<void> _keepAlive({required bool on, required String text}) async {
    await _quietly(on ? WakelockPlus.enable : WakelockPlus.disable);
    if (!AndroidNative.available) return;
    if (on) {
      await _quietly(() => AndroidNative.requestPermissions(['notifications']));
      await _quietly(() => AndroidNative.startSessionService(title: 'Group Play', text: text));
    } else {
      await _quietly(AndroidNative.stopSessionService);
    }
  }

  Future<void> _quietly(Future<void> Function() f) async {
    try {
      await f();
    } on Object catch (e) {
      ref.read(logsProvider.notifier).add('  app ${describeError(e)}');
    }
  }

  Future<bool> _run(SessionAction action, Future<void> Function() f) async {
    if (state.pending != null) return false;
    state = state.copyWith(pending: action);
    try {
      await f();
      return true;
    } on Object catch (e) {
      final msg = describeError(e);
      ref.read(logsProvider.notifier).add('  app error: $msg');
      _alerts.error(msg);
      return false;
    } finally {
      if (ref.mounted) state = state.copyWith(clearPending: true);
    }
  }
}
