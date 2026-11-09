import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/theme.dart';

Future<void> showLogs(BuildContext context, TuttiController controller) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: TuttiColors.surface,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (c, scroll) {
        final lines = controller.logs.reversed.toList();
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(children: [
              const Text('Logs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: controller.logs.join('\n')));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs copied')));
                },
              ),
            ]),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(14),
              itemCount: lines.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: TuttiColors.muted)),
              ),
            ),
          ),
        ]);
      },
    ),
  );
}
