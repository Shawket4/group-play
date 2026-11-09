import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Rename this phone. Holds only the text controller (no setState).
class NameScreen extends ConsumerStatefulWidget {
  const NameScreen({super.key});

  @override
  ConsumerState<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends ConsumerState<NameScreen> {
  late final TextEditingController _text = TextEditingController(text: ref.read(deviceSettingsProvider).name);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(deviceSettingsProvider.notifier).rename(_text.text);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return GPPage(
      title: 'Name',
      previousPageTitle: 'Back',
      trailing: GPBarButton('Done', bold: true, onPressed: _save),
      slivers: [
        GPSection(
          footer: 'Shown to the other phones in a session.',
          children: [
            GPCellContent(
              padding: const EdgeInsets.symmetric(horizontal: GPSpace.md, vertical: GPSpace.xxs),
              child: CupertinoTextField.borderless(
                controller: _text,
                autofocus: true,
                maxLength: 32,
                textCapitalization: TextCapitalization.words,
                clearButtonMode: OverlayVisibilityMode.editing,
                style: GPText.body,
                padding: const EdgeInsets.symmetric(vertical: GPSpace.sm),
                onSubmitted: (_) => _save(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
