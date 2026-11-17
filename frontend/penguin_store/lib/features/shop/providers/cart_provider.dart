import 'dart:convert';

import 'package:flutter/material.dart';
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

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = _items.values.map((item) => item.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('Failed to persist cart: $e');
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
    _saveToStorage();
  }

  void incrementQuantity(int productId) {
    final existing = _items[productId];
    if (existing == null || existing.quantity >= 100) return;
    existing.quantity += 1;
    notifyListeners();
    _saveToStorage();
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
    _saveToStorage();
  }

  void removeItem(int productId) {
    if (_items.remove(productId) != null) {
      notifyListeners();
      _saveToStorage();
    }
  }

  void clear() {
    _items.clear();
    notifyListeners();
    _saveToStorage();
  }
}
