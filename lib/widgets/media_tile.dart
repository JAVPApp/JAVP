import 'package:flutter/material.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';
import 'package:javp/widgets/desktop/hover_marquee_text.dart';
import 'package:javp/widgets/glow_progress_bar.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/poster_lift.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.compact = false,
    this.portrait,
    this.sourceLabel,
    this.trailing,
    this.variantCount,
    this.programImageUrl,
    this.programProgress,
    this.actionsEnabled = true,
  });

  final MediaItem item;
  final VoidCallback onTap;

  /// Touch long-press / mouse right-click.
  ///
  /// On desktop, [anchor] is the pointer position so the menu opens there
  /// instead of as a bottom sheet across the window.
  final void Function(Offset? anchor)? onLongPress;

  /// When [onLongPress] is null, show the shared actions sheet on hold.
  final bool actionsEnabled;
  final bool compact;

  /// Prefer 2:3 poster art when true, 16:9 when false.
  ///
  /// Null keeps the previous auto behavior (compact VOD with a poster URL).
  /// Live always stays landscape.
  final bool? portrait;
  final String? sourceLabel;
  final Widget? trailing;

  /// When >1, show a versions badge (language / source collapse).
  final int? variantCount;

  /// Current programme artwork for Live rows (backdrop behind channel logo).
  final String? programImageUrl;

  /// Live EPG progress through the current programme (0–1). Drives the thumb
  /// bar without showing VOD “% watched” copy.
  final double? programProgress;

  bool get _usePortrait {
    if (item.isLive) return false;
    if (portrait != null) return portrait!;
    return compact && item.prefersPortraitArt;
  }

  @override
  Widget build(BuildContext context) {
    final library = Provider.of<LibraryProvider?>(context, listen: false);
    var resolvedLabel = sourceLabel;
    var resolvedVariants = variantCount;
    // Home/Catalog freeze the shelf tree so playhead / sync ticks don't rebuild
    // Accueil. Sqlite family hydrate (title open *or* idle Home pump) still
    // finds extra IPTV editions — the chip follows overlay revision without
    // rematerializing every shelf.
    if (library != null &&
        (item.kind == MediaKind.vod || item.isSeries) &&
        !item.isEpisode &&
        !item.isLive &&
        sourceLabel != null) {
      context.select<LibraryProvider, int>(
        (l) => Object.hash(
          l.vodFamilyOverlayRevision,
          l.vodGroupingRevision,
          l.vodCacheRevision,
        ),
      );
      resolvedLabel = library.shelfSourceLabelFor(item);
      final n = library.vodVariantCountFor(item);
      resolvedVariants = n > 1 ? n : null;
    }
    final title = item.isLive || item.kind == MediaKind.catchup
        ? (library?.liveOrCatchupDisplayTitle(item) ?? item.title)
        : item.kind == MediaKind.vod || item.kind == MediaKind.series
        ? VodGrouping.displayTitle(item)
        : item.title;
    final liveProgress = programProgress;
    final subtitle = localizePersistedSubtitle(context.l10n, item.subtitle);
    final episodeCode = _episodeCode(item);
    final seriesName = _seriesNameFromSubtitle(item);
    // Continue watching / episode rows: prefer show title + SxxExx.
    final displayTitle = item.isEpisode && seriesName != null
        ? seriesName
        : title;
    final continueEpisodeTitle = item.isSeries
        ? _continueWatchingEpisodeTitle(item, episodeCode)
        : null;
    final episodeTitle = item.title.trim();
    final bareEpisodeTitle = RegExp(
      r'^(episode|épisode|ep)\s*\d+$',
      caseSensitive: false,
    ).hasMatch(episodeTitle);
    final episodeMeta = item.isEpisode
        ? [
            ?episodeCode,
            if (seriesName != null &&
                episodeTitle.isNotEmpty &&
                !bareEpisodeTitle)
              episodeTitle,
            if (_versionLabel(item) != null) _versionLabel(item)!,
          ].join(' \u00b7 ')
        : (item.isSeries && episodeCode != null
              ? [episodeCode, ?continueEpisodeTitle].join(' \u00b7 ')
              : null);
    final progressLabel = _progressLabel(
      context,
      item,
      liveProgress: liveProgress,
    );
    final thumb = _Thumb(
      item: item,
      sourceLabel: resolvedLabel,
      portrait: _usePortrait,
      variantCount: resolvedVariants,
      dense: !compact,
      // Shelf tiles churn through artwork; skip the fade so scroll stays crisp.
      fadeIn: !compact,
      programImageUrl: programImageUrl,
      programProgress: liveProgress,
    );
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HoverMarqueeText(
          text: displayTitle,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
            height: 1.2,
            fontSize: compact && _usePortrait ? 13 : null,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          [
            if (resolvedLabel != null &&
                resolvedLabel.isNotEmpty &&
                isMultiSourceCountLabel(context.l10n, resolvedLabel))
              resolvedLabel,
            if (episodeMeta != null && episodeMeta.isNotEmpty)
              episodeMeta
            else if (subtitle != null && subtitle.isNotEmpty)
              subtitle
            else if (item.group != null && item.group!.isNotEmpty)
              item.group!,
            if (item.isSeries) context.l10n.series,
            ?progressLabel,
          ].join(' • '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.textMuted,
            fontSize: compact && _usePortrait ? 11 : null,
          ),
        ),
      ],
    );

    final hold =
        onLongPress ??
        (actionsEnabled && !TvPlatform.isAndroidTv
            ? (Offset? anchor) => showMediaItemActions(
                context: context,
                item: item,
                anchor: anchor,
              )
            : null);

    Widget wrapTap(Widget child, {double radius = 12, bool lift = false}) {
      if (TvPlatform.isAndroidTv) {
        return TvFocusable(
          onSelect: onTap,
          borderRadius: radius,
          expandOnFocus: lift,
          child: child,
        );
      }
      if (DesktopUi.enabled) {
        // Mouse: hover ring + play badge, right-click for a menu at the pointer.
        return DesktopHoverTile(
          radius: radius,
          onTap: onTap,
          onSecondaryTap: hold != null ? () => hold(null) : null,
          onSecondaryTapAt: hold != null ? (position) => hold(position) : null,
          showPlayBadge: lift,
          child: child,
        );
      }
      return InkWell(
        onTap: onTap,
        onLongPress: hold != null ? () => hold(null) : null,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );
    }

    if (compact) {
      final width = AdaptiveLayout.compactTileWidth(
        context,
        portrait: _usePortrait,
      );
      // Portrait shelf: title + episode/progress line under the poster.
      final posterMeta = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HoverMarqueeText(
            text: displayTitle,
            maxLines:
                episodeMeta != null ||
                    progressLabel != null ||
                    (subtitle != null && subtitle.isNotEmpty)
                ? 1
                : 2,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
              height: 1.15,
              fontSize: 12,
            ),
          ),
          if (episodeMeta != null && episodeMeta.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              episodeMeta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
                fontSize: 11,
                height: 1.1,
              ),
            ),
          ] else if (subtitle != null && subtitle.isNotEmpty) ...[
            // Simkl Watching etc.: "11/13 eps" under portrait posters.
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
                fontSize: 11,
                height: 1.1,
              ),
            ),
          ],
          if (progressLabel != null) ...[
            const SizedBox(height: 2),
            Text(
              progressLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ],
        ],
      );
      return SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            wrapTap(
              PosterCardShell(
                radius: 12,
                poster: AspectRatio(
                  aspectRatio: _usePortrait ? 2 / 3 : 16 / 9,
                  child: thumb,
                ),
                meta: _usePortrait ? posterMeta : meta,
              ),
              lift: true,
            ),
          ],
        ),
      );
    }

    // Dense list row (IPTV / Library / Search) — avoid full-bleed 16:9 thumbs.
    return wrapTap(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: _usePortrait ? 40 : 88,
              height: _usePortrait ? 60 : 50,
              child: thumb,
            ),
            const SizedBox(width: 10),
            Expanded(child: meta),
            ?trailing,
          ],
        ),
      ),
      radius: 8,
    );
  }
}

String? _episodeCode(MediaItem item) {
  if (item.seasonNumber == null && item.episodeNumber == null) {
    // Fall back to "Series · S01E01" suffix in subtitle.
    final sub = item.subtitle?.trim();
    if (sub == null || !sub.contains(' · ')) return null;
    final tail = sub.split(' · ').last.trim();
    if (RegExp(r'^S\d+E\d+$', caseSensitive: false).hasMatch(tail)) {
      return tail.toUpperCase();
    }
    return null;
  }
  final sn = item.seasonNumber ?? 1;
  final en = item.episodeNumber ?? 0;
  return 'S${sn.toString().padLeft(2, '0')}'
      'E${en.toString().padLeft(2, '0')}';
}

/// `episodeMediaItem` stores subtitle as `"Show title · S01E01"`.
String? _seriesNameFromSubtitle(MediaItem item) {
  final sub = item.subtitle?.trim();
  if (sub == null || !sub.contains(' · ')) return null;
  final head = sub.split(' · ').first.trim();
  if (head.isEmpty) return null;
  // Avoid treating plain group names as series titles when no episode code.
  if (item.seasonNumber == null &&
      item.episodeNumber == null &&
      item.seriesId == null) {
    return null;
  }
  return head;
}

/// Third+ segment of `"Show · S01E01 · GroupA · 1080p…"`.
String? _versionLabel(MediaItem item) {
  if (item.resolution != null && item.resolution!.trim().isNotEmpty) {
    // Prefer compact resolution on the tile when label is huge.
    final sub = item.subtitle?.trim();
    if (sub != null && sub.contains(' · ')) {
      final parts = sub.split(' · ');
      if (parts.length >= 3) {
        final rest = parts.sublist(2).join(' · ').trim();
        if (rest.isNotEmpty) return rest;
      }
    }
    return item.resolution!.trim();
  }
  final sub = item.subtitle?.trim();
  if (sub == null || !sub.contains(' · ')) return null;
  final parts = sub.split(' · ');
  if (parts.length < 3) return null;
  final rest = parts.sublist(2).join(' · ').trim();
  return rest.isEmpty ? null : rest;
}

/// Episode name from continue-watching series subtitle (`S01E03 · Title`).
String? _continueWatchingEpisodeTitle(MediaItem item, String? episodeCode) {
  final sub = item.subtitle?.trim();
  if (sub == null || sub.isEmpty) return null;
  String? rest;
  if (episodeCode != null &&
      sub.toUpperCase().startsWith(episodeCode.toUpperCase())) {
    rest = sub
        .substring(episodeCode.length)
        .replaceFirst(RegExp(r'^\s*\u00b7\s*'), '')
        .trim();
  } else if (sub.contains('\u00b7')) {
    final parts = sub.split('\u00b7');
    if (parts.length >= 2) {
      rest = parts.sublist(1).join('\u00b7').trim();
    }
  }
  if (rest == null || rest.isEmpty) return null;
  // Hide generic "Episode 7" — SxxExx on the tile is enough.
  if (RegExp(
    r'^(episode|épisode|ep)\s*\d+$',
    caseSensitive: false,
  ).hasMatch(rest)) {
    return null;
  }
  return rest;
}

String? _progressLabel(
  BuildContext context,
  MediaItem item, {
  double? liveProgress,
}) {
  if (liveProgress != null) return null;
  // Tracker series progress is already in subtitle ("11/13 eps") — don't also
  // paint a percent that attributes the same ratio to a catalog chip.
  final sub = item.subtitle?.trim() ?? '';
  if (item.isSeries &&
      RegExp(r'\d+\s*/\s*\d+\s*eps', caseSensitive: false).hasMatch(sub)) {
    return null;
  }
  if (item.progress <= 0.02 || item.progress >= 0.95) return null;
  final l10n = context.l10n;
  final dur = item.duration;
  if (dur != null && dur.inSeconds > 0) {
    final left = Duration(
      milliseconds: (dur.inMilliseconds * (1 - item.progress)).round(),
    );
    final mins = left.inMinutes;
    if (mins >= 60) {
      return l10n.hoursMinutesLeft(mins ~/ 60, mins % 60);
    }
    if (mins > 0) return l10n.minutesLeft(mins);
    return l10n.secondsLeft(left.inSeconds);
  }
  return l10n.percentWatched((item.progress * 100).round());
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.item,
    this.sourceLabel,
    this.portrait = false,
    this.variantCount,
    this.dense = false,
    this.fadeIn = true,
    this.programImageUrl,
    this.programProgress,
  });

  final MediaItem item;
  final String? sourceLabel;
  final bool portrait;
  final int? variantCount;
  final bool dense;
  final bool fadeIn;
  final String? programImageUrl;
  final double? programProgress;

  @override
  Widget build(BuildContext context) {
    final logo = item.thumbnailUrl;
    final programArt = programImageUrl?.trim();
    final hasProgramArt =
        programArt != null && programArt.isNotEmpty && item.isLive && dense;
    final art = hasProgramArt ? programArt : item.artUrlFor(portrait: portrait);
    final badgePad = dense ? 4.0 : 10.0;
    final badgeFont = dense ? 9.0 : 11.0;
    final barProgress =
        programProgress ??
        (item.progress > 0.02 && item.progress < 0.99 ? item.progress : null);
    final radius = BorderRadius.circular(dense ? AppRadius.sm : AppRadius.md);
    final sourceTint = sourceLabel != null && sourceLabel!.isNotEmpty
        ? context.read<LibraryProvider>().sourceColorFor(item)
        : null;
    return ClipRRect(
      borderRadius: radius,
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
            JavpArt(
              url: art,
              fit: item.isLive && !hasProgramArt
                  ? BoxFit.contain
                  : BoxFit.cover,
              // Decode near display size to avoid full-res decode jank in lists.
              decodeWidth: dense ? 176 : (portrait ? 236 : 440),
              fadeIn: fadeIn,
            ),
          if (hasProgramArt)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Color(0x99000000), Color(0x33000000)],
                ),
              ),
            ),
          if (hasProgramArt && logo != null && logo.isNotEmpty)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                clipBehavior: Clip.antiAlias,
                child: JavpArt(url: logo, fit: BoxFit.contain, decodeWidth: 56),
              ),
            ),
          if (item.isLive && !hasProgramArt)
            Positioned(
              left: badgePad,
              top: badgePad,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 5 : 8,
                  vertical: dense ? 2 : 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(dense ? 4 : 6),
                ),
                child: Text(
                  context.l10n.liveBadge,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: badgeFont,
                  ),
                ),
              ),
            ),
          if (item.isSeries)
            Positioned(
              left: badgePad,
              top: badgePad,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 5 : 8,
                  vertical: dense ? 2 : 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(dense ? 4 : 6),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  context.l10n.series,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: badgeFont,
                  ),
                ),
              ),
            ),
          if (variantCount != null && variantCount! > 1)
            Positioned(
              left: badgePad,
              bottom: barProgress != null ? (dense ? 4 : 8) : badgePad,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 5 : 8,
                  vertical: dense ? 2 : 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(dense ? 4 : 6),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  context.l10n.versionsCount(variantCount!),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: badgeFont,
                  ),
                ),
              ),
            ),
          // sourceLabel is the multi-source cue ("3 sources") or a single
          // catalog name — keep it visually distinct from the versions badge.
          if (sourceLabel != null && sourceLabel!.isNotEmpty)
            Positioned(
              right: dense ? 4 : 10,
              top: dense ? null : 10,
              bottom: dense ? 4 : null,
              child: Container(
                constraints: BoxConstraints(maxWidth: dense ? 72 : 140),
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 4 : 8,
                  vertical: dense ? 2 : 4,
                ),
                decoration: BoxDecoration(
                  color: sourceTint != null
                      ? sourceBadgeFill(sourceTint)
                      : Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(dense ? 4 : 6),
                  border: Border.all(
                    color:
                        sourceTint ??
                        (dense ? Colors.transparent : Colors.white24),
                    width: sourceTint != null ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  sourceLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: badgeFont,
                  ),
                ),
              ),
            ),
          if (barProgress != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GlowProgressBar(
                value: barProgress,
                height: dense ? 3 : (portrait ? 4 : 3),
              ),
            ),
          if (!portrait && !hasProgramArt)
            Center(
              child: Icon(
                item.isLive
                    ? Icons.sensors_rounded
                    : item.isSeries
                    ? Icons.video_library_rounded
                    : Icons.play_circle_fill,
                color: Colors.white.withValues(alpha: 0.8),
                size: dense ? 22 : 42,
              ),
            ),
          // Hairline on top of the art, so posters sit on the page rather
          // than bleeding into it.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: const Color(0x14FFFFFF)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
