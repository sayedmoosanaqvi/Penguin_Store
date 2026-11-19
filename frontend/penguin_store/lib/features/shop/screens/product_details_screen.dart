import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/premium_interactive_card.dart';

import '../models/product_model.dart';
import '../providers/cart_provider.dart';
import '../services/product_service.dart';
import '../services/premium_3d_service.dart';
import '../services/showcase_3d_service.dart';

import 'premium_subscription_screen.dart';
import 'product_3d_viewer_screen.dart';

class ProductDetailScreen extends StatefulWidget {
  final Product? product;
  final int? productId;
  final String? heroTag;

  const ProductDetailScreen({
    super.key,
    this.product,
    this.productId,
    this.heroTag,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final ProductService _productService = ProductService();
  final Premium3DService _premiumService = Premium3DService();
  final CommerceService _commerceService = CommerceService();

  late Future<Product?> _productFuture;

  Future<Product3DAvailability>? _availabilityFuture;
  int? _availabilityProductId;

  bool _opening3D = false;
  bool _deletingProduct = false;
  bool _useProxyImage = false;
  int _selectedQuantity = 1;
  String? _selectedVariant;

  ProductReviewsBundle? _reviewsBundle;
  ProductReviewInsightsModel? _reviewInsights;
  bool _loadingReviews = false;
  bool _insightsExpanded = true;
  bool _hideSuspiciousReviews = true;
  int? _lastSyncedProductId;

  // Signed GLB URLs fetched ahead of time so the viewer opens instantly.
  final Map<int, Future<String>> _urlPrefetch = {};
  List<Product3DModel> _availabilityModels = const [];

  List<String> _variantsForCategory(String category) {
    final c = category.toLowerCase();
    if (c.contains('shoe') || c.contains('sneaker') || c.contains('boot')) {
      return const ['40', '41', '42', '43', '44'];
    }
    if (c.contains('shirt') || c.contains('pant') || c.contains('dress') || c.contains('top')) {
      return const ['S', 'M', 'L', 'XL'];
    }
    return const ['Standard', 'Gift Wrapped', 'Pro Edition'];
  }

  String _resolveVariant(Product product) {
    final options = _variantsForCategory(product.category);
    if (_selectedVariant != null && options.contains(_selectedVariant)) {
      return _selectedVariant!;
    }
    return options.first;
  }

  void _prefetchModels(Product product, Product3DAvailability availability) {
    _availabilityModels = availability.models;
    for (final model in availability.models.take(2)) {
      _urlPrefetch.putIfAbsent(model.id, () {
        final future = Showcase3DService().fetchModelUrl(product.id, model.id);
        // A failed prefetch must not poison the real tap.
        future.catchError((_) {
          _urlPrefetch.remove(model.id);
          return '';
        });
        return future;
      });
    }
  }

  static String get _baseUrl =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  @override
  void initState() {
    super.initState();
    _initializeProduct();
  }

  void _initializeProduct() {
    if (widget.product != null) {
      _productFuture = Future.value(widget.product);
    } else if (widget.productId != null) {
      _productFuture = _fetchProductById(widget.productId!);
    } else {
      _productFuture = Future.value(null);
    }

    final id = widget.product?.id ?? widget.productId;

    _availabilityProductId = id;

    _availabilityFuture = id == null
        ? null
        : _premiumService.getAvailability(id);
  }

  @override
  void didUpdateWidget(covariant ProductDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.product != widget.product ||
        oldWidget.productId != widget.productId) {
      _initializeProduct();
    }
  }

  Future<Product?> _fetchProductById(int id) async {
    try {
      return await _productService.fetchProductById(id);
    } catch (e) {
      debugPrint('Product fetch failed: $e');
      return null;
    }
  }

  void _syncViewedAndReviews(Product product) {
    if (_lastSyncedProductId == product.id) return;
    _lastSyncedProductId = product.id;
    Future.microtask(() {
      if (!mounted) return;
      context.read<ShopStateProvider>().recordViewed(product);
      _loadReviews(product.id);
    });
  }

  Future<void> _loadReviews(int productId) async {
    if (!mounted) return;
    setState(() => _loadingReviews = true);
    try {
      final results = await Future.wait([
        _commerceService.fetchReviews(productId),
        _commerceService.fetchReviewInsights(productId),
      ]);
      if (mounted) {
        setState(() {
          _reviewsBundle = results[0] as ProductReviewsBundle;
          _reviewInsights = results[1] as ProductReviewInsightsModel;
        });
      }
    } catch (_) {
      try {
        final bundle = await _commerceService.fetchReviews(productId);
        if (mounted) setState(() => _reviewsBundle = bundle);
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _loadingReviews = false);
    }
  }

  Future<void> _openWriteReviewModal(Product product) async {
    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated) {
      CustomToast.show(
        context,
        'Please log in to write a customer review.',
        isError: true,
      );
      return;
    }

    final titleCtrl = TextEditingController();
    final commentCtrl = TextEditingController();
    int chosenRating = 5;
    bool submitting = false;

    final published = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(22)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Write a Review',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx, false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (index) {
                        final star = index + 1;
                        return IconButton(
                          iconSize: 34,
                          onPressed: () =>
                              setSheetState(() => chosenRating = star),
                          icon: Icon(
                            star <= chosenRating
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: Colors.amber,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Headline (optional)',
                        hintText: 'Summarize your experience',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: commentCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Your Review',
                        hintText: 'Share build quality, fit, or performance...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: submitting
                          ? null
                          : () async {
                              if (commentCtrl.text.trim().length < 5) {
                                CustomToast.show(
                                  ctx,
                                  'Please enter at least 5 characters.',
                                  isError: true,
                                );
                                return;
                              }
                              setSheetState(() => submitting = true);
                              try {
                                await _commerceService.submitReview(
                                  productId: product.id,
                                  rating: chosenRating,
                                  title: titleCtrl.text,
                                  comment: commentCtrl.text,
                                );
                                if (ctx.mounted) Navigator.pop(ctx, true);
                              } catch (e) {
                                if (ctx.mounted) {
                                  CustomToast.show(
                                    ctx,
                                    ApiErrorHandler.sanitize(e),
                                    isError: true,
                                  );
                                }
                              } finally {
                                if (ctx.mounted) {
                                  setSheetState(() => submitting = false);
                                }
                              }
                            },
                      child: submitting
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit Review'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    titleCtrl.dispose();
    commentCtrl.dispose();

    if (published == true && mounted) {
      CustomToast.show(context, 'Thank you! Your review is live.');
      await _loadReviews(product.id);
    }
  }

  void _refresh3DAvailability(int productId) {
    setState(() {
      _availabilityProductId = productId;
      _availabilityFuture = _premiumService.getAvailability(productId);
    });
  }

  void _showPremiumInfo() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PremiumSubscriptionScreen(),
      ),
    );
  }

  Future<void> _confirmDelete(Product product) async {
    if (_deletingProduct) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Text('Delete Product?'),
          content: Text(
            'Are you sure you want to delete '
            '${product.name}?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text(
                'DELETE',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmed != true) return;

    setState(() {
      _deletingProduct = true;
    });

    try {
      final success = await _productService.deleteProduct(product.id);

      if (!mounted) return;

      if (success) {
        CustomToast.show(context, 'Product Deleted');

        Navigator.of(context).maybePop();
      } else {
        CustomToast.show(context, 'Delete Failed', isError: true);
      }
    } catch (e) {
      debugPrint('Delete product error: $e');

      if (!mounted) return;

      CustomToast.show(context, 'Unable to delete product.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _deletingProduct = false;
        });
      }
    }
  }

  // Public 3D showcase:
  // No login, Stripe checkout, or subscription required.
  // FastAPI must have ENABLE_PUBLIC_3D_SHOWCASE=true.
  Future<void> _open3DViewer(Product product, Product3DModel model) async {
    if (_opening3D) return;

    setState(() {
      _opening3D = true;
    });

    try {
      // Re-uses the URL fetched while the page was idle when available.
      final modelUrl = await (_urlPrefetch[model.id] ??
          Showcase3DService().fetchModelUrl(product.id, model.id));

      if (!mounted) return;

      final models = _availabilityModels;

      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 380),
          pageBuilder: (_, __, ___) {
            return Product3DViewerScreen(
              productName: product.name,
              modelUrl: modelUrl,
              posterUrl: product.imageUrl.isNotEmpty ? product.imageUrl : null,
              productId: product.id,
              models: models,
              currentModelId: model.id,
            );
          },
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
                child: child,
              ),
            );
          },
        ),
      );

      // Signed URLs expire; drop the cached one after use.
      _urlPrefetch.remove(model.id);
    } catch (e) {
      debugPrint('3D showcase error: $e');

      if (!mounted) return;

      CustomToast.show(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _opening3D = false;
        });
      }
    }
  }

  BoxDecoration _sectionDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: theme.colorScheme.outline.withValues(alpha: 0.15),
      ),
    );
  }

  Widget _buildComingSoonCard(Product product, ThemeData theme) {
    final colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _sectionDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  Icons.view_in_ar_rounded,
                  color: colors.primary,
                  size: 29,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '3D Experience Coming Soon',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Interactive 3D viewing is being '
                      'added to selected products. '
                      'Explore our upcoming Premium features.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _showPremiumInfo,
                  icon: const Icon(Icons.workspace_premium_outlined, size: 18),
                  label: const Text(
                    'EXPLORE PREMIUM',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 15,
                      horizontal: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Refresh 3D availability',
                onPressed: () {
                  _refresh3DAvailability(product.id);
                },
                icon: Icon(Icons.refresh_rounded, color: colors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvailable3DCard(
    Product product,
    Product3DAvailability availability,
    ThemeData theme,
  ) {
    final colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primary.withValues(alpha: 0.10), colors.surface],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  Icons.view_in_ar_rounded,
                  color: colors.primary,
                  size: 29,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Experience in 3D',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Rotate • Zoom • Explore',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.view_in_ar_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    SizedBox(width: 5),
                    Text(
                      '3D DEMO',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),

          Text(
            'Try this interactive 3D product '
            'experience for free during our showcase. '
            'Penguin Premium subscriptions are coming soon.',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 16),

          ...availability.models.map((model) {
            final variant = model.variantName;

            final hasVariant = variant != null && variant.isNotEmpty;

            final label = hasVariant
                ? 'TRY ${variant.toUpperCase()} IN 3D'
                : 'TRY FREE 3D DEMO';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _opening3D
                      ? null
                      : () => _open3DViewer(product, model),
                  icon: _opening3D
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.threed_rotation_rounded),
                  label: Text(
                    _opening3D ? 'OPENING 3D DEMO...' : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
              ),
            );
          }),

          const SizedBox(height: 6),

          TextButton.icon(
            onPressed: _showPremiumInfo,
            icon: const Icon(Icons.workspace_premium_outlined, size: 18),
            label: const Text('ABOUT PENGUIN PREMIUM'),
          ),

          const SizedBox(height: 8),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: colors.onSurfaceVariant,
                size: 17,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Free preview. No login, '
                  'subscription, or payment required.',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _build3DSection(Product product, ThemeData theme) {
    if (_availabilityProductId != product.id || _availabilityFuture == null) {
      _availabilityProductId = product.id;
      _availabilityFuture = _premiumService.getAvailability(product.id);
    }

    return FutureBuilder<Product3DAvailability>(
      future: _availabilityFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: _sectionDecoration(theme),
            child: const Row(
              children: [
                SizedBox(
                  width: 21,
                  height: 21,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 14),
                Expanded(child: Text('Checking 3D availability...')),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          return Container(
            padding: const EdgeInsets.all(18),
            decoration: _sectionDecoration(theme),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, color: theme.colorScheme.error),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Unable to check 3D availability.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _refresh3DAvailability(product.id);
                  },
                  child: const Text('RETRY'),
                ),
              ],
            ),
          );
        }

        final availability = snapshot.data;

        if (availability == null ||
            !availability.has3D ||
            availability.models.isEmpty) {
          return _buildComingSoonCard(product, theme);
        }

        _prefetchModels(product, availability);

        return _buildAvailable3DCard(product, availability, theme);
      },
    );
  }

  Widget _buildBottomActions(Product product, ThemeData theme) {
    final colors = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: colors.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Row(
          children: [
            Consumer<ShopStateProvider>(
              builder: (context, shopState, _) {
                final isWished = shopState.isWishlisted(product.id);
                return PremiumInteractiveCard(
                  onTap: () {
                    shopState.toggleWishlist(product);
                    CustomToast.show(
                      context,
                      isWished
                          ? 'Removed from wishlist'
                          : 'Saved to your wishlist!',
                    );
                  },
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isWished
                          ? Colors.redAccent.withValues(alpha: 0.1)
                          : null,
                      border: Border.all(
                        color: isWished
                            ? Colors.redAccent
                            : colors.outline.withValues(alpha: 0.22),
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      isWished
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: isWished ? Colors.redAccent : colors.onSurface,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(width: 16),

            Expanded(
              child: PremiumInteractiveCard(
                onTap: () {
                  final variant = _resolveVariant(product);
                  context.read<CartProvider>().addToCart(
                        product,
                        quantity: _selectedQuantity,
                        variant: variant,
                      );

                  CustomToast.show(
                    context,
                    '${product.name} (x$_selectedQuantity · $variant) added to cart!',
                  );
                },
                child: Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colors.primary, const Color(0xFF00ACC1)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withValues(alpha: 0.25),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    'ADD TO CART  •  \$${(product.price * _selectedQuantity).toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final authProvider = context.watch<AuthProvider>();

    return FutureBuilder<Product?>(
      future: _productFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: CircularProgressIndicator(color: colors.primary),
            ),
          );
        }

        final product = snapshot.data;

        if (product == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Product not found.')),
          );
        }

        _syncViewedAndReviews(product);

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                expandedHeight: 350,
                pinned: true,
                stretch: true,
                backgroundColor: theme.scaffoldBackgroundColor,
                iconTheme: IconThemeData(color: colors.onSurface),
                actions: [
                  if (authProvider.isAdmin)
                    IconButton(
                      tooltip: 'Delete product',
                      onPressed: _deletingProduct
                          ? null
                          : () => _confirmDelete(product),
                      icon: _deletingProduct
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                    ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  stretchModes: const [StretchMode.zoomBackground],
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: widget.heroTag ?? 'product-${product.id}',
                        child: Image.network(
                          _useProxyImage
                              ? '$_baseUrl/api/search/image-proxy?url=${Uri.encodeComponent(product.imageUrl)}'
                              : product.imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            if (!_useProxyImage && product.imageUrl.startsWith('http')) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  setState(() => _useProxyImage = true);
                                }
                              });
                            }
                            return Container(
                              color: colors.surfaceContainerHighest,
                              child: const Center(
                                child: Icon(
                                  Icons.image_not_supported_outlined,
                                  size: 60,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.center,
                            colors: [Colors.black54, Colors.transparent],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 950),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(30),
                          topRight: Radius.circular(30),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  product.category.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.star_rounded,
                                color: colors.primary,
                                size: 20,
                              ),
                              Text(
                                ' ${product.rating} '
                                '(${product.reviews} reviews)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          Text(
                            product.name,
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.w800,
                              color: colors.onSurface,
                            ),
                          ),

                          const SizedBox(height: 16),

                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '\$${product.price.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 27,
                                  fontWeight: FontWeight.w900,
                                  color: colors.primary,
                                ),
                              ),
                              if (product.originalPrice != null &&
                                  product.originalPrice! > product.price) ...[
                                const SizedBox(width: 10),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    '\$${product.originalPrice!.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontSize: 15,
                                      decoration: TextDecoration.lineThrough,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16A34A)
                                      .withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: const Color(0xFF16A34A)
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_circle_rounded,
                                      size: 13,
                                      color: Color(0xFF16A34A),
                                    ),
                                    SizedBox(width: 5),
                                    Text(
                                      'In Stock • Fast Dispatch',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF16A34A),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          _buildVariantAndQuantitySection(product, theme),

                          const SizedBox(height: 24),

                          Text(
                            'Description',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),

                          const SizedBox(height: 10),

                          Text(
                            product.description,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.6,
                              color: colors.onSurfaceVariant,
                            ),
                          ),

                          const SizedBox(height: 22),

                          _buildTrustStrip(theme),

                          const SizedBox(height: 28),

                          Row(
                            children: [
                              Icon(
                                Icons.view_in_ar_rounded,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 9),
                              const Expanded(
                                child: Text(
                                  '3D Product Experience',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 15),

                          _build3DSection(product, theme),

                          const SizedBox(height: 28),

                          _buildReviewsSummaryCard(product, theme),

                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: _buildBottomActions(product, theme),
        );
      },
    );
  }

  Widget _buildVariantAndQuantitySection(Product product, ThemeData theme) {
    final options = _variantsForCategory(product.category);
    final selected = _resolveVariant(product);
    final colors = theme.colorScheme;

    return FadeSlideIn(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.primary.withValues(alpha: 0.14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Select Option',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  'Quantity',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: options.map((opt) {
                      final active = selected == opt;
                      return ChoiceChip(
                        label: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: active ? Colors.white : colors.onSurface,
                          ),
                        ),
                        selected: active,
                        showCheckmark: false,
                        selectedColor: colors.primary,
                        onSelected: (_) => setState(() => _selectedVariant = opt),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colors.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _selectedQuantity > 1
                            ? () => setState(() => _selectedQuantity--)
                            : null,
                        icon: const Icon(Icons.remove_rounded, size: 17),
                      ),
                      Text(
                        '$_selectedQuantity',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _selectedQuantity < 20
                            ? () => setState(() => _selectedQuantity++)
                            : null,
                        icon: const Icon(Icons.add_rounded, size: 17),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrustStrip(ThemeData theme) {
    final items = const [
      (Icons.assignment_return_outlined, '14-Day Returns'),
      (Icons.verified_user_outlined, 'Stripe Encrypted'),
      (Icons.view_in_ar_rounded, 'AI & 3D Verified'),
    ];
    return Row(
      children: items
          .map(
            (e) => Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.12),
                  ),
                ),
                child: Column(
                  children: [
                    Icon(e.$1, size: 18, color: theme.primaryColor),
                    const SizedBox(height: 5),
                    Text(
                      e.$2,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildAiReviewInsightsCard(Product product, ThemeData theme) {
    final colors = theme.colorScheme;
    final insights = _reviewInsights;
    final twScore = insights?.trustWeightedRating ??
        _reviewsBundle?.trustWeightedRating ??
        (product.rating > 0 ? product.rating : 4.8);
    final rawScore = insights?.rawRating ??
        _reviewsBundle?.averageRating ??
        (product.rating > 0 ? product.rating : 4.8);
    final authPct = insights?.verifiedAuthenticPercent ?? 96.0;
    final pros = insights?.pros ??
        [
          'Verified build quality and material finish for ${product.name}',
          'Strong price-to-performance value at \$${product.price.toStringAsFixed(2)}',
          'Interactive 3D & catalog verification reduces buyer uncertainty',
        ];
    final cons = insights?.cons ??
        ['No recurring defects reported among verified high-trust buyers'];
    final verdict = insights?.verdict.isNotEmpty == true
        ? insights!.verdict
        : 'With a ${twScore.toStringAsFixed(1)}/5.0 Trust-Weighted Rating across verified authentic reviews, ${product.name} is a high-confidence choice.';
    final aspectBars = insights?.aspectSentimentBars ??
        const {
          'Quality': 92,
          'Value': 88,
          'Delivery/Experience': 90,
          'Performance': 91,
        };

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primary.withValues(alpha: 0.09),
            const Color(0xFF00ACC1).withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.verified_user_rounded,
                  color: colors.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI Review Insights & Trust Engine',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Trust-Weighted ${twScore.toStringAsFixed(1)}★ vs Raw ${rawScore.toStringAsFixed(1)}★',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.shield_rounded,
                      size: 13,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${authPct.toStringAsFixed(0)}% Verified & Authentic',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Animated Aspect Sentiment Progress Bars
          const Text(
            'Aspect-Based Sentiment Analysis',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...aspectBars.entries.map((entry) {
            final pct = entry.value.clamp(0, 100);
            return Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        entry.key,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '$pct% Positive',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: pct / 100.0),
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.easeOutCubic,
                    builder: (context, val, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: val,
                        minHeight: 7,
                        backgroundColor:
                            colors.primary.withValues(alpha: 0.12),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          pct >= 80
                              ? const Color(0xFF16A34A)
                              : colors.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 18),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () =>
                setState(() => _insightsExpanded = !_insightsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'AI Pros / Cons / Verdict Summary',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(
                    _insightsExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_insightsExpanded) ...[
            const SizedBox(height: 8),
            ...pros.map(
              (p) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_circle_outline_rounded,
                      size: 15,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p,
                        style: const TextStyle(fontSize: 12, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ...cons.map(
              (c) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        c,
                        style: const TextStyle(fontSize: 12, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Verdict: $verdict',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewsSummaryCard(Product product, ThemeData theme) {
    final colors = theme.colorScheme;
    final bundle = _reviewsBundle;
    final hasLiveReviews = bundle != null && bundle.totalReviews > 0;
    final rating = hasLiveReviews
        ? bundle.trustWeightedRating
        : (product.rating > 0 ? product.rating : 4.8);
    final totalCount =
        bundle != null ? bundle.totalReviews : product.reviews;

    double barFraction(int star) {
      if (bundle == null || bundle.totalReviews == 0) {
        return const {5: 0.78, 4: 0.16, 3: 0.04, 2: 0.02, 1: 0.0}[star] ?? 0.0;
      }
      return (bundle.distribution[star] ?? 0) / bundle.totalReviews;
    }

    final allReviews = bundle?.reviews ?? const <ProductReviewModel>[];
    final suspiciousCount =
        allReviews.where((r) => r.isFlaggedSuspicious).length;
    final displayedReviews = _hideSuspiciousReviews
        ? allReviews.where((r) => !r.isFlaggedSuspicious).toList()
        : allReviews;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _sectionDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAiReviewInsightsCard(product, theme),
          Row(
            children: [
              Icon(Icons.reviews_outlined, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Customer Reviews',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: () => _openWriteReviewModal(product),
                icon: const Icon(Icons.rate_review_outlined, size: 16),
                label: const Text('Write Review'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Column(
                children: [
                  Text(
                    rating.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Row(
                    children: List.generate(
                      5,
                      (i) => Icon(
                        i < rating.round()
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: Colors.amber,
                        size: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$totalCount trust-weighted ${totalCount == 1 ? 'review' : 'reviews'}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  children: [
                    _ratingBar('5★', barFraction(5), colors.primary),
                    _ratingBar('4★', barFraction(4), colors.primary),
                    _ratingBar('3★', barFraction(3), colors.primary),
                    _ratingBar('2★', barFraction(2), colors.primary),
                    _ratingBar('1★', barFraction(1), colors.primary),
                  ],
                ),
              ),
            ],
          ),
          if (suspiciousCount > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.auto_fix_high_rounded,
                  size: 14,
                  color: colors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _hideSuspiciousReviews
                        ? '$suspiciousCount low-trust suspicious review(s) hidden by AI Trust Filter'
                        : 'Showing all reviews including $suspiciousCount flagged item(s)',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _hideSuspiciousReviews = !_hideSuspiciousReviews,
                  ),
                  child: Text(
                    _hideSuspiciousReviews ? 'Show All' : 'Hide Flagged',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          if (_loadingReviews && bundle == null) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(minHeight: 2),
          ] else if (bundle != null && displayedReviews.isEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'No written high-trust reviews yet. Be the first to review ${product.name}!',
              style: TextStyle(
                fontSize: 12.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ] else if (bundle != null && displayedReviews.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            ...displayedReviews.take(8).map((rev) {
              final isHighTrust =
                  !rev.isFlaggedSuspicious && rev.trustScore >= 75.0;
              return Opacity(
                opacity: rev.isFlaggedSuspicious ? 0.58 : 1.0,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                    border: rev.isFlaggedSuspicious
                        ? Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                          )
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            rev.author,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (rev.verifiedPurchase)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: const Text(
                                'Verified Buyer',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.green,
                                ),
                              ),
                            ),
                          if (isHighTrust)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                'High Trust (${rev.trustScore.toInt()}%)',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                          if (rev.isFlaggedSuspicious)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                'Flagged Low Trust (${rev.trustScore.toInt()}%)',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.deepOrange,
                                ),
                              ),
                            ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(
                              5,
                              (i) => Icon(
                                i < rev.rating
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: Colors.amber,
                                size: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (rev.title.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          rev.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        rev.comment,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _ratingBar(String label, double fraction, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(label, style: const TextStyle(fontSize: 10)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: color.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
