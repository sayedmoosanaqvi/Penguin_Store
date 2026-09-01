import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';

class OrderTrackingScreen extends StatefulWidget {
  final String customerEmail;

  const OrderTrackingScreen({super.key, required this.customerEmail});

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  bool _isLoading = true;
  List<dynamic> _orders = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchOrderHistory();
  }

  Future<void> _fetchOrderHistory() async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/orders/history/${widget.customerEmail}'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _orders = data['orders'];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to load order history.';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error connecting to server: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('My Orders & Tracking'),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: theme.primaryColor))
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)))
              : _orders.isEmpty
                  ? Center(
                      child: Text(
                        'No past orders found.',
                        style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _orders.length,
                      itemBuilder: (context, index) {
                        final order = _orders[index];
                        return Card(
                          color: theme.cardTheme.color,
                          margin: const EdgeInsets.only(bottom: 16),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Order #${order['order_id']}',
                                      style: TextStyle(
                                        color: theme.textTheme.titleMedium?.color,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    Text(
                                      '\$${order['total_amount'].toStringAsFixed(2)}',
                                      style: TextStyle(
                                        color: theme.primaryColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Shipped to: ${order['shipping_address']}, ${order['city']}',
                                  style: TextStyle(color: theme.textTheme.bodySmall?.color, fontSize: 13),
                                ),
                                const Divider(color: Colors.grey, height: 20),
                                ...((order['items'] as List).map((item) {
                                  final isDropship = item['fulfillment_type'] == 'DROPSHIP';
                                  final badgeColor = isDropship ? Colors.blueAccent : Colors.amber.shade700;

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${item['product_name']} (x${item['quantity']})',
                                                style: TextStyle(
                                                  color: theme.textTheme.bodyLarge?.color,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            // Enhanced Modern Badge UI
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: badgeColor.withOpacity(0.15),
                                                borderRadius: BorderRadius.circular(20),
                                                border: Border.all(color: badgeColor.withOpacity(0.4)),
                                              ),
                                              child: Text(
                                                item['fulfillment_type'],
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: badgeColor,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Status: ${item['dispatch_status']} | Tracking: ${item['tracking_number'] ?? 'Pending'}',
                                          style: TextStyle(color: theme.textTheme.bodySmall?.color, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  );
                                })),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}