import 'dart:math';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late AnimationController _logoController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  // Background floating/falling particles controller
  late AnimationController _particleController;

  final List<_FallingParticle> _particles = List.generate(15, (index) => _FallingParticle());

  @override
  void initState() {
    super.initState();
    
    // Logo entrance animation
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _scaleAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeIn),
    );

    _logoController.forward();

    // Continuous motion controller for falling/floating items
    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();

    // Automatically navigate to home after 3 seconds
    Future.delayed(const Duration(milliseconds: 3000), () {
      if (mounted) {
        context.go('/');
      }
    });
  }

  @override
  void dispose() {
    _logoController.dispose();
    _particleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Dynamic Falling / Floating Background Elements
          AnimatedBuilder(
            animation: _particleController,
            builder: (context, child) {
              return CustomPaint(
                painter: _ParticlePainter(
                  animationValue: _particleController.value,
                  particles: _particles,
                  primaryColor: theme.primaryColor,
                ),
                child: const SizedBox.expand(),
              );
            },
          ),
          
          // Centered Branded Logo Entry Animation
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: theme.primaryColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.4),
                            blurRadius: 30,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.storefront,
                        size: 65,
                        color: theme.scaffoldBackgroundColor,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'PENGUIN STORE',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3.0,
                        color: theme.textTheme.titleLarge?.color,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Next-Gen Commerce Experience',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.textTheme.bodySmall?.color,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Particle model for real falling/floating physics behavior
class _FallingParticle {
  double x = Random().nextDouble();
  double y = Random().nextDouble() * -1.0; // Start above screen
  double speed = 0.2 + Random().nextDouble() * 0.5;
  double size = 8.0 + Random().nextDouble() * 16.0;
  double opacity = 0.1 + Random().nextDouble() * 0.3;
}

// Custom painter to render falling items smoothly across the screen
class _ParticlePainter extends CustomPainter {
  final double animationValue;
  final List<_FallingParticle> particles;
  final Color primaryColor;

  _ParticlePainter({
    required this.animationValue,
    required this.particles,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    for (var p in particles) {
      // Calculate real falling movement down the Y axis
      double currentY = (p.y + (animationValue * p.speed)) % 1.2;
      double currentX = p.x * size.width;
      double renderY = currentY * size.height;

      paint.color = primaryColor.withOpacity(p.opacity);
      
      // Draw smooth falling circles or shopping item indicators
      canvas.drawCircle(Offset(currentX, renderY), p.size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}