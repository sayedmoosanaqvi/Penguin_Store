import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:penguin_store/features/shop/widgets/product_card_skeleton.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final ProductService _productService = ProductService();
  final TextEditingController _searchController = TextEditingController();

  late Future<List<Product>> _productsFuture;
  int _selectedCategoryIndex = 0;
  String _searchQuery = '';
  String _sortBy = 'featured';

  final List<Map<String, dynamic>> _categories = [
    {
      'title': 'All Products',
      'key': 'All',
      'icon': Icons.grid_view_rounded,
      'subtitle': 'Explore our complete AI-curated catalog',
    },
    {
      'title': '3D Interactive',
      'key': '3D',
      'icon': Icons.view_in_ar_rounded,
      'subtitle': 'Products with interactive 360° GLB models',
    },
    {
      'title': 'Shirts',
      'key': 'Shirts',
      'icon': Icons.checkroom_rounded,
      'subtitle': 'Tailored shirts, casual tops & textures',
    },
    {
      'title': 'Pants',
      'key': 'Pants',
      'icon': Icons.straighten_rounded,
      'subtitle': 'Modern trousers, denim & streetwear essentials',
    },
    {
      'title': 'Men Shoes',
      'key': 'Men Shoes',
      'icon': Icons.directions_run_rounded,
      'subtitle': 'Performance sneakers, boots & formal footwear',
    },
    {
      'title': 'Accessories',
      'key': 'Accessories',
      'icon': Icons.watch_rounded,
      'subtitle': 'Watches, tech gear, eyewear & lifestyle bags',
    },
  ];

  @override
  void initState() {
    super.initState();
    Catalog3D.refresh();
    _productsFuture = _productService.fetchProducts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    Catalog3D.refresh(force: true);
    setState(() {
      _productsFuture = _productService.fetchProducts();
    });
  }

  List<Product> _filterAndSort(List<Product> allProducts, Set<int> ids3d) {
    final selectedKey = _categories[_selectedCategoryIndex]['key'] as String;

    final filtered = allProducts.where((p) {
      bool matchesCategory = true;
      if (selectedKey == '3D') {
        matchesCategory =
            ids3d.contains(p.id) ||
            p.category.toLowerCase().contains('3d');
      } else if (selectedKey != 'All') {
        matchesCategory =
            p.category.toLowerCase() == selectedKey.toLowerCase();
      }

      if (!matchesCategory) return false;
      if (_searchQuery.trim().isEmpty) return true;

      final q = _searchQuery.trim().toLowerCase();
      return p.name.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q) ||
          p.category.toLowerCase().contains(q);
    }).toList();

    switch (_sortBy) {
      case 'price_asc':
        filtered.sort((a, b) => a.price.compareTo(b.price));
        break;
      case 'price_desc':
        filtered.sort((a, b) => b.price.compareTo(a.price));
        break;
      case 'rating':
        filtered.sort((a, b) => b.rating.compareTo(a.rating));
        break;
      default:
        filtered.sort((a, b) {
          final a3d = ids3d.contains(a.id) ? 1 : 0;
          final b3d = ids3d.contains(b.id) ? 1 : 0;
          if (a3d != b3d) return b3d.compareTo(a3d);
          final aFeat = a.isFeatured ? 1 : 0;
          final bFeat = b.isFeatured ? 1 : 0;
          if (aFeat != bFeat) return bFeat.compareTo(aFeat);
          return b.id.compareTo(a.id);
        });
    }

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0A0F1D) : const Color(0xFFF3F7FB);
    final sidebarColor = isDark ? const Color(0xFF111827) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final isCompact = MediaQuery.of(context).size.width < 760;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      body: Column(
        children: [
          _buildHeroHeader(isDark, isCompact),
          if (isCompact) _buildMobileCategoryChips(isDark),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isCompact)
                  _buildDesktopSidebar(
                    isDark: isDark,
                    sidebarColor: sidebarColor,
                    textColor: textColor,
                  ),
                Expanded(
                  child: ValueListenableBuilder<Set<int>>(
                    valueListenable: Catalog3D.ids,
                    builder: (context, ids3d, _) {
                      return FutureBuilder<List<Product>>(
                        future: _productsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return GridView.builder(
                              padding: const EdgeInsets.all(20),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 250,
                                childAspectRatio: 0.65,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                              ),
                              itemCount: 8,
                              itemBuilder: (_, _) =>
                                  const ProductCardSkeleton(),
                            );
                          }

                          if (snapshot.hasError) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.cloud_off_rounded,
                                      size: 52,
                                      color: Colors.redAccent,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Could not load catalog.\n${snapshot.error}',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: textColor),
                                    ),
                                    const SizedBox(height: 16),
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF1E88E5),
                                      ),
                                      onPressed: _reload,
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }

                          final allProducts = snapshot.data ?? const [];
                          final filtered =
                              _filterAndSort(allProducts, ids3d);
                          final activeCat =
                              _categories[_selectedCategoryIndex];

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildToolbar(
                                title: activeCat['title'] as String,
                                subtitle: activeCat['subtitle'] as String,
                                count: filtered.length,
                                isDark: isDark,
                                textColor: textColor,
                              ),
                              Expanded(
                                child: filtered.isEmpty
                                    ? _buildEmptyState(isDark, textColor)
                                    : GridView.builder(
                                        padding: const EdgeInsets.fromLTRB(
                                          20,
                                          4,
                                          20,
                                          32,
                                        ),
                                        gridDelegate:
                                            const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 250,
                                          childAspectRatio: 0.65,
                                          crossAxisSpacing: 16,
                                          mainAxisSpacing: 16,
                                        ),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          return FadeSlideIn.staggered(
                                            index: index,
                                            child: ProductCard(
                                              product: filtered[index],
                                              onProductDeleted: _reload,
                                            ),
                                          );
                                        },
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
          ),
        ],
      ),
    );
  }

  Widget _buildHeroHeader(bool isDark, bool isCompact) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0A192F),
            Color(0xFF1565C0),
            Color(0xFF00ACC1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E88E5).withValues(alpha: 0.22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SnowfallBackground(
          flakes: 22,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 16 : 24,
              vertical: isCompact ? 16 : 20,
            ),
            child: Wrap(
              spacing: 16,
              runSpacing: 14,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'PENGUIN CURATED CATALOG',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PressableScale(
                          onTap: () => context.push('/showcase-3d'),
                          child: const Badge3D(compact: true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Discover Collections & 3D Drops',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'Filter by name, style, or category...',
                      hintStyle: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear_rounded,
                                color: Colors.white70,
                                size: 18,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.14),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: Colors.cyanAccent,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileCategoryChips(bool isDark) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final isSelected = _selectedCategoryIndex == index;
          final cat = _categories[index];
          return ChoiceChip(
            avatar: Icon(
              cat['icon'] as IconData,
              size: 16,
              color: isSelected ? Colors.white : const Color(0xFF1E88E5),
            ),
            label: Text(cat['title'] as String),
            selected: isSelected,
            selectedColor: const Color(0xFF1E88E5),
            backgroundColor:
                isDark ? const Color(0xFF131C31) : Colors.white,
            labelStyle: TextStyle(
              color: isSelected
                  ? Colors.white
                  : (isDark ? Colors.white70 : const Color(0xFF334155)),
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
            onSelected: (_) =>
                setState(() => _selectedCategoryIndex = index),
          );
        },
      ),
    );
  }

  Widget _buildDesktopSidebar({
    required bool isDark,
    required Color sidebarColor,
    required Color textColor,
  }) {
    return Container(
      width: 225,
      margin: const EdgeInsets.fromLTRB(16, 4, 0, 16),
      decoration: BoxDecoration(
        color: sidebarColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final isSelected = _selectedCategoryIndex == index;
          final category = _categories[index];

          return FadeSlideIn.staggered(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PressableScale(
                onTap: () =>
                    setState(() => _selectedCategoryIndex = index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.symmetric(
                    vertical: 13,
                    horizontal: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: isSelected
                        ? const LinearGradient(
                            colors: [
                              Color(0xFF1E88E5),
                              Color(0xFF00ACC1),
                            ],
                          )
                        : null,
                    color: isSelected
                        ? null
                        : (isDark
                              ? Colors.white.withValues(alpha: 0.03)
                              : const Color(0xFFF8FAFC)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        category['icon'] as IconData,
                        size: 20,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF1E88E5),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          category['title'] as String,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isSelected
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: isSelected ? Colors.white : textColor,
                          ),
                        ),
                      ),
                      if (category['key'] == '3D')
                        const Badge3D(compact: true),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildToolbar({
    required String title,
    required String subtitle,
    required int count,
    required bool isDark,
    required Color textColor,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color:
                          const Color(0xFF1E88E5).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$count items',
                      style: const TextStyle(
                        color: Color(0xFF1E88E5),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white60 : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF131C31) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sortBy,
                isDense: true,
                icon: const Icon(
                  Icons.sort_rounded,
                  size: 18,
                  color: Color(0xFF1E88E5),
                ),
                style: TextStyle(
                  color: textColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'featured',
                    child: Text('Sort: Featured & 3D First'),
                  ),
                  DropdownMenuItem(
                    value: 'price_asc',
                    child: Text('Price: Low to High'),
                  ),
                  DropdownMenuItem(
                    value: 'price_desc',
                    child: Text('Price: High to Low'),
                  ),
                  DropdownMenuItem(
                    value: 'rating',
                    child: Text('Top Customer Rating'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _sortBy = v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, Color textColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PulsingOrb(
              icon: Icons.inventory_2_outlined,
              size: 68,
            ),
            const SizedBox(height: 16),
            Text(
              'No matching products in this view',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Try clearing your search filter or switching to All Products.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white60 : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                  _selectedCategoryIndex = 0;
                });
              },
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset Filters'),
            ),
          ],
        ),
      ),
    );
  }
}
