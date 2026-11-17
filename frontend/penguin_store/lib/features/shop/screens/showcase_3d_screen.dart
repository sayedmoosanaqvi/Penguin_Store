import 'package:flutter/material.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';

/// Gallery of every product that has an active 3D model.
class Showcase3DScreen extends StatefulWidget {
  const Showcase3DScreen({super.key});

  @override
  State<Showcase3DScreen> createState() => _Showcase3DScreenState();
}

class _Showcase3DScreenState extends State<Showcase3DScreen> {
  final Showcase3DService _service = Showcase3DService();
  late Future<List<Showcase3DItem>> _future = _service.fetchShowcase();
  int? _openingProductId;

  Future<void> _reload() async {
    final next = _service.fetchShowcase();
    setState(() => _future = next);
    Catalog3D.refresh(force: true);
    try {
      await next;
    } catch (_) {}
  }

  Future<void> _open(Showcase3DItem item) async {
    if (_openingProductId != null || item.models.isEmpty) return;
    setState(() => _openingProductId = item.product.id);

    try {
      final model = item.models.first;
      final url = await _service.fetchModelUrl(item.product.id, model.id);
      if (!mounted) return;

      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 380),
          pageBuilder: (_, __, ___) => Product3DViewerScreen(
            productName: item.product.name,
            modelUrl: url,
            posterUrl:
                item.product.imageUrl.isNotEmpty ? item.product.imageUrl : null,
            productId: item.product.id,
            models: item.models,
            currentModelId: model.id,
          ),
          transitionsBuilder: (_, animation, __, child) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _openingProductId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('3D Showcase')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<Showcase3DItem>>(
          future: _future,
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <Showcase3DItem>[];

            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _hero(theme, items.length)),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (snapshot.hasError)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_rounded, size: 40),
                          const SizedBox(height: 8),
                          const Text('Could not load 3D models.'),
                          TextButton(
                            onPressed: _reload,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (items.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(30),
                        child: Text(
                          'No 3D models yet.\nCheck back soon!',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  )
                else
                  SliverLayoutBuilder(
                    builder: (context, c) {
                      final w = c.crossAxisExtent;
                      final cols = w >= 1000 ? 4 : w >= 700 ? 3 : 2;
                      return SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.78,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => FadeSlideIn.staggered(
                              key: ValueKey('3d-${items[i].product.id}'),
                              index: i,
                              child: _card(theme, items[i]),
                            ),
                            childCount: items.length,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _hero(ThemeData theme, int count) {
    return Container(
      margin: const EdgeInsets.all(12),
      height: 130,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SnowfallBackground(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const PulsingOrb(
                size: 62,
                icon: Icons.view_in_ar_rounded,
                colors: [Color(0x66FFFFFF), Color(0x33FFFFFF)],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Touch it. Spin it. Own it.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      count == 0
                          ? 'Interactive 3D products'
                          : '$count products in interactive 3D',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(ThemeData theme, Showcase3DItem item) {
    final p = item.product;
    final opening = _openingProductId == p.id;

    return PressableScale(
      onTap: () => _open(item),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.primaryColor.withValues(alpha: 0.14)),
          boxShadow: [
            BoxShadow(
              color: theme.primaryColor.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(15)),
                    child: p.imageUrl.isEmpty
                        ? const ColoredBox(color: Color(0xFFEAF5FF))
                        : Image.network(
                            p.imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const ColoredBox(
                              color: Color(0xFFEAF5FF),
                              child: Icon(Icons.view_in_ar_rounded, size: 40),
                            ),
                          ),
                  ),
                  const Positioned(left: 8, top: 8, child: Badge3D()),
                  if (opening)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x55FFFFFF),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '\$${p.price.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: theme.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Product details',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ProductDetailScreen(
                          product: p,
                          productId: p.id,
                        ),
                      ),
                    ),
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
