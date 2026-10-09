import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart'; // <-- Required for MediaType
import 'package:penguin_store/config/api_config.dart';
import 'dart:convert';

class VisualSearchService {
  final ImagePicker _picker = ImagePicker();

  Future<List<dynamic>> searchWithCameraOrGallery(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return [];

      final bytes = await image.readAsBytes();

      final url = Uri.parse('${ApiConfig.baseUrl}/api/search/visual');
      var request = http.MultipartRequest('POST', url);
      
      // Explicitly define the MediaType so FastAPI accepts the file
      request.files.add(http.MultipartFile.fromBytes(
        'file', 
        bytes,
        filename: image.name.isNotEmpty ? image.name : 'upload.png',
        contentType: MediaType('image', 'png'), 
      ));

      request.headers.addAll({
        'Accept': 'application/json',
      });

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        var jsonResult = json.decode(response.body);
        if (jsonResult['matches'] != null) {
          return jsonResult['matches'];
        }
        return [];
      } else {
        print("❌ Backend Error (${response.statusCode}): ${response.body}");
        return []; 
      }
    } catch (e) {
      print("❌ Network Exception: $e");
      return [];
    }
  }
}