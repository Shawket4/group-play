import 'package:flutter/widgets.dart';
import 'package:group_play/app/app.dart';
import 'package:group_play/app/boot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final overrides = await boot();
  runApp(GroupPlayRoot(overrides: overrides));
}
