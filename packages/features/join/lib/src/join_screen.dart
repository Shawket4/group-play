import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:feature_join/src/join_flow.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scan the host's code. Then, if needed, join its hotspot; then connect.
class JoinScreen extends ConsumerWidget {
  const JoinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(joinFlowProvider.select((s) => s.phase), (_, phase) {
      if (phase == JoinPhase.joined) context.go(Routes.speaker);
    });
    final flow = ref.watch(joinFlowProvider);
    final camera = ref.watch(scannerProvider);
    final n = ref.read(joinFlowProvider.notifier);
    final secondary = GPColors.of(context, GPColors.secondaryLabel);

    return CupertinoPageScaffold(
      backgroundColor: GPColors.background,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Join'),
        previousPageTitle: 'Group Play',
        border: null,
        backgroundColor: GPColors.background,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(GPSpace.page, GPSpace.xs, GPSpace.page, GPSpace.md),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(GPRadius.large * 1.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: CupertinoColors.black,
                        child: MobileScanner(
                          controller: camera,
                          onDetect: (capture) {
                            for (final b in capture.barcodes) {
                              final v = b.rawValue;
                              if (v != null) {
                                unawaited(n.onCode(v));
                                break;
                              }
                            }
                          },
                          errorBuilder: (context, error) => GPEmptyState(
                            icon: CupertinoIcons.camera,
                            title: 'Camera unavailable',
                            message: error.errorCode == MobileScannerErrorCode.permissionDenied
                                ? 'Allow camera access in Settings, or paste a code instead.'
                                : 'Paste a code instead.',
                          ),
                        ),
                      ),
                      const IgnorePointer(child: Center(child: _Viewfinder())),
                      if (flow.phase != JoinPhase.scanning) _Progress(flow: flow),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: GPSpace.md),
              Text('Point the camera at the code on the host’s screen.', textAlign: TextAlign.center, style: GPText.subheadline.copyWith(color: secondary)),
              const SizedBox(height: GPSpace.xs),
              CupertinoButton(
                minimumSize: const Size(GPSize.minTap, GPSize.minTap),
                onPressed: flow.phase == JoinPhase.scanning ? n.pasteFromClipboard : null,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Icon(CupertinoIcons.doc_on_clipboard, size: 18), SizedBox(width: 6), Text('Paste a Code')],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four corner brackets.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 230, height: 230, child: CustomPaint(painter: _CornersPainter()));
  }
}

class _CornersPainter extends CustomPainter {
  const _CornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = CupertinoColors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const l = 34.0;
    const r = 18.0;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, l)
      ..lineTo(0, r)
      ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
      ..lineTo(l, 0)
      ..moveTo(w - l, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, l)
      ..moveTo(w, h - l)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
      ..lineTo(w - l, h)
      ..moveTo(l, h)
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: const Radius.circular(r))
      ..lineTo(0, h - l);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Covers the camera while joining: progress, or the manual Wi-Fi steps.
class _Progress extends ConsumerWidget {
  const _Progress({required this.flow});

  final JoinState flow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(joinFlowProvider.notifier);
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return ColoredBox(
      color: GPColors.of(context, GPColors.surface),
      child: Padding(
        padding: const EdgeInsets.all(GPSpace.xl),
        child: Center(
          child: flow.phase == JoinPhase.needsWifi
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const GPIconTile(CupertinoIcons.wifi, size: 52),
                    const SizedBox(height: GPSpace.md),
                    const Text('Join the Host’s Wi-Fi', style: GPText.title3, textAlign: TextAlign.center),
                    const SizedBox(height: GPSpace.xs),
                    Text('In Settings › Wi-Fi, join this network, then come back.', textAlign: TextAlign.center, style: GPText.subheadline.copyWith(color: secondary)),
                    const SizedBox(height: GPSpace.md),
                    _CopyLine(label: 'Network', value: flow.ssid),
                    _CopyLine(label: 'Password', value: flow.passphrase),
                    const SizedBox(height: GPSpace.md),
                    GPButton(label: 'I’ve Joined', onPressed: n.wifiJoinedByHand),
                    if (IosNative.available) ...[
                      const SizedBox(height: GPSpace.xs),
                      const GPButton(label: 'Open Settings', style: GPButtonStyle.secondary, onPressed: IosNative.openSettings),
                    ],
                    CupertinoButton(onPressed: n.cancel, child: const Text('Cancel')),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CupertinoActivityIndicator(radius: 16),
                    const SizedBox(height: GPSpace.md),
                    Text(
                      flow.phase == JoinPhase.joiningWifi ? 'Joining “${flow.ssid}”…' : 'Connecting to ${flow.hostName}…',
                      textAlign: TextAlign.center,
                      style: GPText.headline,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _CopyLine extends StatelessWidget {
  const _CopyLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: GPSpace.xxs),
      minimumSize: const Size(GPSize.minTap, GPSize.minTap),
      onPressed: () => Clipboard.setData(ClipboardData(text: value)),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(label, style: GPText.body.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)))),
          Expanded(child: Text(value, style: GPText.body.copyWith(color: GPColors.of(context, GPColors.label), fontWeight: FontWeight.w600))),
          Icon(CupertinoIcons.doc_on_clipboard, size: 18, color: GPColors.of(context, GPColors.ink)),
        ],
      ),
    );
  }
}
