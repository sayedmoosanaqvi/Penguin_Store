
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:penguin_store/config/api_config.dart';

class StripePaymentService {
  static String get _baseUrl => ApiConfig.baseUrl;

  static Future<void> startCheckout({
    required int orderId,
    required String currency,
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError(
        'Mobile checkout requires a separate payment integration.',
      );
    }

    final response = await http.post(
      Uri.parse('$_baseUrl/create-checkout-session'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'order_id': orderId,
        'currency': currency,
        'frontend_origin': Uri.base.origin,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Checkout session failed: ${response.body}',
      );
    }

    final data = jsonDecode(response.body);

    if (data is! Map || data['url'] is! String) {
      throw Exception(
        'Invalid Stripe checkout response.',
      );
    }

    final checkoutUrl = data['url'] as String;
    final uri = Uri.tryParse(checkoutUrl);

    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'checkout.stripe.com' ||
            uri.host.endsWith('.checkout.stripe.com'))) {
      throw Exception(
        'Invalid Stripe Checkout URL.',
      );
    }

    final launched = await launchUrl(
      uri,
      webOnlyWindowName: '_self',
    );

    if (!launched) {
      throw Exception(
        'Unable to open Stripe Checkout.',
      );
    }
  }
}
