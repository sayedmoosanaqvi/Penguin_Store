import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'dart:convert';

class VisualSearchService {
  final ImagePicker _picker = ImagePicker();

  Future<List<dynamic>> searchWithCameraOrGallery(ImageSource source) async {
    try {
      // 1. Capture or select the image
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return [];

      // 2. Read the file as raw bytes
      final bytes = await image.readAsBytes();

      // 3. Prepare the multipart request pointing to your cloud API
      final url = Uri.parse('${ApiConfig.baseUrl}/api/search/visual');
      var request = http.MultipartRequest('POST', url);
      request.files.add(http.MultipartFile.fromBytes(
        'file', 
        bytes,
        filename: image.name,
      ));

      print("🚀 Sending image to AI Backend...");
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      // 4. Parse the results properly
      if (response.statusCode == 200) {
        var jsonResult = json.decode(response.body);
        print("✅ AI Match Successful: ${jsonResult['total_matches']} products found.");
        
        if (jsonResult['matches'] != null) {
          return jsonResult['matches'];
        }
        return [];
      } else {
        // Stop silently hiding errors! Print the exact backend crash log.
        print("❌ Backend Crash (${response.statusCode}): ${response.body}");
        return []; 
      }
    } catch (e) {
      print("❌ Network/Frontend Exception: $e");
      return [];
    }
  }
}