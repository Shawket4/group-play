import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A remote speaker's sliders show what that speaker last reported (about once a second).
/// While a finger is on a slider, and briefly after, the slider shows this draft instead so it
/// does not jump back.
final sliderDraftsProvider = NotifierProvider<SliderDrafts, Map<String, double>>(SliderDrafts.new);

class SliderDrafts extends Notifier<Map<String, double>> {
  final Map<String, Timer> _expiry = {};

  @override
  Map<String, double> build() {
    ref.onDispose(() {
      for (final t in _expiry.values) {
        t.cancel();
      }
    });
    return const {};
  }

  void set(String key, double v) {
    _expiry.remove(key)?.cancel();
    state = {...state, key: v};
  }

  /// Keep the draft until the speaker's report has caught up.
  void release(String key) {
    _expiry.remove(key)?.cancel();
    _expiry[key] = Timer(const Duration(milliseconds: 2500), () {
      _expiry.remove(key);
      state = {...state}..remove(key);
    });
  }
}
