import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/secure_storage_service.dart';

class CtrlXPanel extends StatefulWidget {
  const CtrlXPanel({super.key});

  @override
  State<CtrlXPanel> createState() => _CtrlXPanelState();
}

class _CtrlXPanelState extends State<CtrlXPanel> {
  final TextEditingController _commandController = TextEditingController();
  bool _isSending = false;

  final List<Map<String, String>> _messages = [
    {
      "sender": "CTRL-X",
      "text":
          "System Online. I am monitoring the Penguin Store. Ask for an inventory report, low-stock alerts, or store telemetry."
    }
  ];

  @override
  void dispose() {
    _commandController.dispose();
    super.dispose();
  }

  Future<void> _sendCommand() async {
    final sentText = _commandController.text.trim();
    if (sentText.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
      _messages.add({"sender": "Admin", "text": sentText});
      _messages.add({"sender": "CTRL-X", "text": "Processing command..."});
    });

    _commandController.clear();

    try {
      final token = (await SecureStorageService.getToken())?.trim();
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

      http.Response response;
      if (token != null && token.isNotEmpty) {
        response = await http
            .post(
              Uri.parse('$base/api/agent/admin-command'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'command': sentText}),
            )
            .timeout(const Duration(seconds: 30));
      } else {
        response = await http
            .post(
              Uri.parse('$base/api/agent/chat'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'user_input': sentText,
                'thread_id': 'admin-console-session',
              }),
            )
            .timeout(const Duration(seconds: 30));
      }

      if (!mounted) return;

      String reply = "Command executed.";
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['response'] is String) {
          reply = decoded['response'] as String;
        }
      } else {
        reply =
            "CTRL-X returned HTTP ${response.statusCode}. Verify admin session.";
      }

      setState(() {
        _messages.removeLast();
        _messages.add({
          "sender": "CTRL-X",
          "text": reply,
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.removeLast();
        _messages.add({
          "sender": "CTRL-X",
          "text": "Unable to reach backend server: $e",
        });
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border(
                bottom: BorderSide(
                  color: Colors.cyanAccent.withOpacity(0.3),
                ),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.memory, color: Colors.cyanAccent),
                SizedBox(width: 10),
                Text(
                  "CTRL-X STORE MANAGER",
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),

          // Chat Messages Area
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isAdmin = msg["sender"] == "Admin";
                return Align(
                  alignment:
                      isAdmin ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    decoration: BoxDecoration(
                      color: isAdmin
                          ? Colors.cyan.withOpacity(0.2)
                          : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isAdmin
                            ? Colors.cyanAccent.withOpacity(0.5)
                            : Colors.white12,
                      ),
                    ),
                    child: Text(
                      msg["text"]!,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                );
              },
            ),
          ),

          // Input Area
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.analytics_outlined,
                    color: Colors.cyanAccent,
                  ),
                  tooltip: 'Run Store Diagnostic Report',
                  onPressed: _isSending
                      ? null
                      : () {
                          _commandController.text =
                              'Run store inventory status report';
                          _sendCommand();
                        },
                ),
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    enabled: !_isSending,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Enter a store command...",
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendCommand(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.cyanAccent),
                  onPressed: _isSending ? null : _sendCommand,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
