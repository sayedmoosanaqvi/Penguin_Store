import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds app-wide persisted Wishlist, Recently Viewed, Recent Searches,
/// Saved Addresses, and Notification unread count.
class ShopStateProvider with ChangeNotifier {
  static const String _wishlistKey = 'penguin_wishlist_v1';
  static const String _recentKey = 'penguin_recently_viewed_v1';
  static const String _searchesKey = 'penguin_recent_searches_v1';
  static const String _filterCategoryKey = 'penguin_active_category_v1';

  final CommerceService _commerce = CommerceService();

  List<Product> _wishlist = [];
  List<Product> _recentlyViewed = [];
  List<Product> _compareList = [];
  List<String> _recentSearches = [];
  List<SavedAddress> _addresses = [];
  String _savedCategory = 'All';
  int _unreadNotifications = 0;

  ShopStateProvider() {
    _loadLocal();
  }

  List<Product> get wishlist => List.unmodifiable(_wishlist);
  List<Product> get recentlyViewed => List.unmodifiable(_recentlyViewed);
  List<Product> get compareList => List.unmodifiable(_compareList);
  List<String> get recentSearches => List.unmodifiable(_recentSearches);
  List<SavedAddress> get addresses => List.unmodifiable(_addresses);
  String get savedCategory => _savedCategory;
  int get unreadNotifications => _unreadNotifications;

  bool isWishlisted(int productId) =>
      _wishlist.any((p) => p.id == productId);

  bool isComparing(int productId) =>
      _compareList.any((p) => p.id == productId);

  /// Toggles a product in the Side-by-Side Comparison tray (up to 3 products).
  String toggleCompare(Product product) {
    final existingIdx = _compareList.indexWhere((p) => p.id == product.id);
    if (existingIdx != -1) {
      _compareList.removeAt(existingIdx);
      notifyListeners();
      return 'Removed "${product.name}" from comparison.';
    }
    if (_compareList.length >= 3) {
      return 'Comparison tray holds up to 3 products. Remove one first.';
    }
    _compareList.add(product);
    notifyListeners();
    return 'Added "${product.name}" to comparison (${_compareList.length}/3).';
  }

  void clearCompare() {
    if (_compareList.isEmpty) return;
    _compareList = [];
    notifyListeners();
  }

  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final rawWish = prefs.getString(_wishlistKey);
      if (rawWish != null && rawWish.isNotEmpty) {
        final list = jsonDecode(rawWish) as List;
        _wishlist = list
            .whereType<Map>()
            .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }

      final rawRecent = prefs.getString(_recentKey);
      if (rawRecent != null && rawRecent.isNotEmpty) {
        final list = jsonDecode(rawRecent) as List;
        _recentlyViewed = list
            .whereType<Map>()
            .map((m) => Product.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }

      _recentSearches = prefs.getStringList(_searchesKey) ?? [];
      _savedCategory = prefs.getString(_filterCategoryKey) ?? 'All';

      notifyListeners();
    } catch (e) {
      debugPrint('ShopStateProvider local load error: $e');
    }
  }

  Future<void> _saveWishlistLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _wishlistKey,
        jsonEncode(_wishlist.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> setSavedCategory(String category) async {
    _savedCategory = category;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_filterCategoryKey, category);
    } catch (_) {}
  }

  Future<void> toggleWishlist(Product product) async {
    final existed = isWishlisted(product.id);
    if (existed) {
      _wishlist.removeWhere((p) => p.id == product.id);
    } else {
      _wishlist.insert(0, product);
    }
    notifyListeners();
    await _saveWishlistLocal();

    // Sync silently with Supabase if authenticated
    await _commerce.toggleWishlist(product.id);
  }

  Future<void> recordViewed(Product product) async {
    _recentlyViewed.removeWhere((p) => p.id == product.id);
    _recentlyViewed.insert(0, product);
    if (_recentlyViewed.length > 12) {
      _recentlyViewed = _recentlyViewed.sublist(0, 12);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _recentKey,
        jsonEncode(_recentlyViewed.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}

    await _commerce.recordRecentlyViewed(product.id);
  }

  Future<void> addSearchTerm(String term) async {
    final clean = term.trim();
    if (clean.length < 2) return;
    _recentSearches.removeWhere((s) => s.toLowerCase() == clean.toLowerCase());
    _recentSearches.insert(0, clean);
    if (_recentSearches.length > 8) {
      _recentSearches = _recentSearches.sublist(0, 8);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchesKey, _recentSearches);
    } catch (_) {}
  }

  Future<void> removeSearchTerm(String term) async {
    _recentSearches.remove(term);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchesKey, _recentSearches);
    } catch (_) {}
  }

  Future<void> syncFromServer({String? userEmail}) async {
    try {
      final localIds = _wishlist.map((p) => p.id).toList();
      final serverWish = localIds.isNotEmpty
          ? await _commerce.syncFavorites(localIds)
          : await _commerce.fetchWishlist();
      if (serverWish.isNotEmpty) {
        _wishlist = serverWish;
        await _saveWishlistLocal();
      }
      _addresses = await _commerce.fetchAddresses();
      await _commerce.checkSmartNotifications();
      if (userEmail != null && userEmail.trim().isNotEmpty) {
        _unreadNotifications =
            await _commerce.fetchUnreadNotificationCount(userEmail);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('ShopState server sync skipped: $e');
    }
  }

  void clearPrivateSessionData() {
    _addresses = [];
    _unreadNotifications = 0;
    notifyListeners();
  }

  Future<void> refreshAddresses() async {
    _addresses = await _commerce.fetchAddresses();
    notifyListeners();
  }

  Future<void> addAddress({
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
    await _commerce.saveAddress(
      label: label,
      recipientName: recipientName,
      phone: phone,
      streetAddress: streetAddress,
      city: city,
      stateProvince: stateProvince,
      country: country,
      postalCode: postalCode,
      isDefault: isDefault,
    );
    await refreshAddresses();
  }

  Future<void> removeAddress(int id) async {
    await _commerce.deleteAddress(id);
    _addresses.removeWhere((a) => a.id == id);
    notifyListeners();
  }

  void setUnreadNotifications(int count) {
    if (_unreadNotifications != count) {
      _unreadNotifications = count;
      notifyListeners();
    }
  }
}
