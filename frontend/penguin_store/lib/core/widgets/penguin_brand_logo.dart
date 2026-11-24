import 'package:flutter/material.dart';

/// Bulletproof, zero-latency reusable Penguin Store brand emblem.
///
/// Loads the locally bundled `'assets/images/penguin_logo.png'` (no leading slash,
/// works identically on GitHub Pages `/Penguin_Store/` and root `penguinstore.co/`),
/// with an automatic `errorBuilder` falling back to a custom Canvas vector crest
/// so it can NEVER display a broken-image cross icon.
class PenguinBrandLogo extends StatelessWidget {
  final double size;
  final bool onLightBackground;
  final bool showGlow;

  const PenguinBrandLogo({
    super.key,
    this.size = 34,
    this.onLightBackground = false,
    this.showGlow = false,
  });

  static const String assetPath = 'assets/images/penguin_logo.png';

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.28);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          colors: onLightBackground
              ? const [Color(0xFF1E88E5), Color(0xFF00ACC1)]
              : [
                  Colors.white.withValues(alpha: 0.24),
                  Colors.white.withValues(alpha: 0.10),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: Colors.white.withValues(
            alpha: onLightBackground ? 0.28 : 0.52,
          ),
          width: 1.2,
        ),
        boxShadow: (onLightBackground || showGlow)
            ? [
                BoxShadow(
                  color: const Color(0xFF1E88E5).withValues(
                    alpha: showGlow ? 0.42 : 0.26,
                  ),
                  blurRadius: showGlow ? 20 : 10,
                  spreadRadius: showGlow ? 2 : 0,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular((size * 0.28 - 1.2).clamp(4.0, 40.0)),
        child: Image.asset(
          assetPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => Center(
            child: CustomPaint(
              size: Size.square(size * 0.68),
              painter: const PenguinVectorCrestPainter(),
            ),
          ),
        ),
      ),
    );
  }
}

class PenguinVectorCrestPainter extends CustomPainter {
  const PenguinVectorCrestPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final darkBody = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    final whiteBelly = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final beakPaint = Paint()
      ..color = const Color(0xFFFFB300)
      ..style = PaintingStyle.fill;

    final body = Path()
      ..moveTo(w * 0.5, h * 0.06)
      ..cubicTo(w * 0.78, h * 0.06, w * 0.88, h * 0.42, w * 0.88, h * 0.72)
      ..quadraticBezierTo(w * 0.88, h * 0.94, w * 0.5, h * 0.94)
      ..quadraticBezierTo(w * 0.12, h * 0.94, w * 0.12, h * 0.72)
      ..cubicTo(w * 0.12, h * 0.42, w * 0.22, h * 0.06, w * 0.5, h * 0.06)
      ..close();
    canvas.drawPath(body, darkBody);

    final belly = Path()
      ..moveTo(w * 0.5, h * 0.34)
      ..cubicTo(w * 0.72, h * 0.34, w * 0.76, h * 0.62, w * 0.72, h * 0.84)
      ..quadraticBezierTo(w * 0.5, h * 0.92, w * 0.28, h * 0.84)
      ..cubicTo(w * 0.24, h * 0.62, w * 0.28, h * 0.34, w * 0.5, h * 0.34)
      ..close();
    canvas.drawPath(belly, whiteBelly);

    canvas.drawCircle(Offset(w * 0.39, h * 0.26), w * 0.055, whiteBelly);
    canvas.drawCircle(Offset(w * 0.61, h * 0.26), w * 0.055, whiteBelly);

    final beak = Path()
      ..moveTo(w * 0.42, h * 0.32)
      ..lineTo(w * 0.58, h * 0.32)
      ..lineTo(w * 0.50, h * 0.44)
      ..close();
    canvas.drawPath(beak, beakPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
