import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/cart_provider.dart';
import '../services/stripe_payment_service.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = Provider.of<CartProvider>(context);
    final items = cart.items.values.toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Your Cart'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.whiteText,
      ),
      body: items.isEmpty
          ? const Center(
              child: Text(
                'Your cart is empty.',
                style: TextStyle(color: AppColors.whiteText, fontSize: 16),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final product = item.product;

                return Card(
                  color: AppColors.card,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: Image.network(
                      product.imageUrl,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                    title: Text(
                      product.name,
                      style: const TextStyle(color: AppColors.whiteText),
                    ),
                    subtitle: Text(
                      '\$${product.price}  x${item.quantity}',
                      style: const TextStyle(color: AppColors.greyText),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.card,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total: \$${cart.totalPrice.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: AppColors.whiteText,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                onPressed: items.isEmpty
                    ? null
                    : () async {
                        try {
                          // 1. Prepare cart items for your FastAPI checkout payload
                          final cartPayloadItems = items.map((item) => {
                            'product_id': item.product.id,
                            'quantity': item.quantity,
                          }).toList();

                          // 2. Call your FastAPI /api/orders/checkout endpoint
                          final checkoutResponse = await http.post(
                            Uri.parse('http://127.0.0.1:8000/api/orders/checkout'),
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({
                              'customer_name': 'Moosa Raza',
                              'customer_email': 'moosa@penguin.com',
                              'shipping_address': '123 Main St',
                              'city': 'Sargodha',
                              'postal_code': '40100',
                              'items': cartPayloadItems,
                            }),
                          );

                          if (checkoutResponse.statusCode == 200) {
                            final orderData = json.decode(checkoutResponse.body);
                            final int createdOrderId = orderData['order_id'];

                            // 3. Generate Stripe Session using the secure order ID
                            await StripePaymentService.startCheckout(
                              orderId: createdOrderId,
                              currency: 'usd',
                            );
                            
                            cart.clear();
                          } else {
                            throw Exception('Checkout failed: ${checkoutResponse.body}');
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      },
                child: const Text('CHECKOUT'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}