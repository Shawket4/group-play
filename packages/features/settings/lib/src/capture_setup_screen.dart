import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// One-time setup for full sharing: install Shizuku, start it, allow Group Play.
/// When hosting, the last step starts sharing straight away.
class CaptureSetupScreen extends ConsumerWidget {
  const CaptureSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capsAsync = ref.watch(androidCapsProvider);
    final caps = capsAsync.value ?? AndroidCapabilities.none;
    final role = ref.watch(sessionRoleProvider);
    final pending = ref.watch(sessionProvider.select((s) => s.pending));
    final capsN = ref.read(androidCapsProvider.notifier);

    Widget step(int n, {required bool done, required String title, required String body, Widget? action}) {
      return GPCellContent(
        padding: const EdgeInsets.fromLTRB(GPSpace.md, GPSpace.sm, GPSpace.md, GPSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: done ? 'Step $n done' : 'Step $n',
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: GPColors.of(context, done ? GPColors.good : GPColors.fill),
                  shape: BoxShape.circle,
                ),
                child: done
                    ? const Icon(CupertinoIcons.checkmark_alt, size: 16, color: CupertinoColors.white)
                    : Text('$n', style: GPText.footnote.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: GPSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GPText.headline),
                  const SizedBox(height: 2),
                  Text(body, style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel))),
                  if (action != null) ...[const SizedBox(height: GPSpace.xs), action],
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget link(String label, VoidCallback onTap) => Align(
          alignment: Alignment.centerLeft,
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(GPSize.minTap, GPSize.minTap),
            onPressed: onTap,
            child: Text(label, style: GPText.body.copyWith(color: GPColors.of(context, GPColors.ink))),
          ),
        );

    return GPPage(
      title: 'Full Sharing',
      previousPageTitle: 'Back',
      trailing: GPBarButton('Check', onPressed: capsN.refresh),
      bottom: role == SessionRole.host
          ? GPButton(
              label: 'Start Sharing',
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              busy: pending == SessionAction.source,
              onPressed: caps.fullCaptureReady
                  ? () async {
                      final r = await ref.read(sessionProvider.notifier).playCapture(CaptureMode.output);
                      if (r == CaptureStart.started && context.mounted) context.pop();
                    }
                  : null,
            )
          : null,
      slivers: [
        const GPParagraph(
          'Spotify and Chrome block ordinary audio capture. Shizuku, a free app, lets Group Play record the phone’s whole output the way a computer over USB debugging can. No root needed. While sharing, this phone stays quiet and the speakers play.',
        ),
        if (!caps.outputCaptureSupported && caps.sdkInt > 0)
          const GPSection(
            children: [
              GPRow(
                leading: GPIconTile(CupertinoIcons.exclamationmark_triangle_fill),
                title: 'Needs Android 12 or newer',
                subtitle: 'Use “Apps that allow capture” on this phone instead.',
              ),
            ],
          ),
        GPSection(
          children: [
            step(
              1,
              done: caps.shizukuInstalled,
              title: 'Install Shizuku',
              body: 'From Google Play, or GitHub (RikkaApps/Shizuku).',
              action: caps.shizukuInstalled ? null : link('Get Shizuku', AndroidNative.openShizukuDownload),
            ),
            step(
              2,
              done: caps.shizukuRunning,
              title: 'Start Shizuku',
              body:
                  'Settings › About phone › tap Build number 7 times. Then Developer options › turn on Wireless debugging. In Shizuku, tap Pairing, enter the code from Wireless debugging, then Start. Start it again after every restart.',
              action: caps.shizukuRunning || !caps.shizukuInstalled ? null : link('Open Shizuku', AndroidNative.openShizukuApp),
            ),
            step(
              3,
              done: caps.shizukuPermission,
              title: 'Allow Group Play',
              body: 'Tap Allow in Shizuku’s dialog.',
              action: caps.shizukuPermission || !caps.shizukuRunning ? null : link('Allow', capsN.requestShizukuPermission),
            ),
          ],
        ),
        if (caps.fullCaptureReady)
          GPSection(
            children: [
              GPRow(
                leading: const GPIconTile(CupertinoIcons.checkmark_alt),
                title: 'Ready',
                subtitle: caps.shizukuUid == 0 ? 'Shizuku runs as root' : 'Shizuku runs as the shell user',
              ),
            ],
          ),
      ],
    );
  }
}
