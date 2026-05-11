import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import '../models/product_model.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
// 1. Import your new config file (adjust the path if your folder is named differently)

class ProductService {
  // 2. The Auto-Logic: This now automatically grabs the correct URL
  // depending on whether you are running on Desktop, Web, or Mobile!
  // 2. The Auto-Logic: Call the static class directly without ()
  static String get baseUrl => ApiConfig.baseUrl;

  // This function reaches out to your FastAPI /products/ route
  Future<List<Product>> fetchProducts() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/products/'));

      if (response.statusCode == 200) {
        // Decode the JSON list from the database
        List<dynamic> body = jsonDecode(response.body);

        // Convert that list of JSON maps into a list of Product objects
        return body.map((item) => Product.fromJson(item)).toList();
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Could not connect to backend: $e');
    }
  }

  // Add this method inside your ProductService class
  Future<bool> addProduct(Map<String, dynamic> productData) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/products/'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(productData),
      );

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print("Error adding product: $e");
      return false;
    }
  }
// Function to delete a product by its ID
 // --- ADD THIS INSIDE YOUR ProductService CLASS ---
  Future<bool> deleteProduct(int productId) async {
    try {
      var response = await http.delete(Uri.parse('${ApiConfig.baseUrl}/products/$productId'));
      
      if (response.statusCode == 200) {
        return true;
      } else {
        print("Failed to delete. Status: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      print("Error deleting product: $e");
      return false;
    }
  }

  Future<String?> uploadImage(XFile imageFile) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse('${ApiConfig.baseUrl}/upload-file/'));
      
      // Read the file as raw bytes (This bypasses the web file path security issue)
      var bytes = await imageFile.readAsBytes();

      // Attach the bytes to the request, passing the filename so AWS knows the extension
      request.files.add(http.MultipartFile.fromBytes(
        'file', 
        bytes,
        filename: imageFile.name, 
      ));

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        var jsonResponse = json.decode(response.body);
        return jsonResponse['url']; 
      } else {
        print("Upload failed with status: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Error uploading image: $e");
      return null;
    }
  }


}
