import 'package:flutter/material.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';
import 'package:javp/widgets/desktop/hover_marquee_text.dart';
import 'package:javp/widgets/glow_progress_bar.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// MyCanal-style live “On now” card: program art, progress, readable channel chip.
///
/// Use [compact] in narrow panels (player browse sidebar) so suggestions stay
/// scannable instead of stacking full 16:9 tiles.
class NowOnCard extends StatelessWidget {
  const NowOnCard({
    super.key,
    required this.channel,
    required this.program,
    required this.channelLabel,
    required this.onTap,
    this.onLongPress,
    this.onPlayFromStart,
    this.compact = false,
  });

  final MediaItem channel;
  final EpgProgram program;
  final String channelLabel;
  final VoidCallback onTap;

  /// Touch long-press / mouse right-click. Desktop passes the pointer [anchor].
  final void Function(Offset? anchor)? onLongPress;
  final VoidCallback? onPlayFromStart;

  /// Horizontal row layout for side panels / dense lists.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final progress = program.progressAt(now);
    final art = (program.imageUrl?.trim().isNotEmpty ?? false)
        ? program.imageUrl!.trim()
        : channel.artUrl;
    final logo = channel.thumbnailUrl?.trim();
    final secondary = [
      if (channel.group != null && channel.group!.trim().isNotEmpty)
        channel.group!.trim(),
      if (program.description != null && program.description!.trim().isNotEmpty)
        program.description!.trim(),
    ].join(' · ');

    final card = compact
        ? _compactBody(
            context,
            art: art,
            logo: logo,
            progress: progress,
            secondary: secondary,
          )
        : _heroPoster(
            context,
            art: art,
            logo: logo,
            progress: progress,
          );

    final Widget poster = _interactive(
      context,
      child: card,
      lift: !compact,
    );

    if (compact) {
      return Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: poster),
              if (onPlayFromStart != null && !TvPlatform.isAndroidTv)
                _startOverButton(context, compact: true),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: 248,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          poster,
          const SizedBox(height: 8),
          _heroMeta(context, secondary: secondary),
        ],
      ),
    );
  }

  Widget _interactive(
    BuildContext context, {
    required Widget child,
    required bool lift,
  }) {
    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        onSelect: onTap,
        borderRadius: compact ? 10 : 12,
        expandOnFocus: lift,
        child: child,
      );
    }
    if (DesktopUi.enabled) {
      return DesktopHoverTile(
        radius: compact ? 10 : 12,
        onTap: onTap,
        onSecondaryTap: onLongPress != null ? () => onLongPress!(null) : null,
        onSecondaryTapAt: onLongPress != null
            ? (position) => onLongPress!(position)
            : null,
        showPlayBadge: lift,
        child: child,
      );
    }
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress != null ? () => onLongPress!(null) : null,
      borderRadius: BorderRadius.circular(compact ? 10 : 12),
      child: child,
    );
  }

  Widget _compactBody(
    BuildContext context, {
    required String? art,
    required String? logo,
    required double progress,
    required String secondary,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 112,
                height: 63,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: AppColors.surface),
                    if (art != null && art.isNotEmpty)
                      JavpArt(url: art, decodeWidth: 224),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: GlowProgressBar(
                        value: progress,
                        trackColor: Colors.white24,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (logo != null && logo.isNotEmpty) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: JavpArt(
                              url: logo,
                              fit: BoxFit.contain,
                              decodeWidth: 32,
                              fallback: const ColoredBox(
                                color: AppColors.surface,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(
                          channelLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  HoverMarqueeText(
                    text: program.title,
                    maxLines: 2,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      height: 1.15,
                    ),
                  ),
                  if (secondary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textDim,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
  }

  Widget _heroPoster(
    BuildContext context, {
    required String? art,
    required String? logo,
    required double progress,
  }) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.surfaceHigh, AppColors.surface],
                ),
              ),
            ),
            if (art != null && art.isNotEmpty)
              JavpArt(url: art, decodeWidth: 496),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x22000000), Color(0x88000000)],
                ),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 10,
              right: 8,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 200),
                  padding: const EdgeInsets.fromLTRB(4, 3, 8, 3),
                  decoration: BoxDecoration(
                    color: const Color(0xE612141A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (logo != null && logo.isNotEmpty) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: JavpArt(
                              url: logo,
                              fit: BoxFit.contain,
                              decodeWidth: 44,
                              fallback: const ColoredBox(
                                color: AppColors.surfaceHigh,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          channelLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GlowProgressBar(
                value: progress,
                trackColor: Colors.white24,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: const Color(0x14FFFFFF)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroMeta(BuildContext context, {required String secondary}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  program.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (secondary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (onPlayFromStart != null && !TvPlatform.isAndroidTv)
          _startOverButton(context, compact: false),
      ],
    );
  }

  Widget _startOverButton(BuildContext context, {required bool compact}) {
    return IconButton(
      tooltip: context.l10n.watchFromStart,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(
        minWidth: compact ? 32 : 36,
        minHeight: compact ? 32 : 36,
      ),
      padding: EdgeInsets.zero,
      onPressed: onPlayFromStart,
      icon: Icon(
        Icons.skip_previous_rounded,
        size: compact ? 20 : 22,
        color: AppColors.textMuted,
      ),
    );
  }
}
