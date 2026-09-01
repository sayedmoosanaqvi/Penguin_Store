// ignore_for_file: prefer_const_constructors

import 'package:penguin_store/helpers/shared_preferences.dart';
import 'package:penguin_store/values/colors.dart';
import 'package:flutter/material.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  ThemeProvider() {
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    String? savedTheme = SharedPreferencesHelper.getString('theme_mode');
    if (savedTheme == 'dark') {
      _themeMode = ThemeMode.dark;
      notifyListeners();
    }
  }

  void toggleTheme() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;

    // Notify listeners immediately for instant UI update
    notifyListeners();

    // Save preference in background (non-blocking)
    SharedPreferencesHelper.setString(
      'theme_mode',
      _themeMode == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  void setTheme(ThemeMode mode) {
    _themeMode = mode;

    // Notify listeners immediately for instant UI update
    notifyListeners();

    // Save preference in background (non-blocking)
    SharedPreferencesHelper.setString(
      'theme_mode',
      mode == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  // Light Theme
  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: PRIMARY_BLUE,
      scaffoldBackgroundColor: WHITE,
      fontFamily: 'Poppins',
      colorScheme: ColorScheme.light(
        primary: PRIMARY_BLUE,
        secondary: ACCENT_TEAL,
        tertiary: GRADIENT_INDIGO,
        surface: WHITE,
        background: BG_GREY,
        error: LIGHT_RED,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: WHITE, // Changed to match the clean look
        foregroundColor: PRIMARY_BLUE, // Dark text/icons on light app bar
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: PRIMARY_BLUE,
        ),
      ),
      // --- UPDATED BUTTON THEMES ---
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: WHITE,
          backgroundColor: PRIMARY_BLUE, // Solid primary color 
          elevation: 4, // Soft floating shadow
          shadowColor: PRIMARY_BLUE.withOpacity(0.4),
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.bold, // Bolder text like the reference
            letterSpacing: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30), // Fully rounded pill shape
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: PRIMARY_BLUE,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      // -----------------------------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFFAFAFA),
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16), // Taller inputs
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16), // Softer corners
          borderSide: BorderSide.none, // Removes harsh line, relies on fill
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.grey.withOpacity(0.1)), 
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: PRIMARY_BLUE, width: 2),
        ),
        labelStyle: TextStyle(
          fontFamily: 'Poppins',
          color: GREY,
        ),
        hintStyle: TextStyle(
          fontFamily: 'Poppins',
          color: GREY.withValues(alpha: 0.6),
        ),
      ),
      cardTheme: CardThemeData(
        color: WHITE,
        elevation: 0, // Flat cards...
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          // ...with soft custom borders instead of heavy elevation shadows
          side: BorderSide(color: Colors.grey.withOpacity(0.1), width: 1), 
        ),
      ),
    );
  }

  // Dark Theme - Eye-friendly colors
  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: PRIMARY_BLUE,
      scaffoldBackgroundColor: Color(0xFF121212), // Deep clean dark
      fontFamily: 'Poppins',
      colorScheme: ColorScheme.dark(
        primary: PRIMARY_BLUE,
        secondary: ACCENT_TEAL,
        tertiary: GRADIENT_INDIGO,
        surface: Color(0xFF1E1E1E), 
        background: Color(0xFF121212),
        error: LIGHT_RED,
        onSurface: Color(0xFFF0F0F0), 
        onBackground: Color(0xFFF0F0F0), 
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Color(0xFF121212), // Matches background
        foregroundColor: Color(0xFFF0F0F0), 
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF0F0F0), 
        ),
      ),
      // --- UPDATED BUTTON THEMES ---
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: WHITE,
          backgroundColor: PRIMARY_BLUE,
          elevation: 4,
          shadowColor: PRIMARY_BLUE.withOpacity(0.3),
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30), 
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ACCENT_TEAL, // Pop of color in dark mode
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      // -----------------------------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF1E1E1E), // Slightly lighter than background
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.05)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: PRIMARY_BLUE, width: 2),
        ),
        labelStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFF909090),
        ),
        hintStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFF707070), 
        ),
      ),
      cardTheme: CardThemeData(
        color: Color(0xFF1E1E1E), 
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.05), width: 1),
        ),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: Color(0xFFF0F0F0)),
        bodyMedium: TextStyle(color: Color(0xFFD0D0D0)),
        bodySmall: TextStyle(color: Color(0xFFA0A0A0)), 
        titleLarge: TextStyle(color: Color(0xFFF0F0F0), fontWeight: FontWeight.bold),
        titleMedium: TextStyle(color: Color(0xFFF0F0F0), fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: Color(0xFFD0D0D0)), 
      ),
    );
  }
}