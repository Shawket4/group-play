import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'app/theme.dart';
import 'screens/home.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final controller = TuttiController();
  await controller.init();
  runApp(TuttiApp(controller: controller));
}

class TuttiApp extends StatelessWidget {
  const TuttiApp({super.key, required this.controller});
  final TuttiController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tutti',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomeScreen(controller: controller),
    );
  }
}
