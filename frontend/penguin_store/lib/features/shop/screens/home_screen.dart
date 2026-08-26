import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';
import '../../../core/responsive/responsive_layout.dart';
import '../../../core/theme/app_colors.dart';
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      body: RefreshIndicator(
        color: AppColors.background,
        backgroundColor: AppColors.primary,
        onRefresh: _refreshProducts,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(32),
                    topRight: Radius.circular(32),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(
                        left: 40.0,
                        top: 40.0,
                        bottom: 10.0,
                      ),
                      child: Text(
                        'Featured Products',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: AppColors.whiteText,
                        ),
                      ),
                    ),
                    _buildCategoryFilter(),
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
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.background,
        onPressed: () {
          context.go('/ctrlx');
        },
        child: const Icon(Icons.auto_awesome),
      ),
    );
  }

  Widget _buildCategoryFilter() {
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 40),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = _selectedCategory == category;

          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ChoiceChip(
              label: Text(
                category,
                style: TextStyle(
                  color: isSelected ? AppColors.background : Colors.grey[400],
                  fontWeight: FontWeight.bold,
                ),
              ),
              selected: isSelected,
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.card,
              side: BorderSide(
                color: isSelected ? AppColors.primary : AppColors.border,
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
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16.0 : 40.0),
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
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16.0 : 40.0),
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