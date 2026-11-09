import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-wide transient messages (the toast layer draws them). Each disappears on its own.
final alertsProvider = NotifierProvider<Alerts, List<GPToastData>>(Alerts.new);

class Alerts extends Notifier<List<GPToastData>> {
  int _next = 0;
  final Map<int, Timer> _timers = {};

  @override
  List<GPToastData> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
    });
    return const [];
  }

  void show(String message, {GPTone tone = GPTone.neutral, Duration duration = const Duration(seconds: 4)}) {
    final id = _next++;
    state = [...state, GPToastData(id: id, message: message, tone: tone)];
    _timers[id] = Timer(duration, () => dismiss(id));
    if (tone == GPTone.bad || tone == GPTone.warn) {
      unawaited(GPHaptics.warning());
    }
  }

  void error(String message) => show(message, tone: GPTone.bad, duration: const Duration(seconds: 6));

  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    state = [for (final t in state) if (t.id != id) t];
  }
}

/// Turns bridge and platform errors into one readable sentence.
String describeError(Object e) {
  final s = e.toString();
  final any = RegExp(r'AnyhowException\((.*)\)', dotAll: true).firstMatch(s);
  if (any != null) return any.group(1)!.split('\n').first.trim();
  final pe = RegExp(r'PlatformException\([^,]*, ([^,]*)').firstMatch(s);
  if (pe != null) return pe.group(1)!.trim();
  if (e is String) return e;
  return s.replaceFirst('Exception: ', '');
}
