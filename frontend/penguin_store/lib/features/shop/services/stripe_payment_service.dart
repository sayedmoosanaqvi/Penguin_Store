import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:penguin_store/config/api_config.dart';

class StripePaymentService {
  static String get _baseUrl => ApiConfig.baseUrl;

  static Future<void> startCheckout({
    required int orderId,
    required String currency,
  }) async {
    if (kIsWeb) {
      final response = await http.post(
        Uri.parse('$_baseUrl/create-checkout-session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'order_id': orderId,
          'currency': currency,
        }),
      );

      if (response.statusCode != 200) {
        throw 'Checkout session failed: ${response.body}';
      }

      final data = jsonDecode(response.body);
      final url = data['url'];

      if (url == null) {
        throw 'Checkout session response missing "url": ${response.body}';
      }

      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw 'Could not open Stripe Checkout';
      }
    } else {
      throw 'Mobile payment sheet requires backend adjustment for order_id lookup.';
    }
  }
}