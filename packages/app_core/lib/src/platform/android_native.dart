// Typed wrapper over the Kotlin side (MethodChannel "group_play/android"). Every call is
// Android-only; on other platforms the getters report "unsupported" and calls throw.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidCapabilities {
  const AndroidCapabilities({
    required this.sdkInt,
    required this.manufacturer,
    required this.model,
    required this.playbackCaptureSupported,
    required this.outputCaptureSupported,
    required this.shizukuInstalled,
    required this.shizukuRunning,
    required this.shizukuPermission,
    required this.shizukuUid,
    required this.recordAudioGranted,
    required this.notificationsGranted,
  });

  factory AndroidCapabilities.fromMap(Map<dynamic, dynamic> m) => AndroidCapabilities(
        sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
        manufacturer: m['manufacturer'] as String? ?? '',
        model: m['model'] as String? ?? '',
        playbackCaptureSupported: m['playbackCaptureSupported'] == true,
        outputCaptureSupported: m['outputCaptureSupported'] == true,
        shizukuInstalled: m['shizukuInstalled'] == true,
        shizukuRunning: m['shizukuRunning'] == true,
        shizukuPermission: m['shizukuPermission'] == true,
        shizukuUid: (m['shizukuUid'] as num?)?.toInt(),
        recordAudioGranted: m['recordAudioGranted'] == true,
        notificationsGranted: m['notificationsGranted'] == true,
      );

  static const none = AndroidCapabilities(
    sdkInt: 0,
    manufacturer: '',
    model: '',
    playbackCaptureSupported: false,
    outputCaptureSupported: false,
    shizukuInstalled: false,
    shizukuRunning: false,
    shizukuPermission: false,
    shizukuUid: null,
    recordAudioGranted: false,
    notificationsGranted: false,
  );

  final int sdkInt;
  final String manufacturer;
  final String model;

  /// Android 10+: MediaProjection playback capture (apps may opt out).
  final bool playbackCaptureSupported;

  /// Android 12+: whole-output capture through Shizuku (REMOTE_SUBMIX as shell).
  final bool outputCaptureSupported;
  final bool shizukuInstalled;
  final bool shizukuRunning;
  final bool shizukuPermission;

  /// 0 = Shizuku runs as root, 2000 = as adb shell.
  final int? shizukuUid;
  final bool recordAudioGranted;
  final bool notificationsGranted;

  /// Full capture can start right now.
  bool get fullCaptureReady => outputCaptureSupported && shizukuRunning && shizukuPermission;

}

/// "output" = everything the phone plays (Shizuku). "playback" = apps that allow capture.
enum CaptureMode { output, playback }

class CaptureHandle {
  const CaptureHandle({required this.fd, required this.sampleRate, required this.channels});

  /// Read end of a pipe with interleaved s16le PCM. Hand it to the engine, which owns it.
  final int fd;
  final int sampleRate;
  final int channels;
}

class HotspotInfo {
  const HotspotInfo({required this.ssid, required this.passphrase, required this.ips});
  final String ssid;
  final String passphrase;
  final List<String> ips;
}

/// Events from the Kotlin side.
class AndroidEvent {
  const AndroidEvent(this.type, this.data);
  final String type; // captureStopped | shizuku | hotspotStopped | wifiLost
  final Map<dynamic, dynamic> data;
}

class AndroidNative {
  AndroidNative._();

  static const _ch = MethodChannel('group_play/android');
  static const _events = EventChannel('group_play/android/events');

  static bool get available => Platform.isAndroid;

  static Stream<AndroidEvent>? _eventStream;

  static Stream<AndroidEvent> get events {
    if (!available) return const Stream.empty();
    return _eventStream ??= _events.receiveBroadcastStream().map((e) {
      final m = e as Map<dynamic, dynamic>;
      return AndroidEvent(m['type'] as String? ?? '', m);
    }).asBroadcastStream();
  }

  static Future<AndroidCapabilities> capabilities() async {
    if (!available) return AndroidCapabilities.none;
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('capabilities');
    return AndroidCapabilities.fromMap(m ?? const {});
  }

  static Future<bool> requestShizukuPermission() async =>
      await _ch.invokeMethod<bool>('requestShizukuPermission') ?? false;

  /// Keys: audio, notifications, nearbyWifi, location.
  static Future<Map<String, bool>> requestPermissions(List<String> list) async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('requestPermissions', {'list': list});
    return (m ?? const {}).map((k, v) => MapEntry(k as String, v == true));
  }

  static Future<CaptureHandle> startCapture(CaptureMode mode, {int sampleRate = 48000, int channels = 2}) async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('startCapture', {
      'mode': mode.name,
      'sampleRate': sampleRate,
      'channels': channels,
    });
    if (m == null) throw PlatformException(code: 'capture', message: 'no capture handle');
    return CaptureHandle(
      fd: (m['fd'] as num).toInt(),
      sampleRate: (m['sampleRate'] as num?)?.toInt() ?? sampleRate,
      channels: (m['channels'] as num?)?.toInt() ?? channels,
    );
  }

  static Future<void> stopCapture() => _ch.invokeMethod<void>('stopCapture');

  static Future<void> startSessionService({required String title, required String text}) =>
      _ch.invokeMethod<void>('startSessionService', {'title': title, 'text': text});

  static Future<void> stopSessionService() => _ch.invokeMethod<void>('stopSessionService');

  static Future<HotspotInfo> startLocalHotspot() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('startLocalHotspot');
    if (m == null) throw PlatformException(code: 'hotspot', message: 'no hotspot info');
    return HotspotInfo(
      ssid: m['ssid'] as String? ?? '',
      passphrase: m['passphrase'] as String? ?? '',
      ips: ((m['ips'] as List?) ?? const []).cast<String>(),
    );
  }

  static Future<void> stopLocalHotspot() => _ch.invokeMethod<void>('stopLocalHotspot');

  static Future<bool> joinWifi(String ssid, String passphrase) async =>
      await _ch.invokeMethod<bool>('joinWifi', {'ssid': ssid, 'passphrase': passphrase}) ?? false;

  static Future<void> leaveWifi() => _ch.invokeMethod<void>('leaveWifi');

  static Future<void> openShizukuApp() => _ch.invokeMethod<void>('openShizukuApp');

  static Future<void> openShizukuDownload() => _ch.invokeMethod<void>('openShizukuDownload');
}
