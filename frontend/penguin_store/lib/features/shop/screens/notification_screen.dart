import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';

class NotificationScreen extends StatefulWidget {
  final String userEmail;

  const NotificationScreen({super.key, required this.userEmail});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  bool _isLoading = true;
  List<dynamic> _notifications = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchNotifications();
  }

  Future<void> _fetchNotifications() async {
    if (widget.userEmail.isEmpty) {
      setState(() {
        _errorMessage = "Please log in to view notifications.";
        _isLoading = false;
      });
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/notifications/${widget.userEmail}'),
      );

      if (response.statusCode == 200) {
        setState(() {
          _notifications = json.decode(response.body);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to load notifications.';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error connecting to server: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _markAsRead(int id, int index) async {
    if (_notifications[index]['is_read']) return; // Skip if already read

    try {
      final response = await http.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notifications/$id/read'),
      );

      if (response.statusCode == 200) {
        setState(() {
          _notifications[index]['is_read'] = true;
        });
      }
    } catch (e) {
      debugPrint("Failed to mark as read: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: theme.primaryColor))
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)))
              : _notifications.isEmpty
                  ? Center(
                      child: Text(
                        'No new notifications.',
                        style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _notifications.length,
                      itemBuilder: (context, index) {
                        final notif = _notifications[index];
                        final bool isRead = notif['is_read'];

                        return ListTile(
                          tileColor: isRead ? Colors.transparent : theme.primaryColor.withOpacity(0.1),
                          leading: Icon(
                            notif['notification_type'] == 'ORDER' ? Icons.local_shipping : Icons.notifications,
                            color: isRead ? Colors.grey : theme.primaryColor,
                          ),
                          title: Text(
                            notif['title'],
                            style: TextStyle(
                              fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                              color: theme.textTheme.titleMedium?.color,
                            ),
                          ),
                          subtitle: Text(
                            notif['message'],
                            style: TextStyle(color: theme.textTheme.bodySmall?.color),
                          ),
                          onTap: () => _markAsRead(notif['id'], index),
                        );
                      },
                    ),
    );
  }
}