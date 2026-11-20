import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'interactive_3d_preview_stub.dart'
    if (dart.library.js_interop) 'interactive_3d_preview_web.dart' as impl;

/// Controller for [GlbThumbnailStudioWidget] allowing the Admin to re-capture
/// a studio-lit PNG snapshot from whichever camera angle they orbited to.
class GlbStudioController {
  Future<Uint8List?> Function()? _captureHandler;

  bool get isAttached => _captureHandler != null;

  void attach(Future<Uint8List?> Function()? handler) {
    _captureHandler = handler;
  }

  /// Captures a PNG screenshot directly from the mounted `<model-viewer>`.
  Future<Uint8List?> captureCurrentAngle() async {
    final handler = _captureHandler;
    if (handler == null) return null;
    return handler();
  }
}

/// Live interactive `<model-viewer>` box for the Admin Studio form.
/// Renders local `.glb` bytes immediately and auto-captures a crisp studio PNG
/// thumbnail once the `load` event fires.
class GlbThumbnailStudioWidget extends StatelessWidget {
  final Uint8List glbBytes;
  final String fileName;
  final GlbStudioController controller;
  final ValueChanged<Uint8List>? onThumbnailCaptured;
  final ValueChanged<String>? onError;
  final VoidCallback? onModelLoaded;

  const GlbThumbnailStudioWidget({
    super.key,
    required this.glbBytes,
    required this.fileName,
    required this.controller,
    this.onThumbnailCaptured,
    this.onError,
    this.onModelLoaded,
  });

  @override
  Widget build(BuildContext context) {
    return impl.buildGlbThumbnailStudio(
      glbBytes: glbBytes,
      fileName: fileName,
      controller: controller,
      onThumbnailCaptured: onThumbnailCaptured,
      onError: onError,
      onModelLoaded: onModelLoaded,
    );
  }
}

/// Sketchfab-style live interactive `<model-viewer>` mounted directly inside a
/// 3D Showcase card with `camera-controls`, `auto-rotate`, `shadow-intensity="1"`,
/// and a sleek custom `slot="progress-bar"`.
class Inline3DCardViewer extends StatelessWidget {
  final String modelUrl;
  final String? posterUrl;
  final String alt;
  final VoidCallback? onModelLoaded;

  const Inline3DCardViewer({
    super.key,
    required this.modelUrl,
    this.posterUrl,
    this.alt = 'Interactive 3D Product Preview',
    this.onModelLoaded,
  });

  @override
  Widget build(BuildContext context) {
    return impl.buildInline3DCardViewer(
      modelUrl: modelUrl,
      posterUrl: posterUrl,
      alt: alt,
      onModelLoaded: onModelLoaded,
    );
  }
}
