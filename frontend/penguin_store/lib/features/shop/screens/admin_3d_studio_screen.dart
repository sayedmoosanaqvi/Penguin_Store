import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/product_3d_viewer_screen.dart';
import 'package:penguin_store/features/shop/services/admin_3d_service.dart';
import 'package:penguin_store/features/shop/services/product_service.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';

/// Admin screen: drop in a GLB downloaded from the internet and it appears
/// under the "3D" filter. Textures are capped at 512 px server-side.
class Admin3DStudioScreen extends StatefulWidget {
  const Admin3DStudioScreen({super.key});

  @override
  State<Admin3DStudioScreen> createState() => _Admin3DStudioScreenState();
}

enum _Mode { newProduct, existingProduct }

class _Admin3DStudioScreenState extends State<Admin3DStudioScreen> {
  static const int _maxBytes = 60 * 1024 * 1024;

  final _service = Admin3DService();
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _price = TextEditingController();
  final _category = TextEditingController(text: '3D Models');
  final _description = TextEditingController();
  final _variant = TextEditingController();

  _Mode _mode = _Mode.newProduct;

  PlatformFile? _glb;
  Uint8List? _glbBytes;
  Uint8List? _posterBytes;
  String? _posterName;

  List<Product> _products = const [];
  Product? _target;

  bool _busy = false;
  String _status = '';
  String? _lastResult;

  late Future<List<Admin3DModelRow>> _library = _service.listModels();

  @override
  void initState() {
    super.initState();
    ProductService().fetchProducts().then((p) {
      if (mounted) setState(() => _products = p);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _category.dispose();
    _description.dispose();
    _variant.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.redAccent : const Color(0xFF16A34A),
      ),
    );
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _pickGlb() async {
    if (_busy) return;
    try {
      final PlatformFile? file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['glb'],
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();

      if (bytes.isEmpty || bytes.length > _maxBytes) {
        _toast('GLB must be between 1 byte and 60 MB.', error: true);
        return;
      }

      if (bytes.length < 12 ||
          String.fromCharCodes(bytes.sublist(0, 4)) != 'glTF') {
        _toast('That file is not a valid .glb model.', error: true);
        return;
      }

      if (!mounted) return;

      setState(() {
        _glb = file;
        _glbBytes = bytes;
        if (_name.text.trim().isEmpty) {
          _name.text = file.name
              .replaceAll(RegExp(r'\.glb$', caseSensitive: false), '')
              .replaceAll(RegExp(r'[_\-]+'), ' ')
              .trim();
        }
      });
    } catch (e) {
      _toast('Could not read file: $e', error: true);
    }
  }

  Future<void> _pickPoster() async {
    if (_busy) return;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _posterBytes = bytes;
      _posterName = file.name;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;

    if (_glbBytes == null || _glb == null) {
      _toast('Choose a .glb file first.', error: true);
      return;
    }

    if (_mode == _Mode.newProduct) {
      if (!_formKey.currentState!.validate()) return;
    } else if (_target == null) {
      _toast('Pick the product to attach the model to.', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Optimising textures to 512px and uploading securely…';
      _lastResult = null;
    });

    try {
      final raw = _glbBytes!.length;
      final Admin3DUploadResult result;

      if (_mode == _Mode.newProduct) {
        result = await _service.uploadNewProduct(
          fileName: _glb!.name,
          glbBytes: _glbBytes!,
          name: _name.text.trim(),
          price: double.parse(_price.text.trim()),
          category: _category.text.trim(),
          description: _description.text.trim(),
          variantName: _variant.text.trim(),
          posterBytes: _posterBytes,
          posterName: _posterName,
        );
      } else {
        result = await _service.attachToProduct(
          productId: _target!.id,
          fileName: _glb!.name,
          glbBytes: _glbBytes!,
          displayName: '${_target!.name} 3D View',
          variantName: _variant.text.trim(),
        );
      }

      Catalog3D.refresh(force: true);

      if (!mounted) return;

      setState(() {
        _lastResult = 'Live in the 3D filter · ${_size(raw)} → '
            '${_size(result.storedBytes)}';
        _glb = null;
        _glbBytes = null;
        _posterBytes = null;
        _posterName = null;
        _name.clear();
        _price.clear();
        _description.clear();
        _variant.clear();
        _library = _service.listModels();
      });

      _toast('3D model uploaded and activated.');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  Future<void> _preview(Admin3DModelRow row) async {
    try {
      final url = await _service.previewUrl(row.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Product3DViewerScreen(
            productName: row.productName,
            modelUrl: url,
          ),
        ),
      );
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _toggle(Admin3DModelRow row, bool value) async {
    try {
      await _service.setActive(row.id, value);
      Catalog3D.refresh(force: true);
      if (mounted) setState(() => _library = _service.listModels());
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _delete(Admin3DModelRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete 3D model?'),
        content: Text(
          'This permanently removes the model for "${row.productName}". '
          'The product itself is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await _service.deleteModel(row.id);
      Catalog3D.refresh(force: true);
      if (mounted) setState(() => _library = _service.listModels());
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = context.watch<AuthProvider>().isAdmin;

    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('3D Studio')),
        body: const Center(child: Text('Admin access required.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('3D Studio')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          FadeSlideIn(child: _hero()),
          const SizedBox(height: 14),
          FadeSlideIn(
            delay: const Duration(milliseconds: 90),
            child: _uploadCard(theme),
          ),
          const SizedBox(height: 18),
          FadeSlideIn(
            delay: const Duration(milliseconds: 160),
            child: _libraryCard(theme),
          ),
        ],
      ),
    );
  }

  Widget _hero() {
    return Container(
      height: 112,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SnowfallBackground(
        child: const Padding(
          padding: EdgeInsets.all(18),
          child: Row(
            children: [
              PulsingOrb(
                size: 56,
                icon: Icons.view_in_ar_rounded,
                colors: [Color(0x66FFFFFF), Color(0x33FFFFFF)],
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '3D Studio',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Upload any .glb → it appears under the 3D filter.\n'
                      'Textures auto-optimised to 512px for fast loading.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _uploadCard(ThemeData theme) {
    final primary = theme.primaryColor;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: primary.withValues(alpha: 0.15)),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                  value: _Mode.newProduct,
                  icon: Icon(Icons.add_box_outlined, size: 18),
                  label: Text('New 3D product'),
                ),
                ButtonSegment(
                  value: _Mode.existingProduct,
                  icon: Icon(Icons.link_rounded, size: 18),
                  label: Text('Attach to product'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 14),
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _busy ? null : _pickGlb,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: primary.withValues(alpha: _glb == null ? 0.05 : 0.12),
                  border: Border.all(
                    color: primary.withValues(alpha: _glb == null ? 0.25 : 0.7),
                    width: 1.4,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      _glb == null
                          ? Icons.cloud_upload_outlined
                          : Icons.check_circle_rounded,
                      size: 34,
                      color: primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _glb == null
                          ? 'Choose .glb file (max 60 MB)'
                          : '${_glb!.name}  ·  ${_size(_glbBytes!.length)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: primary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_mode == _Mode.newProduct) ...[
              TextFormField(
                controller: _name,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Product name'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter a name'
                    : null,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      enabled: !_busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Price (\$)',
                      ),
                      validator: (v) {
                        final n = double.tryParse((v ?? '').trim());
                        return (n == null || n <= 0) ? 'Valid price' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _category,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: 'Category'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _description,
                enabled: !_busy,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickPoster,
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: Text(
                      _posterBytes == null
                          ? 'Cover image (optional)'
                          : 'Change cover',
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_posterBytes != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _posterBytes!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    )
                  else
                    const Expanded(
                      child: Text(
                        'No cover → a clean 3D poster is generated.',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
            ] else ...[
              DropdownButtonFormField<Product>(
                value: _target,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Attach to existing product',
                ),
                items: _products
                    .map(
                      (p) => DropdownMenuItem(
                        value: p,
                        child: Text(
                          '#${p.id}  ${p.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _busy ? null : (p) => setState(() => _target = p),
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: _variant,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Variant label (optional, e.g. "Red")',
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _busy
                  ? Column(
                      key: const ValueKey('busy'),
                      children: [
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(_status, style: const TextStyle(fontSize: 11)),
                      ],
                    )
                  : SizedBox(
                      key: const ValueKey('idle'),
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submit,
                        icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                        label: const Text('UPLOAD & PUBLISH'),
                      ),
                    ),
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.check_circle,
                      color: Color(0xFF16A34A), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _lastResult!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF16A34A),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _libraryCard(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Model library',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () =>
                  setState(() => _library = _service.listModels()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        FutureBuilder<List<Admin3DModelRow>>(
          future: _library,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  snapshot.error.toString().replaceFirst('Exception: ', ''),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              );
            }

            final rows = snapshot.data ?? const [];
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(18),
                child: Text('No 3D models uploaded yet.'),
              );
            }

            return Column(
              children: [
                for (var i = 0; i < rows.length; i++)
                  FadeSlideIn.staggered(
                    key: ValueKey('row-${rows[i].id}'),
                    index: i,
                    child: _row(theme, rows[i]),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, Admin3DModelRow row) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.view_in_ar_rounded,
            color: row.isActive ? theme.primaryColor : Colors.grey,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [
                    '#${row.productId}',
                    if (row.variantName?.isNotEmpty == true) row.variantName!,
                    if (row.fileSizeBytes != null) _size(row.fileSizeBytes!),
                  ].join('  ·  '),
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: row.isActive,
            onChanged: (v) => _toggle(row, v),
          ),
          IconButton(
            tooltip: 'Preview',
            onPressed: () => _preview(row),
            icon: const Icon(Icons.play_circle_outline_rounded),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: () => _delete(row),
            icon: const Icon(Icons.delete_outline_rounded,
                color: Colors.redAccent),
          ),
        ],
      ),
    );
  }
}
