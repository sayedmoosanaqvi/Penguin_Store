import 'package:flutter/material.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:provider/provider.dart';
import '../models/product_model.dart';
import '../services/product_service.dart'; 
import '../providers/cart_provider.dart';

class ProductDetailScreen extends StatefulWidget {
  final Product product;
  const ProductDetailScreen({super.key, required this.product});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  // --- DELETE LOGIC ---
  Future<void> _confirmDelete(BuildContext context, ThemeData theme) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
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
                Navigator.pop(context); // Close dialog
                
                bool success = await ProductService().deleteProduct(widget.product.id);
                
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Product Deleted"), backgroundColor: Colors.green),
                  );
                  Navigator.pop(context); // Go back to Home Screen
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Delete Failed"), backgroundColor: Colors.red),
                  );
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

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // 2. The Animated Header with Hero Image
          SliverAppBar(
            expandedHeight: 400,
            pinned: true,
            stretch: true,
            backgroundColor: theme.scaffoldBackgroundColor,
            iconTheme: IconThemeData(color: theme.appBarTheme.foregroundColor),
            
            // Secure Delete Button moved to the SliverAppBar
            actions: [
              if (authProvider.isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () => _confirmDelete(context, theme), 
                ),
            ],
            
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: 'product-${widget.product.id}',
                    child: Image.network(widget.product.imageUrl, fit: BoxFit.cover),
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

          // 3. The Product Details Section
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(widget.product.category.toUpperCase(), style: TextStyle(color: theme.textTheme.bodySmall?.color, letterSpacing: 1.2)),
                      Row(
                        children: [
                          Icon(Icons.star, color: theme.primaryColor, size: 20),
                          Text(" ${widget.product.rating} (${widget.product.reviews} reviews)", style: TextStyle(fontWeight: FontWeight.bold, color: theme.textTheme.titleMedium?.color)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(widget.product.name, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.textTheme.titleLarge?.color)),
                  const SizedBox(height: 15),
                  Text("\$${widget.product.price.toStringAsFixed(2)}", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: theme.primaryColor)),
                  const SizedBox(height: 25),
                  Text("Description", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.textTheme.titleLarge?.color)),
                  const SizedBox(height: 10),
                  Text(widget.product.description, style: TextStyle(color: theme.textTheme.bodySmall?.color, height: 1.5, fontSize: 16)),
                  const SizedBox(height: 120), // Extra space so bottom sheet doesn't cover text
                ],
              ),
            ),
          ),
        ],
      ),
      
      // 4. Floating Bottom Action Bar
      bottomSheet: Container(
        padding: const EdgeInsets.all(20),
        height: 100,
        color: theme.cardTheme.color,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.2)), 
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(Icons.favorite_border, color: theme.textTheme.bodyLarge?.color),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: ElevatedButton(
                // --- THE LIVE CART LOGIC ---
                onPressed: () {
                  Provider.of<CartProvider>(context, listen: false).addToCart(widget.product);
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${widget.product.name} added to cart!'),
                      backgroundColor: theme.scaffoldBackgroundColor,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: const Text("ADD TO CART", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}