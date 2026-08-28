import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import '../../../core/theme/app_colors.dart';
 // Ensure path matches your file tree structure

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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('My Orders & Tracking'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.whiteText,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)))
              : _orders.isEmpty
                  ? const Center(
                      child: Text(
                        'No past orders found.',
                        style: TextStyle(color: AppColors.whiteText, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _orders.length,
                      itemBuilder: (context, index) {
                        final order = _orders[index];
                        return Card(
                          color: AppColors.card,
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
                                      style: const TextStyle(
                                        color: AppColors.whiteText,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    Text(
                                      '\$${order['total_amount'].toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        color: Colors.orange,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Shipped to: ${order['shipping_address']}, ${order['city']}',
                                  style: const TextStyle(color: AppColors.greyText, fontSize: 13),
                                ),
                                const Divider(color: Colors.grey, height: 20),
                                ...((order['items'] as List).map((item) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${item['product_name']} (x${item['quantity']})',
                                                style: const TextStyle(color: AppColors.whiteText),
                                              ),
                                            ),
                                            Chip(
                                              label: Text(
                                                item['fulfillment_type'],
                                                style: const TextStyle(fontSize: 10, color: Colors.black),
                                              ),
                                              backgroundColor: item['fulfillment_type'] == 'DROPSHIP'
                                                  ? Colors.blueAccent
                                                  : Colors.amber,
                                              padding: EdgeInsets.zero,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Status: ${item['dispatch_status']} | Tracking: ${item['tracking_number'] ?? 'Pending'}',
                                          style: const TextStyle(color: AppColors.greyText, fontSize: 12),
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