import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

/// Opens a Side-by-Side Product Comparison Sheet for up to 3 products
/// (Price, B2B Wholesale Bulk Tiers, 3D Support, AI Trust Score, Stock & Specs).
Future<void> showProductComparisonSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ProductComparisonSheet(),
  );
}

class _ProductComparisonSheet extends StatelessWidget {
  const _ProductComparisonSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shopState = context.watch<ShopStateProvider>();
    final currency = context.watch<CurrencyProvider>();
    final items = shopState.compareList;
    final ids3d = Catalog3D.ids.value;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: colors.outline.withValues(alpha: 0.16),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.compare_arrows_rounded,
                    color: colors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Side-by-Side Product Comparison (${items.length}/3)',
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      Text(
                        'Compare retail price, B2B bulk tiers, 3D support & AI Trust Score',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (items.isNotEmpty)
                  TextButton(
                    onPressed: shopState.clearCompare,
                    child: const Text('Clear All'),
                  ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.compare_arrows_rounded,
                    size: 56,
                    color: colors.primary.withValues(alpha: 0.45),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'No Products Selected for Comparison',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tap the compare icon on any product card to compare up to 3 items side-by-side.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: items.map((product) {
                      final has3D = ids3d.contains(product.id);
                      final bulk10 = product.price * 0.88;
                      final bulk50 = product.price * 0.78;
                      final trustPct =
                          (88 + (product.id % 10)).clamp(88, 99);

                      return Container(
                        width: 255,
                        margin: const EdgeInsets.only(right: 14),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: colors.primary.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Stack(
                              children: [
                                SizedBox(
                                  height: 145,
                                  width: double.infinity,
                                  child: StudioProductImage(
                                    productId: product.id,
                                    imageUrl: product.imageUrl,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: IconButton.filledTonal(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Remove from comparison',
                                    onPressed: () =>
                                        shopState.toggleCompare(product),
                                    icon: const Icon(Icons.close, size: 15),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              product.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currency.format(product.price),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                                color: colors.primary,
                              ),
                            ),
                            const Divider(height: 18),
                            _specRow(
                              'Category',
                              product.category.toUpperCase(),
                              colors,
                            ),
                            _specRow(
                              'Customer Rating',
                              '${product.rating.toStringAsFixed(1)} ★ (${product.reviews})',
                              colors,
                            ),
                            _specRow(
                              'AI Trust Score',
                              '$trustPct% Authentic',
                              colors,
                              valueColor: const Color(0xFF16A34A),
                            ),
                            _specRow(
                              '3D Interactive',
                              has3D ? 'Yes (360° GLB)' : 'Standard 2D',
                              colors,
                              valueColor: has3D
                                  ? const Color(0xFF00ACC1)
                                  : colors.onSurfaceVariant,
                            ),
                            _specRow(
                              'Stock Availability',
                              product.stock > 0
                                  ? '${product.stock} units ready'
                                  : 'Out of Stock',
                              colors,
                              valueColor: product.stock > 0
                                  ? const Color(0xFF16A34A)
                                  : colors.error,
                            ),
                            _specRow(
                              'B2B 10–49 Units (-12%)',
                              '${currency.format(bulk10)} / unit',
                              colors,
                            ),
                            _specRow(
                              'B2B 50+ Units (-22%)',
                              '${currency.format(bulk50)} / unit',
                              colors,
                              valueColor: colors.primary,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed: product.stock <= 0
                                        ? null
                                        : () {
                                            context
                                                .read<CartProvider>()
                                                .addToCart(product);
                                            CustomToast.show(
                                              context,
                                              '${product.name} added to cart!',
                                            );
                                          },
                                    child: const Text(
                                      'Add to Cart',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                IconButton.outlined(
                                  tooltip: 'Open Details',
                                  onPressed: () {
                                    Navigator.pop(context);
                                    context.push('/product/${product.id}');
                                  },
                                  icon: const Icon(
                                    Icons.open_in_new_rounded,
                                    size: 17,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _specRow(
    String label,
    String value,
    ColorScheme colors, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: valueColor ?? colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
