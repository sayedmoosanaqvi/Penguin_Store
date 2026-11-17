import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';

/// A product that owns at least one active 3D model.
class Showcase3DItem {
  final Product product;
  final List<Product3DModel> models;

  const Showcase3DItem({required this.product, required this.models});

  factory Showcase3DItem.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'] as List? ?? const [];
    return Showcase3DItem(
      product: Product.fromJson(json),
      models: rawModels
          .whereType<Map>()
          .map((m) => Product3DModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

/// App-wide cache of which products have 3D models. Drives the "3D" filter
/// chips and the pulsing 3D badge on product cards.
class Catalog3D {
  Catalog3D._();

  static final ValueNotifier<Set<int>> ids = ValueNotifier<Set<int>>({});
  static DateTime? _lastFetch;
  static Future<void>? _inflight;

  static bool has(int productId) => ids.value.contains(productId);

  static Future<void> refresh({bool force = false}) {
    final fresh = _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < const Duration(minutes: 2);

    if (!force && fresh) return Future.value();
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  static Future<void> _load() async {
    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final response = await http
          .get(
            Uri.parse('$base/api/premium-3d/catalog'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return;

      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['product_ids'] is List) {
        ids.value = (decoded['product_ids'] as List)
            .whereType<num>()
            .map((e) => e.toInt())
            .toSet();
        _lastFetch = DateTime.now();
      }
    } catch (e) {
      debugPrint('3D catalog refresh failed: $e');
    }
  }
}

class Showcase3DService {
  static String get _base =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  Future<List<Showcase3DItem>> fetchShowcase() async {
    final response = await http
        .get(
          Uri.parse('$_base/api/premium-3d/showcase'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception('Unable to load 3D showcase (${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body);
    final items = decoded is Map ? decoded['items'] as List? ?? [] : [];

    return items
        .whereType<Map>()
        .map((m) => Showcase3DItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Returns a short-lived signed GLB URL for a model.
  Future<String> fetchModelUrl(int productId, int modelId) async {
    final response = await http
        .get(
          Uri.parse(
            '$_base/api/premium-3d/products/$productId/models/$modelId/showcase',
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 40));

    if (response.statusCode != 200) {
      String message = 'Unable to load the 3D model.';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['detail'] is String) {
          message = body['detail'] as String;
        }
      } catch (_) {}
      throw Exception(message);
    }

    final decoded = jsonDecode(response.body);
    final url = decoded is Map ? decoded['model_url'] : null;
    final uri = url is String ? Uri.tryParse(url) : null;

    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw Exception('Invalid secure 3D model URL.');
    }

    return url as String;
  }
}
