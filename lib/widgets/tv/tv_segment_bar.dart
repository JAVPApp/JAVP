import 'package:flutter/material.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Horizontal Movies / Series / Settings-style segments for the 10-foot UI.
///
/// Prefer this over [TabBar] on Android TV — Material tabs are hard to land
/// with a D-pad and give a weak focus affordance.
class TvSegmentBar extends StatelessWidget {
  const TvSegmentBar({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.autofocusFirst = false,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: TvFocusable(
                autofocus: autofocusFirst && i == 0,
                borderRadius: AppRadius.pill,
                onSelect: () => onChanged(i),
                child: AnimatedContainer(
                  duration: AppMotion.focus,
                  curve: AppMotion.ease,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(
                    color: i == index
                        ? AppColors.accentSoft
                        : AppColors.surfaceHigh,
                    borderRadius: AppRadius.pillAll,
                    border: Border.all(
                      color: i == index
                          ? AppColors.accent.withValues(alpha: 0.55)
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: i == index ? AppColors.text : AppColors.textMuted,
                      fontWeight:
                          i == index ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
