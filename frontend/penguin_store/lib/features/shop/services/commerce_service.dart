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
  final double trustScore;
  final bool isFlaggedSuspicious;
  final List<String> trustFlags;
  final Map<String, String> aspectSentiments;
  final String moderationStatus;
  final DateTime? createdAt;

  const ProductReviewModel({
    required this.id,
    required this.author,
    required this.rating,
    required this.title,
    required this.comment,
    required this.verifiedPurchase,
    this.trustScore = 85.0,
    this.isFlaggedSuspicious = false,
    this.trustFlags = const [],
    this.aspectSentiments = const {},
    this.moderationStatus = 'approved',
    this.createdAt,
  });

  factory ProductReviewModel.fromJson(Map<String, dynamic> j) {
    final rawFlags = j['trust_flags'];
    final flags = rawFlags is List
        ? rawFlags.map((e) => e.toString()).toList()
        : const <String>[];
    final rawAspects = j['aspect_sentiments'];
    final aspects = rawAspects is Map
        ? rawAspects.map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{};

    return ProductReviewModel(
      id: (j['id'] as num?)?.toInt() ?? 0,
      author: (j['author'] ?? 'Customer').toString(),
      rating: (j['rating'] as num?)?.toInt() ?? 5,
      title: (j['title'] ?? '').toString(),
      comment: (j['comment'] ?? '').toString(),
      verifiedPurchase: j['verified_purchase'] == true,
      trustScore: (j['trust_score'] as num?)?.toDouble() ?? 85.0,
      isFlaggedSuspicious: j['is_flagged_suspicious'] == true,
      trustFlags: flags,
      aspectSentiments: aspects,
      moderationStatus: (j['moderation_status'] ?? 'approved').toString(),
      createdAt: j['created_at'] is String
          ? DateTime.tryParse(j['created_at'] as String)
          : null,
    );
  }
}

class ProductReviewsBundle {
  final double averageRating;
  final double trustWeightedRating;
  final int totalReviews;
  final Map<int, int> distribution;
  final List<ProductReviewModel> reviews;

  const ProductReviewsBundle({
    required this.averageRating,
    required this.trustWeightedRating,
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
    final avg = (j['average_rating'] as num?)?.toDouble() ?? 0.0;
    final twAvg = (j['trust_weighted_rating'] as num?)?.toDouble() ?? avg;
    return ProductReviewsBundle(
      averageRating: avg,
      trustWeightedRating: twAvg,
      totalReviews: (j['total_reviews'] as num?)?.toInt() ?? 0,
      distribution: dist,
      reviews: rawList
          .whereType<Map>()
          .map((m) => ProductReviewModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

class ProductReviewInsightsModel {
  final int productId;
  final double rawRating;
  final double trustWeightedRating;
  final int totalReviews;
  final double verifiedAuthenticPercent;
  final int flaggedSuspiciousCount;
  final List<String> pros;
  final List<String> cons;
  final String verdict;
  final Map<String, int> aspectSentimentBars;

  const ProductReviewInsightsModel({
    required this.productId,
    required this.rawRating,
    required this.trustWeightedRating,
    required this.totalReviews,
    required this.verifiedAuthenticPercent,
    required this.flaggedSuspiciousCount,
    required this.pros,
    required this.cons,
    required this.verdict,
    required this.aspectSentimentBars,
  });

  factory ProductReviewInsightsModel.fromJson(Map<String, dynamic> j) {
    final summary = j['summary'] is Map
        ? Map<String, dynamic>.from(j['summary'] as Map)
        : const <String, dynamic>{};
    final rawPros = summary['pros'] is List ? summary['pros'] as List : const [];
    final rawCons = summary['cons'] is List ? summary['cons'] as List : const [];
    final rawBars = j['aspect_sentiment_bars'] is Map
        ? Map<String, dynamic>.from(j['aspect_sentiment_bars'] as Map)
        : const <String, dynamic>{};

    final bars = <String, int>{};
    for (final entry in rawBars.entries) {
      bars[entry.key] = ((entry.value as num?)?.toInt() ?? 85).clamp(0, 100);
    }
    if (bars.isEmpty) {
      bars['Quality'] = 92;
      bars['Value'] = 88;
      bars['Delivery/Experience'] = 90;
      bars['Performance'] = 91;
    }

    return ProductReviewInsightsModel(
      productId: (j['product_id'] as num?)?.toInt() ?? 0,
      rawRating: (j['raw_rating'] as num?)?.toDouble() ?? 4.8,
      trustWeightedRating: (j['trust_weighted_rating'] as num?)?.toDouble() ?? 4.8,
      totalReviews: (j['total_reviews'] as num?)?.toInt() ?? 0,
      verifiedAuthenticPercent:
          (j['verified_authentic_percent'] as num?)?.toDouble() ?? 96.0,
      flaggedSuspiciousCount:
          (j['flagged_suspicious_count'] as num?)?.toInt() ?? 0,
      pros: rawPros.map((e) => e.toString()).toList(),
      cons: rawCons.map((e) => e.toString()).toList(),
      verdict: (summary['verdict'] ?? '').toString(),
      aspectSentimentBars: bars,
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

  Future<ProductReviewInsightsModel> fetchReviewInsights(
    int productId, {
    bool refresh = false,
  }) async {
    final res = await http
        .get(
          Uri.parse(
            '$_base/api/v1/products/$productId/review-insights${refresh ? '?refresh=true' : ''}',
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return ProductReviewInsightsModel.fromJson(
      Map<String, dynamic>.from(jsonDecode(res.body) as Map),
    );
  }

  Future<Map<String, dynamic>> fetchAdminModerationReviews({
    bool flaggedOnly = false,
  }) async {
    final headers = await _authHeaders();
    final res = await http
        .get(
          Uri.parse(
            '$_base/api/v1/admin/reviews/moderation?flagged_only=$flaggedOnly',
          ),
          headers: headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<void> moderateReview({
    required int reviewId,
    required String action,
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    final res = await http
        .put(
          Uri.parse('$_base/api/v1/admin/reviews/$reviewId/moderate'),
          headers: headers,
          body: jsonEncode({'action': action}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
  }

  Future<Map<String, dynamic>> fetchAdminAiMetricsSummary() async {
    final headers = await _authHeaders();
    final res = await http
        .get(
          Uri.parse('$_base/api/v1/admin/ai-metrics/summary'),
          headers: headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<String> fetchAdminAiMetricsCsv() async {
    final headers = await _authHeaders();
    final res = await http
        .get(
          Uri.parse('$_base/api/v1/admin/ai-metrics/export-csv'),
          headers: headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return res.body;
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
        .get(Uri.parse('$_base/api/v1/favorites'), headers: headers)
        .timeout(_timeout);
    if (res.statusCode != 200) return [];
    final decoded = jsonDecode(res.body) as Map;
    final items = decoded['items'] as List? ?? [];
    return items
        .whereType<Map>()
        .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<List<Product>> syncFavorites(List<int> productIds) async {
    final headers = await _authHeaders(jsonBody: true);
    if (!headers.containsKey('Authorization')) return [];
    final res = await http
        .post(
          Uri.parse('$_base/api/v1/favorites/sync'),
          headers: headers,
          body: jsonEncode({'product_ids': productIds}),
        )
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

  // =========================================================================
  // PHASE 4: ALIBABA-STYLE REQUEST FOR QUOTATION (RFQ) B2B ENDPOINTS
  // =========================================================================

  Future<Map<String, dynamic>> submitRfq({
    required int productId,
    required String productName,
    required String customerEmail,
    required String customerName,
    String companyName = '',
    required int quantity,
    required double targetUnitPrice,
    String customizationNotes = '',
    String deliveryDeadline = '',
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    final res = await http
        .post(
          Uri.parse('$_base/api/v1/rfq'),
          headers: headers,
          body: jsonEncode({
            'product_id': productId,
            'product_name': productName,
            'customer_email': customerEmail.trim(),
            'customer_name': customerName.trim(),
            'company_name': companyName.trim(),
            'quantity': quantity,
            'target_unit_price': targetUnitPrice,
            'customization_notes': customizationNotes.trim(),
            'delivery_deadline': deliveryDeadline.trim(),
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 201 && res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<List<Map<String, dynamic>>> fetchMyRfqs({String? email}) async {
    final headers = await _authHeaders();
    final uri = Uri.parse('$_base/api/v1/rfq/my').replace(
      queryParameters: {
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    final res = await http.get(uri, headers: headers).timeout(_timeout);
    if (res.statusCode != 200) return const [];
    final d = jsonDecode(res.body) as Map;
    final items = d['items'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchAdminRfqs({String? statusFilter}) async {
    final headers = await _authHeaders();
    final uri = Uri.parse('$_base/api/v1/admin/rfq').replace(
      queryParameters: {
        if (statusFilter != null && statusFilter.isNotEmpty)
          'status_filter': statusFilter,
      },
    );
    final res = await http.get(uri, headers: headers).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    final d = jsonDecode(res.body) as Map;
    final items = d['items'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchAdminOrders() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_base/api/orders/admin/all'), headers: headers)
        .timeout(_timeout);
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(res.body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    if (decoded is Map && decoded['orders'] is List) {
      return (decoded['orders'] as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const [];
  }

  Future<bool> updateOrderStatus({
    required int orderId,
    required String status,
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    final res = await http
        .put(
          Uri.parse('$_base/api/orders/admin/$orderId/status'),
          headers: headers,
          body: jsonEncode({'status': status}),
        )
        .timeout(_timeout);
    return res.statusCode == 200;
  }

  Future<Map<String, dynamic>> updateAdminRfq({
    required int rfqId,
    required String status,
    double? adminQuotePrice,
    String adminReply = '',
  }) async {
    final headers = await _authHeaders(jsonBody: true);
    final res = await http
        .patch(
          Uri.parse('$_base/api/v1/admin/rfq/$rfqId'),
          headers: headers,
          body: jsonEncode({
            'status': status,
            if (adminQuotePrice != null && adminQuotePrice > 0)
              'admin_quote_price': adminQuotePrice,
            'admin_reply': adminReply.trim(),
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception(ApiErrorHandler.fromStatus(res.statusCode, res.body));
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }
}
