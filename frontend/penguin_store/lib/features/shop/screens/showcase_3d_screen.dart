import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/interactive_3d_preview.dart';
import 'package:penguin_store/features/shop/widgets/product_card_skeleton.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';

/// Sketchfab-grade 3D Showcase gallery.
///
/// Features:
/// - Renders cached 3D products at 0ms via [ProductProvider].
/// - Default card state displays crisp studio-lit 3D thumbnails with glassmorphic
///   `3D` badge and subtle orbit hint.
/// - Tapping any card activates an in-place interactive `<model-viewer>` directly
///   inside the card (`camera-controls`, `auto-rotate`, `shadow-intensity="1"`,
///   custom `slot="progress-bar"`).
/// - Single-Active-3D-Card Controller (`_active3DProductId`) ensures at most ONE
///   WebGL `<model-viewer>` context is mounted at a time to prevent browser
///   `webglcontextlost` crashes and keep scrolling smooth.
class Showcase3DScreen extends StatefulWidget {
  const Showcase3DScreen({super.key});

  @override
  State<Showcase3DScreen> createState() => _Showcase3DScreenState();
}

class _Showcase3DScreenState extends State<Showcase3DScreen>
    with AutomaticKeepAliveClientMixin {
  String _selectedFilter = 'All';

  // --- Single-Active-3D-Card Controller (WebGL Protection) ---
  int? _active3DProductId;
  int? _activeModelId;
  String? _activeModelUrl;
  bool _loadingInlineUrl = false;
  String? _inlineError;
  int _activationToken = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ProductProvider>().ensureShowcaseLoaded();
    });
  }

  Future<void> _reload() async {
    _deactivateInline3D();
    await context.read<ProductProvider>().ensureShowcaseLoaded(
          forceRefresh: true,
        );
  }

  void _deactivateInline3D() {
    if (_active3DProductId == null && !_loadingInlineUrl) return;
    _activationToken++;
    setState(() {
      _active3DProductId = null;
      _activeModelId = null;
      _activeModelUrl = null;
      _loadingInlineUrl = false;
      _inlineError = null;
    });
  }

  /// Activates interactive `<model-viewer>` directly inside [item]'s card,
  /// immediately unmounting any previously active card to protect WebGL memory.
  Future<void> _activateInline3D(
    Showcase3DItem item, {
    Product3DModel? model,
  }) async {
    if (item.models.isEmpty) return;
    final chosen = model ?? item.models.first;

    // If this exact card & variant is already active and loaded, leave it running
    if (_active3DProductId == item.product.id &&
        _activeModelId == chosen.id &&
        _activeModelUrl != null) {
      return;
    }

    final token = ++_activationToken;
    final provider = context.read<ProductProvider>();
    final cachedUrl = provider.getCachedSigned3DUrl(chosen.id);

    setState(() {
      _active3DProductId = item.product.id;
      _activeModelId = chosen.id;
      _activeModelUrl = cachedUrl;
      _loadingInlineUrl = cachedUrl == null;
      _inlineError = null;
    });

    if (cachedUrl != null) return;

    try {
      final url = await provider.resolveSigned3DUrl(item.product.id, chosen.id);
      if (!mounted || token != _activationToken) return;
      setState(() {
        _activeModelUrl = url;
        _loadingInlineUrl = false;
        _inlineError = null;
      });
    } catch (e) {
      if (!mounted || token != _activationToken) return;
      setState(() {
        _loadingInlineUrl = false;
        _inlineError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Launches the full-screen 3D studio viewer for [item].
  Future<void> _openFullscreenViewer(
    Showcase3DItem item, {
    Product3DModel? initialModel,
  }) async {
    if (item.models.isEmpty) return;
    final chosen = initialModel ?? item.models.first;

    // Unmount inline WebGL context before pushing full-screen WebGL viewer
    _deactivateInline3D();

    final provider = context.read<ProductProvider>();
    String? url = provider.getCachedSigned3DUrl(chosen.id);

    if (url == null) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(18)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.8,
                      color: Color(0xFF1E88E5),
                    ),
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Opening Fullscreen 3D Studio...',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      Object? err;
      try {
        url = await provider.resolveSigned3DUrl(item.product.id, chosen.id);
      } catch (e) {
        err = e;
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (url == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              err?.toString().replaceFirst('Exception: ', '') ??
                  'Could not load 3D model.',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Product3DViewerScreen(
          productName: item.product.name,
          modelUrl: url!,
          posterUrl: Product.resolveImageUrl(item.product.imageUrl),
          productId: item.product.id,
          models: item.models,
          currentModelId: chosen.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final provider = context.watch<ProductProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final allItems = provider.showcaseItems;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0A0F1D) : const Color(0xFFF3F7FB),
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              onPressed: () async {
                final prodProvider = context.read<ProductProvider>();
                _deactivateInline3D();
                await context.push('/admin');
                if (mounted) {
                  prodProvider.ensureShowcaseLoaded();
                }
              },
              icon: const Icon(Icons.view_in_ar_rounded),
              label: const Text(
                'Admin Studio',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          : null,
      body: RefreshIndicator(
        color: const Color(0xFF1E88E5),
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHero(isAdmin)),
            _buildBodySliver(
              provider: provider,
              allItems: allItems,
              isAdmin: isAdmin,
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBodySliver({
    required ProductProvider provider,
    required List<Showcase3DItem> allItems,
    required bool isAdmin,
    required bool isDark,
  }) {
    if (!provider.hasShowcaseItems && provider.isLoadingShowcase) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 360,
            mainAxisSpacing: 18,
            crossAxisSpacing: 18,
            childAspectRatio: 0.72,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, _) => const ProductCardSkeleton(),
            childCount: 4,
          ),
        ),
      );
    }

    if (!provider.hasShowcaseItems && provider.showcaseError != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 56,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 12),
                Text(
                  provider.showcaseError!,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _reload,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E88E5),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (allItems.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmpty(isAdmin),
      );
    }

    final categories = <String>{
      'All',
      ...allItems
          .map((e) => e.product.category.trim())
          .where((c) => c.isNotEmpty),
    }.toList();

    final items = _selectedFilter == 'All'
        ? allItems
        : allItems
            .where(
              (e) =>
                  e.product.category.toLowerCase() ==
                  _selectedFilter.toLowerCase(),
            )
            .toList();

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _buildStatsAndFilterBar(
            totalProducts: allItems.length,
            totalVariants: allItems.fold<int>(
              0,
              (acc, e) => acc + e.models.length,
            ),
            categories: categories,
            isDark: isDark,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 56),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisSpacing: 20,
              crossAxisSpacing: 20,
              childAspectRatio: 0.67,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final item = items[i];
                final isActiveCard = _active3DProductId == item.product.id;

                return FadeSlideIn.staggered(
                  key: ValueKey('showcase-card-${item.product.id}'),
                  index: i,
                  child: _Sketchfab3DCard(
                    item: item,
                    isActive3D: isActiveCard,
                    activeModelId: isActiveCard ? _activeModelId : null,
                    activeModelUrl: isActiveCard ? _activeModelUrl : null,
                    isLoadingUrl: isActiveCard && _loadingInlineUrl,
                    inlineError: isActiveCard ? _inlineError : null,
                    onActivate3D: (model) =>
                        _activateInline3D(item, model: model),
                    onClose3D: _deactivateInline3D,
                    onFullscreen3D: (model) =>
                        _openFullscreenViewer(item, initialModel: model),
                    onOpenDetails: () {
                      _deactivateInline3D();
                      context.push('/product/${item.product.id}');
                    },
                  ),
                );
              },
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHero(bool isAdmin) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
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
            color: const Color(0xFF1E88E5).withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SnowfallBackground(
          flakes: 24,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
            child: Wrap(
              spacing: 20,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 580),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome_rounded,
                              color: Colors.cyanAccent,
                              size: 14,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'INTERACTIVE 3D SHOWROOM · IN-CARD ORBIT',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 11),
                      const Text(
                        'Spin & Inspect Products Right Inside Every Card',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap any 3D poster to launch live 360° WebGL orbit in-place — or open fullscreen Studio View with Arctic, Clean Studio, and Midnight lighting.',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13.5,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PulsingOrb(
                      icon: Icons.view_in_ar_rounded,
                      size: 56,
                    ),
                    if (isAdmin) ...[
                      const SizedBox(width: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF0D47A1),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () async {
                          final prodProvider = context.read<ProductProvider>();
                          _deactivateInline3D();
                          await context.push('/admin');
                          if (mounted) {
                            prodProvider.ensureShowcaseLoaded();
                          }
                        },
                        icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                        label: const Text(
                          'Upload GLB',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatsAndFilterBar({
    required int totalProducts,
    required int totalVariants,
    required List<String> categories,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Badge3D(),
              const SizedBox(width: 10),
              Text(
                '$totalProducts 3D Products · $totalVariants Interactive GLBs',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white70 : const Color(0xFF334155),
                ),
              ),
              if (_active3DProductId != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00ACC1).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '1 WebGL Active',
                    style: TextStyle(
                      color: Color(0xFF00ACC1),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categories.map((cat) {
                final selected = _selectedFilter == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: selected,
                    onSelected: (_) {
                      _deactivateInline3D();
                      setState(() => _selectedFilter = cat);
                    },
                    selectedColor: const Color(0xFF1E88E5),
                    backgroundColor:
                        isDark ? const Color(0xFF151E32) : Colors.white,
                    labelStyle: TextStyle(
                      color: selected
                          ? Colors.white
                          : (isDark
                              ? Colors.white70
                              : const Color(0xFF334155)),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(bool isAdmin) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PulsingOrb(icon: Icons.view_in_ar_rounded, size: 78),
            const SizedBox(height: 18),
            const Text(
              'No 3D models uploaded yet',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Upload a .glb file in Admin Studio to display it here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            if (isAdmin) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E88E5),
                ),
                onPressed: () async {
                  await context.push('/admin');
                  if (mounted) _reload();
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Open Admin Studio'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Sketchfab3DCard extends StatelessWidget {
  final Showcase3DItem item;
  final bool isActive3D;
  final int? activeModelId;
  final String? activeModelUrl;
  final bool isLoadingUrl;
  final String? inlineError;
  final void Function(Product3DModel? model) onActivate3D;
  final VoidCallback onClose3D;
  final void Function(Product3DModel? model) onFullscreen3D;
  final VoidCallback onOpenDetails;

  const _Sketchfab3DCard({
    required this.item,
    required this.isActive3D,
    required this.activeModelId,
    required this.activeModelUrl,
    required this.isLoadingUrl,
    required this.inlineError,
    required this.onActivate3D,
    required this.onClose3D,
    required this.onFullscreen3D,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    final p = item.product;
    final resolvedPoster = Product.resolveImageUrl(p.imageUrl);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentModel = item.models.isNotEmpty
        ? item.models.firstWhere(
            (m) => m.id == activeModelId,
            orElse: () => item.models.first,
          )
        : null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131C2E) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isActive3D
              ? const Color(0xFF00ACC1)
              : const Color(0xFF1E88E5).withValues(alpha: 0.22),
          width: isActive3D ? 2.0 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: (isActive3D
                    ? const Color(0xFF00ACC1)
                    : const Color(0xFF0D47A1))
                .withValues(alpha: isActive3D ? 0.24 : (isDark ? 0.25 : 0.08)),
            blurRadius: isActive3D ? 26 : 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Preview Viewport (Poster OR Live Interactive <model-viewer>) ---
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildViewport(
                  product: p,
                  resolvedPoster: resolvedPoster,
                  isDark: isDark,
                ),

                // Top-left status pill (Category OR LIVE 3D badge)
                Positioned(
                  top: 10,
                  left: 10,
                  child: isActive3D
                      ? _GlassPill(
                          color: const Color(0xFF0A192F).withValues(alpha: 0.78),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: Color(0xFF22C55E),
                              ),
                              SizedBox(width: 6),
                              Text(
                                'LIVE 3D',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.7,
                                ),
                              ),
                            ],
                          ),
                        )
                      : _GlassPill(
                          color: const Color(0xFF0A192F).withValues(alpha: 0.72),
                          child: Text(
                            p.category.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                ),

                // Top-right glassmorphic 3D badge (default) OR Close + Fullscreen (active)
                Positioned(
                  top: 10,
                  right: 10,
                  child: isActive3D
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _OverlayIconBtn(
                              tooltip: 'Fullscreen 3D Studio',
                              icon: Icons.fullscreen_rounded,
                              onTap: () => onFullscreen3D(currentModel),
                            ),
                            const SizedBox(width: 6),
                            _OverlayIconBtn(
                              tooltip: 'Exit 3D Preview',
                              icon: Icons.close_rounded,
                              onTap: onClose3D,
                            ),
                          ],
                        )
                      : _GlassPill(
                          color: const Color(0xFF1E88E5).withValues(alpha: 0.88),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.view_in_ar_rounded,
                                size: 13,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                '3D',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),

                // Bottom subtle orbit hint on default poster state
                if (!isActive3D)
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: IgnorePointer(
                      child: _GlassPill(
                        color: const Color(0xFF0A192F).withValues(alpha: 0.78),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.threed_rotation_rounded,
                              size: 14,
                              color: Colors.cyanAccent,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Tap to Orbit 3D',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // --- Card Metadata + Variant Switcher + Actions ---
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '\$${p.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Color(0xFF1E88E5),
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.layers_outlined,
                      size: 14,
                      color: isDark ? Colors.white54 : Colors.blueGrey,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${item.models.length} ${item.models.length == 1 ? 'GLB' : 'GLBs'}',
                      style: TextStyle(
                        color: isDark ? Colors.white60 : Colors.blueGrey,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (item.models.length > 1) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 28,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: item.models.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (_, idx) {
                        final m = item.models[idx];
                        final selected =
                            isActive3D && activeModelId == m.id;
                        return ChoiceChip(
                          label: Text(
                            m.variantName?.isNotEmpty == true
                                ? m.variantName!
                                : 'View ${idx + 1}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? Colors.white
                                  : (isDark
                                      ? Colors.white70
                                      : const Color(0xFF334155)),
                            ),
                          ),
                          selected: selected,
                          selectedColor: const Color(0xFF00ACC1),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          onSelected: (_) => onActivate3D(m),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: isActive3D
                              ? const Color(0xFF00ACC1)
                              : const Color(0xFF1E88E5),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          if (isActive3D) {
                            onFullscreen3D(currentModel);
                          } else {
                            onActivate3D(null);
                          }
                        },
                        icon: Icon(
                          isActive3D
                              ? Icons.fullscreen_rounded
                              : Icons.threed_rotation_rounded,
                          size: 17,
                        ),
                        label: Text(
                          isActive3D ? 'Fullscreen 3D' : 'Orbit in 3D',
                          style: const TextStyle(
                            fontSize: 12.2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: onOpenDetails,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1E88E5),
                        side: BorderSide(
                          color: const Color(0xFF1E88E5).withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.shopping_bag_outlined, size: 15),
                      label: const Text(
                        'Full View / Buy',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewport({
    required Product product,
    required String resolvedPoster,
    required bool isDark,
  }) {
    // Active In-Place Live 3D Mode
    if (isActive3D) {
      if (inlineError != null) {
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFEAF4FE), Color(0xFFD2E7FA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.redAccent,
                    size: 36,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    inlineError!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0F172A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    onPressed: () => onActivate3D(null),
                    child: const Text('Retry 3D'),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      if (isLoadingUrl || activeModelUrl == null) {
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildPosterLayer(resolvedPoster, isDark),
            Shimmer.fromColors(
              baseColor: const Color(0xFF1E88E5).withValues(alpha: 0.08),
              highlightColor: Colors.white.withValues(alpha: 0.35),
              child: Container(color: Colors.white),
            ),
            Center(
              child: _GlassPill(
                color: const Color(0xFF0A192F).withValues(alpha: 0.82),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.cyanAccent,
                      ),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Loading Interactive 3D...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }

      return Inline3DCardViewer(
        key: ValueKey('inline-3d-${product.id}-$activeModelId'),
        modelUrl: activeModelUrl!,
        posterUrl: resolvedPoster.isEmpty ? null : resolvedPoster,
        alt: '${product.name} interactive 3D preview',
      );
    }

    // Default Poster Mode — tap anywhere on the poster to activate live 3D in-place
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onActivate3D(null),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: _buildPosterLayer(resolvedPoster, isDark),
      ),
    );
  }

  Widget _buildPosterLayer(String resolvedPoster, bool isDark) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.15),
          radius: 0.9,
          colors: [Color(0xFFF4F9FF), Color(0xFFD2E7FA)],
        ),
      ),
      child: resolvedPoster.isEmpty
          ? const _FallbackPoster()
          : CachedNetworkImage(
              imageUrl: resolvedPoster,
              fit: BoxFit.cover,
              placeholder: (_, _) => Shimmer.fromColors(
                baseColor: const Color(0xFFDDECF9),
                highlightColor: const Color(0xFFF4F9FF),
                child: Container(color: Colors.white),
              ),
              errorWidget: (_, _, _) => const _FallbackPoster(),
            ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  final Widget child;
  final Color color;

  const _GlassPill({required this.child, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _OverlayIconBtn extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  const _OverlayIconBtn({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFF0A192F).withValues(alpha: 0.78),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 17, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _FallbackPoster extends StatelessWidget {
  const _FallbackPoster();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A192F), Color(0xFF1565C0), Color(0xFF00ACC1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.view_in_ar_rounded,
          size: 64,
          color: Colors.white70,
        ),
      ),
    );
  }
}
