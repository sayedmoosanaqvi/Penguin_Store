import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Encrypted credential storage using Keychain (iOS), Keystore/EncryptedSharedPrefs
/// (Android), libsecret/DPAPI (Desktop), and Web Crypto API on Flutter Web.
/// Automatically migrates any legacy plain-text `jwt_token` from SharedPreferences.
class SecureStorageService {
  SecureStorageService._();

  static const String _tokenKey = 'jwt_token';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static Future<String?> getToken() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      if (token != null && token.trim().isNotEmpty) {
        return token.trim();
      }
    } catch (e) {
      debugPrint('SecureStorage read error: $e');
    }

    // One-time migration from legacy SharedPreferences storage
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_tokenKey)?.trim();
      if (legacy != null && legacy.isNotEmpty) {
        await setToken(legacy);
        await prefs.remove(_tokenKey);
        return legacy;
      }
    } catch (_) {}

    return null;
  }

  static Future<void> setToken(String token) async {
    final clean = token.trim();
    if (clean.isEmpty) {
      await deleteToken();
      return;
    }
    try {
      await _storage.write(key: _tokenKey, value: clean);
    } catch (e) {
      debugPrint('SecureStorage write error: $e');
    }
    // Ensure no plaintext copy remains in SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
    } catch (_) {}
  }

  static Future<void> deleteToken() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (e) {
      debugPrint('SecureStorage delete error: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
    } catch (_) {}
  }
}
