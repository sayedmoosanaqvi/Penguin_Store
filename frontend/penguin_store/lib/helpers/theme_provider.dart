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

  // Light Theme (WCAG 2.1 AA High-Contrast + Visible Keyboard Focus + 48dp Touch Targets)
  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      focusColor: PRIMARY_BLUE.withValues(alpha: 0.22),
      hoverColor: PRIMARY_BLUE.withValues(alpha: 0.08),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        },
      ),
      brightness: Brightness.light,
      primaryColor: PRIMARY_BLUE,
      scaffoldBackgroundColor: Color(0xFFF5F9FE),
      fontFamily: 'Poppins',
      colorScheme: ColorScheme.light(
        primary: PRIMARY_BLUE,
        secondary: ACCENT_TEAL,
        tertiary: GRADIENT_INDIGO,
        surface: WHITE,
        onSurface: Color(0xFF0F172A),
        onSurfaceVariant: Color(0xFF475569), // 7.5:1 contrast on white
        outline: Color(0xFF64748B),          // >= 3:1 UI component contrast
        outlineVariant: Color(0xFFCBD5E1),
        error: Color(0xFFB91C1C),            // 6.4:1 contrast on white
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: WHITE,
        foregroundColor: PRIMARY_BLUE,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: PRIMARY_BLUE,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(44, 44)),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return PRIMARY_BLUE.withValues(alpha: 0.24);
            }
            return null;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return BorderSide(color: PRIMARY_BLUE, width: 2);
            }
            return null;
          }),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: WHITE,
          backgroundColor: PRIMARY_BLUE,
          minimumSize: Size(48, 44),
          elevation: 4,
          shadowColor: PRIMARY_BLUE.withValues(alpha: 0.4),
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
          foregroundColor: Color(0xFF0D47A1),
          minimumSize: Size(48, 44),
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
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFFAFAFA),
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Color(0xFF94A3B8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Color(0xFFCBD5E1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: PRIMARY_BLUE, width: 2.2),
        ),
        labelStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFF334155), // 9.7:1 contrast
        ),
        hintStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFF475569), // 7.2:1 contrast (WCAG AA >= 4.5:1)
        ),
      ),
      cardTheme: CardThemeData(
        color: WHITE,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withValues(alpha: 0.16), width: 1),
        ),
      ),
    );
  }

  // Dark Theme - WCAG 2.1 AA High-Contrast + Visible Keyboard Focus
  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      focusColor: Color(0xFF38BDF8).withValues(alpha: 0.28),
      hoverColor: Color(0xFF38BDF8).withValues(alpha: 0.10),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        },
      ),
      brightness: Brightness.dark,
      primaryColor: PRIMARY_BLUE,
      scaffoldBackgroundColor: Color(0xFF121212),
      fontFamily: 'Poppins',
      colorScheme: ColorScheme.dark(
        primary: Color(0xFF38BDF8),          // High-contrast icy sky on dark surface
        secondary: ACCENT_TEAL,
        tertiary: GRADIENT_INDIGO,
        surface: Color(0xFF1E1E1E),
        error: Color(0xFFF87171),
        onSurface: Color(0xFFF8FAFC),        // 15.6:1 contrast
        onSurfaceVariant: Color(0xFFCBD5E1), // 10.4:1 contrast (WCAG AAA)
        outline: Color(0xFF94A3B8),          // >= 4.5:1 UI border contrast
        outlineVariant: Color(0xFF334155),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Color(0xFF121212),
        foregroundColor: Color(0xFFF8FAFC),
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF8FAFC),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(44, 44)),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return Color(0xFF38BDF8).withValues(alpha: 0.28);
            }
            return null;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return BorderSide(color: Color(0xFF38BDF8), width: 2);
            }
            return null;
          }),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: WHITE,
          backgroundColor: PRIMARY_BLUE,
          minimumSize: Size(48, 44),
          elevation: 4,
          shadowColor: PRIMARY_BLUE.withValues(alpha: 0.3),
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
          foregroundColor: Color(0xFF38BDF8),
          minimumSize: Size(48, 44),
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
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF1E1E1E),
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Color(0xFF475569)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Color(0xFF38BDF8), width: 2.2),
        ),
        labelStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFFCBD5E1), // 10.4:1 contrast
        ),
        hintStyle: TextStyle(
          fontFamily: 'Poppins',
          color: Color(0xFF94A3B8), // 5.5:1 contrast on #1E1E1E (WCAG AA >= 4.5:1)
        ),
      ),
      cardTheme: CardThemeData(
        color: Color(0xFF1E1E1E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.10), width: 1),
        ),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: Color(0xFFF8FAFC)),
        bodyMedium: TextStyle(color: Color(0xFFE2E8F0)),
        bodySmall: TextStyle(color: Color(0xFFCBD5E1)),
        titleLarge: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.bold),
        titleMedium: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: Color(0xFFE2E8F0)),
      ),
    );
  }
}