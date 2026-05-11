import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class ApiConfig {
  // 1. If testing on a physical phone, put your computer's Wi-Fi IP here
 // FIXED: Changed to match your ipconfig output
  static const String _lanIp = '192.168.1.6'; 
  
  static const bool _isPhysicalDevice = true;

  static String get baseUrl{
    // Web Browser
    if (kIsWeb) {
      return 'http://127.0.0.1:8000';
    }

    // Android (Emulator or Physical)
    if (Platform.isAndroid) {
      return _isPhysicalDevice 
          ? 'http://$_lanIp:8000' 
          : 'http://10.0.2.2:8000'; // Uses this magic IP for the Emulator automatically
    }

    // iOS (Simulator or Physical)
    if (Platform.isIOS) {
      return _isPhysicalDevice 
          ? 'http://$_lanIp:8000' 
          : 'http://127.0.0.1:8000';
    }

    // Desktop (Windows, macOS, Linux)
    return 'http://127.0.0.1:8000';
  }
}