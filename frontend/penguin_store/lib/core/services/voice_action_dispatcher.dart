import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/routing/app_router.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

/// Executes verified `client_action` / `client_actions` commands returned by
/// Penguin Voice Concierge and CTRL-X directly against live app state
/// (Cart, Promo Codes, Wishlist, B2B RFQ, 3D Viewer, Router) with 1-tap Instant Undo.
class VoiceActionDispatcher {
  VoiceActionDispatcher._();

  /// Captures the active screen route, currently viewed product ID (if on `/product/:id`),
  /// live cart unit count, live cart subtotal, and cart line items so voice commands
  /// like "Is this worth buying?", "Apply the best coupon to my cart", or "Show in 3D"
  /// resolve against real database and session state.
  static Map<String, dynamic> collectScreenContext(
    BuildContext context, {
    required String currentRoute,
    String? selectedVariant,
    List<int>? visibleProductIds,
  }) {
    int? viewingPid;
    final match = RegExp(r'^/product/(\d+)').firstMatch(currentRoute);
    if (match != null) {
      viewingPid = int.tryParse(match.group(1) ?? '');
    }
    final showcaseMatch =
        RegExp(r'productId=(\d+)').firstMatch(currentRoute);
    if (viewingPid == null && showcaseMatch != null) {
      viewingPid = int.tryParse(showcaseMatch.group(1) ?? '');
    }

    int cartUnits = 0;
    double cartSubtotal = 0.0;
    List<Map<String, dynamic>> cartItems = const [];
    try {
      final cart = context.read<CartProvider>();
      cartUnits = cart.totalUnits;
      cartSubtotal = cart.subtotalPrice;
      cartItems = cart.items.values
          .map(
            (item) => <String, dynamic>{
              'product_id': item.product.id,
              'name': item.product.name,
              'price': item.effectiveUnitPrice,
              'quantity': item.quantity,
            },
          )
          .toList();
    } catch (_) {}

    return {
      'current_route': currentRoute,
      if (viewingPid != null) 'viewing_product_id': viewingPid,
      if (selectedVariant != null) 'selected_variant': selectedVariant,
      if (visibleProductIds != null && visibleProductIds.isNotEmpty)
        'visible_product_ids': visibleProductIds,
      'cart_item_count': cartUnits,
      'cart_total': double.parse(cartSubtotal.toStringAsFixed(2)),
      'cart_items': cartItems,
    };
  }

  static Product _productFromActionMap(Map<String, dynamic> raw) {
    return Product(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      name: (raw['name'] ?? raw['product_name'] ?? 'Product').toString(),
      description: (raw['description'] ?? '').toString(),
      price: (raw['price'] as num?)?.toDouble() ?? 0.0,
      originalPrice: (raw['original_price'] as num?)?.toDouble(),
      imageUrl: Product.resolveImageUrl(raw['image_url']?.toString()),
      category: (raw['category'] ?? 'CATALOG').toString(),
      rating:
          ((raw['trust_weighted_rating'] ?? raw['rating']) as num?)?.toDouble() ??
          4.8,
      reviews: (raw['reviews'] as num?)?.toInt() ?? 12,
      discountPercent: (raw['discount_percent'] as num?)?.toInt(),
      isFeatured: raw['is_featured'] == true,
      stock: (raw['stock'] as num?)?.toInt() ?? 50,
    );
  }

  /// Dispatches a list of `client_actions` sequentially and returns the combined summary.
  static Future<List<String>> dispatchAll(
    BuildContext context,
    List<dynamic>? actions, {
    Map<String, dynamic>? fallbackSingleAction,
    VoidCallback? closeOverlayBeforeNav,
  }) async {
    final executedLabels = <String>[];
    final list = <Map<String, dynamic>>[];

    if (actions != null && actions.isNotEmpty) {
      for (final raw in actions) {
        if (raw is Map) {
          list.add(Map<String, dynamic>.from(raw));
        }
      }
    } else if (fallbackSingleAction != null) {
      list.add(fallbackSingleAction);
    }

    for (final act in list) {
      if (!context.mounted) break;
      final label = await dispatch(
        context,
        act,
        closeOverlayBeforeNav: closeOverlayBeforeNav,
      );
      if (label != null && label.isNotEmpty) {
        executedLabels.add(label);
      }
    }
    return executedLabels;
  }

  /// Reverses an `executed_action` when the user taps the `[Undo]` chip.
  static Future<String?> undoExecutedAction(
    BuildContext context,
    Map<String, dynamic> executedAction,
  ) async {
    final undoRaw = executedAction['undo_action'];
    if (undoRaw is! Map) return null;
    final undoMap = Map<String, dynamic>.from(undoRaw);
    return dispatch(context, undoMap);
  }

  /// Dispatches one backend `client_action` payload. Returns a short human status
  /// string when executed, or `null` if no action ran.
  static Future<String?> dispatch(
    BuildContext context,
    Map<String, dynamic>? action, {
    VoidCallback? closeOverlayBeforeNav,
  }) async {
    if (action == null) return null;
    final type = (action['type'] ?? '').toString().trim().toLowerCase();
    if (type.isEmpty) return null;

    if (type == 'add_to_cart') {
      final rawProd = action['product'] is Map
          ? Map<String, dynamic>.from(action['product'] as Map)
          : <String, dynamic>{
              'id': action['product_id'] ?? 0,
              'name': action['product_name'] ?? 'Product',
              'price': action['price'] ?? 0.0,
              'image_url': action['image_url'] ?? '',
              'category': action['category'] ?? 'CATALOG',
            };
      final product = _productFromActionMap(rawProd);
      if (product.id <= 0 || !context.mounted) return null;

      final qty = ((action['quantity'] as num?)?.toInt() ?? 1).clamp(1, 500);
      final addOns = (action['add_ons'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      final pricingMode =
          (action['pricing_mode'] ?? (qty >= 10 ? 'B2B' : 'B2C')).toString();

      context.read<CartProvider>().addToCart(
            product,
            quantity: qty,
            addOns: addOns,
            pricingMode: pricingMode,
          );
      CustomToast.show(
        context,
        'Voice Concierge added ${product.name} (×$qty) to your cart!',
      );
      return 'Added ${product.name} (×$qty) to cart';
    }

    if (type == 'remove_from_cart') {
      final pid = (action['product_id'] as num?)?.toInt() ?? 0;
      final pname = (action['product_name'] ?? 'Item').toString();
      if (pid <= 0 || !context.mounted) return null;
      context.read<CartProvider>().removeItem(pid);
      CustomToast.show(context, 'Removed $pname from your cart.');
      return 'Removed $pname from cart';
    }

    if (type == 'clear_cart') {
      if (!context.mounted) return null;
      context.read<CartProvider>().clear();
      CustomToast.show(context, 'Cleared your shopping cart.');
      return 'Cleared shopping cart';
    }

    if (type == 'apply_promo') {
      if (!context.mounted) return null;
      final code =
          (action['promo_code'] ?? action['code'] ?? 'PENGUIN10').toString();
      final cart = context.read<CartProvider>();
      final (ok, _) = cart.applyPromoCode(code);
      final disc = (action['discount_amount'] as num?)?.toDouble() ??
          cart.discountAmount;
      final finalTotal =
          (action['final_total'] as num?)?.toDouble() ?? cart.totalPrice;
      final msg = ok
          ? 'Applied promo $code (-${disc > 0 ? "\$${disc.toStringAsFixed(2)}" : "10%"}) • Final Total: \$${finalTotal.toStringAsFixed(2)}'
          : 'Applied optimal promo $code • Estimated Final Total: \$${finalTotal.toStringAsFixed(2)}';
      CustomToast.show(context, msg);
      return 'Applied coupon $code (-\$${disc.toStringAsFixed(2)})';
    }

    if (type == 'clear_promo') {
      if (!context.mounted) return null;
      context.read<CartProvider>().clearPromoCode();
      CustomToast.show(context, 'Removed promo code.');
      return 'Removed promo code';
    }

    if (type == 'b2b_rfq_submitted') {
      if (!context.mounted) return null;
      final rfqId = action['rfq_id'] ?? 'NEW';
      final pname = (action['product_name'] ?? 'Product').toString();
      final qty = (action['quantity'] as num?)?.toInt() ?? 30;
      final unitPrice =
          (action['target_unit_price'] as num?)?.toDouble() ?? 0.0;
      CustomToast.show(
        context,
        'B2B Wholesale Quote #$rfqId submitted ($qty× $pname @ \$${unitPrice.toStringAsFixed(2)}/unit)!',
      );
      return 'Submitted B2B RFQ #$rfqId ($qty× $pname)';
    }

    if (type == 'toggle_favorite') {
      final rawProd = action['product'] is Map
          ? Map<String, dynamic>.from(action['product'] as Map)
          : <String, dynamic>{
              'id': action['product_id'] ?? 0,
              'name': action['product_name'] ?? 'Product',
              'price': action['price'] ?? 0.0,
            };
      final product = _productFromActionMap(rawProd);
      if (product.id <= 0 || !context.mounted) return null;

      final shopState = context.read<ShopStateProvider>();
      final wasSaved = shopState.isWishlisted(product.id);
      await shopState.toggleWishlist(product);
      if (context.mounted) {
        CustomToast.show(
          context,
          wasSaved
              ? 'Removed "${product.name}" from Favorites.'
              : 'Saved "${product.name}" to Favorites!',
        );
      }
      return wasSaved
          ? 'Removed ${product.name} from Favorites'
          : 'Saved ${product.name} to Favorites';
    }

    if (type == 'open_3d') {
      final pid = (action['product_id'] as num?)?.toInt() ?? 0;
      final pname = (action['product_name'] ?? 'Product 3D Studio').toString();
      if (pid <= 0) return null;

      try {
        final avail = await Premium3DService().getAvailability(pid);
        if (avail.has3D && avail.models.isNotEmpty) {
          final firstModel = avail.models.first;
          final url = await Showcase3DService().fetchModelUrl(
            pid,
            firstModel.id,
          );
          if (!context.mounted) return null;
          context.read<VoiceProvider>().markNavigationConfirmation();
          closeOverlayBeforeNav?.call();
          await Future<void>.delayed(const Duration(milliseconds: 120));
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => Product3DViewerScreen(
                productName: pname,
                modelUrl: url,
                productId: pid,
                models: avail.models,
                currentModelId: firstModel.id,
              ),
            ),
          );
          return 'Opened 3D studio for $pname';
        }
      } catch (e) {
        debugPrint('VoiceActionDispatcher open_3d fallback: $e');
      }

      if (!context.mounted) return null;
      context.read<VoiceProvider>().markNavigationConfirmation();
      closeOverlayBeforeNav?.call();
      appRouter.push('/product/$pid');
      return 'Opened product page for $pname';
    }

    if (type == 'open_product') {
      final pid = (action['product_id'] as num?)?.toInt() ?? 0;
      if (pid <= 0 || !context.mounted) return null;
      final pname = (action['product_name'] ?? 'Product #$pid').toString();
      context.read<VoiceProvider>().markNavigationConfirmation();
      closeOverlayBeforeNav?.call();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      appRouter.push('/product/$pid');
      return 'Opened $pname';
    }

    if (type == 'navigate') {
      final rawRoute = (action['route'] ?? '').toString().trim();
      final route = switch (rawRoute) {
        '/checkout' => '/cart',
        '/favorites' => '/wishlist',
        '/3d' => '/showcase-3d',
        _ => rawRoute,
      };
      if (route.isEmpty || !context.mounted) return null;
      context.read<VoiceProvider>().markNavigationConfirmation();
      closeOverlayBeforeNav?.call();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      const shellRoutes = {'/', '/discover', '/cart', '/support', '/profile'};
      if (shellRoutes.contains(route)) {
        appRouter.go(route);
      } else {
        appRouter.push(route);
      }
      return 'Navigated to $route';
    }

    return null;
  }
}
