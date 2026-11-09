import 'package:flutter/services.dart';

/// Haptics with HIG meanings.
abstract final class GPHaptics {
  /// A selection changed (slider step, toggle, segment).
  static Future<void> selection() => HapticFeedback.selectionClick();

  /// Something started (host, join, play).
  static Future<void> success() => HapticFeedback.mediumImpact();

  /// Something failed or needs attention.
  static Future<void> warning() => HapticFeedback.heavyImpact();
}
