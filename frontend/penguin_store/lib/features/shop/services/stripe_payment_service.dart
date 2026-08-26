import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class StripePaymentService {
  static const String _baseUrl = 'http://localhost:8000';

  // Updated to accept orderId for secure backend price lookup
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
      // Note: For mobile/native platforms, if you want to use order_id with 
      // PaymentIntent, you would update the backend /create-payment-intent route similarly.
      throw 'Mobile payment sheet requires backend adjustment for order_id lookup.';
    }
  }
}