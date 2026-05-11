import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isAdmin = false;
  String? _token;
  String? _userEmail;

  bool get isAuthenticated => _isAuthenticated;
  bool get isAdmin => _isAdmin;
  String? get userEmail => _userEmail;
  String? get token => _token;

  // Since you are running on Web (Edge), 127.0.0.1 is correct!
  // If you switch to an Android Emulator later, change this to 'http://10.0.2.2:8000'
  final String _baseUrl = 'http://127.0.0.1:8000';

  // --- AUTO LOG IN ON APP START ---
  Future<void> tryAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    
    if (!prefs.containsKey('jwt_token')) return;

    final extractedToken = prefs.getString('jwt_token');

    // Check if token is broken or expired (e.g., older than 7 days)
    if (extractedToken == null || JwtDecoder.isExpired(extractedToken)) {
      await logout();
      return;
    }

    // Token is valid! Restore the user's session
    _token = extractedToken;
    Map<String, dynamic> decodedToken = JwtDecoder.decode(_token!);
    _userEmail = decodedToken['sub'];
    _isAdmin = decodedToken['is_admin'] ?? false;
    _isAuthenticated = true;

    notifyListeners();
  }

  // --- SIGN UP ---
  Future<bool> signup(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/signup'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password}),
      );

      return response.statusCode == 201;
    } catch (e) {
      debugPrint("Signup Error: $e");
      return false;
    }
  }

  // --- LOG IN ---
  Future<bool> login(String email, String password) async {
    try {
      // OAuth2 requires form-urlencoded format
      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'username': email, 'password': password},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _token = data['access_token'];

        // Decode token to get user role
        Map<String, dynamic> decodedToken = JwtDecoder.decode(_token!);
        _userEmail = decodedToken['sub'];
        _isAdmin = decodedToken['is_admin'] ?? false;
        _isAuthenticated = true;

        // Save to hard drive for Auto-Login later
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('jwt_token', _token!);

        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("Login Error: $e");
      return false;
    }
  }

  // --- LOG OUT ---
  Future<void> logout() async {
    _isAuthenticated = false;
    _isAdmin = false;
    _userEmail = null;
    _token = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');

    notifyListeners();
  }
}