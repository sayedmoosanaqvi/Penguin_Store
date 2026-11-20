
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  static const Duration _requestTimeout =
      Duration(seconds: 60);

  static const Duration _modelUploadTimeout =
      Duration(seconds: 150);

  static const int _maxImageBytes =
      10 * 1024 * 1024;

  static const int maxModelBytes =
      60 * 1024 * 1024;

  Future<String?> _getAccessToken() async {
    final token = await SecureStorageService.getToken();

    if (token == null || token.trim().isEmpty) {
      debugPrint(
        'Authentication required. Please log in.',
      );
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
      if (includeJsonContentType)
        'Content-Type': 'application/json',
    };
  }

  String _errorDetails(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);

      if (decoded is Map &&
          decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {}

    return 'Server returned HTTP ${response.statusCode}.';
  }

  static List<Product>? _cachedProducts;
  static DateTime? _cachedAt;
  static const String _diskCacheKey = 'penguin_products_cache_v1';

  static List<Product>? get cachedProducts => _cachedProducts;

  /// Stale-while-revalidate catalog loader: returns cached data right away
  /// on back-navigation and refreshes quietly in the background when stale.
  Future<List<Product>> fetchProducts({bool forceRefresh = false}) async {
    final hasFreshMemoryCache = !forceRefresh &&
        _cachedProducts != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 5);

    if (hasFreshMemoryCache) {
      return _cachedProducts!;
    }

    if (!forceRefresh && _cachedProducts == null) {
      final disk = await _loadDiskCache();
      if (disk != null && disk.isNotEmpty) {
        _cachedProducts = disk;
        _cachedAt = DateTime.now().subtract(const Duration(minutes: 4));
        // Trigger background refresh without blocking initial UI render
        fetchProducts(forceRefresh: true).catchError((_) => disk);
        return disk;
      }
    }

    try {
      final response = await http
          .get(Uri.parse('$baseUrl/products/'))
          .timeout(_requestTimeout);

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
          .map(
            (item) => Product.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      _cachedProducts = list;
      _cachedAt = DateTime.now();
      _saveDiskCache(list);
      return list;
    } catch (e) {
      debugPrint('Fetch products error: $e');
      if (_cachedProducts != null) return _cachedProducts!;
      rethrow;
    }
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
        .map((item) => Product.fromJson(Map<String, dynamic>.from(item as Map)))
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
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDiskCache(List<Product> products) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode(products.map((p) => p.toJson()).toList());
      await prefs.setString(_diskCacheKey, payload);
    } catch (_) {}
  }

  static void invalidateCache() {
    _cachedAt = null;
  }

  // Public product details
  Future<Product?> fetchProductById(
    int productId,
  ) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '$baseUrl/products/$productId',
            ),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to fetch product: '
          '${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);

      return Product.fromJson(
        Map<String, dynamic>.from(
          decoded as Map,
        ),
      );

    } catch (e) {
      debugPrint('Fetch product error: $e');
      rethrow;
    }
  }

  // Preserve existing bool-based product creation
  Future<bool> addProduct(
    Map<String, dynamic> productData,
  ) async {
    try {
      final headers = await _getAdminHeaders(
        includeJsonContentType: true,
      );

      if (headers == null) {
        return false;
      }

      final response = await http
          .post(
            Uri.parse('$baseUrl/products/'),
            headers: headers,
            body: jsonEncode(productData),
          )
          .timeout(_requestTimeout);

      return response.statusCode == 200 ||
          response.statusCode == 201;

    } catch (e) {
      debugPrint('Add product error: $e');
      return false;
    }
  }

  // Create product and return its database ID
  Future<int> createProductWithId(
    Map<String, dynamic> productData,
  ) async {
    final headers = await _getAdminHeaders(
      includeJsonContentType: true,
    );

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

    if (response.statusCode != 200 &&
        response.statusCode != 201) {
      throw Exception(
        'Product creation failed: '
        '${_errorDetails(response)}',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map ||
        decoded['id'] is! num) {
      throw const FormatException(
        'Product response is missing its ID.',
      );
    }

    invalidateCache();
    return (decoded['id'] as num).toInt();
  }

  /// Update an existing product's metadata via /api/v1/products/{id}.
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
      throw Exception(
        'Product update failed: ${_errorDetails(response)}',
      );
    }

    invalidateCache();
    final decoded = jsonDecode(response.body) as Map;
    return Product.fromJson(Map<String, dynamic>.from(decoded));
  }

  // Existing admin deletion
  Future<bool> deleteProduct(
    int productId,
  ) async {
    try {
      final headers = await _getAdminHeaders();

      if (headers == null) {
        return false;
      }

      final response = await http
          .delete(
            Uri.parse(
              '$baseUrl/products/$productId',
            ),
            headers: headers,
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        invalidateCache();
        return true;
      }
      return false;

    } catch (e) {
      debugPrint('Delete product error: $e');
      return false;
    }
  }

  /// Upload raw image bytes (manual photo or auto-captured 3D PNG) to Supabase Storage.
  Future<String?> uploadImageBytes(
    Uint8List bytes, {
    String fileName = 'product_image.png',
  }) async {
    try {
      final headers = await _getAdminHeaders();
      if (headers == null) return null;
      if (bytes.isEmpty || bytes.length > _maxImageBytes) return null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload-file/'),
      );
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );

      final stream = await request.send().timeout(_requestTimeout);
      final response =
          await http.Response.fromStream(stream).timeout(_requestTimeout);
      if (response.statusCode != 200) return null;

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

  // Existing public image upload to Supabase
  Future<String?> uploadImage(
    XFile imageFile,
  ) async {
    try {
      final headers = await _getAdminHeaders();

      if (headers == null) {
        return null;
      }

      final fileSize = await imageFile.length();

      if (fileSize <= 0 ||
          fileSize > _maxImageBytes) {
        debugPrint(
          'Invalid image size. Maximum allowed is 10 MB.',
        );
        return null;
      }

      final ext = imageFile.name
          .split('.')
          .last
          .toLowerCase();

      const allowed = {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'avif',
      };

      if (!allowed.contains(ext)) {
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
          await imageFile.readAsBytes(),
          filename: imageFile.name,
        ),
      );

      final stream = await request
          .send()
          .timeout(_requestTimeout);

      final response = await http.Response
          .fromStream(stream)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        debugPrint(
          'Image upload failed: '
          '${_errorDetails(response)}',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);

      if (decoded is Map &&
          decoded['url'] is String) {
        final url = decoded['url'] as String;

        if (url.isNotEmpty) {
          return url;
        }
      }

      return null;

    } catch (e) {
      debugPrint('Upload image error: $e');
      return null;
    }
  }

  // Upload a GLB to private Supabase Storage
  // via the admin-only FastAPI endpoint
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

    if (bytes.isEmpty ||
        bytes.length > maxModelBytes) {
      throw Exception(
        'GLB must be under 60 MB.',
      );
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(
        '$baseUrl/api/premium-3d/admin/'
        'products/$productId/upload',
      ),
    );

    request.headers.addAll(headers);

    request.fields['display_name'] = displayName;

    request.fields['variant_name'] =
        variantName ?? '';

    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
      ),
    );

    final stream = await request
        .send()
        .timeout(_modelUploadTimeout);

    final response = await http.Response
        .fromStream(stream)
        .timeout(_modelUploadTimeout);

    if (response.statusCode != 201) {
      throw Exception(
        '3D upload failed: '
        '${_errorDetails(response)}',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map ||
        decoded['id'] is! num ||
        decoded['storage_path'] is! String) {
      throw const FormatException(
        '3D upload response is invalid.',
      );
    }

    return Uploaded3DModel(
      id: (decoded['id'] as num).toInt(),
      productId: productId,
      storagePath:
          decoded['storage_path'] as String,
      isActive: decoded['is_active'] == true,
    );
  }

  // Admin preview without Stripe subscription
  Future<String> getAdmin3DPreviewUrl(
    int modelId,
  ) async {
    final headers = await _getAdminHeaders();

    if (headers == null) {
      throw Exception('Admin login is required.');
    }

    final response = await http
        .get(
          Uri.parse(
            '$baseUrl/api/premium-3d/'
            'admin/models/$modelId/preview',
          ),
          headers: headers,
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception(
        '3D preview failed: '
        '${_errorDetails(response)}',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map ||
        decoded['model_url'] is! String) {
      throw const FormatException(
        'Missing 3D preview URL.',
      );
    }

    return decoded['model_url'] as String;
  }
}
