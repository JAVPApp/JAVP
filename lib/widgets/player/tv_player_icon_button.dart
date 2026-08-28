import 'package:flutter/material.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Cinema-style player control for Android TV — an icon, not a text chip.
class TvPlayerIconButton extends StatelessWidget {
  const TvPlayerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.primary = false,
    this.caption,
    this.captionBeside = false,
    this.enabled = true,
    this.muted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool primary;
  final String? caption;

  /// Place [caption] to the right of the icon instead of under it.
  final bool captionBeside;
  final bool enabled;

  /// Dim without leaving the D-pad path (e.g. jump-to-live at the live edge).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final disc = primary ? 64.0 : 52.0;
    final glyph = primary ? 36.0 : 28.0;
    final discChild = SizedBox(
      width: disc,
      height: disc,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: primary ? 0.20 : 0.10),
        ),
        child: Icon(icon, size: glyph, color: Colors.white),
      ),
    );
    Widget maybeMute(Widget child) {
      if (!muted) return child;
      return Opacity(opacity: 0.4, child: child);
    }

    if (caption != null && captionBeside) {
      return maybeMute(
        TvFocusable(
          autofocus: autofocus && enabled,
          focusNode: focusNode,
          onSelect: enabled ? onSelect : null,
          enabled: enabled,
          borderRadius: 16,
          padding: const EdgeInsets.only(right: 14),
          child: Semantics(
            button: true,
            enabled: enabled,
            label: tooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                discChild,
                const SizedBox(width: 10),
                Text(
                  caption!,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final button = TvFocusable(
      autofocus: autofocus && enabled,
      focusNode: focusNode,
      onSelect: enabled ? onSelect : null,
      enabled: enabled,
      borderRadius: primary ? disc / 2 : 16,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: discChild,
      ),
    );
    if (caption == null) return maybeMute(button);
    return maybeMute(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button,
          const SizedBox(height: 6),
          SizedBox(
            width: 88,
            child: Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
