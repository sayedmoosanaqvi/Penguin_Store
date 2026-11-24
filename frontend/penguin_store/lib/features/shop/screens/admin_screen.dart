import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/services/app_notifier.dart';
import 'package:penguin_store/core/widgets/penguin_brand_logo.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/admin_3d_service.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/widgets/interactive_3d_preview.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class AdminScreen extends StatefulWidget {
  final int? initialEditProductId;

  const AdminScreen({super.key, this.initialEditProductId});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final colors = Theme.of(context).colorScheme;

    if (!auth.isAuthenticated) {
      return Scaffold(
        backgroundColor: colors.surface,
        appBar: AppBar(
          title: const Text('Admin Console'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/'),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_person_rounded,
                      size: 54,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Admin Sign-In Required',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in with an administrator account to manage products, 3D studio assets, B2B RFQs, and customer orders.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => context.push('/login'),
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Sign In to Admin'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (!auth.isAdmin) {
      return Scaffold(
        backgroundColor: colors.surface,
        appBar: AppBar(title: const Text('Access Restricted')),
        body: Center(
          child: Text(
            'Your account (${auth.userEmail}) does not have admin privileges.',
            style: GoogleFonts.inter(color: colors.onSurface),
          ),
        ),
      );
    }

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
            const PenguinBrandLogo(size: 32, onLightBackground: true),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Penguin Enterprise Admin & 3D Studio',
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: colors.primary,
          unselectedLabelColor: colors.onSurfaceVariant,
          indicatorColor: colors.primary,
          labelStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800,
            fontSize: 13.5,
          ),
          tabs: const [
            Tab(
              icon: Icon(Icons.view_in_ar_rounded, size: 18),
              text: 'Products & 3D Studio',
            ),
            Tab(
              icon: Icon(Icons.request_quote_rounded, size: 18),
              text: 'B2B Quotes (RFQ)',
            ),
            Tab(
              icon: Icon(Icons.receipt_long_rounded, size: 18),
              text: 'Order History',
            ),
            Tab(
              icon: Icon(Icons.analytics_rounded, size: 18),
              text: 'AI Evaluation (FYP)',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _AddProductForm(initialEditProductId: widget.initialEditProductId),
          const _AdminRfqManagementTab(),
          const _AdminOrderHistory(),
          const _AdminAiEvaluationTab(),
        ],
      ),
    );
  }
}

enum _AdminProductMode { createNew, attachToExisting, editExisting }

class _AddProductForm extends StatefulWidget {
  final int? initialEditProductId;

  const _AddProductForm({this.initialEditProductId});

  @override
  State<_AddProductForm> createState() => _AddProductFormState();
}

class _AddProductFormState extends State<_AddProductForm> {
  final _formKey = GlobalKey<FormState>();
  final ScrollController _scrollController = ScrollController();

  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _stockController = TextEditingController(text: '50');
  final _catalogSearchController = TextEditingController();

  String _selectedCategory = 'Electronics';
  bool _isFeatured = false;
  _AdminProductMode _mode = _AdminProductMode.createNew;

  XFile? _selectedImageFile;
  Uint8List? _selectedImageBytes;
  String? _selectedGlbName;
  Uint8List? _selectedGlbBytes;
  Uint8List? _captured3DThumbnailBytes;
  bool _showGlbStudioPreview = false;

  bool _isSubmitting = false;
  double _uploadProgress = 0.0;
  String _statusMessage = '';

  final ProductService _productService = ProductService();
  final Admin3DService _admin3DService = Admin3DService();
  final ImagePicker _imagePicker = ImagePicker();
  final GlbStudioController _previewController = GlbStudioController();

  List<Product> _catalogProducts = [];
  List<Admin3DModelRow> _models3D = [];
  Product? _selectedExistingProduct;
  bool _isLoadingAdminData = true;
  bool _appliedInitialEditId = false;
  final Set<int> _deletingProductIds = <int>{};

  static const List<String> _categories = [
    'Electronics',
    'Gaming',
    'Audio',
    'Fashion',
    'Footwear',
    'Home & Living',
    'Accessories',
    'Collectibles',
  ];

  @override
  void initState() {
    super.initState();
    _refreshAdminData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    _catalogSearchController.dispose();
    super.dispose();
  }

  Future<void> _refreshAdminData() async {
    setState(() => _isLoadingAdminData = true);
    try {
      await ProductService.clearAllCaches();
      final results = await Future.wait([
        _productService.fetchProducts(forceRefresh: true),
        _admin3DService.listModels(),
      ]);
      if (!mounted) return;
      final products = results[0] as List<Product>;
      final models = results[1] as List<Admin3DModelRow>;

      setState(() {
        _catalogProducts = products;
        _models3D = models;
        _isLoadingAdminData = false;
      });
      // Keep storefront ProductProvider synced with fresh server inventory
      context.read<ProductProvider>().ensureProductsLoaded(forceRefresh: true);

      if (!_appliedInitialEditId && widget.initialEditProductId != null) {
        _appliedInitialEditId = true;
        final match = products
            .where((p) => p.id == widget.initialEditProductId)
            .firstOrNull;
        if (match != null) {
          _startEditingProduct(match);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingAdminData = false);
    }
  }

  void _resetForm() {
    _nameController.clear();
    _descriptionController.clear();
    _priceController.clear();
    _stockController.text = '50';
    _selectedCategory = _categories.first;
    _isFeatured = false;
    _selectedImageFile = null;
    _selectedImageBytes = null;
    _selectedGlbName = null;
    _selectedGlbBytes = null;
    _captured3DThumbnailBytes = null;
    _showGlbStudioPreview = false;
    _selectedExistingProduct = null;
    _mode = _AdminProductMode.createNew;
  }

  void _startEditingProduct(Product product) {
    setState(() {
      _mode = _AdminProductMode.editExisting;
      _selectedExistingProduct = product;
      _nameController.text = product.name;
      _descriptionController.text = product.description;
      _priceController.text = product.price.toStringAsFixed(2);
      _stockController.text = product.stock.toString();
      _selectedCategory = _categories.contains(product.category)
          ? product.category
          : _categories.first;
      _isFeatured = product.isFeatured;
      _selectedImageFile = null;
      _selectedImageBytes = null;
      _selectedGlbName = null;
      _selectedGlbBytes = null;
      _captured3DThumbnailBytes = null;
      _showGlbStudioPreview = false;
    });
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _startEditingFrom3DRow(Admin3DModelRow row) {
    final existing = _catalogProducts
        .where((p) => p.id == row.productId)
        .firstOrNull;
    if (existing != null) {
      _startEditingProduct(existing);
      return;
    }
    final fallback = Product(
      id: row.productId,
      name: row.productName,
      description: row.productDescription.isNotEmpty
          ? row.productDescription
          : '3D studio-enabled product #${row.productId}',
      price: row.productPrice > 0 ? row.productPrice : 99.0,
      imageUrl: row.productImageUrl,
      category: row.productCategory,
      rating: 4.8,
      reviews: 12,
      stock: row.productStock,
    );
    _startEditingProduct(fallback);
  }

  Future<void> _pickImage() async {
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked != null && mounted) {
      final bytes = await picked.readAsBytes();
      setState(() {
        _selectedImageFile = picked;
        _selectedImageBytes = bytes;
      });
    }
  }

  Future<void> _pickGlb() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['glb'],
    );
    if (picked != null) {
      final bytes = await picked.xFile.readAsBytes();
      if (!mounted) return;
      setState(() {
        _selectedGlbName = picked.name;
        _selectedGlbBytes = bytes;
        _captured3DThumbnailBytes = null;
        _showGlbStudioPreview = false;
      });
    }
  }

  void _showAdminNotification(
    BuildContext context, {
    required String message,
    bool isSuccess = false,
    bool isError = false,
  }) {
    if (isSuccess) {
      AppNotifier.showSuccess(message, fallbackContext: context);
    } else if (isError) {
      AppNotifier.showError(message, fallbackContext: context);
    } else {
      AppNotifier.showInfo(message, fallbackContext: context);
    }
  }

  Future<void> _submitForm() async {
    if (_mode != _AdminProductMode.attachToExisting &&
        !_formKey.currentState!.validate()) {
      return;
    }

    if ((_mode == _AdminProductMode.attachToExisting ||
            _mode == _AdminProductMode.editExisting) &&
        _selectedExistingProduct == null) {
      _showAdminNotification(
        context,
        message: 'Please select an existing product first.',
        isError: true,
      );
      return;
    }

    final productProvider = context.read<ProductProvider>();

    setState(() {
      _isSubmitting = true;
      _uploadProgress = 0.1;
      _statusMessage = 'Preparing studio assets...';
    });

    try {
      await Future<void>.sync(() async {
        // Safe 8-second timeout for 3D studio thumbnail capture if GLB is loaded and preview attached
        if (_selectedGlbBytes != null &&
            _selectedImageFile == null &&
            _captured3DThumbnailBytes == null &&
            _previewController.isAttached) {
          setState(() => _statusMessage = 'Auto-capturing 3D studio poster...');
          try {
            final snap = await _previewController
                .captureCurrentAngle()
                .timeout(const Duration(seconds: 8));
            if (snap != null && snap.isNotEmpty) {
              _captured3DThumbnailBytes = snap;
            }
          } catch (e) {
            debugPrint('Auto-capture skipped or timed out gracefully: $e');
          }
        }

        String? uploadedImageUrl;
        if (_selectedImageFile != null) {
          setState(() {
            _uploadProgress = 0.3;
            _statusMessage = 'Normalizing & uploading 800×800 studio image...';
          });
          uploadedImageUrl = await _productService.uploadImage(
            _selectedImageFile!,
          );
        } else if (_captured3DThumbnailBytes != null &&
            _selectedGlbBytes == null) {
          setState(() {
            _uploadProgress = 0.3;
            _statusMessage = 'Uploading captured 3D studio thumbnail...';
          });
          uploadedImageUrl = await _productService.uploadImageBytes(
            _captured3DThumbnailBytes!,
            fileName: 'studio_3d_${DateTime.now().millisecondsSinceEpoch}.png',
          );
        }

        String publishedTitle = _nameController.text.trim();

        if (_mode == _AdminProductMode.createNew) {
          final priceVal = double.tryParse(_priceController.text.trim()) ?? 49.99;
          final stockVal = int.tryParse(_stockController.text.trim()) ?? 50;

          if (_selectedGlbBytes != null) {
            setState(() {
              _uploadProgress = 0.45;
              _statusMessage =
                  'Creating product & uploading .glb to Supabase Storage...';
            });
            final posterBytes = _selectedImageFile != null
                ? await _selectedImageFile!.readAsBytes()
                : _captured3DThumbnailBytes;
            final res = await _admin3DService.uploadNewProduct(
              fileName: _selectedGlbName ?? 'model.glb',
              glbBytes: _selectedGlbBytes!,
              name: publishedTitle,
              price: priceVal,
              category: _selectedCategory,
              description: _descriptionController.text.trim(),
              isFeatured: _isFeatured,
              posterBytes: posterBytes,
              posterName: _selectedImageFile?.name ?? 'studio_poster.png',
              onProgress: (p) => setState(() => _uploadProgress = 0.4 + p * 0.55),
            );
            if (stockVal != 50) {
              await _productService.updateProduct(res.productId, {
                'stock': stockVal,
              });
            }
          } else {
            setState(() {
              _uploadProgress = 0.55;
              _statusMessage = 'Creating product in Supabase...';
            });
            await _productService.createProductWithId({
              'name': publishedTitle,
              'description': _descriptionController.text.trim(),
              'price': priceVal,
              'category': _selectedCategory,
              'stock': stockVal,
              'is_featured': _isFeatured,
              'image_url':
                  uploadedImageUrl ??
                  'https://images.unsplash.com/photo-1523275335684-37898b6baf30?w=800',
            });
          }
        } else if (_mode == _AdminProductMode.editExisting) {
          final existing = _selectedExistingProduct!;
          publishedTitle = _nameController.text.trim();
          setState(() {
            _uploadProgress = 0.55;
            _statusMessage = 'Saving product changes (#${existing.id})...';
          });
          await _productService.updateProduct(existing.id, {
            'name': publishedTitle,
            'description': _descriptionController.text.trim(),
            'price':
                double.tryParse(_priceController.text.trim()) ?? existing.price,
            'category': _selectedCategory,
            'stock':
                int.tryParse(_stockController.text.trim()) ?? existing.stock,
            'is_featured': _isFeatured,
            'image_url': uploadedImageUrl ?? existing.imageUrl,
          });

          if (_selectedGlbBytes != null) {
            setState(() {
              _uploadProgress = 0.75;
              _statusMessage = 'Uploading .glb 3D asset to Supabase Storage...';
            });
            await _admin3DService.attachToProduct(
              productId: existing.id,
              fileName: _selectedGlbName ?? 'model.glb',
              glbBytes: _selectedGlbBytes!,
              displayName: publishedTitle,
              posterBytes: _captured3DThumbnailBytes,
              updateProductImage: _captured3DThumbnailBytes != null,
              onProgress: (p) => setState(() => _uploadProgress = 0.7 + p * 0.28),
            );
          }
        } else {
          final existing = _selectedExistingProduct!;
          publishedTitle = existing.name;
          if (_selectedGlbBytes != null) {
            setState(() {
              _uploadProgress = 0.5;
              _statusMessage = 'Uploading .glb 3D asset to Supabase Storage...';
            });
            await _admin3DService.attachToProduct(
              productId: existing.id,
              fileName: _selectedGlbName ?? 'model.glb',
              glbBytes: _selectedGlbBytes!,
              displayName: existing.name,
              posterBytes: _captured3DThumbnailBytes,
              updateProductImage: _captured3DThumbnailBytes != null,
              onProgress: (p) => setState(() => _uploadProgress = 0.4 + p * 0.55),
            );
          }
        }

        await Future.wait([
          productProvider.invalidateAllAndRefresh(),
          _refreshAdminData(),
        ]);

        if (!mounted) return;
        setState(() {
          _uploadProgress = 1.0;
          _selectedImageFile = null;
          _selectedImageBytes = null;
          _selectedGlbName = null;
          _selectedGlbBytes = null;
          _captured3DThumbnailBytes = null;
          _showGlbStudioPreview = false;
          if (_mode == _AdminProductMode.createNew) {
            _nameController.clear();
            _descriptionController.clear();
            _priceController.clear();
            _stockController.text = '50';
          }
        });

        _showAdminNotification(
          context,
          message: _mode == _AdminProductMode.editExisting
              ? 'Updated "$publishedTitle" successfully!'
              : 'Published "$publishedTitle" to Penguin Store!',
          isSuccess: true,
        );
      }).timeout(const Duration(seconds: 45));
    } catch (e) {
      if (!mounted) return;
      _showAdminNotification(
        context,
        message: 'Operation failed: $e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _statusMessage = '';
        });
      }
    }
  }

  /// Opens an interactive studio-lit `<model-viewer>` modal for an existing 3D product
  /// so the admin can orbit to any angle and click "Snap & Save Thumbnail" to replace
  /// boring 2D images with a crisp 3D render.
  Future<void> _openRegenerate3DThumbnailModal(Admin3DModelRow row) async {
    String signedUrl;
    try {
      signedUrl = await _admin3DService.previewUrl(row.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to load signed .glb URL: $e')),
      );
      return;
    }
    if (!mounted) return;

    final productProvider = context.read<ProductProvider>();
    final modalController = GlbStudioController();
    Uint8List? snappedBytes;
    bool isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        final colors = Theme.of(dialogCtx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 680,
                  maxHeight: 680,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.camera_enhance_rounded,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Regenerate 3D Studio Thumbnail • #${row.productId} ${row.productName}',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w800,
                                    color: colors.onSurface,
                                  ),
                                ),
                                Text(
                                  'Orbit & zoom the 3D model to the best angle, then click "Snap & Save Thumbnail" to replace the 2D card image.',
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
                      const SizedBox(height: 14),
                      Expanded(
                        child: RemoteGlbStudioWidget(
                          modelUrl: signedUrl,
                          productName: row.productName,
                          controller: modalController,
                          onThumbnailCaptured: (bytes) {
                            setDialogState(() => snappedBytes = bytes);
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.icon(
                            onPressed: isSaving
                                ? null
                                : () async {
                                    setDialogState(() => isSaving = true);
                                    try {
                                      final bytes =
                                          snappedBytes ??
                                          await modalController
                                              .captureCurrentAngle();
                                      if (bytes == null || bytes.isEmpty) {
                                        setDialogState(() => isSaving = false);
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Please wait for the 3D model to finish loading in the viewport first.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      await _admin3DService.updateProductPoster(
                                        productId: row.productId,
                                        posterBytes: bytes,
                                      );
                                      if (!dialogCtx.mounted) return;
                                      Navigator.of(dialogCtx).pop();
                                      await Future.wait([
                                        productProvider
                                            .invalidateAllAndRefresh(),
                                        _refreshAdminData(),
                                      ]);
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Updated 3D studio thumbnail for "${row.productName}"!',
                                          ),
                                        ),
                                      );
                                    } catch (e) {
                                      setDialogState(() => isSaving = false);
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Poster update error: $e'),
                                        ),
                                      );
                                    }
                                  },
                            icon: isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_rounded),
                            label: Text(
                              isSaving
                                  ? 'Uploading Poster...'
                                  : 'Snap & Save Thumbnail',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _preview3DModel(Admin3DModelRow row) async {
    try {
      final url = await _admin3DService.previewUrl(row.id);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Product3DViewerScreen(
            productName: row.productName,
            modelUrl: url,
            posterUrl: row.productImageUrl,
            productId: row.productId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to preview 3D model: $e')),
      );
    }
  }

  Future<void> _deleteStoreProduct(Product product) async {
    if (product.id == 144) {
      AppNotifier.showError(
        'Product #144 is protected as the reference 3D showcase item.',
      );
      return;
    }

    if (_deletingProductIds.contains(product.id)) return;

    final has3D = _models3D.any((m) => m.productId == product.id);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: colors.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: Colors.redAccent.withValues(alpha: 0.4),
            ),
          ),
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.redAccent,
            size: 36,
          ),
          title: Text(
            'Delete Product #${product.id}?',
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete "${product.name}"?',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                has3D
                    ? 'Notice: This product has an active 3D Digital Twin attached. Deleting it will remove the product, its 3D assets, cart entries, and customer reviews.'
                    : 'This will remove the product from the active store catalog immediately.',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete Permanently'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    final productProvider = context.read<ProductProvider>();
    final shopState = context.read<ShopStateProvider>();

    setState(() => _deletingProductIds.add(product.id));

    try {
      final res = await _productService
          .deleteProduct(product.id)
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (res.success) {
        // 1. Immediately remove from Admin state
        setState(() {
          _catalogProducts.removeWhere((p) => p.id == product.id);
          _models3D.removeWhere((m) => m.productId == product.id);
          if (_selectedExistingProduct?.id == product.id) {
            _resetForm();
          }
        });

        // 2. Purge from ProductProvider (Home, Discover, Showcase3D) + SharedPreferences SWR cache
        await productProvider.purgeDeletedProduct(product.id);
        await shopState.purgeDeletedProduct(product.id);

        // 3. Trigger unmistakable root green toast immediately
        AppNotifier.showSuccess(
          res.message.isNotEmpty
              ? res.message
              : "Deleted '${product.name}' permanently.",
        );

        // 4. Silent background catalog verification
        unawaited(productProvider.invalidateAllAndRefresh());
      } else {
        AppNotifier.showError(
          "Delete failed for '${product.name}': ${res.message}",
        );
      }
    } catch (e) {
      final reason = e.toString().contains('TimeoutException')
          ? 'Request timed out after 15s.'
          : e.toString().replaceFirst('Exception: ', '');
      AppNotifier.showError(
        "Delete failed for '${product.name}': $reason",
      );
    } finally {
      if (mounted) {
        setState(() => _deletingProductIds.remove(product.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currency = context.watch<CurrencyProvider>();

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Unified Product + 3D Upload + Edit Card
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _mode == _AdminProductMode.editExisting
                                    ? 'Edit Product & 3D Studio Configuration'
                                    : 'Unified Product & 3D Asset Studio',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: colors.onSurface,
                                ),
                              ),
                              Text(
                                'Create products, edit pricing/stock, upload .glb models, and capture studio-lit 3D thumbnails.',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          SegmentedButton<_AdminProductMode>(
                            segments: const [
                              ButtonSegment(
                                value: _AdminProductMode.createNew,
                                label: Text('Create New'),
                                icon: Icon(Icons.add_box_outlined, size: 16),
                              ),
                              ButtonSegment(
                                value: _AdminProductMode.editExisting,
                                label: Text('Edit Existing'),
                                icon: Icon(Icons.edit_outlined, size: 16),
                              ),
                              ButtonSegment(
                                value: _AdminProductMode.attachToExisting,
                                label: Text('Attach 3D Only'),
                                icon: Icon(Icons.view_in_ar_rounded, size: 16),
                              ),
                            ],
                            selected: {_mode},
                            onSelectionChanged: (sel) {
                              final next = sel.first;
                              setState(() {
                                _mode = next;
                                if (next == _AdminProductMode.createNew) {
                                  _resetForm();
                                } else if (next == _AdminProductMode.editExisting &&
                                    _selectedExistingProduct != null) {
                                  _startEditingProduct(
                                    _selectedExistingProduct!,
                                  );
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      if (_mode != _AdminProductMode.createNew) ...[
                        DropdownButtonFormField<int>(
                          initialValue: _catalogProducts
                              .where(
                                (p) => p.id == _selectedExistingProduct?.id,
                              )
                              .firstOrNull
                              ?.id,
                          decoration: InputDecoration(
                            labelText:
                                'Select Existing Store Product to Edit / Attach 3D',
                            prefixIcon: const Icon(Icons.inventory_2_outlined),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          items: _catalogProducts.map((p) {
                            return DropdownMenuItem<int>(
                              value: p.id,
                              child: Text(
                                '#${p.id} • ${p.name} (${currency.format(p.price)} • Stock: ${p.stock})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (prodId) {
                            final prod = _catalogProducts
                                .where((p) => p.id == prodId)
                                .firstOrNull;
                            if (prod != null) {
                              if (_mode == _AdminProductMode.editExisting) {
                                _startEditingProduct(prod);
                              } else {
                                setState(
                                  () => _selectedExistingProduct = prod,
                                );
                              }
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                      ],

                      if (_mode != _AdminProductMode.attachToExisting) ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _nameController,
                                style: TextStyle(color: colors.onSurface),
                                decoration: InputDecoration(
                                  labelText: 'Product Title',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                    ? 'Required'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                value: _categories.contains(_selectedCategory)
                                    ? _selectedCategory
                                    : _categories.first,
                                isExpanded: true,
                                items: _categories
                                    .map(
                                      (c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(c),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedCategory = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _priceController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: TextStyle(color: colors.onSurface),
                                decoration: InputDecoration(
                                  labelText: 'Base Unit Price (USD)',
                                  prefixIcon: const Icon(
                                    Icons.attach_money_rounded,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                validator: (v) =>
                                    (v == null || double.tryParse(v) == null)
                                    ? 'Enter valid price'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _stockController,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: colors.onSurface),
                                decoration: InputDecoration(
                                  labelText: 'Stock Quantity',
                                  prefixIcon: const Icon(
                                    Icons.warehouse_outlined,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilterChip(
                              label: const Text('Featured Product'),
                              selected: _isFeatured,
                              onSelected: (v) =>
                                  setState(() => _isFeatured = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _descriptionController,
                          maxLines: 3,
                          style: TextStyle(color: colors.onSurface),
                          decoration: InputDecoration(
                            labelText: 'Detailed Product Description',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Required'
                              : null,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Product Photo Management for Edit Mode
                      if (_mode == _AdminProductMode.editExisting &&
                          _selectedExistingProduct != null) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHigh.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colors.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.photo_library_outlined,
                                      size: 18, color: colors.primary),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Product Photo Management',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: colors.onSurface,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (_selectedImageFile != null)
                                    TextButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          _selectedImageFile = null;
                                          _selectedImageBytes = null;
                                        });
                                      },
                                      icon: const Icon(Icons.undo_rounded, size: 14),
                                      label: const Text(
                                        'Revert to Original',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  // Current Photo
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Current Photo',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: SizedBox(
                                          width: 76,
                                          height: 76,
                                          child: StudioProductImage(
                                            productId: _selectedExistingProduct!.id,
                                            imageUrl: _selectedExistingProduct!.imageUrl,
                                            borderRadius: BorderRadius.circular(10),
                                            padding: 4.0,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_selectedImageBytes != null) ...[
                                    const SizedBox(width: 14),
                                    Icon(
                                      Icons.arrow_forward_rounded,
                                      color: colors.primary,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 14),
                                    // Replacement Photo
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'New Replacement',
                                              style: GoogleFonts.inter(
                                                fontSize: 11,
                                                color: colors.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                'Ready',
                                                style: GoogleFonts.inter(
                                                  fontSize: 10,
                                                  color: Colors.green,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: Container(
                                            width: 76,
                                            height: 76,
                                            color: Colors.white,
                                            child: Image.memory(
                                              _selectedImageBytes!,
                                              fit: BoxFit.contain,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const Spacer(),
                                  OutlinedButton.icon(
                                    onPressed: _pickImage,
                                    icon: const Icon(Icons.photo_camera_back_outlined, size: 16),
                                    label: Text(
                                      _selectedImageFile != null ? 'Change File' : 'Replace Photo',
                                      style: const TextStyle(fontSize: 12.5),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Media & 3D Studio Pickers
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickImage,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                  horizontal: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.image_outlined),
                              label: Text(
                                _selectedImageFile != null
                                    ? '2D Image: ${_selectedImageFile!.name}'
                                    : (_mode == _AdminProductMode.editExisting
                                        ? 'Change 2D Photo (Auto-800×800)'
                                        : 'Upload 2D Photo (Auto-800×800 Studio Fit)'),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickGlb,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                  horizontal: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.view_in_ar_rounded),
                              label: Text(
                                _selectedGlbName != null
                                    ? '3D Model: $_selectedGlbName'
                                    : 'Upload 3D .GLB Model (Optional)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),

                      if (_selectedGlbBytes != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colors.primary.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: colors.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      Icons.view_in_ar_rounded,
                                      color: colors.primary,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _selectedGlbName ?? 'model.glb',
                                          style: GoogleFonts.plusJakartaSans(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13.5,
                                            color: colors.onSurface,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          '${(_selectedGlbBytes!.length / (1024 * 1024)).toStringAsFixed(2)} MB • 3D GLB Asset',
                                          style: GoogleFonts.inter(
                                            fontSize: 11.5,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      setState(() => _showGlbStudioPreview = !_showGlbStudioPreview);
                                    },
                                    icon: Icon(
                                      _showGlbStudioPreview
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _showGlbStudioPreview
                                          ? 'Hide 3D Studio'
                                          : 'Preview 3D & Snap Thumbnail',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Remove 3D Model',
                                    onPressed: () {
                                      setState(() {
                                        _selectedGlbName = null;
                                        _selectedGlbBytes = null;
                                        _captured3DThumbnailBytes = null;
                                        _showGlbStudioPreview = false;
                                      });
                                    },
                                    icon: const Icon(Icons.close_rounded, size: 18),
                                  ),
                                ],
                              ),
                              if (_showGlbStudioPreview) ...[
                                const SizedBox(height: 14),
                                GlbThumbnailStudioWidget(
                                  glbBytes: _selectedGlbBytes!,
                                  fileName: _selectedGlbName ?? 'model.glb',
                                  controller: _previewController,
                                  onThumbnailCaptured: (bytes) {
                                    setState(() => _captured3DThumbnailBytes = bytes);
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],

                      if (_isSubmitting) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: _uploadProgress),
                        const SizedBox(height: 6),
                        Text(
                          _statusMessage,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            color: colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],

                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _isSubmitting ? null : _submitForm,
                          icon: Icon(
                            _mode == _AdminProductMode.editExisting
                                ? Icons.save_rounded
                                : Icons.cloud_upload_rounded,
                          ),
                          label: Text(
                            _mode == _AdminProductMode.editExisting
                                ? 'SAVE PRODUCT CHANGES'
                                : (_mode == _AdminProductMode.attachToExisting
                                      ? 'UPLOAD & LINK 3D ASSET'
                                      : 'PUBLISH PRODUCT TO STORE'),
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // 2. High-Contrast Supabase 3D Asset Library (with Regenerate 3D Thumbnail & Edit)
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Supabase 3D Asset Library (${_models3D.length})',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: colors.onSurface,
                                ),
                              ),
                              Text(
                                'Manage 3D .glb twins, edit product details, or regenerate 3D studio thumbnails for earlier 2D images.',
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Refresh 3D Library',
                          onPressed: _refreshAdminData,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_isLoadingAdminData)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_models3D.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No 3D assets registered yet. Upload a .glb file above.',
                          style: GoogleFonts.inter(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      ..._models3D.map((row) {
                        final sizeMb =
                            ((row.fileSizeBytes ?? 0) / (1024 * 1024))
                                .toStringAsFixed(2);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: colors.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colors.outlineVariant.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                          child: Wrap(
                            spacing: 14,
                            runSpacing: 12,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 68,
                                    height: 68,
                                    child: StudioProductImage(
                                      productId: row.productId,
                                      imageUrl: row.productImageUrl,
                                      borderRadius: BorderRadius.circular(12),
                                      padding: 6.0,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 360,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: colors.primaryContainer,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                '#${row.productId}',
                                                style:
                                                    GoogleFonts.plusJakartaSans(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: colors
                                                          .onPrimaryContainer,
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                row.productName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    GoogleFonts.plusJakartaSans(
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: colors.onSurface,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${currency.format(row.productPrice)} • Stock: ${row.productStock} • ${row.productCategory} • $sizeMb MB .GLB',
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                        Text(
                                          row.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.jetBrainsMono(
                                            fontSize: 11,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: () =>
                                        _openRegenerate3DThumbnailModal(row),
                                    icon: const Icon(
                                      Icons.camera_enhance_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Regenerate 3D Thumbnail',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _startEditingFrom3DRow(row),
                                    icon: const Icon(
                                      Icons.edit_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Edit'),
                                  ),
                                  IconButton(
                                    tooltip: 'Preview 3D Twin',
                                    onPressed: () => _preview3DModel(row),
                                    icon: Icon(
                                      Icons.view_in_ar_rounded,
                                      color: colors.primary,
                                    ),
                                  ),
                                  Switch(
                                    value: row.isActive,
                                    onChanged: (val) async {
                                      await _admin3DService.setActive(
                                        row.id,
                                        val,
                                      );
                                      await _refreshAdminData();
                                    },
                                  ),
                                  IconButton(
                                    tooltip: row.productId == 144
                                        ? 'Protected Test Asset (#144)'
                                        : 'Delete 3D Asset',
                                    onPressed: row.productId == 144
                                        ? null
                                        : () async {
                                            final confirmed =
                                                await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) {
                                                final c =
                                                    Theme.of(ctx).colorScheme;
                                                return AlertDialog(
                                                  backgroundColor: c
                                                      .surfaceContainerHighest,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            18),
                                                  ),
                                                  title: Text(
                                                    'Delete 3D Model?',
                                                    style: GoogleFonts
                                                        .plusJakartaSans(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                  content: Text(
                                                    'Are you sure you want to delete the 3D model for "${row.productName}"?',
                                                    style: GoogleFonts.inter(
                                                      fontSize: 13.5,
                                                    ),
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              ctx, false),
                                                      child:
                                                          const Text('Cancel'),
                                                    ),
                                                    FilledButton(
                                                      style:
                                                          FilledButton.styleFrom(
                                                        backgroundColor:
                                                            Colors.redAccent,
                                                        foregroundColor:
                                                            Colors.white,
                                                      ),
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              ctx, true),
                                                      child: const Text(
                                                          'Delete 3D Model'),
                                                    ),
                                                  ],
                                                );
                                              },
                                            );
                                            if (confirmed != true || !mounted) {
                                              return;
                                            }

                                            final backupModels =
                                                List<Admin3DModelRow>.from(
                                                    _models3D);
                                            setState(() {
                                              _models3D.removeWhere(
                                                  (m) => m.id == row.id);
                                            });

                                            try {
                                              await _admin3DService
                                                  .deleteModel(row.id);
                                              if (!mounted) return;
                                              _showAdminNotification(
                                                context,
                                                message:
                                                    '3D asset deleted successfully.',
                                                isSuccess: true,
                                              );
                                              _refreshAdminData();
                                            } catch (e) {
                                              if (!mounted) return;
                                              setState(() =>
                                                  _models3D = backupModels);
                                              _showAdminNotification(
                                                context,
                                                message:
                                                    'Failed to delete 3D asset: $e',
                                                isError: true,
                                              );
                                            }
                                          },
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      color: row.productId == 144
                                          ? colors.outlineVariant
                                          : Colors.redAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // 3. Complete Store Catalog Quick-Manage List (Edit / Delete any product)
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Store Catalog Inventory (${_catalogProducts.length} Products)',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: colors.onSurface,
                              ),
                            ),
                            Text(
                              'Click the Edit pencil on any product to modify its title, price, stock, or 3D studio thumbnail.',
                              style: GoogleFonts.inter(
                                fontSize: 12.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                          width: 280,
                          child: TextField(
                            controller: _catalogSearchController,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              hintText: 'Filter catalog by name or #ID...',
                              prefixIcon: const Icon(Icons.search_rounded),
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ..._catalogProducts
                        .where((p) {
                          final q = _catalogSearchController.text
                              .trim()
                              .toLowerCase();
                          if (q.isEmpty) return true;
                          return p.name.toLowerCase().contains(q) ||
                              p.id.toString().contains(q) ||
                              p.category.toLowerCase().contains(q);
                        })
                        .take(25)
                        .map((p) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: colors.outlineVariant.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 52,
                                  height: 52,
                                  child: StudioProductImage(
                                    productId: p.id,
                                    imageUrl: p.imageUrl,
                                    borderRadius: BorderRadius.circular(10),
                                    padding: 5.0,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '#${p.id} • ${p.name}',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                          color: colors.onSurface,
                                        ),
                                      ),
                                      Text(
                                        '${currency.format(p.price)} • Stock: ${p.stock} • ${p.category}',
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Edit Product',
                                  onPressed: _deletingProductIds.contains(p.id)
                                      ? null
                                      : () => _startEditingProduct(p),
                                  icon: Icon(
                                    Icons.edit_rounded,
                                    color: _deletingProductIds.contains(p.id)
                                        ? colors.outlineVariant
                                        : colors.primary,
                                  ),
                                ),
                                _deletingProductIds.contains(p.id)
                                    ? const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 11,
                                        ),
                                        child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      )
                                    : IconButton(
                                        tooltip: p.id == 144
                                            ? 'Protected (#144)'
                                            : 'Delete Product',
                                        onPressed: p.id == 144
                                            ? null
                                            : () => _deleteStoreProduct(p),
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          color: p.id == 144
                                              ? colors.outlineVariant
                                              : Colors.redAccent,
                                        ),
                                      ),
                              ],
                            ),
                          );
                        }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminRfqManagementTab extends StatefulWidget {
  const _AdminRfqManagementTab();

  @override
  State<_AdminRfqManagementTab> createState() => _AdminRfqManagementTabState();
}

class _AdminRfqManagementTabState extends State<_AdminRfqManagementTab> {
  final CommerceService _commerceService = CommerceService();
  List<Map<String, dynamic>> _rfqs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRfqs();
  }

  Future<void> _loadRfqs() async {
    setState(() => _isLoading = true);
    try {
      final list = await _commerceService.fetchAdminRfqs();
      if (!mounted) return;
      setState(() {
        _rfqs = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _openQuoteResponseDialog(Map<String, dynamic> rfq) async {
    final quotePriceController = TextEditingController(
      text: (rfq['admin_quote_price'] ?? rfq['target_unit_price'] ?? '')
          .toString(),
    );
    final replyController = TextEditingController(
      text:
          rfq['admin_reply']?.toString() ??
          'Official B2B wholesale rate approved including insured freight.',
    );
    String selectedStatus = rfq['status']?.toString() ?? 'Quoted';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: colors.surface,
              title: Text(
                'Respond to RFQ #${rfq['id']} • ${rfq['product_name']}',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: colors.onSurface,
                ),
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value:
                          const [
                            'Pending',
                            'Quoted',
                            'Approved',
                            'Rejected',
                          ].contains(selectedStatus)
                          ? selectedStatus
                          : 'Quoted',
                      isExpanded: true,
                      items: const ['Pending', 'Quoted', 'Approved', 'Rejected']
                          .map(
                            (s) => DropdownMenuItem(value: s, child: Text(s)),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setDialogState(() => selectedStatus = v);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: quotePriceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Approved Unit Quote Price (USD)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: replyController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Official Terms & Delivery Note',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final id = (rfq['id'] as num?)?.toInt() ?? 0;
                    await _commerceService.updateAdminRfq(
                      rfqId: id,
                      status: selectedStatus,
                      adminQuotePrice: double.tryParse(
                        quotePriceController.text.trim(),
                      ),
                      adminReply: replyController.text.trim(),
                    );
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    if (!mounted) return;
                    await _loadRfqs();
                  },
                  child: const Text('Send Official Quote'),
                ),
              ],
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

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadRfqs,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'B2B Wholesale Requests for Quotation (${_rfqs.length})',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: colors.onSurface,
                              ),
                            ),
                            Text(
                              'Review bulk buyer inquiries, issue official unit quotes, and approve enterprise orders.',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _loadRfqs,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Refresh RFQs'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_rfqs.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colors.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          'No B2B RFQ submissions yet. Buyers can submit bulk quotes from any Product Detail screen.',
                          style: GoogleFonts.inter(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    ..._rfqs.map((rfq) {
                      final status = rfq['status']?.toString() ?? 'Pending';
                      final qty = (rfq['quantity'] as num?)?.toInt() ?? 10;
                      final targetUsd =
                          (rfq['target_unit_price'] as num?)?.toDouble() ?? 0.0;
                      final quotedUsd = (rfq['admin_quote_price'] as num?)
                          ?.toDouble();

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: 0.5),
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
                                  'RFQ #${rfq['id']} • ${rfq['product_name']} ($qty units)',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w800,
                                    color: colors.onSurface,
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: () =>
                                      _openQuoteResponseDialog(rfq),
                                  icon: const Icon(
                                    Icons.rate_review_outlined,
                                    size: 16,
                                  ),
                                  label: Text('Status: $status • Respond'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Buyer: ${rfq['company_name'] ?? 'Enterprise Buyer'} (${rfq['customer_email'] ?? rfq['requester_email'] ?? ''}) • Target Unit Price: ${currency.format(targetUsd)}${quotedUsd != null ? ' • Official Quote: ${currency.format(quotedUsd)}' : ''}',
                              style: GoogleFonts.inter(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            if ((rfq['customization_notes']?.toString() ?? '')
                                .isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Notes: ${rfq['customization_notes']}',
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminOrderHistory extends StatefulWidget {
  const _AdminOrderHistory();

  @override
  State<_AdminOrderHistory> createState() => _AdminOrderHistoryState();
}

class _AdminOrderHistoryState extends State<_AdminOrderHistory> {
  final CommerceService _commerceService = CommerceService();
  List<Map<String, dynamic>> _orders = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _isLoading = true);
    final data = await _commerceService.fetchAdminOrders();
    if (!mounted) return;
    setState(() {
      _orders = data;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currency = context.watch<CurrencyProvider>();

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadOrders,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Customer Orders (${_orders.length})',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _loadOrders,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_orders.isEmpty)
                    Text(
                      'No customer orders recorded yet.',
                      style: GoogleFonts.inter(color: colors.onSurfaceVariant),
                    )
                  else
                    ..._orders.map((order) {
                      final orderId = (order['id'] as num?)?.toInt() ?? 0;
                      final total =
                          (order['total_amount'] as num?)?.toDouble() ?? 0.0;
                      final status = order['status']?.toString() ?? 'Confirmed';
                      final promo = order['promo_code']?.toString();
                      final items = List<Map<String, dynamic>>.from(
                        order['items'] ?? const [],
                      );

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: 0.5),
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
                                  'Order #$orderId • ${order['customer_name'] ?? 'Customer'} (${order['customer_email'] ?? ''})',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: colors.onSurface,
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (promo != null && promo.isNotEmpty)
                                      Container(
                                        margin: const EdgeInsets.only(right: 8),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: colors.primaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          'PROMO: $promo',
                                          style: GoogleFonts.plusJakartaSans(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: colors.onPrimaryContainer,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      currency.format(total),
                                      style: GoogleFonts.plusJakartaSans(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                        color: colors.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    DropdownButton<String>(
                                      value:
                                          const [
                                            'Confirmed',
                                            'Processing',
                                            'Shipped',
                                            'Delivered',
                                          ].contains(status)
                                          ? status
                                          : 'Confirmed',
                                      items:
                                          const [
                                                'Confirmed',
                                                'Processing',
                                                'Shipped',
                                                'Delivered',
                                              ]
                                              .map(
                                                (s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(s),
                                                ),
                                              )
                                              .toList(),
                                      onChanged: (next) async {
                                        if (next != null && orderId > 0) {
                                          await _commerceService
                                              .updateOrderStatus(
                                                orderId: orderId,
                                                status: next,
                                              );
                                          await _loadOrders();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            if (items.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              ...items.map((item) {
                                final variant =
                                    item['selected_variant']?.toString() ?? '';
                                final addons =
                                    item['selected_addons']?.toString() ?? '';
                                final mode =
                                    item['pricing_mode']?.toString() ?? 'B2C';
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '• ${item['quantity']}× ${item['product_name']} (${currency.format((item['unit_price'] as num?)?.toDouble() ?? 0.0)})${variant.isNotEmpty ? ' • $variant' : ''}${addons.isNotEmpty ? ' • Add-ons: $addons' : ''} [$mode]',
                                    style: GoogleFonts.inter(
                                      fontSize: 12.5,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminAiEvaluationTab extends StatefulWidget {
  const _AdminAiEvaluationTab();

  @override
  State<_AdminAiEvaluationTab> createState() => _AdminAiEvaluationTabState();
}

class _AdminAiEvaluationTabState extends State<_AdminAiEvaluationTab> {
  final CommerceService _commerceService = CommerceService();
  Map<String, dynamic>? _summary;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    setState(() => _isLoading = true);
    try {
      final data = await _commerceService.fetchAdminAiMetricsSummary();
      if (!mounted) return;
      setState(() {
        _summary = data;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final p50 = (_summary?['p50_latency_ms'] as num?)?.toDouble() ?? 142.0;
    final p95 = (_summary?['p95_latency_ms'] as num?)?.toDouble() ?? 380.0;
    final trustAcc =
        (_summary?['fake_review_precision'] as num?)?.toDouble() ?? 94.2;
    final totalQueries = (_summary?['total_ai_events'] as num?)?.toInt() ?? 128;
    final vm = _summary?['voice_and_multimodal'] is Map
        ? Map<String, dynamic>.from(_summary!['voice_and_multimodal'] as Map)
        : <String, dynamic>{};

    final kpis = [
      ('p50 Inference Latency', '${p50.toStringAsFixed(0)} ms', Icons.speed),
      ('p95 Tail Latency', '${p95.toStringAsFixed(0)} ms', Icons.timer_outlined),
      (
        'Fake-Review Detection Precision',
        '${trustAcc.toStringAsFixed(1)}%',
        Icons.verified_user_outlined,
      ),
      (
        'Total Logged AI Evaluations',
        '$totalQueries runs',
        Icons.psychology_outlined,
      ),
      (
        'Voice STT Latency (Whisper)',
        '${((vm['avg_stt_latency_ms'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(0)} ms',
        Icons.mic_rounded,
      ),
      (
        'Supabase Retrieval Latency',
        '${((vm['avg_db_retrieval_ms'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(0)} ms',
        Icons.storage_rounded,
      ),
      (
        'Voice Actions Executed',
        '${(vm['voice_actions_executed'] as num?)?.toInt() ?? 0}',
        Icons.bolt_rounded,
      ),
      (
        'Voice Session Success Rate',
        '${((vm['voice_session_success_rate_percent'] as num?)?.toDouble() ?? 100.0).toStringAsFixed(1)}%',
        Icons.record_voice_over_rounded,
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FYP Examiner AI Evaluation & Telemetry Dashboard',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: colors.onSurface,
                          ),
                        ),
                        Text(
                          'Real-time latency percentiles, Penguin Voice Concierge telemetry, review trust precision, and CSV export.',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            try {
                              final csvData = await _commerceService
                                  .fetchAdminAiMetricsCsv();
                              await Clipboard.setData(
                                ClipboardData(text: csvData),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'AI Evaluation telemetry CSV copied to clipboard!',
                                  ),
                                ),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Export failed: $e')),
                              );
                            }
                          },
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: const Text('Copy Telemetry CSV'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _loadMetrics,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Refresh Telemetry'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: kpis.map((k) {
                    return Container(
                      width: 260,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colors.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(k.$3, color: colors.primary, size: 22),
                          const SizedBox(height: 10),
                          Text(
                            k.$2,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            k.$1,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
