
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class TrendingCarousel extends StatefulWidget {
  final String country;

  const TrendingCarousel({
    super.key,
    this.country = 'Pakistan',
  });

  @override
  State<TrendingCarousel> createState() => _TrendingCarouselState();
}

class _TrendingCarouselState extends State<TrendingCarousel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ProductProvider>().ensureTrendingLoaded(widget.country);
    });
  }

  @override
  void didUpdateWidget(covariant TrendingCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.country != widget.country) {
      context.read<ProductProvider>().ensureTrendingLoaded(widget.country);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;
    final provider = context.watch<ProductProvider>();
    final trendingProducts = provider.trendingFor(widget.country);
    final isLoading = provider.isTrendingLoading(widget.country);

    if (isLoading && trendingProducts.isEmpty) {
      return SizedBox(
        height: 175,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          scrollDirection: Axis.horizontal,
          itemCount: 4,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, _) => Shimmer.fromColors(
            baseColor:
                isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            highlightColor:
                isDark ? const Color(0xFF334155) : const Color(0xFFF8FAFC),
            child: Container(
              width: 132,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      );
    }

    if (trendingProducts.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth >= 900
            ? 165.0
            : constraints.maxWidth >= 600
                ? 145.0
                : 122.0;

        final cardHeight = cardWidth * 1.47;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 11),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.local_fire_department_rounded,
                      color: primary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Trending in ${widget.country}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          'Top products today',
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: primary.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      'TOP ${trendingProducts.length}',
                      style: TextStyle(
                        color: primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: trendingProducts.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 9),
                itemBuilder: (context, index) {
                  final product = trendingProducts[index];
                  final id = product['id'];
                  final name =
                      (product['name'] ?? 'Trending Product').toString();
                  final imageUrl =
                      (product['image_url'] ?? '').toString();

                  final price = product['price'];
                  final currency = context.watch<CurrencyProvider>();
                  final priceText = price is num
                      ? currency.format(price.toDouble())
                      : null;

                  return SizedBox(
                    width: cardWidth,
                    child: Material(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(11),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: id == null
                            ? null
                            : () => context.push('/product/$id'),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: theme.dividerColor.withOpacity(0.16),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    StudioProductImage(
                                      productId: id is num
                                          ? id.toInt()
                                          : (int.tryParse(
                                                  id?.toString() ?? '',
                                                ) ??
                                                0),
                                      imageUrl: imageUrl,
                                      borderRadius:
                                          const BorderRadius.vertical(
                                        top: Radius.circular(10),
                                      ),
                                      padding: 8.0,
                                    ),
                                    Positioned(
                                      left: 7,
                                      top: 7,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: primary,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.local_fire_department,
                                              color: Colors.white,
                                              size: 12,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              '#${index + 1}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
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
                                padding: const EdgeInsets.fromLTRB(
                                  8, 8, 8, 9,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (priceText != null)
                                      Text(
                                        priceText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      )
                                    else
                                      Text(
                                        'View Product',
                                        style: TextStyle(
                                          color: primary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
          ],
        );
      },
    );
  }
}
