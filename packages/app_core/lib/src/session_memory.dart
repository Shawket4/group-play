import 'dart:convert';
import 'dart:math';

import 'package:app_core/src/device_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

/// The session this phone was in when the app last closed.
class RememberedSession {
  const RememberedSession.host() : isHost = true, ticket = null, hostName = null;
  const RememberedSession.guest({required String this.ticket, required String this.hostName}) : isHost = false;

  final bool isHost;

  /// Guest: the host's latest ticket (its id stays the same, so this keeps working).
  final String? ticket;
  final String? hostName;
}

/// What survives a restart so two phones find each other again without a QR code:
/// - this phone's identity key (its id, and as host its ticket, never change),
/// - the session it was in (hosting, or the host it played for),
/// - the timing of every phone it has hosted (by id): tuning is remembered per phone.
class SessionMemory {
  SessionMemory(this._prefs);

  final SharedPreferences _prefs;

  static const _kIdentity = 'identity';
  static const _kRole = 'session.role';
  static const _kTicket = 'session.ticket';
  static const _kHostName = 'session.hostName';
  static const _kTimings = 'session.timings';
  static const _kSelfDelay = 'session.selfDelayMs';
  static const _kSelfTuned = 'session.selfTuned';

  /// This phone's identity key; made on first launch.
  static Future<List<int>> identityKey(SharedPreferences prefs) async {
    final saved = prefs.getString(_kIdentity);
    if (saved != null) {
      try {
        final bytes = base64Decode(saved);
        if (bytes.length == 32) return bytes;
      } on FormatException {
        // replaced below
      }
    }
    final rng = Random.secure();
    final key = List<int>.generate(32, (_) => rng.nextInt(256));
    await prefs.setString(_kIdentity, base64Encode(key));
    return key;
  }

  RememberedSession? get session {
    switch (_prefs.getString(_kRole)) {
      case 'host':
        return const RememberedSession.host();
      case 'guest':
        final t = _prefs.getString(_kTicket);
        if (t == null || t.isEmpty) return null;
        return RememberedSession.guest(ticket: t, hostName: _prefs.getString(_kHostName) ?? 'the host');
    }
    return null;
  }

  Future<void> rememberHost() async {
    await _prefs.setString(_kRole, 'host');
    await _prefs.remove(_kTicket);
  }

  Future<void> rememberGuest(String ticket, String hostName) async {
    await _prefs.setString(_kRole, 'guest');
    await _prefs.setString(_kTicket, ticket);
    await _prefs.setString(_kHostName, hostName);
  }

  /// The host's newer ticket (its addresses changed); only while remembering a guest session.
  Future<void> updateTicket(String ticket, String hostName) async {
    if (_prefs.getString(_kRole) != 'guest') return;
    if (_prefs.getString(_kTicket) == ticket && _prefs.getString(_kHostName) == hostName) return;
    await _prefs.setString(_kTicket, ticket);
    await _prefs.setString(_kHostName, hostName);
  }

  /// Leaving or ending on purpose: next launch starts at Home. Timings stay (they describe phones).
  Future<void> forget() async {
    await _prefs.remove(_kRole);
    await _prefs.remove(_kTicket);
    await _prefs.remove(_kHostName);
  }

  Map<String, ({double delayMs, bool tuned})> get _timingMap {
    final raw = _prefs.getString(_kTimings);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((id, v) {
        final e = v as Map<String, dynamic>;
        return MapEntry(id, (delayMs: (e['d'] as num).toDouble(), tuned: e['t'] == true));
      });
    } on Object {
      return {};
    }
  }

  List<rust.KnownTiming> get timings => [
    for (final e in _timingMap.entries) rust.KnownTiming(peerId: e.key, delayMs: e.value.delayMs, tuned: e.value.tuned),
  ];

  /// Merges what the host knows now. Returns quickly when nothing changed (called on status).
  Future<void> saveTimings(Iterable<({String id, double delayMs, bool tuned})> now) async {
    final m = _timingMap;
    var changed = false;
    for (final t in now) {
      final old = m[t.id];
      if (old == null || (old.delayMs - t.delayMs).abs() > 0.05 || old.tuned != t.tuned) {
        m[t.id] = (delayMs: t.delayMs, tuned: t.tuned);
        changed = true;
      }
    }
    if (!changed) return;
    await _prefs.setString(_kTimings, jsonEncode(m.map((id, v) => MapEntry(id, {'d': v.delayMs, 't': v.tuned}))));
  }

  ({double ms, bool tuned}) get selfDelay => (ms: _prefs.getDouble(_kSelfDelay) ?? 0, tuned: _prefs.getBool(_kSelfTuned) ?? false);

  Future<void> saveSelfDelay(double ms, {required bool tuned}) async {
    final old = selfDelay;
    if ((old.ms - ms).abs() <= 0.05 && old.tuned == tuned) return;
    await _prefs.setDouble(_kSelfDelay, ms);
    await _prefs.setBool(_kSelfTuned, tuned);
  }
}

final sessionMemoryProvider = Provider<SessionMemory>((ref) => SessionMemory(ref.watch(prefsProvider)));
