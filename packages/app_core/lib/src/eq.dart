import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_core/src/device_settings.dart';
import 'package:app_core/src/engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart' as rust;

/// Band centres, Hz (the engine's eq::BAND_HZ).
const eqBandHz = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const eqMaxBandDb = 12.0;
const eqMaxBoostDb = 12.0;

/// Presets, dB per band (32 Hz … 16 kHz).
const eqPresets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass Boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Vocal': [-2, -2, -1, 0, 2, 3, 3, 2, 0, -1],
  'Loudness': [5, 4, 2, 0, -1, -1, 0, 2, 4, 5],
  'Treble': [0, 0, 0, 0, 0, 0, 1, 3, 5, 6],
};

/// The host's EQ and boost (eqMac style). Saved on this phone; while hosting, every phone in the
/// session plays through it.
class EqState {
  const EqState({required this.enabled, required this.boostDb, required this.bands});

  factory EqState.fromJson(Object? j) {
    if (j is! Map) return flat;
    final b = (j['bands'] as List?)?.map((v) => (v as num).toDouble().clamp(-eqMaxBandDb, eqMaxBandDb)).toList();
    return EqState(
      enabled: j['enabled'] == true,
      boostDb: ((j['boostDb'] as num?)?.toDouble() ?? 0).clamp(0, eqMaxBoostDb),
      bands: b != null && b.length == eqBandHz.length ? b : flat.bands,
    );
  }

  static const flat = EqState(enabled: false, boostDb: 0, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

  final bool enabled;
  final double boostDb;
  final List<double> bands;

  /// The preset these bands match, if any.
  String? get preset {
    for (final e in eqPresets.entries) {
      if (_same(e.value, bands)) return e.key;
    }
    return null;
  }

  EqState copyWith({bool? enabled, double? boostDb, List<double>? bands}) =>
      EqState(enabled: enabled ?? this.enabled, boostDb: boostDb ?? this.boostDb, bands: bands ?? this.bands);

  Map<String, Object> toJson() => {'enabled': enabled, 'boostDb': boostDb, 'bands': bands};

  static bool _same(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.05) return false;
    }
    return true;
  }
}

final eqProvider = NotifierProvider<EqController, EqState>(EqController.new);

class EqController extends Notifier<EqState> {
  static const _key = 'eq';

  @override
  EqState build() {
    final raw = ref.watch(prefsProvider).getString(_key);
    if (raw == null) return EqState.flat;
    try {
      return EqState.fromJson(jsonDecode(raw));
    } on FormatException {
      return EqState.flat;
    }
  }

  /// Applies [s] at once (cheap: the sliders call this on every move) and, when [save], keeps it.
  Future<void> set(EqState s, {bool save = true}) async {
    state = s;
    await applyToEngine();
    if (save) await ref.read(prefsProvider).setString(_key, jsonEncode(s.toJson()));
  }

  Future<void> setEnabled(bool on) => set(state.copyWith(enabled: on));
  Future<void> setBoost(double db, {bool save = true}) => set(state.copyWith(boostDb: db, enabled: true), save: save);
  Future<void> setPreset(String name) => set(state.copyWith(bands: eqPresets[name], enabled: true));

  Future<void> setBand(int i, double db, {bool save = true}) {
    final bands = [...state.bands]..[i] = db;
    return set(state.copyWith(bands: bands, enabled: true), save: save);
  }

  /// Hands the EQ to the engine while hosting (a speaker gets the host's from the host).
  /// [hosting]: the caller knows a host just started (the role provider lags the engine by a tick).
  Future<void> applyToEngine({bool hosting = false}) async {
    if (!hosting && ref.read(sessionRoleProvider) != SessionRole.host) return;
    try {
      await rust.setEq(eq: rust.EqConfig(enabled: state.enabled, boostDb: state.boostDb, bandsDb: Float64List.fromList(state.bands)));
    } on Object {
      // not hosting any more; the next host() applies it
    }
  }
}
