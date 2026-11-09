import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show NotifierProviderFamily;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:rust_bridge/rust_bridge.dart' as rust;

enum JoinPhase { scanning, joiningWifi, needsWifi, connecting, joined }

class JoinState {
  const JoinState({
    this.phase = JoinPhase.scanning,
    this.hostName = '',
    this.ssid = '',
    this.passphrase = '',
    this.ticket = '',
    this.cameraWanted = true,
  });

  final JoinPhase phase;
  final String hostName;
  final String ssid;
  final String passphrase;
  final String ticket;

  /// False while a deep-linked ticket is being joined: no camera (and no camera prompt).
  final bool cameraWanted;

  JoinState copyWith({JoinPhase? phase, String? hostName, String? ssid, String? passphrase, String? ticket}) => JoinState(
        phase: phase ?? this.phase,
        hostName: hostName ?? this.hostName,
        ssid: ssid ?? this.ssid,
        passphrase: passphrase ?? this.passphrase,
        ticket: ticket ?? this.ticket,
        cameraWanted: cameraWanted,
      );
}

/// The camera, owned by the join flow's lifetime.
final Provider<MobileScannerController> scannerProvider = Provider.autoDispose<MobileScannerController>((ref) {
  final c = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  ref.onDispose(c.dispose);
  return c;
});

/// Scan → (join the host's hotspot) → connect. The argument is a ticket that arrived with a
/// deep link (the phone's camera scanned the host's code): the flow starts with it.
final NotifierProviderFamily<JoinFlow, JoinState, String?> joinFlowProvider =
    NotifierProvider.autoDispose.family<JoinFlow, JoinState, String?>(JoinFlow.new);

class JoinFlow extends Notifier<JoinState> {
  JoinFlow(this.initialTicket);

  final String? initialTicket;

  @override
  JoinState build() {
    final t = initialTicket;
    if (t != null && t.isNotEmpty) {
      // after build returns, so the initial state is in place first
      unawaited(Future.microtask(() => onCode(t)));
      return const JoinState(cameraWanted: false);
    }
    return const JoinState();
  }

  MobileScannerController get _camera => ref.read(scannerProvider);

  /// A code was seen (or pasted). Non-Group Play codes are ignored. Returns whether it was ours.
  Future<bool> onCode(String raw) async {
    if (state.phase != JoinPhase.scanning) return true;
    final rust.TicketInfo info;
    try {
      info = rust.parseTicket(ticket: raw);
    } on Object {
      return false;
    }
    final camera = state.cameraWanted;
    state = JoinState(phase: JoinPhase.connecting, hostName: info.hostName, ticket: raw, cameraWanted: camera);
    if (camera) unawaited(_camera.stop());
    final ssid = info.wifiSsid ?? '';
    if (ssid.isNotEmpty) {
      state = state.copyWith(phase: JoinPhase.joiningWifi, ssid: ssid, passphrase: info.wifiPassphrase ?? '');
      final ok = await ref.read(sessionProvider.notifier).joinWifi(ssid, info.wifiPassphrase ?? '');
      if (!ref.mounted) return true;
      if (!ok) {
        state = state.copyWith(phase: JoinPhase.needsWifi);
        return true;
      }
    }
    await _connect();
    return true;
  }

  /// The person joined the hotspot in Settings.
  Future<void> wifiJoinedByHand() => _connect();

  Future<void> pasteFromClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final ours = text.isNotEmpty && await onCode(text);
    if (!ours) ref.read(alertsProvider.notifier).show('The clipboard has no Group Play code.');
  }

  /// Back to scanning (also after a deep-linked join failed: then the camera comes up).
  void cancel() {
    final hadCamera = state.cameraWanted;
    state = const JoinState();
    if (hadCamera) unawaited(_camera.start());
  }

  Future<void> _connect() async {
    state = state.copyWith(phase: JoinPhase.connecting);
    final ok = await ref.read(sessionProvider.notifier).join(state.ticket, wifiHandled: true);
    if (!ref.mounted) return;
    if (ok) {
      state = state.copyWith(phase: JoinPhase.joined);
    } else {
      cancel();
    }
  }
}
