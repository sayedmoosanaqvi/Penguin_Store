import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/api_error_handler.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/commerce_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

class NotificationScreen extends StatefulWidget {
  final String userEmail;

  const NotificationScreen({super.key, required this.userEmail});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final CommerceService _commerce = CommerceService();
  bool _isLoading = true;
  bool _markingAll = false;
  List<dynamic> _notifications = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchNotifications();
  }

  Future<Map<String, String>> _buildAuthHeaders() async {
    final token = (await SecureStorageService.getToken())?.trim();
    return {
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  void _syncUnreadBadge() {
    if (!mounted) return;
    final unread =
        _notifications.where((n) => n is Map && n['is_read'] != true).length;
    context.read<ShopStateProvider>().setUnreadNotifications(unread);
  }

  Future<void> _fetchNotifications() async {
    if (widget.userEmail.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please log in to view notifications.';
        _isLoading = false;
      });
      return;
    }

    try {
      await _commerce.checkSmartNotifications();
      final headers = await _buildAuthHeaders();
      final response = await http
          .get(
            Uri.parse(
              '${ApiConfig.baseUrl}/api/notifications/${Uri.encodeComponent(widget.userEmail.trim())}',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 25));

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _notifications = json.decode(response.body) as List<dynamic>;
          _isLoading = false;
          _errorMessage = null;
        });
        _syncUnreadBadge();
      } else {
        setState(() {
          _errorMessage = ApiErrorHandler.fromStatus(
            response.statusCode,
            response.body,
            fallback: 'Failed to load notifications.',
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = ApiErrorHandler.sanitize(e);
        _isLoading = false;
      });
    }
  }

  Future<void> _markAsRead(int id, Map<dynamic, dynamic> notif) async {
    if (notif['is_read'] != true) {
      try {
        final headers = await _buildAuthHeaders();
        final response = await http
            .put(
              Uri.parse('${ApiConfig.baseUrl}/api/notifications/$id/read'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 12));

        if (mounted && response.statusCode == 200) {
          setState(() {
            notif['is_read'] = true;
          });
          _syncUnreadBadge();
        }
      } catch (e) {
        debugPrint('Failed to mark as read: $e');
      }
    }

    if (!mounted) return;
    final route = notif['action_route']?.toString().trim() ?? '';
    if (route.startsWith('/')) {
      context.push(route);
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    setState(() => _markingAll = true);
    try {
      final ok = await _commerce.markAllNotificationsRead();
      if (!mounted) return;
      if (ok) {
        setState(() {
          for (final item in _notifications) {
            if (item is Map) item['is_read'] = true;
          }
        });
        _syncUnreadBadge();
        CustomToast.show(context, 'All notifications marked as read.');
      }
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  bool _isOrderNotif(Map<dynamic, dynamic> n) {
    final cat = (n['category'] ?? '').toString().toUpperCase();
    final kind = (n['notification_type'] ?? '').toString().toUpperCase();
    return cat == 'ORDER' || kind == 'ORDER';
  }

  IconData _iconFor(Map<dynamic, dynamic> n) {
    final cat =
        (n['category'] ?? n['notification_type'] ?? '').toString().toUpperCase();
    if (cat.contains('ORDER')) return Icons.local_shipping_outlined;
    if (cat.contains('PRICE')) return Icons.trending_down_rounded;
    if (cat.contains('REVIEW')) return Icons.rate_review_outlined;
    return Icons.notifications_active_outlined;
  }

  Widget _buildSkeleton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        highlightColor: isDark ? Colors.grey.shade700 : Colors.grey.shade50,
        child: Container(
          height: 82,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<dynamic> items, ThemeData theme) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No notifications in this category.',
          style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontSize: 15),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchNotifications,
      child: ListView.builder(
        padding: const EdgeInsets.all(14),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final notif = items[index] as Map;
          final bool isRead = notif['is_read'] == true;
          final catLabel =
              (notif['category'] ?? notif['notification_type'] ?? 'SYSTEM')
                  .toString()
                  .replaceAll('_', ' ');

          return FadeSlideIn.staggered(
            index: index,
            child: Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: isRead ? 0 : 1,
              color: isRead
                  ? theme.colorScheme.surface
                  : theme.primaryColor.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isRead
                      ? theme.dividerColor.withValues(alpha: 0.2)
                      : theme.primaryColor.withValues(alpha: 0.35),
                ),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                leading: CircleAvatar(
                  backgroundColor: isRead
                      ? Colors.grey.withValues(alpha: 0.14)
                      : theme.primaryColor.withValues(alpha: 0.16),
                  child: Icon(
                    _iconFor(notif),
                    color: isRead ? Colors.grey : theme.primaryColor,
                    size: 20,
                  ),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (notif['title'] ?? 'Update').toString(),
                        style: TextStyle(
                          fontWeight: isRead ? FontWeight.w600 : FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        catLabel,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: theme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    (notif['message'] ?? '').toString(),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                onTap: () => _markAsRead((notif['id'] as num).toInt(), notif),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unreadCount =
        _notifications.where((n) => n is Map && n['is_read'] != true).length;
    final orderItems = _notifications
        .where((n) => n is Map && _isOrderNotif(n))
        .toList();
    final alertItems = _notifications
        .where((n) => n is Map && !_isOrderNotif(n))
        .toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            unreadCount > 0 ? 'Notifications ($unreadCount)' : 'Notifications',
          ),
          backgroundColor: theme.appBarTheme.backgroundColor,
          foregroundColor: theme.appBarTheme.foregroundColor,
          actions: [
            if (unreadCount > 0)
              TextButton.icon(
                onPressed: _markingAll ? null : _markAllRead,
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('Read All'),
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: 'All (${_notifications.length})'),
              Tab(text: 'Orders (${orderItems.length})'),
              Tab(text: 'Alerts & Deals (${alertItems.length})'),
            ],
          ),
        ),
        body: _isLoading
            ? _buildSkeleton(theme)
            : _errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  )
                : TabBarView(
                    children: [
                      _buildList(_notifications, theme),
                      _buildList(orderItems, theme),
                      _buildList(alertItems, theme),
                    ],
                  ),
      ),
    );
  }
}
