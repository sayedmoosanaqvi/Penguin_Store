import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import '../models/product_model.dart';

class Uploaded3DModel {
  final int id;
  final int productId;
  final String storagePath;
  final bool isActive;

  const Uploaded3DModel({
    required this.id,
    required this.productId,
    required this.storagePath,
    required this.isActive,
  });
}

class ProductService {
  static String get baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  static const Duration _requestTimeout = Duration(seconds: 45);
  static const Duration _searchTimeout = Duration(seconds: 12);
  static const Duration _deleteTimeout = Duration(seconds: 15);
  static const Duration _modelUploadTimeout = Duration(seconds: 150);

  static const int _maxImageBytes = 10 * 1024 * 1024;
  static const int maxModelBytes = 60 * 1024 * 1024;

  static List<Product>? _cachedProducts;
  static DateTime? _cachedAt;
  static const String _diskCacheKey = 'penguin_products_cache_v1';

  /// Client-side tombstone set so deleted IDs can NEVER resurrect from stale responses.
  static final Set<int> _deletedProductIds = <int>{};

  static List<Product>? get cachedProducts => _cachedProducts;

  static bool _isProductActive(Product p) {
    if (_deletedProductIds.contains(p.id)) return false;
    if (p.name.trim().startsWith('[Archived]')) return false;
    if (p.stock < 0) return false;
    return true;
  }

  Future<String?> _getAccessToken() async {
    final token = await SecureStorageService.getToken();
    if (token == null || token.trim().isEmpty) {
      debugPrint('Authentication required. Please log in.');
      return null;
    }
    return token.trim();
  }

  Future<Map<String, String>?> _getAdminHeaders({
    bool includeJsonContentType = false,
  }) async {
    final token = await _getAccessToken();
    if (token == null) return null;
    return {
      'Authorization': 'Bearer $token',
      if (includeJsonContentType) 'Content-Type': 'application/json',
    };
  }

  String _errorDetails(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
      if (decoded is Map && decoded['message'] != null) {
        return decoded['message'].toString();
      }
    } catch (_) {}
    return 'Server returned HTTP ${response.statusCode}.';
  }

  /// Stale-while-revalidate catalog loader: returns cached active data right away
  /// on back-navigation and refreshes quietly in the background when stale.
  Future<List<Product>> fetchProducts({bool forceRefresh = false}) async {
    final hasFreshMemoryCache = !forceRefresh &&
        _cachedProducts != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 5);

    if (hasFreshMemoryCache) {
      return _cachedProducts!.where(_isProductActive).toList();
    }

    if (!forceRefresh && _cachedProducts == null) {
      final disk = await _loadDiskCache();
      if (disk != null && disk.isNotEmpty) {
        final cleanDisk = disk.where(_isProductActive).toList();
        _cachedProducts = cleanDisk;
        _cachedAt = DateTime.now().subtract(const Duration(minutes: 4));
        fetchProducts(forceRefresh: true).catchError((_) => cleanDisk);
        return cleanDisk;
      }
    }

    try {
      final uri = forceRefresh
          ? Uri.parse(
              '$baseUrl/api/v1/products/?_ts=${DateTime.now().millisecondsSinceEpoch}',
            )
          : Uri.parse('$baseUrl/api/v1/products/');

      http.Response response = await http
          .get(
            uri,
            headers: const {
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        response = await http
            .get(Uri.parse('$baseUrl/products/'))
            .timeout(_requestTimeout);
      }

      if (response.statusCode != 200) {
        throw Exception(
          ApiErrorHandler.fromStatus(
            response.statusCode,
            response.body,
            fallback: 'Failed to load products.',
          ),
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const FormatException('Invalid product list response.');
      }

      final list = decoded
          .whereType<Map>()
          .map((item) => Product.fromJson(Map<String, dynamic>.from(item)))
          .where(_isProductActive)
          .toList();

      _cachedProducts = list;
      _cachedAt = DateTime.now();
      await _saveDiskCache(list);
      return list;
    } catch (e) {
      debugPrint('Fetch products error: $e');
      if (!forceRefresh && _cachedProducts != null) {
        return _cachedProducts!.where(_isProductActive).toList();
      }
      rethrow;
    }
  }

  /// Fast hybrid search hitting GET /api/v1/products/search with automatic fallback.
  Future<List<Product>> searchProducts({
    required String query,
    String? category,
    double? minPrice,
    double? maxPrice,
    bool only3D = false,
    String? sort,
    int limit = 60,
  }) async {
    final cleanQuery = query.trim();
    final params = <String, String>{
      'limit': '$limit',
      if (cleanQuery.isNotEmpty) 'q': cleanQuery,
      if (category != null &&
          category.trim().isNotEmpty &&
          category.trim() != 'All')
        'category': category.trim(),
      if (minPrice != null) 'min_price': minPrice.toStringAsFixed(2),
      if (maxPrice != null) 'max_price': maxPrice.toStringAsFixed(2),
      if (only3D) 'only_3d': 'true',
      if (sort != null && sort.trim().isNotEmpty) 'sort': sort.trim(),
    };

    try {
      final uri = Uri.parse('$baseUrl/api/v1/products/search')
          .replace(queryParameters: params);
      http.Response response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_searchTimeout);

      if (response.statusCode == 404 || response.statusCode == 422) {
        // Fallback to /api/v1/products/?search=...
        final fallbackParams = Map<String, String>.from(params);
        if (cleanQuery.isNotEmpty) {
          fallbackParams['search'] = cleanQuery;
        }
        final fallbackUri = Uri.parse('$baseUrl/api/v1/products/')
            .replace(queryParameters: fallbackParams);
        response = await http
            .get(fallbackUri, headers: const {'Accept': 'application/json'})
            .timeout(_searchTimeout);
      }

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
              .where(_isProductActive)
              .toList();
        }
      }
    } catch (e) {
      debugPrint('Hybrid search API fallback to local filter: $e');
    }

    // Resilient client-side fallback if backend is waking up
    final source = (_cachedProducts ?? const <Product>[])
        .where(_isProductActive)
        .toList();
    if (cleanQuery.isEmpty) return source;
    final words = cleanQuery
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return source.where((p) {
      final hay = '${p.name} ${p.category} ${p.description}'.toLowerCase();
      return words.every((w) => hay.contains(w));
    }).toList();
  }

  /// Paginated v1 catalog fetch for incremental scrolling/filtering.
  Future<List<Product>> fetchProductsPage({
    int limit = 40,
    int offset = 0,
    String? category,
    String? search,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/products/').replace(
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
        if (category != null && category.isNotEmpty && category != 'All')
          'category': category,
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    final response = await http.get(uri).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw Exception(
        ApiErrorHandler.fromStatus(response.statusCode, response.body),
      );
    }
    final decoded = jsonDecode(response.body) as List;
    return decoded
        .whereType<Map>()
        .map((item) => Product.fromJson(Map<String, dynamic>.from(item)))
        .where(_isProductActive)
        .toList();
  }

  Future<List<Product>?> _loadDiskCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diskCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
          .where(_isProductActive)
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDiskCache(List<Product> products) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clean = products.where(_isProductActive).toList();
      final payload = jsonEncode(clean.map((p) => p.toJson()).toList());
      await prefs.setString(_diskCacheKey, payload);
    } catch (_) {}
  }

  static void invalidateCache() {
    _cachedProducts = null;
    _cachedAt = null;
  }

  /// Completely wipes both in-memory AND SharedPreferences product caches.
  static Future<void> clearAllCaches() async {
    _cachedProducts = null;
    _cachedAt = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_diskCacheKey);
    } catch (_) {}
  }

  /// Immediately purges a deleted product from memory AND SharedPreferences SWR cache
  /// so navigating back or pressing Ctrl+F5/F5 NEVER resurrects it.
  static Future<void> purgeDeletedProductFromCaches(int productId) async {
    _deletedProductIds.add(productId);
    if (_cachedProducts != null) {
      _cachedProducts =
          _cachedProducts!.where((p) => p.id != productId).toList();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diskCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final filtered = decoded.where((entry) {
            if (entry is Map && entry['id'] is num) {
              return (entry['id'] as num).toInt() != productId;
            }
            return true;
          }).toList();
          await prefs.setString(_diskCacheKey, jsonEncode(filtered));
        }
      }
    } catch (_) {}
  }

  Future<Product?> fetchProductById(int productId) async {
    if (_deletedProductIds.contains(productId)) return null;
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/v1/products/$productId'))
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch product: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final prod = Product.fromJson(Map<String, dynamic>.from(decoded as Map));
      return _isProductActive(prod) ? prod : null;
    } catch (e) {
      debugPrint('Fetch product error: $e');
      rethrow;
    }
  }

  Future<bool> addProduct(Map<String, dynamic> productData) async {
    try {
      final headers = await _getAdminHeaders(includeJsonContentType: true);
      if (headers == null) return false;

      final response = await http
          .post(
            Uri.parse('$baseUrl/products/'),
            headers: headers,
            body: jsonEncode(productData),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        await clearAllCaches();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Add product error: $e');
      return false;
    }
  }

  Future<int> createProductWithId(Map<String, dynamic> productData) async {
    final headers = await _getAdminHeaders(includeJsonContentType: true);
    if (headers == null) {
      throw Exception('Admin login is required.');
    }

    final response = await http
        .post(
          Uri.parse('$baseUrl/products/'),
          headers: headers,
          body: jsonEncode(productData),
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Product creation failed: ${_errorDetails(response)}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['id'] is! num) {
      throw const FormatException('Product response is missing its ID.');
    }

    final newId = (decoded['id'] as num).toInt();
    _deletedProductIds.remove(newId);
    await clearAllCaches();
    return newId;
  }

  Future<Product> updateProduct(
    int productId,
    Map<String, dynamic> updates,
  ) async {
    final headers = await _getAdminHeaders(includeJsonContentType: true);
    if (headers == null) {
      throw Exception('Admin login is required.');
    }

    final response = await http
        .put(
          Uri.parse('$baseUrl/api/v1/products/$productId'),
          headers: headers,
          body: jsonEncode(updates),
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Product update failed: ${_errorDetails(response)}');
    }

    await clearAllCaches();
    final decoded = jsonDecode(response.body) as Map;
    return Product.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Instant Admin deletion (<15s strict timeout) with multi-layer cache purge.
  Future<({bool success, String message, String mode})> deleteProduct(
    int productId,
  ) async {
    if (productId == 144) {
      return (
        success: false,
        message: 'Product #144 is protected as the reference 3D showcase item.',
        mode: 'none',
      );
    }

    try {
      final headers = await _getAdminHeaders();
      if (headers == null) {
        return (
          success: false,
          message: 'Admin session expired. Please sign in again.',
          mode: 'none',
        );
      }

      http.Response response = await http
          .delete(
            Uri.parse('$baseUrl/api/v1/products/$productId'),
            headers: headers,
          )
          .timeout(_deleteTimeout);

      if (response.statusCode == 405) {
        response = await http
            .delete(
              Uri.parse('$baseUrl/products/$productId'),
              headers: headers,
            )
            .timeout(_deleteTimeout);
      }

      if (response.statusCode == 200) {
        await purgeDeletedProductFromCaches(productId);
        String msg = 'Product deleted permanently.';
        String mode = 'hard';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            if (decoded['message'] != null) {
              msg = decoded['message'].toString();
            }
            if (decoded['mode'] != null) {
              mode = decoded['mode'].toString();
            }
          }
        } catch (_) {}
        return (success: true, message: msg, mode: mode);
      }

      // If server reports 404 (phantom item already deleted in DB), purge local cache cleanly!
      if (response.statusCode == 404) {
        await purgeDeletedProductFromCaches(productId);
        return (
          success: true,
          message: 'Removed stale deleted item from catalog cache.',
          mode: 'purged',
        );
      }

      return (
        success: false,
        message: _errorDetails(response),
        mode: 'none',
      );
    } catch (e) {
      debugPrint('Delete product error: $e');
      final cleanErr = e.toString().contains('TimeoutException')
          ? 'Request timed out after 15s. Please check server connection.'
          : e.toString().replaceFirst('Exception: ', '');
      return (success: false, message: cleanErr, mode: 'none');
    }
  }

  Future<String?> uploadImageBytes(
    Uint8List bytes, {
    String fileName = 'studio_poster.png',
  }) async {
    try {
      final headers = await _getAdminHeaders();
      if (headers == null || bytes.isEmpty || bytes.length > _maxImageBytes) {
        return null;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload-file/'),
      );
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ),
      );

      final stream = await request.send().timeout(_requestTimeout);
      final response =
          await http.Response.fromStream(stream).timeout(_requestTimeout);

      if (response.statusCode != 200) {
        debugPrint('Image bytes upload failed: ${_errorDetails(response)}');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['url'] is String) {
        final url = decoded['url'] as String;
        if (url.isNotEmpty) return url;
      }
      return null;
    } catch (e) {
      debugPrint('Upload image bytes error: $e');
      return null;
    }
  }

  Future<String?> uploadImage(XFile imageFile) async {
    try {
      final headers = await _getAdminHeaders();
      if (headers == null) return null;

      final size = await imageFile.length();
      if (size <= 0 || size > _maxImageBytes) {
        debugPrint('Image must be under 10 MB.');
        return null;
      }

      final ext = imageFile.name.split('.').last.toLowerCase();
      const allowed = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'};
      if (!allowed.contains(ext)) return null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload-file/'),
      );
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          await imageFile.readAsBytes(),
          filename: imageFile.name,
        ),
      );

      final stream = await request.send().timeout(_requestTimeout);
      final response =
          await http.Response.fromStream(stream).timeout(_requestTimeout);

      if (response.statusCode != 200) {
        debugPrint('Image upload failed: ${_errorDetails(response)}');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['url'] is String) {
        final url = decoded['url'] as String;
        if (url.isNotEmpty) return url;
      }
      return null;
    } catch (e) {
      debugPrint('Upload image error: $e');
      return null;
    }
  }

  Future<Uploaded3DModel> upload3DModel({
    required int productId,
    required String fileName,
    required Uint8List bytes,
    required String displayName,
    String? variantName,
  }) async {
    final headers = await _getAdminHeaders();
    if (headers == null) {
      throw Exception('Admin login is required.');
    }
    if (!fileName.toLowerCase().endsWith('.glb')) {
      throw Exception('Select a .glb file.');
    }
    if (bytes.isEmpty || bytes.length > maxModelBytes) {
      throw Exception('GLB must be under 60 MB.');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/premium-3d/admin/products/$productId/upload'),
    );
    request.headers.addAll(headers);
    request.fields['display_name'] = displayName;
    request.fields['variant_name'] = variantName ?? '';
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
    );

    final stream = await request.send().timeout(_modelUploadTimeout);
    final response =
        await http.Response.fromStream(stream).timeout(_modelUploadTimeout);

    if (response.statusCode != 201) {
      throw Exception('3D upload failed: ${_errorDetails(response)}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map ||
        decoded['id'] is! num ||
        decoded['storage_path'] is! String) {
      throw const FormatException('3D upload response is invalid.');
    }

    return Uploaded3DModel(
      id: (decoded['id'] as num).toInt(),
      productId: productId,
      storagePath: decoded['storage_path'] as String,
      isActive: decoded['is_active'] == true,
    );
  }

  Future<String> getAdmin3DPreviewUrl(int modelId) async {
    final headers = await _getAdminHeaders();
    if (headers == null) {
      throw Exception('Admin login is required.');
    }

    final response = await http
        .get(
          Uri.parse('$baseUrl/api/premium-3d/admin/models/$modelId/preview'),
          headers: headers,
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('3D preview failed: ${_errorDetails(response)}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['model_url'] is! String) {
      throw const FormatException('Missing 3D preview URL.');
    }

    return decoded['model_url'] as String;
  }
}
