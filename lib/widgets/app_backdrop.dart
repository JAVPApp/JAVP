import 'package:flutter/material.dart';

import 'package:javp/theme/app_tokens.dart';

/// The ambient wash behind the app shell: a deepening vertical gradient with
/// two soft blooms, matching the aurora on javp.app.
///
/// The site drifts its blooms on a 26-38s loop. Here they are fixed, and the
/// whole thing is painted once into its own layer — an animated full-screen
/// gradient would repaint every pixel every frame for an effect nobody looks
/// at directly.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _BackdropPainter()),
          ),
        ),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter();

  static const _baseWash = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF101218), AppColors.bg, AppColors.bgDeep],
    stops: [0, 0.38, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = _baseWash.createShader(rect));

    // Accent bloom cresting just above the top edge.
    _bloom(
      canvas,
      center: Offset(size.width * 0.5, -size.height * 0.06),
      radiusX: size.width * 0.95,
      radiusY: size.height * 0.30,
      color: const Color(0x38E11D48),
    );
    // Cooler counterweight off the right edge, low enough to read as depth.
    _bloom(
      canvas,
      center: Offset(size.width * 1.05, size.height * 0.34),
      radiusX: size.width * 0.62,
      radiusY: size.height * 0.24,
      color: const Color(0x2E8128B4),
    );
  }

  void _bloom(
    Canvas canvas, {
    required Offset center,
    required double radiusX,
    required double radiusY,
    required Color color,
  }) {
    if (radiusX <= 0 || radiusY <= 0) return;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, radiusY / radiusX);
    final bounds = Rect.fromCircle(center: Offset.zero, radius: radiusX);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
        stops: const [0, 0.62],
      ).createShader(bounds);
    canvas.drawCircle(Offset.zero, radiusX, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) => false;
}
