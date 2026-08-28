import 'package:javp/models/series_info.dart';

/// Flatten seasons (already sorted) into a single episode list.
List<SeriesEpisode> flattenedEpisodes(SeriesInfo info) {
  return [for (final season in info.seasons) ...season.episodes];
}

/// Episodes after [seasonNumber]/[episodeNum], up to [count].
List<SeriesEpisode> episodesAfter({
  required SeriesInfo info,
  required int seasonNumber,
  required int episodeNum,
  required int count,
}) {
  if (count <= 0) return const [];
  final flat = flattenedEpisodes(info);
  final idx = flat.indexWhere(
    (e) => e.seasonNumber == seasonNumber && e.episodeNum == episodeNum,
  );
  if (idx < 0) return const [];
  final start = idx + 1;
  if (start >= flat.length) return const [];
  final end = (start + count).clamp(start, flat.length);
  return flat.sublist(start, end);
}

/// Episodes before [seasonNumber]/[episodeNum], up to [count] (nearest first).
List<SeriesEpisode> episodesBefore({
  required SeriesInfo info,
  required int seasonNumber,
  required int episodeNum,
  required int count,
}) {
  if (count <= 0) return const [];
  final flat = flattenedEpisodes(info);
  final idx = flat.indexWhere(
    (e) => e.seasonNumber == seasonNumber && e.episodeNum == episodeNum,
  );
  if (idx <= 0) return const [];
  final start = (idx - count).clamp(0, idx);
  // Nearest previous first (idx-1, idx-2, …).
  return flat.sublist(start, idx).reversed.toList();
}

/// Remaining episodes in [seasonNumber] from [fromEpisodeNum] inclusive.
/// If [fromEpisodeNum] is null, returns the whole season.
List<SeriesEpisode> remainingInSeason({
  required SeriesInfo info,
  required int seasonNumber,
  int? fromEpisodeNum,
}) {
  final season = info.seasons.cast<SeriesSeason?>().firstWhere(
        (s) => s?.seasonNumber == seasonNumber,
        orElse: () => null,
      );
  if (season == null) return const [];
  if (fromEpisodeNum == null) return List.of(season.episodes);
  final idx = season.episodes.indexWhere((e) => e.episodeNum == fromEpisodeNum);
  if (idx < 0) return List.of(season.episodes);
  return season.episodes.sublist(idx);
}

/// Every episode across all seasons (already sorted).
List<SeriesEpisode> allEpisodesInSeries(SeriesInfo info) =>
    flattenedEpisodes(info);

/// Diff helper: new episode ids since [known]. Empty [known] means first baseline.
List<String> newEpisodeIds({
  required Iterable<String> currentIds,
  required Iterable<String> knownIds,
}) {
  if (knownIds.isEmpty) return const [];
  final known = knownIds.toSet();
  return [for (final id in currentIds) if (!known.contains(id)) id];
}
