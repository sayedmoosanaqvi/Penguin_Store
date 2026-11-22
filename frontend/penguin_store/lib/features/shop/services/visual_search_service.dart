import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:penguin_store/config/api_config.dart';

class PickedSearchImage {
  final Uint8List bytes;
  final String filename;

  const PickedSearchImage({
    required this.bytes,
    required this.filename,
  });
}

class VisualSearchResponse {
  final String status; // 'success', 'not_in_database', 'cancelled', 'error'
  final bool inDatabase;
  final String message;
  final List<dynamic> matches;
  final Uint8List? queryImageBytes;
  final Map<String, dynamic> analysis;

  const VisualSearchResponse({
    required this.status,
    required this.inDatabase,
    required this.message,
    required this.matches,
    this.queryImageBytes,
    this.analysis = const {},
  });

  bool get isCancelled => status == 'cancelled';
  bool get isError => status == 'error';
  bool get isNotInDatabase =>
      status == 'not_in_database' || (!inDatabase && matches.isEmpty);
}

class VisualSearchService {
  final ImagePicker _picker = ImagePicker();

  static const Duration _timeout = Duration(seconds: 35);

  MediaType _mediaTypeForFilename(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return MediaType('image', 'jpeg');
      case 'webp':
        return MediaType('image', 'webp');
      case 'gif':
        return MediaType('image', 'gif');
      case 'avif':
        return MediaType('image', 'avif');
      default:
        return MediaType('image', 'png');
    }
  }

  /// Step 1: Pick an image from camera or gallery with fast client-side
  /// resizing (1024px max dimension) before showing any blocking dialog.
  Future<PickedSearchImage?> pickImageForSearch(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (image == null) return null;

      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) return null;

      final filename =
          image.name.trim().isNotEmpty ? image.name.trim() : 'upload.jpg';

      return PickedSearchImage(
        bytes: bytes,
        filename: filename,
      );
    } catch (e) {
      debugPrint('Image picker exception: $e');
      return null;
    }
  }

  /// Step 2: Upload the picked image bytes to the FastAPI visual search engine
  /// and parse the full structured response (including 'not_in_database' & blur analysis).
  Future<VisualSearchResponse> searchWithImageBytes(
    Uint8List bytes, {
    String filename = 'upload.png',
  }) async {
    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/search/visual');
      final request = http.MultipartRequest('POST', url);

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: _mediaTypeForFilename(filename),
        ),
      );

      request.headers.addAll({
        'Accept': 'application/json',
      });

      final streamedResponse = await request.send().timeout(_timeout);
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final rawMatches = map['matches'];
          final matchesList =
              rawMatches is List ? List<dynamic>.from(rawMatches) : <dynamic>[];
          final queryStatus =
              (map['query_status'] ?? (matchesList.isNotEmpty ? 'success' : 'not_in_database'))
                  .toString();
          final inDb = map['in_database'] is bool
              ? map['in_database'] as bool
              : matchesList.isNotEmpty;
          final msg = (map['message'] ??
                  (inDb
                      ? 'Found ${matchesList.length} matching products.'
                      : 'This product is not in the Penguin Store database.'))
              .toString();
          final analysisMap = map['analysis'] is Map
              ? Map<String, dynamic>.from(map['analysis'] as Map)
              : <String, dynamic>{};

          return VisualSearchResponse(
            status: inDb ? 'success' : queryStatus,
            inDatabase: inDb,
            message: msg,
            matches: matchesList,
            queryImageBytes: bytes,
            analysis: analysisMap,
          );
        }
      }

      String errorMsg = 'Visual search failed (${response.statusCode}).';
      try {
        final errJson = json.decode(response.body);
        if (errJson is Map && errJson['detail'] is String) {
          errorMsg = errJson['detail'] as String;
        }
      } catch (_) {}

      return VisualSearchResponse(
        status: 'error',
        inDatabase: false,
        message: errorMsg,
        matches: const [],
        queryImageBytes: bytes,
      );
    } catch (e) {
      debugPrint('Visual Search Network Exception: $e');
      return VisualSearchResponse(
        status: 'error',
        inDatabase: false,
        message: 'Unable to reach the visual search server. Please try again.',
        matches: const [],
        queryImageBytes: bytes,
      );
    }
  }

  /// Hybrid Multimodal RRF Search combining an optional image with spoken or
  /// typed natural-language refinements (`POST /api/v1/search/multimodal`).
  Future<VisualSearchResponse> searchMultimodal({
    Uint8List? imageBytes,
    String filename = 'upload.png',
    String? queryText,
    double? minPrice,
    double? maxPrice,
    String? category,
    bool only3d = false,
  }) async {
    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/v1/search/multimodal');
      final request = http.MultipartRequest('POST', url);

      if (imageBytes != null && imageBytes.isNotEmpty) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            imageBytes,
            filename: filename,
            contentType: _mediaTypeForFilename(filename),
          ),
        );
      }

      if (queryText != null && queryText.trim().isNotEmpty) {
        request.fields['query'] = queryText.trim();
      }
      if (minPrice != null) {
        request.fields['min_price'] = minPrice.toString();
      }
      if (maxPrice != null) {
        request.fields['max_price'] = maxPrice.toString();
      }
      if (category != null && category.trim().isNotEmpty) {
        request.fields['category'] = category.trim();
      }
      if (only3d) {
        request.fields['only_3d'] = 'true';
      }

      request.headers.addAll({'Accept': 'application/json'});

      const multimodalTimeout = Duration(seconds: 40);
      final streamedResponse = await request.send().timeout(multimodalTimeout);
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(multimodalTimeout);

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final rawMatches = map['matches'];
          final matchesList = rawMatches is List
              ? List<dynamic>.from(rawMatches)
              : <dynamic>[];
          final inDb = map['in_database'] is bool
              ? map['in_database'] as bool
              : matchesList.isNotEmpty;
          final queryStatus = (map['query_status'] ??
                  (inDb ? 'success' : 'not_in_database'))
              .toString();
          final msg = (map['message'] ??
                  (inDb
                      ? 'Found ${matchesList.length} multimodal matches.'
                      : 'No products matched your combined image and criteria.'))
              .toString();
          final analysisMap = map['analysis'] is Map
              ? Map<String, dynamic>.from(map['analysis'] as Map)
              : <String, dynamic>{};

          return VisualSearchResponse(
            status: inDb ? 'success' : queryStatus,
            inDatabase: inDb,
            message: msg,
            matches: matchesList,
            queryImageBytes: imageBytes,
            analysis: analysisMap,
          );
        }
      }

      String errorMsg = 'Multimodal search failed (${response.statusCode}).';
      try {
        final errJson = json.decode(response.body);
        if (errJson is Map && errJson['detail'] is String) {
          errorMsg = errJson['detail'] as String;
        }
      } catch (_) {}

      return VisualSearchResponse(
        status: 'error',
        inDatabase: false,
        message: errorMsg,
        matches: const [],
        queryImageBytes: imageBytes,
      );
    } catch (e) {
      debugPrint('Multimodal Search Network Exception: $e');
      return VisualSearchResponse(
        status: 'error',
        inDatabase: false,
        message: 'Unable to reach the multimodal search server. Please try again.',
        matches: const [],
        queryImageBytes: imageBytes,
      );
    }
  }

  /// Backward-compatible method used by existing callers.
  Future<List<dynamic>> searchWithCameraOrGallery(ImageSource source) async {
    final picked = await pickImageForSearch(source);
    if (picked == null) return [];

    final result = await searchWithImageBytes(
      picked.bytes,
      filename: picked.filename,
    );
    return result.matches;
  }
}
