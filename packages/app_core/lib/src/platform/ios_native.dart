// MethodChannel "group_play/ios" (apps/group_play/ios/Runner/AppDelegate.swift).

import 'dart:io';

import 'package:app_core/src/platform/android_native.dart' show CaptureHandle;
import 'package:flutter/services.dart';

class IosNative {
  IosNative._();

  static const _ch = MethodChannel('group_play/ios');

  static bool get available => Platform.isIOS;

  static Future<Map<dynamic, dynamic>> configureAudio() async =>
      await _ch.invokeMethod<Map<dynamic, dynamic>>('configureAudio') ?? const {};

  static Future<Map<dynamic, dynamic>> audioInfo() async => await _ch.invokeMethod<Map<dynamic, dynamic>>('audioInfo') ?? const {};

  /// Joins a Wi-Fi network. Needs the Hotspot Configuration entitlement; throws without it.
  static Future<bool> joinWifi(String ssid, String passphrase) async =>
      await _ch.invokeMethod<bool>('joinWifi', {'ssid': ssid, 'passphrase': passphrase}) ?? false;

  static Future<void> openSettings() => _ch.invokeMethod<void>('openSettings');

  /// Starts the microphone for tuning (asks for permission the first time). The audio session
  /// is play-and-record until [stopMic]. Mono s16le; the engine owns the fd.
  static Future<CaptureHandle> startMic() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('startMic');
    if (m == null) throw PlatformException(code: 'mic', message: 'no microphone handle');
    return CaptureHandle(
      fd: (m['fd'] as num).toInt(),
      sampleRate: (m['sampleRate'] as num).toInt(),
      channels: (m['channels'] as num?)?.toInt() ?? 1,
    );
  }

  static Future<void> stopMic() => _ch.invokeMethod<void>('stopMic');

  /// The lock-screen, Control Center and Dynamic Island player. [active] false clears it.
  static Future<void> setNowPlaying({required bool active, String title = '', String subtitle = '', bool playing = true}) =>
      _ch.invokeMethod<void>('nowPlaying', {'active': active, 'title': title, 'subtitle': subtitle, 'playing': playing});

  /// Play/pause pressed on that player: "play" | "pause" | "toggle".
  static void onRemoteCommand(void Function(String command) handler) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'remoteCommand' && call.arguments is String) handler(call.arguments as String);
    });
  }
}
