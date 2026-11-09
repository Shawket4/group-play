import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    final caps = ref.watch(androidCapsProvider).value;
    final logCount = ref.watch(logsProvider.select((l) => l.length));
    return GPPage(
      title: 'Settings',
      previousPageTitle: 'Group Play',
      slivers: [
        GPSection(
          children: [
            GPRow(
              leading: const GPIconTile(CupertinoIcons.device_phone_portrait),
              title: 'Name',
              value: name,
              onTap: () => context.push(Routes.settingsName),
            ),
          ],
        ),
        if (AndroidNative.available)
          GPSection(
            header: 'Sharing this phone’s audio',
            footer: 'Full sharing plays anything this phone plays, Spotify and Chrome included, through Shizuku.',
            children: [
              GPRow(
                leading: const GPIconTile(CupertinoIcons.antenna_radiowaves_left_right),
                title: 'Full Sharing Setup',
                value: caps == null ? null : (caps.fullCaptureReady ? 'Ready' : 'Not set up'),
                onTap: () => context.push(Routes.settingsCapture),
              ),
            ],
          ),
        GPSection(
          header: 'Diagnostics',
          children: [
            GPRow(
              leading: const GPIconTile(CupertinoIcons.doc_text),
              title: 'Logs',
              value: '$logCount',
              onTap: () => context.push(Routes.settingsLogs),
            ),
          ],
        ),
        GPSection(
          header: 'About',
          footer: 'Clock sync, playback and networking run in a shared Rust engine. Speakers on the same Wi-Fi or hotspot connect directly.',
          children: [
            const GPRow(title: 'Version', value: '0.1.0'),
            GPRow(title: 'Platform', value: platformName),
            if (caps != null && caps.sdkInt > 0) GPRow(title: 'Android', value: 'API ${caps.sdkInt}'),
          ],
        ),
      ],
    );
  }
}
