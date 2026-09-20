import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:provider/provider.dart';
import '../providers/cart_provider.dart';
import '../services/stripe_payment_service.dart';
import '../services/notification_service.dart'; 
import 'package:penguin_store/features/shop/widgets/premium_interactive_card.dart';
// ---> NEW IMPORT FOR CUSTOM TOAST <---
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  Future<void> _processDynamicCheckout(
      BuildContext context, 
      String dynamicEmail, 
      List<dynamic> items, 
      CartProvider cart) async {
    
    try {
      final cartPayloadItems = items.map((item) => {
        'product_id': item.product.id,
        'quantity': item.quantity,
      }).toList();

      final checkoutResponse = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/orders/checkout'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'customer_name': 'Valued Customer', 
          'customer_email': dynamicEmail, 
          'shipping_address': '123 Main St',
          'city': 'Sargodha',
          'postal_code': '40100',
          'items': cartPayloadItems,
        }),
      );

      if (checkoutResponse.statusCode == 200) {
        final orderData = json.decode(checkoutResponse.body);
        final int createdOrderId = orderData['order_id'];

        await StripePaymentService.startCheckout(
          orderId: createdOrderId,
          currency: 'usd',
        );
        
        cart.clear();

        if (context.mounted) {
          NotificationService.showPushBanner(
            context,
            'Payment Successful! 🎉',
            'Your order #$createdOrderId is confirmed and processing.',
          );
        }

      } else {
        throw Exception('Checkout failed: ${checkoutResponse.body}');
      }
    } catch (e) {
      if (context.mounted) {
        // ---> TRIGGER PREMIUM ERROR TOAST <---
        CustomToast.show(context, 'Error: $e', isError: true);
      }
    }
  }

  void _showCheckoutForm(BuildContext context, List<dynamic> items, CartProvider cart) {
    final emailController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).cardTheme.color,
        title: const Text('Checkout Details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Where should we send your receipt?'),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email Address',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final typedEmail = emailController.text.trim();
              if (typedEmail.isNotEmpty) {
                Navigator.pop(dialogContext);
                _processDynamicCheckout(context, typedEmail, items, cart); 
              }
            },
            child: const Text('Continue to Payment'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.shopping_bag_outlined,
              size: 80,
              color: theme.primaryColor,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your Cart is Empty',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: theme.textTheme.titleLarge?.color,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Looks like you haven\'t added anything yet.\nLet\'s find something special for you!',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textTheme.bodyMedium?.color,
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 36),
          PremiumInteractiveCard(
            onTap: () => context.go('/'), 
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              decoration: BoxDecoration(
                color: theme.primaryColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: theme.primaryColor.withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Text(
                'START SHOPPING',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = Provider.of<CartProvider>(context);
    final items = cart.items.values.toList();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Your Cart', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
        centerTitle: true,
        elevation: 0,
      ),
      body: items.isEmpty
          ? _buildEmptyState(context, theme) 
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final product = item.product;

                return Card(
                  color: theme.cardTheme.color,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 2,
                  shadowColor: Colors.black.withOpacity(0.1),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          product.imageUrl,
                          width: 55,
                          height: 55,
                          fit: BoxFit.cover,
                        ),
                      ),
                      title: Text(
                        product.name,
                        style: TextStyle(
                          color: theme.textTheme.titleMedium?.color,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          '\$${product.price}  x${item.quantity}',
                          style: TextStyle(
                            color: theme.primaryColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: items.isEmpty 
        ? const SizedBox.shrink() 
        : SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  )
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Payment',
                        style: TextStyle(
                          color: theme.textTheme.bodySmall?.color,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '\$${cart.totalPrice.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: theme.textTheme.titleLarge?.color,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  PremiumInteractiveCard(
                    onTap: () => _showCheckoutForm(context, items, cart),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      decoration: BoxDecoration(
                        color: theme.primaryColor,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: const Text(
                        'CHECKOUT',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }
}