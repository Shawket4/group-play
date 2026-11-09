import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:group_play/app/router.dart';

class GroupPlayRoot extends StatelessWidget {
  const GroupPlayRoot({required this.overrides, super.key});

  final List<Override> overrides;

  @override
  Widget build(BuildContext context) => ProviderScope(overrides: overrides, child: const GroupPlayApp());
}

class GroupPlayApp extends ConsumerWidget {
  const GroupPlayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // keep the log tail alive from the start, so the Logs screen has history
    ref.watch(logsProvider.select((_) => 0));
    return CupertinoApp.router(
      title: 'Group Play',
      debugShowCheckedModeBanner: false,
      theme: buildGPTheme(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => _Toasts(child: child ?? const SizedBox.shrink()),
    );
  }
}

class _Toasts extends ConsumerWidget {
  const _Toasts({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GPToastLayer(
      toasts: ref.watch(alertsProvider),
      onDismiss: ref.read(alertsProvider.notifier).dismiss,
      child: child,
    );
  }
}
