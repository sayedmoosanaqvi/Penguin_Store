import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
 // Import your config to use the correct IP

class AnalyticsService {
  static Future<void> trackUserAction(String action, dynamic details) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/track'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'action': action,
          'details': details,
          'timestamp': DateTime.now().toIso8601String(),
          'device': 'Pixel 7a', // Useful for debugging
        }),
      );

      if (response.statusCode == 200) {
        print("Agent Tracking: Success ($action)");
      }
    } catch (e) {
      print("Agent Tracking Error: $e");
    }
  }
}