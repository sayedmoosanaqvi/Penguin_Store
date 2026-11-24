import 'dart:math' as math;

import 'package:flutter/material.dart';

export 'package:penguin_store/core/widgets/penguin_brand_logo.dart';

/// Penguin brand motion kit: reusable, dependency-free animations.

/// Fades + slides its child in once, optionally after [delay].
/// Use [FadeSlideIn.staggered] inside lists/grids for a cascading entrance.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final Curve curve;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 520),
    this.offset = const Offset(0, 0.08),
    this.curve = Curves.easeOutCubic,
  });

  /// Delay grows with [index] but is capped so long lists never feel slow.
  factory FadeSlideIn.staggered({
    Key? key,
    required int index,
    required Widget child,
    int stepMs = 55,
    int maxSteps = 8,
  }) {
    return FadeSlideIn(
      key: key,
      delay: Duration(milliseconds: math.min(index, maxSteps) * stepMs),
      child: child,
    );
  }

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    final curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _opacity = curved;
    _slide = Tween<Offset>(begin: widget.offset, end: Offset.zero)
        .animate(curved);

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Gentle press-in scale feedback for any tappable surface.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: reduceMotion
          ? widget.child
          : AnimatedScale(
              scale: _down ? widget.scale : 1,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut,
              child: widget.child,
            ),
    );
  }
}

/// Soft falling snow: the Penguin brand moment. Cheap (one painter, ~30
/// flakes) and wrapped in a RepaintBoundary.
class SnowfallBackground extends StatefulWidget {
  final Widget? child;
  final int flakes;
  final Color color;
  final double speed;

  const SnowfallBackground({
    super.key,
    this.child,
    this.flakes = 28,
    this.color = Colors.white,
    this.speed = 1,
  });

  @override
  State<SnowfallBackground> createState() => _SnowfallBackgroundState();
}

class _Flake {
  final double x, size, speed, drift, phase;
  const _Flake(this.x, this.size, this.speed, this.drift, this.phase);
}

class _SnowfallBackgroundState extends State<SnowfallBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Flake> _flakes;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    _flakes = List.generate(widget.flakes, (_) {
      return _Flake(
        rnd.nextDouble(),
        1.2 + rnd.nextDouble() * 2.6,
        0.35 + rnd.nextDouble() * 0.9,
        8 + rnd.nextDouble() * 18,
        rnd.nextDouble() * math.pi * 2,
      );
    });
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child ?? const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => CustomPaint(
                  painter: _SnowPainter(
                    _flakes,
                    _controller.value,
                    widget.color,
                    widget.speed,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _SnowPainter extends CustomPainter {
  final List<_Flake> flakes;
  final double t;
  final Color color;
  final double speed;

  _SnowPainter(this.flakes, this.t, this.color, this.speed);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final f in flakes) {
      final progress = (t * f.speed * speed * 6 + f.phase) % 1.0;
      final y = progress * (size.height + 12) - 6;
      final x = f.x * size.width +
          math.sin(progress * math.pi * 2 + f.phase) * f.drift;
      paint.color = color.withValues(alpha: 0.25 + (f.size / 4) * 0.45);
      canvas.drawCircle(Offset(x, y), f.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SnowPainter old) => old.t != t;
}

/// Glowing, breathing AI avatar used by the CTRL-X screens.
class PulsingOrb extends StatefulWidget {
  final double size;
  final IconData icon;
  final List<Color> colors;

  const PulsingOrb({
    super.key,
    this.size = 84,
    this.icon = Icons.auto_awesome_rounded,
    this.colors = const [Color(0xFF42A5F5), Color(0xFF00ACC1)],
  });

  @override
  State<PulsingOrb> createState() => _PulsingOrbState();
}

class _PulsingOrbState extends State<PulsingOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = reduceMotion ? 0.3 : Curves.easeInOut.transform(_c.value);
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: widget.colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.colors.first.withValues(alpha: 0.28 + 0.3 * t),
                  blurRadius: 18 + 26 * t,
                  spreadRadius: 1 + 6 * t,
                ),
              ],
            ),
            child: Transform.scale(
              scale: reduceMotion ? 1.0 : (0.94 + 0.08 * t),
              child: Icon(
                widget.icon,
                color: Colors.white,
                size: widget.size * 0.46,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Three bouncing dots: "the AI is typing".
class TypingDots extends StatefulWidget {
  final Color color;
  const TypingDots({super.key, this.color = const Color(0xFF1E88E5)});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = ((_c.value - i * 0.16) % 1.0);
            final bump = math.sin(phase * math.pi).clamp(0.0, 1.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: 7,
              height: 7,
              transform: Matrix4.translationValues(0, -4 * bump, 0),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.35 + 0.65 * bump),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Pulsing "3D" pill used on product cards and filters.
class Badge3D extends StatefulWidget {
  final bool compact;
  const Badge3D({super.key, this.compact = false});

  @override
  State<Badge3D> createState() => _Badge3DState();
}

class _Badge3DState extends State<Badge3D>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 6 : 8,
            vertical: widget.compact ? 2 : 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E88E5)
                    .withValues(alpha: 0.25 + 0.3 * _c.value),
                blurRadius: 6 + 6 * _c.value,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_in_ar_rounded,
                  color: Colors.white, size: widget.compact ? 10 : 12),
              const SizedBox(width: 3),
              Text(
                '3D',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.compact ? 8.5 : 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// PenguinBrandLogo is defined in `penguin_brand_logo.dart` and re-exported above.

/// Modern, crisp circular account avatar with icy-blue gradient ring,
/// user initial (or sharp person glyph for guests), online indicator dot,
/// and admin shield badge.
class PenguinAccountAvatar extends StatelessWidget {
  final double size;
  final bool isAuthenticated;
  final bool isAdmin;
  final String? email;
  final bool lightRingOnPrimaryBar;

  const PenguinAccountAvatar({
    super.key,
    this.size = 36,
    this.isAuthenticated = false,
    this.isAdmin = false,
    this.email,
    this.lightRingOnPrimaryBar = false,
  });

  String? get _initial {
    final trimmed = email?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final ch = trimmed.characters.first.toUpperCase();
    return RegExp(r'[A-Z0-9]').hasMatch(ch) ? ch : null;
  }

  @override
  Widget build(BuildContext context) {
    final initial = isAuthenticated ? _initial : null;

    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: lightRingOnPrimaryBar
                    ? const [Color(0xFFFFFFFF), Color(0xFFB3E5FC)]
                    : const [Color(0xFF1E88E5), Color(0xFF00ACC1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1E88E5).withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isAuthenticated
                    ? const LinearGradient(
                        colors: [Color(0xFF1565C0), Color(0xFF0097A7)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : const LinearGradient(
                        colors: [Color(0xFFEAF5FF), Color(0xFFD6EBFC)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
              ),
              child: Center(
                child: initial != null
                    ? Text(
                        initial,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size * 0.42,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      )
                    : Icon(
                        isAuthenticated
                            ? Icons.person_rounded
                            : Icons.account_circle_outlined,
                        size: size * 0.56,
                        color: isAuthenticated
                            ? Colors.white
                            : const Color(0xFF1E88E5),
                      ),
              ),
            ),
          ),
          if (isAuthenticated)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: (size * 0.34).clamp(9.0, 18.0),
                height: (size * 0.34).clamp(9.0, 18.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isAdmin
                      ? const Color(0xFF00ACC1)
                      : const Color(0xFF22C55E),
                  border: Border.all(color: Colors.white, width: 1.6),
                ),
                child: isAdmin
                    ? Icon(
                        Icons.verified_rounded,
                        size: (size * 0.21).clamp(6.0, 12.0),
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}
