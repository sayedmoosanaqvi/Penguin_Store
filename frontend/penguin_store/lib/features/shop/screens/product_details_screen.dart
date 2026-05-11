import 'package:flutter/material.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:provider/provider.dart'; // Needed for Provider.of
import '../../../core/theme/app_colors.dart';
import '../models/product_model.dart';
import '../services/product_service.dart'; 

import '../providers/cart_provider.dart'; // Added your cart provider!

class ProductDetailScreen extends StatefulWidget {
  final Product product;
  const ProductDetailScreen({super.key, required this.product});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  // --- DELETE LOGIC ---
  Future<void> _confirmDelete(BuildContext context) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Delete Product?"),
          content: Text("Are you sure you want to delete '${widget.product.name}'?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCEL"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // Close dialog
                
                // Using your ProductService
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
              child: const Text("DELETE", style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. Activate AuthProvider to secure the Delete button
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: AppColors.secondaryWhite,
      
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // 2. The Animated Header with Hero Image
          SliverAppBar(
            expandedHeight: 400,
            pinned: true,
            stretch: true,
            backgroundColor: AppColors.primaryBlack,
            iconTheme: const IconThemeData(color: Colors.white),
            
            // Secure Delete Button moved to the SliverAppBar
            actions: [
              if (authProvider.isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () => _confirmDelete(context), 
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
              decoration: const BoxDecoration(
                color: AppColors.secondaryWhite,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(widget.product.category.toUpperCase(), style: TextStyle(color: Colors.grey[600], letterSpacing: 1.2)),
                      Row(
                        children: [
                          const Icon(Icons.star, color: AppColors.accentYellow, size: 20),
                          Text(" ${widget.product.rating} (${widget.product.reviews} reviews)", style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(widget.product.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 15),
                  Text("\$${widget.product.price.toStringAsFixed(2)}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppColors.primaryBlack)),
                  const SizedBox(height: 25),
                  const Text("Description", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Text(widget.product.description, style: TextStyle(color: Colors.grey[700], height: 1.5, fontSize: 16)),
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
        color: Colors.white,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(15)),
              child: const Icon(Icons.favorite_border),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryBlack,
                  foregroundColor: AppColors.accentYellow,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                ),
                // --- THE LIVE CART LOGIC ---
                onPressed: () {
                  // 1. Save to Provider
                  Provider.of<CartProvider>(context, listen: false).addToCart(widget.product);
                  
                  // 2. Show Success Popup
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${widget.product.name} added to cart!'),
                      backgroundColor: AppColors.primaryBlack,
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