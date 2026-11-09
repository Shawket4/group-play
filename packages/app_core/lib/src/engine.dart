
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// The engine's snapshot, four times a second.
final engineStatusProvider = StreamProvider<EngineStatus>((ref) => statusStream());

enum SessionRole { idle, host, guest }

/// What this phone is doing right now.
final sessionRoleProvider = Provider<SessionRole>((ref) {
  final role = ref.watch(engineStatusProvider.select((s) => s.value?.role));
  return switch (role) {
    'host' => SessionRole.host,
    'guest' => SessionRole.guest,
    _ => SessionRole.idle,
  };
});

/// Engine log lines (most recent last), for the Logs screen.
final logsProvider = NotifierProvider<Logs, List<String>>(Logs.new);

class Logs extends Notifier<List<String>> {
  static const _max = 500;

  @override
  List<String> build() {
    final sub = logStream().listen(add);
    ref.onDispose(sub.cancel);
    return const [];
  }

  void add(String line) {
    final next = [...state, line];
    state = next.length > _max ? next.sublist(next.length - _max) : next;
  }
}
