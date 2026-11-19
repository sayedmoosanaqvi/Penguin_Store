import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/product_card_skeleton.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';

/// Public gallery of every product in Penguin Store that has a 3D model.
class Showcase3DScreen extends StatefulWidget {
  const Showcase3DScreen({super.key});

  @override
  State<Showcase3DScreen> createState() => _Showcase3DScreenState();
}

class _Showcase3DScreenState extends State<Showcase3DScreen> {
  final Showcase3DService _service = Showcase3DService();
  late Future<List<Showcase3DItem>> _future;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    Catalog3D.refresh(force: true);
    setState(() {
      _future = _service.fetchShowcase();
    });
  }

  Future<void> _openViewer(
    Showcase3DItem item, {
    Product3DModel? initialModel,
  }) async {
    if (item.models.isEmpty) return;
    final chosenModel = initialModel ?? item.models.first;

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
                CircularProgressIndicator(color: Color(0xFF1E88E5)),
                SizedBox(height: 14),
                Text(
                  'Preparing 3D Studio View...',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    String? url;
    Object? err;
    try {
      url = await _service.fetchModelUrl(item.product.id, chosenModel.id);
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

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Product3DViewerScreen(
          productName: item.product.name,
          modelUrl: url!,
          posterUrl: Product.resolveImageUrl(item.product.imageUrl),
          productId: item.product.id,
          models: item.models,
          currentModelId: chosenModel.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0A0F1D)
          : const Color(0xFFF3F7FB),
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              onPressed: () async {
                await context.push('/admin/3d');
                if (mounted) _reload();
              },
              icon: const Icon(Icons.view_in_ar_rounded),
              label: const Text(
                '3D Studio',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          : null,
      body: RefreshIndicator(
        color: const Color(0xFF1E88E5),
        onRefresh: () async => _reload(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHero(isAdmin)),
            FutureBuilder<List<Showcase3DItem>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 340,
                        mainAxisSpacing: 18,
                        crossAxisSpacing: 18,
                        childAspectRatio: 0.72,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => const ProductCardSkeleton(),
                        childCount: 4,
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
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
                              snap.error
                                  .toString()
                                  .replaceFirst('Exception: ', ''),
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

                final allItems = snap.data ?? const [];
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
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 340,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.69,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => FadeSlideIn.staggered(
                            index: i,
                            child: _ShowcaseCard(
                              item: items[i],
                              onView3D: (model) =>
                                  _openViewer(items[i], initialModel: model),
                              onDetails: () => context.push(
                                '/product/${items[i].product.id}',
                                extra: items[i].product,
                              ),
                            ),
                          ),
                          childCount: items.length,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
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
          flakes: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Wrap(
              spacing: 20,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
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
                              'PENGUIN 3D INTERACTIVE SHOWROOM',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Inspect Every Angle in True 360° 3D',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Rotate, zoom, and switch studio lighting backdrops (Arctic Ice, Clean Studio, Midnight) on live GLB models stored in Supabase.',
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
                          await context.push('/admin/3d');
                          if (mounted) _reload();
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
                '$totalProducts 3D Products · $totalVariants Interactive GLB Assets',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white70 : const Color(0xFF334155),
                ),
              ),
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
                    onSelected: (_) => setState(() => _selectedFilter = cat),
                    selectedColor: const Color(0xFF1E88E5),
                    backgroundColor: isDark
                        ? const Color(0xFF151E32)
                        : Colors.white,
                    labelStyle: TextStyle(
                      color: selected
                          ? Colors.white
                          : (isDark ? Colors.white70 : const Color(0xFF334155)),
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
              'Upload a .glb file in 3D Studio to display it here.',
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
                  await context.push('/admin/3d');
                  if (mounted) _reload();
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Open 3D Studio'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShowcaseCard extends StatelessWidget {
  final Showcase3DItem item;
  final void Function(Product3DModel? model) onView3D;
  final VoidCallback onDetails;

  const _ShowcaseCard({
    required this.item,
    required this.onView3D,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final p = item.product;
    final resolvedImage = Product.resolveImageUrl(p.imageUrl);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PressableScale(
      onTap: () => onView3D(null),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF131C2E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF1E88E5).withValues(alpha: 0.22),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0D47A1).withValues(
                alpha: isDark ? 0.25 : 0.08,
              ),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? const [Color(0xFF0F172A), Color(0xFF1E293B)]
                            : const [Color(0xFFEAF4FE), Color(0xFFD7ECFB)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: resolvedImage.isEmpty
                        ? const _FallbackPoster()
                        : Image.network(
                            resolvedImage,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const _FallbackPoster(),
                          ),
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A192F).withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(20),
                      ),
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
                  const Positioned(
                    top: 10,
                    right: 10,
                    child: Badge3D(),
                  ),
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1E88E5)
                                .withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.threed_rotation_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'Tap to Rotate',
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
                ],
              ),
            ),
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
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1E88E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => onView3D(null),
                          icon: const Icon(Icons.view_in_ar_rounded, size: 17),
                          label: const Text(
                            'Launch 3D',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: 'Product Details',
                        onPressed: onDetails,
                        style: IconButton.styleFrom(
                          side: BorderSide(
                            color: const Color(0xFF1E88E5)
                                .withValues(alpha: 0.35),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                          color: Color(0xFF1E88E5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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
