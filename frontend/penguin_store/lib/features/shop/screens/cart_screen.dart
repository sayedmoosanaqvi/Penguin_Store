
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/services/stripe_payment_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  // Stripe code remains intact and ready; paused while COD/manual dispatch is active.
  static const bool _stripePaymentsEnabled = false;

  bool _isCheckingOut = false;

  Future<void> _processDynamicCheckout(
    _CheckoutDetails details,
    List<CartItem> items,
  ) async {
    if (_isCheckingOut || items.isEmpty) return;

    setState(() => _isCheckingOut = true);

    try {
      final cartPayloadItems = items.map((item) {
        return {
          'product_id': item.product.id,
          'quantity': item.quantity,
        };
      }).toList();

      final token = (await SecureStorageService.getToken())?.trim();
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

      if (_stripePaymentsEnabled) {
        await StripePaymentService.startCheckout(
          orderId: createdOrderId,
          currency: 'usd',
        );
        return;
      }

      context.read<CartProvider>().clear();
      CustomToast.show(
        context,
        'Order #$createdOrderId placed! Confirmation sent to ${details.email}.',
      );
      context.go('/success');
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

  Future<void> _showCheckoutForm(
    List<CartItem> items,
  ) async {
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
                color: theme.primaryColor.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_bag_outlined,
                size: 52,
                color: theme.primaryColor,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Your Cart is Empty',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Discover something special and add it to your cart.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.go('/discover'),
              icon: const Icon(
                Icons.grid_view_rounded,
                size: 18,
              ),
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
  ) {
    final product = item.product;
    final cart = context.read<CartProvider>();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.primaryColor.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/product/${product.id}'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                product.imageUrl,
                width: 78,
                height: 85,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) {
                  return Container(
                    width: 78,
                    height: 85,
                    color: theme.primaryColor.withValues(alpha: 0.05),
                    child: const Icon(
                      Icons.image_not_supported_outlined,
                    ),
                  );
                },
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
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
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
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.selectedVariant != null
                        ? '${product.category}  •  ${item.selectedVariant}'
                        : product.category,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '\$${product.price.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.primaryColor.withValues(alpha: 0.16),
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
                                  color: theme.primaryColor,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                '${item.quantity}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: theme.primaryColor,
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
                                  color: theme.primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '\$${(product.price * item.quantity).toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
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

  Widget _buildCheckoutBar(
    ThemeData theme,
    CartProvider cart,
    List<CartItem> items,
  ) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
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
                    'Total Payment',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '\$${cart.totalPrice.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _isCheckingOut
                  ? null
                  : () => _showCheckoutForm(items),
              style: FilledButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: _isCheckingOut
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'CHECKOUT',
                      style: TextStyle(
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
                  padding: const EdgeInsets.fromLTRB(
                    12, 12, 12, 24,
                  ),
                  children: [
                    Text(
                      '${items.length} products in your cart',
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
                        child: _buildCartItem(items[i], theme),
                      ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.dividerColor.withValues(
                            alpha: 0.16,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Subtotal',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '\$${cart.totalPrice.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 22),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                '\$${cart.totalPrice.toStringAsFixed(2)}',
                                style: TextStyle(
                                  color: theme.primaryColor,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
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
            ),
      bottomNavigationBar: items.isEmpty
          ? null
          : _buildCheckoutBar(theme, cart, items),
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

  const _CheckoutDetails({
    required this.name,
    required this.email,
    required this.streetAddress,
    required this.city,
    required this.stateProvince,
    required this.country,
    required this.postalCode,
    required this.saveAddress,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text(
        'Shipping & Checkout',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.local_shipping_outlined, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Cash on Delivery / Pay on Dispatch (Online card payments are paused).',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.savedAddresses.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Saved Addresses',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: widget.savedAddresses.map((addr) {
                      return ChoiceChip(
                        label: Text('${addr.label} • ${addr.city}'),
                        selected: _selectedAddressId == addr.id,
                        onSelected: (_) => _applySavedAddress(addr),
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().length < 2) ? 'Required' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Receipt Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (value) {
                    final email = value?.trim() ?? '';
                    if (email.isEmpty ||
                        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                            .hasMatch(email)) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _streetController,
                  decoration: const InputDecoration(
                    labelText: 'Street Address',
                    prefixIcon: Icon(Icons.home_outlined),
                  ),
                  validator: (v) => (v == null || v.trim().length < 4)
                      ? 'Enter delivery street address'
                      : null,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _cityController,
                        decoration: const InputDecoration(labelText: 'City'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Required'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _postalController,
                        decoration:
                            const InputDecoration(labelText: 'Postal Code'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Required'
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _stateController,
                  decoration:
                      const InputDecoration(labelText: 'State / Province'),
                ),
                if (widget.isAuthenticated) ...[
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Save this shipping address',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: _saveAddress,
                    onChanged: (v) => setState(() => _saveAddress = v),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
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
                  saveAddress: _saveAddress,
                ),
              );
            }
          },
          child: const Text('Place Order'),
        ),
      ],
    );
  }
}
