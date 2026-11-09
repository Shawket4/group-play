import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../platform/android_native.dart';

/// One-time setup for full capture. Returns true once Shizuku is running and Tutti is allowed.
Future<bool?> showShizukuSetup(BuildContext context, TuttiController controller) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TuttiColors.surface,
    builder: (c) => _ShizukuSetup(controller: controller),
  );
}

class _ShizukuSetup extends StatelessWidget {
  const _ShizukuSetup({required this.controller});
  final TuttiController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller.caps;
        final step1 = c.shizukuInstalled;
        final step2 = c.shizukuRunning;
        final step3 = c.shizukuPermission;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Share everything this phone plays', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Spotify and Chrome block normal audio capture. Tutti gets around that with Shizuku, a free app that lets Tutti record the phone\'s whole output the way a computer over USB debugging could. No root needed.',
                style: TextStyle(color: TuttiColors.muted),
              ),
              if (!c.outputCaptureSupported) ...[
                const SizedBox(height: 12),
                const Text('This phone runs Android older than 12, which full capture needs.', style: TextStyle(color: TuttiColors.bad)),
              ],
              const SizedBox(height: 18),
              _Step(
                n: 1,
                done: step1,
                title: 'Install Shizuku',
                body: 'From Google Play (or GitHub: RikkaApps/Shizuku).',
                action: step1 ? null : ('Get Shizuku', AndroidNative.openShizukuDownload),
              ),
              _Step(
                n: 2,
                done: step2,
                title: 'Start Shizuku',
                body: 'Settings → About phone → tap Build number 7× to unlock Developer options. Turn on Wireless debugging (on Wi-Fi). '
                    'In Shizuku tap "Pairing", enter the pairing code from Wireless debugging, then "Start". '
                    'Repeat "Start" after each reboot.',
                action: step2 ? null : ('Open Shizuku', AndroidNative.openShizukuApp),
              ),
              _Step(
                n: 3,
                done: step3,
                title: 'Allow Tutti',
                body: 'Tap Allow in the Shizuku dialog.',
                action: (!step2 || step3) ? null : ('Allow', () async {
                  await AndroidNative.requestShizukuPermission();
                  await controller.refreshCaps();
                }),
              ),
              const SizedBox(height: 10),
              Row(children: [
                TextButton(onPressed: controller.refreshCaps, child: const Text('Check again')),
                const Spacer(),
                FilledButton(
                  onPressed: c.fullCaptureReady ? () => Navigator.pop(context, true) : null,
                  child: const Text('Start sharing'),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.done, required this.title, required this.body, this.action});
  final int n;
  final bool done;
  final String title;
  final String body;
  final (String, Future<void> Function())? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: done ? TuttiColors.good : TuttiColors.surfaceHigh,
          child: done ? const Icon(Icons.check_rounded, size: 16, color: Colors.black) : Text('$n', style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(body, style: const TextStyle(fontSize: 13, color: TuttiColors.muted)),
            if (action != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ]),
        ),
      ]),
    );
  }
}
