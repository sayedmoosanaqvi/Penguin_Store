import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class OrderTrackingScreen extends StatefulWidget {
  final String customerEmail;

  const OrderTrackingScreen({super.key, required this.customerEmail});

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  final CommerceService _commerceService = CommerceService();
  bool _isLoading = true;
  bool _isLoadingRfqs = true;
  int? _reorderingOrderId;
  List<dynamic> _orders = [];
  List<Map<String, dynamic>> _rfqs = [];
  String? _errorMessage;

  String get _effectiveEmail {
    final fromWidget = widget.customerEmail.trim();
    if (fromWidget.isNotEmpty) return fromWidget;
    return context.read<AuthProvider>().userEmail?.trim() ?? '';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchOrderHistory();
      _fetchMyRfqs();
    });
  }

  Future<void> _fetchMyRfqs() async {
    final email = _effectiveEmail;
    if (email.isEmpty) {
      if (mounted) setState(() => _isLoadingRfqs = false);
      return;
    }
    setState(() => _isLoadingRfqs = true);
    try {
      final list = await _commerceService.fetchMyRfqs(email: email);
      if (mounted) {
        setState(() {
          _rfqs = list;
          _isLoadingRfqs = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingRfqs = false);
    }
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
        final qty = ((raw['quantity'] as num?)?.toInt() ?? 1).clamp(1, 500);
        final unitPrice = (raw['unit_price'] as num?)?.toDouble();

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
          price: unitPrice ?? 0.0,
          imageUrl: Product.resolveImageUrl(null),
          category: 'CATALOG',
          rating: 4.8,
          reviews: 0,
        );

        cart.addToCart(
          product,
          quantity: qty,
          variant: raw['selected_variant']?.toString(),
          unitPrice: unitPrice,
          pricingMode: (raw['pricing_mode'] ?? 'B2C').toString(),
        );
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

  /// Phase 2.2: Printable / Downloadable Itemized Order Invoice Dialog.
  Future<void> _showOrderInvoiceDialog(
    Map<dynamic, dynamic> order,
    CurrencyProvider currency,
  ) async {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final orderId = order['order_id'];
    final createdAt = (order['created_at'] ?? '').toString();
    final dateLabel =
        createdAt.length >= 10 ? createdAt.substring(0, 10) : 'Today';
    final items = (order['items'] as List? ?? []).whereType<Map>().toList();
    final subtotal = (order['subtotal_amount'] as num?)?.toDouble() ??
        (order['total_amount'] as num?)?.toDouble() ??
        0.0;
    final discount = (order['discount_amount'] as num?)?.toDouble() ?? 0.0;
    final tax = (order['tax_amount'] as num?)?.toDouble() ?? 0.0;
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final promo = order['promo_code']?.toString();
    final address =
        '${order['shipping_address'] ?? ''}, ${order['city'] ?? ''} ${order['postal_code'] ?? ''}';

    final receiptBuffer = StringBuffer()
      ..writeln('=============================================')
      ..writeln('         PENGUIN STORE OFFICIAL INVOICE      ')
      ..writeln('=============================================')
      ..writeln('Invoice #: INV-$orderId')
      ..writeln('Order Date: $dateLabel')
      ..writeln('Customer: ${_effectiveEmail}')
      ..writeln('Delivery Address: $address')
      ..writeln('---------------------------------------------')
      ..writeln('ITEMS:');

    for (final it in items) {
      final qty = (it['quantity'] as num?)?.toInt() ?? 1;
      final up = (it['unit_price'] as num?)?.toDouble() ?? 0.0;
      final variant = it['selected_variant']?.toString();
      receiptBuffer.writeln(
        '- ${it['product_name']}${variant != null && variant.isNotEmpty ? ' [$variant]' : ''} '
        'x$qty @ ${currency.format(up)} = ${currency.format(up * qty)}',
      );
    }
    receiptBuffer
      ..writeln('---------------------------------------------')
      ..writeln('Subtotal: ${currency.format(subtotal)}');
    if (discount > 0) {
      receiptBuffer.writeln(
        'Promo Discount (${promo ?? "PROMO"}): -${currency.format(discount)}',
      );
    }
    if (tax > 0) {
      receiptBuffer.writeln('Tax & Handling: ${currency.format(tax)}');
    }
    receiptBuffer
      ..writeln('GRAND TOTAL: ${currency.format(total)}')
      ..writeln('=============================================');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.receipt_long_rounded, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Invoice #INV-$orderId',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: colors.onSurface,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'VERIFIED',
                style: TextStyle(
                  color: Color(0xFF16A34A),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Penguin Store Commercial Receipt • Date: $dateLabel',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Ship To: $address',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const Divider(height: 22),
                ...items.map((it) {
                  final qty = (it['quantity'] as num?)?.toInt() ?? 1;
                  final up = (it['unit_price'] as num?)?.toDouble() ?? 0.0;
                  final variant = it['selected_variant']?.toString();
                  final addons = (it['selected_addons'] as List?)
                          ?.map((e) => e.toString())
                          .toList() ??
                      const <String>[];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${it['product_name']} (x$qty)',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: colors.onSurface,
                                ),
                              ),
                              if (variant != null && variant.isNotEmpty)
                                Text(
                                  'Option: $variant',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.primary,
                                  ),
                                ),
                              if (addons.isNotEmpty)
                                Text(
                                  'Add-Ons: ${addons.join(", ")}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF16A34A),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          currency.format(up * qty),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const Divider(height: 20),
                _invoiceRow('Subtotal', currency.format(subtotal), colors),
                if (discount > 0)
                  _invoiceRow(
                    'Promo Discount (${promo ?? "PROMO"})',
                    '-${currency.format(discount)}',
                    colors,
                    valueColor: const Color(0xFF16A34A),
                  ),
                if (tax > 0)
                  _invoiceRow(
                    'Tax & Handling (5%)',
                    currency.format(tax),
                    colors,
                  ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total Paid',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: colors.onSurface,
                      ),
                    ),
                    Text(
                      currency.format(total),
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: receiptBuffer.toString()),
              );
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                CustomToast.show(
                  context,
                  'Invoice #INV-$orderId copied to clipboard for printing/saving!',
                );
              }
            },
            icon: const Icon(Icons.download_rounded, size: 17),
            label: const Text('Copy / Save Invoice'),
          ),
        ],
      ),
    );
  }

  Widget _invoiceRow(
    String label,
    String value,
    ColorScheme colors, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: valueColor ?? colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrdersSkeleton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (_, _) => Shimmer.fromColors(
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
    final cleanEmail = _effectiveEmail;
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
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final response = await http
          .get(
            Uri.parse(
              '${ApiConfig.baseUrl}/api/orders/history/${Uri.encodeComponent(cleanEmail)}',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 25));

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
    final colors = theme.colorScheme;
    final currency = context.watch<CurrencyProvider>();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('Orders, Invoices & B2B Quotes'),
          backgroundColor: theme.appBarTheme.backgroundColor,
          foregroundColor: theme.appBarTheme.foregroundColor,
          bottom: TabBar(
            labelColor: colors.primary,
            unselectedLabelColor: colors.onSurfaceVariant,
            indicatorColor: colors.primary,
            tabs: [
              Tab(
                icon: const Icon(Icons.local_shipping_outlined, size: 18),
                text: 'My Orders (${_orders.length})',
              ),
              Tab(
                icon: const Icon(Icons.request_quote_outlined, size: 18),
                text: 'B2B Quotes / RFQs (${_rfqs.length})',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildOrdersTab(theme, colors, currency),
            _buildRfqsTab(theme, colors, currency),
          ],
        ),
      ),
    );
  }

  Widget _buildOrdersTab(
    ThemeData theme,
    ColorScheme colors,
    CurrencyProvider currency,
  ) {
    if (_isLoading) return _buildOrdersSkeleton(theme);
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: colors.error),
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.error),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _fetchOrderHistory,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_orders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 56,
                color: colors.primary.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 12),
              Text(
                'No Past Orders Found',
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Place an order to track shipments and download official invoices here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _orders.length,
      itemBuilder: (context, index) {
        final order = _orders[index] as Map;
        final orderId = (order['order_id'] as num?)?.toInt();
        final isReordering = _reorderingOrderId == orderId;
        final totalAmount = (order['total_amount'] as num?)?.toDouble() ?? 0.0;

        return FadeSlideIn.staggered(
          index: index,
          child: Card(
            color: colors.surface,
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
                          color: colors.onSurface,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        currency.format(totalAmount),
                        style: TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 16.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Shipped to: ${order['shipping_address']}, ${order['city']}',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  ),
                  const Divider(height: 20),
                  ...((order['items'] as List? ?? []).map((item) {
                    final isDropship = item['fulfillment_type'] == 'DROPSHIP';
                    final badgeColor = isDropship
                        ? Colors.blueAccent
                        : Colors.amber.shade700;
                    final variant = item['selected_variant']?.toString();

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
                                  '${item['product_name']} (x${item['quantity']})${variant != null && variant.isNotEmpty ? ' • $variant' : ''}',
                                  style: TextStyle(
                                    color: colors.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: badgeColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: badgeColor.withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  (item['fulfillment_type'] ?? 'IN_HOUSE')
                                      .toString(),
                                  style: TextStyle(
                                    fontSize: 10.5,
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
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  })),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _showOrderInvoiceDialog(order, currency),
                          icon: const Icon(
                            Icons.receipt_long_rounded,
                            size: 17,
                          ),
                          label: const Text('View / Download Invoice'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed:
                              isReordering ? null : () => _reorderOrder(order),
                          icon: isReordering
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.replay_rounded, size: 17),
                          label: Text(
                            isReordering ? 'Adding...' : 'One-Tap Reorder',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRfqsTab(
    ThemeData theme,
    ColorScheme colors,
    CurrencyProvider currency,
  ) {
    if (_isLoadingRfqs) return _buildOrdersSkeleton(theme);
    if (_rfqs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.request_quote_outlined,
                size: 56,
                color: colors.primary.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 12),
              Text(
                'No Bulk Quotes (RFQs) Submitted Yet',
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Open any product page and tap "Request Bulk Quote (RFQ)" to negotiate custom wholesale pricing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchMyRfqs,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _rfqs.length,
        itemBuilder: (context, index) {
          final rfq = _rfqs[index];
          final status = (rfq['status'] ?? 'Pending').toString();
          final qty = (rfq['quantity'] as num?)?.toInt() ?? 10;
          final targetPrice =
              (rfq['target_unit_price'] as num?)?.toDouble() ?? 0.0;
          final quotedPrice =
              (rfq['admin_quote_price'] as num?)?.toDouble();
          final adminReply = (rfq['admin_reply'] ?? '').toString();

          final Color statusColor = switch (status) {
            'Approved' || 'Quoted' => const Color(0xFF16A34A),
            'Rejected' => colors.error,
            _ => const Color(0xFFD97706),
          };

          return Card(
            color: colors.surface,
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'RFQ #${rfq['id']} • ${rfq['product_name']}',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          status.toUpperCase(),
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Requested Quantity: $qty units  •  Target Unit Price: ${currency.format(targetPrice)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if ((rfq['customization_notes'] ?? '')
                      .toString()
                      .isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Notes: ${rfq['customization_notes']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (quotedPrice != null || adminReply.isNotEmpty) ...[
                    const Divider(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (quotedPrice != null)
                            Text(
                              'Official Quoted Unit Price: ${currency.format(quotedPrice)} (Total: ${currency.format(quotedPrice * qty)})',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 13.5,
                                color: colors.primary,
                              ),
                            ),
                          if (adminReply.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Supplier Reply: $adminReply',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurface,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
