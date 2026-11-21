import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/multipart_upload_helper.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';

class Admin3DModelRow {
  final int id;
  final int productId;
  final String productName;
  final String productImageUrl;
  final double productPrice;
  final String productCategory;
  final int productStock;
  final String productDescription;
  final String displayName;
  final String? variantName;
  final int? fileSizeBytes;
  final bool isActive;

  const Admin3DModelRow({
    required this.id,
    required this.productId,
    required this.productName,
    this.productImageUrl = '',
    this.productPrice = 0.0,
    this.productCategory = '3D Models',
    this.productStock = 50,
    this.productDescription = '',
    required this.displayName,
    required this.variantName,
    required this.fileSizeBytes,
    required this.isActive,
  });

  factory Admin3DModelRow.fromJson(Map<String, dynamic> j) => Admin3DModelRow(
        id: (j['id'] as num).toInt(),
        productId: (j['product_id'] as num).toInt(),
        productName: (j['product_name'] ?? '').toString(),
        productImageUrl: (j['product_image_url'] ?? '').toString(),
        productPrice: (j['product_price'] as num?)?.toDouble() ?? 0.0,
        productCategory: (j['product_category'] ?? '3D Models').toString(),
        productStock: (j['product_stock'] as num?)?.toInt() ?? 50,
        productDescription: (j['product_description'] ?? '').toString(),
        displayName: (j['display_name'] ?? '3D model').toString(),
        variantName: j['variant_name']?.toString(),
        fileSizeBytes: (j['file_size_bytes'] as num?)?.toInt(),
        isActive: j['is_active'] == true,
      );
}

class Admin3DUploadResult {
  final int productId;
  final int modelId;
  final int storedBytes;
  final String? imageUrl;

  const Admin3DUploadResult(
    this.productId,
    this.modelId,
    this.storedBytes, {
    this.imageUrl,
  });
}

/// Admin-only calls for the unified Admin Studio & 3D Asset Library.
class Admin3DService {
  static String get _base =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  static const Duration _timeout = Duration(seconds: 60);
  static const Duration _uploadTimeout = Duration(minutes: 4);

  Future<Map<String, String>> _headers() async {
    final token = (await SecureStorageService.getToken())?.trim() ?? '';
    if (token.isEmpty) throw Exception('Admin login is required.');
    return {'Authorization': 'Bearer $token', 'Accept': 'application/json'};
  }

  String _detailFromBody(int statusCode, String body) {
    try {
      final d = jsonDecode(body);
      if (d is Map && d['detail'] is String) return d['detail'] as String;
    } catch (_) {}
    return 'Server returned HTTP $statusCode.';
  }

  String _detail(http.Response r) => _detailFromBody(r.statusCode, r.body);

  Future<List<Admin3DModelRow>> listModels() async {
    final r = await http
        .get(
          Uri.parse('$_base/api/premium-3d/admin/models'),
          headers: await _headers(),
        )
        .timeout(_timeout);

    if (r.statusCode != 200) throw Exception(_detail(r));

    final items = (jsonDecode(r.body) as Map)['items'] as List? ?? [];
    return items
        .whereType<Map>()
        .map((m) => Admin3DModelRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> setActive(int modelId, bool active) async {
    final headers = await _headers();
    headers['Content-Type'] = 'application/json';

    final r = await http
        .patch(
          Uri.parse('$_base/api/premium-3d/admin/models/$modelId'),
          headers: headers,
          body: jsonEncode({'is_active': active}),
        )
        .timeout(_timeout);

    if (r.statusCode != 200) throw Exception(_detail(r));
  }

  Future<void> deleteModel(int modelId) async {
    final r = await http
        .delete(
          Uri.parse('$_base/api/premium-3d/admin/models/$modelId'),
          headers: await _headers(),
        )
        .timeout(_timeout);

    if (r.statusCode != 200) throw Exception(_detail(r));
  }

  Future<String> previewUrl(int modelId) async {
    final r = await http
        .get(
          Uri.parse('$_base/api/premium-3d/admin/models/$modelId/preview'),
          headers: await _headers(),
        )
        .timeout(_timeout);

    if (r.statusCode != 200) throw Exception(_detail(r));
    return (jsonDecode(r.body) as Map)['model_url'] as String;
  }

  /// One-step: create a product + attach the GLB + optional auto-captured or
  /// manual poster, reporting real byte-level upload progress (0.0–1.0).
  Future<Admin3DUploadResult> uploadNewProduct({
    required String fileName,
    required Uint8List glbBytes,
    required String name,
    required double price,
    required String category,
    String description = '',
    String variantName = '',
    bool isFeatured = false,
    Uint8List? posterBytes,
    String? posterName,
    void Function(double progress)? onProgress,
  }) async {
    final files = <MultipartUploadFile>[
      MultipartUploadFile(
        fieldName: 'file',
        fileName: fileName,
        bytes: glbBytes,
        contentType: 'model/gltf-binary',
      ),
      if (posterBytes != null && posterBytes.isNotEmpty)
        MultipartUploadFile(
          fieldName: 'poster',
          fileName: posterName ?? 'studio_poster.png',
          bytes: posterBytes,
          contentType: (posterName ?? '').toLowerCase().endsWith('.png')
              ? 'image/png'
              : 'image/jpeg',
        ),
    ];

    final res = await sendMultipartWithProgress(
      uri: Uri.parse('$_base/api/premium-3d/admin/showcase-upload'),
      headers: await _headers(),
      fields: {
        'name': name,
        'price': price.toString(),
        'category': category,
        'description': description,
        'variant_name': variantName,
        'is_featured': isFeatured.toString(),
      },
      files: files,
      onProgress: onProgress,
      timeout: _uploadTimeout,
    );

    if (res.statusCode != 201) {
      throw Exception(_detailFromBody(res.statusCode, res.body));
    }

    final d = jsonDecode(res.body) as Map;
    return Admin3DUploadResult(
      (d['product_id'] as num).toInt(),
      (d['model_id'] as num).toInt(),
      (d['file_size_bytes'] as num?)?.toInt() ?? 0,
      imageUrl: d['image_url']?.toString(),
    );
  }

  /// Attach a GLB (and optional auto-captured studio poster) to an existing product
  /// with real byte-level upload progress (0.0–1.0).
  Future<Admin3DUploadResult> attachToProduct({
    required int productId,
    required String fileName,
    required Uint8List glbBytes,
    required String displayName,
    String variantName = '',
    Uint8List? posterBytes,
    String? posterName,
    bool updateProductImage = false,
    void Function(double progress)? onProgress,
  }) async {
    final files = <MultipartUploadFile>[
      MultipartUploadFile(
        fieldName: 'file',
        fileName: fileName,
        bytes: glbBytes,
        contentType: 'model/gltf-binary',
      ),
      if (posterBytes != null && posterBytes.isNotEmpty)
        MultipartUploadFile(
          fieldName: 'poster',
          fileName: posterName ?? 'studio_poster.png',
          bytes: posterBytes,
          contentType: (posterName ?? '').toLowerCase().endsWith('.png')
              ? 'image/png'
              : 'image/jpeg',
        ),
    ];

    final res = await sendMultipartWithProgress(
      uri: Uri.parse('$_base/api/premium-3d/admin/products/$productId/upload'),
      headers: await _headers(),
      fields: {
        'display_name': displayName,
        'variant_name': variantName,
        'update_product_image': updateProductImage.toString(),
      },
      files: files,
      onProgress: onProgress,
      timeout: _uploadTimeout,
    );

    if (res.statusCode != 201) {
      throw Exception(_detailFromBody(res.statusCode, res.body));
    }

    final d = jsonDecode(res.body) as Map;
    return Admin3DUploadResult(
      productId,
      (d['id'] as num).toInt(),
      (d['file_size_bytes'] as num?)?.toInt() ?? 0,
      imageUrl: d['poster_url']?.toString(),
    );
  }

  /// Replaces an existing 3D product's 2D poster image in Supabase Storage
  /// with a newly captured `<model-viewer>` studio thumbnail.
  Future<String> updateProductPoster({
    required int productId,
    required Uint8List posterBytes,
    String fileName = 'regenerated_3d_poster.png',
  }) async {
    final res = await sendMultipartWithProgress(
      uri: Uri.parse('$_base/api/premium-3d/admin/products/$productId/poster'),
      headers: await _headers(),
      fields: const {},
      files: [
        MultipartUploadFile(
          fieldName: 'poster',
          fileName: fileName,
          bytes: posterBytes,
          contentType: 'image/png',
        ),
      ],
      timeout: _timeout,
    );

    if (res.statusCode != 200) {
      throw Exception(_detailFromBody(res.statusCode, res.body));
    }

    final d = jsonDecode(res.body) as Map;
    return (d['image_url'] ?? '').toString();
  }
}
