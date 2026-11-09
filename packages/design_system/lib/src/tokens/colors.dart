import 'package:flutter/cupertino.dart';

/// Ink on paper. The values are the Madar design system's (paper ground, white cards, a sunk
/// grey, ink text; slate paper and pale-ink in dark). There is no accent colour: the one
/// "primary" is ink itself. Green, amber and red appear only where they mean something (a
/// status dot, a destructive action), never as decoration.
abstract final class GPColors {
  /// The page: paper.
  static const CupertinoDynamicColor background = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF1F3F3),
    darkColor: Color(0xFF0F1A1E),
  );

  /// Cards, cells.
  static const CupertinoDynamicColor surface = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF16252A),
  );

  /// The sunk grey: icon wells, secondary buttons, slider tracks, steppers.
  static const CupertinoDynamicColor fill = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFE4E9EA),
    darkColor: Color(0xFF213238),
  );

  static const CupertinoDynamicColor separator = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFD3DADB),
    darkColor: Color(0xFF2C4048),
  );

  /// Ink: text, glyphs, the filled button, the active switch. The app's only "tint".
  static const CupertinoDynamicColor ink = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF0D1A1E),
    darkColor: Color(0xFFD3DEE1),
  );

  /// Text/glyphs on an ink fill.
  static const CupertinoDynamicColor onInk = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF0D1A1E),
  );

  static const CupertinoDynamicColor label = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF101820),
    darkColor: Color(0xFFEEF3F4),
  );
  static const CupertinoDynamicColor secondaryLabel = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF4F5F66),
    darkColor: Color(0xFFB3C2C7),
  );
  static const CupertinoDynamicColor tertiaryLabel = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF7A8890),
    darkColor: Color(0xFF7E929A),
  );

  // Status — meaning only.
  static const CupertinoDynamicColor good = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF178A4C),
    darkColor: Color(0xFF3BCB7E),
  );
  static const CupertinoDynamicColor warn = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFBF5F07),
    darkColor: Color(0xFFF0A23F),
  );
  static const CupertinoDynamicColor bad = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFD0392C),
    darkColor: Color(0xFFF26B5E),
  );
  static const CupertinoDynamicColor badBg = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFBE3E0),
    darkColor: Color(0xFF3D1C1C),
  );

  /// Resolves for the current brightness.
  static Color of(BuildContext context, CupertinoDynamicColor color) => CupertinoDynamicColor.resolve(color, context);
}

/// Status tone shared by badges, glyphs and sync readouts. Neutral and ink are the default;
/// the coloured three carry state.
enum GPTone { neutral, ink, good, warn, bad }

extension GPToneColor on GPTone {
  CupertinoDynamicColor get color => switch (this) {
        GPTone.neutral => GPColors.secondaryLabel,
        GPTone.ink => GPColors.ink,
        GPTone.good => GPColors.good,
        GPTone.warn => GPColors.warn,
        GPTone.bad => GPColors.bad,
      };
}
