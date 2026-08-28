import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class ApiConfig {
  static const String _lanIp = '192.168.1.6';
  static const bool _isPhysicalDevice = true;

  static String get baseUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      // If testing locally in the browser
      if (host == 'localhost' || host == '127.0.0.1') {
        return 'http://localhost:8000';
      }
      // Automatically uses Render for GitHub Pages or any future custom domain
      return 'https://penguin-store-backend.onrender.com';
    }

    if (Platform.isAndroid) {
      return _isPhysicalDevice
          ? 'http://$_lanIp:8000'
          : 'http://10.0.2.2:8000';
    }

    if (Platform.isIOS) {
      return _isPhysicalDevice
          ? 'http://$_lanIp:8000'
          : 'http://127.0.0.1:8000';
    }

    return 'http://127.0.0.1:8000';
  }
}