import 'package:flutter/material.dart';

/// Calm, data-first palette. Metric accents are shared by cards and charts.
class AppColors {
  static const seed = Color(0xFF2F6F62);
  static const sleep = Color(0xFF5B6CD9);
  static const heart = Color(0xFFD9534F);
  static const activity = Color(0xFF2E9E6A);
  static const points = Color(0xFFE0A030);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, centerTitle: false),
  );
}
