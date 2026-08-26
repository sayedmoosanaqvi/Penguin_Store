import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../core/theme/app_colors.dart';

class CtrlXScreen extends StatefulWidget {
  const CtrlXScreen({super.key});

  @override
  State<CtrlXScreen> createState() => _CtrlXScreenState();
}

class _CtrlXScreenState extends State<CtrlXScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false; // Tracks if the AI is "thinking"

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({"role": "user", "text": text});
      _isLoading = true;
    });

    _controller.clear();

    try {
      // Assuming you are running this on Flutter Web (localhost)
      // If testing on an Android emulator later, change 127.0.0.1 to 10.0.2.2
      final url = Uri.parse('http://127.0.0.1:8000/api/agent/chat');
      
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "user_input": text,
          "thread_id": "flutter_user_session" // Hardcoded for now; can be dynamic later
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // Handle both standard success and HitL "paused" status messages
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('CTRL‑X Assistant'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.whiteText,
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Ask anything to CTRL‑X...',
                      style: TextStyle(color: AppColors.whiteText),
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
                                ? AppColors.primary
                                : AppColors.card,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            msg["text"] ?? '',
                            style: TextStyle(
                              color: isUser
                                  ? AppColors.background
                                  : AppColors.whiteText,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // Loading indicator shown while waiting for HTTP response
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            color: AppColors.card,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: AppColors.whiteText),
                    enabled: !_isLoading, // Disable input while waiting
                    decoration: InputDecoration(
                      hintText: 'Type your prompt...',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, color: AppColors.primary),
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