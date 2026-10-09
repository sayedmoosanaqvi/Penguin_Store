
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/services/stripe_payment_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _isCheckingOut = false;

  Future<void> _processDynamicCheckout(
    String email,
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

      final checkoutResponse = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/orders/checkout'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'customer_name': 'Valued Customer',
          'customer_email': email,
          'shipping_address': '123 Main St',
          'city': 'Sargodha',
          'postal_code': '40100',
          'items': cartPayloadItems,
        }),
      );

      if (checkoutResponse.statusCode != 200) {
        throw Exception(
          'Checkout failed: ${checkoutResponse.body}',
        );
      }

      final orderData = jsonDecode(checkoutResponse.body);

      final int createdOrderId =
          (orderData['order_id'] as num).toInt();

      if (!mounted) return;

      await StripePaymentService.startCheckout(
        orderId: createdOrderId,
        currency: 'usd',
      );

      // Keep cart items until payment success is verified.
    } catch (e) {
      if (!mounted) return;

      CustomToast.show(
        context,
        'Checkout error: $e',
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

    final email = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return _CheckoutEmailDialog(
          initialEmail: auth.userEmail ?? '',
        );
      },
    );

    if (!mounted || email == null) return;

    await _processDynamicCheckout(email, items);
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

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.16),
        ),
      ),
      child: InkWell(
        onTap: () => context.push('/product/${product.id}'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
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
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    product.category,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '\$${product.price.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withValues(
                            alpha: 0.09,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Qty: ${item.quantity}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: theme.primaryColor,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '\$${(product.price * item.quantity).toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
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
                    for (final item in items)
                      _buildCartItem(item, theme),
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

class _CheckoutEmailDialog extends StatefulWidget {
  final String initialEmail;

  const _CheckoutEmailDialog({
    required this.initialEmail,
  });

  @override
  State<_CheckoutEmailDialog> createState() =>
      _CheckoutEmailDialogState();
}

class _CheckoutEmailDialogState extends State<_CheckoutEmailDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _emailController;

  @override
  void initState() {
    super.initState();

    _emailController = TextEditingController(
      text: widget.initialEmail,
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Checkout Details',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Where should we send your order receipt?',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email Address',
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
          ],
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
                _emailController.text.trim(),
              );
            }
          },
          child: const Text('Continue to Payment'),
        ),
      ],
    );
  }
}
