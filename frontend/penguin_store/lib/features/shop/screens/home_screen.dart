import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';
import '../../../core/responsive/responsive_layout.dart';
import '../models/product_model.dart';
import '../widgets/product_card.dart';
import '../services/product_service.dart';
import '../widgets/product_card_skeleton.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProductService _productService = ProductService();
  late Future<List<Product>> _productsFuture;

  String _selectedCategory = 'All';
  final List<String> _categories = [
    'All',
    'Shirts',
    'Pants',
    'Men Shoes',
    'Accessories',
  ];

  @override
  void initState() {
    super.initState();
    _productsFuture = _productService.fetchProducts();
  }

  Future<void> _refreshProducts() async {
    setState(() {
      _productsFuture = _productService.fetchProducts();
    });
    await _productsFuture;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      body: RefreshIndicator(
        color: theme.scaffoldBackgroundColor,
        backgroundColor: theme.primaryColor,
        onRefresh: _refreshProducts,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- SECTION 1: Welcome & Overview Card ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color ?? theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: isLight ? Colors.grey.withOpacity(0.08) : Colors.black.withOpacity(0.25),
                        blurRadius: 15,
                        offset: const Offset(0, 6),
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
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: theme.primaryColor.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(Icons.store, size: 18, color: theme.primaryColor),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'PENGUIN STORE HQ',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: theme.primaryColor),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.circle, size: 8, color: Colors.green),
                                SizedBox(width: 6),
                                Text('Live API Online', style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Welcome back, Moosa',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.textTheme.titleLarge?.color),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Your storefront architecture is optimized and running smoothly.',
                        style: TextStyle(fontSize: 13, color: theme.textTheme.bodySmall?.color),
                      ),
                      const SizedBox(height: 20),
                      
                      // Metric Mini-Cards Row
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricTile(theme, 'Catalog Status', 'Synced', Icons.cloud_done, Colors.blue),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricTile(theme, 'AI Assistant', 'Ready', Icons.auto_awesome, Colors.purple),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // --- SECTION 2: Promo / Quick Action Banner ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 4.0),
                child: InkWell(
                  onTap: () => context.go('/ctrlx'),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [theme.primaryColor, theme.primaryColor.withOpacity(0.85)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: theme.primaryColor.withOpacity(0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.bolt, color: Colors.white, size: 26),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'CTRL-X Agentic Assistant',
                                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Ask questions about products, inventory, or orders instantly.',
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 14),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // --- SECTION 3: Main Products Dashboard Container ---
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: theme.cardTheme.color ?? theme.colorScheme.surface,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(32),
                    topRight: Radius.circular(32),
                  ),
                  border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.1))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 24.0, right: 24.0, top: 28.0, bottom: 12.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Featured Products',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: theme.textTheme.titleLarge?.color,
                            ),
                          ),
                          TextButton(
                            onPressed: _refreshProducts,
                            child: Text('Refresh', style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                    _buildCategoryFilter(theme),
                    const SizedBox(height: 20),
                    _buildLiveGrid(),
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: theme.primaryColor,
        foregroundColor: theme.colorScheme.onPrimary,
        onPressed: () {
          context.go('/ctrlx');
        },
        child: const Icon(Icons.auto_awesome),
      ),
    );
  }

  Widget _buildMetricTile(ThemeData theme, String title, String value, IconData icon, Color accentColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accentColor),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 10, color: theme.textTheme.bodySmall?.color)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: theme.textTheme.titleMedium?.color)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryFilter(ThemeData theme) {
    return SizedBox(
      height: 45,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = _selectedCategory == category;

          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ChoiceChip(
              label: Text(
                category,
                style: TextStyle(
                  color: isSelected ? Colors.white : theme.textTheme.bodySmall?.color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              selected: isSelected,
              selectedColor: theme.primaryColor,
              backgroundColor: theme.scaffoldBackgroundColor,
              side: BorderSide(
                color: isSelected ? theme.primaryColor : Colors.grey.withOpacity(0.2),
              ),
              showCheckmark: false,
              onSelected: (bool selected) {
                setState(() {
                  _selectedCategory = category;
                });
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveGrid() {
    return FutureBuilder<List<Product>>(
      future: _productsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ResponsiveLayout(
            mobile: _buildShimmerGrid(crossAxisCount: 2, isMobile: true),
            desktop: _buildShimmerGrid(crossAxisCount: 4, isMobile: false),
          );
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No products found in PostgreSQL.'));
        }

        final allProducts = snapshot.data!;

        final filteredProducts = _selectedCategory == 'All'
            ? allProducts
            : allProducts.where((p) {
                String databaseCategory = p.category.trim().toLowerCase();
                String buttonCategory = _selectedCategory.trim().toLowerCase();
                return databaseCategory.contains(buttonCategory) ||
                    buttonCategory.contains(databaseCategory);
              }).toList();

        if (filteredProducts.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(40.0),
              child: Text(
                'No $_selectedCategory available right now.',
                style: TextStyle(fontSize: 16, color: Colors.grey[400]),
              ),
            ),
          );
        }

        return ResponsiveLayout(
          mobile: _gridBuilder(
            filteredProducts,
            crossAxisCount: 2,
            isMobile: true,
          ),
          desktop: _gridBuilder(
            filteredProducts,
            crossAxisCount: 4,
            isMobile: false,
          ),
        );
      },
    );
  }

  Widget _buildShimmerGrid({
    required int crossAxisCount,
    required bool isMobile,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16.0 : 24.0),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 0.68,
        ),
        itemCount: 6,
        itemBuilder: (context, index) {
          return const ProductCardSkeleton();
        },
      ),
    );
  }

  Widget _gridBuilder(
    List<Product> products, {
    required int crossAxisCount,
    required bool isMobile,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16.0 : 24.0),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 0.68,
        ),
        itemCount: products.length,
        itemBuilder: (context, index) {
          return ProductCard(
            product: products[index],
            onProductDeleted: _refreshProducts,
          );
        },
      ),
    );
  }
}