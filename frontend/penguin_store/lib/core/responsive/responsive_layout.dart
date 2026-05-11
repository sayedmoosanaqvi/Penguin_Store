import 'package:flutter/material.dart';

class ResponsiveLayout extends StatelessWidget {
  final Widget mobile;
  final Widget desktop;

  const ResponsiveLayout({
    super.key,
    required this.mobile,
    required this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // If screen width is less than 800 pixels, it's a mobile/tablet screen
        if (constraints.maxWidth < 800) {
          return mobile;
        } 
        // Otherwise, it's a desktop/web screen
        else {
          return desktop;
        }
      },
    );
  }
}