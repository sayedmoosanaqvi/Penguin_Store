import 'package:flutter/material.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:provider/provider.dart';
import '../models/product_model.dart';
import '../services/product_service.dart'; 
import '../providers/cart_provider.dart';
// ---> NEW IMPORTS FOR PREMIUM UPGRADES <---
import 'package:penguin_store/features/shop/widgets/premium_interactive_card.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class ProductDetailScreen extends StatefulWidget {
  final Product? product;
  final int? productId;

  const ProductDetailScreen({
    super.key, 
    this.product,
    this.productId,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  late Future<Product?> _productFuture;
  final ProductService _productService = ProductService();

  @override
  void initState() {
    super.initState();
    if (widget.product != null) {
      _productFuture = Future.value(widget.product);
    } else if (widget.productId != null) {
      _productFuture = _fetchProductById(widget.productId!);
    } else {
      _productFuture = Future.value(null);
    }
  }

  Future<Product?> _fetchProductById(int id) async {
    try {
      List<Product> products = await _productService.fetchProducts();
      return products.firstWhere((p) => p.id == id);
    } catch (e) {
      debugPrint('Error fetching product by ID: $e');
      return null;
    }
  }

  Future<void> _confirmDelete(BuildContext context, ThemeData theme, Product product) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: theme.cardTheme.color,
          title: Text("Delete Product?", style: TextStyle(color: theme.textTheme.titleLarge?.color)),
          content: Text("Are you sure you want to delete '${product.name}'?", style: TextStyle(color: theme.textTheme.bodyLarge?.color)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); 
                bool success = await _productService.deleteProduct(product.id);
                if (success) {
                  // ---> TRIGGER PREMIUM SUCCESS TOAST <---
                  if (context.mounted) {
                    CustomToast.show(context, "Product Deleted");
                    Navigator.pop(context);
                  }
                } else {
                  // ---> TRIGGER PREMIUM ERROR TOAST <---
                  if (context.mounted) {
                    CustomToast.show(context, "Delete Failed", isError: true);
                  }
                }
              },
              child: const Text("DELETE", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final theme = Theme.of(context);

    return FutureBuilder<Product?>(
      future: _productFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            appBar: AppBar(),
            body: Center(child: CircularProgressIndicator(color: theme.primaryColor)),
          );
        }

        if (!snapshot.hasData || snapshot.data == null) {
          return Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            appBar: AppBar(),
            body: const Center(child: Text('Product not found.')),
          );
        }

        final product = snapshot.data!;

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                expandedHeight: 400,
                pinned: true,
                stretch: true,
                backgroundColor: theme.scaffoldBackgroundColor,
                iconTheme: IconThemeData(color: theme.appBarTheme.foregroundColor),
                actions: [
                  if (authProvider.isAdmin)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () => _confirmDelete(context, theme, product), 
                    ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  stretchModes: const [StretchMode.zoomBackground],
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: 'product-${product.id}',
                        child: Image.network(product.imageUrl, fit: BoxFit.cover),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.center,
                            colors: [Colors.black54, Colors.transparent],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color,
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
                  ),
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 400),
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    curve: Curves.easeOut,
                    builder: (context, value, child) {
                      return Transform.translate(
                        offset: Offset(0, 30 * (1 - value)),
                        child: Opacity(
                          opacity: value,
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(product.category.toUpperCase(), style: TextStyle(color: theme.textTheme.bodySmall?.color, letterSpacing: 1.2)),
                            Row(
                              children: [
                                Icon(Icons.star, color: theme.primaryColor, size: 20),
                                Text(" ${product.rating} (${product.reviews} reviews)", style: TextStyle(fontWeight: FontWeight.bold, color: theme.textTheme.titleMedium?.color)),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(product.name, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.textTheme.titleLarge?.color)),
                        const SizedBox(height: 15),
                        Text("\$${product.price.toStringAsFixed(2)}", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: theme.primaryColor)),
                        const SizedBox(height: 25),
                        Text("Description", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.textTheme.titleLarge?.color)),
                        const SizedBox(height: 10),
                        Text(product.description, style: TextStyle(color: theme.textTheme.bodySmall?.color, height: 1.5, fontSize: 16)),
                        const SizedBox(height: 120),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomSheet: Container(
            padding: const EdgeInsets.all(20),
            height: 100,
            decoration: BoxDecoration(
              color: theme.cardTheme.color,
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -5))
              ],
            ),
            child: Row(
              children: [
                // ---> PREMIUM PHYSICS ON FAVORITE BUTTON <---
                PremiumInteractiveCard(
                  onTap: () {
                    CustomToast.show(context, 'Added to favorites!');
                  },
                  child: Container(
                    height: 56,
                    width: 56,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.withOpacity(0.2)), 
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(Icons.favorite_border, color: theme.textTheme.bodyLarge?.color),
                  ),
                ),
                const SizedBox(width: 20),
                // ---> PREMIUM PHYSICS ON ADD TO CART BUTTON <---
                Expanded(
                  child: PremiumInteractiveCard(
                    onTap: () {
                      Provider.of<CartProvider>(context, listen: false).addToCart(product);
                      CustomToast.show(context, '${product.name} added to cart!');
                    },
                    child: Container(
                      height: 56,
                      alignment: Alignment.center,
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
                        "ADD TO CART", 
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.0),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}