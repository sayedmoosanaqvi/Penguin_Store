import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/screens/checkout_result_screens.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/services/stripe_payment_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  // Phase 2: Stripe online card payments are now ACTIVE alongside Cash on Delivery (COD).
  static const bool _stripePaymentsEnabled = true;

  final TextEditingController _promoController = TextEditingController();
  bool _isCheckingOut = false;

  @override
  void dispose() {
    _promoController.dispose();
    super.dispose();
  }

  void _applyPromo(CartProvider cart, [String? preset]) {
    final code = (preset ?? _promoController.text).trim();
    final (ok, msg) = cart.applyPromoCode(code);
    if (ok && preset != null) {
      _promoController.text = preset;
    }
    CustomToast.show(context, msg, isError: !ok);
  }

  Future<void> _processDynamicCheckout(
    _CheckoutDetails details,
    List<CartItem> items,
  ) async {
    if (_isCheckingOut || items.isEmpty) return;

    setState(() => _isCheckingOut = true);

    try {
      final cart = context.read<CartProvider>();
      final currency = context.read<CurrencyProvider>();

      final cartPayloadItems = items.map((item) {
        return {
          'product_id': item.product.id,
          'quantity': item.quantity,
          'unit_price': item.effectiveUnitPrice,
          'selected_variant': item.selectedVariant,
          'selected_addons': item.selectedAddOns,
          'pricing_mode': item.pricingMode,
        };
      }).toList();

      final token = (await SecureStorageService.getToken())?.trim();
      final isStripePayment =
          _stripePaymentsEnabled && details.paymentMethod == 'STRIPE';

      final checkoutResponse = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/orders/checkout'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'customer_name': details.name,
              'customer_email': details.email,
              'shipping_address': details.streetAddress,
              'city': details.city,
              'state_province': details.stateProvince,
              'country': details.country,
              'postal_code': details.postalCode,
              'promo_code': cart.appliedPromoCode,
              'discount_amount': cart.discountAmount,
              'tax_amount': cart.taxAmount,
              'currency_code': currency.code,
              'payment_method': isStripePayment ? 'STRIPE' : 'COD',
              'items': cartPayloadItems,
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (checkoutResponse.statusCode != 200) {
        throw Exception(
          ApiErrorHandler.fromStatus(
            checkoutResponse.statusCode,
            checkoutResponse.body,
            fallback: 'Could not place your order right now.',
          ),
        );
      }

      final orderData = jsonDecode(checkoutResponse.body) as Map;
      final int createdOrderId = (orderData['order_id'] as num).toInt();

      if (!mounted) return;

      if (details.saveAddress) {
        await context.read<ShopStateProvider>().addAddress(
              label: 'Home',
              recipientName: details.name,
              phone: '',
              streetAddress: details.streetAddress,
              city: details.city,
              stateProvince: details.stateProvince,
              country: details.country,
              postalCode: details.postalCode,
              isDefault: true,
            );
      }

      if (!mounted) return;

      if (isStripePayment) {
        CustomToast.show(
          context,
          'Redirecting to Stripe Secure Checkout for Order #$createdOrderId...',
        );
        final voice = context.read<VoiceProvider>();
        if (voice.voiceEnabled && voice.autoSpeakOrderConfirmation) {
          // Fire-and-forget cue while Stripe Checkout opens
          voice.speakText(
            'Redirecting to secure Stripe checkout.',
            label: 'Checkout Redirect',
          );
        }
        await StripePaymentService.startCheckout(
          orderId: createdOrderId,
          currency: 'usd',
        );
        return;
      }

      // Cash on Delivery (COD) flow: deduct stock & show confirmed receipt
      context.read<ProductProvider>().ensureProductsLoaded(forceRefresh: true);
      context.read<CartProvider>().clear();
      _promoController.clear();
      CustomToast.show(
        context,
        'COD Order #$createdOrderId confirmed! View your invoice.',
      );
      context.go('/checkout-success?order_id=$createdOrderId&mode=cod');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(
        context,
        ApiErrorHandler.sanitize(
          e,
          fallback: 'Checkout could not be completed. Please try again.',
        ),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isCheckingOut = false);
      }
    }
  }

  Future<void> _showCheckoutForm(List<CartItem> items) async {
    if (_isCheckingOut || items.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final shopState = context.read<ShopStateProvider>();

    final details = await showDialog<_CheckoutDetails>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return _CheckoutDetailsDialog(
          initialEmail: auth.userEmail ?? '',
          isAuthenticated: auth.isAuthenticated,
          savedAddresses: shopState.addresses,
        );
      },
    );

    if (!mounted || details == null) return;
    await _processDynamicCheckout(details, items);
  }

  Widget _buildEmptyState(ThemeData theme) {
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 105,
              height: 105,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_bag_outlined,
                size: 52,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Your Cart is Empty',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Discover retail & B2B wholesale products and add them to your cart.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.go('/discover'),
              icon: const Icon(Icons.grid_view_rounded, size: 18),
              label: const Text('Explore Products'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartItem(
    CartItem item,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final product = item.product;
    final cart = context.read<CartProvider>();
    final colors = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/product/${product.id}'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 84,
              height: 88,
              child: StudioProductImage(
                productId: product.id,
                imageUrl: product.imageUrl,
                padding: 8,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove item',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        onPressed: _isCheckingOut
                            ? null
                            : () => cart.removeItem(product.id),
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: colors.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Itemized Variant, Add-Ons & B2B Wholesale Mode Tags
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    children: [
                      _itemTag(
                        product.category.toUpperCase(),
                        colors.onSurfaceVariant,
                        colors.surfaceContainerHighest,
                      ),
                      if (item.selectedVariant != null &&
                          item.selectedVariant!.isNotEmpty)
                        _itemTag(
                          'Option: ${item.selectedVariant}',
                          colors.primary,
                          colors.primary.withValues(alpha: 0.1),
                        ),
                      if (item.pricingMode == 'B2B')
                        _itemTag(
                          'B2B Wholesale Tier',
                          const Color(0xFF00ACC1),
                          const Color(0xFF00ACC1).withValues(alpha: 0.12),
                        ),
                      for (final addon in item.selectedAddOns)
                        _itemTag(
                          '+ $addon',
                          const Color(0xFF16A34A),
                          const Color(0xFF16A34A).withValues(alpha: 0.11),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${currency.format(item.effectiveUnitPrice)} / unit',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (item.effectiveUnitPrice != product.price) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(Base ${currency.format(product.price)})',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colors.primary.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(9),
                              ),
                              onTap: _isCheckingOut
                                  ? null
                                  : () => cart.decrementQuantity(product.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                child: Icon(
                                  Icons.remove_rounded,
                                  size: 15,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 7),
                              child: Text(
                                '${item.quantity}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                            InkWell(
                              borderRadius: const BorderRadius.horizontal(
                                right: Radius.circular(9),
                              ),
                              onTap: _isCheckingOut
                                  ? null
                                  : () => cart.incrementQuantity(product.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 15,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Text(
                          currency.format(item.lineTotal),
                          key: ValueKey(
                            'line-${product.id}-${item.quantity}-${item.effectiveUnitPrice}-${currency.code}',
                          ),
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w900,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemTag(String label, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildPromoAndSummaryCard(
    ThemeData theme,
    CartProvider cart,
    CurrencyProvider currency,
  ) {
    final colors = theme.colorScheme;
    final discount = cart.discountAmount;
    final subtotal = cart.subtotalPrice;
    final tax = cart.taxAmount;
    final total = cart.totalPrice;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_offer_outlined, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Promo & Commercial Discount Code',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _promoController,
                  textCapitalization: TextCapitalization.characters,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter PENGUIN10, WELCOME20, or WHOLESALE15',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _applyPromo(cart),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _isCheckingOut ? null : () => _applyPromo(cart),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Apply',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final code in const [
                ('PENGUIN10', '10% Off'),
                ('WELCOME20', '\$20 Off \$200+'),
                ('WHOLESALE15', '15% B2B'),
                ('ARCTIC5', '\$5 Bonus'),
              ])
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    cart.appliedPromoCode == code.$1
                        ? Icons.check_circle_rounded
                        : Icons.sell_outlined,
                    size: 14,
                    color: cart.appliedPromoCode == code.$1
                        ? const Color(0xFF16A34A)
                        : colors.primary,
                  ),
                  label: Text(
                    '${code.$1} (${code.$2})',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () => _applyPromo(cart, code.$1),
                ),
            ],
          ),
          if (cart.appliedPromoCode != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFF16A34A).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.verified_rounded,
                    size: 16,
                    color: Color(0xFF16A34A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${cart.appliedPromoCode}: ${cart.promoDescription ?? "Discount active"}',
                      style: const TextStyle(
                        color: Color(0xFF16A34A),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      cart.clearPromoCode();
                      _promoController.clear();
                    },
                    child: const Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: Color(0xFF16A34A),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 24),
          _summaryRow('Items Subtotal', currency.format(subtotal), colors),
          if (discount > 0)
            _summaryRow(
              'Promo Discount (${cart.appliedPromoCode})',
              '-${currency.format(discount)}',
              colors,
              valueColor: const Color(0xFF16A34A),
            ),
          _summaryRow(
            'Estimated Tax & Handling (5%)',
            currency.format(tax),
            colors,
          ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Grand Total',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: colors.onSurface,
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  currency.format(total),
                  key: ValueKey('total-$total-${currency.code}'),
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value,
    ColorScheme colors, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: valueColor ?? colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckoutBar(
    ThemeData theme,
    CartProvider cart,
    CurrencyProvider currency,
    List<CartItem> items,
  ) {
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(
            top: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cart.discountAmount > 0
                        ? 'Total Payment (Saved ${currency.format(cart.discountAmount)})'
                        : 'Total Payment (incl. Tax)',
                    style: TextStyle(
                      fontSize: 11,
                      color: cart.discountAmount > 0
                          ? const Color(0xFF16A34A)
                          : colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      currency.format(cart.totalPrice),
                      key: ValueKey('bar-${cart.totalPrice}-${currency.code}'),
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed:
                  _isCheckingOut ? null : () => _showCheckoutForm(items),
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isCheckingOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.lock_outline_rounded, size: 17),
              label: Text(
                _isCheckingOut ? 'PLACING ORDER...' : 'PROCEED TO CHECKOUT',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final currency = context.watch<CurrencyProvider>();
    final items = cart.items.values.toList();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: const Text(
          'My Shopping Cart',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: _isCheckingOut ? null : cart.clear,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: items.isEmpty
          ? _buildEmptyState(theme)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    const CheckoutStepperBanner(activeStep: 1),
                    const SizedBox(height: 12),
                    Text(
                      '${items.length} product${items.length == 1 ? '' : 's'} (${cart.totalUnits} total units) in your cart',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < items.length; i++)
                      FadeSlideIn.staggered(
                        key: ValueKey('cart-item-${items[i].product.id}'),
                        index: i,
                        child: _buildCartItem(items[i], theme, currency),
                      ),
                    const SizedBox(height: 6),
                    _buildPromoAndSummaryCard(theme, cart, currency),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: items.isEmpty
          ? null
          : _buildCheckoutBar(theme, cart, currency, items),
    );
  }
}

class _CheckoutDetails {
  final String name;
  final String email;
  final String streetAddress;
  final String city;
  final String stateProvince;
  final String country;
  final String postalCode;
  final bool saveAddress;
  final String paymentMethod; // 'STRIPE' or 'COD'

  const _CheckoutDetails({
    required this.name,
    required this.email,
    required this.streetAddress,
    required this.city,
    required this.stateProvince,
    required this.country,
    required this.postalCode,
    required this.saveAddress,
    this.paymentMethod = 'STRIPE',
  });
}

class _CheckoutDetailsDialog extends StatefulWidget {
  final String initialEmail;
  final bool isAuthenticated;
  final List<SavedAddress> savedAddresses;

  const _CheckoutDetailsDialog({
    required this.initialEmail,
    required this.isAuthenticated,
    required this.savedAddresses,
  });

  @override
  State<_CheckoutDetailsDialog> createState() =>
      _CheckoutDetailsDialogState();
}

class _CheckoutDetailsDialogState extends State<_CheckoutDetailsDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _streetController;
  late final TextEditingController _cityController;
  late final TextEditingController _stateController;
  late final TextEditingController _postalController;

  bool _saveAddress = false;
  int? _selectedAddressId;
  String _paymentMethod = 'STRIPE'; // Default to Stripe online card checkout

  @override
  void initState() {
    super.initState();

    SavedAddress? def;
    if (widget.savedAddresses.isNotEmpty) {
      def = widget.savedAddresses.firstWhere(
        (a) => a.isDefault,
        orElse: () => widget.savedAddresses.first,
      );
      _selectedAddressId = def.id;
    }

    _nameController = TextEditingController(
      text: def?.recipientName ?? '',
    );
    _emailController = TextEditingController(
      text: widget.initialEmail,
    );
    _streetController = TextEditingController(
      text: def?.streetAddress ?? '',
    );
    _cityController = TextEditingController(
      text: def?.city ?? '',
    );
    _stateController = TextEditingController(
      text: def?.stateProvince ?? 'Punjab',
    );
    _postalController = TextEditingController(
      text: def?.postalCode ?? '',
    );
  }

  void _applySavedAddress(SavedAddress addr) {
    setState(() {
      _selectedAddressId = addr.id;
      _nameController.text = addr.recipientName;
      _streetController.text = addr.streetAddress;
      _cityController.text = addr.city;
      _stateController.text = addr.stateProvince;
      _postalController.text = addr.postalCode;
      _saveAddress = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _streetController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _postalController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.of(context).pop(
      _CheckoutDetails(
        name: _nameController.text.trim(),
        email: _emailController.text.trim().toLowerCase(),
        streetAddress: _streetController.text.trim(),
        city: _cityController.text.trim(),
        stateProvince: _stateController.text.trim().isEmpty
            ? 'Punjab'
            : _stateController.text.trim(),
        country: 'Pakistan',
        postalCode: _postalController.text.trim(),
        saveAddress: widget.isAuthenticated && _saveAddress,
        paymentMethod: _paymentMethod,
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String? Function(String?) validator,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 19),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      title: const Text(
        'Delivery Details',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.savedAddresses.isNotEmpty) ...[
                  const Text(
                    'Saved Addresses',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: widget.savedAddresses.map((addr) {
                      final selected = _selectedAddressId == addr.id;
                      return ChoiceChip(
                        label: Text(
                          '${addr.label} (${addr.city})',
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: selected,
                        onSelected: (_) => _applySavedAddress(addr),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                _buildField(
                  controller: _nameController,
                  label: 'Full Name',
                  icon: Icons.person_outline,
                  validator: (value) {
                    if (value == null || value.trim().length < 2) {
                      return 'Enter your full name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _buildField(
                  controller: _emailController,
                  label: 'Email Address',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    final email = value?.trim() ?? '';
                    final valid = RegExp(
                      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                    ).hasMatch(email);
                    if (!valid) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _buildField(
                  controller: _streetController,
                  label: 'Street Address',
                  icon: Icons.home_outlined,
                  maxLines: 2,
                  validator: (value) {
                    if (value == null || value.trim().length < 5) {
                      return 'Enter your full delivery address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _buildField(
                  controller: _cityController,
                  label: 'City',
                  icon: Icons.location_city_outlined,
                  validator: (value) {
                    if (value == null || value.trim().length < 2) {
                      return 'Enter your city';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildField(
                        controller: _stateController,
                        label: 'Province',
                        icon: Icons.map_outlined,
                        validator: (value) {
                          if (value == null || value.trim().length < 2) {
                            return 'Required';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildField(
                        controller: _postalController,
                        label: 'Postal Code',
                        icon: Icons.markunread_mailbox_outlined,
                        keyboardType: TextInputType.streetAddress,
                        validator: (value) {
                          if (value == null || value.trim().length < 3) {
                            return 'Required';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                if (widget.isAuthenticated) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _saveAddress,
                    onChanged: (val) =>
                        setState(() => _saveAddress = val ?? false),
                    title: const Text(
                      'Save this address for future checkouts',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                const Text(
                  'Select Payment Method',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _paymentMethod = 'STRIPE'),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _paymentMethod == 'STRIPE'
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).dividerColor,
                        width: _paymentMethod == 'STRIPE' ? 1.8 : 1.0,
                      ),
                      color: _paymentMethod == 'STRIPE'
                          ? Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.08)
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _paymentMethod == 'STRIPE'
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: _paymentMethod == 'STRIPE'
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.credit_card_rounded, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Pay Online with Card (Stripe)',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                'Instant Visa / Mastercard checkout • Email sent after payment',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _paymentMethod = 'COD'),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _paymentMethod == 'COD'
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).dividerColor,
                        width: _paymentMethod == 'COD' ? 1.8 : 1.0,
                      ),
                      color: _paymentMethod == 'COD'
                          ? Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.08)
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _paymentMethod == 'COD'
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: _paymentMethod == 'COD'
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.payments_outlined, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Cash on Delivery (COD)',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                'Pay cash upon doorstep delivery • Instant order dispatch',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(
            _paymentMethod == 'STRIPE'
                ? Icons.lock_rounded
                : Icons.check_circle_outline_rounded,
            size: 17,
          ),
          label: Text(
            _paymentMethod == 'STRIPE'
                ? 'Proceed to Stripe Payment'
                : 'Place COD Order',
          ),
        ),
      ],
    );
  }
}
