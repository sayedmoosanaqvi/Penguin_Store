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
  final List<String> selectedAddOns;
  final double? customUnitPrice;
  final String pricingMode; // 'B2C' or 'B2B'

  CartItem({
    required this.product,
    this.quantity = 1,
    this.selectedVariant,
    this.selectedAddOns = const [],
    this.customUnitPrice,
    this.pricingMode = 'B2C',
  });

  double get effectiveUnitPrice => customUnitPrice ?? product.price;
  double get lineTotal => effectiveUnitPrice * quantity;

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'quantity': quantity,
        if (selectedVariant != null) 'selected_variant': selectedVariant,
        if (selectedAddOns.isNotEmpty) 'selected_addons': selectedAddOns,
        if (customUnitPrice != null) 'custom_unit_price': customUnitPrice,
        'pricing_mode': pricingMode,
      };

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        product: Product.fromJson(
          Map<String, dynamic>.from(json['product'] as Map),
        ),
        quantity: ((json['quantity'] as num?)?.toInt() ?? 1).clamp(1, 500),
        selectedVariant: json['selected_variant']?.toString(),
        selectedAddOns: (json['selected_addons'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        customUnitPrice: (json['custom_unit_price'] as num?)?.toDouble(),
        pricingMode: (json['pricing_mode'] ?? 'B2C').toString(),
      );
}

class CartProvider with ChangeNotifier {
  static const String _storageKey = 'penguin_cart_v1';
  final Map<int, CartItem> _items = {};

  String? _appliedPromoCode;
  String? _promoDescription;

  CartProvider() {
    _loadFromStorage();
  }

  Map<int, CartItem> get items => _items;

  int get itemCount => _items.length;

  String? get appliedPromoCode => _appliedPromoCode;
  String? get promoDescription => _promoDescription;

  int get totalUnits {
    int count = 0;
    for (final item in _items.values) {
      count += item.quantity;
    }
    return count;
  }

  double get subtotalPrice {
    double total = 0;
    for (final item in _items.values) {
      total += item.effectiveUnitPrice * item.quantity;
    }
    return total;
  }

  double get discountAmount {
    final sub = subtotalPrice;
    final code = _appliedPromoCode;
    if (sub <= 0 || code == null || code.isEmpty) return 0.0;

    switch (code) {
      case 'PENGUIN10':
        return double.parse((sub * 0.10).toStringAsFixed(2));
      case 'WELCOME20':
        return sub >= 200.0
            ? 20.0
            : double.parse((sub * 0.10).toStringAsFixed(2));
      case 'WHOLESALE15':
      case 'B2BBULK':
        return sub >= 250.0
            ? double.parse((sub * 0.15).toStringAsFixed(2))
            : double.parse((sub * 0.08).toStringAsFixed(2));
      case 'ARCTIC5':
        return sub >= 15.0 ? 5.0 : 0.0;
      default:
        return 0.0;
    }
  }

  double get taxAmount {
    final afterDiscount = (subtotalPrice - discountAmount).clamp(0.0, 1e9);
    return double.parse((afterDiscount * 0.05).toStringAsFixed(2));
  }

  double get totalPrice {
    final afterDiscount = (subtotalPrice - discountAmount).clamp(0.0, 1e9);
    return double.parse((afterDiscount + taxAmount).toStringAsFixed(2));
  }

  (bool, String) applyPromoCode(String rawCode) {
    final code = rawCode.trim().toUpperCase();
    if (code.isEmpty) {
      return (false, 'Enter a promo code first.');
    }
    final sub = subtotalPrice;
    switch (code) {
      case 'PENGUIN10':
        _appliedPromoCode = code;
        _promoDescription = '10% Storewide Discount applied';
        notifyListeners();
        return (true, 'PENGUIN10 applied — 10% off your order!');
      case 'WELCOME20':
        _appliedPromoCode = code;
        _promoDescription = sub >= 200
            ? '\$20.00 Welcome Discount applied'
            : '10% Welcome Discount applied (\$20 off on \$200+)';
        notifyListeners();
        return (
          true,
          sub >= 200
              ? 'WELCOME20 applied — \$20.00 off!'
              : 'WELCOME20 applied — 10% off (spend \$200+ for \$20 off)!'
        );
      case 'WHOLESALE15':
      case 'B2BBULK':
        _appliedPromoCode = code;
        _promoDescription = '15% B2B Commercial Partner Discount';
        notifyListeners();
        return (true, '$code applied — B2B Partner Discount activated!');
      case 'ARCTIC5':
        _appliedPromoCode = code;
        _promoDescription = '\$5.00 Instant Arctic Bonus';
        notifyListeners();
        return (true, 'ARCTIC5 applied — \$5.00 off!');
      default:
        return (
          false,
          'Invalid code "$code". Try PENGUIN10, WELCOME20, WHOLESALE15, or ARCTIC5.'
        );
    }
  }

  void clearPromoCode() {
    _appliedPromoCode = null;
    _promoDescription = null;
    notifyListeners();
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

    try {
      final token = (await SecureStorageService.getToken())?.trim();
      if (token == null || token.isEmpty) return;

      final serverItems = _items.values
          .map(
            (i) => {
              'product_id': i.product.id,
              'quantity': i.quantity,
              'selected_variant': [
                if (i.selectedVariant != null && i.selectedVariant!.isNotEmpty)
                  i.selectedVariant!,
                ...i.selectedAddOns,
              ].join(' + '),
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
              imageUrl:
                  Product.resolveImageUrl(entry['image_url']?.toString()),
              category: (entry['category'] ?? 'CATALOG').toString(),
              rating: 4.8,
              reviews: 0,
            ),
            quantity:
                ((entry['quantity'] as num?)?.toInt() ?? 1).clamp(1, 500),
            selectedVariant:
                entry['selected_variant']?.toString().isNotEmpty == true
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

  void addToCart(
    Product product, {
    int quantity = 1,
    String? variant,
    List<String> addOns = const [],
    double? unitPrice,
    String pricingMode = 'B2C',
  }) {
    final safeQty = quantity.clamp(1, 500);
    if (_items.containsKey(product.id)) {
      final existing = _items[product.id]!;
      final nextQty = (existing.quantity + safeQty).clamp(1, 500);
      _items[product.id] = CartItem(
        product: product,
        quantity: nextQty,
        selectedVariant: variant ?? existing.selectedVariant,
        selectedAddOns:
            addOns.isNotEmpty ? addOns : existing.selectedAddOns,
        customUnitPrice: unitPrice ?? existing.customUnitPrice,
        pricingMode: pricingMode,
      );
    } else {
      _items[product.id] = CartItem(
        product: product,
        quantity: safeQty,
        selectedVariant: variant,
        selectedAddOns: addOns,
        customUnitPrice: unitPrice,
        pricingMode: pricingMode,
      );
    }
    notifyListeners();
    _saveAndSync();
  }

  void incrementQuantity(int productId) {
    final existing = _items[productId];
    if (existing == null || existing.quantity >= 500) return;
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
    _appliedPromoCode = null;
    _promoDescription = null;
    notifyListeners();
    _saveAndSync();
  }
}
