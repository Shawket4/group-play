import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../platform/ios_native.dart';
import '../src/rust/api/engine.dart' as rust;
import '../widgets/common.dart';

/// Scan (or paste) the host's ticket, join its hotspot if it has one, then connect.
/// Pops `true` when joined.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.controller});
  final TuttiController controller;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handling = false;
  String? _status;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _onCode(String raw) async {
    if (_handling) return;
    final rust.TicketInfo info;
    try {
      info = rust.parseTicket(ticket: raw);
    } catch (_) {
      return; // not ours, keep scanning
    }
    setState(() {
      _handling = true;
      _status = 'Found ${info.hostName}';
    });
    await _scanner.stop();
    final c = widget.controller;
    final ssid = info.wifiSsid;
    if (ssid != null && ssid.isNotEmpty) {
      setState(() => _status = 'Joining Wi-Fi "$ssid"…');
      final ok = await c.joinWifi(ssid, info.wifiPassphrase ?? '');
      if (!ok && mounted) {
        final proceed = await _manualWifi(ssid, info.wifiPassphrase ?? '');
        if (proceed != true) {
          _reset();
          return;
        }
      }
    }
    setState(() => _status = 'Connecting to ${info.hostName}…');
    // join without re-trying Wi-Fi (done above)
    await c.joinTicketOnly(raw);
    if (!mounted) return;
    if (c.isGuest) {
      Navigator.of(context).pop(true);
    } else {
      _reset();
    }
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _handling = false;
      _status = null;
    });
    _scanner.start();
  }

  Future<bool?> _manualWifi(String ssid, String pass) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Join the host\'s Wi-Fi'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('In Settings → Wi-Fi, join:'),
          const SizedBox(height: 10),
          SelectableText('Network:  $ssid', style: const TextStyle(fontWeight: FontWeight.w600)),
          SelectableText('Password: $pass', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          const Text('Then come back here.', style: TextStyle(color: TuttiColors.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: pass)), child: const Text('Copy password')),
          if (IosNative.available) TextButton(onPressed: IosNative.openSettings, child: const Text('Settings')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('I\'ve joined')),
        ],
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    await _onCode(text);
    if (!_handling && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The clipboard has no Tutti code')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MessageListener(
      controller: widget.controller,
      child: Scaffold(
        appBar: AppBar(title: const Text('Join a session')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(fit: StackFit.expand, children: [
                  MobileScanner(
                    controller: _scanner,
                    onDetect: (cap) {
                      for (final b in cap.barcodes) {
                        final v = b.rawValue;
                        if (v != null) {
                          _onCode(v);
                          break;
                        }
                      }
                    },
                    errorBuilder: (context, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Camera unavailable: ${error.errorCode.name}', textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 3),
                        ),
                      ),
                    ),
                  ),
                  if (_status != null)
                    Container(
                      color: Colors.black.withValues(alpha: 0.6),
                      child: Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(_status!, style: const TextStyle(fontSize: 16)),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Point the camera at the QR code on the host phone.', style: TextStyle(color: TuttiColors.muted)),
            const SizedBox(height: 10),
            TextButton.icon(onPressed: _handling ? null : _paste, icon: const Icon(Icons.content_paste_rounded), label: const Text('Paste a code instead')),
          ]),
        ),
      ),
    );
  }
}
