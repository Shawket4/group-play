import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(logsProvider).reversed.toList();
    return GPPage(
      title: 'Logs',
      previousPageTitle: 'Settings',
      trailing: GPBarButton(
        'Copy',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: ref.read(logsProvider).join('\n')));
          ref.read(alertsProvider.notifier).show('Logs copied', tone: GPTone.good);
        },
      ),
      slivers: [
        if (lines.isEmpty)
          const SliverToBoxAdapter(child: GPEmptyState(icon: CupertinoIcons.doc_text, title: 'No logs yet'))
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: GPSpace.page),
            sliver: SliverList.builder(
              itemCount: lines.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  lines[i],
                  style: GPText.mono.copyWith(
                    color: GPColors.of(context, GPColors.secondaryLabel),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
