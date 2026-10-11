
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

class Product3DViewerScreen extends StatelessWidget {
  final String productName;
  final String modelUrl;

  const Product3DViewerScreen({
    super.key,
    required this.productName,
    required this.modelUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          productName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.view_in_ar_rounded,
                          color: theme.primaryColor,
                          size: 25,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Interactive 3D Experience',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Explore your product from every angle.',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: isDark
                          ? theme.colorScheme.surface
                          : const Color(0xFFF5F8FC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.primaryColor.withValues(alpha: 0.12),
                      ),
                    ),
                    child: ModelViewer(
                      key: ValueKey(modelUrl),
                      src: modelUrl,
                      alt: 'Interactive 3D model of $productName',
                      cameraControls: true,
                      autoRotate: true,
                      autoRotateDelay: 1000,
                      rotationPerSecond: '20deg',
                      shadowIntensity: 0.8,
                      exposure: 1,
                      environmentImage: 'neutral',
                      backgroundColor: Colors.transparent,
                      disableZoom: false,
                      interactionPrompt: InteractionPrompt.auto,
                      loading: Loading.eager,
                      reveal: Reveal.auto,
                      ar: false,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _controlHint(
                        Icons.threed_rotation_rounded,
                        'Rotate',
                        theme,
                      ),
                      const SizedBox(width: 22),
                      _controlHint(
                        Icons.zoom_in_rounded,
                        'Zoom',
                        theme,
                      ),
                      const SizedBox(width: 22),
                      _controlHint(
                        Icons.touch_app_outlined,
                        'Interact',
                        theme,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlHint(
    IconData icon,
    String label,
    ThemeData theme,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          color: theme.primaryColor,
          size: 17,
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
