import 'package:flutter/material.dart';

/// Global root key attached to [MaterialApp.router] so toast notifications
/// ALWAYS render visibly on top of every route, tab, drawer, or modal sheet.
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class AppNotifier {
  AppNotifier._();

  static void showSuccess(String message, {BuildContext? fallbackContext}) {
    _show(
      message: message,
      backgroundColor: const Color(0xFF059669),
      icon: Icons.check_circle_rounded,
      duration: const Duration(milliseconds: 3500),
      fallbackContext: fallbackContext,
    );
  }

  static void showError(String message, {BuildContext? fallbackContext}) {
    _show(
      message: message,
      backgroundColor: const Color(0xFFDC2626),
      icon: Icons.error_rounded,
      duration: const Duration(milliseconds: 4200),
      fallbackContext: fallbackContext,
    );
  }

  static void showInfo(String message, {BuildContext? fallbackContext}) {
    _show(
      message: message,
      backgroundColor: const Color(0xFF1E293B),
      icon: Icons.info_rounded,
      duration: const Duration(milliseconds: 3500),
      fallbackContext: fallbackContext,
    );
  }

  static void _show({
    required String message,
    required Color backgroundColor,
    required IconData icon,
    required Duration duration,
    BuildContext? fallbackContext,
  }) {
    ScaffoldMessengerState? messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null && fallbackContext != null) {
      messenger = ScaffoldMessenger.maybeOf(fallbackContext);
    }
    if (messenger == null) return;

    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 22),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: backgroundColor,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.22),
            width: 1,
          ),
        ),
        content: Semantics(
          liveRegion: true,
          container: true,
          label: message,
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Semantics(
                label: 'Dismiss notification',
                button: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => messenger?.hideCurrentSnackBar(),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
