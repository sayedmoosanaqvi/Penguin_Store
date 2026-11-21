import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class WishlistScreen extends StatelessWidget {
  const WishlistScreen({super.key});

  void _moveAllToCart(BuildContext context, List<Product> items) {
    final cart = context.read<CartProvider>();
    int addedCount = 0;
    for (final p in items) {
      if (p.stock > 0) {
        cart.addToCart(p);
        addedCount++;
      }
    }
    if (addedCount > 0) {
      CustomToast.show(
        context,
        'Added $addedCount favorite item${addedCount == 1 ? '' : 's'} to your cart!',
      );
    } else {
      CustomToast.show(
        context,
        'All saved items are currently out of stock.',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shopState = context.watch<ShopStateProvider>();
    final currency = context.watch<CurrencyProvider>();
    final items = shopState.wishlist;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: colors.onSurface),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.favorite_rounded,
                color: Colors.redAccent,
                size: 19,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'My Favorites (${items.length})',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: colors.onSurface,
              ),
            ),
          ],
        ),
        actions: [
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonalIcon(
                onPressed: () => _moveAllToCart(context, items),
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 17),
                label: const Text('Add All to Cart'),
              ),
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.favorite_border_rounded,
                        size: 48,
                        color: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'No Saved Favorites Yet',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the heart icon on any product card or 3D twin to save it here with live stock & price-drop tracking.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: () => context.go('/discover'),
                      icon: const Icon(Icons.explore_outlined),
                      label: const Text('Explore Store Catalog'),
                    ),
                  ],
                ),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final crossAxisCount = width > 980
                        ? 3
                        : width > 640
                            ? 2
                            : 1;

                    return GridView.builder(
                      padding: const EdgeInsets.all(18),
                      itemCount: items.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 195,
                      ),
                      itemBuilder: (context, index) {
                        final product = items[index];
                        final has3D = Catalog3D.has(product.id);
                        final isOut = product.stock <= 0;
                        final isLow = product.stock > 0 && product.stock < 10;
                        final hasPriceDrop = product.originalPrice != null &&
                            product.originalPrice! > product.price;

                        return FadeSlideIn.staggered(
                          key: ValueKey('fav-card-${product.id}'),
                          index: index,
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: colors.outlineVariant.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () =>
                                      context.push('/product/${product.id}'),
                                  child: SizedBox(
                                    width: 118,
                                    height: double.infinity,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        StudioProductImage(
                                          productId: product.id,
                                          imageUrl: product.imageUrl,
                                          padding: 10.0,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        if (has3D)
                                          Positioned(
                                            top: 6,
                                            left: 6,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 3,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF0B132B),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFF00E5FF,
                                                  ),
                                                ),
                                              ),
                                              child: const Text(
                                                '3D VIEW',
                                                style: TextStyle(
                                                  color: Color(0xFF00E5FF),
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              product.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  GoogleFonts.plusJakartaSans(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w800,
                                                    color: colors.onSurface,
                                                  ),
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Remove from Favorites',
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () {
                                              shopState.toggleWishlist(product);
                                              CustomToast.show(
                                                context,
                                                'Removed "${product.name}" from Favorites',
                                              );
                                            },
                                            icon: const Icon(
                                              Icons.favorite_rounded,
                                              color: Colors.redAccent,
                                              size: 20,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isOut
                                                  ? Colors.redAccent.withValues(
                                                      alpha: 0.14,
                                                    )
                                                  : (isLow
                                                        ? Colors.amber
                                                              .withValues(
                                                                alpha: 0.16,
                                                              )
                                                        : const Color(
                                                            0xFF10B981,
                                                          ).withValues(
                                                            alpha: 0.14,
                                                          )),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              isOut
                                                  ? 'Out of Stock'
                                                  : (isLow
                                                        ? 'Only ${product.stock} Left'
                                                        : 'In Stock (${product.stock})'),
                                              style:
                                                  GoogleFonts.plusJakartaSans(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w800,
                                                    color: isOut
                                                        ? Colors.redAccent
                                                        : (isLow
                                                              ? Colors
                                                                    .amber
                                                                    .shade800
                                                              : const Color(
                                                                  0xFF10B981,
                                                                )),
                                                  ),
                                            ),
                                          ),
                                          if (hasPriceDrop ||
                                              (product.discountPercent ?? 0) >
                                                  0)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 7,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: colors.primaryContainer,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                'PRICE DROP ACTIVE',
                                                style:
                                                    GoogleFonts.plusJakartaSans(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: colors
                                                          .onPrimaryContainer,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Text(
                                            currency.format(product.price),
                                            style: GoogleFonts.plusJakartaSans(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w900,
                                              color: colors.primary,
                                            ),
                                          ),
                                          if (product.originalPrice !=
                                              null) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              currency.format(
                                                product.originalPrice!,
                                              ),
                                              style: GoogleFonts.inter(
                                                fontSize: 12,
                                                decoration:
                                                    TextDecoration.lineThrough,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const Spacer(),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: SizedBox(
                                              height: 36,
                                              child: FilledButton.icon(
                                                onPressed: isOut
                                                    ? null
                                                    : () {
                                                        context
                                                            .read<
                                                              CartProvider
                                                            >()
                                                            .addToCart(product);
                                                        shopState
                                                            .toggleWishlist(
                                                              product,
                                                            );
                                                        CustomToast.show(
                                                          context,
                                                          'Moved "${product.name}" to your cart!',
                                                        );
                                                      },
                                                icon: const Icon(
                                                  Icons
                                                      .shopping_bag_outlined,
                                                  size: 15,
                                                ),
                                                label: const Text(
                                                  'Move to Cart',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            height: 36,
                                            child: OutlinedButton(
                                              onPressed: () => context.push(
                                                '/product/${product.id}',
                                              ),
                                              child: const Text(
                                                'View',
                                                style: TextStyle(fontSize: 12),
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
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
    );
  }
}
