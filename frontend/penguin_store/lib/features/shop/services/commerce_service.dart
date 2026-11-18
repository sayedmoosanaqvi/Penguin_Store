import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';

class ProductReviewModel {
  final int id;
  final String author;
  final int rating;
  final String title;
  final String comment;
  final bool verifiedPurchase;
  final DateTime? createdAt;

  const ProductReviewModel({
    required this.id,
    required this.author,
    required this.rating,
    required this.title,
    required this.comment,
    required this.verifiedPurchase,
    this.createdAt,
  });

  factory ProductReviewModel.fromJson(Map<String, dynamic> j) => ProductReviewModel(
        id: (j['id'] as num?)?.toInt() ?? 0,
        author: (j['author'] ?? 'Customer').toString(),
        rating: (j['rating'] as num?)?.toInt() ?? 5,
        title: (j['title'] ?? '').toString(),
        comment: (j['comment'] ?? '').toString(),
        verifiedPurchase: j['verified_purchase'] == true,
        createdAt: j['created_at'] is String
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
      );
}

class ProductReviewsBundle {
  final double averageRating;
  final int totalReviews;
  final Map<int, int> distribution;
  final List<ProductReviewModel> reviews;

  const ProductReviewsBundle({
    required this.averageRating,
    required this.totalReviews,
    required this.distribution,
    required this.reviews,
  });

  factory ProductReviewsBundle.fromJson(Map<String, dynamic> j) {
    final rawDist = j['distribution'] as Map? ?? const {};
    final dist = <int, int>{5: 0, 4: 0, 3: 0, 2: 0, 1: 0};
    for (final k in dist.keys) {
      dist[k] = (rawDist['$k'] as num?)?.toInt() ?? 0;
    }
    final rawList = j['reviews'] as List? ?? const [];
    return ProductReviewsBundle(
      averageRating: (j['average_rating'] as num?)?.toDouble() ?? 0.0,
      totalReviews: (j['total_reviews'] as num?)?.toInt() ?? 0,
      distribution: dist,
      reviews: rawList
          .whereType<Map>()
          .map((m) => ProductReviewModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

class SavedAddress {
  final int id;
  final String label;
  final String recipientName;
  final String phone;
  final String streetAddress;
  final String city;
  final String stateProvince;
  final String country;
  final String postalCode;
  final bool isDefault;

  const SavedAddress({
    required this.id,
    required this.label,
    required this.recipientName,
    required this.phone,
    required this.streetAddress,
    required this.city,
    required this.stateProvince,
    required this.country,
    required this.postalCode,
    required this.isDefault,
  });

  factory SavedAddress.fromJson(Map<String, dynamic> j) => SavedAddress(
        id: (j['id'] as num?)?.toInt() ?? 0,
        label: (j['label'] ?? 'Home').toString(),
        recipientName: (j['recipient_name'] ?? '').toString(),
        phone: (j['phone'] ?? '').toString(),
        streetAddress: (j['street_address'] ?? '').toString(),
        city: (j['city'] ?? '').toString(),
        stateProvince: (j['state_province'] ?? 'Punjab').toString(),
        country: (j['country'] ?? 'Pakistan').toString(),
        postalCode: (j['postal_code'] ?? '').toString(),
        isDefault: j['is_default'] == true,
      );
}

class CommerceService {
  static String get _base => ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
  static const Duration _timeout = Duration(seconds: 25);

  Future<Map<String, String>> _authHeaders({bool jsonBody = false}) async {
    final token = (await SecureStorageService.getToken())?.trim() ?? '';
    return {
      'Accept': 'application/json',
      if (jsonBody) 'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<ProductReviewsBundle> fetchReviews(int productId) async {
    final res = await http
        .get(
          Uri.parse('$_base/api/v1/products/$productId/reviews'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return ProductReviewsBundle.fromJson(
      Map<String, dynamic>.from(jsonDecode(res.body) as Map),
    );
  }

  Future<void> submitReview({
    required int productId,
    required int rating,
    required String title,
    required String comment,
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    if (!headers.containsKey('Authorization')) {
      throw Exception('Please log in to write a review.');
    }
    final res = await http
        .post(
          Uri.parse('$_base/api/v1/products/$productId/reviews'),
          headers: headers,
          body: jsonEncode({
            'rating': rating,
            if (title.trim().isNotEmpty) 'title': title.trim(),
            'comment': comment.trim(),
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 201) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
  }

  Future<List<Product>> fetchWishlist() async {
    final headers = await _authHeaders();
    if (!headers.containsKey('Authorization')) return [];
    final res = await http
        .get(Uri.parse('$_base/api/v1/wishlist/'), headers: headers)
        .timeout(_timeout);
    if (res.statusCode != 200) return [];
    final decoded = jsonDecode(res.body) as Map;
    final items = decoded['items'] as List? ?? [];
    return items
        .whereType<Map>()
        .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<bool?> toggleWishlist(int productId) async {
    final headers = await _authHeaders(jsonBody: true);
    if (!headers.containsKey('Authorization')) return null;
    final res = await http
        .post(
          Uri.parse('$_base/api/v1/wishlist/toggle'),
          headers: headers,
          body: jsonEncode({'product_id': productId}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(res.body) as Map;
    return decoded['wishlisted'] == true;
  }

  Future<void> recordRecentlyViewed(int productId) async {
    try {
      final headers = await _authHeaders();
      if (!headers.containsKey('Authorization')) return;
      await http
          .post(
            Uri.parse('$_base/api/v1/recently-viewed/$productId'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Recently viewed sync skipped: $e');
    }
  }

  Future<List<SavedAddress>> fetchAddresses() async {
    final headers = await _authHeaders();
    if (!headers.containsKey('Authorization')) return [];
    final res = await http
        .get(Uri.parse('$_base/api/v1/addresses/'), headers: headers)
        .timeout(_timeout);
    if (res.statusCode != 200) return [];
    final decoded = jsonDecode(res.body) as Map;
    final raw = decoded['addresses'] as List? ?? [];
    return raw
        .whereType<Map>()
        .map((m) => SavedAddress.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<SavedAddress> saveAddress({
    required String label,
    required String recipientName,
    required String phone,
    required String streetAddress,
    required String city,
    required String stateProvince,
    required String country,
    required String postalCode,
    bool isDefault = true,
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    if (!headers.containsKey('Authorization')) {
      throw Exception('Please log in to save shipping addresses.');
    }
    final res = await http
        .post(
          Uri.parse('$_base/api/v1/addresses/'),
          headers: headers,
          body: jsonEncode({
            'label': label,
            'recipient_name': recipientName,
            'phone': phone,
            'street_address': streetAddress,
            'city': city,
            'state_province': stateProvince,
            'country': country,
            'postal_code': postalCode,
            'is_default': isDefault,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 201) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return SavedAddress.fromJson(
      Map<String, dynamic>.from(jsonDecode(res.body) as Map),
    );
  }

  Future<void> deleteAddress(int addressId) async {
    final headers = await _authHeaders();
    final res = await http
        .delete(
          Uri.parse('$_base/api/v1/addresses/$addressId'),
          headers: headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
  }

  Future<int> checkSmartNotifications() async {
    try {
      final headers = await _authHeaders();
      if (!headers.containsKey('Authorization')) return 0;
      final res = await http
          .post(
            Uri.parse('$_base/api/v1/notifications/check-smart'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0;
      final d = jsonDecode(res.body) as Map;
      return (d['created_notifications'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> fetchUnreadNotificationCount(String email) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty) return 0;
    try {
      final headers = await _authHeaders();
      if (!headers.containsKey('Authorization')) return 0;
      final res = await http
          .get(
            Uri.parse('$_base/api/notifications/${Uri.encodeComponent(clean)}'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0;
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return 0;
      return decoded
          .whereType<Map>()
          .where((m) => m['is_read'] != true)
          .length;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> markAllNotificationsRead() async {
    try {
      final headers = await _authHeaders();
      if (!headers.containsKey('Authorization')) return false;
      final res = await http
          .put(
            Uri.parse('$_base/api/notifications/read-all'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
