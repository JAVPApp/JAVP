import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';
import 'package:javp/widgets/desktop/hover_marquee_text.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/poster_lift.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Series with at least one episode downloaded — browseable like My List.
///
/// Grouped by series so a show with a whole season offline shows once, instead
/// of one row per episode. Tapping opens the series page (with the episode
/// list) rather than a bare player.
class DownloadedSeriesScreen extends StatelessWidget {
  const DownloadedSeriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final series = library.downloadedSeriesItems;
    final l10n = context.l10n;
    final portrait = library.displaySettings.moviesCoverGridPortrait;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.downloadedSeries),
      ),
      body: series.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_outlined,
                      size: 52,
                      color: AppColors.textMuted.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.nothingSavedOfflineYet,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.downloadEpisodesHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            )
          : GridView.builder(
              padding: AppLayout.pagePadding(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: AdaptiveLayout.posterGridColumns(
                  AdaptiveLayout.contentWidth(context),
                ),
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: AdaptiveLayout.posterGridChildAspectRatio(
                  portrait: portrait,
                ),
              ),
              itemCount: series.length,
              itemBuilder: (context, index) {
                final item = series[index];
                return _SeriesCell(
                  item: item,
                  portrait: portrait,
                  onTap: () => context.push('/series', extra: item),
                );
              },
            ),
    );
  }
}

class _SeriesCell extends StatelessWidget {
  const _SeriesCell({
    required this.item,
    required this.portrait,
    required this.onTap,
  });

  final MediaItem item;
  final bool portrait;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final title = VodGrouping.displayTitle(item);
    final art = item.artUrlFor(portrait: portrait) ?? item.thumbnailUrl;
    final downloaded = library.downloadedEpisodesForSeries(item);
    final subtitle = l10n.nAvailableOffline(downloaded.length);

    final posterArt = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surfaceHigh,
                  Color.lerp(AppColors.accent, AppColors.bg, 0.72)!,
                ],
              ),
            ),
          ),
          if (art != null && art.isNotEmpty)
            JavpArt(url: art, decodeWidth: portrait ? 320 : 420),
          Positioned(
            left: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                l10n.series.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 9,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final card = PosterCardShell(
      radius: 10,
      expandPoster: true,
      poster: posterArt,
      meta: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HoverMarqueeText(
            text: title,
            maxLines: 1,
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              height: 1.1,
            ),
          ),
        ],
      ),
    );

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        onSelect: onTap,
        borderRadius: 10,
        expandOnFocus: true,
        child: card,
      );
    }
    if (DesktopUi.enabled) {
      return DesktopHoverTile(
        radius: 10,
        onTap: onTap,
        showPlayBadge: true,
        child: card,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: card,
    );
  }
}
