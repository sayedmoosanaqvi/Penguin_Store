
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:penguin_store/features/shop/admin/widgets/ctrl_x_panel.dart';

import '../../../core/theme/app_colors.dart';
import '../services/product_service.dart';
import 'product_3d_viewer_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _formKey = GlobalKey<FormState>();
  final _productService = ProductService();

  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _categoryController = TextEditingController();
  final _descController = TextEditingController();
  final _variantController = TextEditingController();

  XFile? _selectedImageFile;
  Uint8List? _imageBytes;

  PlatformFile? _selectedModel;
  Uint8List? _modelBytes;

  bool _isFeatured = false;
  bool _enable3D = false;
  bool _isLoading = false;

  String _progressText = '';

  String? _uploadedImageUrl;
  int? _createdProductId;
  int? _createdModelId;

  bool get _productAlreadyCreated =>
      _createdProductId != null;

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    _categoryController.dispose();
    _descController.dispose();
    _variantController.dispose();
    super.dispose();
  }

  void _showMessage(
    String message, {
    bool error = false,
  }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? Colors.redAccent
            : const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _updateProgress(String message) {
    if (!mounted) return;

    setState(() {
      _progressText = message;
    });
  }

  Future<void> _pickImage() async {
    if (_isLoading || _productAlreadyCreated) return;

    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );

      if (file == null) return;

      final size = await file.length();

      if (size <= 0 || size > 10 * 1024 * 1024) {
        _showMessage(
          'Product image must be under 10 MB.',
          error: true,
        );
        return;
      }

      final bytes = await file.readAsBytes();

      if (!mounted) return;

      setState(() {
        _selectedImageFile = file;
        _imageBytes = bytes;
        _uploadedImageUrl = null;
      });
    } catch (e) {
      _showMessage(
        'Unable to select image: $e',
        error: true,
      );
    }
  }

  Future<void> _pick3DModel() async {
    if (_isLoading || _createdModelId != null) {
      return;
    }

    try {
      final PlatformFile? file =
          await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['glb'],
      );

      if (file == null) return;

      if (!file.name.toLowerCase().endsWith('.glb')) {
        _showMessage(
          'Please select a .glb file.',
          error: true,
        );
        return;
      }

      final fileLength = await file.length();

      if (fileLength != null &&
          (fileLength <= 0 ||
              fileLength > ProductService.maxModelBytes)) {
        _showMessage(
          'GLB file must be under 20 MB.',
          error: true,
        );
        return;
      }

      final Uint8List bytes = await file.readAsBytes();

      if (bytes.isEmpty ||
          bytes.lengthInBytes >
              ProductService.maxModelBytes) {
        _showMessage(
          'GLB file must be under 20 MB.',
          error: true,
        );
        return;
      }

      if (!mounted) return;

      setState(() {
        _selectedModel = file;
        _modelBytes = bytes;
      });

      _showMessage(
        '${file.name} selected successfully.',
      );
    } catch (e) {
      _showMessage(
        'Unable to select GLB: $e',
        error: true,
      );
    }
  }

  Future<void> _submitData() async {
    if (_isLoading) return;

    if (!_productAlreadyCreated &&
        !_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedImageFile == null) {
      _showMessage(
        'Please select a product image.',
        error: true,
      );
      return;
    }

    if (_enable3D &&
        (_selectedModel == null ||
            _modelBytes == null)) {
      _showMessage(
        'Please select a GLB model.',
        error: true,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      if (_uploadedImageUrl == null) {
        _updateProgress(
          'Uploading product image to Supabase...',
        );

        final imageUrl =
            await _productService.uploadImage(
          _selectedImageFile!,
        );

        if (imageUrl == null || imageUrl.isEmpty) {
          throw Exception(
            'Image upload failed. Check FastAPI.',
          );
        }

        _uploadedImageUrl = imageUrl;
      }

      if (_createdProductId == null) {
        _updateProgress(
          'Saving product in PostgreSQL...',
        );

        final price = double.tryParse(
          _priceController.text.trim(),
        );

        if (price == null || price <= 0) {
          throw Exception(
            'Please enter a valid price.',
          );
        }

        final productData = <String, dynamic>{
          'name': _nameController.text.trim(),
          'description': _descController.text.trim(),
          'price': price,
          'image_url': _uploadedImageUrl!,
          'category': _categoryController
              .text
              .trim()
              .toUpperCase(),
          'is_featured': _isFeatured,
        };

        final productId =
            await _productService.createProductWithId(
          productData,
        );

        _createdProductId = productId;
      }

      if (_enable3D && _createdModelId == null) {
        _updateProgress(
          'Uploading GLB to private Supabase Storage...',
        );

        final uploadedModel =
            await _productService.upload3DModel(
          productId: _createdProductId!,
          fileName: _selectedModel!.name,
          bytes: _modelBytes!,
          displayName:
              '${_nameController.text.trim()} 3D View',
          variantName: _variantController.text.trim(),
        );

        _createdModelId = uploadedModel.id;

        _updateProgress(
          '3D model registered successfully.',
        );
      }

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _progressText = '';
      });

      await _showPublishResult();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _progressText = '';
      });

      final details = e
          .toString()
          .replaceFirst('Exception: ', '');

      if (_productAlreadyCreated &&
          _enable3D &&
          _createdModelId == null) {
        _showMessage(
          'Product #$_createdProductId is saved, '
          'but the GLB upload is not confirmed. '
          'Check Storage before retrying. $details',
          error: true,
        );
      } else {
        _showMessage(
          details,
          error: true,
        );
      }
    }
  }

  Future<void> _showPublishResult() async {
    final has3DModel = _createdModelId != null;

    final preview = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.check_circle,
                color: Colors.green,
              ),
              SizedBox(width: 10),
              Text('Product Published'),
            ],
          ),
          content: Text(
            has3DModel
                ? 'Product #$_createdProductId '
                    'and its GLB model were saved successfully. '
                    'The product image is public, '
                    'while the 3D model remains private.'
                : 'Product #$_createdProductId '
                    'has been published successfully.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('DONE'),
            ),
            if (has3DModel)
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(dialogContext).pop(true);
                },
                icon: const Icon(
                  Icons.view_in_ar_rounded,
                ),
                label: const Text('PREVIEW 3D'),
              ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (preview == true && _createdModelId != null) {
      try {
        final modelUrl =
            await _productService.getAdmin3DPreviewUrl(
          _createdModelId!,
        );

        if (!mounted) return;

        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) {
              return Product3DViewerScreen(
                productName: _nameController.text.trim(),
                modelUrl: modelUrl,
              );
            },
          ),
        );
      } catch (e) {
        _showMessage(
          'Unable to preview 3D model: $e',
          error: true,
        );
      }
    }

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  void _deleteProduct() {
    _showMessage(
      'To delete a product, open it from '
      'the product list first.',
      error: true,
    );
  }

  void _openCtrlXAgent() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(
              sheetContext,
            ).viewInsets.bottom,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(25),
            ),
            child: SizedBox(
              height: MediaQuery.of(
                    sheetContext,
                  ).size.height *
                  0.75,
              child: const CtrlXPanel(),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Admin Panel',
          style: TextStyle(
            color: AppColors.whiteText,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.background,
        iconTheme: const IconThemeData(
          color: AppColors.whiteText,
        ),
      ),
      floatingActionButton:
          FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0F172A),
        icon: const Icon(
          Icons.memory,
          color: Colors.cyanAccent,
        ),
        label: const Text(
          'CTRL-X',
          style: TextStyle(
            color: Colors.cyanAccent,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        onPressed: _openCtrlXAgent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 900,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'New Product',
                    style: TextStyle(
                      color: AppColors.whiteText,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  _buildImageSelector(),

                  const SizedBox(height: 24),

                  _buildProductInformation(),

                  const SizedBox(height: 20),

                  _build3DSelector(),

                  const SizedBox(height: 26),

                  if (_productAlreadyCreated &&
                      _enable3D &&
                      _createdModelId == null)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: 16,
                      ),
                      child: Text(
                        'Product #$_createdProductId '
                        'is already created. '
                        'The next attempt will upload only '
                        'its missing GLB model.',
                        style: const TextStyle(
                          color: Colors.amberAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),

                  if (_isLoading) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      _progressText,
                      style: const TextStyle(
                        color: AppColors.whiteText,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],

                  _buildActionButtons(),

                  const SizedBox(height: 85),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageSelector() {
    return GestureDetector(
      onTap: _isLoading || _productAlreadyCreated
          ? null
          : _pickImage,
      child: Container(
        width: double.infinity,
        height: 210,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.primary,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: 0.12,
              ),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: _imageBytes != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.memory(
                  _imageBytes!,
                  width: double.infinity,
                  fit: BoxFit.contain,
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 52,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Tap to upload product image',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'JPG, PNG, WEBP, GIF or AVIF — max 10 MB',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildProductInformation() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildTextField(
            _nameController,
            'Product Name',
            Icons.edit_note,
          ),
          _buildTextField(
            _descController,
            'Description',
            Icons.description_outlined,
            maxLines: 3,
          ),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  _priceController,
                  'Price (USD)',
                  Icons.attach_money,
                  isNumber: true,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _buildTextField(
                  _categoryController,
                  'Category',
                  Icons.category_outlined,
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Mark as Featured',
              style: TextStyle(
                color: AppColors.whiteText,
                fontWeight: FontWeight.w500,
              ),
            ),
            value: _isFeatured,
            activeThumbColor: AppColors.primary,
            onChanged:
                _isLoading || _productAlreadyCreated
                    ? null
                    : (value) {
                        setState(() {
                          _isFeatured = value;
                        });
                      },
          ),
        ],
      ),
    );
  }

  Widget _build3DSelector() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _enable3D
              ? AppColors.primary
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(
              Icons.view_in_ar_rounded,
              color: AppColors.primary,
              size: 30,
            ),
            title: const Text(
              'Enable 3D Product',
              style: TextStyle(
                color: AppColors.whiteText,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: const Text(
              'Optional GLB model for Premium customers',
              style: TextStyle(
                color: Colors.white70,
              ),
            ),
            value: _enable3D,
            activeThumbColor: AppColors.primary,
            onChanged:
                _isLoading || _productAlreadyCreated
                    ? null
                    : (value) {
                        setState(() {
                          _enable3D = value;
                        });
                      },
          ),

          if (_enable3D) ...[
            const Divider(
              color: Colors.white24,
            ),
            const SizedBox(height: 14),

            const Text(
              '3D Model File',
              style: TextStyle(
                color: AppColors.whiteText,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    _isLoading || _createdModelId != null
                        ? null
                        : _pick3DModel,
                icon: const Icon(
                  Icons.upload_file_rounded,
                ),
                label: Text(
                  _selectedModel == null
                      ? 'CHOOSE GLB FILE'
                      : 'CHANGE GLB FILE',
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 17,
                  ),
                  side: const BorderSide(
                    color: AppColors.primary,
                  ),
                  foregroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            if (_selectedModel != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.background
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.view_in_ar_rounded,
                      color: Colors.cyanAccent,
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedModel!.name,
                            maxLines: 2,
                            overflow:
                                TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.whiteText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${((_modelBytes?.lengthInBytes ?? 0) / (1024 * 1024)).toStringAsFixed(2)} MB',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.check_circle,
                      color: Colors.greenAccent,
                    ),
                  ],
                ),
              )
            else
              const Text(
                'No GLB selected. Maximum file size: 20 MB.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),

            const SizedBox(height: 18),

            _buildTextField(
              _variantController,
              '3D Variant (optional)',
              Icons.palette_outlined,
              optional: true,
              lockAfterCreate: false,
            ),

            const Row(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  color: Colors.greenAccent,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your GLB is uploaded to private '
                    'Supabase Storage. Its storage path '
                    'is registered automatically in PostgreSQL.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        SizedBox(
          width: 65,
          height: 58,
          child: OutlinedButton(
            onPressed: _isLoading
                ? null
                : _deleteProduct,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(
                color: Colors.redAccent,
                width: 2,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              padding: EdgeInsets.zero,
            ),
            child: const Icon(
              Icons.delete_outline,
              color: Colors.redAccent,
              size: 26,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: SizedBox(
            height: 58,
            child: ElevatedButton(
              onPressed: _isLoading
                  ? null
                  : _submitData,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryDark,
                foregroundColor: AppColors.whiteText,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: _isLoading
                  ? const CircularProgressIndicator(
                      color: AppColors.whiteText,
                    )
                  : Text(
                      _productAlreadyCreated &&
                              _enable3D &&
                              _createdModelId == null
                          ? 'RETRY 3D UPLOAD'
                          : 'PUBLISH PRODUCT',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool isNumber = false,
    int maxLines = 1,
    bool optional = false,
    bool lockAfterCreate = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: 20,
      ),
      child: TextFormField(
        controller: controller,
        enabled: !_isLoading &&
            (!lockAfterCreate ||
                !_productAlreadyCreated),
        maxLines: maxLines,
        style: const TextStyle(
          color: AppColors.whiteText,
        ),
        keyboardType: isNumber
            ? const TextInputType.numberWithOptions(
                decimal: true,
              )
            : TextInputType.text,
        decoration: InputDecoration(
          prefixIcon: Icon(
            icon,
            color: Colors.grey[400],
            size: 20,
          ),
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.grey[500],
            fontSize: 14,
          ),
          filled: true,
          fillColor: AppColors.background
              .withValues(alpha: 0.4),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppColors.border,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(
              color: AppColors.primary,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          errorBorder: OutlineInputBorder(
            borderSide: const BorderSide(
              color: Colors.redAccent,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        validator: (value) {
          final input = (value ?? '').trim();

          if (!optional && input.isEmpty) {
            return 'This field is required';
          }

          if (isNumber) {
            final price = double.tryParse(input);

            if (price == null || price <= 0) {
              return 'Enter a valid price';
            }
          }

          if (optional && input.length > 100) {
            return 'Maximum 100 characters';
          }

          return null;
        },
      ),
    );
  }
}
