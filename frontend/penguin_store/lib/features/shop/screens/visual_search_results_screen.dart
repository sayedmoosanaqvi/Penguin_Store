import 'package:flutter/material.dart';
import '../models/product_model.dart';
import '../widgets/product_card.dart';

class VisualSearchResultsScreen extends StatelessWidget {
  final List<dynamic> matches;

  const VisualSearchResultsScreen({
    super.key,
    required this.matches,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // Evaluate screen width directly to avoid Sliver/Box layout conflicts
    final bool isDesktop = MediaQuery.of(context).size.width > 600;
    final int crossAxisCount = isDesktop ? 4 : 2;

    // Convert raw JSON payload into Product model instances
    final List<Map<String, dynamic>> items = matches.map((m) {
      final productData = m['product'] as Map<String, dynamic>;
      final double score = (m['score'] as num?)?.toDouble() ?? 0.0;
      
      return {
        'score': (score * 100).toStringAsFixed(1),
        'product': Product(
          id: productData['id'] ?? 0,
          name: productData['name'] ?? '',
          description: productData['description'] ?? '', 
          price: (productData['price'] as num?)?.toDouble() ?? 0.0,
          imageUrl: productData['image_url'] ?? '',
          category: productData['category'] ?? '',
          rating: (productData['rating'] as num?)?.toDouble() ?? 0.0, 
          reviews: productData['reviews'] ?? 0, 
        ),
      };
    }).toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('AI Visual Matches', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: theme.textTheme.titleLarge?.color,
        centerTitle: true,
      ),
      body: items.isEmpty
          ? _buildEmptyState(theme)
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [theme.primaryColor, theme.primaryColor.withOpacity(0.7)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.document_scanner, color: Colors.white, size: 28),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Analysis Complete',
                                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Found ${items.length} visually similar items in the catalog.',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                  // Pass the calculated columns directly into the SliverGrid
                  sliver: _buildGridSliver(items, crossAxisCount),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 60)),
              ],
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 80, color: Colors.grey.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            'No visual matches found',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.textTheme.titleMedium?.color),
          ),
          const SizedBox(height: 8),
          const Text('Try uploading a clearer image.', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildGridSliver(List<Map<String, dynamic>> items, int crossAxisCount) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.64,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = items[index];
          final Product product = item['product'] as Product;
          final String score = item['score'] as String;

          return TweenAnimationBuilder<double>(
            duration: Duration(milliseconds: 400 + (index * 100)),
            tween: Tween<double>(begin: 0.0, end: 1.0),
            curve: Curves.easeOutQuart,
            builder: (context, value, child) {
              return Transform.translate(
                offset: Offset(0, 50 * (1 - value)),
                child: Opacity(
                  opacity: value,
                  child: child,
                ),
              );
            },
            child: Stack(
              children: [
                ProductCard(
                  product: product,
                  onProductDeleted: () {}, 
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.2), width: 0.5),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4, offset: const Offset(0, 2))
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.blur_on, color: Colors.cyanAccent, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          '$score% Match',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        childCount: items.length,
      ),
    );
  }
}