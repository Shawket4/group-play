import 'dart:async';

import 'package:app_core/src/platform/android_native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this Android phone can capture, and Shizuku's state. `none` elsewhere.
final androidCapsProvider = AsyncNotifierProvider<AndroidCaps, AndroidCapabilities>(AndroidCaps.new);

class AndroidCaps extends AsyncNotifier<AndroidCapabilities> {
  @override
  Future<AndroidCapabilities> build() async {
    if (!AndroidNative.available) return AndroidCapabilities.none;
    final sub = AndroidNative.events.where((e) => e.type == 'shizuku').listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return await AndroidNative.capabilities();
  }

  Future<AndroidCapabilities> refresh() async {
    if (!AndroidNative.available) return AndroidCapabilities.none;
    final caps = await AndroidNative.capabilities();
    state = AsyncData(caps);
    return caps;
  }

  Future<bool> requestShizukuPermission() async {
    final ok = await AndroidNative.requestShizukuPermission();
    await refresh();
    return ok;
  }
}
