import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  VideoPlayerController? _videoController;

  bool _isReady = false;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();
    _initializeSplash();
  }

  Future<void> _initializeSplash() async {
    try {
      final controller = VideoPlayerController.asset(
        'assets/videos/penguinstore_splash_animation.mp4',
      );

      _videoController = controller;

      await controller.initialize();

      if (!mounted) return;

      await controller.setLooping(false);
      await controller.setVolume(0);

      setState(() => _isReady = true);

      await controller.play();

      final duration = controller.value.duration;

      if (duration > Duration.zero) {
        await Future.delayed(duration);
      } else {
        await Future.delayed(const Duration(milliseconds: 3500));
      }

      _navigateHome();
    } catch (e) {
      debugPrint('Splash animation error: $e');

      await Future.delayed(const Duration(seconds: 3));

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
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: _isReady && _videoController != null
            ? SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: _videoController!.value.size.width,
                    height: _videoController!.value.size.height,
                    child: VideoPlayer(_videoController!),
                  ),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.pets_rounded, size: 58, color: theme.primaryColor),
                  const SizedBox(height: 16),
                  Text(
                    'PenguinStore',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
