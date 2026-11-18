import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/product_model.dart';

class CartItem {
  final Product product;
  int quantity;
  final String? selectedVariant;

  CartItem({
    required this.product,
    this.quantity = 1,
    this.selectedVariant,
  });

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'quantity': quantity,
        if (selectedVariant != null) 'selected_variant': selectedVariant,
      };

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        product: Product.fromJson(
          Map<String, dynamic>.from(json['product'] as Map),
        ),
        quantity: ((json['quantity'] as num?)?.toInt() ?? 1).clamp(1, 100),
        selectedVariant: json['selected_variant']?.toString(),
      );
}

class CartProvider with ChangeNotifier {
  static const String _storageKey = 'penguin_cart_v1';
  final Map<int, CartItem> _items = {};

  CartProvider() {
    _loadFromStorage();
  }

  Map<int, CartItem> get items => _items;

  int get itemCount => _items.length;

  int get totalUnits {
    int count = 0;
    for (final item in _items.values) {
      count += item.quantity;
    }
    return count;
  }

  double get totalPrice {
    double total = 0;
    for (final item in _items.values) {
      total += item.product.price * item.quantity;
    }
    return total;
  }

  String get _base => ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      bool changed = false;
      for (final entry in decoded) {
        if (entry is Map) {
          final item = CartItem.fromJson(Map<String, dynamic>.from(entry));
          _items.putIfAbsent(item.product.id, () => item);
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('Failed to restore cart: $e');
    }
  }

  Future<void> _saveAndSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = _items.values.map((item) => item.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('Failed to persist cart: $e');
    }

    // Best-effort sync to PostgreSQL /api/v1/cart/sync if user is signed in
    try {
      final token = (await SecureStorageService.getToken())?.trim();
      if (token == null || token.isEmpty) return;

      final serverItems = _items.values
          .map(
            (i) => {
              'product_id': i.product.id,
              'quantity': i.quantity,
              'selected_variant': i.selectedVariant ?? '',
            },
          )
          .toList();

      await http
          .put(
            Uri.parse('$_base/api/v1/cart/sync'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'items': serverItems}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Called on login/app boot when user already has an authenticated JWT.
  Future<void> syncWithServer() async {
    try {
      final token = (await SecureStorageService.getToken())?.trim();
      if (token == null || token.isEmpty) return;

      final res = await http
          .get(
            Uri.parse('$_base/api/v1/cart/'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) return;
      final decoded = jsonDecode(res.body) as Map;
      final serverList = decoded['items'] as List? ?? [];

      if (serverList.isEmpty && _items.isNotEmpty) {
        await _saveAndSync();
        return;
      }

      bool merged = false;
      for (final entry in serverList.whereType<Map>()) {
        final pid = (entry['product_id'] as num?)?.toInt();
        if (pid == null) continue;
        if (!_items.containsKey(pid)) {
          _items[pid] = CartItem(
            product: Product(
              id: pid,
              name: (entry['name'] ?? 'Product').toString(),
              description: '',
              price: (entry['price'] as num?)?.toDouble() ?? 0.0,
              imageUrl: Product.resolveImageUrl(entry['image_url']?.toString()),
              category: (entry['category'] ?? 'CATALOG').toString(),
              rating: 4.8,
              reviews: 0,
            ),
            quantity: ((entry['quantity'] as num?)?.toInt() ?? 1).clamp(1, 100),
            selectedVariant: entry['selected_variant']?.toString().isNotEmpty == true
                ? entry['selected_variant'].toString()
                : null,
          );
          merged = true;
        }
      }
      if (merged) {
        notifyListeners();
        await _saveAndSync();
      }
    } catch (e) {
      debugPrint('Cart server sync skipped: $e');
    }
  }

  void addToCart(Product product, {int quantity = 1, String? variant}) {
    final safeQty = quantity.clamp(1, 100);
    if (_items.containsKey(product.id)) {
      _items[product.id]!.quantity =
          (_items[product.id]!.quantity + safeQty).clamp(1, 100);
    } else {
      _items[product.id] = CartItem(
        product: product,
        quantity: safeQty,
        selectedVariant: variant,
      );
    }
    notifyListeners();
    _saveAndSync();
  }

  void incrementQuantity(int productId) {
    final existing = _items[productId];
    if (existing == null || existing.quantity >= 100) return;
    existing.quantity += 1;
    notifyListeners();
    _saveAndSync();
  }

  void decrementQuantity(int productId) {
    final existing = _items[productId];
    if (existing == null) return;
    if (existing.quantity <= 1) {
      _items.remove(productId);
    } else {
      existing.quantity -= 1;
    }
    notifyListeners();
    _saveAndSync();
  }

  void removeItem(int productId) {
    if (_items.remove(productId) != null) {
      notifyListeners();
      _saveAndSync();
    }
  }

  void clear() {
    _items.clear();
    notifyListeners();
    _saveAndSync();
  }
}
