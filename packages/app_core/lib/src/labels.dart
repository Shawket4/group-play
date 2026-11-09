import 'package:design_system/design_system.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// How well a device is locked to the shared timeline, in words + tone.
({String label, GPTone tone}) syncQuality({required bool synced, required bool playing, required double errMs}) {
  if (!synced) return (label: 'Syncing clock', tone: GPTone.warn);
  if (!playing) return (label: 'Ready', tone: GPTone.good);
  final e = errMs.abs();
  if (e < 1.5) return (label: 'In sync', tone: GPTone.good);
  if (e < 8) return (label: 'Settling · ${e.toStringAsFixed(1)} ms', tone: GPTone.warn);
  return (label: 'Off by ${e.toStringAsFixed(0)} ms', tone: GPTone.bad);
}

({String label, GPTone tone}) peerQuality(PeerStatus p) {
  if (!p.connected) return (label: 'Left', tone: GPTone.bad);
  return syncQuality(synced: p.syncRttMs > 0, playing: p.playing, errMs: p.errMs);
}

String formatMs(double v, {int digits = 1}) => '${v.toStringAsFixed(digits)} ms';

String formatSignedMs(double v) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(0)} ms';

String formatPercent(double v) => '${(v * 100).round()}%';

/// "Direct · 4 ms" / "Relay · 80 ms".
String linkLabel(String path, double rttMs) {
  final kind = switch (path) {
    'direct' => 'Direct',
    'relay' => 'Relay',
    _ => 'Linked',
  };
  return rttMs > 0 ? '$kind · ${rttMs.toStringAsFixed(0)} ms' : kind;
}
