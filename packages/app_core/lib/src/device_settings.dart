import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden at boot with the loaded preferences.
final prefsProvider = Provider<SharedPreferences>(
  (_) => throw StateError('prefsProvider read before boot override'),
);

/// This phone's identity and calibration. Survive restarts; pushed into the engine.
class DeviceSettingsState {
  const DeviceSettingsState({required this.name, required this.delayMs, required this.volume});

  final String name;

  /// Positive = this phone plays later (use when it sounds early).
  final double delayMs;
  final double volume;

  DeviceSettingsState copyWith({String? name, double? delayMs, double? volume}) => DeviceSettingsState(
        name: name ?? this.name,
        delayMs: delayMs ?? this.delayMs,
        volume: volume ?? this.volume,
      );
}

final deviceSettingsProvider = NotifierProvider<DeviceSettings, DeviceSettingsState>(DeviceSettings.new);

class DeviceSettings extends Notifier<DeviceSettingsState> {
  static const _kName = 'deviceName';
  static const _kDelay = 'delayMs';
  static const _kVolume = 'volume';

  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  DeviceSettingsState build() {
    final p = ref.watch(prefsProvider);
    return DeviceSettingsState(
      name: p.getString(_kName) ?? 'Phone',
      delayMs: p.getDouble(_kDelay) ?? 0,
      volume: p.getDouble(_kVolume) ?? 1,
    );
  }

  /// Sends the stored values to the engine (at boot).
  Future<void> applyToEngine() async {
    configure(deviceName: state.name, platform: platformName);
    await setDelayMs(ms: state.delayMs);
    await setVolume(volume: state.volume);
  }

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    state = state.copyWith(name: n);
    configure(deviceName: n, platform: platformName);
    await _prefs.setString(_kName, n);
  }

  Future<void> setDelay(double ms) async {
    state = state.copyWith(delayMs: ms);
    await setDelayMs(ms: ms);
    await _prefs.setDouble(_kDelay, ms);
  }

  Future<void> setVolumeLevel(double v) async {
    state = state.copyWith(volume: v);
    await setVolume(volume: v);
    await _prefs.setDouble(_kVolume, v);
  }

  /// A friendly default name from the device model, used until the person renames it.
  static Future<String> defaultName(SharedPreferences prefs) async {
    final saved = prefs.getString(_kName);
    if (saved != null && saved.isNotEmpty) return saved;
    var name = 'Phone';
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final brand = a.manufacturer.isEmpty ? '' : '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)} ';
        name = '$brand${a.model}'.trim();
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        name = i.name.isNotEmpty ? i.name : i.model;
      }
    } on Exception {
      // keep the generic name
    }
    await prefs.setString(_kName, name);
    return name;
  }
}

String get platformName => Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : Platform.operatingSystem);
