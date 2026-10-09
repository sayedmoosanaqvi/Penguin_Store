
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final ProductService _service = ProductService();
  final TextEditingController _searchController = TextEditingController();

  late Future<List<Product>> _productsFuture;
  String _selectedCategory = 'All';
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _productsFuture = _service.fetchProducts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _productsFuture = _service.fetchProducts();
    });
    await _productsFuture;
  }

  IconData _categoryIcon(String category) {
    final value = category.toLowerCase();

    if (value.contains('shirt')) return Icons.checkroom_outlined;
    if (value.contains('pant')) return Icons.style_outlined;
    if (value.contains('shoe')) return Icons.directions_run_outlined;
    if (value.contains('accessor')) return Icons.watch_outlined;
    if (value.contains('computer')) return Icons.computer_outlined;
    if (value.contains('phone')) return Icons.smartphone_outlined;

    return Icons.category_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text(
          'Discover',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            onPressed: () => context.go('/cart'),
            icon: const Icon(Icons.shopping_bag_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() => _searchQuery = value.toLowerCase().trim());
              },
              decoration: InputDecoration(
                hintText: 'Search products and categories',
                hintStyle: const TextStyle(fontSize: 13),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: theme.primaryColor,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDark
                    ? theme.colorScheme.surface
                    : theme.primaryColor.withOpacity(0.05),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.primaryColor.withOpacity(0.2),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.primaryColor.withOpacity(0.2),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Product>>(
              future: _productsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: theme.primaryColor,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off_outlined, size: 42),
                        const SizedBox(height: 10),
                        const Text('Unable to load products'),
                        TextButton(
                          onPressed: _refresh,
                          child: const Text('Try Again'),
                        ),
                      ],
                    ),
                  );
                }

                final allProducts = snapshot.data ?? [];

                final categories = [
                  'All',
                  ...{
                    for (final product in allProducts)
                      if (product.category.trim().isNotEmpty)
                        product.category.trim(),
                  },
                ];

                final selected = categories.contains(_selectedCategory)
                    ? _selectedCategory
                    : 'All';

                final products = allProducts.where((product) {
                  final matchesCategory = selected == 'All' ||
                      product.category == selected;

                  final matchesSearch = _searchQuery.isEmpty ||
                      product.name.toLowerCase().contains(_searchQuery) ||
                      product.category.toLowerCase().contains(_searchQuery) ||
                      product.description.toLowerCase().contains(_searchQuery);

                  return matchesCategory && matchesSearch;
                }).toList();

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final sidebarWidth = width < 550 ? 104.0 : 170.0;
                    final availableWidth = width - sidebarWidth - 32;
                    final columns = availableWidth >= 800
                        ? 4
                        : availableWidth >= 540
                            ? 3
                            : availableWidth >= 270
                                ? 2
                                : 1;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: sidebarWidth,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            border: Border(
                              right: BorderSide(
                                color: theme.dividerColor.withOpacity(0.2),
                              ),
                            ),
                          ),
                          child: ListView.builder(
                            itemCount: categories.length,
                            itemBuilder: (context, index) {
                              final category = categories[index];
                              final active = selected == category;

                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedCategory = category;
                                  });
                                },
                                child: Container(
                                  constraints: const BoxConstraints(
                                    minHeight: 93,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? theme.primaryColor.withOpacity(0.08)
                                        : Colors.transparent,
                                    border: Border(
                                      left: BorderSide(
                                        width: 3,
                                        color: active
                                            ? theme.primaryColor
                                            : Colors.transparent,
                                      ),
                                      bottom: BorderSide(
                                        color: theme.dividerColor
                                            .withOpacity(0.08),
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        category == 'All'
                                            ? Icons.grid_view_rounded
                                            : _categoryIcon(category),
                                        color: active
                                            ? theme.primaryColor
                                            : theme.colorScheme.onSurfaceVariant,
                                        size: 25,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        category,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: active
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: active
                                              ? theme.primaryColor
                                              : theme.colorScheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Expanded(
                          child: RefreshIndicator(
                            onRefresh: _refresh,
                            child: CustomScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                SliverToBoxAdapter(
                                  child: Container(
                                    margin: const EdgeInsets.all(12),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 16,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          theme.primaryColor.withOpacity(0.13),
                                          theme.colorScheme.surface,
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                selected == 'All'
                                                    ? 'All Categories'
                                                    : selected,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: theme.primaryColor,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${products.length} products available',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: theme.colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Icon(
                                          _categoryIcon(selected),
                                          color: theme.primaryColor,
                                          size: 34,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (products.isEmpty)
                                  const SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: Center(
                                      child: Text('No matching products found'),
                                    ),
                                  )
                                else
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12, 0, 12, 24,
                                    ),
                                    sliver: SliverGrid(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: columns,
                                        mainAxisSpacing: 10,
                                        crossAxisSpacing: 10,
                                        childAspectRatio:
                                            width < 550 ? 0.57 : 0.72,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          return ProductCard(
                                            product: products[index],
                                            onProductDeleted: _refresh,
                                          );
                                        },
                                        childCount: products.length,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
