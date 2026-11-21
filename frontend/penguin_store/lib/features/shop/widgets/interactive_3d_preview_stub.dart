import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import 'interactive_3d_preview.dart';

Widget buildGlbThumbnailStudio({
  required Uint8List glbBytes,
  required String fileName,
  required GlbStudioController controller,
  ValueChanged<Uint8List>? onThumbnailCaptured,
  ValueChanged<String>? onError,
  VoidCallback? onModelLoaded,
}) {
  return Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xFFEBF4FF), Color(0xFFD2E7FA)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.view_in_ar_rounded,
              size: 48,
              color: Color(0xFF1E88E5),
            ),
            const SizedBox(height: 10),
            Text(
              fileName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(glbBytes.lengthInBytes / (1024 * 1024)).toStringAsFixed(2)} MB GLB ready · Server auto-poster active if no photo is added',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF475569),
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget buildInline3DCardViewer({
  required String modelUrl,
  String? posterUrl,
  required String alt,
  VoidCallback? onModelLoaded,
}) {
  return ModelViewer(
    src: modelUrl,
    poster: posterUrl,
    alt: alt,
    backgroundColor: const Color(0xFFEAF4FE),
    cameraControls: true,
    autoRotate: true,
    autoRotateDelay: 0,
    shadowIntensity: 1,
    disableZoom: false,
    ar: false,
  );
}

Widget buildRemoteGlbStudio({
  required String modelUrl,
  required String productName,
  required GlbStudioController controller,
  ValueChanged<Uint8List>? onThumbnailCaptured,
  ValueChanged<String>? onError,
  VoidCallback? onModelLoaded,
}) {
  return ModelViewer(
    src: modelUrl,
    alt: productName,
    backgroundColor: const Color(0xFFEAF4FE),
    cameraControls: true,
    autoRotate: true,
    shadowIntensity: 1,
  );
}
