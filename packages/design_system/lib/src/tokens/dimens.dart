/// Spacing on a 4-pt rhythm, radii and touch sizes from the HIG.
abstract final class GPSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Inset-grouped page margin.
  static const double page = 20;
}

abstract final class GPRadius {
  /// Inset grouped sections, cards.
  static const double card = 10;

  /// Large action cards, the QR plate.
  static const double large = 16;

  /// Settings-style icon tiles (29 pt square).
  static const double tile = 7;

  /// Buttons.
  static const double button = 14;
}

abstract final class GPSize {
  /// Minimum touch target (44 × 44 pt).
  static const double minTap = 44;

  /// Settings-style icon tile.
  static const double tile = 29;

  /// Filled button height.
  static const double button = 54;
}
