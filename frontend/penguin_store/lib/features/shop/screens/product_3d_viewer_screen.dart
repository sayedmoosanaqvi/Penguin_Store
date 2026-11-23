import 'package:flutter/material.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/services/premium_3d_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/interactive_3d_preview.dart';

enum _ViewerBackdrop { ice, studio, night }

/// Interactive 3D viewer.
///
/// Keeps the original `productName` + `modelUrl` contract (admin preview and
/// product details still call it that way) and adds optional extras:
/// a poster image shown while the GLB streams in, variant switching,
/// auto-rotate and background presets.
class Product3DViewerScreen extends StatefulWidget {
  final String productName;
  final String modelUrl;
  final String? posterUrl;
  final int? productId;
  final List<Product3DModel> models;
  final int? currentModelId;

  const Product3DViewerScreen({
    super.key,
    required this.productName,
    required this.modelUrl,
    this.posterUrl,
    this.productId,
    this.models = const [],
    this.currentModelId,
  });

  @override
  State<Product3DViewerScreen> createState() => _Product3DViewerScreenState();
}

class _Product3DViewerScreenState extends State<Product3DViewerScreen> {
  late String _modelUrl = widget.modelUrl;
  late int? _modelId = widget.currentModelId;

  bool _autoRotate = true;
  bool _switching = false;
  int _viewerGeneration = 0;
  _ViewerBackdrop _backdrop = _ViewerBackdrop.ice;

  List<Color> get _backdropColors {
    switch (_backdrop) {
      case _ViewerBackdrop.ice:
        return const [Color(0xFFEAF5FF), Color(0xFFBFDDF7)];
      case _ViewerBackdrop.studio:
        return const [Color(0xFFF7F7F9), Color(0xFFD9DCE3)];
      case _ViewerBackdrop.night:
        return const [Color(0xFF0E1B2E), Color(0xFF1B3556)];
    }
  }

  bool get _darkBackdrop => _backdrop == _ViewerBackdrop.night;

  Future<void> _switchVariant(Product3DModel model) async {
    final productId = widget.productId;
    if (productId == null || model.id == _modelId || _switching) return;

    setState(() => _switching = true);

    try {
      final url = await Showcase3DService().fetchModelUrl(productId, model.id);
      if (!mounted) return;
      setState(() {
        _modelUrl = url;
        _modelId = model.id;
        _viewerGeneration++;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = _darkBackdrop ? Colors.white : const Color(0xFF16324F);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: _backdropColors.last,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: fg,
        centerTitle: true,
        title: Text(
          widget.productName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: fg,
          ),
        ),
        actions: [
          IconButton(
            tooltip: _autoRotate ? 'Pause rotation' : 'Auto-rotate',
            onPressed: () => setState(() {
              _autoRotate = !_autoRotate;
              _viewerGeneration++;
            }),
            icon: Icon(
              _autoRotate
                  ? Icons.pause_circle_outline_rounded
                  : Icons.threed_rotation_rounded,
            ),
          ),
        ],
      ),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _backdropColors,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SnowfallBackground(
          flakes: 22,
          color: _darkBackdrop ? Colors.white : const Color(0xFF9CC9F2),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                              child: Inline3DCardViewer(
                                key: ValueKey('$_modelUrl#$_viewerGeneration'),
                                modelUrl: _modelUrl,
                                posterUrl: widget.posterUrl,
                                alt:
                                    'Interactive 3D model of ${widget.productName}',
                              ),
                            ),
                          ),
                          if (_switching)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Color(0x33000000),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 14,
                            top: 64,
                            child: FadeSlideIn(
                              delay: const Duration(milliseconds: 300),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.bolt_rounded,
                                        size: 13, color: Color(0xFF1E88E5)),
                                    SizedBox(width: 4),
                                    Text(
                                      'Optimised  •  512px textures',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF16324F),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.models.length > 1)
                      SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          itemCount: widget.models.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final m = widget.models[i];
                            final selected = m.id == _modelId;
                            return ChoiceChip(
                              label: Text(
                                m.variantName?.isNotEmpty == true
                                    ? m.variantName!
                                    : m.displayName,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: selected ? Colors.white : fg,
                                ),
                              ),
                              selected: selected,
                              showCheckmark: false,
                              selectedColor: theme.primaryColor,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.25),
                              onSelected: (_) => _switchVariant(m),
                            );
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _hint(Icons.threed_rotation_rounded, 'Drag to rotate', fg),
                          _hint(Icons.pinch_rounded, 'Pinch to zoom', fg),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: _ViewerBackdrop.values.map((b) {
                              final selected = _backdrop == b;
                              return GestureDetector(
                                onTap: () => setState(() {
                                  _backdrop = b;
                                }),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  margin: const EdgeInsets.only(left: 8),
                                  width: selected ? 26 : 22,
                                  height: selected ? 26 : 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: switch (b) {
                                        _ViewerBackdrop.ice => const [
                                            Color(0xFFEAF5FF),
                                            Color(0xFF8CC4F2)
                                          ],
                                        _ViewerBackdrop.studio => const [
                                            Colors.white,
                                            Color(0xFFBFC4CF)
                                          ],
                                        _ViewerBackdrop.night => const [
                                            Color(0xFF1B3556),
                                            Color(0xFF0E1B2E)
                                          ],
                                      },
                                    ),
                                    border: Border.all(
                                      color: selected
                                          ? theme.primaryColor
                                          : Colors.white,
                                      width: selected ? 2.4 : 1.4,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hint(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color.withValues(alpha: 0.8), size: 16),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: color.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}
