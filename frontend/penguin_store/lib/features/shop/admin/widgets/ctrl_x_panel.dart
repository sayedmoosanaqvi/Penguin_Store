import 'package:flutter/material.dart';

class CtrlXPanel extends StatefulWidget {
  const CtrlXPanel({super.key});

  @override
  State<CtrlXPanel> createState() => _CtrlXPanelState();
}

class _CtrlXPanelState extends State<CtrlXPanel> {
  final TextEditingController _commandController = TextEditingController();
  final List<Map<String, String>> _messages = [
    {
      "sender": "CTRL-X",
      "text": "System Online. I am monitoring the Penguin Store. How can I assist you today?"
    }
  ];

  void _sendCommand() {
    if (_commandController.text.trim().isEmpty) return;

    setState(() {
      // 1. Add user command to the chat
      _messages.add({"sender": "Admin", "text": _commandController.text});
      
      // 2. Add a temporary "thinking" message
      _messages.add({"sender": "CTRL-X", "text": "Processing command..."});
    });

    final sentText = _commandController.text;
    _commandController.clear();

    // TODO: Send 'sentText' to your FastAPI backend here!
    // For now, we simulate a response after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      setState(() {
        _messages.removeLast(); // Remove "Processing..."
        _messages.add({
          "sender": "CTRL-X",
          "text": "I have received your command to: '$sentText'. Awaiting Aura backend connection to execute."
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A), // Deep futuristic dark blue/black
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border(bottom: BorderSide(color: Colors.cyanAccent.withOpacity(0.3))),
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
                  alignment: isAdmin ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: isAdmin ? Colors.cyan.withOpacity(0.2) : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isAdmin ? Colors.cyanAccent.withOpacity(0.5) : Colors.white12,
                      ),
                    ),
                    child: Text(
                      msg["text"]!,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
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
                // Voice Command Button
                IconButton(
                  icon: const Icon(Icons.mic, color: Colors.white54),
                  onPressed: () {
                    // TODO: Implement speech_to_text package here
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Voice integration pending...')),
                    );
                  },
                ),
                // Text Input
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Enter a command...",
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendCommand(),
                  ),
                ),
                // Send Button
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.cyanAccent),
                  onPressed: _sendCommand,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}