
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';

class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isAdmin = false;
  String _role = 'customer';
  bool _isInitializing = true;
  bool _isLoading = false;

  String? _token;
  String? _userEmail;
  String? _errorMessage;

  int _authRevision = 0;

  static const Duration _timeout = Duration(seconds: 25);

  bool get isAuthenticated => _isAuthenticated;
  bool get isAdmin => _isAdmin;
  String get role => _role;
  bool get isInitializing => _isInitializing;
  bool get isLoading => _isLoading;

  String? get userEmail => _userEmail;
  String? get token => _token;
  String? get errorMessage => _errorMessage;

  String get _baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  void _clearSession() {
    _isAuthenticated = false;
    _isAdmin = false;
    _role = 'customer';
    _token = null;
    _userEmail = null;
  }

  bool _applyVerifiedSession(
    String token,
    Map<String, dynamic> profile,
  ) {
    final email = profile['email'];
    final isAdmin = profile['is_admin'];
    final rawRole = profile['role']?.toString().trim().toLowerCase();

    if (email is! String ||
        email.trim().isEmpty ||
        isAdmin is! bool) {
      return false;
    }

    _token = token;
    _userEmail = email;
    _isAdmin = isAdmin || rawRole == 'admin';
    _role = (rawRole != null && rawRole.isNotEmpty)
        ? rawRole
        : (_isAdmin ? 'admin' : 'customer');
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
      final savedToken = await SecureStorageService.getToken();

      if (revision != _authRevision) return;

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
        await SecureStorageService.deleteToken();

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

        await SecureStorageService.deleteToken();
        _clearSession();
        return;
      }

      if (response.statusCode == 401 ||
          response.statusCode == 403) {
        await SecureStorageService.deleteToken();
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
      _errorMessage = ApiErrorHandler.sanitize(
        e,
        fallback: 'Unable to connect to the server. Please try again.',
      );

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

      if (profile == null) {
        _errorMessage =
            'The server returned an invalid user profile.';
        return false;
      }

      await SecureStorageService.setToken(accessToken);

      if (revision != _authRevision) {
        await SecureStorageService.deleteToken();
        return false;
      }

      if (!_applyVerifiedSession(
        accessToken,
        profile,
      )) {
        await SecureStorageService.deleteToken();
        _errorMessage =
            'The server returned an invalid user profile.';
        return false;
      }

      _errorMessage = null;
      return true;
    } catch (e) {
      if (revision != _authRevision) return false;

      _errorMessage = ApiErrorHandler.sanitize(
        e,
        fallback: 'Unable to connect to the server. Please try again.',
      );

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

    await SecureStorageService.deleteToken();
  }

  /// Google Play Store compliance: permanently delete user account after password check.
  Future<String?> deleteAccount(String password) async {
    final token = _token ?? await SecureStorageService.getToken();
    if (token == null || token.isEmpty) {
      return 'You must be logged in to delete your account.';
    }
    try {
      final response = await http
          .delete(
            Uri.parse('$_baseUrl/api/v1/auth/me'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'password': password}),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        await logout();
        return null;
      }
      return ApiErrorHandler.fromStatus(
        response.statusCode,
        response.body,
        fallback: 'Unable to delete account.',
      );
    } catch (e) {
      return ApiErrorHandler.sanitize(e);
    }
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
