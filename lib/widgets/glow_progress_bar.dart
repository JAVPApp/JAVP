import 'package:flutter/material.dart';

import 'package:javp/theme/app_tokens.dart';

/// A thin lit progress bar, matching the scrub bar on javp.app.
///
/// Sits at the foot of poster art and inside player chrome. The glow is a
/// 6px blur — small enough to keep in a scrolling shelf, unlike the wider
/// shadows in [AppShadows].
class GlowProgressBar extends StatelessWidget {
  const GlowProgressBar({
    super.key,
    required this.value,
    this.height = 3,
    this.trackColor = const Color(0x73000000),
    this.color = AppColors.accent,
  });

  final double value;
  final double height;
  final Color trackColor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Thin shelf bars skip the blur — dozens of 6px glows in one row show up
    // as scroll jank on desktop; player chrome still wants the lit look.
    final glow = height >= 4;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: trackColor),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                boxShadow: glow ? AppShadows.progressGlow : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
