import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:uuid/uuid.dart';
import '../models/product_model.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';

// 1. Custom model to handle multi-modal responses (Text, Products, Bundles, Cart, Orders, Reasoning Trace)
class AgentMessage {
  final String role; // "user" or "bot"
  final String text;
  final String dataType; // "text", "product_list", "bundle", "cart_update", "order_tracker"
  final List<Product> suggestedProducts;
  final Map<String, dynamic>? orderAction;
  final Map<String, dynamic>? bundle;
  final List<Map<String, dynamic>> reasoningSteps;
  final String routedAgent;

  AgentMessage({
    required this.role,
    required this.text,
    this.dataType = "text",
    this.suggestedProducts = const [],
    this.orderAction,
    this.bundle,
    this.reasoningSteps = const [],
    this.routedAgent = "CTRL-X",
  });
}

class CtrlXScreen extends StatefulWidget {
  const CtrlXScreen({super.key});

  @override
  State<CtrlXScreen> createState() => _CtrlXScreenState();
}

class _CtrlXScreenState extends State<CtrlXScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<AgentMessage> _messages = [];
  bool _isLoading = false;

  // Unique session thread ID for LangGraph memory persistence
  final String _threadId = const Uuid().v4();

  static const List<String> _quickPrompts = [
    'Build a phone + earbuds bundle under \$1,200',
    'Build me a \$200 shirt + shoes outfit',
    'Do you have shirts?',
    'Recommend men shoes',
    'What is your return policy?',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendPromptText(String prompt) async {
    _controller.text = prompt;
    await _sendMessage();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      _messages.add(AgentMessage(role: "user", text: text));
      _isLoading = true;
    });

    _controller.clear();
    _scrollToBottom();

    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/agent/chat');

      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              "user_input": text,
              "thread_id": _threadId,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiReply =
            (data['response'] ?? "No response received.").toString();
        final dataType = (data['data_type'] ?? "text").toString();
        final routedAgent = (data['routed_agent'] ?? "CTRL-X").toString();

        List<Product> products = [];
        Map<String, dynamic>? orderData;
        Map<String, dynamic>? bundleData;
        List<Map<String, dynamic>> reasoningSteps = [];

        if (data['reasoning_steps'] is List) {
          reasoningSteps = (data['reasoning_steps'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }

        if (data['bundle'] is Map) {
          bundleData = Map<String, dynamic>.from(data['bundle'] as Map);
        }

        // 1. Handle Product Search or Bundle Results
        if ((dataType == "product_list" || dataType == "bundle") &&
            data['suggested_products'] is List) {
          final List<dynamic> rawProducts = data['suggested_products'];
          products = rawProducts
              .whereType<Map>()
              .map(
                (p) => Product(
                  id: (p['id'] as num?)?.toInt() ?? 0,
                  name: (p['name'] ?? 'Product').toString(),
                  price: (p['price'] as num?)?.toDouble() ?? 0.0,
                  originalPrice:
                      (p['original_price'] as num?)?.toDouble(),
                  category: (p['category'] ?? 'CATALOG').toString(),
                  isFeatured: p['is_featured'] == true,
                  discountPercent:
                      (p['discount_percent'] as num?)?.toInt(),
                  imageUrl: (p['image_url'] ?? '').toString().trim(),
                  description:
                      (p['description'] ?? 'Suggested by CTRL-X')
                          .toString(),
                  rating: ((p['trust_weighted_rating'] ?? p['rating']) as num?)
                          ?.toDouble() ??
                      4.8,
                  reviews: (p['reviews'] as num?)?.toInt() ?? 12,
                ),
              )
              .toList();
        }
        // 2. Handle Cart Actions
        else if (dataType == "cart_update" &&
            data['cart_action'] is Map) {
          final cartAction =
              Map<String, dynamic>.from(data['cart_action'] as Map);
          if (cartAction['action'] == "add_to_cart" &&
              cartAction['product'] is Map) {
            final productData = Map<String, dynamic>.from(
              cartAction['product'] as Map,
            );
            final int qty =
                (cartAction['quantity'] as num?)?.toInt() ?? 1;

            final aiProduct = Product(
              id: (productData['id'] as num?)?.toInt() ?? 0,
              name: (productData['name'] ?? 'Product').toString(),
              price: (productData['price'] as num?)?.toDouble() ?? 0.0,
              category: 'AI_ADDED',
              imageUrl:
                  (productData['image_url'] ?? '').toString().trim(),
              description: 'Added via CTRL-X',
              rating: 5.0,
              reviews: 1,
            );

            if (mounted) {
              final cart = Provider.of<CartProvider>(
                context,
                listen: false,
              );
              for (int i = 0; i < qty; i++) {
                cart.addToCart(aiProduct);
              }

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.white),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Added ${aiProduct.name} (x$qty) to cart!",
                        ),
                      ),
                    ],
                  ),
                  backgroundColor: Theme.of(context).primaryColor,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          }
        }
        // 3. Handle Order Status Tracking
        else if (dataType == "order_tracker" &&
            data['order_action'] is Map) {
          orderData = Map<String, dynamic>.from(
            data['order_action'] as Map,
          );
        }

        setState(() {
          _messages.add(
            AgentMessage(
              role: "bot",
              text: aiReply,
              dataType: dataType,
              suggestedProducts: products,
              orderAction: orderData,
              bundle: bundleData,
              reasoningSteps: reasoningSteps,
              routedAgent: routedAgent,
            ),
          );
        });
      } else {
        String errorDetail =
            "Server returned status ${response.statusCode}. Please try again.";
        try {
          final errJson = jsonDecode(response.body);
          if (errJson is Map && errJson['detail'] is String) {
            errorDetail = errJson['detail'] as String;
          }
        } catch (_) {}

        setState(() {
          _messages.add(
            AgentMessage(
              role: "bot",
              text: errorDetail,
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          AgentMessage(
            role: "bot",
            text:
                "Unable to reach the CTRL-X AI server right now. Please check your connection and try again.",
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Helper widget to render a gorgeous Order Tracker Card inside the chat
  Widget _buildOrderTrackerCard(
    Map<String, dynamic> orderDetails,
    ThemeData theme,
  ) {
    final order = orderDetails['order'] is Map
        ? Map<String, dynamic>.from(orderDetails['order'] as Map)
        : <String, dynamic>{};
    final orderId = (order['order_id'] ?? 'N/A').toString();
    final status =
        (order['overall_status'] ?? order['status'] ?? 'PROCESSING')
            .toString();
    final total = (order['total'] as num?)?.toDouble() ?? 0.0;
    final trackingNumbers = order['tracking_numbers'] is List
        ? List<dynamic>.from(order['tracking_numbers'] as List)
        : const [];
    final address = (order['shipping_address'] ??
            (trackingNumbers.isNotEmpty
                ? trackingNumbers.join(', ')
                : 'Pending Assignment'))
        .toString();
    final delivery =
        (order['estimated_delivery'] ?? 'Standard Delivery').toString();
    final items = order['items'] is List
        ? List<dynamic>.from(order['items'] as List)
        : const [];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, top: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.primaryColor.withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.local_shipping_rounded,
                    color: theme.primaryColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Order #$orderId",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Total Amount:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              Text(
                "\$${total.toStringAsFixed(2)}",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Est. Delivery:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              Flexible(
                child: Text(
                  delivery,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.primaryColor,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Tracking:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  address,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const Divider(height: 18),
            ...items.whereType<Map>().map((item) {
              final pName =
                  (item['product_name'] ?? 'Item').toString();
              final qty = (item['quantity'] ?? 1).toString();
              final fType =
                  (item['fulfillment_type'] ?? 'IN_HOUSE').toString();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '$pName (x$qty)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      fType,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: theme.primaryColor,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  static const List<IconData> _promptIcons = [
    Icons.auto_awesome_rounded,
    Icons.shopping_bag_outlined,
    Icons.checkroom_rounded,
    Icons.directions_run_rounded,
    Icons.policy_outlined,
  ];

  Widget _buildBundleCard(
    Map<String, dynamic> bundle,
    List<Product> bundleProducts,
    ThemeData theme,
  ) {
    final title = (bundle['title'] ?? 'CTRL-X Trust-Verified Bundle').toString();
    final totalPrice = (bundle['total_price'] as num?)?.toDouble() ?? 0.0;
    final budget = (bundle['budget'] as num?)?.toDouble();
    final budgetRemaining =
        (bundle['budget_remaining'] as num?)?.toDouble() ?? 0.0;
    final avgTrust =
        (bundle['average_trust_rating'] as num?)?.toDouble() ?? 4.8;
    final rationale = (bundle['rationale'] ?? '').toString();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20, top: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.primaryColor.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.auto_awesome_mosaic_rounded,
                  color: theme.primaryColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                      ),
                    ),
                    Text(
                      '${bundleProducts.length} items • Avg Trust ${avgTrust.toStringAsFixed(1)}★',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  budget != null
                      ? '\$${budgetRemaining.toStringAsFixed(2)} Under Budget'
                      : 'Trust Verified',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (rationale.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              rationale,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Divider(height: 20),
          ...bundleProducts.map((prod) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: prod.imageUrl.isNotEmpty
                          ? Image.network(
                              prod.imageUrl,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.inventory_2_outlined,
                                size: 20,
                              ),
                            )
                          : const Icon(Icons.inventory_2_outlined, size: 20),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prod.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              prod.category,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.verified_rounded,
                              size: 12,
                              color: Colors.green,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${prod.rating.toStringAsFixed(1)}★ Trust',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '\$${prod.price.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Bundle Total',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  Text(
                    '\$${totalPrice.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: bundleProducts.isEmpty
                    ? null
                    : () {
                        final cart = context.read<CartProvider>();
                        for (final item in bundleProducts) {
                          cart.addToCart(item);
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Added all ${bundleProducts.length} bundle items (\$${totalPrice.toStringAsFixed(2)}) to cart!',
                            ),
                            backgroundColor: theme.primaryColor,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 17),
                label: const Text('Add Full Bundle to Cart'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _botAvatar() {
    return Container(
      width: 30,
      height: 30,
      margin: const EdgeInsets.only(right: 8, bottom: 8),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF42A5F5), Color(0xFF00ACC1)],
        ),
      ),
      child: const Icon(Icons.auto_awesome_rounded,
          color: Colors.white, size: 16),
    );
  }

  Widget _buildBubble(AgentMessage msg, ThemeData theme, bool isDark) {
    final isUser = msg.role == "user";
    final maxWidth = MediaQuery.of(context).size.width * 0.74;

    final bubble = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(220.0, 560.0)),
      decoration: BoxDecoration(
        gradient: isUser
            ? const LinearGradient(
                colors: [Color(0xFF1E88E5), Color(0xFF3949AB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isUser
            ? null
            : (isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.92)),
        border: isUser
            ? null
            : Border.all(color: theme.primaryColor.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 18),
        ),
        boxShadow: [
          BoxShadow(
            color: (isUser ? const Color(0xFF1E88E5) : Colors.black)
                .withValues(alpha: isUser ? 0.22 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: SelectableText(
        msg.text,
        style: TextStyle(
          fontSize: 14.5,
          height: 1.45,
          color: isUser ? Colors.white : theme.textTheme.bodyLarge?.color,
        ),
      ),
    );

    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isUser) _botAvatar(),
        Flexible(child: bubble),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 90, 22, 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const PulsingOrb(size: 92),
            const SizedBox(height: 22),
            FadeSlideIn(
              delay: const Duration(milliseconds: 150),
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
                ).createShader(rect),
                child: const Text(
                  'Hi, I\'m CTRL‑X',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FadeSlideIn(
              delay: const Duration(milliseconds: 260),
              child: Text(
                'Your AI shopping agent. Find products, build your cart,\n'
                'track orders and learn store policies.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 26),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: List.generate(_quickPrompts.length, (i) {
                  final prompt = _quickPrompts[i];
                  return FadeSlideIn(
                    delay: Duration(milliseconds: 360 + i * 90),
                    child: PressableScale(
                      onTap: _isLoading ? null : () => _sendPromptText(prompt),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.primaryColor.withValues(alpha: 0.22),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  theme.primaryColor.withValues(alpha: 0.07),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _promptIcons[i % _promptIcons.length],
                              size: 17,
                              color: theme.primaryColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              prompt,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: theme.primaryColor,
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'CTRL‑X Assistant',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF22C55E),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isLoading ? 'thinking…' : 'online',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? const [Color(0xFF0B1624), Color(0xFF10243B)]
                : const [Color(0xFFFFFFFF), Color(0xFFE8F3FE)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SnowfallBackground(
          flakes: 26,
          color: isDark ? Colors.white : const Color(0xFF9CC9F2),
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(theme)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(14, 96, 14, 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isUser = msg.role == "user";

                          return FadeSlideIn(
                            key: ValueKey('msg-$index'),
                            offset: Offset(isUser ? 0.06 : -0.06, 0.04),
                            duration: const Duration(milliseconds: 380),
                            child: Column(
                              crossAxisAlignment: isUser
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (!isUser && msg.reasoningSteps.isNotEmpty)
                                  _ReasoningTraceAccordion(
                                    steps: msg.reasoningSteps,
                                    routedAgent: msg.routedAgent,
                                  ),
                                _buildBubble(msg, theme, isDark),

                                // Bundle Card Injection (Phase 2)
                                if (!isUser &&
                                    msg.bundle != null &&
                                    msg.suggestedProducts.isNotEmpty)
                                  _buildBundleCard(
                                    msg.bundle!,
                                    msg.suggestedProducts,
                                    theme,
                                  ),

                                // Product Carousel Injection
                                if (!isUser &&
                                    msg.dataType == "product_list" &&
                                    msg.bundle == null &&
                                    msg.suggestedProducts.isNotEmpty)
                                  Container(
                                    height: 300,
                                    margin: const EdgeInsets.only(
                                      bottom: 24,
                                      top: 8,
                                    ),
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: msg.suggestedProducts.length,
                                      itemBuilder: (context, productIndex) {
                                        final prod =
                                            msg.suggestedProducts[productIndex];
                                        return FadeSlideIn.staggered(
                                          index: productIndex,
                                          child: Container(
                                            width: 200,
                                            margin: const EdgeInsets.only(
                                              right: 16,
                                            ),
                                            child: ProductCard(
                                              product: prod,
                                              heroTag:
                                                  'ctrlx-product-${prod.id}-$index-$productIndex',
                                              onProductDeleted: () {},
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),

                                // Order Tracker Card Injection
                                if (!isUser &&
                                    msg.dataType == "order_tracker" &&
                                    msg.orderAction != null)
                                  _buildOrderTrackerCard(
                                    msg.orderAction!,
                                    theme,
                                  ),

                                if (!isUser &&
                                    msg.dataType != "product_list" &&
                                    msg.dataType != "order_tracker")
                                  const SizedBox(height: 10),
                              ],
                            ),
                          );
                        },
                      ),
              ),

              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Row(
                    children: [
                      _botAvatar(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.primaryColor.withValues(alpha: 0.14),
                          ),
                        ),
                        child: TypingDots(color: theme.primaryColor),
                      ),
                    ],
                  ),
                ),

              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: theme.primaryColor.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          style: TextStyle(
                            color: theme.textTheme.bodyLarge?.color,
                          ),
                          enabled: !_isLoading,
                          onSubmitted: (_) {
                            if (!_isLoading) _sendMessage();
                          },
                          decoration: InputDecoration(
                            hintText:
                                'Ask about products, orders, or tracking...',
                            hintStyle: TextStyle(
                              fontSize: 13,
                              color: theme.textTheme.bodySmall?.color,
                            ),
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                        ),
                      ),
                      PressableScale(
                        onTap: _isLoading ? null : _sendMessage,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: _isLoading
                                  ? [Colors.grey.shade400, Colors.grey.shade500]
                                  : const [
                                      Color(0xFF1E88E5),
                                      Color(0xFF00ACC1),
                                    ],
                            ),
                          ),
                          child: const Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
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
    );
  }
}

class _ReasoningTraceAccordion extends StatefulWidget {
  final List<Map<String, dynamic>> steps;
  final String routedAgent;

  const _ReasoningTraceAccordion({
    required this.steps,
    required this.routedAgent,
  });

  @override
  State<_ReasoningTraceAccordion> createState() =>
      _ReasoningTraceAccordionState();
}

class _ReasoningTraceAccordionState extends State<_ReasoningTraceAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = widget.steps.fold<double>(
      0.0,
      (sum, s) => sum + ((s['duration_ms'] as num?)?.toDouble() ?? 0.0),
    );

    return Container(
      margin: const EdgeInsets.only(left: 38, bottom: 6),
      constraints: const BoxConstraints(maxWidth: 540),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: theme.primaryColor,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Agent Reasoning Trace • ${widget.routedAgent} (${widget.steps.length} steps • ${totalMs.toStringAsFixed(1)} ms)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: theme.primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 17,
                    color: theme.primaryColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                children: widget.steps.map((s) {
                  final stepName = (s['step'] ?? 'Step').toString();
                  final summary = (s['summary'] ?? '').toString();
                  final ms = (s['duration_ms'] as num?)?.toDouble() ?? 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Text(
                                      stepName,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${ms.toStringAsFixed(1)} ms',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: theme.primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                              if (summary.isNotEmpty)
                                Text(
                                  summary,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
