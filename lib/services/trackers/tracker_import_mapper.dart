import 'package:javp/models/betaseries_models.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/models/trakt_models.dart';

/// Maps SIMKL / Trakt / BetaSeries API rows into shared [TrackerStatusEntry]s.
///
/// Serializd / Letterboxd build the same entry type on their side so
/// [mergeTrackerStatuses] / [TrackerStatusStore.replaceSource] stay agnostic.
class TrackerImportMapper {
  TrackerImportMapper._();

  static TrackerStatusKind? statusFromSimkl(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'watching':
        return TrackerStatusKind.watching;
      case 'completed':
        return TrackerStatusKind.completed;
      case 'hold':
      case 'onhold':
      case 'on-hold':
      case 'on_hold':
        return TrackerStatusKind.hold;
      case 'dropped':
        return TrackerStatusKind.dropped;
      case 'plantowatch':
      case 'plan to watch':
      case 'plan_to_watch':
        return TrackerStatusKind.planToWatch;
      default:
        return null;
    }
  }

  static TrackerStatusEntry? fromSimklLibraryItem(SimklLibraryItem item) {
    final status = statusFromSimkl(item.status) ??
        (item.isWatchingStatus ? TrackerStatusKind.watching : null);
    if (status == null ||
        status == TrackerStatusKind.planToWatch ||
        status == TrackerStatusKind.watchlist) {
      // Plan-to-watch stays on the My List shelf, not the exclusion store.
      return null;
    }
    final next = _parseSeasonEpisode(item.nextToWatch);
    // Prefer displayWatchedEpisodes so shelf N/M and inbound merge agree when
    // Simkl's count and next_to_watch disagree (count=5 + next S01E05 → 4).
    final watched = item.displayWatchedEpisodes ?? item.watchedEpisodes;
    return TrackerStatusEntry(
      source: TrackerSources.simkl,
      status: status,
      title: item.title,
      tmdbId: item.ids.tmdb,
      imdbId: item.ids.imdb,
      tvdbId: item.ids.tvdb,
      anilistId: item.ids.anilist,
      simklId: item.ids.simkl,
      year: item.year,
      progress: item.episodeProgress,
      seasonNumber: next?.$1,
      episodeNumber: next?.$2,
      watchedEpisodes: watched,
      totalEpisodes: item.totalEpisodes,
      updatedAt: item.lastWatchedAt,
    );
  }

  static TrackerStatusEntry? fromSimklPlayback(SimklPlayback pb) {
    if (pb.title.trim().isEmpty &&
        pb.ids.tmdb == null &&
        pb.ids.imdb == null &&
        pb.ids.simkl == null) {
      return null;
    }
    return TrackerStatusEntry(
      source: TrackerSources.simkl,
      status: TrackerStatusKind.watching,
      title: pb.title,
      tmdbId: pb.ids.tmdb,
      imdbId: pb.ids.imdb,
      tvdbId: pb.ids.tvdb,
      simklId: pb.ids.simkl,
      year: pb.year,
      progress: pb.progress.clamp(0.0, 1.0),
      seasonNumber: pb.seasonNumber,
      episodeNumber: pb.episodeNumber,
      updatedAt: pb.pausedAt,
    );
  }

  static TrackerStatusEntry? fromTraktDropped(TraktIdHit hit) {
    if (hit.title.trim().isEmpty &&
        hit.tmdb == null &&
        hit.imdb == null &&
        hit.trakt == null) {
      return null;
    }
    return TrackerStatusEntry(
      source: TrackerSources.trakt,
      status: TrackerStatusKind.dropped,
      title: hit.title,
      tmdbId: hit.tmdb,
      imdbId: hit.imdb,
      tvdbId: hit.tvdb,
      year: hit.year,
      updatedAt: hit.listedAt,
    );
  }

  static TrackerStatusEntry? fromTraktPlayback(TraktPlayback pb) {
    if (pb.title.trim().isEmpty &&
        pb.tmdb == null &&
        pb.imdb == null &&
        pb.trakt == null) {
      return null;
    }
    return TrackerStatusEntry(
      source: TrackerSources.trakt,
      status: TrackerStatusKind.watching,
      title: pb.title,
      tmdbId: pb.tmdb,
      imdbId: pb.imdb,
      tvdbId: pb.tvdb,
      year: pb.year,
      progress: pb.progress.clamp(0.0, 1.0),
      seasonNumber: pb.seasonNumber,
      episodeNumber: pb.episodeNumber,
      updatedAt: pb.pausedAt,
    );
  }

  /// Collect SIMKL status buckets (dropped / completed / hold / watching meta).
  static List<TrackerStatusEntry> fromSimklStatusLists({
    List<SimklLibraryItem> watching = const [],
    List<SimklLibraryItem> dropped = const [],
    List<SimklLibraryItem> completed = const [],
    List<SimklLibraryItem> hold = const [],
    List<SimklPlayback> playbacks = const [],
  }) {
    final out = <TrackerStatusEntry>[];
    void take(Iterable<SimklLibraryItem> rows) {
      for (final row in rows) {
        final entry = fromSimklLibraryItem(row);
        if (entry != null) out.add(entry);
      }
    }

    take(watching);
    take(dropped);
    take(completed);
    take(hold);
    for (final pb in playbacks) {
      final entry = fromSimklPlayback(pb);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  static List<TrackerStatusEntry> fromBetaseriesLists(BetaseriesUserLists lists) {
    return lists.toStatusEntries();
  }

  static List<TrackerStatusEntry> fromTraktInbound({
    List<TraktIdHit> dropped = const [],
    List<TraktPlayback> playbacks = const [],
  }) {
    final out = <TrackerStatusEntry>[];
    for (final hit in dropped) {
      final entry = fromTraktDropped(hit);
      if (entry != null) out.add(entry);
    }
    for (final pb in playbacks) {
      final entry = fromTraktPlayback(pb);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  /// Parses `S02E01` / `2x01` style next-to-watch labels.
  static (int, int)? _parseSeasonEpisode(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final se = RegExp(r'[Ss](\d{1,2})\s*[Ee](\d{1,3})').firstMatch(text);
    if (se != null) {
      return (int.parse(se.group(1)!), int.parse(se.group(2)!));
    }
    final x = RegExp(r'(\d{1,2})\s*[xX]\s*(\d{1,3})').firstMatch(text);
    if (x != null) {
      return (int.parse(x.group(1)!), int.parse(x.group(2)!));
    }
    return null;
  }
}
