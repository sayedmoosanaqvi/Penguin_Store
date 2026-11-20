import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';

class _SignedUrlEntry {
  final String url;
  final DateTime expiresAt;
  const _SignedUrlEntry(this.url, this.expiresAt);
  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

/// Persistent in-memory store for products, 3D showcase items, regional trends,
/// personalized recommendations, and signed GLB URLs.
///
/// Guarantees 0ms rendering when returning to Home / Discover / 3D Showcase,
/// with automatic silent background refresh when caches exceed [cacheTtl]
/// and instant invalidation after Admin catalog mutations.
class ProductProvider with ChangeNotifier {
  static const Duration cacheTtl = Duration(minutes: 5);

  final ProductService _productService = ProductService();
  final Showcase3DService _showcase3DService = Showcase3DService();

  // --- Products catalog ---
  List<Product> _products = [];
  DateTime? _productsLoadedAt;
  bool _isLoadingProducts = false;
  bool _isRefreshingProducts = false;
  String? _productsError;
  Future<List<Product>>? _productsInflight;

  // --- 3D Showcase ---
  List<Showcase3DItem> _showcaseItems = [];
  DateTime? _showcaseLoadedAt;
  bool _isLoadingShowcase = false;
  String? _showcaseError;
  Future<List<Showcase3DItem>>? _showcaseInflight;

  // --- Trending carousel (keyed by country) ---
  final Map<String, List<Map<String, dynamic>>> _trendingByCountry = {};
  final Map<String, DateTime> _trendingLoadedAt = {};
  final Set<String> _trendingLoading = {};

  // --- Recommendations carousel (keyed by lowercase email) ---
  final Map<String, List<Map<String, dynamic>>> _recsByEmail = {};
  final Map<String, DateTime> _recsLoadedAt = {};
  final Set<String> _recsLoading = {};

  // --- Signed GLB URL cache (keyed by modelId) ---
  final Map<int, _SignedUrlEntry> _signedUrlCache = {};

  // Getters — Products
  List<Product> get products => List.unmodifiable(_products);
  bool get hasProducts => _products.isNotEmpty;
  bool get isLoadingProducts => _isLoadingProducts;
  bool get isRefreshingProducts => _isRefreshingProducts;
  String? get productsError => _productsError;

  // Getters — 3D Showcase
  List<Showcase3DItem> get showcaseItems => List.unmodifiable(_showcaseItems);
  bool get hasShowcaseItems => _showcaseItems.isNotEmpty;
  bool get isLoadingShowcase => _isLoadingShowcase;
  String? get showcaseError => _showcaseError;

  // Getters — Trending & Recommendations
  List<Map<String, dynamic>> trendingFor(String country) =>
      List.unmodifiable(_trendingByCountry[country] ?? const []);
  bool isTrendingLoading(String country) =>
      _trendingLoading.contains(country) &&
      (_trendingByCountry[country]?.isEmpty ?? true);

  List<Map<String, dynamic>> recommendationsFor(String email) =>
      List.unmodifiable(_recsByEmail[email.trim().toLowerCase()] ?? const []);
  bool isRecommendationsLoading(String email) {
    final key = email.trim().toLowerCase();
    return _recsLoading.contains(key) && (_recsByEmail[key]?.isEmpty ?? true);
  }

  String? getCachedSigned3DUrl(int modelId) {
    final entry = _signedUrlCache[modelId];
    return (entry != null && entry.isFresh) ? entry.url : null;
  }

  bool get _isProductsCacheFresh =>
      _products.isNotEmpty &&
      _productsLoadedAt != null &&
      DateTime.now().difference(_productsLoadedAt!) < cacheTtl;

  bool get _isShowcaseCacheFresh =>
      _showcaseItems.isNotEmpty &&
      _showcaseLoadedAt != null &&
      DateTime.now().difference(_showcaseLoadedAt!) < cacheTtl;

  /// Ensures products are available.
  /// - Fresh memory cache (<5 min): 0ms return, zero network traffic.
  /// - Stale memory cache (>=5 min): keeps current list visible (no spinner!)
  ///   and silently refreshes in the background.
  /// - Cold start: loads from disk cache / network while setting [isLoadingProducts].
  Future<List<Product>> ensureProductsLoaded({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _isProductsCacheFresh) {
      return _products;
    }

    if (!forceRefresh && _products.isNotEmpty) {
      // Stale-while-revalidate: render cached data immediately & refresh quietly
      _refreshProductsInternal(forceRefresh: true, silent: true);
      return _products;
    }

    return _refreshProductsInternal(
      forceRefresh: forceRefresh,
      silent: _products.isNotEmpty,
    );
  }

  Future<List<Product>> _refreshProductsInternal({
    required bool forceRefresh,
    required bool silent,
  }) {
    if (_productsInflight != null) return _productsInflight!;

    if (silent) {
      _isRefreshingProducts = true;
    } else {
      _isLoadingProducts = true;
    }
    _productsError = null;
    notifyListeners();

    final future = _productService
        .fetchProducts(forceRefresh: forceRefresh)
        .then((list) {
      _products = list;
      _productsLoadedAt = DateTime.now();
      _productsError = null;
      return list;
    }).catchError((Object err) {
      debugPrint('ProductProvider.fetchProducts error: $err');
      if (_products.isEmpty) {
        _productsError = err.toString().replaceFirst('Exception: ', '');
      }
      return _products;
    }).whenComplete(() {
      _isLoadingProducts = false;
      _isRefreshingProducts = false;
      _productsInflight = null;
      notifyListeners();
    });

    _productsInflight = future;
    return future;
  }

  /// Ensures 3D showcase items are loaded with the same 0ms + 5-min stale-while-revalidate pattern.
  Future<List<Showcase3DItem>> ensureShowcaseLoaded({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _isShowcaseCacheFresh) {
      return _showcaseItems;
    }

    if (!forceRefresh && _showcaseItems.isNotEmpty) {
      _refreshShowcaseInternal(silent: true);
      return _showcaseItems;
    }

    return _refreshShowcaseInternal(silent: _showcaseItems.isNotEmpty);
  }

  Future<List<Showcase3DItem>> _refreshShowcaseInternal({
    required bool silent,
  }) {
    if (_showcaseInflight != null) return _showcaseInflight!;

    if (!silent) {
      _isLoadingShowcase = true;
      _showcaseError = null;
      notifyListeners();
    }

    final future = _showcase3DService.fetchShowcase().then((items) {
      _showcaseItems = items;
      _showcaseLoadedAt = DateTime.now();
      _showcaseError = null;
      // Keep Catalog3D global notifier synchronized
      Catalog3D.ids.value = items.map((e) => e.product.id).toSet();
      return items;
    }).catchError((Object err) {
      debugPrint('ProductProvider.fetchShowcase error: $err');
      if (_showcaseItems.isEmpty) {
        _showcaseError = err.toString().replaceFirst('Exception: ', '');
      }
      return _showcaseItems;
    }).whenComplete(() {
      _isLoadingShowcase = false;
      _showcaseInflight = null;
      notifyListeners();
    });

    _showcaseInflight = future;
    return future;
  }

  /// Fetches and caches a signed GLB URL for in-card or full-screen 3D rendering.
  Future<String> resolveSigned3DUrl(int productId, int modelId) async {
    final cached = getCachedSigned3DUrl(modelId);
    if (cached != null) return cached;

    final url = await _showcase3DService.fetchModelUrl(productId, modelId);
    _signedUrlCache[modelId] = _SignedUrlEntry(
      url,
      DateTime.now().add(const Duration(minutes: 4)),
    );
    return url;
  }

  /// Caches regional trending products for 5 minutes so HomeScreen returns at 0ms.
  Future<void> ensureTrendingLoaded(
    String country, {
    bool forceRefresh = false,
  }) async {
    final loadedAt = _trendingLoadedAt[country];
    final hasCached = (_trendingByCountry[country]?.isNotEmpty ?? false);
    final isFresh = hasCached &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < cacheTtl;

    if (!forceRefresh && isFresh) return;
    if (_trendingLoading.contains(country)) return;

    _trendingLoading.add(country);
    if (!hasCached) notifyListeners();

    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/trending/top-10').replace(
        queryParameters: {'country': country},
      );
      final response = await http.get(url).timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['products'] is List) {
          _trendingByCountry[country] = (data['products'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          _trendingLoadedAt[country] = DateTime.now();
        }
      }
    } catch (e) {
      debugPrint('Error fetching trends: $e');
    } finally {
      _trendingLoading.remove(country);
      notifyListeners();
    }
  }

  /// Caches personalized recommendations per email for 5 minutes.
  Future<void> ensureRecommendationsLoaded(
    String email, {
    bool forceRefresh = false,
  }) async {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return;

    final loadedAt = _recsLoadedAt[key];
    final hasCached = (_recsByEmail[key]?.isNotEmpty ?? false);
    final isFresh = hasCached &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < cacheTtl;

    if (!forceRefresh && isFresh) return;
    if (_recsLoading.contains(key)) return;

    _recsLoading.add(key);
    if (!hasCached) notifyListeners();

    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/recommendations/for-user').replace(
        queryParameters: {'email': key, 'limit': '5'},
      );
      final response = await http.get(url).timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['products'] is List) {
          _recsByEmail[key] = (data['products'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          _recsLoadedAt[key] = DateTime.now();
        }
      }
    } catch (e) {
      debugPrint('Error fetching recommendations: $e');
    } finally {
      _recsLoading.remove(key);
      notifyListeners();
    }
  }

  /// Called immediately after an Admin creates, updates, or deletes a product or 3D model.
  Future<void> invalidateAllAndRefresh() async {
    ProductService.invalidateCache();
    _productsLoadedAt = null;
    _showcaseLoadedAt = null;
    _signedUrlCache.clear();
    _trendingLoadedAt.clear();
    _recsLoadedAt.clear();

    await Future.wait([
      Catalog3D.refresh(force: true),
      _refreshProductsInternal(forceRefresh: true, silent: _products.isNotEmpty),
      _refreshShowcaseInternal(silent: _showcaseItems.isNotEmpty),
    ]);
  }
}
