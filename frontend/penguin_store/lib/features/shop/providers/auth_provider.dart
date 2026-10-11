
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:penguin_store/config/api_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isAdmin = false;
  bool _isInitializing = true;
  bool _isLoading = false;

  String? _token;
  String? _userEmail;
  String? _errorMessage;

  int _authRevision = 0;

  static const String _tokenStorageKey = 'jwt_token';
  static const Duration _timeout = Duration(seconds: 20);

  bool get isAuthenticated => _isAuthenticated;
  bool get isAdmin => _isAdmin;
  bool get isInitializing => _isInitializing;
  bool get isLoading => _isLoading;

  String? get userEmail => _userEmail;
  String? get token => _token;
  String? get errorMessage => _errorMessage;

  String get _baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  // Clear the local authentication state.
  void _clearSession() {
    _isAuthenticated = false;
    _isAdmin = false;
    _token = null;
    _userEmail = null;
  }

  // Validate the authenticated profile returned by FastAPI.
  bool _applyVerifiedSession(
    String token,
    Map<String, dynamic> profile,
  ) {
    final email = profile['email'];
    final isAdmin = profile['is_admin'];

    if (email is! String ||
        email.trim().isEmpty ||
        isAdmin is! bool) {
      return false;
    }

    _token = token;
    _userEmail = email;
    _isAdmin = isAdmin;
    _isAuthenticated = true;

    notifyListeners();
    return true;
  }

  // Check the JWT against the actual backend.
  Future<http.Response> _verifyWithBackend(
    String token,
  ) {
    return http.get(
      Uri.parse('$_baseUrl/auth/me'),
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    ).timeout(_timeout);
  }

  // Safely decode API responses.
  Map<String, dynamic>? _decodeJson(
    String responseBody,
  ) {
    try {
      final decoded = jsonDecode(responseBody);

      if (decoded is Map<String, dynamic>) {
        return decoded;
      }

      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  String _getApiError(
    http.Response response,
    String fallback,
  ) {
    final body = _decodeJson(response.body);
    final detail = body?['detail'];

    if (detail is String && detail.isNotEmpty) {
      return detail;
    }

    return fallback;
  }

  // Restore a saved session only after backend verification.
  Future<void> tryAutoLogin() async {
    final revision = ++_authRevision;

    _isInitializing = true;
    _errorMessage = null;

    try {
      final prefs = await SharedPreferences.getInstance();

      if (revision != _authRevision) return;

      final savedToken = prefs.getString(
        _tokenStorageKey,
      );

      if (savedToken == null || savedToken.isEmpty) {
        _clearSession();
        return;
      }

      bool expired;

      try {
        expired = JwtDecoder.isExpired(savedToken);
      } catch (_) {
        expired = true;
      }

      if (expired) {
        await prefs.remove(_tokenStorageKey);

        if (revision == _authRevision) {
          _clearSession();
        }

        return;
      }

      final response = await _verifyWithBackend(
        savedToken,
      );

      if (revision != _authRevision) return;

      if (response.statusCode == 200) {
        final profile = _decodeJson(response.body);

        if (profile != null &&
            _applyVerifiedSession(
              savedToken,
              profile,
            )) {
          return;
        }

        await prefs.remove(_tokenStorageKey);
        _clearSession();
        return;
      }

      if (response.statusCode == 401 ||
          response.statusCode == 403) {
        await prefs.remove(_tokenStorageKey);
        _clearSession();

        _errorMessage =
            'Your previous session expired. Please log in again.';
        return;
      }

      _clearSession();
      _errorMessage =
          'Could not verify your session. Please retry.';
    } catch (e) {
      if (revision != _authRevision) return;

      _clearSession();
      _errorMessage =
          'Unable to connect to the server. Please try again.';

      debugPrint('Auto-login verification error: $e');
    } finally {
      if (revision == _authRevision) {
        _isInitializing = false;
        notifyListeners();
      }
    }
  }

  // Create a regular customer account.
  Future<bool> signup(
    String email,
    String password,
  ) async {
    _errorMessage = null;

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/signup'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email.trim().toLowerCase(),
          'password': password,
        }),
      ).timeout(_timeout);

      if (response.statusCode == 201) {
        return true;
      }

      _errorMessage = _getApiError(
        response,
        'Account registration failed.',
      );

      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage =
          'Unable to connect to the server.';

      debugPrint('Signup error: $e');
      notifyListeners();
      return false;
    }
  }

  // Log in and verify the token against FastAPI.
  Future<bool> login(
    String email,
    String password,
  ) async {
    if (_isLoading) return false;

    final revision = ++_authRevision;

    _isLoading = true;
    _isInitializing = false;
    _errorMessage = null;

    notifyListeners();

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {
          'Content-Type':
              'application/x-www-form-urlencoded',
        },
        body: {
          'username': email.trim().toLowerCase(),
          'password': password,
        },
      ).timeout(_timeout);

      if (revision != _authRevision) return false;

      if (response.statusCode != 200) {
        _errorMessage = _getApiError(
          response,
          'Incorrect email or password.',
        );

        return false;
      }

      final body = _decodeJson(response.body);
      final accessToken = body?['access_token'];

      if (accessToken is! String ||
          accessToken.isEmpty) {
        _errorMessage =
            'The server returned an invalid login response.';
        return false;
      }

      final profileResponse = await _verifyWithBackend(
        accessToken,
      );

      if (revision != _authRevision) return false;

      if (profileResponse.statusCode != 200) {
        _errorMessage =
            'Your login could not be verified.';
        return false;
      }

      final profile = _decodeJson(
        profileResponse.body,
      );

      if (profile == null ||
          !_applyVerifiedSession(
            accessToken,
            profile,
          )) {
        _errorMessage =
            'The server returned an invalid user profile.';
        return false;
      }

      final prefs = await SharedPreferences.getInstance();

      if (revision != _authRevision) return false;

      await prefs.setString(
        _tokenStorageKey,
        accessToken,
      );

      if (revision != _authRevision) {
        await prefs.remove(_tokenStorageKey);
        return false;
      }

      _errorMessage = null;
      return true;
    } catch (e) {
      if (revision != _authRevision) return false;

      _errorMessage =
          'Unable to connect to the server. Please try again.';

      debugPrint('Login error: $e');
      return false;
    } finally {
      if (revision == _authRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  // Sign out and remove saved credentials.
  Future<void> logout() async {
    ++_authRevision;

    _clearSession();
    _errorMessage = null;
    _isLoading = false;
    _isInitializing = false;

    notifyListeners();

    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(
      _tokenStorageKey,
    );
  }

  // Manually revalidate the current saved session.
  Future<bool> refreshSession() async {
    await tryAutoLogin();
    return _isAuthenticated;
  }

  // Clear error text after it has been displayed.
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
