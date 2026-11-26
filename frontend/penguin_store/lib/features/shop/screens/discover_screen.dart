import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/multimodal_search_sheet.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:penguin_store/features/shop/widgets/product_card_skeleton.dart';
import 'package:penguin_store/features/shop/widgets/product_filters.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';
import 'package:penguin_store/features/shop/widgets/voice_concierge_overlay.dart';

class DiscoverScreen extends StatefulWidget {
  final String? initialQuery;
  final String? initialCategory;

  const DiscoverScreen({
    super.key,
    this.initialQuery,
    this.initialCategory,
  });

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;

  int _selectedCategoryIndex = 0;
  String _searchQuery = '';
  String _sortBy = 'featured';
  List<Product>? _backendSearchMatches;
  bool _isSearchingBackend = false;

  @override
  bool get wantKeepAlive => true;

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
    _applyInitialRouteParams(
      query: widget.initialQuery,
      category: widget.initialCategory,
      triggerSearch: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Catalog3D.refresh();
      context.read<ProductProvider>().ensureProductsLoaded();
      if (_searchQuery.trim().isNotEmpty) {
        _runHybridSearch(_searchQuery.trim());
      }
    });
  }

  @override
  void didUpdateWidget(covariant DiscoverScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialQuery != oldWidget.initialQuery ||
        widget.initialCategory != oldWidget.initialCategory) {
      _applyInitialRouteParams(
        query: widget.initialQuery,
        category: widget.initialCategory,
        triggerSearch: true,
      );
    }
  }

  void _applyInitialRouteParams({
    String? query,
    String? category,
    required bool triggerSearch,
  }) {
    bool changed = false;
    if (query != null && query.trim() != _searchQuery.trim()) {
      _searchQuery = query.trim();
      _searchController.text = _searchQuery;
      changed = true;
    }
    if (category != null && category.trim().isNotEmpty) {
      final idx = _categories.indexWhere(
        (c) => (c['key'] as String).toLowerCase() == category.trim().toLowerCase(),
      );
      if (idx != -1 && idx != _selectedCategoryIndex) {
        _selectedCategoryIndex = idx;
        changed = true;
      }
    }
    if (changed) {
      if (mounted) setState(() {});
      if (triggerSearch) {
        if (_searchQuery.isNotEmpty) {
          _runHybridSearch(_searchQuery);
        } else {
          setState(() => _backendSearchMatches = null);
        }
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    context.read<ProductProvider>().invalidateAllAndRefresh();
    if (_searchQuery.trim().isNotEmpty) {
      _runHybridSearch(_searchQuery.trim());
    }
  }

  void _onSearchChanged(String val) {
    final trimmed = val.trim();
    setState(() {
      _searchQuery = trimmed;
      if (trimmed.isEmpty) {
        _backendSearchMatches = null;
        _isSearchingBackend = false;
      }
    });

    _searchDebounce?.cancel();
    if (trimmed.isEmpty) return;

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _runHybridSearch(trimmed);
    });
  }

  void _onSearchSubmitted([String? raw]) {
    _searchDebounce?.cancel();
    final q = (raw ?? _searchController.text).trim();
    if (q.length >= 2) {
      context.read<ShopStateProvider>().addSearchTerm(q);
    }
    _searchFocusNode.unfocus();
    setState(() => _searchQuery = q);
    if (q.isNotEmpty) {
      _runHybridSearch(q);
    } else {
      setState(() => _backendSearchMatches = null);
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _backendSearchMatches = null;
      _isSearchingBackend = false;
    });
  }

  Future<void> _runHybridSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    final selectedKey = _categories[_selectedCategoryIndex]['key'] as String;
    setState(() => _isSearchingBackend = true);
    try {
      final results = await context.read<ProductProvider>().searchCatalog(
            clean,
            category: selectedKey == '3D' ? 'All' : selectedKey,
            only3D: selectedKey == '3D',
            sort: _sortBy,
          );
      if (!mounted || _searchQuery.trim() != clean) return;
      setState(() {
        _backendSearchMatches = results;
        _isSearchingBackend = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isSearchingBackend = false);
    }
  }

  Future<void> _handleVoiceSearch() async {
    final voice = context.read<VoiceProvider>();
    final transcript = await voice.toggleRecordingAndTranscribe(
      context: context,
    );
    if (!mounted || transcript == null || transcript.trim().isEmpty) return;

    final clean = transcript.trim();
    _searchController.text = clean;
    _onSearchSubmitted(clean);
  }

  List<Product> _filterAndSort(List<Product> allProducts, Set<int> ids3d) {
    final selectedKey = _categories[_selectedCategoryIndex]['key'] as String;
    final q = _searchQuery.trim();

    // Combine instant local matches + deep backend hybrid matches
    final localFiltered = ProductFilters(
      category: selectedKey == '3D' ? 'All' : selectedKey,
      only3D: selectedKey == '3D',
      query: q,
    ).apply(allProducts, ids3d);

    final mergedMap = <int, Product>{};
    for (final p in localFiltered) {
      mergedMap[p.id] = p;
    }

    if (q.isNotEmpty && _backendSearchMatches != null) {
      for (final p in _backendSearchMatches!) {
        final catOk = selectedKey == '3D'
            ? ids3d.contains(p.id)
            : ProductFilters.categoryMatches(p.category, selectedKey);
        if (catOk) {
          mergedMap.putIfAbsent(p.id, () => p);
        }
      }
    }

    final filtered = mergedMap.values.toList();

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
        if (q.isEmpty) {
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
    }

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
                      final provider = context.watch<ProductProvider>();

                      if (!provider.hasProducts && provider.isLoadingProducts) {
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
                          itemBuilder: (_, _) => const ProductCardSkeleton(),
                        );
                      }

                      if (!provider.hasProducts &&
                          provider.productsError != null) {
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
                                  'Could not load catalog.\n${provider.productsError}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: textColor),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF1E88E5),
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

                      final allProducts = provider.products;
                      final filtered = _filterAndSort(allProducts, ids3d);
                      final activeCat = _categories[_selectedCategoryIndex];

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
                                      final item = filtered[index];
                                      return FadeSlideIn.staggered(
                                        key: ValueKey('discover-${item.id}'),
                                        index: index,
                                        child: ProductCard(
                                          product: item,
                                          onProductDeleted: () {
                                            context
                                                .read<ProductProvider>()
                                                .purgeDeletedProduct(item.id);
                                            context
                                                .read<ShopStateProvider>()
                                                .purgeDeletedProduct(item.id);
                                          },
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
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
    final isNarrow = MediaQuery.of(context).size.width < 430;

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
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    textInputAction: TextInputAction.search,
                    onChanged: _onSearchChanged,
                    onSubmitted: _onSearchSubmitted,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: isNarrow
                          ? 'Search products or 3D models...'
                          : "Search or ask AI: 'Headphones under \$350'...",
                      hintStyle: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                      prefixIcon: IconButton(
                        tooltip: 'Search Catalog',
                        onPressed: () => _onSearchSubmitted(),
                        icon: _isSearchingBackend
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.search_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_searchQuery.isNotEmpty)
                            IconButton(
                              tooltip: 'Clear search',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.clear_rounded,
                                color: Colors.white70,
                                size: 18,
                              ),
                              onPressed: _clearSearch,
                            ),
                          Consumer<VoiceProvider>(
                            builder: (context, voice, _) {
                              return IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: voice.isRecording
                                    ? 'Stop voice input'
                                    : 'Voice Search (Whisper STT)',
                                onPressed: _handleVoiceSearch,
                                icon: voice.isTranscribing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Icon(
                                        voice.isRecording
                                            ? Icons.stop_circle_rounded
                                            : Icons.mic_none_rounded,
                                        color: voice.isRecording
                                            ? Colors.redAccent
                                            : Colors.white,
                                        size: 20,
                                      ),
                              );
                            },
                          ),
                          if (!isNarrow)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => GlobalVoiceOverlay.openConcierge(
                                  initialQuery: _searchQuery.trim().isNotEmpty
                                      ? _searchQuery.trim()
                                      : null,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF00ACC1),
                                        Color(0xFF1E88E5),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.graphic_eq_rounded,
                                        color: Colors.white,
                                        size: 13,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Voice AI',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Multimodal AI Search (Image + Voice)',
                            icon: const Icon(
                              Icons.camera_alt_outlined,
                              color: Colors.white,
                              size: 19,
                            ),
                            onPressed: () => showMultimodalSearchSheet(
                              context,
                              initialQuery: _searchQuery.trim(),
                            ),
                          ),
                        ],
                      ),
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
            onSelected: (_) {
              setState(() => _selectedCategoryIndex = index);
              if (_searchQuery.trim().isNotEmpty) {
                _runHybridSearch(_searchQuery.trim());
              }
            },
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
                onTap: () {
                  setState(() => _selectedCategoryIndex = index);
                  if (_searchQuery.trim().isNotEmpty) {
                    _runHybridSearch(_searchQuery.trim());
                  }
                },
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
    final hasSearch = _searchQuery.trim().isNotEmpty;

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
                  Flexible(
                    child: Text(
                      hasSearch
                          ? "Showing $count result${count == 1 ? '' : 's'} for '${_searchQuery.trim()}'"
                          : title,
                      style: TextStyle(
                        fontSize: hasSearch ? 17.5 : 20,
                        fontWeight: FontWeight.w900,
                        color: textColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (hasSearch)
                    ActionChip(
                      avatar: const Icon(Icons.close_rounded, size: 15),
                      label: const Text(
                        'Clear',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: _clearSearch,
                    )
                  else
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
                hasSearch
                    ? 'Filtered in $title • Hybrid keyword & semantic search active'
                    : subtitle,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white60 : const Color(0xFF64748B),
                ),
              ),
              if (hasSearch)
                Consumer<VoiceProvider>(
                  builder: (context, voice, _) {
                    final heard = voice.lastHeardTranscript?.trim() ?? '';
                    if (heard.isEmpty ||
                        heard.toLowerCase() != _searchQuery.trim().toLowerCase()) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          voice.wasLastTranscriptRepaired
                              ? Icons.auto_fix_high_rounded
                              : Icons.mic_rounded,
                          size: 14,
                        ),
                        label: Text(
                          'Heard: "$heard" • Edit',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: () {
                          _searchFocusNode.requestFocus();
                          _searchController.selection = TextSelection(
                            baseOffset: 0,
                            extentOffset: _searchController.text.length,
                          );
                        },
                      ),
                    );
                  },
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
                  if (v != null) {
                    setState(() => _sortBy = v);
                    if (_searchQuery.trim().isNotEmpty) {
                      _runHybridSearch(_searchQuery.trim());
                    }
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, Color textColor) {
    final q = _searchQuery.trim();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PulsingOrb(
                icon: Icons.search_off_rounded,
                size: 68,
              ),
              const SizedBox(height: 16),
              Text(
                q.isNotEmpty
                    ? 'No catalog items matched "$q"'
                    : 'No matching products in this category',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                q.isNotEmpty
                    ? 'Let CTRL-X AI search alternatives, bundles, or custom B2B sourcing for your exact request.'
                    : 'Try switching to All Products or browse a quick category below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? Colors.white60 : const Color(0xFF64748B),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E88E5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () {
                      context.push(
                        q.isNotEmpty
                            ? '/ctrlx?q=${Uri.encodeComponent(q)}'
                            : '/ctrlx',
                      );
                    },
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text(
                      q.isNotEmpty
                          ? 'Ask CTRL-X AI to find this'
                          : 'Ask CTRL-X AI Assistant',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      _clearSearch();
                      setState(() => _selectedCategoryIndex = 0);
                    },
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Clear & Show All'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: List.generate(_categories.length, (i) {
                  final cat = _categories[i];
                  return ActionChip(
                    avatar: Icon(cat['icon'] as IconData, size: 15),
                    label: Text(
                      cat['title'] as String,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () {
                      _clearSearch();
                      setState(() => _selectedCategoryIndex = i);
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
