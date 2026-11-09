import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The join code, big, in a sheet. Live: it follows address and hotspot changes.
Future<void> showInviteSheet(BuildContext context) {
  return showCupertinoSheet<void>(
    context: context,
    showDragHandle: true,
    scrollableBuilder: (context, controller) => _InviteSheet(controller: controller),
  );
}

class _InviteSheet extends ConsumerWidget {
  const _InviteSheet({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticket = ref.watch(engineStatusProvider.select((s) => s.value?.ticket ?? ''));
    final hotspot = ref.watch(sessionProvider.select((s) => s.hotspot));
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    final speakers = ref.watch(engineStatusProvider.select((s) => s.value?.peers.where((p) => p.connected).length ?? 0));
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return CupertinoPageScaffold(
      backgroundColor: GPColors.background,
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(GPSpace.page, GPSpace.xl, GPSpace.page, GPSpace.xxl),
        children: [
          const Text('Invite Speakers', style: GPText.title2, textAlign: TextAlign.center),
          const SizedBox(height: GPSpace.xs),
          Text(
            'Scan with Group Play, or with the Camera app.',
            textAlign: TextAlign.center,
            style: GPText.subheadline.copyWith(color: secondary),
          ),
          const SizedBox(height: GPSpace.xl),
          Center(child: GPQrCode(data: Routes.joinLink(ticket), size: 260, semanticLabel: 'Join code')),
          const SizedBox(height: GPSpace.lg),
          Text(
            'Hosted by $name · ${speakers == 0 ? 'no speakers yet' : '$speakers connected'}',
            textAlign: TextAlign.center,
            style: GPText.footnote.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel)),
          ),
          if (hotspot != null) ...[
            const SizedBox(height: GPSpace.xxl),
            const GPSectionLabel('This phone’s hotspot'),
            GPCard(
              child: Row(
                children: [
                  GPQrCode(
                    data: 'WIFI:T:WPA;S:${_esc(hotspot.ssid)};P:${_esc(hotspot.passphrase)};;',
                    size: 92,
                    semanticLabel: 'Wi-Fi code for the hotspot',
                  ),
                  const SizedBox(width: GPSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(hotspot.ssid, style: GPText.headline),
                        Text(hotspot.passphrase, style: GPText.numMd.copyWith(color: secondary)),
                        const SizedBox(height: GPSpace.xs),
                        Text(
                          'Android joins it from the join code. iPhone: scan this Wi-Fi code with the Camera app first.',
                          style: GPText.footnote.copyWith(color: secondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: GPSpace.xxl),
          GPButton(label: 'Done', style: GPButtonStyle.secondary, onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  static String _esc(String s) => s.replaceAllMapped(RegExp(r'([\;,:"])'), (m) => '\\${m[1]}');
}
