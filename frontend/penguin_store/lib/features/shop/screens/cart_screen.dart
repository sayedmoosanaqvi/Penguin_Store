import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:provider/provider.dart';
import '../providers/cart_provider.dart';
import '../services/stripe_payment_service.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = Provider.of<CartProvider>(context);
    final items = cart.items.values.toList();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Your Cart'),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                'Your cart is empty.',
                style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontSize: 16),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final product = item.product;

                return Card(
                  color: theme.cardTheme.color,
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
                      style: TextStyle(color: theme.textTheme.titleMedium?.color),
                    ),
                    subtitle: Text(
                      '\$${product.price}  x${item.quantity}',
                      style: TextStyle(color: theme.textTheme.bodySmall?.color),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          color: theme.cardTheme.color,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total: \$${cart.totalPrice.toStringAsFixed(2)}',
                style: TextStyle(
                  color: theme.textTheme.titleLarge?.color,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              ElevatedButton(
                onPressed: items.isEmpty
                    ? null
                    : () async {
                        try {
                          final cartPayloadItems = items.map((item) => {
                            'product_id': item.product.id,
                            'quantity': item.quantity,
                          }).toList();

                          final checkoutResponse = await http.post(
                            Uri.parse('${ApiConfig.baseUrl}/api/orders/checkout'),
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