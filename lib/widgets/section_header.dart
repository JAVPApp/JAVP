import 'package:flutter/material.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/horizontal_scroll_text.dart';
import 'package:javp/widgets/kicker.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.kicker,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.favorited,
    this.onFavorite,
  });

  final String title;

  /// Optional accent label above the title, as on the marketing site.
  final String? kicker;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// When set with [onFavorite], shows a star control before the action.
  final bool? favorited;
  final VoidCallback? onFavorite;

  @override
  Widget build(BuildContext context) {
    final action = actionLabel == null
        ? null
        : TextButton(
            onPressed: onAction,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  actionLabel!,
                  style: const TextStyle(color: AppColors.accentHi),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppColors.accentHi,
                ),
              ],
            ),
          );

    final favorite = onFavorite == null
        ? null
        : IconButton(
            tooltip: favorited == true ? 'Favorited' : 'Favorite',
            onPressed: onFavorite,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              favorited == true
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              color: favorited == true ? AppColors.accent : AppColors.textMuted,
            ),
          );

    return Padding(
      padding: AppLayout.sectionHeaderPadding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (kicker != null) ...[
                  Kicker(kicker!),
                  const SizedBox(height: 5),
                ],
                HorizontalScrollText(
                  text: title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          if (favorite != null)
            TvPlatform.isAndroidTv
                ? TvFocusable(
                    borderRadius: 24,
                    skipTraversalUnlessNearby: true,
                    onSelect: onFavorite,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        favorited == true
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: favorited == true
                            ? AppColors.accent
                            : AppColors.textMuted,
                      ),
                    ),
                  )
                : favorite,
          if (action != null)
            TvPlatform.isAndroidTv
                ? TvFocusable(
                    borderRadius: 10,
                    skipTraversalUnlessNearby: true,
                    onSelect: onAction,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        actionLabel!,
                        style: const TextStyle(color: AppColors.accent),
                      ),
                    ),
                  )
                : action,
        ],
      ),
    );
  }
}
