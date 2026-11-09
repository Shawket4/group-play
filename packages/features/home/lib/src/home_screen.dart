import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Start screen: host or join, plus the running session if there is one.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(sessionRoleProvider);
    final pending = ref.watch(sessionProvider.select((s) => s.pending));
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    final hostName = ref.watch(engineStatusProvider.select((s) => s.value?.hostName ?? ''));

    Future<void> host() async {
      if (role == SessionRole.host) {
        await context.push(Routes.host);
        return;
      }
      final ok = await ref.read(sessionProvider.notifier).host();
      if (ok && context.mounted) await context.push(Routes.host);
    }

    return GPPage(
      title: 'Group Play',
      trailing: GPIconButton(
        CupertinoIcons.gear,
        label: 'Settings',
        onPressed: () => context.push(Routes.settings),
      ),
      slivers: [
        const GPParagraph('Every phone in the room plays the same song at the same moment.'),
        if (role != SessionRole.idle)
          GPSection(
            header: 'Now',
            children: [
              GPRow(
                leading: GPIconTile(
                  role == SessionRole.host ? CupertinoIcons.dot_radiowaves_left_right : CupertinoIcons.speaker_2_fill,
                ),
                title: role == SessionRole.host ? 'You’re hosting' : 'Playing with $hostName',
                subtitle: 'Tap to return to the session',
                onTap: () => context.push(role == SessionRole.host ? Routes.host : Routes.speaker),
              ),
            ],
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(GPSpace.page, GPSpace.xs, GPSpace.page, GPSpace.lg),
          sliver: SliverList.list(
            children: [
              GPHeroAction(
                primary: true,
                icon: CupertinoIcons.dot_radiowaves_left_right,
                title: role == SessionRole.host ? 'Open Your Session' : 'Host a Session',
                subtitle: 'This phone picks the music. Others join with a QR code.',
                busy: pending == SessionAction.hosting,
                onTap: role == SessionRole.guest ? null : host,
              ),
              const SizedBox(height: GPSpace.sm),
              GPHeroAction(
                icon: CupertinoIcons.qrcode_viewfinder,
                title: 'Join as a Speaker',
                subtitle: 'Scan the host’s code and play in sync.',
                onTap: role == SessionRole.host ? null : () => context.push(Routes.join),
              ),
            ],
          ),
        ),
        GPSection(
          header: 'This phone',
          footer: 'Other phones see this name in the speaker list.',
          children: [
            GPRow(
              leading: const GPIconTile(CupertinoIcons.device_phone_portrait),
              title: name,
              onTap: () => context.push(Routes.settingsName),
            ),
          ],
        ),
      ],
    );
  }
}
