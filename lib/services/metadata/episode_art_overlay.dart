import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';

/// Provider-agnostic episode still / title / plot used to overlay catalog rows.
class SeasonEpisodeArt {
  const SeasonEpisodeArt({
    required this.episodeNumber,
    required this.seasonNumber,
    this.title,
    this.plot,
    this.thumbnailUrl,
    this.duration,
    this.airDate,
  });

  final int episodeNumber;
  final int seasonNumber;
  final String? title;
  final String? plot;
  final String? thumbnailUrl;
  final Duration? duration;
  final DateTime? airDate;
}

/// Overlay metadata episode art onto catalog [SeriesInfo] without touching playUrls.
class EpisodeArtOverlay {
  EpisodeArtOverlay._();

  /// True when the tile would show series art (or nothing) instead of a still.
  static bool needsStill(
    SeriesEpisode episode, {
    MediaItem? series,
    SeriesInfo? info,
  }) {
    final thumb = episode.thumbnailUrl?.trim();
    if (thumb == null || thumb.isEmpty) return true;
    final fallbacks = <String>{
      if (series?.posterUrl?.trim().isNotEmpty == true)
        series!.posterUrl!.trim(),
      if (series?.thumbnailUrl?.trim().isNotEmpty == true)
        series!.thumbnailUrl!.trim(),
      if (series?.backdropUrl?.trim().isNotEmpty == true)
        series!.backdropUrl!.trim(),
      if (info?.coverUrl?.trim().isNotEmpty == true) info!.coverUrl!.trim(),
      if (info?.backdropUrl?.trim().isNotEmpty == true)
        info!.backdropUrl!.trim(),
    };
    if (fallbacks.contains(thumb)) return true;
    final thumbKey = artFingerprint(thumb);
    if (thumbKey == null) return false;
    return fallbacks.any((url) => artFingerprint(url) == thumbKey);
  }

  /// Stills, generic "Episode N" titles, or empty plots.
  static bool episodeNeedsArt(
    SeriesEpisode episode, {
    MediaItem? series,
    SeriesInfo? info,
  }) {
    if (needsStill(episode, series: series, info: info)) return true;
    if (isGenericEpisodeTitle(episode.title, episode.episodeNum)) {
      return true;
    }
    final plot = episode.plot?.trim();
    return plot == null || plot.isEmpty;
  }

  /// Filename / last path segment so AniList `cover/large` vs `cover/medium`
  /// (same file) still counts as reused series art.
  static String? artFingerprint(String? url) {
    final raw = url?.trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    final path = uri == null || uri.pathSegments.isEmpty
        ? raw
        : uri.pathSegments.last;
    final name = path.split('/').last.trim().toLowerCase();
    return name.isEmpty ? null : name;
  }

  /// Apply [stills] for one season onto [info]. Catalog playUrls stay intact.
  static SeriesInfo mergeSeason(
    SeriesInfo info,
    int seasonNumber,
    List<SeasonEpisodeArt> stills, {
    MediaItem? series,
  }) {
    if (stills.isEmpty) return info;
    final byEp = <int, SeasonEpisodeArt>{
      for (final s in stills) s.episodeNumber: s,
    };
    var changed = false;
    final seasons = <SeriesSeason>[];
    for (final season in info.seasons) {
      if (season.seasonNumber != seasonNumber) {
        seasons.add(season);
        continue;
      }
      final episodes = <SeriesEpisode>[];
      for (final ep in season.episodes) {
        final art = byEp[ep.episodeNum];
        if (art == null) {
          episodes.add(ep);
          continue;
        }
        final replaceThumb = needsStill(ep, series: series, info: info);
        final nextThumb = replaceThumb ? art.thumbnailUrl?.trim() : null;
        final artPlot = art.plot?.trim();
        final nextPlot =
            (ep.plot == null || ep.plot!.trim().isEmpty) &&
                artPlot != null &&
                artPlot.isNotEmpty
            ? artPlot
            : null;
        final artTitle = art.title?.trim();
        final nextTitle =
            isGenericEpisodeTitle(ep.title, ep.episodeNum) &&
                artTitle != null &&
                artTitle.isNotEmpty
            ? artTitle
            : null;
        final nextDuration =
            (ep.duration == null || ep.duration!.inSeconds <= 0)
            ? art.duration
            : null;
        final nextAirDate = ep.airDate == null ? art.airDate : null;
        if ((nextThumb == null || nextThumb.isEmpty) &&
            nextPlot == null &&
            nextTitle == null &&
            nextDuration == null &&
            nextAirDate == null) {
          episodes.add(ep);
          continue;
        }
        changed = true;
        episodes.add(
          ep.copyWith(
            thumbnailUrl: (nextThumb != null && nextThumb.isNotEmpty)
                ? nextThumb
                : null,
            plot: nextPlot,
            title: nextTitle,
            duration: nextDuration,
            airDate: nextAirDate,
          ),
        );
      }
      seasons.add(
        SeriesSeason(
          seasonNumber: season.seasonNumber,
          name: season.name,
          coverUrl: season.coverUrl,
          episodes: episodes,
        ),
      );
    }
    if (!changed) return info;
    return SeriesInfo(
      seriesId: info.seriesId,
      title: info.title,
      seasons: seasons,
      plot: info.plot,
      coverUrl: info.coverUrl,
      genre: info.genre,
      releaseDate: info.releaseDate,
      rating: info.rating,
      backdropUrl: info.backdropUrl,
    );
  }

  static bool isGenericEpisodeTitle(String title, int episodeNum) {
    final t = title.trim();
    if (t.isEmpty) return true;
    final match = RegExp(
      r'^(?:episode|épisode|ep\.?)\s*0*(\d+)$',
      caseSensitive: false,
    ).firstMatch(t);
    if (match == null) return false;
    return int.tryParse(match.group(1)!) == episodeNum;
  }
}
