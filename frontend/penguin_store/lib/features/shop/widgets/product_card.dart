import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/core/services/app_notifier.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/product_comparison_sheet.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class ProductCard extends StatefulWidget {
  final Product product;
  final VoidCallback onProductDeleted;
  final String? heroTag;

  const ProductCard({
    super.key,
    required this.product,
    required this.onProductDeleted,
    this.heroTag,
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  bool _isHovering = false;
  bool _isDeleting = false;

  void _openProduct() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          product: widget.product,
          productId: widget.product.id,
          heroTag: widget.heroTag ?? 'product-${widget.product.id}',
        ),
      ),
    );
  }

  void _addToCart() {
    if (widget.product.stock <= 0) {
      CustomToast.show(context, 'This item is currently out of stock.',
          isError: true);
      return;
    }
    context.read<CartProvider>().addToCart(widget.product);
    CustomToast.show(
      context,
      '${widget.product.name} added to cart!',
    );
  }

  Future<void> _deleteProduct() async {
    if (widget.product.id == 144) {
      CustomToast.show(
        context,
        'Product #144 is protected as the reference 3D showcase asset.',
        isError: true,
      );
      return;
    }

    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        title: const Text('Delete Product?'),
        content: Text(
          "Are you sure you want to delete '${widget.product.name}'?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'DELETE',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted || _isDeleting) return;

    setState(() => _isDeleting = true);

    try {
      final res = await ProductService()
          .deleteProduct(widget.product.id)
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (res.success) {
        await context.read<ProductProvider>().purgeDeletedProduct(widget.product.id);
        if (mounted) {
          await context.read<ShopStateProvider>().purgeDeletedProduct(widget.product.id);
        }
        AppNotifier.showSuccess(
          res.message.isNotEmpty
              ? res.message
              : "Deleted '${widget.product.name}' permanently.",
        );
        widget.onProductDeleted();
      } else {
        AppNotifier.showError(
          "Delete failed for '${widget.product.name}': ${res.message}",
        );
      }
    } catch (e) {
      AppNotifier.showError(
        "Delete failed for '${widget.product.name}': $e",
      );
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  Widget _buildBadge(
    String label,
    Color backgroundColor,
    Color textColor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final currency = context.watch<CurrencyProvider>();
    final product = widget.product;
    final primary = colors.primary;
    final outOfStock = product.stock <= 0;
    final lowStock = product.stock > 0 && product.stock <= 8;

    final hasDiscount = product.originalPrice != null &&
        product.originalPrice! > product.price;

    final discount = product.discountPercent ??
        (hasDiscount
            ? ((product.originalPrice! - product.price) /
                    product.originalPrice! *
                    100)
                .round()
            : null);

    final effectiveHeroTag = widget.heroTag ?? 'product-${product.id}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 180;
        final veryCompact = constraints.maxWidth < 125;

        return RepaintBoundary(
          child: MouseRegion(
            onEnter: (_) {
              if (kIsWeb && mounted) {
                setState(() => _isHovering = true);
              }
            },
            onExit: (_) {
              if (kIsWeb && mounted) {
                setState(() => _isHovering = false);
              }
            },
            child: Semantics(
              container: true,
              label:
                  '${product.name}, ${currency.format(product.price)}, rated ${product.rating} stars',
              child: Material(
            color: colors.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: _openProduct,
              borderRadius: BorderRadius.circular(14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 190),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isHovering
                        ? primary
                        : theme.dividerColor.withValues(alpha: 0.2),
                    width: _isHovering ? 1.5 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: primary.withValues(
                        alpha: _isHovering ? 0.14 : 0.04,
                      ),
                      blurRadius: _isHovering ? 16 : 6,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Standardized Studio Product Image Framing
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Hero(
                            tag: effectiveHeroTag,
                            child: StudioProductImage(
                              productId: product.id,
                              imageUrl: product.imageUrl,
                              padding: veryCompact ? 8.0 : 12.0,
                              isHovered: _isHovering,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(13),
                              ),
                            ),
                          ),
                          // Top-left discount, featured, and animated 3D View glass badge
                          Positioned(
                            left: 7,
                            top: 7,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (discount != null && discount > 0)
                                  _buildBadge(
                                    '-$discount%',
                                    colors.error,
                                    Colors.white,
                                  ),
                                if (product.isFeatured) ...[
                                  const SizedBox(height: 4),
                                  _buildBadge(
                                    'FEATURED',
                                    primary,
                                    Colors.white,
                                  ),
                                ],
                                ValueListenableBuilder<Set<int>>(
                                  valueListenable: Catalog3D.ids,
                                  builder: (context, ids, _) {
                                    if (!ids.contains(product.id)) {
                                      return const SizedBox.shrink();
                                    }
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 3.5,
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [
                                              Color(0xF01E88E5),
                                              Color(0xF000ACC1),
                                            ],
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.35),
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x331E88E5),
                                              blurRadius: 4,
                                              offset: Offset(0, 1.5),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.view_in_ar_rounded,
                                              color: Colors.white,
                                              size: 11,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              veryCompact ? '3D' : '3D View',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 0.3,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          // Top-right Wishlist + Compare + Admin Edit/Delete actions
                          Positioned(
                            top: 5,
                            right: 5,
                            child: Consumer<ShopStateProvider>(
                              builder: (context, shopState, _) {
                                final wished =
                                    shopState.isWishlisted(product.id);
                                final comparing =
                                    shopState.isComparing(product.id);
                                return Column(
                                  children: [
                                    _circleIconBtn(
                                      colors: colors,
                                      tooltip: wished
                                          ? 'Remove ${product.name} from Wishlist'
                                          : 'Save ${product.name} to Wishlist',
                                      toggled: wished,
                                      icon: wished
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      iconColor: wished
                                          ? Colors.redAccent
                                          : colors.onSurfaceVariant,
                                      onTap: () {
                                        shopState.toggleWishlist(product);
                                        CustomToast.show(
                                          context,
                                          wished
                                              ? 'Removed from wishlist'
                                              : 'Saved to wishlist',
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 4),
                                    _circleIconBtn(
                                      colors: colors,
                                      tooltip: comparing
                                          ? 'Comparing ${product.name} (tap to toggle)'
                                          : 'Compare ${product.name} side-by-side',
                                      toggled: comparing,
                                      icon: Icons.compare_arrows_rounded,
                                      iconColor: comparing
                                          ? const Color(0xFF00ACC1)
                                          : colors.onSurfaceVariant,
                                      onTap: () {
                                        final msg =
                                            shopState.toggleCompare(product);
                                        ScaffoldMessenger.of(context)
                                          ..hideCurrentSnackBar()
                                          ..showSnackBar(
                                            SnackBar(
                                              content: Text(msg),
                                              duration:
                                                  const Duration(seconds: 3),
                                              behavior:
                                                  SnackBarBehavior.floating,
                                              action: shopState
                                                      .compareList.isNotEmpty
                                                  ? SnackBarAction(
                                                      label: 'COMPARE NOW',
                                                      textColor:
                                                          Colors.cyanAccent,
                                                      onPressed: () =>
                                                          showProductComparisonSheet(
                                                        context,
                                                      ),
                                                    )
                                                  : null,
                                            ),
                                          );
                                      },
                                    ),
                                    if (isAdmin) ...[
                                      const SizedBox(height: 4),
                                      _circleIconBtn(
                                        colors: colors,
                                        tooltip: 'Edit Product in Admin Studio',
                                        icon: Icons.edit_outlined,
                                        iconColor: primary,
                                        onTap: () => context.push(
                                          '/admin?editId=${product.id}',
                                        ),
                                      ),
                                      if (product.id != 144) ...[
                                        const SizedBox(height: 4),
                                        _circleIconBtn(
                                          colors: colors,
                                          tooltip: 'Delete Product',
                                          icon: Icons.delete_outline_rounded,
                                          iconColor: Colors.redAccent,
                                          isLoading: _isDeleting,
                                          onTap: _isDeleting
                                              ? null
                                              : _deleteProduct,
                                        ),
                                      ],
                                    ],
                                  ],
                                );
                              },
                            ),
                          ),

                          // Low / Out of stock indicator strip at bottom of image
                          if (outOfStock || lowStock)
                            Positioned(
                              left: 7,
                              bottom: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: (outOfStock
                                          ? colors.error
                                          : const Color(0xFFD97706))
                                      .withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  outOfStock
                                      ? 'Out of Stock'
                                      : 'Only ${product.stock} Left',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Product Info & Add to Cart
                    Padding(
                      padding: EdgeInsets.all(veryCompact ? 5 : 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product.category.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: veryCompact ? 8 : 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            product.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: veryCompact ? 10 : 12,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Color(0xFFFFB300),
                                size: 13,
                              ),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  '${product.rating} (${product.reviews})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: veryCompact ? 9 : 10,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          if (hasDiscount)
                            Text(
                              currency.format(product.originalPrice!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: veryCompact ? 9 : 10,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          Text(
                            currency.format(product.price),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: primary,
                              fontSize: veryCompact ? 12 : 14.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: double.infinity,
                            height: compact ? 29 : 32,
                            child: ElevatedButton(
                              onPressed: outOfStock ? null : _addToCart,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    outOfStock
                                        ? Icons.block_rounded
                                        : Icons.add_shopping_cart_rounded,
                                    size: veryCompact ? 12 : 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      outOfStock
                                          ? 'SOLD OUT'
                                          : (veryCompact
                                              ? 'ADD'
                                              : 'ADD TO CART'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: veryCompact ? 8.5 : 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
        ),
      ),
    );
      },
    );
  }

  Widget _circleIconBtn({
    required ColorScheme colors,
    required String tooltip,
    required IconData icon,
    required Color iconColor,
    VoidCallback? onTap,
    bool isLoading = false,
    bool? toggled,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      toggled: toggled,
      enabled: onTap != null && !isLoading,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: colors.surface.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: isLoading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, color: iconColor, size: 15.5),
            ),
          ),
        ),
      ),
    );
  }
}
