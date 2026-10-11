import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/premium_interactive_card.dart';

import '../models/product_model.dart';
import '../providers/cart_provider.dart';
import '../services/product_service.dart';
import '../services/premium_3d_service.dart';

import 'premium_subscription_screen.dart';
import 'product_3d_viewer_screen.dart';

class ProductDetailScreen extends StatefulWidget {
  final Product? product;
  final int? productId;

  const ProductDetailScreen({super.key, this.product, this.productId});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final ProductService _productService = ProductService();
  final Premium3DService _premiumService = Premium3DService();

  late Future<Product?> _productFuture;

  Future<Product3DAvailability>? _availabilityFuture;
  int? _availabilityProductId;

  bool _opening3D = false;
  bool _deletingProduct = false;

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
      final endpoint = Uri.parse(
        '$_baseUrl/api/premium-3d/'
        'products/${product.id}/'
        'models/${model.id}/showcase',
      );

      final response = await http
          .get(endpoint, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 40));

      if (response.statusCode != 200) {
        String errorMessage = 'Unable to load the 3D showcase.';

        try {
          final decoded = jsonDecode(response.body);

          if (decoded is Map && decoded['detail'] is String) {
            errorMessage = decoded['detail'] as String;
          }
        } catch (_) {}

        throw Exception(errorMessage);
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map || decoded['model_url'] is! String) {
        throw Exception('Invalid 3D model response.');
      }

      final modelUrl = decoded['model_url'] as String;

      final parsedUrl = Uri.tryParse(modelUrl);

      if (parsedUrl == null ||
          parsedUrl.scheme != 'https' ||
          parsedUrl.host.isEmpty) {
        throw Exception('Invalid secure 3D model URL.');
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) {
            return Product3DViewerScreen(
              productName: product.name,
              modelUrl: modelUrl,
            );
          },
        ),
      );
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
            PremiumInteractiveCard(
              onTap: () {
                CustomToast.show(context, 'Added to favorites!');
              },
              child: Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colors.outline.withValues(alpha: 0.22),
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.favorite_border, color: colors.onSurface),
              ),
            ),

            const SizedBox(width: 16),

            Expanded(
              child: PremiumInteractiveCard(
                onTap: () {
                  context.read<CartProvider>().addToCart(product);

                  CustomToast.show(context, '${product.name} added to cart!');
                },
                child: Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withValues(alpha: 0.25),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Text(
                    'ADD TO CART',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      letterSpacing: 1,
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
                        tag: 'product-${product.id}',
                        child: Image.network(
                          product.imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
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

                          Text(
                            '\$${product.price.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.w900,
                              color: colors.primary,
                            ),
                          ),

                          const SizedBox(height: 26),

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

                          const SizedBox(height: 30),

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
}
