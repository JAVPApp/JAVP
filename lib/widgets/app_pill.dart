import 'package:flutter/material.dart';

import 'package:javp/theme/app_tokens.dart';

/// The site's eyebrow badge: a hairline capsule with an optional status dot.
///
/// Used for statuses that sit beside a heading — "Live now", "4K", "Offline".
class AppPill extends StatelessWidget {
  const AppPill({
    super.key,
    required this.label,
    this.dotColor,
    this.icon,
    this.foreground = AppColors.textMuted,
  });

  /// A live indicator with the green status dot.
  const AppPill.live({super.key, required this.label})
      : dotColor = AppColors.live,
        icon = null,
        foreground = AppColors.textMuted;

  final String label;

  /// Draws a small filled dot before the label, with a matching halo.
  final Color? dotColor;
  final IconData? icon;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(dotColor != null ? 10 : 13, 6, 13, 6),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            _StatusDot(color: dotColor!),
            const SizedBox(width: 9),
          ] else if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 7),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
          ),
        ],
      ),
    );
  }
}

/// The site pulses this dot on a 2.4s loop. A permanently animating widget
/// keeps the raster thread awake for as long as it is on screen, so here the
/// halo is baked in instead.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 6),
        ],
      ),
    );
  }
}
