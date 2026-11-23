import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';

/// Unified Studio Product Card Image Framing (Phase 1.1).
///
/// Standardizes every product image across the app (API products, admin-uploaded
/// photos, and 3D studio renders):
/// - Clean studio radial-gradient backdrop that adapts automatically to Light & Dark mode
/// - `BoxFit.contain` with uniform inner padding (`12px` default)
/// - Soft drop shadow and subtle hover/tap zoom (`1.04x`)
/// - Automatic proxy fallback for legacy S3 / cross-origin image URLs
class StudioProductImage extends StatefulWidget {
  final int productId;
  final String imageUrl;
  final double padding;
  final BorderRadius? borderRadius;
  final bool isHovered;
  final BoxFit fit;

  const StudioProductImage({
    super.key,
    required this.productId,
    required this.imageUrl,
    this.padding = 12.0,
    this.borderRadius,
    this.isHovered = false,
    this.fit = BoxFit.contain,
  });

  @override
  State<StudioProductImage> createState() => _StudioProductImageState();
}

class _StudioProductImageState extends State<StudioProductImage> {
  bool _useProxyFallback = false;

  @override
  void didUpdateWidget(covariant StudioProductImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.productId != widget.productId) {
      _useProxyFallback = false;
    }
  }

  String _resolvedUrl() {
    final trimmed = Product.resolveImageUrl(widget.imageUrl);
    final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

    if (_useProxyFallback || trimmed.isEmpty) {
      if (widget.productId > 0) {
        return '$base/api/search/image-proxy?product_id=${widget.productId}'
            '${trimmed.isNotEmpty ? '&url=${Uri.encodeComponent(trimmed)}' : ''}';
      }
      if (trimmed.isNotEmpty) {
        return '$base/api/search/image-proxy?url=${Uri.encodeComponent(trimmed)}';
      }
      return '';
    }

    if (kIsWeb && trimmed.contains('penguin-store-assets-v1.s3')) {
      return '$base/api/search/image-proxy?product_id=${widget.productId}&url=${Uri.encodeComponent(trimmed)}';
    }

    return trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final targetUrl = _resolvedUrl();

    Widget content;
    if (targetUrl.isEmpty) {
      content = _buildFallback(theme, isDark);
    } else {
      content = AnimatedScale(
        scale: widget.isHovered ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: Padding(
          padding: EdgeInsets.all(widget.padding),
          child: CachedNetworkImage(
            imageUrl: targetUrl,
            key: ValueKey(targetUrl),
            width: double.infinity,
            height: double.infinity,
            fit: widget.fit,
            fadeInDuration: const Duration(milliseconds: 180),
            placeholder: (_, _) => _buildShimmer(isDark),
            errorWidget: (_, _, _) {
              if (!_useProxyFallback &&
                  (widget.productId > 0 ||
                      widget.imageUrl.trim().isNotEmpty)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_useProxyFallback) {
                    setState(() => _useProxyFallback = true);
                  }
                });
                return _buildShimmer(isDark);
              }
              return _buildFallback(theme, isDark);
            },
          ),
        ),
      );
    }

    final studioContainer = Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        gradient: RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 0.92,
          colors: isDark
              ? const [Color(0xFF1E293B), Color(0xFF0F172A)]
              : const [Color(0xFFFFFFFF), Color(0xFFF8FAFC)],
        ),
      ),
      child: content,
    );

    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: studioContainer,
      );
    }
    return studioContainer;
  }

  Widget _buildShimmer(bool isDark) {
    return Shimmer.fromColors(
      baseColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2ECF7),
      highlightColor:
          isDark ? const Color(0xFF334155) : const Color(0xFFF8FBFF),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  Widget _buildFallback(ThemeData theme, bool isDark) {
    return Center(
      child: Icon(
        Icons.inventory_2_outlined,
        color: theme.colorScheme.primary.withValues(alpha: isDark ? 0.55 : 0.45),
        size: 32,
      ),
    );
  }
}
