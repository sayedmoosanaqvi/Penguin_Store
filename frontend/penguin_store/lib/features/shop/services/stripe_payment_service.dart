import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'package:penguin_store/config/api_config.dart';

class StripePaymentService {
  static String get _baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  /// Resolves the current frontend origin + base-href path (e.g. `/Penguin_Store` on GitHub Pages)
  /// so Stripe redirects back to the exact app URL.
  static String _resolveFrontendOrigin() {
    if (!kIsWeb) return 'http://localhost:8080';
    final origin = Uri.base.origin;
    final path = Uri.base.path.replaceAll(RegExp(r'/$'), '');
    if (path.isNotEmpty && path != '/') {
      return '$origin$path';
    }
    return origin;
  }

  /// Creates a Stripe Checkout Session for [orderId] and redirects the browser
  /// (or opens the external browser on mobile) to Stripe's hosted payment page.
  static Future<void> startCheckout({
    required int orderId,
    String currency = 'usd',
  }) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/api/v1/stripe/create-checkout-session'),
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'order_id': orderId,
            'currency': currency,
            'frontend_origin': _resolveFrontendOrigin(),
          }),
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      String detail = 'Unable to create Stripe Checkout Session.';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['detail'] is String) {
          detail = decoded['detail'] as String;
        }
      } catch (_) {}
      throw Exception(detail);
    }

    final data = jsonDecode(response.body);
    if (data is! Map) {
      throw Exception('Invalid Stripe checkout response.');
    }

    final checkoutUrl =
        (data['checkout_url'] ?? data['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(checkoutUrl);

    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'checkout.stripe.com' ||
            uri.host.endsWith('.checkout.stripe.com'))) {
      throw Exception('Invalid Stripe Checkout URL.');
    }

    final launched = await launchUrl(
      uri,
      mode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      webOnlyWindowName: '_self',
    );

    if (!launched) {
      throw Exception('Unable to open Stripe Checkout.');
    }
  }

  /// Calls the backend to verify a completed Stripe Checkout Session,
  /// triggering idempotent order fulfillment, stock deduction, and email confirmation.
  static Future<Map<String, dynamic>> verifyCheckoutSession({
    required String sessionId,
    int? orderId,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/api/v1/stripe/verify-session/${Uri.encodeComponent(sessionId)}'
      '${orderId != null ? '?order_id=$orderId' : ''}',
    );
    final res = await http
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 25));

    if (res.statusCode != 200) {
      throw Exception('Unable to verify Stripe payment session.');
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  /// Fetches an order record directly by ID (used for COD confirmation or fallback).
  static Future<Map<String, dynamic>?> fetchOrderDetail(int orderId) async {
    try {
      final res = await http
          .get(
            Uri.parse('$_baseUrl/api/orders/detail/$orderId'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map && data['order'] is Map) {
        return Map<String, dynamic>.from(data['order'] as Map);
      }
    } catch (_) {}
    return null;
  }
}
