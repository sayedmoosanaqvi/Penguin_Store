import 'package:flutter/material.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import '../models/product_model.dart';
import 'package:provider/provider.dart';
import '../providers/cart_provider.dart';
// 1. IMPORT YOUR AUTH PROVIDER
import '../services/product_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class ProductCard extends StatefulWidget {
  final Product product;
  final VoidCallback onProductDeleted;

  const ProductCard({
    super.key, 
    required this.product,
    required this.onProductDeleted,
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    // 2. ACCESS THE AUTH PROVIDER
    final authProvider = Provider.of<AuthProvider>(context);
    // Grab the dynamic theme
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => isHovering = true),
      onExit: (_) => setState(() => isHovering = false),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ProductDetailScreen(product: widget.product),
            ),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: theme.cardTheme.color ?? theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isHovering ? theme.primaryColor : Colors.transparent,
              width: 2,
            ),
            // The signature Medical-Modern soft shadow
            boxShadow: [
              BoxShadow(
                color: theme.brightness == Brightness.light 
                    ? Colors.grey.withOpacity(0.1) 
                    : Colors.black.withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Hero(
                      tag: 'product-${widget.product.id}',
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                        child: Image.network(
                          widget.product.imageUrl,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),

                    if (kIsWeb)
                      AnimatedOpacity(
                        opacity: isHovering ? 0.1 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                            color: theme.scaffoldBackgroundColor,
                          ),
                        ),
                      ),

                    // Tags
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.product.discountPercent != null)
                            _buildTag('-${widget.product.discountPercent}%', theme.scaffoldBackgroundColor, theme.primaryColor),
                          if (widget.product.isFeatured)
                            _buildTag('FEATURED', theme.primaryColor, theme.scaffoldBackgroundColor),
                        ],
                      ),
                    ),
                    
                    // --- ADMIN ONLY DELETE BUTTON ---
                    if (authProvider.isAdmin) // 3. WRAP IN ADMIN CHECK
                      Positioned(
                        top: 8,
                        right: 8,
                        child: AnimatedOpacity(
                          opacity: (kIsWeb && isHovering) || !kIsWeb ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            decoration: BoxDecoration(
                              color: theme.scaffoldBackgroundColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4)
                              ]
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              onPressed: () {
                                _showDeleteDialog(context, theme);
                              },
                            ),
                          ),
                        ),
                      ),

                    // --- ADD TO CART BUTTON (Web Only) ---
                    if (kIsWeb)
                      AnimatedOpacity(
                        opacity: isHovering ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.primaryColor,
                                foregroundColor: theme.scaffoldBackgroundColor,
                                minimumSize: const Size(double.infinity, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () {
                                Provider.of<CartProvider>(context, listen: false).addToCart(widget.product);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: theme.scaffoldBackgroundColor,
                                    behavior: SnackBarBehavior.floating,
                                    duration: const Duration(seconds: 1),
                                    content: Text(
                                      '${widget.product.name} added to cart!', 
                                      style: TextStyle(color: theme.textTheme.bodyLarge?.color)
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                              label: const Text("ADD TO CART", style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Details section
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.product.category.toUpperCase(),
                      style: TextStyle(color: theme.textTheme.bodySmall?.color ?? Colors.grey[500], fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.product.name,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: theme.textTheme.titleMedium?.color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.star, color: theme.primaryColor, size: 16),
                        const SizedBox(width: 4),
                        Text("${widget.product.rating}", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: theme.textTheme.bodyMedium?.color)),
                        Text(" (${widget.product.reviews})", style: TextStyle(color: theme.textTheme.bodySmall?.color ?? Colors.grey[500], fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '\$${widget.product.price.toStringAsFixed(2)}',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: theme.primaryColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Extracted Dialog for Cleanliness
  void _showDeleteDialog(BuildContext context, ThemeData theme) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: theme.cardTheme.color,
        title: Text("Delete Product?", style: TextStyle(color: theme.textTheme.titleLarge?.color)),
        content: Text("Are you sure you want to delete '${widget.product.name}'?", style: TextStyle(color: theme.textTheme.bodyLarge?.color)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); 
              bool success = await ProductService().deleteProduct(widget.product.id);
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Product deleted!'), backgroundColor: Colors.green),
                );
                widget.onProductDeleted(); 
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Failed to delete.'), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text("DELETE", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }
}