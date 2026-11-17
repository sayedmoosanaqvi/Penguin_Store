import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:penguin_store/config/api_config.dart';

class Admin3DModelRow {
  final int id;
  final int productId;
  final String productName;
  final String displayName;
  final String? variantName;
  final int? fileSizeBytes;
  final bool isActive;

  const Admin3DModelRow({
    required this.id,
    required this.productId,
    required this.productName,
    required this.displayName,
    required this.variantName,
    required this.fileSizeBytes,
    required this.isActive,
  });

  factory Admin3DModelRow.fromJson(Map<String, dynamic> j) => Admin3DModelRow(
        id: (j['id'] as num).toInt(),
        productId: (j['product_id'] as num).toInt(),
        productName: (j['product_name'] ?? '').toString(),
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
  const Admin3DUploadResult(this.productId, this.modelId, this.storedBytes);
}

/// Admin-only calls for the 3D Studio screen.
class Admin3DService {
  static String get _base =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  static const Duration _timeout = Duration(seconds: 60);
  static const Duration _uploadTimeout = Duration(minutes: 4);

  Future<Map<String, String>> _headers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token')?.trim() ?? '';
    if (token.isEmpty) throw Exception('Admin login is required.');
    return {'Authorization': 'Bearer $token', 'Accept': 'application/json'};
  }

  String _detail(http.Response r) {
    try {
      final d = jsonDecode(r.body);
      if (d is Map && d['detail'] is String) return d['detail'] as String;
    } catch (_) {}
    return 'Server returned HTTP ${r.statusCode}.';
  }

  Future<List<Admin3DModelRow>> listModels() async {
    final r = await http
        .get(Uri.parse('$_base/api/premium-3d/admin/models'),
            headers: await _headers())
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
        .delete(Uri.parse('$_base/api/premium-3d/admin/models/$modelId'),
            headers: await _headers())
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

  /// One-step: create a product + attach the GLB (textures capped at 512 px
  /// on the server).
  Future<Admin3DUploadResult> uploadNewProduct({
    required String fileName,
    required Uint8List glbBytes,
    required String name,
    required double price,
    required String category,
    String description = '',
    String variantName = '',
    Uint8List? posterBytes,
    String? posterName,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_base/api/premium-3d/admin/showcase-upload'),
    )
      ..headers.addAll(await _headers())
      ..fields.addAll({
        'name': name,
        'price': price.toString(),
        'category': category,
        'description': description,
        'variant_name': variantName,
      })
      ..files.add(
        http.MultipartFile.fromBytes('file', glbBytes, filename: fileName),
      );

    if (posterBytes != null && posterBytes.isNotEmpty) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'poster',
          posterBytes,
          filename: posterName ?? 'poster.jpg',
        ),
      );
    }

    final streamed = await request.send().timeout(_uploadTimeout);
    final r = await http.Response.fromStream(streamed).timeout(_uploadTimeout);

    if (r.statusCode != 201) throw Exception(_detail(r));

    final d = jsonDecode(r.body) as Map;
    return Admin3DUploadResult(
      (d['product_id'] as num).toInt(),
      (d['model_id'] as num).toInt(),
      (d['file_size_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Attach a GLB to a product that already exists (original endpoint).
  Future<Admin3DUploadResult> attachToProduct({
    required int productId,
    required String fileName,
    required Uint8List glbBytes,
    required String displayName,
    String variantName = '',
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_base/api/premium-3d/admin/products/$productId/upload'),
    )
      ..headers.addAll(await _headers())
      ..fields.addAll({
        'display_name': displayName,
        'variant_name': variantName,
      })
      ..files.add(
        http.MultipartFile.fromBytes('file', glbBytes, filename: fileName),
      );

    final streamed = await request.send().timeout(_uploadTimeout);
    final r = await http.Response.fromStream(streamed).timeout(_uploadTimeout);

    if (r.statusCode != 201) throw Exception(_detail(r));

    final d = jsonDecode(r.body) as Map;
    return Admin3DUploadResult(
      productId,
      (d['id'] as num).toInt(),
      (d['file_size_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}
