
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class ProductCard extends StatefulWidget {
  final Product product;
  final VoidCallback onProductDeleted;

  const ProductCard({
    super.key,
    required this.product,
    required this.onProductDeleted,
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
          productId: widget.product.id,
        ),
      ),
    );
  }

  void _addToCart() {
    context.read<CartProvider>().addToCart(widget.product);

    CustomToast.show(
      context,
      '${widget.product.name} added to cart!',
    );
  }

  Future<void> _deleteProduct() async {
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
      final success = await ProductService().deleteProduct(
        widget.product.id,
      );

      if (!mounted) return;

      if (success) {
        CustomToast.show(context, 'Product deleted!');
        widget.onProductDeleted();
      } else {
        CustomToast.show(
          context,
          'Failed to delete.',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(
          context,
          'Failed to delete: $e',
          isError: true,
        );
      }
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
        borderRadius: BorderRadius.circular(5),
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
    final isDark = theme.brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final product = widget.product;
    final primary = theme.primaryColor;

    final hasDiscount = product.originalPrice != null &&
        product.originalPrice! > product.price;

    final discount = product.discountPercent ??
        (hasDiscount
            ? ((product.originalPrice! - product.price) /
                    product.originalPrice! *
                    100)
                .round()
            : null);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 180;
        final veryCompact = constraints.maxWidth < 125;

        return MouseRegion(
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
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              onTap: _openProduct,
              borderRadius: BorderRadius.circular(11),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: _isHovering
                        ? primary
                        : theme.dividerColor.withOpacity(0.18),
                    width: _isHovering ? 1.4 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(
                        _isHovering ? 0.09 : 0.025,
                      ),
                      blurRadius: _isHovering ? 10 : 4,
                      offset: const Offset(0, 3),
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
                          Hero(
                            tag: 'product-${product.id}',
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              child: Image.network(
                                product.imageUrl,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stack) {
                                  return Container(
                                    color: isDark
                                        ? Colors.white.withOpacity(0.04)
                                        : Colors.grey.shade50,
                                    child: Center(
                                      child: Icon(
                                        Icons.image_not_supported_outlined,
                                        color: theme.colorScheme
                                            .onSurfaceVariant,
                                        size: 30,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (discount != null && discount > 0)
                                  _buildBadge(
                                    '-$discount%',
                                    theme.colorScheme.error,
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
                              ],
                            ),
                          ),
                          if (isAdmin)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Material(
                                color: theme.colorScheme.surface
                                    .withOpacity(0.94),
                                borderRadius: BorderRadius.circular(20),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: _isDeleting ? null : _deleteProduct,
                                  child: Padding(
                                    padding: const EdgeInsets.all(7),
                                    child: _isDeleting
                                        ? const SizedBox(
                                            width: 15,
                                            height: 15,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.delete_outline_rounded,
                                            color: Colors.redAccent,
                                            size: 17,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
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
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: veryCompact ? 8 : 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            product.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: veryCompact ? 10 : 12,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Color(0xFFFFB300),
                                size: 14,
                              ),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  '${product.rating} (${product.reviews})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: veryCompact ? 9 : 10,
                                    color: theme.colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (hasDiscount)
                            Text(
                              '\$${product.originalPrice!.toStringAsFixed(2)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: veryCompact ? 9 : 10,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          Text(
                            '\$${product.price.toStringAsFixed(2)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: primary,
                              fontSize: veryCompact ? 12 : 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 7),
                          SizedBox(
                            width: double.infinity,
                            height: compact ? 30 : 33,
                            child: ElevatedButton(
                              onPressed: _addToCart,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(7),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_shopping_cart_rounded,
                                    size: veryCompact ? 13 : 15,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      veryCompact ? 'ADD' : 'ADD TO CART',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: veryCompact ? 9 : 10,
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
        );
      },
    );
  }
}
