import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _videoController;
  late final AnimationController _pulseController;

  bool _isVideoReady = false;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _initializeSplash();
  }

  Future<void> _initializeSplash() async {
    try {
      final controller = VideoPlayerController.asset(
        'assets/videos/penguinstore_splash_animation.mp4',
      );
      _videoController = controller;

      await controller.initialize().timeout(
        const Duration(milliseconds: 2200),
      );

      if (!mounted) return;

      await controller.setLooping(false);
      await controller.setVolume(0);

      if (mounted) {
        setState(() => _isVideoReady = true);
      }

      await controller.play();

      final duration = controller.value.duration;
      final waitTime = (duration > Duration.zero &&
              duration <= const Duration(seconds: 4))
          ? duration
          : const Duration(milliseconds: 2200);

      await Future.delayed(waitTime);
      _navigateHome();
    } catch (e) {
      debugPrint('Splash video skipped (using PenguinBrandLogo splash): $e');
      await Future.delayed(const Duration(milliseconds: 1500));
      _navigateHome();
    }
  }

  void _navigateHome() {
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;
    context.go('/');
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasValidVideo = _isVideoReady &&
        _videoController != null &&
        _videoController!.value.isInitialized &&
        _videoController!.value.size.width > 0;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0A192F),
              Color(0xFF1565C0),
              Color(0xFF00ACC1),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SnowfallBackground(
          flakes: 26,
          child: Center(
            child: hasValidVideo
                ? ColoredBox(
                    color: Colors.white,
                    child: SizedBox.expand(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: _videoController!.value.size.width,
                          height: _videoController!.value.size.height,
                          child: VideoPlayer(_videoController!),
                        ),
                      ),
                    ),
                  )
                : AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final scale = 0.96 + 0.06 * _pulseController.value;
                      return Transform.scale(scale: scale, child: child);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const PenguinBrandLogo(
                          size: 108,
                          showGlow: true,
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          'Penguin Store',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'AI-Powered 3D & Voice Commerce',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.82),
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 26),
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
