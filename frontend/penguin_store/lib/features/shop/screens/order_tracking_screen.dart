import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class OrderTrackingScreen extends StatefulWidget {
  final String customerEmail;

  const OrderTrackingScreen({super.key, required this.customerEmail});

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  bool _isLoading = true;
  int? _reorderingOrderId;
  List<dynamic> _orders = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchOrderHistory();
  }

  Future<void> _reorderOrder(Map<dynamic, dynamic> order) async {
    final orderId = (order['order_id'] as num?)?.toInt();
    final rawItems = order['items'] as List? ?? [];
    if (rawItems.isEmpty || _reorderingOrderId != null) return;

    setState(() => _reorderingOrderId = orderId);
    final cart = context.read<CartProvider>();
    final productService = ProductService();
    final cached = ProductService.cachedProducts ?? const <Product>[];

    try {
      int addedCount = 0;
      for (final raw in rawItems.whereType<Map>()) {
        final pid = (raw['product_id'] as num?)?.toInt();
        if (pid == null) continue;
        final qty = ((raw['quantity'] as num?)?.toInt() ?? 1).clamp(1, 50);

        Product? product;
        for (final p in cached) {
          if (p.id == pid) {
            product = p;
            break;
          }
        }
        product ??= await productService.fetchProductById(pid).catchError(
              (_) => null,
            );
        product ??= Product(
          id: pid,
          name: (raw['product_name'] ?? 'Product #$pid').toString(),
          description: '',
          price: (raw['unit_price'] as num?)?.toDouble() ?? 0.0,
          imageUrl: Product.resolveImageUrl(null),
          category: 'CATALOG',
          rating: 4.8,
          reviews: 0,
        );

        cart.addToCart(product, quantity: qty);
        addedCount += qty;
      }

      if (!mounted) return;
      if (addedCount > 0) {
        CustomToast.show(
          context,
          'Added $addedCount item${addedCount == 1 ? '' : 's'} from Order #$orderId to cart!',
        );
        context.go('/cart');
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, ApiErrorHandler.sanitize(e), isError: true);
      }
    } finally {
      if (mounted) setState(() => _reorderingOrderId = null);
    }
  }

  Widget _buildOrdersSkeleton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        highlightColor: isDark ? Colors.grey.shade700 : Colors.grey.shade50,
        child: Container(
          height: 155,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Future<void> _fetchOrderHistory() async {
    final cleanEmail = widget.customerEmail.trim();
    if (cleanEmail.isEmpty) {
      setState(() {
        _orders = [];
        _isLoading = false;
      });
      return;
    }

    try {
      final token = (await SecureStorageService.getToken())?.trim();
      final headers = <String, String>{
        'Accept': 'application/json',
        if (token != null && token.isNotEmpty)
          'Authorization': 'Bearer $token',
      };

      final response = await http.get(
        Uri.parse(
          '${ApiConfig.baseUrl}/api/orders/history/${Uri.encodeComponent(cleanEmail)}',
        ),
        headers: headers,
      ).timeout(const Duration(seconds: 25));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _orders = data['orders'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = ApiErrorHandler.fromStatus(
            response.statusCode,
            response.body,
            fallback: 'Failed to load order history.',
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = ApiErrorHandler.sanitize(e);
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
          ? _buildOrdersSkeleton(theme)
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
                        final orderId = (order['order_id'] as num?)?.toInt();
                        final isReordering = _reorderingOrderId == orderId;
                        return FadeSlideIn.staggered(
                          index: index,
                          child: Card(
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
                                        '\$${(order['total_amount'] as num).toStringAsFixed(2)}',
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
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: isReordering
                                          ? null
                                          : () => _reorderOrder(order as Map),
                                      icon: isReordering
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.replay_rounded, size: 18),
                                      label: Text(
                                        isReordering ? 'Adding items...' : 'One-Tap Reorder',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}