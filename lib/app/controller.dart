// App state: the engine's status stream, device capabilities, and every user action.

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../platform/android_native.dart';
import '../platform/ios_native.dart';
import '../src/rust/api/engine.dart' as rust;

enum SourceKind { none, clicks, file, captureFull, captureBasic }

class TuttiController extends ChangeNotifier {
  rust.EngineStatus? status;
  AndroidCapabilities caps = AndroidCapabilities.none;
  String deviceName = 'Phone';
  final List<String> logs = [];
  HotspotInfo? hotspot;
  SourceKind source = SourceKind.none;
  bool busy = false;

  /// One-shot messages for the UI (snackbars). Cleared by [takeMessage].
  String? _message;

  StreamSubscription<rust.EngineStatus>? _statusSub;
  StreamSubscription<String>? _logSub;
  StreamSubscription<AndroidEvent>? _eventSub;
  SharedPreferences? _prefs;
  bool _hostLocalBeforeCapture = true;

  String get platform => Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : Platform.operatingSystem);
  String get role => status?.role ?? 'idle';
  bool get isHost => role == 'host';
  bool get isGuest => role == 'guest';

  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  void _say(String m) {
    _message = m;
    notifyListeners();
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    deviceName = _prefs!.getString('deviceName') ?? await _defaultName();
    rust.configure(deviceName: deviceName, platform: platform);
    final delay = _prefs!.getDouble('delayMs') ?? 0;
    final volume = _prefs!.getDouble('volume') ?? 1;
    await rust.setDelayMs(ms: delay);
    await rust.setVolume(volume: volume);
    _statusSub = rust.statusStream().listen((s) {
      status = s;
      notifyListeners();
    });
    _logSub = rust.logStream().listen((line) {
      logs.add(line);
      if (logs.length > 400) logs.removeRange(0, logs.length - 400);
    });
    if (AndroidNative.available) {
      _eventSub = AndroidNative.events.listen(_onAndroidEvent);
      await refreshCaps();
    }
    if (IosNative.available) {
      try {
        await IosNative.configureAudio();
      } catch (_) {}
    }
  }

  Future<String> _defaultName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final brand = a.manufacturer.isEmpty ? '' : '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)} ';
        return '$brand${a.model}'.trim();
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return i.name.isNotEmpty ? i.name : i.model;
      }
    } catch (_) {}
    return 'Phone';
  }

  Future<void> setDeviceName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    deviceName = n;
    await _prefs?.setString('deviceName', n);
    rust.configure(deviceName: n, platform: platform);
    notifyListeners();
  }

  Future<void> refreshCaps() async {
    if (!AndroidNative.available) return;
    try {
      caps = await AndroidNative.capabilities();
    } catch (e) {
      _log('capabilities: $e');
    }
    notifyListeners();
  }

  void _onAndroidEvent(AndroidEvent e) {
    switch (e.type) {
      case 'captureStopped':
        if (source == SourceKind.captureFull || source == SourceKind.captureBasic) {
          source = SourceKind.none;
          _restoreHostLocal();
          _say('Capture stopped: ${e.data['reason'] ?? 'unknown reason'}');
        }
      case 'shizuku':
        refreshCaps();
      case 'hotspotStopped':
        hotspot = null;
        rust.setHostWifi();
        _say('Hotspot stopped');
      case 'wifiLost':
        _say('Lost the session Wi-Fi');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- session

  Future<void> host() => _run(() async {
        await rust.startHost();
        source = SourceKind.none;
        await _keepAlive(true, 'Hosting a Tutti session');
      });

  Future<void> join(String ticket) => _run(() async {
        final info = rust.parseTicket(ticket: ticket);
        final ssid = info.wifiSsid;
        if (ssid != null && ssid.isNotEmpty) {
          await joinWifi(ssid, info.wifiPassphrase ?? '');
        }
        await rust.join(ticket: ticket);
        await _keepAlive(true, 'Playing with ${info.hostName}');
      });

  /// Connects to the host only (the caller already handled the ticket's Wi-Fi).
  Future<void> joinTicketOnly(String ticket) => _run(() async {
        final info = rust.parseTicket(ticket: ticket);
        await rust.join(ticket: ticket);
        await _keepAlive(true, 'Playing with ${info.hostName}');
      });

  /// Tries to join the host's hotspot. Returns false when the user has to do it by hand.
  Future<bool> joinWifi(String ssid, String pass) async {
    try {
      if (AndroidNative.available) return await AndroidNative.joinWifi(ssid, pass);
      if (IosNative.available) return await IosNative.joinWifi(ssid, pass);
    } catch (e) {
      _log('joinWifi: $e');
    }
    return false;
  }

  Future<void> leave() => _run(() async {
        await _stopCaptureIfAny();
        if (hotspot != null) {
          try {
            await AndroidNative.stopLocalHotspot();
          } catch (_) {}
          hotspot = null;
        }
        await rust.leave();
        source = SourceKind.none;
        await _keepAlive(false, '');
        if (AndroidNative.available) {
          try {
            await AndroidNative.leaveWifi();
          } catch (_) {}
        }
      });

  Future<void> _keepAlive(bool on, String text) async {
    try {
      on ? await WakelockPlus.enable() : await WakelockPlus.disable();
    } catch (_) {}
    if (!AndroidNative.available) return;
    try {
      if (on) {
        await AndroidNative.requestPermissions(['notifications']);
        await AndroidNative.startSessionService(title: 'Tutti', text: text);
      } else {
        await AndroidNative.stopSessionService();
      }
    } catch (e) {
      _log('session service: $e');
    }
  }

  // ---------------------------------------------------------------- host sources

  Future<void> playClicks() => _run(() async {
        await _stopCaptureIfAny();
        await rust.playClicks(bpm: 120);
        source = SourceKind.clicks;
      });

  Future<void> playFile(String path) => _run(() async {
        await _stopCaptureIfAny();
        await rust.playFile(path: path);
        source = SourceKind.file;
      });

  /// Shares what this phone plays. Full = everything (Shizuku), basic = apps that allow it.
  Future<void> playCapture(CaptureMode mode) => _run(() async {
        await _stopCaptureIfAny();
        await refreshCaps();
        if (mode == CaptureMode.output) {
          if (!caps.outputCaptureSupported) throw 'Full capture needs Android 12 or newer.';
          if (!caps.shizukuInstalled) throw 'Install Shizuku first (see Setup).';
          if (!caps.shizukuRunning) throw 'Start Shizuku first (open Shizuku → Start).';
          if (!caps.shizukuPermission) {
            final ok = await AndroidNative.requestShizukuPermission();
            if (!ok) throw 'Tutti needs Shizuku permission for full capture.';
          }
        } else {
          final p = await AndroidNative.requestPermissions(['audio']);
          if (p['audio'] != true) throw 'Basic capture needs the microphone/recording permission.';
        }
        // The capture includes (output mode) or would echo (basic mode) our own playback, so
        // the host phone does not play the synced copy while capturing.
        final st = status?.local;
        _hostLocalBeforeCapture = st?.enabled ?? true;
        await rust.setHostLocalPlayback(enabled: false);
        final h = await AndroidNative.startCapture(mode);
        await rust.playFd(
          fd: h.fd,
          sampleRate: h.sampleRate,
          channels: h.channels,
          label: mode == CaptureMode.output ? "$deviceName's audio" : "$deviceName's audio (basic)",
        );
        source = mode == CaptureMode.output ? SourceKind.captureFull : SourceKind.captureBasic;
        await refreshCaps();
      });

  Future<void> stopSource() => _run(() async {
        await _stopCaptureIfAny();
        await rust.stopSource();
        source = SourceKind.none;
      });

  Future<void> _stopCaptureIfAny() async {
    if (source == SourceKind.captureFull || source == SourceKind.captureBasic) {
      try {
        await AndroidNative.stopCapture();
      } catch (e) {
        _log('stopCapture: $e');
      }
      await _restoreHostLocal();
    }
  }

  Future<void> _restoreHostLocal() async {
    try {
      await rust.setHostLocalPlayback(enabled: _hostLocalBeforeCapture);
    } catch (_) {}
  }

  bool get capturing => source == SourceKind.captureFull || source == SourceKind.captureBasic;

  Future<void> setHostLocal(bool on) async {
    if (capturing && on) {
      _say('This phone cannot play along while it shares its own audio.');
      return;
    }
    await rust.setHostLocalPlayback(enabled: on);
  }

  Future<void> startHotspot() => _run(() async {
        final p = await AndroidNative.requestPermissions(['nearbyWifi', 'location']);
        if (p.values.every((v) => !v)) throw 'Tutti needs the nearby Wi-Fi permission for a hotspot.';
        final h = await AndroidNative.startLocalHotspot();
        hotspot = h;
        await rust.setHostWifi(ssid: h.ssid, passphrase: h.passphrase);
      });

  Future<void> stopHotspot() => _run(() async {
        await AndroidNative.stopLocalHotspot();
        hotspot = null;
        await rust.setHostWifi();
      });

  Future<void> setPlayoutDelay(int ms) async {
    try {
      await rust.setPlayoutDelayMs(ms: ms);
    } catch (e) {
      _log('playout delay: $e');
    }
  }

  // ---------------------------------------------------------------- calibration

  Future<void> setDelay(double ms) async {
    await rust.setDelayMs(ms: ms);
    await _prefs?.setDouble('delayMs', ms);
  }

  Future<void> setVolume(double v) async {
    await rust.setVolume(volume: v);
    await _prefs?.setDouble('volume', v);
  }

  Future<void> setPeerDelay(String id, double ms) => rust.setPeerDelayMs(peerId: id, ms: ms);
  Future<void> setPeerVolume(String id, double v) => rust.setPeerVolume(peerId: id, volume: v);

  // ---------------------------------------------------------------- helpers

  Future<void> _run(Future<void> Function() f) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await f();
    } catch (e) {
      final msg = e is String ? e : _clean(e.toString());
      _log('error: $msg');
      _message = msg;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  static String _clean(String s) {
    // anyhow errors arrive as "AnyhowException(...)"; platform errors as "PlatformException(code, msg, ...)"
    final any = RegExp(r'AnyhowException\((.*)\)', dotAll: true).firstMatch(s);
    if (any != null) return any.group(1)!.split('\n').first;
    final pe = RegExp(r'PlatformException\([^,]*, ([^,]*)').firstMatch(s);
    if (pe != null) return pe.group(1)!;
    return s;
  }

  void _log(String s) {
    logs.add('  app $s');
    debugPrint('tutti: $s');
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _logSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }
}
