import 'package:flutter/material.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Trailing AppBar source-filter chip shared by TV and Catalog.
class SourceFilterAppBarChip extends StatelessWidget {
  const SourceFilterAppBarChip({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
    this.accentColor,
  });

  final String label;
  final VoidCallback onTap;

  /// True when a subset is selected (not “All”).
  final bool active;

  /// Optional per-source tint when a single source is filtered.
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final highlight = accentColor ?? AppColors.accent;
    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        borderRadius: 24,
        onSelect: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active && accentColor != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? highlight : null,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: active ? highlight : null,
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? highlight : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active && accentColor != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? highlight : AppColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: active ? highlight : AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
