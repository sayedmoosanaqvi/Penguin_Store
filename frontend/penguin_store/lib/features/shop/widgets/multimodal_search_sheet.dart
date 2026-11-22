import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/features/shop/screens/visual_search_results_screen.dart';
import 'package:penguin_store/features/shop/services/visual_search_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

/// Opens the Hybrid Multimodal AI Search modal allowing users to combine an
/// optional photo (Camera/Gallery) with spoken or typed refinements (e.g.
/// "like this, under $250 with 3D model") powered by RRF fusion.
Future<void> showMultimodalSearchSheet(
  BuildContext context, {
  String initialQuery = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => MultimodalSearchSheet(initialQuery: initialQuery),
  );
}

class MultimodalSearchSheet extends StatefulWidget {
  final String initialQuery;

  const MultimodalSearchSheet({
    super.key,
    this.initialQuery = '',
  });

  @override
  State<MultimodalSearchSheet> createState() => _MultimodalSearchSheetState();
}

class _MultimodalSearchSheetState extends State<MultimodalSearchSheet> {
  final VisualSearchService _visualSearchService = VisualSearchService();
  late final TextEditingController _queryController;
  final TextEditingController _maxPriceController = TextEditingController();

  PickedSearchImage? _selectedImage;
  bool _only3d = false;
  bool _isSearching = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _queryController.dispose();
    _maxPriceController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_isSearching) return;
    final picked = await _visualSearchService.pickImageForSearch(source);
    if (!mounted || picked == null) return;
    setState(() {
      _selectedImage = picked;
      _inlineError = null;
    });
  }

  Future<void> _dictateModifier() async {
    if (_isSearching) return;
    final voice = context.read<VoiceProvider>();
    final transcript = await voice.toggleRecordingAndTranscribe(
      context: context,
    );
    if (!mounted || transcript == null || transcript.trim().isEmpty) return;

    final existing = _queryController.text.trim();
    setState(() {
      _queryController.text = existing.isEmpty
          ? transcript.trim()
          : '$existing ${transcript.trim()}';
      _inlineError = null;
    });
  }

  void _applyQuickPreset(String snippet, {double? maxPrice, bool? only3d}) {
    setState(() {
      if (maxPrice != null) {
        _maxPriceController.text = maxPrice.toStringAsFixed(0);
      }
      if (only3d != null) {
        _only3d = only3d;
      }
      if (snippet.isNotEmpty) {
        final cur = _queryController.text.trim();
        if (!cur.toLowerCase().contains(snippet.toLowerCase())) {
          _queryController.text = cur.isEmpty ? snippet : '$cur $snippet';
        }
      }
      _inlineError = null;
    });
  }

  Future<void> _runMultimodalSearch() async {
    final queryText = _queryController.text.trim();
    final double? maxPrice = double.tryParse(_maxPriceController.text.trim());

    if (_selectedImage == null && queryText.isEmpty) {
      setState(() {
        _inlineError =
            'Please upload a photo, speak a query, or type what you are looking for.';
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _inlineError = null;
    });

    final VisualSearchResponse response =
        await _visualSearchService.searchMultimodal(
      imageBytes: _selectedImage?.bytes,
      filename: _selectedImage?.filename ?? 'upload.png',
      queryText: queryText.isEmpty ? null : queryText,
      maxPrice: maxPrice,
      only3d: _only3d,
    );

    if (!mounted) return;

    setState(() => _isSearching = false);

    if (response.isError) {
      setState(() => _inlineError = response.message);
      CustomToast.show(context, response.message, isError: true);
      return;
    }

    final Uint8List? previewBytes = _selectedImage?.bytes;
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VisualSearchResultsScreen(
          matches: response.matches,
          queryImageBytes: previewBytes,
          analysis: response.analysis,
          statusMessage: response.message,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final voice = context.watch<VoiceProvider>();
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, bottomInset + 22),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colors.primary, colors.tertiary],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Multimodal AI Search (RRF Hybrid)',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      Text(
                        'Combine a photo + spoken or typed modifiers (price, category, 3D).',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Image attachment row
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _selectedImage != null
                      ? colors.primary.withValues(alpha: 0.5)
                      : colors.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  if (_selectedImage != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        _selectedImage!.bytes,
                        width: 58,
                        height: 58,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedImage!.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Visual vector ready for RRF ranking',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove photo',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: _isSearching
                          ? null
                          : () => setState(() => _selectedImage = null),
                    ),
                  ] else ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSearching
                            ? null
                            : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt_outlined, size: 18),
                        label: const Text('Take Photo'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSearching
                            ? null
                            : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined, size: 18),
                        label: const Text('Upload Image'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Voice + Text modifier input
            TextField(
              controller: _queryController,
              enabled: !_isSearching,
              onSubmitted: (_) => _runMultimodalSearch(),
              decoration: InputDecoration(
                labelText: 'Voice or Text Modifier',
                hintText: 'e.g. "similar sneakers under \$200 with 3D model"',
                prefixIcon: const Icon(Icons.tune_rounded, size: 20),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_queryController.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear text',
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _queryController.clear();
                          setState(() {});
                        },
                      ),
                    IconButton(
                      tooltip: voice.isRecording
                          ? 'Tap to stop recording'
                          : 'Speak search modifier',
                      onPressed: _isSearching ? null : _dictateModifier,
                      icon: voice.isTranscribing
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.primary,
                              ),
                            )
                          : Icon(
                              voice.isRecording
                                  ? Icons.stop_circle_rounded
                                  : Icons.mic_rounded,
                              color: voice.isRecording
                                  ? colors.error
                                  : colors.primary,
                            ),
                    ),
                  ],
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (voice.isRecording) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, size: 16, color: colors.error),
                  const SizedBox(width: 6),
                  Text(
                    'Listening via microphone... tap the stop icon when done.',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),

            // Price & 3D quick filters
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxPriceController,
                    enabled: !_isSearching,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Max Price (USD)',
                      hintText: 'e.g. 250',
                      isDense: true,
                      prefixIcon: const Icon(Icons.attach_money_rounded, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilterChip(
                  selected: _only3d,
                  label: const Text('3D Only'),
                  avatar: Icon(
                    Icons.view_in_ar_rounded,
                    size: 16,
                    color: _only3d ? colors.onPrimaryContainer : colors.primary,
                  ),
                  onSelected: _isSearching
                      ? null
                      : (v) => setState(() => _only3d = v),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('Under \$150'),
                  onPressed: () => _applyQuickPreset('under \$150', maxPrice: 150),
                ),
                ActionChip(
                  label: const Text('Under \$300'),
                  onPressed: () => _applyQuickPreset('under \$300', maxPrice: 300),
                ),
                ActionChip(
                  label: const Text('3D Twin Ready'),
                  onPressed: () => _applyQuickPreset('with 3D view', only3d: true),
                ),
              ],
            ),

            if (_inlineError != null) ...[
              const SizedBox(height: 10),
              Text(
                _inlineError!,
                style: TextStyle(
                  color: colors.error,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _isSearching ? null : _runMultimodalSearch,
                icon: _isSearching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.search_rounded),
                label: Text(
                  _isSearching
                      ? 'Fusing Visual & Semantic Ranks...'
                      : 'Search Hybrid Catalog',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
