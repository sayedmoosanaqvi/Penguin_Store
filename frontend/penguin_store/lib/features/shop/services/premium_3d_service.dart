
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';

class Premium3DException implements Exception {
  final String message;
  final int? statusCode;

  const Premium3DException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

class Product3DModel {
  final int id;
  final String displayName;
  final String? variantName;

  const Product3DModel({
    required this.id,
    required this.displayName,
    this.variantName,
  });

  factory Product3DModel.fromJson(Map<String, dynamic> json) {
    return Product3DModel(
      id: (json['id'] as num).toInt(),
      displayName:
          json['display_name']?.toString() ?? '3D Product',
      variantName: json['variant_name']?.toString(),
    );
  }
}

class Product3DAvailability {
  final int productId;
  final bool has3D;
  final List<Product3DModel> models;

  const Product3DAvailability({
    required this.productId,
    required this.has3D,
    required this.models,
  });

  factory Product3DAvailability.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawModels = json['models'] as List? ?? [];

    return Product3DAvailability(
      productId: (json['product_id'] as num).toInt(),
      has3D: json['has_3d'] == true,
      models: rawModels.map((model) {
        return Product3DModel.fromJson(
          Map<String, dynamic>.from(model as Map),
        );
      }).toList(),
    );
  }
}

class Premium3DStatus {
  final bool isPremium;
  final String? planName;
  final String status;
  final DateTime? currentPeriodEnd;

  const Premium3DStatus({
    required this.isPremium,
    required this.planName,
    required this.status,
    required this.currentPeriodEnd,
  });

  factory Premium3DStatus.fromJson(
    Map<String, dynamic> json,
  ) {
    final expiry = json['current_period_end'];

    return Premium3DStatus(
      isPremium: json['is_premium'] == true,
      planName: json['plan_name']?.toString(),
      status: json['status']?.toString() ?? 'inactive',
      currentPeriodEnd: expiry is String
          ? DateTime.tryParse(expiry)
          : null,
    );
  }
}

class Premium3DService {
  static String get baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  static const Duration timeout = Duration(seconds: 25);

  Map<String, String> _authHeaders(String token) {
    if (token.trim().isEmpty) {
      throw const Premium3DException(
        'Please log in to continue.',
        statusCode: 401,
      );
    }

    return {
      'Authorization': 'Bearer ${token.trim()}',
      'Accept': 'application/json',
    };
  }

  Map<String, dynamic> _decodeResponse(
    http.Response response,
  ) {
    dynamic decoded;

    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Premium3DException(
        'Invalid server response.',
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map) {
      throw const Premium3DException(
        'Unexpected response format.',
      );
    }

    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _requireSuccess(
    http.Response response,
  ) {
    if (response.statusCode >= 200 &&
        response.statusCode < 300) {
      return _decodeResponse(response);
    }

    String message = 'Request failed.';

    try {
      final body = _decodeResponse(response);
      final detail = body['detail'];

      if (detail is String) {
        message = detail;
      }
    } catch (_) {}

    if (response.statusCode == 401) {
      message = 'Your session expired. Please log in again.';
    } else if (response.statusCode == 403) {
      message = 'An active Premium subscription is required.';
    }

    throw Premium3DException(
      message,
      statusCode: response.statusCode,
    );
  }

  // Check whether a product has an active 3D model.
  Future<Product3DAvailability> getAvailability(
    int productId,
  ) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/api/premium-3d/products/$productId',
      ),
      headers: {
        'Accept': 'application/json',
      },
    ).timeout(timeout);

    final data = _requireSuccess(response);

    return Product3DAvailability.fromJson(data);
  }

  // Check Premium entitlement through FastAPI.
  Future<Premium3DStatus> getMyStatus(
    String accessToken,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/premium-3d/me'),
      headers: _authHeaders(accessToken),
    ).timeout(timeout);

    final data = _requireSuccess(response);

    return Premium3DStatus.fromJson(data);
  }

  // Request a private Supabase signed model URL.
  Future<String> getModelUrl({
    required int productId,
    required int modelId,
    required String accessToken,
  }) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/api/premium-3d/products/'
        '$productId/models/$modelId/view',
      ),
      headers: _authHeaders(accessToken),
    ).timeout(timeout);

    final data = _requireSuccess(response);
    final modelUrl = data['model_url'];

    if (modelUrl is! String || modelUrl.isEmpty) {
      throw const Premium3DException(
        'The 3D model URL is unavailable.',
      );
    }

    final uri = Uri.tryParse(modelUrl);

    if (uri == null || uri.scheme != 'https') {
      throw const Premium3DException(
        'Invalid 3D model URL.',
      );
    }

    return modelUrl;
  }
}
