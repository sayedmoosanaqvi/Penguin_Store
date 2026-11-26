import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';
import 'package:penguin_store/features/shop/widgets/voice_concierge_overlay.dart';

/// Shared responsive search bar with:
/// - 300ms debounced `onChanged` + live hybrid backend suggestions
/// - `onSubmitted` (Enter key) + clickable Search icon button
/// - Live suggestion rows (studio thumbnail, title, category, formatted price, 3D badge)
/// - Non-overlapping Voice Mic, Voice AI pill, and Visual Search camera triggers
class PenguinSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback onClear;
  final VoidCallback onVoiceTap;
  final VoidCallback onVisualSearchTap;
  final bool visualSearchLoading;
  final bool showDiscoverShortcut;

  const PenguinSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.onQueryChanged,
    required this.onSearchSubmitted,
    required this.onClear,
    required this.onVoiceTap,
    required this.onVisualSearchTap,
    this.visualSearchLoading = false,
    this.showDiscoverShortcut = true,
  });

  @override
  State<PenguinSearchBar> createState() => _PenguinSearchBarState();
}

class _PenguinSearchBarState extends State<PenguinSearchBar> {
  Timer? _debounce;
  List<Product> _remoteMatches = const [];
  bool _isSearchingBackend = false;
  String _lastFetchedQuery = '';

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _handleTextChanged(String raw) {
    final trimmed = raw.trim();
    widget.onQueryChanged(trimmed);

    _debounce?.cancel();
    if (trimmed.isEmpty) {
      if (_remoteMatches.isNotEmpty || _isSearchingBackend) {
        setState(() {
          _remoteMatches = const [];
          _isSearchingBackend = false;
          _lastFetchedQuery = '';
        });
      }
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _fetchHybridSuggestions(trimmed);
    });
  }

  Future<void> _fetchHybridSuggestions(String q) async {
    if (q.isEmpty || q == _lastFetchedQuery) return;
    setState(() => _isSearchingBackend = true);
    try {
      final results = await context
          .read<ProductProvider>()
          .searchCatalog(q);
      if (!mounted || widget.query.trim() != q) return;
      setState(() {
        _remoteMatches = results;
        _lastFetchedQuery = q;
        _isSearchingBackend = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isSearchingBackend = false);
    }
  }

  void _triggerSubmit() {
    final val = widget.controller.text.trim();
    if (val.length >= 2) {
      context.read<ShopStateProvider>().addSearchTerm(val);
    }
    widget.focusNode.unfocus();
    widget.onSearchSubmitted(val);
  }

  List<Product> _mergedSuggestions(List<Product> inMemoryProducts) {
    final q = widget.query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final byId = <int, Product>{};

    // 1. Instant in-memory matches
    for (final p in inMemoryProducts) {
      final hay = '${p.name} ${p.category} ${p.description}'.toLowerCase();
      if (words.every((w) => hay.contains(w))) {
        byId[p.id] = p;
      }
      if (byId.length >= 6) break;
    }

    // 2. Deep backend hybrid/semantic matches
    for (final p in _remoteMatches) {
      byId.putIfAbsent(p.id, () => p);
      if (byId.length >= 6) break;
    }

    return byId.values.take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 430;

    final shopState = context.watch<ShopStateProvider>();
    final provider = context.watch<ProductProvider>();
    final currency = context.watch<CurrencyProvider>();
    final recentTerms = shopState.recentSearches;
    final suggestions = _mergedSuggestions(provider.products);
    final ids3d = Catalog3D.ids.value;

    final hasQuery = widget.query.trim().isNotEmpty;
    final showDropdown = widget.focusNode.hasFocus &&
        (hasQuery || recentTerms.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: widget.focusNode.hasFocus
                  ? theme.primaryColor
                  : theme.primaryColor.withValues(alpha: 0.22),
              width: widget.focusNode.hasFocus ? 1.5 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.14 : 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Search Products',
                onPressed: _triggerSubmit,
                visualDensity: VisualDensity.compact,
                icon: _isSearchingBackend
                    ? SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.primaryColor,
                        ),
                      )
                    : Icon(
                        Icons.search_rounded,
                        color: theme.primaryColor,
                        size: 21,
                      ),
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  textInputAction: TextInputAction.search,
                  onChanged: _handleTextChanged,
                  onSubmitted: (_) => _triggerSubmit(),
                  style: TextStyle(
                    fontSize: 13.5,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: isNarrow
                        ? 'Search products, 3D models...'
                        : "Search products or ask AI: 'Headphones under \$350'...",
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              if (hasQuery)
                IconButton(
                  tooltip: 'Clear search',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    _debounce?.cancel();
                    setState(() {
                      _remoteMatches = const [];
                      _lastFetchedQuery = '';
                      _isSearchingBackend = false;
                    });
                    widget.onClear();
                  },
                ),
              if (hasQuery && !isNarrow)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    onPressed: _triggerSubmit,
                    child: const Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              Consumer<VoiceProvider>(
                builder: (context, voice, _) {
                  return IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: voice.isRecording
                        ? 'Stop recording'
                        : 'Voice Search (Whisper STT)',
                    onPressed: widget.onVoiceTap,
                    icon: voice.isTranscribing
                        ? SizedBox(
                            width: 17,
                            height: 17,
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
                                ? theme.colorScheme.error
                                : theme.primaryColor,
                            size: 20,
                          ),
                  );
                },
              ),
              if (!isNarrow)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => GlobalVoiceOverlay.openConcierge(
                      initialQuery: hasQuery ? widget.query.trim() : null,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF0D47A1),
                            Color(0xFF1E88E5),
                            Color(0xFF00ACC1),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.graphic_eq_rounded,
                            color: Colors.white,
                            size: 13,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Voice AI',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Container(
                height: 22,
                width: 1,
                color: theme.dividerColor.withValues(alpha: 0.3),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'AI Visual & Multimodal Search',
                onPressed:
                    widget.visualSearchLoading ? null : widget.onVisualSearchTap,
                icon: Icon(
                  Icons.camera_alt_outlined,
                  color: theme.primaryColor,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
        Consumer<VoiceProvider>(
          builder: (context, voice, _) {
            if (voice.isRecording) {
              final lvl = voice.micLevel.clamp(0.08, 1.0);
              const weights = [0.45, 0.80, 1.0, 0.75, 0.50];
              return Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 18,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: weights.map((w) {
                          final barH = (4.0 + 14.0 * lvl * w).clamp(4.0, 18.0);
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 85),
                            width: 3.2,
                            height: barH,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.error,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Listening (16 kHz Whisper v3)... Speak clearly, then tap stop.',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: widget.onVoiceTap,
                      child: const Text('Done'),
                    ),
                  ],
                ),
              );
            }

            final heard = voice.lastHeardTranscript?.trim() ?? '';
            if (heard.isNotEmpty &&
                widget.query.trim().toLowerCase() == heard.toLowerCase()) {
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.55,
                        ),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: theme.primaryColor.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            voice.wasLastTranscriptRepaired
                                ? Icons.auto_fix_high_rounded
                                : Icons.mic_rounded,
                            size: 13,
                            color: theme.primaryColor,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Heard: "$heard"${voice.wasLastTranscriptRepaired ? ' (Smart-matched)' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              widget.focusNode.requestFocus();
                              widget.controller.selection = TextSelection(
                                baseOffset: 0,
                                extentOffset: widget.controller.text.length,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              child: Text(
                                'Edit',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: theme.primaryColor,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: voice.dismissLastHeard,
                            child: Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            return const SizedBox.shrink();
          },
        ),
        if (showDropdown)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.primaryColor.withValues(alpha: 0.22),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!hasQuery && recentTerms.isNotEmpty) ...[
                  Text(
                    'Recent Searches',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: recentTerms.map((term) {
                      return InputChip(
                        label: Text(term, style: const TextStyle(fontSize: 11.5)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          widget.controller.text = term;
                          widget.onQueryChanged(term);
                          widget.focusNode.unfocus();
                          widget.onSearchSubmitted(term);
                        },
                        onDeleted: () => shopState.removeSearchTerm(term),
                      );
                    }).toList(),
                  ),
                ],
                if (hasQuery) ...[
                  Row(
                    children: [
                      Text(
                        suggestions.isEmpty
                            ? (_isSearchingBackend
                                ? 'Searching catalog...'
                                : 'No direct matches for "${widget.query.trim()}"')
                            : 'Live Matches (${suggestions.length})',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      if (widget.showDiscoverShortcut)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: () {
                            final q = widget.query.trim();
                            shopState.addSearchTerm(q);
                            widget.focusNode.unfocus();
                            context.go(
                              '/discover?q=${Uri.encodeComponent(q)}',
                            );
                          },
                          icon: const Icon(Icons.open_in_new_rounded, size: 14),
                          label: const Text(
                            'Open in Discover',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    ...suggestions.map((p) {
                      final is3d = ids3d.contains(p.id);
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          shopState.addSearchTerm(widget.query.trim());
                          widget.focusNode.unfocus();
                          context.push('/product/${p.id}');
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 5,
                            horizontal: 4,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 42,
                                height: 42,
                                child: StudioProductImage(
                                  productId: p.id,
                                  imageUrl: p.imageUrl,
                                  borderRadius: BorderRadius.circular(9),
                                  padding: 4,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            p.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: theme.colorScheme.onSurface,
                                            ),
                                          ),
                                        ),
                                        if (is3d) ...[
                                          const SizedBox(width: 6),
                                          const Badge3D(compact: true),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      p.category,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                currency.format(p.price),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: theme.primaryColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ] else if (!_isSearchingBackend) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          final q = widget.query.trim();
                          widget.focusNode.unfocus();
                          context.push('/ctrlx?q=${Uri.encodeComponent(q)}');
                        },
                        icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                        label: Text(
                          'Ask CTRL-X AI to find "${widget.query.trim()}"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
      ],
    );
  }
}
