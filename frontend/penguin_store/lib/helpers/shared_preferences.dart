import 'package:shared_preferences/shared_preferences.dart';

class SharedPreferencesHelper {
  static SharedPreferences? _prefs;

  // Initializes the preferences (we will call this in main.dart later)
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Gets the saved theme string
  static String? getString(String key) {
    return _prefs?.getString(key);
  }

  // Saves the theme string
  static Future<bool> setString(String key, String value) async {
    if (_prefs == null) return false;
    return await _prefs!.setString(key, value);
  }
}