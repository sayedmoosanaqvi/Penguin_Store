import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';

class CtrlXScreen extends StatefulWidget {
  const CtrlXScreen({super.key});

  @override
  State<CtrlXScreen> createState() => _CtrlXScreenState();
}

class _CtrlXScreenState extends State<CtrlXScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({"role": "user", "text": text});
      _isLoading = true;
    });

    _controller.clear();

    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/agent/chat');
      
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "user_input": text,
          "thread_id": "flutter_user_session"
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiReply = data['response'] ?? data['message'] ?? "No response received.";
        
        setState(() {
          _messages.add({"role": "bot", "text": aiReply});
        });
      } else {
        setState(() {
          _messages.add({"role": "bot", "text": "Error: Server returned ${response.statusCode}"});
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({"role": "bot", "text": "Failed to connect to AI server. Make sure FastAPI is running."});
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('CTRL‑X Assistant'),
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: theme.appBarTheme.foregroundColor,
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'Ask anything to CTRL‑X...',
                      style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg["role"] == "user";
                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isUser
                                ? theme.primaryColor
                                : theme.cardTheme.color,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            msg["text"] ?? '',
                            style: TextStyle(
                              color: isUser
                                  ? theme.scaffoldBackgroundColor
                                  : theme.textTheme.bodyLarge?.color,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: CircularProgressIndicator(color: theme.primaryColor),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            color: theme.cardTheme.color,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                    enabled: !_isLoading,
                    onSubmitted: (_) {
                      if (!_isLoading) {
                        _sendMessage();
                      }
                    },
                    decoration: InputDecoration(
                      hintText: 'Type your prompt...',
                      hintStyle: TextStyle(color: theme.textTheme.bodySmall?.color),
                      filled: true,
                      fillColor: theme.scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.send, color: theme.primaryColor),
                  onPressed: _isLoading ? null : _sendMessage,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}