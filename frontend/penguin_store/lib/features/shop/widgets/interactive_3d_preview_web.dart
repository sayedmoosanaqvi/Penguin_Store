import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'interactive_3d_preview.dart';

int _viewIdSeq = 0;

Widget buildGlbThumbnailStudio({
  required Uint8List glbBytes,
  required String fileName,
  required GlbStudioController controller,
  ValueChanged<Uint8List>? onThumbnailCaptured,
  ValueChanged<String>? onError,
  VoidCallback? onModelLoaded,
}) {
  return _WebGlbThumbnailStudio(
    glbBytes: glbBytes,
    fileName: fileName,
    controller: controller,
    onThumbnailCaptured: onThumbnailCaptured,
    onError: onError,
    onModelLoaded: onModelLoaded,
  );
}

Widget buildInline3DCardViewer({
  required String modelUrl,
  String? posterUrl,
  required String alt,
  VoidCallback? onModelLoaded,
}) {
  return _WebInline3DCardViewer(
    modelUrl: modelUrl,
    posterUrl: posterUrl,
    alt: alt,
    onModelLoaded: onModelLoaded,
  );
}

/// Builds a sleek icy-blue progress bar slotted inside `<model-viewer slot="progress-bar">`.
web.HTMLDivElement _createProgressBarSlot(web.HTMLElement mv) {
  final wrapper = web.document.createElement('div') as web.HTMLDivElement;
  wrapper.setAttribute('slot', 'progress-bar');
  wrapper.style
    ..position = 'absolute'
    ..left = '0'
    ..right = '0'
    ..bottom = '14px'
    ..display = 'flex'
    ..flexDirection = 'column'
    ..alignItems = 'center'
    ..pointerEvents = 'none'
    ..transition = 'opacity 0.25s ease';

  final track = web.document.createElement('div') as web.HTMLDivElement;
  track.style
    ..width = '64%'
    ..height = '5px'
    ..borderRadius = '999px'
    ..backgroundColor = 'rgba(15, 23, 42, 0.18)'
    ..overflow = 'hidden'
    ..backdropFilter = 'blur(4px)';

  final fill = web.document.createElement('div') as web.HTMLDivElement;
  fill.style
    ..width = '12%'
    ..height = '100%'
    ..borderRadius = '999px'
    ..background = 'linear-gradient(90deg, #1E88E5, #00ACC1)'
    ..transition = 'width 0.15s ease-out';

  track.appendChild(fill);
  wrapper.appendChild(track);

  mv.addEventListener(
    'progress',
    ((web.Event evt) {
      try {
        final detail = evt.getProperty<JSAny?>('detail'.toJS);
        if (detail != null && detail.isA<JSObject>()) {
          final obj = detail as JSObject;
          final raw = obj.getProperty<JSNumber?>('totalProgress'.toJS);
          if (raw != null) {
            final p = raw.toDartDouble.clamp(0.0, 1.0);
            fill.style.width = '${(p * 100).round()}%';
            if (p >= 0.999) {
              wrapper.style.opacity = '0';
            } else {
              wrapper.style.opacity = '1';
            }
          }
        }
      } catch (_) {}
    }).toJS,
  );

  return wrapper;
}

Future<Uint8List?> _captureModelViewerPng(web.HTMLElement mv) async {
  // Prefer official `<model-viewer>.toBlob({ mimeType: 'image/png', idealAspect: true })`
  try {
    if (mv.hasProperty('toBlob'.toJS).toDart) {
      final opts = <String, Object?>{
        'mimeType': 'image/png',
        'idealAspect': true,
      }.jsify();
      final promise = mv.callMethod<JSPromise<web.Blob>>('toBlob'.toJS, opts);
      final blob = await promise.toDart;
      final arrayBuffer = await blob.arrayBuffer().toDart;
      final bytes = arrayBuffer.toDart.asUint8List();
      if (bytes.isNotEmpty) {
        return Uint8List.fromList(bytes);
      }
    }
  } catch (_) {}

  // Fallback to `<model-viewer>.toDataURL('image/png')`
  try {
    if (mv.hasProperty('toDataURL'.toJS).toDart) {
      final dataUrl =
          mv.callMethod<JSString>('toDataURL'.toJS, 'image/png'.toJS).toDart;
      final commaIdx = dataUrl.indexOf(',');
      if (commaIdx != -1) {
        final decoded = base64Decode(dataUrl.substring(commaIdx + 1));
        if (decoded.isNotEmpty) return decoded;
      }
    }
  } catch (_) {}

  return null;
}

class _WebGlbThumbnailStudio extends StatefulWidget {
  final Uint8List glbBytes;
  final String fileName;
  final GlbStudioController controller;
  final ValueChanged<Uint8List>? onThumbnailCaptured;
  final ValueChanged<String>? onError;
  final VoidCallback? onModelLoaded;

  const _WebGlbThumbnailStudio({
    required this.glbBytes,
    required this.fileName,
    required this.controller,
    this.onThumbnailCaptured,
    this.onError,
    this.onModelLoaded,
  });

  @override
  State<_WebGlbThumbnailStudio> createState() => _WebGlbThumbnailStudioState();
}

class _WebGlbThumbnailStudioState extends State<_WebGlbThumbnailStudio> {
  late String _viewType;
  String? _blobUrl;
  web.HTMLElement? _mvElement;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  @override
  void didUpdateWidget(covariant _WebGlbThumbnailStudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.glbBytes, widget.glbBytes) ||
        oldWidget.fileName != widget.fileName) {
      _cleanupDom();
      _initViewer();
    }
  }

  void _initViewer() {
    final blob = web.Blob(
      <JSAny>[widget.glbBytes.toJS].toJS,
      web.BlobPropertyBag(type: 'model/gltf-binary'),
    );
    _blobUrl = web.URL.createObjectURL(blob);
    _viewType = 'penguin-admin-glb-studio-${++_viewIdSeq}';

    final mv = web.document.createElement('model-viewer') as web.HTMLElement;
    mv.setAttribute('src', _blobUrl!);
    mv.setAttribute('alt', widget.fileName);
    mv.setAttribute('camera-controls', '');
    mv.setAttribute('auto-rotate', '');
    mv.setAttribute('auto-rotate-delay', '1500');
    mv.setAttribute('rotation-per-second', '18deg');
    mv.setAttribute('shadow-intensity', '1');
    mv.setAttribute('shadow-softness', '0.9');
    mv.setAttribute('exposure', '1.08');
    mv.setAttribute('environment-image', 'neutral');
    mv.setAttribute('interaction-prompt', 'none');
    mv.setAttribute('loading', 'eager');
    mv.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..background = 'radial-gradient(circle at 50% 40%, #F4F9FF 0%, #D4E8FA 100%)';

    mv.appendChild(_createProgressBarSlot(mv));

    mv.addEventListener(
      'load',
      ((web.Event _) {
        if (_disposed) return;
        widget.onModelLoaded?.call();
        // Wait briefly for WebGL shading & shadow pass to settle before auto-capturing
        Future<void>.delayed(const Duration(milliseconds: 350), () async {
          if (_disposed || _mvElement == null) return;
          final png = await _captureModelViewerPng(_mvElement!);
          if (!_disposed && png != null && png.isNotEmpty) {
            widget.onThumbnailCaptured?.call(png);
          }
        });
      }).toJS,
    );

    mv.addEventListener(
      'error',
      ((web.Event _) {
        if (_disposed) return;
        widget.onError?.call('Could not render this GLB file in WebGL.');
      }).toJS,
    );

    _mvElement = mv;
    widget.controller.attach(() async {
      if (_disposed || _mvElement == null) return null;
      return _captureModelViewerPng(_mvElement!);
    });

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => mv,
    );
  }

  void _cleanupDom() {
    widget.controller.attach(null);
    if (_mvElement != null) {
      _mvElement!.removeAttribute('src');
      _mvElement = null;
    }
    if (_blobUrl != null) {
      web.URL.revokeObjectURL(_blobUrl!);
      _blobUrl = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cleanupDom();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      key: ValueKey(_viewType),
      viewType: _viewType,
    );
  }
}

class _WebInline3DCardViewer extends StatefulWidget {
  final String modelUrl;
  final String? posterUrl;
  final String alt;
  final VoidCallback? onModelLoaded;

  const _WebInline3DCardViewer({
    required this.modelUrl,
    this.posterUrl,
    required this.alt,
    this.onModelLoaded,
  });

  @override
  State<_WebInline3DCardViewer> createState() => _WebInline3DCardViewerState();
}

class _WebInline3DCardViewerState extends State<_WebInline3DCardViewer> {
  late String _viewType;
  web.HTMLElement? _mvElement;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  @override
  void didUpdateWidget(covariant _WebInline3DCardViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelUrl != widget.modelUrl) {
      _cleanupDom();
      _initViewer();
    }
  }

  void _initViewer() {
    _viewType = 'penguin-inline-3d-card-${++_viewIdSeq}';

    final mv = web.document.createElement('model-viewer') as web.HTMLElement;
    mv.setAttribute('src', widget.modelUrl);
    if (widget.posterUrl != null && widget.posterUrl!.isNotEmpty) {
      mv.setAttribute('poster', widget.posterUrl!);
    }
    mv.setAttribute('alt', widget.alt);
    mv.setAttribute('camera-controls', '');
    mv.setAttribute('auto-rotate', '');
    mv.setAttribute('auto-rotate-delay', '0');
    mv.setAttribute('rotation-per-second', '22deg');
    mv.setAttribute('shadow-intensity', '1');
    mv.setAttribute('shadow-softness', '0.9');
    mv.setAttribute('exposure', '1.08');
    mv.setAttribute('environment-image', 'neutral');
    mv.setAttribute('interaction-prompt', 'none');
    mv.setAttribute('loading', 'eager');
    mv.setAttribute('reveal', 'auto');
    mv.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..background = 'radial-gradient(circle at 50% 42%, #F4F9FF 0%, #D2E7FA 100%)';

    mv.appendChild(_createProgressBarSlot(mv));

    mv.addEventListener(
      'load',
      ((web.Event _) {
        if (!_disposed) {
          widget.onModelLoaded?.call();
        }
      }).toJS,
    );

    _mvElement = mv;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => mv,
    );
  }

  void _cleanupDom() {
    if (_mvElement != null) {
      // Immediately clear src so browser releases WebGL context cleanly
      _mvElement!.removeAttribute('src');
      _mvElement!.textContent = '';
      _mvElement = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cleanupDom();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      key: ValueKey(_viewType),
      viewType: _viewType,
    );
  }
}
