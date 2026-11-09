// MethodChannel "tutti/ios" (ios/Runner/AppDelegate.swift).

import 'dart:io';

import 'package:flutter/services.dart';

class IosNative {
  IosNative._();

  static const _ch = MethodChannel('tutti/ios');

  static bool get available => Platform.isIOS;

  static Future<Map<dynamic, dynamic>> configureAudio() async =>
      await _ch.invokeMethod<Map<dynamic, dynamic>>('configureAudio') ?? const {};

  static Future<Map<dynamic, dynamic>> audioInfo() async =>
      await _ch.invokeMethod<Map<dynamic, dynamic>>('audioInfo') ?? const {};

  /// Joins a Wi-Fi network. Needs the Hotspot Configuration entitlement; throws without it.
  static Future<bool> joinWifi(String ssid, String passphrase) async =>
      await _ch.invokeMethod<bool>('joinWifi', {'ssid': ssid, 'passphrase': passphrase}) ?? false;

  static Future<void> openSettings() => _ch.invokeMethod<void>('openSettings');
}
