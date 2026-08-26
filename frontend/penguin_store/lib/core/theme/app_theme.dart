import 'package:flutter/material.dart';
import 'app_colors.dart';

ThemeData darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: AppColors.background,

  colorScheme: const ColorScheme.dark(
    primary: AppColors.primary,
    secondary: AppColors.glow,
    surface: AppColors.card,
  ),

  appBarTheme: const AppBarTheme(
    backgroundColor: AppColors.background,
    elevation: 0,
  ),

  cardColor: AppColors.card,

  textTheme: const TextTheme(
    bodyLarge: TextStyle(color: AppColors.whiteText),
    bodyMedium: TextStyle(color: AppColors.greyText),
  ),
);