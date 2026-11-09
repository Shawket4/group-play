import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rust_bridge/rust_bridge.dart';

/// Start screen: what the app does, and the two ways in, within thumb reach.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(sessionRoleProvider);
    final pending = ref.watch(sessionProvider.select((s) => s.pending));
    final name = ref.watch(deviceSettingsProvider.select((s) => s.name));
    final status = ref.watch(engineStatusProvider).value;
    final secondary = GPColors.of(context, GPColors.secondaryLabel);

    Future<void> host() async {
      final ok = await ref.read(sessionProvider.notifier).host();
      if (ok && context.mounted) await context.push(Routes.host);
    }

    return CupertinoPageScaffold(
      backgroundColor: GPColors.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(GPSpace.page, 0, GPSpace.page, GPSpace.md),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: GPIconButton(CupertinoIcons.gear, label: 'Settings', onPressed: () => context.push(Routes.settings)),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        const GPRings(size: 210),
                        const SizedBox(height: GPSpace.xl),
                        const Text('Group Play', style: GPText.title1, textAlign: TextAlign.center),
                        const SizedBox(height: GPSpace.xs),
                        Text(
                          'Every phone in the room plays\nthe same song, at the same moment.',
                          textAlign: TextAlign.center,
                          style: GPText.body.copyWith(color: secondary, fontWeight: FontWeight.w400),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (role != SessionRole.idle) ...[
                _SessionBanner(role: role, status: status),
                const SizedBox(height: GPSpace.sm),
              ] else ...[
                GPButton(
                  label: 'Host a Session',
                  icon: CupertinoIcons.dot_radiowaves_left_right,
                  busy: pending == SessionAction.hosting,
                  onPressed: host,
                ),
                const SizedBox(height: GPSpace.sm),
                GPButton(
                  label: 'Join as a Speaker',
                  icon: CupertinoIcons.qrcode_viewfinder,
                  style: GPButtonStyle.secondary,
                  onPressed: () => context.push(Routes.join),
                ),
              ],
              CupertinoButton(
                minimumSize: const Size(GPSize.minTap, GPSize.minTap),
                onPressed: () => context.push(Routes.settingsName),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'This phone is ', style: GPText.footnote.copyWith(color: GPColors.of(context, GPColors.tertiaryLabel))),
                      TextSpan(text: name, style: GPText.footnote.copyWith(color: GPColors.of(context, GPColors.ink), fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A session is already running: say so, and take the person back to it.
class _SessionBanner extends StatelessWidget {
  const _SessionBanner({required this.role, required this.status});

  final SessionRole role;
  final EngineStatus? status;

  @override
  Widget build(BuildContext context) {
    final host = role == SessionRole.host;
    final s = status;
    final speakers = host && s != null ? s.peers.where((p) => p.connected).length : 0;
    final title = host ? 'You’re hosting' : 'Playing with ${s?.hostName ?? 'the host'}';
    final caption = host ? '$speakers ${speakers == 1 ? 'speaker' : 'speakers'} connected' : (s?.source ?? 'Waiting for music');
    return GPCard(
      inverted: true,
      padding: const EdgeInsets.fromLTRB(GPSpace.md, GPSpace.sm, GPSpace.xs, GPSpace.sm),
      child: Row(
        children: [
          Icon(host ? CupertinoIcons.dot_radiowaves_left_right : CupertinoIcons.speaker_2_fill, color: GPColors.of(context, GPColors.onInk)),
          const SizedBox(width: GPSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GPText.headline.copyWith(color: GPColors.of(context, GPColors.onInk))),
                Text(caption, style: GPText.footnote.copyWith(color: GPColors.of(context, GPColors.onInk).withValues(alpha: 0.7))),
              ],
            ),
          ),
          CupertinoButton(
            minimumSize: const Size(GPSize.minTap, GPSize.minTap),
            onPressed: () => context.push(host ? Routes.host : Routes.speaker),
            child: Text('Open', style: GPText.button.copyWith(color: GPColors.of(context, GPColors.onInk))),
          ),
        ],
      ),
    );
  }
}
