import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:rust_bridge/rust_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loads the engine and preferences before the first frame; returns the provider overrides.
Future<List<Override>> boot() async {
  // iOS links the engine statically into rust_bridge.framework: there is no group_play_frb.framework to open.
  await RustLib.init(externalLibrary: Platform.isIOS ? ExternalLibrary.process(iKnowHowToUseIt: true) : null);
  final prefs = await SharedPreferences.getInstance();
  final name = await DeviceSettings.defaultName(prefs);
  configure(deviceName: name, platform: platformName);
  // a fixed identity: this phone keeps its id, so remembered sessions find each other again
  setIdentity(key: await SessionMemory.identityKey(prefs));
  await setVolume(volume: prefs.getDouble('volume') ?? 1);
  if (IosNative.available) {
    try {
      await IosNative.configureAudio();
    } on Object {
      // the engine still plays; the session category is a nicety at this point
    }
  }
  return [prefsProvider.overrideWithValue(prefs)];
}
