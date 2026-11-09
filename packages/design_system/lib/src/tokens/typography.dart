import 'package:flutter/widgets.dart';

/// Madar's type: IBM Plex Sans (Arabic cut; it carries Latin) for words, IBM Plex Mono for every
/// figure. Sizes follow the Madar scale (28 / 22 / 18 / 16 / 15 / 13 / 12) with a large title on
/// top for the collapsing navigation bar.
abstract final class GPText {
  static const String family = 'IBMPlexSansArabic';
  static const String monoFamily = 'IBMPlexMono';
  static const String package = 'design_system';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static const TextStyle largeTitle = TextStyle(fontFamily: family, package: package, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -0.6, height: 1.1);
  static const TextStyle title1 = TextStyle(fontFamily: family, package: package, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.1);
  static const TextStyle title2 = TextStyle(fontFamily: family, package: package, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.2, height: 1.15);
  static const TextStyle title3 = TextStyle(fontFamily: family, package: package, fontSize: 18, fontWeight: FontWeight.w600, height: 1.25);

  /// A row's title / emphasised line.
  static const TextStyle headline = TextStyle(fontFamily: family, package: package, fontSize: 16, fontWeight: FontWeight.w600, height: 1.3);

  /// Default body text.
  static const TextStyle body = TextStyle(fontFamily: family, package: package, fontSize: 15, fontWeight: FontWeight.w500, height: 1.35);

  /// A row's second line, help text.
  static const TextStyle subheadline = TextStyle(fontFamily: family, package: package, fontSize: 13, fontWeight: FontWeight.w500, height: 1.38);
  static const TextStyle footnote = TextStyle(fontFamily: family, package: package, fontSize: 13, fontWeight: FontWeight.w400, height: 1.38);

  /// Uppercase section labels (pair with [tracking]).
  static const TextStyle label = TextStyle(fontFamily: family, package: package, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: tracking);
  static const TextStyle caption1 = TextStyle(fontFamily: family, package: package, fontSize: 12, fontWeight: FontWeight.w600, height: 1.3);

  /// A button's word.
  static const TextStyle button = TextStyle(fontFamily: family, package: package, fontSize: 16, fontWeight: FontWeight.w700);

  static const double tracking = 0.8;

  // Figures — Plex Mono, tabular: ms, ppm, counts, codes.
  static const TextStyle num = TextStyle(fontFamily: monoFamily, package: package, fontSize: 13, fontWeight: FontWeight.w600, fontFeatures: tabular);
  static const TextStyle numMd = TextStyle(fontFamily: monoFamily, package: package, fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: tabular);
  static const TextStyle numXl = TextStyle(fontFamily: monoFamily, package: package, fontSize: 30, fontWeight: FontWeight.w700, fontFeatures: tabular, letterSpacing: -0.5);
  static const TextStyle mono = TextStyle(fontFamily: monoFamily, package: package, fontSize: 12, fontWeight: FontWeight.w500, height: 1.4);
}
