import 'package:flutter/material.dart';

/// Tutti's palette: deep ink background, violet→cyan accent.
class TuttiColors {
  static const bg = Color(0xFF0D0E14);
  static const surface = Color(0xFF161823);
  static const surfaceHigh = Color(0xFF1E2130);
  static const outline = Color(0xFF2A2E40);
  static const text = Color(0xFFF2F3F8);
  static const muted = Color(0xFF9097AE);
  static const violet = Color(0xFF7C5CFF);
  static const cyan = Color(0xFF2EC5FF);
  static const good = Color(0xFF3DDC97);
  static const warn = Color(0xFFFFB547);
  static const bad = Color(0xFFFF5C7A);

  static const accent = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: TuttiColors.violet,
    brightness: Brightness.dark,
  ).copyWith(
    surface: TuttiColors.surface,
    primary: TuttiColors.violet,
    secondary: TuttiColors.cyan,
    error: TuttiColors.bad,
    onSurface: TuttiColors.text,
    outline: TuttiColors.outline,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: TuttiColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: TuttiColors.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: TuttiColors.text),
    ),
    textTheme: base.textTheme.apply(bodyColor: TuttiColors.text, displayColor: TuttiColors.text),
    cardTheme: CardThemeData(
      color: TuttiColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: TuttiColors.outline),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      trackHeight: 4,
      activeTrackColor: TuttiColors.cyan,
      inactiveTrackColor: TuttiColors.outline,
      thumbColor: TuttiColors.text,
      overlayColor: TuttiColors.cyan.withValues(alpha: 0.15),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: TuttiColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: const DividerThemeData(color: TuttiColors.outline, space: 1),
  );
}
