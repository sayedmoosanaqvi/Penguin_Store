import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PremiumInteractiveCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double scaleFactor;

  const PremiumInteractiveCard({
    super.key,
    required this.child,
    required this.onTap,
    this.scaleFactor = 0.96, // Shrinks to 96% size on tap
  });

  @override
  State<PremiumInteractiveCard> createState() => _PremiumInteractiveCardState();
}

class _PremiumInteractiveCardState extends State<PremiumInteractiveCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        // Triggers a subtle physical vibration on the device
        HapticFeedback.lightImpact(); 
        setState(() => _isPressed = true);
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? widget.scaleFactor : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}