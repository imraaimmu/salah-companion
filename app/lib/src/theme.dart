import 'package:flutter/material.dart';

/// Dark, calm palette. Pure black is reserved for the prayer screen
/// (OLED pixels off); other screens use a deep navy.
abstract final class AppColors {
  static const background = Color(0xFF0B1220);
  static const surface = Color(0xFF141C2E);
  static const accent = Color(0xFFE8D9A8);
  static const textPrimary = Color(0xFFF2F4F8);
  static const textQuiet = Color(0xFF8B95A8);
  static const prayerBlack = Color(0xFF000000);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
    surface: AppColors.background,
    primary: AppColors.accent,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: const TextTheme(
      titleLarge: TextStyle(color: AppColors.textPrimary),
      bodyMedium: TextStyle(color: AppColors.textQuiet),
    ),
  );
}
