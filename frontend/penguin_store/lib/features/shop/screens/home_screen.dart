
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/visual_search_service.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:penguin_store/features/shop/widgets/product_card_skeleton.dart';
import 'package:penguin_store/features/shop/widgets/trending_carousel.dart';
import 'package:penguin_store/features/shop/widgets/personalized_carousel.dart';
import 'package:penguin_store/features/shop/widgets/premium_interactive_card.dart';
import 'package:penguin_store/features/shop/screens/visual_search_results_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProductService _productService = ProductService();
  final VisualSearchService _visualSearchService = VisualSearchService();
  final TextEditingController _searchController = TextEditingController();

  late Future<List<Product>> _productsFuture;

  String _selectedCategory = 'All';
  String _searchQuery = '';
  bool _visualSearchLoading = false;

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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshProducts() async {
    final future = _productService.fetchProducts();

    setState(() {
      _productsFuture = future;
    });

    try {
      await future;
    } catch (e) {
      debugPrint('Product refresh failed: $e');
    }
  }

  Future<void> _startVisualSearch(ImageSource source) async {
    if (_visualSearchLoading) return;

    setState(() => _visualSearchLoading = true);

    bool dialogVisible = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            content: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                  ),
                ),
                SizedBox(width: 16),
                Flexible(
                  child: Text(
                    'AI is analyzing your image...',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) => dialogVisible = false);

    try {
      final matches = await _visualSearchService
          .searchWithCameraOrGallery(source);

      if (!mounted) return;

      if (dialogVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogVisible = false;
      }

      if (matches.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VisualSearchResultsScreen(
              matches: matches,
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No visual matches found. Please try another image.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      if (dialogVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogVisible = false;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Visual search failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _visualSearchLoading = false);
      }
    }
  }

  void _showVisualSearchOptions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'AI Visual Search',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'Search for similar products using an image.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('Take Photo'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _startVisualSearch(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from Gallery'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _startVisualSearch(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: const TopNavBar(),
      drawer: const RightDrawer(),
      body: RefreshIndicator(
        color: theme.primaryColor,
        onRefresh: _refreshProducts,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSearchBar(theme),
                  _buildQuickCategories(theme),
                  _buildWelcomeBanner(theme),
                  _buildAiBanner(theme),
                  const SizedBox(height: 14),
                  const TrendingCarousel(country: 'Pakistan'),

                  // Recommendations follow the authenticated account.
                  Consumer<AuthProvider>(
                    builder: (context, auth, child) {
                      final currentEmail = auth.userEmail?.trim();

                      if (!auth.isAuthenticated ||
                          currentEmail == null ||
                          currentEmail.isEmpty) {
                        return const SizedBox.shrink();
                      }

                      return PersonalizedCarousel(
                        key: ValueKey(
                          'recommendations-$currentEmail',
                        ),
                        userEmail: currentEmail,
                      );
                    },
                  ),

                  const SizedBox(height: 12),
                  _buildSectionHeader(theme),
                  _buildCategoryFilter(theme),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _buildProductsGrid(),
            const SliverToBoxAdapter(
              child: SizedBox(height: 28),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'home-ctrlx-fab',
        backgroundColor: theme.primaryColor,
        foregroundColor: Colors.white,
        tooltip: 'CTRL-X AI Assistant',
        onPressed: () => context.push('/ctrlx'),
        child: const Icon(Icons.auto_awesome_rounded),
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: theme.primaryColor.withOpacity(0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(
                isDark ? 0.08 : 0.025,
              ),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            setState(() {
              _searchQuery = value.trim().toLowerCase();
            });
          },
          decoration: InputDecoration(
            hintText: 'Search products in Penguin Store',
            hintStyle: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: theme.primaryColor,
              size: 21,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear Search',
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                    ),
                    onPressed: () {
                      _searchController.clear();

                      setState(() {
                        _searchQuery = '';
                      });
                    },
                  ),
                Container(
                  height: 25,
                  width: 1,
                  color: theme.dividerColor.withOpacity(0.3),
                ),
                IconButton(
                  tooltip: 'AI Visual Search',
                  icon: Icon(
                    Icons.camera_alt_outlined,
                    color: theme.primaryColor,
                    size: 21,
                  ),
                  onPressed: _visualSearchLoading
                      ? null
                      : _showVisualSearchOptions,
                ),
              ],
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 11,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
          ),
        ),
      ),
    );
  }

  Widget _buildQuickCategories(ThemeData theme) {
    final quickCategories = [
      (Icons.grid_view_rounded, 'All'),
      (Icons.checkroom_outlined, 'Shirts'),
      (Icons.style_outlined, 'Pants'),
      (Icons.directions_run_outlined, 'Men Shoes'),
      (Icons.watch_outlined, 'Accessories'),
    ];

    return SizedBox(
      height: 85,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        itemCount: quickCategories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final item = quickCategories[index];
          final selected = _selectedCategory == item.$2;

          return InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () {
              setState(() {
                _selectedCategory = item.$2;
              });
            },
            child: SizedBox(
              width: 76,
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: selected
                          ? theme.primaryColor
                          : theme.primaryColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      item.$1,
                      color: selected
                          ? Colors.white
                          : theme.primaryColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.$2,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: selected
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
    );
  }

  Widget _buildWelcomeBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.primaryColor.withOpacity(0.12),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 39,
            height: 39,
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.storefront_rounded,
              color: theme.primaryColor,
              size: 21,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome to Penguin Store',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Discover products powered by smart AI shopping.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          IconButton(
            tooltip: 'Discover Products',
            onPressed: () => context.go('/discover'),
            icon: Icon(
              Icons.arrow_forward_ios_rounded,
              size: 16,
              color: theme.primaryColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiBanner(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: PremiumInteractiveCard(
        onTap: () => context.push('/ctrlx'),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 15,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.primaryColor,
                theme.colorScheme.tertiary,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.17),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.smart_toy_outlined,
                  color: Colors.white,
                  size: 25,
                ),
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CTRL-X AI Shopping Agent',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Ask about products, orders, inventory and more.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white,
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Featured Products',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  'Explore products from our latest collection',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _refreshProducts,
            icon: const Icon(
              Icons.refresh_rounded,
              size: 16,
            ),
            label: const Text(
              'Refresh',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryFilter(ThemeData theme) {
    return SizedBox(
      height: 37,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final selected = _selectedCategory == category;

          return ChoiceChip(
            label: Text(
              category,
              style: TextStyle(
                fontSize: 10,
                color: selected
                    ? Colors.white
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            selected: selected,
            showCheckmark: false,
            selectedColor: theme.primaryColor,
            backgroundColor: theme.colorScheme.surface,
            side: BorderSide(
              color: selected
                  ? theme.primaryColor
                  : theme.dividerColor.withOpacity(0.3),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              setState(() {
                _selectedCategory = category;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildProductsGrid() {
    return FutureBuilder<List<Product>>(
      future: _productsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildResponsiveGrid(
            isLoading: true,
            products: const [],
          );
        }

        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  const Icon(
                    Icons.wifi_off_rounded,
                    size: 36,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 9),
                  const Text('Unable to load products'),
                  const SizedBox(height: 6),
                  Text(
                    '${snapshot.error}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                    ),
                  ),
                  TextButton(
                    onPressed: _refreshProducts,
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            ),
          );
        }

        final allProducts = snapshot.data ?? [];

        if (allProducts.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(30),
              child: Center(
                child: Text('No products found in PostgreSQL.'),
              ),
            ),
          );
        }

        final filteredProducts = allProducts.where((product) {
          final databaseCategory =
              product.category.trim().toLowerCase();

          final buttonCategory =
              _selectedCategory.trim().toLowerCase();

          final matchesCategory = _selectedCategory == 'All' ||
              databaseCategory.contains(buttonCategory) ||
              buttonCategory.contains(databaseCategory);

          final matchesSearch = _searchQuery.isEmpty ||
              product.name.toLowerCase().contains(_searchQuery) ||
              product.category.toLowerCase().contains(_searchQuery) ||
              product.description.toLowerCase().contains(_searchQuery);

          return matchesCategory && matchesSearch;
        }).toList();

        if (filteredProducts.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(35),
              child: Column(
                children: [
                  const Icon(
                    Icons.search_off_rounded,
                    size: 36,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _searchQuery.isNotEmpty
                        ? 'No products match your search.'
                        : 'No $_selectedCategory products available.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      _searchController.clear();

                      setState(() {
                        _selectedCategory = 'All';
                        _searchQuery = '';
                      });
                    },
                    child: const Text('Clear Filters'),
                  ),
                ],
              ),
            ),
          );
        }

        return _buildResponsiveGrid(
          products: filteredProducts,
          isLoading: false,
        );
      },
    );
  }

  Widget _buildResponsiveGrid({
    required List<Product> products,
    required bool isLoading,
  }) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;

        int crossAxisCount;

        if (width >= 1150) {
          crossAxisCount = 6;
        } else if (width >= 900) {
          crossAxisCount = 5;
        } else if (width >= 650) {
          crossAxisCount = 4;
        } else if (width >= 430) {
          crossAxisCount = 3;
        } else {
          crossAxisCount = 2;
        }

        final horizontalPadding = width >= 650 ? 18.0 : 10.0;
        final spacing = width >= 650 ? 12.0 : 8.0;

        final itemWidth =
            (width - horizontalPadding * 2 -
                (crossAxisCount - 1) * spacing) /
            crossAxisCount;

        final itemHeight = itemWidth < 145
            ? itemWidth * 2.2
            : itemWidth < 190
                ? itemWidth * 1.95
                : itemWidth * 1.75;

        return SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 8,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (isLoading) {
                  return const ProductCardSkeleton();
                }

                return ProductCard(
                  product: products[index],
                  onProductDeleted: _refreshProducts,
                );
              },
              childCount: isLoading
                  ? crossAxisCount * 2
                  : products.length,
            ),
          ),
        );
      },
    );
  }
}
