import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/services/metadata/episode_art_overlay.dart';
import 'package:javp/services/tmdb/tmdb_client.dart';

/// Overlay TMDB season stills onto catalog episode rows (playback unchanged).
class TmdbEpisodeStills {
  TmdbEpisodeStills._();

  /// True when the tile would show series art (or nothing) instead of a still.
  static bool needsStill(
    SeriesEpisode episode, {
    MediaItem? series,
    SeriesInfo? info,
  }) => EpisodeArtOverlay.needsStill(episode, series: series, info: info);

  /// Stills, generic "Episode N" titles, or empty plots — fetch the season.
  static bool episodeNeedsTmdb(
    SeriesEpisode episode, {
    MediaItem? series,
    SeriesInfo? info,
  }) => EpisodeArtOverlay.episodeNeedsArt(episode, series: series, info: info);

  /// Filename / last path segment so AniList `cover/large` vs `cover/medium`
  /// (same file) still counts as reused series art.
  static String? artFingerprint(String? url) =>
      EpisodeArtOverlay.artFingerprint(url);

  /// Apply [stills] for one season onto [info]. Catalog playUrls stay intact.
  static SeriesInfo mergeSeason(
    SeriesInfo info,
    int seasonNumber,
    List<TmdbSeasonEpisode> stills, {
    MediaItem? series,
  }) {
    return EpisodeArtOverlay.mergeSeason(info, seasonNumber, [
      for (final s in stills)
        SeasonEpisodeArt(
          episodeNumber: s.episodeNumber,
          seasonNumber: s.seasonNumber,
          title: s.title,
          plot: s.plot,
          thumbnailUrl: s.thumbnailUrl,
          duration: s.duration,
          airDate: s.airDate,
        ),
    ], series: series);
  }
}
