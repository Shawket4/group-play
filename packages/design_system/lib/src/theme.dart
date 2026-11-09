import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';

/// The app theme: paper ground, ink everything. Brightness follows the system.
CupertinoThemeData buildGPTheme() => CupertinoThemeData(
      primaryColor: GPColors.ink,
      primaryContrastingColor: GPColors.onInk,
      scaffoldBackgroundColor: GPColors.background,
      barBackgroundColor: GPColors.background,
      textTheme: CupertinoTextThemeData(
        primaryColor: GPColors.ink,
        textStyle: GPText.body.copyWith(color: GPColors.label),
        actionTextStyle: GPText.body.copyWith(color: GPColors.ink),
        navTitleTextStyle: GPText.headline.copyWith(color: GPColors.label),
        navLargeTitleTextStyle: GPText.largeTitle.copyWith(color: GPColors.label),
        navActionTextStyle: GPText.body.copyWith(color: GPColors.ink),
      ),
    );
