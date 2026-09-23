import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'dart:convert';
// Import your central config file

class VisualSearchService {
  final ImagePicker _picker = ImagePicker();

  Future<List<dynamic>> searchWithCameraOrGallery(ImageSource source) async {
    try {
      // 1. Capture or select the image
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return [];

      // 2. Read the file as raw bytes (Works on Web, Android, and iOS)
      final bytes = await image.readAsBytes();

      // 3. Prepare the multipart request using ApiConfig.baseUrl
      final url = Uri.parse('${ApiConfig.baseUrl}/api/search/visual');
      var request = http.MultipartRequest('POST', url);
      request.files.add(http.MultipartFile.fromBytes(
        'file', 
        bytes,
        filename: image.name,
      ));

      // 4. Send the image to your backend
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      // 5. Parse the ranked matches
      if (response.statusCode == 200) {
        var jsonResult = json.decode(response.body);
        return jsonResult['matches']; 
      } else {
        print("Backend Error: ${response.statusCode} - ${response.body}");
        return [];
      }
    } catch (e) {
      print("Visual Search Exception: $e");
      return [];
    }
  }
}