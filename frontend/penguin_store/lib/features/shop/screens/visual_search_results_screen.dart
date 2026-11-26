import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
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

class _VisualSearchResultsScreenState extends State<VisualSearchResultsScreen> {
  final VisualSearchService _visualSearchService = VisualSearchService();
  final TextEditingController _refineController = TextEditingController();

  late List<dynamic> _matches;
  Uint8List? _queryImageBytes;
  late Map<String, dynamic> _analysis;
  String? _statusMessage;
  bool _isSearchingAgain = false;
  bool _only3dRefine = false;
  String _loadingStepText = 'Extracting 2048-D visual features...';

  @override
  void initState() {
    super.initState();
    _matches = List<dynamic>.from(widget.matches);
    _queryImageBytes = widget.queryImageBytes;
    _analysis = Map<String, dynamic>.from(widget.analysis);
    _statusMessage = widget.statusMessage;
    final initialQ = _analysis['query_text']?.toString().trim() ?? '';
    if (initialQ.isNotEmpty) {
      _refineController.text = initialQ;
    }
    _only3dRefine = _analysis['only_3d'] == true;
  }

  @override
  void dispose() {
    _refineController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _parseMatchedItems() {
    final List<Map<String, dynamic>> items = [];

    for (final raw in _matches) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);

      final Map<String, dynamic> productData = map['product'] is Map
          ? Map<String, dynamic>.from(map['product'] as Map)
          : map;

      final double rawScore = (map['score'] as num?)?.toDouble() ?? 0.65;
      final double clampedScore = rawScore.clamp(0.0, 1.0);
      final String tier = (map['confidence_tier'] ??
              (clampedScore >= 0.75
                  ? 'strong_match'
                  : clampedScore >= 0.55
                      ? 'similar_style'
                      : 'closest_alternatives'))
          .toString();
      final String matchLabel = (map['match_label'] ??
              (clampedScore >= 0.75
                  ? 'Strong Match'
                  : clampedScore >= 0.55
                      ? 'Similar Style'
                      : 'Closest Alternative'))
          .toString();
      final String matchReason = (map['match_reason'] ?? '').toString().trim();

      final int id = (productData['id'] as num?)?.toInt() ?? 0;
      final String name = (productData['name'] ?? 'Product').toString();
      final String description = (productData['description'] ?? '').toString();
      final double price = (productData['price'] as num?)?.toDouble() ?? 0.0;
      final double? originalPrice =
          (productData['original_price'] as num?)?.toDouble();
      final String imageUrl =
          (productData['image_url'] ?? productData['imageUrl'] ?? '')
              .toString()
              .trim();
      final String category =
          (productData['category'] ?? 'CATALOG').toString();
      final double rating = (productData['rating'] as num?)?.toDouble() ?? 0.0;
      final int reviews = (productData['reviews'] as num?)?.toInt() ?? 0;
      final int? discountPercent =
          (productData['discount_percent'] as num?)?.toInt();
      final bool isFeatured = productData['is_featured'] == true;
      final int stock = (productData['stock'] as num?)?.toInt() ?? 50;

      items.add({
        'score': (clampedScore * 100).toStringAsFixed(0),
        'scoreValue': clampedScore,
        'confidenceTier': tier,
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
          stock: stock,
        ),
      });
    }

    return items;
  }

  Future<void> _runNewVisualSearch(ImageSource source) async {
    if (_isSearchingAgain) return;

    final picked = await _visualSearchService.pickImageForSearch(source);
    if (picked == null || !mounted) return;

    setState(() {
      _isSearchingAgain = true;
      _loadingStepText = 'Extracting 2048-D visual features...';
      _queryImageBytes = picked.bytes;
    });

    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _isSearchingAgain) {
        setState(() {
          _loadingStepText = 'Searching catalog vectors & calibrating tiers...';
        });
      }
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

  Future<void> _runInlineRefinement({String? presetOverride}) async {
    if (_isSearchingAgain) return;
    if (presetOverride != null) {
      _refineController.text = presetOverride;
    }
    final q = _refineController.text.trim();
    if (_queryImageBytes == null && q.isEmpty && !_only3dRefine) return;

    setState(() {
      _isSearchingAgain = true;
      _loadingStepText =
          'Fusing photo vector + "$q" via Reciprocal Rank Fusion...';
    });

    try {
      final response = await _visualSearchService.searchMultimodal(
        imageBytes: _queryImageBytes,
        filename: 'query_photo.png',
        queryText: q.isEmpty ? null : q,
        only3d: _only3dRefine,
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
          content: Text('Refinement failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _dictateInlineRefinement() async {
    if (_isSearchingAgain) return;
    final voice = context.read<VoiceProvider>();
    final transcript = await voice.toggleRecordingAndTranscribe(
      context: context,
    );
    if (!mounted || transcript == null || transcript.trim().isEmpty) return;
    setState(() {
      _refineController.text = transcript.trim();
    });
    await _runInlineRefinement();
  }

  void _askCtrlXAboutPhoto(List<Map<String, dynamic>> items) {
    final category = _analysis['detected_category']?.toString().trim() ?? '';
    final modifier = _refineController.text.trim();
    String prompt;
    if (items.isNotEmpty) {
      final topNames = items
          .take(3)
          .map((m) {
            final p = m['product'] as Product;
            return '${p.name} (\$${p.price.toStringAsFixed(0)})';
          })
          .join(', ');
      prompt =
          'I just ran a visual photo search${category.isNotEmpty ? ' in $category' : ''}'
          '${modifier.isNotEmpty ? ' refined with "$modifier"' : ''}. '
          'Compare the closest catalog matches ($topNames) and recommend the best one based on real reviews and value.';
    } else {
      prompt =
          'I uploaded a photo to visual search${modifier.isNotEmpty ? ' looking for "$modifier"' : ''}, '
          'but no exact match was found. Help me find the closest available item in Penguin Store.';
    }
    context.push('/ctrlx?q=${Uri.encodeComponent(prompt)}');
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
                    'Auto-rotates EXIF orientation, composites transparent PNGs on white, and enhances blur.',
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
          'AI Visual & Multimodal Search',
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
              ? _buildNotInDatabaseState(theme, items)
              : CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          children: [
                            _buildAnalysisBanner(theme, items),
                            const SizedBox(height: 12),
                            _buildInlineRefineCard(theme, items),
                          ],
                        ),
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
            Text(
              _loadingStepText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ResNet-50 ONNX 2048-D cosine similarity + RRF calibration',
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

  Widget _buildAnalysisBanner(
    ThemeData theme,
    List<Map<String, dynamic>> items,
  ) {
    final bool wasDeblurred = _analysis['was_deblurred'] == true;
    final String? detectedCategory = _analysis['detected_category']?.toString();
    final dynamic searchTimeMs = _analysis['search_time_ms'];
    final bool isMultimodal = _analysis['search_mode'] == 'multimodal_rrf';
    final String? queryText = _analysis['query_text']?.toString().trim();
    final dynamic maxPriceCap = _analysis['max_price'];
    final bool only3dFilter = _analysis['only_3d'] == true;
    final String tier = (_analysis['confidence_tier'] ??
            (items.isNotEmpty ? items.first['confidenceTier'] : 'similar_style'))
        .toString();
    final String summaryText = (_analysis['search_summary'] ??
            _statusMessage ??
            'Found ${items.length} catalog matches.')
        .toString();

    final bool isClosestFallback = tier == 'closest_alternatives';
    final bool isStrong = tier == 'strong_match';

    final List<Color> bannerGradient = isClosestFallback
        ? [const Color(0xFF92400E), const Color(0xFFB45309)]
        : (isStrong
            ? [theme.primaryColor, const Color(0xFF0F766E)]
            : [theme.primaryColor, theme.colorScheme.tertiary]);

    final String headline = isClosestFallback
        ? 'Closest Catalog Alternatives'
        : (isMultimodal
            ? 'Multimodal AI Hybrid Match'
            : (isStrong ? 'Strong Visual Match' : 'Similar Styles in Stock'));

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: bannerGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: bannerGradient.first.withValues(alpha: 0.25),
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
                      color: Colors.white.withValues(alpha: 0.75),
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
                    color: Colors.white.withValues(alpha: 0.2),
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
                      headline,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      summaryText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isMultimodal)
                _buildInfoPill(
                  icon: Icons.merge_type_rounded,
                  label: 'RRF Hybrid Fusion',
                ),
              if (queryText != null && queryText.isNotEmpty)
                _buildInfoPill(
                  icon: Icons.tune_rounded,
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
              if (detectedCategory != null && detectedCategory.isNotEmpty)
                _buildInfoPill(
                  icon: Icons.category_outlined,
                  label: detectedCategory,
                ),
              if (searchTimeMs != null)
                _buildInfoPill(
                  icon: Icons.bolt_rounded,
                  label: '${searchTimeMs}ms',
                ),
              ActionChip(
                avatar: const Icon(Icons.auto_awesome_rounded, size: 15),
                label: const Text(
                  'Ask CTRL-X about this photo',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => _askCtrlXAboutPhoto(items),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInlineRefineCard(
    ThemeData theme,
    List<Map<String, dynamic>> items,
  ) {
    final colors = theme.colorScheme;
    final voice = context.watch<VoiceProvider>();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
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
              Icon(Icons.tune_rounded, size: 17, color: theme.primaryColor),
              const SizedBox(width: 6),
              Text(
                'Refine This Photo with Text or Voice',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _refineController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _runInlineRefinement(),
                  decoration: InputDecoration(
                    hintText:
                        'e.g. "black leather under \$150" or "with 3D model"',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    suffixIcon: IconButton(
                      tooltip: voice.isRecording
                          ? 'Stop recording'
                          : 'Speak refinement',
                      onPressed: _dictateInlineRefinement,
                      icon: voice.isTranscribing
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.primaryColor,
                              ),
                            )
                          : Icon(
                              voice.isRecording
                                  ? Icons.stop_circle_rounded
                                  : Icons.mic_none_rounded,
                              color: voice.isRecording
                                  ? colors.error
                                  : theme.primaryColor,
                              size: 20,
                            ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _runInlineRefinement(),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Refine',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Under \$150', style: TextStyle(fontSize: 11)),
                onPressed: () =>
                    _runInlineRefinement(presetOverride: 'under \$150'),
              ),
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Under \$300', style: TextStyle(fontSize: 11)),
                onPressed: () =>
                    _runInlineRefinement(presetOverride: 'under \$300'),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                selected: _only3dRefine,
                label: const Text('3D Twin Only', style: TextStyle(fontSize: 11)),
                onSelected: (v) {
                  setState(() => _only3dRefine = v);
                  _runInlineRefinement();
                },
              ),
            ],
          ),
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
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.24),
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

  Widget _buildNotInDatabaseState(
    ThemeData theme,
    List<Map<String, dynamic>> items,
  ) {
    final bool isBlank = _analysis['is_blank_or_noise'] == true;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_queryImageBytes != null) ...[
                      Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
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
                      const SizedBox(height: 16),
                    ],
                    Text(
                      isBlank
                          ? 'Unclear or Blank Photo'
                          : 'No Exact Match for Current Filters',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusMessage?.isNotEmpty == true
                          ? _statusMessage!
                          : 'Try relaxing your price filter, refining with text below, or uploading a clearer angle.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _showRescanSheet,
                            icon: const Icon(Icons.camera_alt_outlined, size: 17),
                            label: const Text('Try Another Photo'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _askCtrlXAboutPhoto(items),
                            icon: const Icon(
                              Icons.auto_awesome_outlined,
                              size: 16,
                            ),
                            label: const Text('Ask CTRL-X'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_queryImageBytes != null && !isBlank) ...[
                const SizedBox(height: 14),
                _buildInlineRefineCard(theme, items),
              ],
            ],
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
                final String tier = item['confidenceTier'] as String;
                final String matchLabel = item['matchLabel'] as String;
                final String matchReason =
                    (item['matchReason'] ?? '').toString().trim();

                final Color badgeAccent = tier == 'strong_match'
                    ? const Color(0xFF00E676)
                    : tier == 'similar_style'
                        ? Colors.cyanAccent
                        : Colors.amberAccent;

                final String topBadgeText = tier == 'closest_alternatives'
                    ? 'Closest Alt ($score%)'
                    : '$matchLabel • $score%';

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
                      left: 7,
                      child: IgnorePointer(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.84),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: badgeAccent.withValues(alpha: 0.6),
                                  width: 0.9,
                                ),
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
                                    topBadgeText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (matchReason.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: (itemWidth - 20).clamp(90.0, 185.0),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.78),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    matchReason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 9.2,
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
