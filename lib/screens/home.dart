import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../widgets/common.dart';
import 'host.dart';
import 'join.dart';
import 'listen.dart';
import 'logs.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final TuttiController controller;

  Future<void> _host(BuildContext context) async {
    await controller.host();
    if (!context.mounted || !controller.isHost) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => HostScreen(controller: controller)));
  }

  Future<void> _join(BuildContext context) async {
    final joined = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => JoinScreen(controller: controller)));
    if (joined == true && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListenScreen(controller: controller)));
    }
  }

  Future<void> _rename(BuildContext context) async {
    final ctl = TextEditingController(text: controller.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('This phone\'s name'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Kitchen')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null) await controller.setDeviceName(name);
  }

  @override
  Widget build(BuildContext context) {
    return MessageListener(
      controller: controller,
      child: Scaffold(
        body: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              // came back to the home screen while a session still runs (e.g. app restarted)
              final role = controller.role;
              return Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Spacer(),
                      IconButton(
                        tooltip: 'Logs',
                        icon: const Icon(Icons.receipt_long_rounded, color: TuttiColors.muted),
                        onPressed: () => showLogs(context, controller),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    const GradientText('Tutti', style: TextStyle(fontSize: 56, fontWeight: FontWeight.w800, height: 1)),
                    const SizedBox(height: 10),
                    const Text('Every phone, one sound.', style: TextStyle(fontSize: 18, color: TuttiColors.muted)),
                    const SizedBox(height: 18),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _rename(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(platformIcon(controller.platform), size: 18, color: TuttiColors.muted),
                          const SizedBox(width: 8),
                          Text(controller.deviceName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          const Icon(Icons.edit_rounded, size: 15, color: TuttiColors.muted),
                        ]),
                      ),
                    ),
                    const Spacer(),
                    if (role != 'idle')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _ResumeBanner(controller: controller),
                      ),
                    _BigAction(
                      icon: Icons.podcasts_rounded,
                      title: 'Host a session',
                      subtitle: 'This phone picks the music. Others join with a QR code.',
                      gradient: true,
                      busy: controller.busy,
                      onTap: () => _host(context),
                    ),
                    const SizedBox(height: 14),
                    _BigAction(
                      icon: Icons.qr_code_scanner_rounded,
                      title: 'Join as a speaker',
                      subtitle: 'Scan the host\'s code and play in sync.',
                      busy: false,
                      onTap: () => _join(context),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({required this.controller});
  final TuttiController controller;

  @override
  Widget build(BuildContext context) {
    final host = controller.isHost;
    return Section(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(children: [
        Icon(host ? Icons.podcasts_rounded : Icons.speaker_rounded, color: TuttiColors.cyan),
        const SizedBox(width: 12),
        Expanded(child: Text(host ? 'You are hosting' : 'Playing with ${controller.status?.hostName ?? 'host'}')),
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => host ? HostScreen(controller: controller) : ListenScreen(controller: controller))),
          child: const Text('Open'),
        ),
      ]),
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({required this.icon, required this.title, required this.subtitle, required this.onTap, required this.busy, this.gradient = false});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: busy ? null : onTap,
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: gradient ? TuttiColors.accent : null,
            color: gradient ? null : TuttiColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: gradient ? null : Border.all(color: TuttiColors.outline),
          ),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: gradient ? 0.18 : 0.06),
                borderRadius: BorderRadius.circular(16),
              ),
              child: busy
                  ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 13.5, color: Colors.white.withValues(alpha: gradient ? 0.85 : 0.6))),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white),
          ]),
        ),
      ),
    );
  }
}
