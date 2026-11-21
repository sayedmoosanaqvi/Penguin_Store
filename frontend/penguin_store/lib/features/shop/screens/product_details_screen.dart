import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/product_card.dart';
import 'package:penguin_store/features/shop/widgets/product_comparison_sheet.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class _VariantOption {
  final String label;
  final String subtitle;
  final double priceDelta;

  const _VariantOption({
    required this.label,
    required this.subtitle,
    required this.priceDelta,
  });
}

class _AddOnOption {
  final String id;
  final String title;
  final String subtitle;
  final double price;
  final IconData icon;

  const _AddOnOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.icon,
  });
}

class _BulkPriceTier {
  final int minQty;
  final int? maxQty;
  final String label;
  final double discountPercent;

  const _BulkPriceTier({
    required this.minQty,
    this.maxQty,
    required this.label,
    required this.discountPercent,
  });

  bool matches(int qty) {
    if (qty < minQty) return false;
    if (maxQty != null && qty > maxQty!) return false;
    return true;
  }

  String get rangeText =>
      maxQty == null ? '$minQty+ units' : '$minQty–$maxQty units';
}

class ProductDetailScreen extends StatefulWidget {
  final int? productId;
  final Product? product;
  final String? heroTag;

  const ProductDetailScreen({
    super.key,
    this.productId,
    this.product,
    this.heroTag,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final ProductService _productService = ProductService();
  final CommerceService _commerceService = CommerceService();
  final Premium3DService _premium3DService = Premium3DService();
  final Showcase3DService _showcase3DService = Showcase3DService();
  final TextEditingController _reviewTitleController = TextEditingController();
  final TextEditingController _reviewCommentController =
      TextEditingController();

  Product? _product;
  bool _isLoading = true;
  bool _isReviewsLoading = true;
  bool _isRecommendationsLoading = true;
  bool _isSubmittingReview = false;

  // 3D state
  bool _has3D = false;
  List<Product3DModel> _models3D = const [];
  String? _signed3DUrl;
  bool _isLoading3DUrl = false;
  bool _showInline3DViewer = false;

  // Dynamic Pricing, Variants, Add-ons & B2B Wholesale state
  String? _selectedVariant;
  final Set<String> _selectedAddOnIds = <String>{};
  int _quantity = 1;
  bool _isB2BMode = false;

  int _selectedRating = 5;
  List<ProductReviewModel> _reviews = [];
  double _averageRating = 0;
  double _weightedTrustRating = 0;
  bool _verifiedBuyersOnly = false;
  ProductReviewInsightsModel? _aiReviewInsights;
  bool _isLoadingAiInsights = false;
  List<Product> _recommendedProducts = [];

  static const List<_AddOnOption> _availableAddOns = [
    _AddOnOption(
      id: 'gift_wrap',
      title: 'Gift Wrapping',
      subtitle: 'Luxury Arctic gift box, satin ribbon & custom card',
      price: 9.99,
      icon: Icons.card_giftcard_rounded,
    ),
    _AddOnOption(
      id: 'extended_warranty',
      title: 'Extended 2-Year Warranty',
      subtitle: 'Penguin Care+ accidental damage & instant replacement',
      price: 29.99,
      icon: Icons.verified_user_rounded,
    ),
    _AddOnOption(
      id: 'express_handling',
      title: 'Priority Express Handling',
      subtitle: 'Same-day warehouse dispatch & insured air courier',
      price: 14.50,
      icon: Icons.rocket_launch_rounded,
    ),
  ];

  static const List<_BulkPriceTier> _bulkTiers = [
    _BulkPriceTier(
      minQty: 1,
      maxQty: 9,
      label: 'Standard Retail',
      discountPercent: 0,
    ),
    _BulkPriceTier(
      minQty: 10,
      maxQty: 49,
      label: 'Corporate Wholesale',
      discountPercent: 12,
    ),
    _BulkPriceTier(
      minQty: 50,
      maxQty: null,
      label: 'Enterprise Distributor',
      discountPercent: 22,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _product = widget.product;
    if (_product != null) {
      _isLoading = false;
      final options = _variantOptionsForCategory(_product!.category);
      _selectedVariant = options.first.label;
      _has3D = Catalog3D.has(_product!.id);
    }
    _loadData();
  }

  @override
  void dispose() {
    _reviewTitleController.dispose();
    _reviewCommentController.dispose();
    super.dispose();
  }

  List<_VariantOption> _variantOptionsForCategory(String category) {
    final normalized = category.toLowerCase();
    if (normalized.contains('cloth') ||
        normalized.contains('fashion') ||
        normalized.contains('apparel') ||
        normalized.contains('wear') ||
        normalized.contains('jacket') ||
        normalized.contains('shoe') ||
        normalized.contains('foot')) {
      return const [
        _VariantOption(
          label: 'S — Standard Fit',
          subtitle: 'Chest 36-38" • Regular Arctic Cut',
          priceDelta: 0.0,
        ),
        _VariantOption(
          label: 'M — Standard Fit',
          subtitle: 'Chest 39-41" • Regular Arctic Cut',
          priceDelta: 0.0,
        ),
        _VariantOption(
          label: 'L — Standard Fit',
          subtitle: 'Chest 42-44" • Regular Arctic Cut',
          priceDelta: 0.0,
        ),
        _VariantOption(
          label: 'XL — Tailored Fit',
          subtitle: 'Reinforced seams & extended thermal lining',
          priceDelta: 8.0,
        ),
        _VariantOption(
          label: 'Pro Custom Fit',
          subtitle: 'Bespoke sizing + water-repellent nano-coating',
          priceDelta: 18.0,
        ),
      ];
    }
    return const [
      _VariantOption(
        label: 'Standard Edition',
        subtitle: 'Factory calibrated core configuration',
        priceDelta: 0.0,
      ),
      _VariantOption(
        label: 'Pro Edition',
        subtitle: 'Enhanced performance kit + premium accessories',
        priceDelta: 24.0,
      ),
      _VariantOption(
        label: 'Collector Studio Edition',
        subtitle: 'Limited serialized finish + hard-shell travel case',
        priceDelta: 45.0,
      ),
    ];
  }

  _VariantOption _activeVariantOption(Product product) {
    final options = _variantOptionsForCategory(product.category);
    return options.firstWhere(
      (o) => o.label == _selectedVariant,
      orElse: () => options.first,
    );
  }

  _BulkPriceTier get _activeBulkTier {
    for (final tier in _bulkTiers) {
      if (tier.matches(_quantity)) return tier;
    }
    return _bulkTiers.first;
  }

  double _computeAddOnsUnitDelta() {
    double sum = 0.0;
    for (final addon in _availableAddOns) {
      if (_selectedAddOnIds.contains(addon.id)) {
        sum += addon.price;
      }
    }
    return sum;
  }

  List<String> _selectedAddOnLabels() {
    final currency = context.read<CurrencyProvider>();
    return _availableAddOns
        .where((a) => _selectedAddOnIds.contains(a.id))
        .map((a) => '${a.title} (+${currency.format(a.price)})')
        .toList();
  }

  double _computeEffectiveUnitPrice(Product product) {
    final variantDelta = _activeVariantOption(product).priceDelta;
    final basePlusVariant = product.price + variantDelta;
    final discountFactor = 1.0 - (_activeBulkTier.discountPercent / 100.0);
    final discountedUnit = basePlusVariant * discountFactor;
    return discountedUnit + _computeAddOnsUnitDelta();
  }

  double _computeTotalSavings(Product product) {
    final variantDelta = _activeVariantOption(product).priceDelta;
    final basePlusVariant = product.price + variantDelta;
    final perUnitSavings =
        basePlusVariant * (_activeBulkTier.discountPercent / 100.0);
    return perUnitSavings * _quantity;
  }

  Future<void> _loadData() async {
    final int? targetId = widget.productId ?? _product?.id;
    if (targetId == null || targetId <= 0) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (_product == null) {
      try {
        final fetchedProduct = await _productService.fetchProductById(targetId);
        if (!mounted) return;
        final options = _variantOptionsForCategory(
          fetchedProduct?.category ?? 'General',
        );
        setState(() {
          _product = fetchedProduct;
          _selectedVariant ??= options.first.label;
          _has3D = Catalog3D.has(targetId);
          _isLoading = false;
        });
      } catch (_) {
        if (mounted) setState(() => _isLoading = false);
      }
    }

    if (_product == null || !mounted) return;
    context.read<ShopStateProvider>().recordViewed(_product!);

    await Future.wait([
      _check3DAvailability(_product!.id),
      _loadReviews(_product!.id),
      _loadAiInsights(_product!.id),
      _loadRecommendations(_product!),
    ]);
  }

  Future<void> _check3DAvailability(int productId) async {
    try {
      final avail = await _premium3DService.getAvailability(productId);
      if (!mounted) return;
      setState(() {
        _has3D = avail.has3D || Catalog3D.has(productId);
        _models3D = avail.models;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _has3D = Catalog3D.has(productId));
    }
  }

  Future<void> _launch3DViewer(Product product, {bool inline = false}) async {
    if (_models3D.isEmpty) {
      await _check3DAvailability(product.id);
    }
    if (!mounted) return;
    final firstModel = _models3D.isNotEmpty ? _models3D.first : null;
    if (firstModel == null) {
      context.push('/showcase-3d');
      return;
    }

    setState(() => _isLoading3DUrl = true);
    try {
      final url =
          _signed3DUrl ??
          await _showcase3DService.fetchModelUrl(product.id, firstModel.id);
      if (!mounted) return;
      setState(() {
        _signed3DUrl = url;
        _isLoading3DUrl = false;
        if (inline) {
          _showInline3DViewer = !_showInline3DViewer;
        }
      });

      if (!inline) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Product3DViewerScreen(
              productName: product.name,
              modelUrl: url,
              posterUrl: product.imageUrl,
              productId: product.id,
              models: _models3D,
              currentModelId: firstModel.id,
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading3DUrl = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('3D Twin loading notice: $e')),
      );
    }
  }

  Future<void> _loadReviews(int productId) async {
    setState(() => _isReviewsLoading = true);
    try {
      final bundle = await _commerceService.fetchReviews(productId);
      if (!mounted) return;
      setState(() {
        _averageRating = bundle.averageRating > 0
            ? bundle.averageRating
            : (_product?.rating ?? 4.8);
        _weightedTrustRating = bundle.trustWeightedRating > 0
            ? bundle.trustWeightedRating
            : _averageRating;
        _reviews = bundle.reviews;
        _isReviewsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isReviewsLoading = false);
    }
  }

  Future<void> _loadAiInsights(int productId) async {
    setState(() => _isLoadingAiInsights = true);
    try {
      final insights = await _commerceService.fetchReviewInsights(productId);
      if (!mounted) return;
      setState(() {
        _aiReviewInsights = insights;
        if (insights.trustWeightedRating > 0) {
          _weightedTrustRating = insights.trustWeightedRating;
        }
        _isLoadingAiInsights = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingAiInsights = false);
    }
  }

  Future<void> _loadRecommendations(Product current) async {
    setState(() => _isRecommendationsLoading = true);
    try {
      final allProducts = await _productService.fetchProducts();
      if (!mounted) return;

      final sameCategory = allProducts
          .where((p) => p.id != current.id && p.category == current.category)
          .take(6)
          .toList();

      if (sameCategory.length < 6) {
        final fallback = allProducts
            .where(
              (p) =>
                  p.id != current.id && !sameCategory.any((s) => s.id == p.id),
            )
            .take(6 - sameCategory.length);
        sameCategory.addAll(fallback);
      }

      setState(() {
        _recommendedProducts = sameCategory;
        _isRecommendationsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isRecommendationsLoading = false);
    }
  }

  Future<void> _submitReview() async {
    final product = _product;
    if (product == null) return;

    final comment = _reviewCommentController.text.trim();
    if (comment.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please write at least 3 characters for your review.'),
        ),
      );
      return;
    }

    setState(() => _isSubmittingReview = true);
    try {
      await _commerceService.submitReview(
        productId: product.id,
        rating: _selectedRating,
        title: _reviewTitleController.text.trim(),
        comment: comment,
      );
      if (!mounted) return;
      setState(() => _isSubmittingReview = false);
      _reviewTitleController.clear();
      _reviewCommentController.clear();
      await Future.wait([
        _loadReviews(product.id),
        _loadAiInsights(product.id),
      ]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Review analyzed by AI Trust Engine & published!'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmittingReview = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _confirmAndDeleteProduct(Product product) async {
    if (product.id == 144) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Product #144 is protected for 3D testing and cannot be deleted.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product?'),
        content: Text(
          'Are you sure you want to permanently remove "${product.name}" (#${product.id})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final ok = await _productService.deleteProduct(product.id);
    if (!mounted) return;

    if (ok) {
      await context.read<ProductProvider>().invalidateAllAndRefresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "${product.name}".')),
      );
      context.go('/');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to delete product. Check admin permissions.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _openRfqModal(Product product) async {
    final auth = context.read<AuthProvider>();
    final currency = context.read<CurrencyProvider>();
    final companyController = TextEditingController();
    final nameController = TextEditingController(
      text: auth.userEmail?.split('@').first ?? 'Enterprise Procurement',
    );
    final emailController = TextEditingController(
      text: auth.userEmail ?? 'procurement@enterprise.com',
    );
    final qtyController = TextEditingController(
      text: (_quantity >= 10 ? _quantity : 50).toString(),
    );
    final targetPriceController = TextEditingController(
      text: (product.price * 0.78).toStringAsFixed(2),
    );
    final deadlineController = TextEditingController(text: 'Within 14 Days');
    final notesController = TextEditingController();
    bool isSubmitting = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final colors = Theme.of(sheetContext).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.request_quote_rounded,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Request Bulk Quotation (B2B RFQ)',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: colors.onSurface,
                                ),
                              ),
                              Text(
                                'Direct factory pricing & custom OEM terms for ${product.name}',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest.withValues(
                          alpha: 0.45,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.verified_rounded,
                            size: 18,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Standard Unit Price: ${currency.format(product.price)} • MOQ for Custom RFQ: 5+ units • Avg. Quote Turnaround < 2 hrs',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: qtyController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Quantity (MOQ 5+)',
                              prefixIcon: const Icon(
                                Icons.inventory_2_outlined,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: targetPriceController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Target Unit Price (USD)',
                              prefixIcon: const Icon(
                                Icons.attach_money_rounded,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: companyController,
                            decoration: InputDecoration(
                              labelText: 'Company / Organization',
                              hintText: 'e.g. Arctic Retail Group Ltd.',
                              prefixIcon: const Icon(Icons.business_rounded),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: deadlineController,
                            decoration: InputDecoration(
                              labelText: 'Delivery Timeline',
                              hintText: 'e.g. Within 14 Days',
                              prefixIcon: const Icon(
                                Icons.event_available_rounded,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              labelText: 'Contact Person Name',
                              prefixIcon: const Icon(Icons.person_outline),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: emailController,
                            decoration: InputDecoration(
                              labelText: 'Procurement Email',
                              prefixIcon: const Icon(Icons.email_outlined),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText:
                            'Customization, Packaging, or Spec Requirements',
                        hintText:
                            'Describe custom logo engraving, bulk pallet packaging, or destination port...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: isSubmitting
                            ? null
                            : () async {
                                final qty =
                                    int.tryParse(qtyController.text.trim()) ??
                                    0;
                                if (qty < 5) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Minimum RFQ quantity is 5 units.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                setSheetState(() => isSubmitting = true);
                                try {
                                  final targetUsd =
                                      double.tryParse(
                                        targetPriceController.text.trim(),
                                      ) ??
                                      (product.price * 0.8);
                                  final result = await _commerceService
                                      .submitRfq(
                                        productId: product.id,
                                        productName: product.name,
                                        customerEmail:
                                            emailController.text.trim().isEmpty
                                            ? 'buyer@penguinstore.com'
                                            : emailController.text.trim(),
                                        customerName:
                                            nameController.text.trim().isEmpty
                                            ? 'Enterprise Buyer'
                                            : nameController.text.trim(),
                                        companyName:
                                            companyController.text
                                                .trim()
                                                .isEmpty
                                            ? 'Verified B2B Buyer'
                                            : companyController.text.trim(),
                                        quantity: qty,
                                        targetUnitPrice: targetUsd,
                                        customizationNotes: notesController.text
                                            .trim(),
                                        deliveryDeadline: deadlineController
                                            .text
                                            .trim(),
                                      );
                                  if (!sheetContext.mounted || !mounted) return;
                                  Navigator.of(sheetContext).pop();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'RFQ #${result['id'] ?? 'NEW'} submitted for $qty units of ${product.name}!',
                                      ),
                                      action: SnackBarAction(
                                        label: 'VIEW RFQs',
                                        onPressed: () =>
                                            context.push('/orders'),
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  setSheetState(() => isSubmitting = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('RFQ submission error: $e'),
                                    ),
                                  );
                                }
                              },
                        icon: isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(
                          isSubmitting
                              ? 'SUBMITTING RFQ...'
                              : 'SUBMIT OFFICIAL B2B RFQ',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currency = context.watch<CurrencyProvider>();
    final shopState = context.watch<ShopStateProvider>();

    if (_isLoading) {
      return Scaffold(
        backgroundColor: colors.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_product == null) {
      return Scaffold(
        backgroundColor: colors.surface,
        appBar: AppBar(),
        body: Center(
          child: Text(
            'Product not found',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
        ),
      );
    }

    final product = _product!;
    final isWishlisted = shopState.isWishlisted(product.id);
    final isComparing = shopState.isComparing(product.id);
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final has3D = _has3D || Catalog3D.has(product.id);

    final effectiveUnitPrice = _computeEffectiveUnitPrice(product);
    final totalOrderPrice = effectiveUnitPrice * _quantity;
    final totalSavings = _computeTotalSavings(product);
    final activeVariant = _activeVariantOption(product);
    final isOutOfStock = product.stock <= 0;

    return Scaffold(
      backgroundColor: colors.surface,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/ctrlx'),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
        label: Text(
          'Ask CTRL-X AI',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 420,
            pinned: true,
            backgroundColor: colors.surface,
            leading: Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: colors.surface.withValues(alpha: 0.85),
                child: IconButton(
                  icon: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: colors.onSurface,
                  ),
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/'),
                ),
              ),
            ),
            actions: [
              if (isAdmin) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: CircleAvatar(
                    backgroundColor: colors.primaryContainer.withValues(
                      alpha: 0.92,
                    ),
                    child: IconButton(
                      tooltip: 'Edit Product (Admin)',
                      icon: Icon(
                        Icons.edit_rounded,
                        size: 18,
                        color: colors.onPrimaryContainer,
                      ),
                      onPressed: () =>
                          context.push('/admin?editId=${product.id}'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: CircleAvatar(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.9),
                    child: IconButton(
                      tooltip: 'Delete Product (Admin)',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      onPressed: () => _confirmAndDeleteProduct(product),
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: CircleAvatar(
                  backgroundColor: isComparing
                      ? colors.primary
                      : colors.surface.withValues(alpha: 0.85),
                  child: IconButton(
                    tooltip: isComparing
                        ? 'Comparing (Tap to view or remove)'
                        : 'Compare Product',
                    icon: Icon(
                      Icons.compare_arrows_rounded,
                      size: 18,
                      color: isComparing ? colors.onPrimary : colors.onSurface,
                    ),
                    onPressed: () {
                      context.read<ShopStateProvider>().toggleCompare(product);
                      if (context
                          .read<ShopStateProvider>()
                          .compareList
                          .isNotEmpty) {
                        showProductComparisonSheet(context);
                      }
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: CircleAvatar(
                  backgroundColor: colors.surface.withValues(alpha: 0.85),
                  child: IconButton(
                    tooltip: 'Toggle Wishlist',
                    icon: Icon(
                      isWishlisted
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 18,
                      color: isWishlisted ? Colors.redAccent : colors.onSurface,
                    ),
                    onPressed: () => context
                        .read<ShopStateProvider>()
                        .toggleWishlist(product),
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: widget.heroTag ?? 'product-${product.id}',
                    child: StudioProductImage(
                      productId: product.id,
                      imageUrl: product.imageUrl,
                      padding: 28.0,
                    ),
                  ),
                  if (has3D)
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FilledButton.icon(
                        onPressed: _isLoading3DUrl
                            ? null
                            : () => _launch3DViewer(product),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0B132B),
                          foregroundColor: const Color(0xFF00E5FF),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                            side: const BorderSide(color: Color(0xFF00E5FF)),
                          ),
                        ),
                        icon: _isLoading3DUrl
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00E5FF),
                                ),
                              )
                            : const Icon(Icons.view_in_ar_rounded, size: 18),
                        label: Text(
                          'Launch 3D Studio',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
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
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeaderSection(
                        context,
                        product,
                        effectiveUnitPrice: effectiveUnitPrice,
                        activeVariant: activeVariant,
                        currency: currency,
                        has3D: has3D,
                      ),
                      const SizedBox(height: 18),
                      _buildStockAndDeliveryStrip(context, product),
                      const SizedBox(height: 20),
                      if (has3D) ...[
                        _build3DInlineCard(context, product),
                        const SizedBox(height: 22),
                      ],
                      _buildB2BWholesaleSection(
                        context,
                        product,
                        effectiveUnitPrice: effectiveUnitPrice,
                        totalSavings: totalSavings,
                        currency: currency,
                      ),
                      const SizedBox(height: 22),
                      _buildVariantAndAddOnsSection(
                        context,
                        product,
                        currency: currency,
                      ),
                      const SizedBox(height: 22),
                      _buildQuantityAndSummaryCard(
                        context,
                        product,
                        effectiveUnitPrice: effectiveUnitPrice,
                        totalOrderPrice: totalOrderPrice,
                        totalSavings: totalSavings,
                        currency: currency,
                      ),
                      const SizedBox(height: 22),
                      _buildSupplierTrustAndPolicySection(context, product),
                      const SizedBox(height: 28),
                      Text(
                        'Product Overview',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        product.description,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          height: 1.6,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      _buildAiReviewInsightsCard(context),
                      const SizedBox(height: 20),
                      _buildReviewsSummaryCard(context, product),
                      const SizedBox(height: 28),
                      _buildRecommendationsSection(context, product),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(
                color: colors.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _openRfqModal(product),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.request_quote_outlined, size: 18),
                label: Text(
                  'Request Quote',
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: isOutOfStock
                        ? null
                        : () {
                            final addOns = _selectedAddOnLabels();
                            final mode = (_isB2BMode || _quantity >= 10)
                                ? 'B2B'
                                : 'B2C';
                            context.read<CartProvider>().addToCart(
                              product,
                              quantity: _quantity,
                              variant: _selectedVariant,
                              addOns: addOns,
                              unitPrice: effectiveUnitPrice,
                              pricingMode: mode,
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Added $_quantity × ${product.name} ($_selectedVariant${addOns.isEmpty ? '' : ' + ${addOns.length} add-on(s)'}) to cart!',
                                ),
                                action: SnackBarAction(
                                  label: 'VIEW CART',
                                  onPressed: () => context.push('/cart'),
                                ),
                              ),
                            );
                          },
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: Icon(
                      isOutOfStock
                          ? Icons.block_rounded
                          : Icons.shopping_bag_outlined,
                      size: 19,
                    ),
                    label: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: Text(
                        isOutOfStock
                            ? 'OUT OF STOCK'
                            : 'ADD TO CART • ${currency.format(totalOrderPrice)}',
                        key: ValueKey<String>(
                          'cta_${isOutOfStock}_${currency.code}_${totalOrderPrice.toStringAsFixed(2)}',
                        ),
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection(
    BuildContext context,
    Product product, {
    required double effectiveUnitPrice,
    required _VariantOption activeVariant,
    required CurrencyProvider currency,
    required bool has3D,
  }) {
    final colors = Theme.of(context).colorScheme;
    final hasCustomPrice = (effectiveUnitPrice - product.price).abs() > 0.005;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                product.category.toUpperCase(),
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
            if (has3D)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B132B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00E5FF)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.view_in_ar_rounded,
                      size: 13,
                      color: Color(0xFF00E5FF),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '3D STUDIO READY',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star_rounded, size: 15, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text(
                    '${_weightedTrustRating.toStringAsFixed(1)} AI Trust Rating (${_reviews.length})',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                product.name,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: colors.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1.0).animate(
                      animation,
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Text(
                    currency.format(effectiveUnitPrice),
                    key: ValueKey<String>(
                      'hdr_${currency.code}_${effectiveUnitPrice.toStringAsFixed(2)}',
                    ),
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: colors.primary,
                    ),
                  ),
                ),
                Text(
                  hasCustomPrice
                      ? 'Base: ${currency.format(product.price)} / unit'
                      : 'Per unit (${activeVariant.label})',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStockAndDeliveryStrip(BuildContext context, Product product) {
    final colors = Theme.of(context).colorScheme;
    final stock = product.stock;
    final bool isOut = stock <= 0;
    final bool isLow = stock > 0 && stock < 10;

    final Color badgeColor = isOut
        ? Colors.redAccent
        : (isLow ? Colors.amber.shade800 : const Color(0xFF10B981));
    final String stockText = isOut
        ? 'Out of Stock — Temporarily Unavailable'
        : (isLow
              ? 'Only $stock Left in Stock — Order Soon'
              : 'In Stock ($stock units ready for immediate dispatch)');

    final bool hasExpress = _selectedAddOnIds.contains('express_handling');
    final now = DateTime.now();
    final startDay = now.add(Duration(days: hasExpress ? 1 : 3));
    final endDay = now.add(Duration(days: hasExpress ? 2 : 5));
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final deliveryWindow =
        '${months[startDay.month - 1]} ${startDay.day} – ${months[endDay.month - 1]} ${endDay.day}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stockText,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: badgeColor,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_shipping_outlined,
                size: 17,
                color: colors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Est. Delivery: $deliveryWindow (${hasExpress ? 'Priority Air' : 'Standard Tracked'})',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _build3DInlineCard(BuildContext context, Product product) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primaryContainer.withValues(alpha: 0.45),
            colors.surfaceContainerHighest.withValues(alpha: 0.4),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.view_in_ar_rounded, color: colors.primary, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Interactive 3D Product Twin Available',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: colors.onSurface,
                      ),
                    ),
                    Text(
                      'Inspect every angle, material sheen, and dimension in real time.',
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _isLoading3DUrl
                    ? null
                    : () => _launch3DViewer(product, inline: true),
                icon: Icon(
                  _showInline3DViewer
                      ? Icons.expand_less_rounded
                      : Icons.threed_rotation_rounded,
                  size: 18,
                ),
                label: Text(_showInline3DViewer ? 'Hide 3D' : 'Inspect Here'),
              ),
            ],
          ),
          if (_showInline3DViewer && _signed3DUrl != null) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 360,
                child: Product3DViewerScreen(
                  productName: product.name,
                  modelUrl: _signed3DUrl!,
                  posterUrl: product.imageUrl,
                  productId: product.id,
                  models: _models3D,
                  currentModelId: _models3D.isNotEmpty
                      ? _models3D.first.id
                      : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildB2BWholesaleSection(
    BuildContext context,
    Product product, {
    required double effectiveUnitPrice,
    required double totalSavings,
    required CurrencyProvider currency,
  }) {
    final colors = Theme.of(context).colorScheme;
    final activeTier = _activeBulkTier;
    final variantDelta = _activeVariantOption(product).priceDelta;
    final baseWithVariant = product.price + variantDelta;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _isB2BMode || _quantity >= 10
              ? colors.primary.withValues(alpha: 0.6)
              : colors.outlineVariant.withValues(alpha: 0.45),
          width: _isB2BMode || _quantity >= 10 ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.workspace_premium_rounded,
                    color: colors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Retail (B2C) & Wholesale (B2B) Tiered Pricing',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                ],
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(
                    value: false,
                    label: Text('Retail (B2C)'),
                    icon: Icon(Icons.person_outline_rounded, size: 16),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text('Wholesale (B2B)'),
                    icon: Icon(Icons.domain_rounded, size: 16),
                  ),
                ],
                selected: {_isB2BMode},
                onSelectionChanged: (selection) {
                  final nextMode = selection.first;
                  setState(() {
                    _isB2BMode = nextMode;
                    if (_isB2BMode && _quantity < 10) {
                      _quantity = 10;
                    } else if (!_isB2BMode && _quantity >= 10) {
                      _quantity = 1;
                    }
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: _bulkTiers.map((tier) {
              final isSelected = activeTier.minQty == tier.minQty;
              final tierUnit =
                  baseWithVariant * (1.0 - tier.discountPercent / 100.0);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      setState(() {
                        _quantity = tier.minQty;
                        _isB2BMode = tier.minQty >= 10;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colors.primaryContainer.withValues(alpha: 0.65)
                            : colors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected
                              ? colors.primary
                              : colors.outlineVariant.withValues(alpha: 0.45),
                          width: isSelected ? 1.8 : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(
                                  tier.rangeText,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: isSelected
                                        ? colors.primary
                                        : colors.onSurface,
                                  ),
                                ),
                              ),
                              if (tier.discountPercent > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF10B981,
                                    ).withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '-${tier.discountPercent.toInt()}%',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: const Color(0xFF10B981),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            currency.format(tierUnit),
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: colors.onSurface,
                            ),
                          ),
                          Text(
                            tier.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          if (totalSavings > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.savings_rounded,
                    size: 18,
                    color: Color(0xFF10B981),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Active Tier: ${activeTier.label} (${activeTier.discountPercent.toInt()}% off) — You save ${currency.format(totalSavings)} on $_quantity units!',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF10B981),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVariantAndAddOnsSection(
    BuildContext context,
    Product product, {
    required CurrencyProvider currency,
  }) {
    final colors = Theme.of(context).colorScheme;
    final variants = _variantOptionsForCategory(product.category);
    final isApparel = variants.first.label.contains('Fit');

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isApparel ? 'Select Size & Fit Edition' : 'Select Product Edition',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Selecting an edition or add-on dynamically updates the unit price and carries into Cart & Checkout.',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: variants.map((option) {
              final selected = _selectedVariant == option.label;
              final deltaLabel = option.priceDelta <= 0
                  ? 'Included'
                  : '+${currency.format(option.priceDelta)}';
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _selectedVariant = option.label),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primaryContainer.withValues(alpha: 0.7)
                        : colors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected
                          ? colors.primary
                          : colors.outlineVariant.withValues(alpha: 0.5),
                      width: selected ? 1.8 : 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 16,
                            color: selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            option.label,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? colors.primary
                                  : colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              deltaLabel,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: selected
                                    ? colors.onPrimary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        option.subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),
          Divider(color: colors.outlineVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            'Optional Protection & Gift Add-Ons',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          ..._availableAddOns.map((addon) {
            final isChecked = _selectedAddOnIds.contains(addon.id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  setState(() {
                    if (isChecked) {
                      _selectedAddOnIds.remove(addon.id);
                    } else {
                      _selectedAddOnIds.add(addon.id);
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isChecked
                        ? colors.primaryContainer.withValues(alpha: 0.45)
                        : colors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isChecked
                          ? colors.primary
                          : colors.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: isChecked,
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedAddOnIds.add(addon.id);
                            } else {
                              _selectedAddOnIds.remove(addon.id);
                            }
                          });
                        },
                      ),
                      Icon(addon.icon, size: 20, color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              addon.title,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: colors.onSurface,
                              ),
                            ),
                            Text(
                              addon.subtitle,
                              style: GoogleFonts.inter(
                                fontSize: 11.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '+${currency.format(addon.price)}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildQuantityAndSummaryCard(
    BuildContext context,
    Product product, {
    required double effectiveUnitPrice,
    required double totalOrderPrice,
    required double totalSavings,
    required CurrencyProvider currency,
  }) {
    final colors = Theme.of(context).colorScheme;
    final maxStock = product.stock > 0 ? product.stock : 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 14,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Order Quantity:',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_rounded, size: 18),
                      onPressed: _quantity > 1
                          ? () => setState(() => _quantity--)
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '$_quantity',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      onPressed: _quantity < maxStock
                          ? () => setState(() => _quantity++)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ActionChip(
                label: const Text('+10 Bulk'),
                onPressed: () {
                  setState(() {
                    _quantity = (_quantity + 10).clamp(1, 500);
                    if (_quantity >= 10) _isB2BMode = true;
                  });
                },
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Configured Total ($_quantity × ${currency.format(effectiveUnitPrice)})',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  currency.format(totalOrderPrice),
                  key: ValueKey<String>(
                    'tot_${currency.code}_${totalOrderPrice.toStringAsFixed(2)}',
                  ),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSupplierTrustAndPolicySection(
    BuildContext context,
    Product product,
  ) {
    final colors = Theme.of(context).colorScheme;
    final trustBadges = [
      (
        Icons.verified_rounded,
        'Verified Supplier',
        'Penguin Direct ISO-9001 Audited',
      ),
      (
        Icons.shield_rounded,
        'Trade Assurance & Escrow',
        '100% payment protection until delivery',
      ),
      (
        Icons.fact_check_rounded,
        'Quality Inspection Passed',
        'Pre-shipment 24-point QA check',
      ),
      (
        Icons.bolt_rounded,
        'Fast B2B Desk',
        'Avg. quotation response < 2 hrs',
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 12,
              children: trustBadges.map((b) {
                return SizedBox(
                  width: 235,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(b.$1, size: 18, color: colors.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.$2,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: colors.onSurface,
                              ),
                            ),
                            Text(
                              b.$3,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
          ExpansionTile(
            leading: Icon(
              Icons.assignment_return_outlined,
              color: colors.primary,
              size: 20,
            ),
            title: Text(
              '30-Day Arctic Return Policy & Commercial Warranty Details',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                '• Free 30-Day Returns: Return any item in its original studio packaging within 30 days for a full refund or instant replacement.\n'
                '• B2B Trade Assurance: Bulk orders and RFQs are covered against transit damage, late dispatch, and specification variance.\n'
                '• Promo Codes Available at Checkout: Use PENGUIN10 (10% off), WELCOME20 (\$20 off \$200+), or WHOLESALE15 (15% off \$250+ bulk orders).',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  height: 1.55,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAiReviewInsightsCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_isLoadingAiInsights) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final insights = _aiReviewInsights;
    if (insights == null) return const SizedBox.shrink();

    final summary = insights.verdict.isNotEmpty
        ? insights.verdict
        : 'AI Trust Engine analyzed verified buyer feedback for authenticity.';
    final pros = insights.pros;
    final cons = insights.cons;
    final aspects = insights.aspectSentimentBars;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_rounded, color: colors.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'AI Review Intelligence & Fake-Review Detection Engine',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Weighted Trust: ${_weightedTrustRating.toStringAsFixed(2)} ★',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            summary,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (pros.isNotEmpty || cons.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pros.isNotEmpty)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Verified Strengths',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...pros.map(
                          (p) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '✓ $p',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: colors.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (cons.isNotEmpty)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reported Trade-offs',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.amber.shade800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...cons.map(
                          (c) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '• $c',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: colors.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (aspects.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: aspects.entries.map((entry) {
                return Chip(
                  label: Text(
                    '${entry.key}: ${entry.value}% positive',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewsSummaryCard(BuildContext context, Product product) {
    final colors = Theme.of(context).colorScheme;
    final filteredReviews = _verifiedBuyersOnly
        ? _reviews
              .where((r) => !r.isFlaggedSuspicious && r.trustScore >= 70)
              .toList()
        : _reviews;
    final verifiedCount = _reviews
        .where((r) => r.verifiedPurchase || r.trustScore >= 75)
        .length;
    final flaggedCount = _reviews.where((r) => r.isFlaggedSuspicious).length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Customer Reviews (${_reviews.length}) • $verifiedCount High-Trust • $flaggedCount Flagged',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
              FilterChip(
                label: const Text('Verified High-Trust Only'),
                selected: _verifiedBuyersOnly,
                onSelected: (val) => setState(() => _verifiedBuyersOnly = val),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _reviewCommentController,
                  decoration: InputDecoration(
                    hintText: 'Share your experience with ${product.name}...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<int>(
                value: _selectedRating,
                items: [5, 4, 3, 2, 1]
                    .map(
                      (r) => DropdownMenuItem(value: r, child: Text('$r ★')),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedRating = v);
                },
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _isSubmittingReview ? null : _submitReview,
                child: Text(_isSubmittingReview ? 'Posting...' : 'Post'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isReviewsLoading)
            const Center(child: CircularProgressIndicator())
          else if (filteredReviews.isEmpty)
            Text(
              'No reviews match the current filter yet.',
              style: GoogleFonts.inter(color: colors.onSurfaceVariant),
            )
          else
            ...filteredReviews.take(8).map((r) {
              final trustScore = r.trustScore;
              final isSuspicious = r.isFlaggedSuspicious || trustScore < 45;
              final trustLabel = isSuspicious
                  ? 'Flagged Suspicious'
                  : (trustScore >= 80
                        ? 'Verified High-Trust'
                        : 'Likely Genuine');
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSuspicious
                        ? Colors.redAccent.withValues(alpha: 0.4)
                        : colors.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${r.author} • ${r.rating} ★',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: colors.onSurface,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: isSuspicious
                                ? Colors.redAccent.withValues(alpha: 0.15)
                                : const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$trustLabel (${trustScore.toStringAsFixed(0)}/100)',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: isSuspicious
                                  ? Colors.redAccent
                                  : const Color(0xFF10B981),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      r.comment,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildRecommendationsSection(BuildContext context, Product current) {
    final colors = Theme.of(context).colorScheme;
    if (_isRecommendationsLoading || _recommendedProducts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Similar Studio Picks',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 330,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _recommendedProducts.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final item = _recommendedProducts[index];
              return SizedBox(
                width: 220,
                child: ProductCard(
                  product: item,
                  onProductDeleted: () => _loadRecommendations(current),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
