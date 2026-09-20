import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:uuid/uuid.dart';
import '../models/product_model.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';

// 1. Custom model to handle multi-modal responses (Text, Products, Cart, Orders)
class AgentMessage {
  final String role; // "user" or "bot"
  final String text;
  final String dataType; // "text", "product_list", "cart_update", "order_tracker"
  final List<Product> suggestedProducts;
  final Map<String, dynamic>? orderAction;

  AgentMessage({
    required this.role,
    required this.text,
    this.dataType = "text",
    this.suggestedProducts = const [],
    this.orderAction,
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
  final ProductService _productService = ProductService();

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add(AgentMessage(role: "user", text: text));
      _isLoading = true;
    });

    _controller.clear();
    _scrollToBottom();

    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/agent/chat');
      
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "user_input": text,
          "thread_id": _threadId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiReply = data['response'] ?? "No response received.";
        final dataType = data['data_type'] ?? "text";
        
        List<Product> products = [];
        Map<String, dynamic>? orderData;
        
        // 1. Handle Product Search Results
        if (dataType == "product_list" && data['suggested_products'] != null) {
          final List<dynamic> rawProducts = data['suggested_products'];
          products = rawProducts.map((p) => Product(
            id: p['id'],
            name: p['name'],
            price: (p['price'] as num).toDouble(),
            category: p['category'],
            isFeatured: p['is_featured'] ?? false,
            imageUrl: p['image_url'] ?? 'https://via.placeholder.com/400x400.png?text=No+Image', 
            description: p['description'] ?? 'Suggested by CTRL-X',
            rating: (p['rating'] as num?)?.toDouble() ?? 5.0,
            reviews: p['reviews'] ?? 12,
          )).toList();
        }
        // 2. Handle Cart Actions
        else if (dataType == "cart_update" && data['cart_action'] != null) {
          final cartAction = data['cart_action'];
          if (cartAction['action'] == "add_to_cart") {
            final productData = cartAction['product'];
            
            final aiProduct = Product(
              id: productData['id'],
              name: productData['name'],
              price: (productData['price'] as num).toDouble(),
              category: 'AI_ADDED',
              imageUrl: productData['image_url'] ?? 'https://via.placeholder.com/400x400.png?text=No+Image',
              description: 'Added via CTRL-X',
              rating: 5.0,
              reviews: 1,
            );

            if (mounted) {
              Provider.of<CartProvider>(context, listen: false).addToCart(aiProduct);
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.white),
                      const SizedBox(width: 12),
                      Expanded(child: Text("Added ${aiProduct.name} to cart!")),
                    ],
                  ),
                  backgroundColor: Theme.of(context).primaryColor,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          }
        }
        // 3. Handle Order Status Tracking (THE NEW MAGIC)
        else if (dataType == "order_tracker" && data['order_action'] != null) {
          orderData = data['order_action'];
        }

        setState(() {
          _messages.add(AgentMessage(
            role: "bot", 
            text: aiReply,
            dataType: dataType,
            suggestedProducts: products,
            orderAction: orderData,
          ));
        });
      } else {
        setState(() {
          _messages.add(AgentMessage(role: "bot", text: "Error: Server returned ${response.statusCode}"));
        });
      }
    } catch (e) {
      setState(() {
        _messages.add(AgentMessage(role: "bot", text: "Failed to connect to AI server. Make sure FastAPI is running."));
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
      _scrollToBottom();
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
  Widget _buildOrderTrackerCard(Map<String, dynamic> orderDetails, ThemeData theme) {
    final order = orderDetails['order'] ?? {};
    final orderId = order['order_id'] ?? 'N/A';
    final status = order['status'] ?? 'PROCESSING';
    final total = order['total'] ?? 0.0;
    final address = order['shipping_address'] ?? 'N/A';
    final delivery = order['estimated_delivery'] ?? 'Standard Delivery';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, top: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.primaryColor.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 4),
          )
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
                  Icon(Icons.local_shipping_rounded, color: theme.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  Text("Order #$orderId", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Total Amount:", style: TextStyle(color: Colors.grey, fontSize: 13)),
              Text("\$$total", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Est. Delivery:", style: TextStyle(color: Colors.grey, fontSize: 13)),
              Text(delivery, style: TextStyle(fontWeight: FontWeight.w600, color: theme.primaryColor, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Ship to:", style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  address, 
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('CTRL‑X Assistant', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.auto_awesome, size: 60, color: theme.primaryColor.withOpacity(0.5)),
                        const SizedBox(height: 16),
                        Text(
                          'Ask anything to CTRL‑X...',
                          style: TextStyle(color: theme.textTheme.bodyMedium?.color, fontSize: 16),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg.role == "user";
                      
                      return Column(
                        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                              decoration: BoxDecoration(
                                color: isUser ? theme.primaryColor : theme.cardTheme.color,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                                  bottomRight: Radius.circular(isUser ? 4 : 16),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 5,
                                    offset: const Offset(0, 2),
                                  )
                                ],
                              ),
                              child: Text(
                                msg.text,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.4,
                                  color: isUser ? Colors.white : theme.textTheme.bodyLarge?.color,
                                ),
                              ),
                            ),
                          ),
                          
                          // Product Carousel Injection
                          if (!isUser && msg.dataType == "product_list" && msg.suggestedProducts.isNotEmpty)
                            Container(
                              height: 300,
                              margin: const EdgeInsets.only(bottom: 24, top: 8),
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: msg.suggestedProducts.length,
                                itemBuilder: (context, productIndex) {
                                  return Container(
                                    width: 200,
                                    margin: const EdgeInsets.only(right: 16),
                                    child: ProductCard(
                                      product: msg.suggestedProducts[productIndex],
                                      onProductDeleted: () {},
                                    ),
                                  );
                                },
                              ),
                            ),

                          // Order Tracker Card Injection
                          if (!isUser && msg.dataType == "order_tracker" && msg.orderAction != null)
                            _buildOrderTrackerCard(msg.orderAction!, theme),
                          
                          if (!isUser && msg.dataType != "product_list" && msg.dataType != "order_tracker")
                            const SizedBox(height: 16),
                        ],
                      );
                    },
                  ),
          ),
          
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: theme.primaryColor, strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text("CTRL-X is thinking...", style: TextStyle(color: theme.textTheme.bodySmall?.color, fontSize: 12)),
                ],
              ),
            ),
            
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.cardTheme.color,
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -5))
              ]
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                      enabled: !_isLoading,
                      onSubmitted: (_) {
                        if (!_isLoading) _sendMessage();
                      },
                      decoration: InputDecoration(
                        hintText: 'Ask about products, orders, or tracking...',
                        hintStyle: TextStyle(color: theme.textTheme.bodySmall?.color),
                        filled: true,
                        fillColor: theme.scaffoldBackgroundColor,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      onPressed: _isLoading ? null : _sendMessage,
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}