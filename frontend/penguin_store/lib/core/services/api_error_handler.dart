import 'dart:async';
import 'dart:convert';

/// Sanitizes network/backend errors so raw exceptions, URLs, or stack traces
/// are never shown to end users (Google Play Store data-safety best practice).
class ApiErrorHandler {
  ApiErrorHandler._();

  static String fromStatus(int statusCode, String body, {String fallback = 'Request could not be completed.'}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        final detail = (decoded['detail'] as String).trim();
        if (detail.isNotEmpty && detail.length <= 220 && !detail.contains('Traceback')) {
          return detail;
        }
      }
    } catch (_) {}

    if (statusCode == 401) return 'Your session expired. Please log in again.';
    if (statusCode == 403) return 'You do not have permission to perform this action.';
    if (statusCode == 404) return 'The requested item was not found.';
    if (statusCode == 422) return 'Please check the entered details and try again.';
    if (statusCode == 429) return 'Too many requests. Please wait a moment and try again.';
    if (statusCode >= 500) return 'Server is temporarily unavailable. Please try again shortly.';
    return fallback;
  }

  static String sanitize(Object error, {String fallback = 'Unable to connect right now. Please try again.'}) {
    if (error is TimeoutException) {
      return 'Connection timed out. The server may be waking up—please try again.';
    }
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    final lower = raw.toLowerCase();

    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception') ||
        lower.contains('connection refused') ||
        lower.contains('xmlhttprequest error')) {
      return 'Unable to reach Penguin Store servers. Check your internet connection.';
    }

    if (raw.contains('http://') ||
        raw.contains('https://') ||
        lower.contains('traceback') ||
        lower.contains('psycopg') ||
        lower.contains('sqlalchemy')) {
      return fallback;
    }

    if (raw.isEmpty || raw.length > 180) return fallback;
    return raw;
  }
}
