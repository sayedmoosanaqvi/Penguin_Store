import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../models/product_model.dart';
import '../services/visual_search_service.dart';
import '../widgets/product_card.dart';

class VisualSearchResultsScreen extends StatefulWidget {
  final List<dynamic> matches;
  final Uint8List? queryImageBytes;
  final Map<String, dynamic> analysis;
  final String? statusMessage;

  const VisualSearchResultsScreen({
    super.key,
    required this.matches,
    this.queryImageBytes,
    this.analysis = const {},
    this.statusMessage,
  });

  @override
  State<VisualSearchResultsScreen> createState() =>
      _VisualSearchResultsScreenState();
}

class _VisualSearchResultsScreenState
    extends State<VisualSearchResultsScreen> {
  final VisualSearchService _visualSearchService = VisualSearchService();

  late List<dynamic> _matches;
  Uint8List? _queryImageBytes;
  late Map<String, dynamic> _analysis;
  String? _statusMessage;
  bool _isSearchingAgain = false;

  @override
  void initState() {
    super.initState();
    _matches = List<dynamic>.from(widget.matches);
    _queryImageBytes = widget.queryImageBytes;
    _analysis = Map<String, dynamic>.from(widget.analysis);
    _statusMessage = widget.statusMessage;
  }

  List<Map<String, dynamic>> _parseMatchedItems() {
    final List<Map<String, dynamic>> items = [];

    for (final raw in _matches) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);

      final Map<String, dynamic> productData = map['product'] is Map
          ? Map<String, dynamic>.from(map['product'] as Map)
          : map;

      final double rawScore =
          (map['score'] as num?)?.toDouble() ?? 0.90;
      final double clampedScore = rawScore.clamp(0.0, 1.0);
      final String matchLabel = (map['match_label'] ??
              (clampedScore >= 0.85
                  ? 'Exact Match'
                  : clampedScore >= 0.65
                      ? 'Strong Match'
                      : 'Visual Match'))
          .toString();
      final String matchReason = (map['match_reason'] ?? '').toString().trim();

      final int id = (productData['id'] as num?)?.toInt() ?? 0;
      final String name = (productData['name'] ?? 'Product').toString();
      final String description =
          (productData['description'] ?? '').toString();
      final double price =
          (productData['price'] as num?)?.toDouble() ?? 0.0;
      final double? originalPrice =
          (productData['original_price'] as num?)?.toDouble();
      final String imageUrl =
          (productData['image_url'] ?? productData['imageUrl'] ?? '')
              .toString()
              .trim();
      final String category =
          (productData['category'] ?? 'CATALOG').toString();
      final double rating =
          (productData['rating'] as num?)?.toDouble() ?? 0.0;
      final int reviews =
          (productData['reviews'] as num?)?.toInt() ?? 0;
      final int? discountPercent =
          (productData['discount_percent'] as num?)?.toInt();
      final bool isFeatured = productData['is_featured'] == true;

      items.add({
        'score': (clampedScore * 100).toStringAsFixed(1),
        'scoreValue': clampedScore,
        'matchLabel': matchLabel,
        'matchReason': matchReason,
        'product': Product(
          id: id,
          name: name,
          description: description,
          price: price,
          originalPrice: originalPrice,
          imageUrl: imageUrl,
          category: category,
          rating: rating,
          reviews: reviews,
          discountPercent: discountPercent,
          isFeatured: isFeatured,
        ),
      });
    }

    return items;
  }

  Future<void> _runNewVisualSearch(ImageSource source) async {
    if (_isSearchingAgain) return;

    final picked =
        await _visualSearchService.pickImageForSearch(source);
    if (picked == null || !mounted) return;

    setState(() {
      _isSearchingAgain = true;
      _queryImageBytes = picked.bytes;
    });

    try {
      final response = await _visualSearchService.searchWithImageBytes(
        picked.bytes,
        filename: picked.filename,
      );

      if (!mounted) return;

      setState(() {
        _matches = response.matches;
        _analysis = response.analysis;
        _statusMessage = response.message;
        _isSearchingAgain = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearchingAgain = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Visual search failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _showRescanSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'Scan Another Image',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    'Our AI automatically enhances blurry or low-light photos.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('Take Photo'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _runNewVisualSearch(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from Gallery'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _runNewVisualSearch(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _parseMatchedItems();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'AI Visual Search',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: theme.textTheme.titleLarge?.color,
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Scan Another Image',
            onPressed: _isSearchingAgain ? null : _showRescanSheet,
            icon: const Icon(Icons.camera_enhance_outlined),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _isSearchingAgain
          ? _buildAnalyzingView(theme)
          : items.isEmpty
              ? _buildNotInDatabaseState(theme)
              : CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: _buildAnalysisBanner(theme, items.length),
                      ),
                    ),
                    _buildResponsiveGridSliver(items),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: 48),
                    ),
                  ],
                ),
    );
  }

  Widget _buildAnalyzingView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_queryImageBytes != null)
              Container(
                width: 110,
                height: 110,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.primaryColor,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(
                    _queryImageBytes!,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            CircularProgressIndicator(color: theme.primaryColor),
            const SizedBox(height: 18),
            const Text(
              'Analyzing image & enhancing details...',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Matching 2048-D visual features against Penguin Store database',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysisBanner(ThemeData theme, int matchCount) {
    final bool wasDeblurred = _analysis['was_deblurred'] == true;
    final String? detectedCategory =
        _analysis['detected_category']?.toString();
    final dynamic searchTimeMs = _analysis['search_time_ms'];
    final bool isMultimodal = _analysis['search_mode'] == 'multimodal_rrf';
    final String? queryText = _analysis['query_text']?.toString().trim();
    final dynamic maxPriceCap = _analysis['max_price'];
    final bool only3dFilter = _analysis['only_3d'] == true;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.primaryColor,
            theme.colorScheme.tertiary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: theme.primaryColor.withOpacity(0.28),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_queryImageBytes != null)
                Container(
                  width: 62,
                  height: 62,
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.7),
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      _queryImageBytes!,
                      fit: BoxFit.cover,
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.document_scanner_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isMultimodal
                          ? 'Multimodal AI Hybrid Match'
                          : 'Visual Match Found',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Found $matchCount ${isMultimodal ? 'hybrid-ranked' : 'visually matching'} ${matchCount == 1 ? 'product' : 'products'} in the Penguin Store database.',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (wasDeblurred ||
              isMultimodal ||
              (queryText != null && queryText.isNotEmpty) ||
              maxPriceCap != null ||
              only3dFilter ||
              (detectedCategory != null && detectedCategory.isNotEmpty) ||
              searchTimeMs != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (isMultimodal)
                  _buildInfoPill(
                    icon: Icons.merge_type_rounded,
                    label: 'RRF Hybrid Fusion',
                  ),
                if (queryText != null && queryText.isNotEmpty)
                  _buildInfoPill(
                    icon: Icons.mic_none_rounded,
                    label: '"$queryText"',
                  ),
                if (maxPriceCap != null)
                  _buildInfoPill(
                    icon: Icons.attach_money_rounded,
                    label: 'Max \$$maxPriceCap',
                  ),
                if (only3dFilter)
                  _buildInfoPill(
                    icon: Icons.view_in_ar_rounded,
                    label: '3D Models Only',
                  ),
                if (wasDeblurred)
                  _buildInfoPill(
                    icon: Icons.auto_fix_high_rounded,
                    label: 'Blur Auto-Enhanced',
                  ),
                if (detectedCategory != null &&
                    detectedCategory.isNotEmpty)
                  _buildInfoPill(
                    icon: Icons.category_outlined,
                    label: detectedCategory,
                  ),
                if (searchTimeMs != null)
                  _buildInfoPill(
                    icon: Icons.bolt_rounded,
                    label: '${searchTimeMs}ms',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoPill({
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.22),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.24),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotInDatabaseState(ThemeData theme) {
    final bool wasDeblurred = _analysis['was_deblurred'] == true;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: theme.dividerColor.withOpacity(0.2),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_queryImageBytes != null) ...[
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        width: 116,
                        height: 116,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.error.withOpacity(0.5),
                            width: 2,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.memory(
                            _queryImageBytes!,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.search_off_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.search_off_rounded,
                      size: 42,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'NOT IN DATABASE',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Product Not in Database',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _statusMessage?.isNotEmpty == true
                      ? _statusMessage!
                      : 'We analyzed your image${wasDeblurred ? ' (with automatic blur enhancement)' : ''}, '
                          'but this item is not currently available in the Penguin Store database.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _showRescanSheet,
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Try Another Image'),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => context.push('/ctrlx'),
                        icon: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 16,
                        ),
                        label: const Text(
                          'Ask CTRL-X',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.storefront_outlined,
                          size: 16,
                        ),
                        label: const Text(
                          'Browse Store',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResponsiveGridSliver(List<Map<String, dynamic>> items) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;

        int crossAxisCount;
        if (width >= 1100) {
          crossAxisCount = 5;
        } else if (width >= 800) {
          crossAxisCount = 4;
        } else if (width >= 520) {
          crossAxisCount = 3;
        } else {
          crossAxisCount = 2;
        }

        final horizontalPadding = width >= 650 ? 20.0 : 12.0;
        final spacing = width >= 650 ? 14.0 : 10.0;

        final itemWidth = (width -
                horizontalPadding * 2 -
                (crossAxisCount - 1) * spacing) /
            crossAxisCount;

        final itemHeight = itemWidth < 150
            ? itemWidth * 2.15
            : itemWidth < 195
                ? itemWidth * 1.92
                : itemWidth * 1.72;

        return SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 4,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = items[index];
                final Product product = item['product'] as Product;
                final String score = item['score'] as String;
                final double scoreVal =
                    (item['scoreValue'] as num?)?.toDouble() ?? 0.8;
                final String matchReason =
                    (item['matchReason'] ?? '').toString().trim();

                final Color badgeAccent = scoreVal >= 0.85
                    ? const Color(0xFF00E676)
                    : scoreVal >= 0.65
                        ? Colors.cyanAccent
                        : Colors.amberAccent;

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ProductCard(
                      product: product,
                      heroTag: 'visual-match-${product.id}-$index',
                      onProductDeleted: () {
                        setState(() {
                          _matches.removeAt(index);
                        });
                      },
                    ),
                    Positioned(
                      top: 7,
                      right: 7,
                      child: IgnorePointer(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.82),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: badgeAccent.withOpacity(0.5),
                                  width: 0.8,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.25),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.blur_on_rounded,
                                    color: badgeAccent,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$score%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (matchReason.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: (itemWidth - 20).clamp(90.0, 175.0),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.76),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    matchReason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
              childCount: items.length,
            ),
          ),
        );
      },
    );
  }
}
