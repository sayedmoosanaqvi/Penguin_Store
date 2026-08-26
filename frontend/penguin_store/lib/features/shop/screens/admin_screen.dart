import 'dart:typed_data'; // Replaces dart:io for web safety
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:penguin_store/features/shop/admin/widgets/ctrl_x_panel.dart';
import '../../../core/theme/app_colors.dart';
import '../services/product_service.dart';

// IMPORTANT: Import the CtrlXPanel file we created in the last step!
// Adjust the path if you saved it somewhere else.

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
  bool _isFeatured = false;

  // --- WEB-SAFE IMAGE VARIABLES ---
  XFile? _selectedImageFile; // Holds the file reference to send to backend
  Uint8List? _imageBytes;    // Holds the raw data to display on screen
  bool _isLoading = false; 

  // --- NEW PICK IMAGE FUNCTION ---
  Future<void> _pickImage() async {
    final pickedFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes(); // Read for the web preview
      setState(() {
        _selectedImageFile = pickedFile;
        _imageBytes = bytes;
      });
    }
  }

  void _submitData() async {
    // 1. Validate form AND ensure an image is selected
    if (_formKey.currentState!.validate()) {
      if (_selectedImageFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an image first!'), backgroundColor: Colors.orange),
        );
        return;
      }

      // 2. Start the loading spinner
      setState(() => _isLoading = true);

      // 3. Upload the image to FastAPI -> AWS S3
      String? uploadedAwsUrl = await _productService.uploadImage(_selectedImageFile!);

      if (uploadedAwsUrl == null) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Image upload failed. Check server.'), backgroundColor: Colors.red),
        );
        return;
      }

      // 4. If image upload succeeds, save the rest of the product!
      final productData = {
        "name": _nameController.text,
        "description": _descController.text,
        "price": double.parse(_priceController.text),
        "image_url": uploadedAwsUrl, // USE THE NEW AWS URL HERE!
        "category": _categoryController.text.toUpperCase(),
        "is_featured": _isFeatured,
      };

      bool success = await _productService.addProduct(productData);

      setState(() => _isLoading = false); // Stop loading spinner

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product published successfully!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Database save failed.'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _deleteProduct() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('To delete, please select an existing product from the list first!'), 
        backgroundColor: Colors.orange
      ),
    );
  }

  // --- NEW: FUNCTION TO OPEN THE AI AGENT ---
  void _openCtrlXAgent() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Allows the sheet to take up more screen space
      backgroundColor: Colors.transparent, // Let the panel handle its own dark theme
      builder: (context) {
        return Padding(
          // This padding ensures the keyboard doesn't cover the chat input!
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.75, // Takes up 75% of the screen
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
        title: const Text('Admin Panel', style: TextStyle(color: AppColors.whiteText, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.whiteText),
      ),
      
      // --- NEW: THE FLOATING AI AGENT BUTTON ---
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0F172A), // CTRL-X dark theme color
        icon: const Icon(Icons.memory, color: Colors.cyanAccent),
        label: const Text(
          "CTRL-X", 
          style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, letterSpacing: 1.2)
        ),
        onPressed: _openCtrlXAgent,
      ),
      
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("New Product", style: TextStyle(color: AppColors.whiteText, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 25),

              // --- NEW PREMIUM IMAGE UPLOAD BOX ---
              GestureDetector(
                onTap: _pickImage,
                child: Container(
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primary, width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, 5))
                    ],
                  ),
                  child: _imageBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.memory(_imageBytes!, fit: BoxFit.cover, width: double.infinity),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.cloud_upload_outlined, size: 50, color: Colors.grey[400]),
                            const SizedBox(height: 10),
                            Text("Tap to upload product image", style: TextStyle(color: Colors.grey[500], fontWeight: FontWeight.w500)),
                          ],
                        ),
                ),
              ),

              const SizedBox(height: 25),

              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, 5))
                  ],
                ),
                child: Column(
                  children: [
                    _buildTextField(_nameController, "Product Name", Icons.edit_note),
                    _buildTextField(_descController, "Description", Icons.description, maxLines: 3),
                    Row(
                      children: [
                        Expanded(child: _buildTextField(_priceController, "Price", Icons.attach_money, isNumber: true)),
                        const SizedBox(width: 15),
                        Expanded(child: _buildTextField(_categoryController, "Category", Icons.category)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Mark as Featured", style: TextStyle(fontWeight: FontWeight.w500, color: AppColors.whiteText)),
                      value: _isFeatured,
                      activeColor: AppColors.primary,
                      onChanged: (val) => setState(() => _isFeatured = val),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 40),

              Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: SizedBox(
                      height: 60,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.redAccent, width: 2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        ),
                        onPressed: _deleteProduct,
                        child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 28),
                      ),
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 60,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryDark,
                          foregroundColor: AppColors.whiteText,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                          elevation: 5,
                        ),
                        // Disable button if loading to prevent double-clicks
                        onPressed: _isLoading ? null : _submitData,
                        child: _isLoading 
                            ? const CircularProgressIndicator(color: AppColors.whiteText) 
                            : const Text("PUBLISH PRODUCT", style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 80), // Added bottom padding so the FAB doesn't cover buttons
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, IconData icon, {bool isNumber = false, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        style: const TextStyle(color: AppColors.whiteText),
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: Colors.grey[400], size: 20),
          labelText: label,
          labelStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
          filled: true,
          fillColor: AppColors.background.withOpacity(0.4),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          errorBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Colors.redAccent),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        validator: (value) => value!.isEmpty ? "This field is required" : null,
      ),
    );
  }
}