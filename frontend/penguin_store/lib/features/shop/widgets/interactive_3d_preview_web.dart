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

/// Global Singleton Active 3D WebGL Viewer Manager.
/// Enforces that AT MOST ONE `<model-viewer>` DOM element exists in the entire document
/// at any time, preventing WebGL context loss ("too many active WebGL contexts") and
/// CanvasKit shader compilation blackouts.
class Global3DViewerManager {
  static web.HTMLElement? _activeElement;
  static String? _activeViewType;
  static VoidCallback? _activeDisposer;

  /// Returns the viewType of the currently mounted viewer, if any.
  static String? get activeViewType => _activeViewType;

  /// Acquires the singleton active viewer lock. Immediately and aggressively tears down
  /// any previously active `<model-viewer>` before mounting the new one.
  static void acquireViewer({
    required String viewType,
    required web.HTMLElement element,
    VoidCallback? onEvicted,
  }) {
    if (_activeElement != null && _activeElement != element) {
      releaseActiveViewer();
    }
    _activeElement = element;
    _activeViewType = viewType;
    _activeDisposer = onEvicted;

    _cleanupOrphanDomViewers(keepElement: element);
  }

  /// Explicitly tears down the active `<model-viewer>`, blanking `src = ""`, removing
  /// it from the DOM, and freeing GPU memory & WebGL context.
  static void releaseActiveViewer({web.HTMLElement? element}) {
    if (element != null && _activeElement != element) {
      _destroyElement(element);
      return;
    }

    if (_activeElement != null) {
      _activeDisposer?.call();
      _destroyElement(_activeElement!);
      _activeElement = null;
      _activeViewType = null;
      _activeDisposer = null;
    }
    _cleanupOrphanDomViewers();
  }

  static void _destroyElement(web.HTMLElement el) {
    try {
      el.setAttribute('src', '');
      el.removeAttribute('src');
      el.textContent = '';
      if (el.parentNode != null) {
        el.remove();
      }
    } catch (_) {}
  }

  static void _cleanupOrphanDomViewers({web.HTMLElement? keepElement}) {
    try {
      final nodes = web.document.querySelectorAll('model-viewer');
      for (var i = 0; i < nodes.length; i++) {
        final node = nodes.item(i);
        if (node != null && node != keepElement) {
          final el = node as web.HTMLElement;
          _destroyElement(el);
        }
      }
    } catch (_) {}
  }
}

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

Widget buildRemoteGlbStudio({
  required String modelUrl,
  required String productName,
  required GlbStudioController controller,
  ValueChanged<Uint8List>? onThumbnailCaptured,
  ValueChanged<String>? onError,
  VoidCallback? onModelLoaded,
}) {
  return _WebRemoteGlbStudio(
    modelUrl: modelUrl,
    productName: productName,
    controller: controller,
    onThumbnailCaptured: onThumbnailCaptured,
    onError: onError,
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
    ..overflow = 'hidden';

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

/// Strict 8-second timeout-safe 3D Auto-Thumbnail capture.
Future<Uint8List?> _captureModelViewerPng(web.HTMLElement mv) async {
  try {
    return await Future<Uint8List?>.sync(() async {
      // 1. Prefer `<model-viewer>.toBlob({ mimeType: 'image/png', idealAspect: true })`
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

      // 2. Fallback to `<model-viewer>.toDataURL('image/png')`
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
    }).timeout(const Duration(seconds: 8));
  } catch (e) {
    debugPrint('[3D Studio] Auto-capture timed out or failed gracefully: $e');
    return null;
  }
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
    mv.setAttribute('shadow-intensity', '0.5'); // Lightweight GPU shadow
    mv.setAttribute('shadow-softness', '0.9');
    mv.setAttribute('exposure', '1.08');
    mv.setAttribute('environment-image', 'neutral');
    mv.setAttribute('interaction-prompt', 'none');
    mv.setAttribute('disable-pan', '');
    mv.setAttribute('loading', 'eager');
    mv.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..background = 'radial-gradient(circle at 50% 40%, #FFFFFF 0%, #F1F5F9 100%)';

    mv.appendChild(_createProgressBarSlot(mv));

    mv.addEventListener(
      'load',
      ((web.Event _) {
        if (_disposed) return;
        widget.onModelLoaded?.call();
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
    Global3DViewerManager.acquireViewer(
      viewType: _viewType,
      element: mv,
      onEvicted: () {
        if (mounted) setState(() {});
      },
    );

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
      Global3DViewerManager.releaseActiveViewer(element: _mvElement);
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
    mv.setAttribute('shadow-intensity', '0.5'); // Lightweight GPU shadow
    mv.setAttribute('shadow-softness', '0.9');
    mv.setAttribute('exposure', '1.08');
    mv.setAttribute('environment-image', 'neutral');
    mv.setAttribute('interaction-prompt', 'none');
    mv.setAttribute('disable-pan', '');
    mv.setAttribute('loading', 'eager');
    mv.setAttribute('reveal', 'auto');
    mv.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..background = 'radial-gradient(circle at 50% 42%, #FFFFFF 0%, #F1F5F9 100%)';

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
    Global3DViewerManager.acquireViewer(
      viewType: _viewType,
      element: mv,
      onEvicted: () {
        if (mounted) setState(() {});
      },
    );

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => mv,
    );
  }

  void _cleanupDom() {
    if (_mvElement != null) {
      Global3DViewerManager.releaseActiveViewer(element: _mvElement);
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

class _WebRemoteGlbStudio extends StatefulWidget {
  final String modelUrl;
  final String productName;
  final GlbStudioController controller;
  final ValueChanged<Uint8List>? onThumbnailCaptured;
  final ValueChanged<String>? onError;
  final VoidCallback? onModelLoaded;

  const _WebRemoteGlbStudio({
    required this.modelUrl,
    required this.productName,
    required this.controller,
    this.onThumbnailCaptured,
    this.onError,
    this.onModelLoaded,
  });

  @override
  State<_WebRemoteGlbStudio> createState() => _WebRemoteGlbStudioState();
}

class _WebRemoteGlbStudioState extends State<_WebRemoteGlbStudio> {
  late String _viewType;
  web.HTMLElement? _mvElement;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  @override
  void didUpdateWidget(covariant _WebRemoteGlbStudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelUrl != widget.modelUrl) {
      _cleanupDom();
      _initViewer();
    }
  }

  void _initViewer() {
    _viewType = 'penguin-remote-glb-studio-${++_viewIdSeq}';

    final mv = web.document.createElement('model-viewer') as web.HTMLElement;
    mv.setAttribute('src', widget.modelUrl);
    mv.setAttribute('crossorigin', 'anonymous');
    mv.setAttribute('alt', widget.productName);
    mv.setAttribute('camera-controls', '');
    mv.setAttribute('auto-rotate', '');
    mv.setAttribute('auto-rotate-delay', '1800');
    mv.setAttribute('rotation-per-second', '16deg');
    mv.setAttribute('shadow-intensity', '0.5'); // Lightweight GPU shadow
    mv.setAttribute('shadow-softness', '0.9');
    mv.setAttribute('exposure', '1.08');
    mv.setAttribute('environment-image', 'neutral');
    mv.setAttribute('interaction-prompt', 'none');
    mv.setAttribute('disable-pan', '');
    mv.setAttribute('loading', 'eager');
    mv.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..background = 'radial-gradient(circle at 50% 40%, #FFFFFF 0%, #F1F5F9 100%)';

    mv.appendChild(_createProgressBarSlot(mv));

    mv.addEventListener(
      'load',
      ((web.Event _) {
        if (_disposed) return;
        widget.onModelLoaded?.call();
        Future<void>.delayed(const Duration(milliseconds: 400), () async {
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
        widget.onError?.call('Could not load remote 3D GLB model.');
      }).toJS,
    );

    _mvElement = mv;
    Global3DViewerManager.acquireViewer(
      viewType: _viewType,
      element: mv,
      onEvicted: () {
        if (mounted) setState(() {});
      },
    );

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
      Global3DViewerManager.releaseActiveViewer(element: _mvElement);
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
