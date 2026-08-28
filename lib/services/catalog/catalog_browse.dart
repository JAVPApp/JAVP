import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/recommendations/local_recommender.dart';

/// Identity keys used to hide finished titles across source siblings.
Iterable<String> catalogWatchKeys(MediaItem item) sync* {
  yield 'id:${item.id}';
  yield 'taste:${LocalRecommender.tasteIdentityKey(item)}';
  final group = VodGrouping.groupKey(item);
  if (group != null && group.isNotEmpty) yield 'group:$group';
  final tmdb = item.tmdbId;
  if (tmdb != null && tmdb > 0) {
    yield 'tmdb:$tmdb';
    yield item.isSeries ? 'tmdb-tv:$tmdb' : 'tmdb-movie:$tmdb';
  }
  final imdb = item.imdbId?.trim().toLowerCase();
  if (imdb != null && imdb.isNotEmpty) yield 'imdb:$imdb';
  final anilist = item.anilistId;
  if (anilist != null && anilist > 0) yield 'al:$anilist';
  final tvdb = item.tvdbId;
  if (tvdb != null && tvdb > 0) yield 'tvdb:$tvdb';
}

/// Finished movies / completed series from local history + tracker completed.
///
/// One finished episode does **not** hide its series — only a series shell
/// (or tracker Completed) counts as watched for a show.
class CatalogWatchedIndex {
  CatalogWatchedIndex({
    required List<MediaItem> history,
    List<TrackerStatusEntry> trackerStatuses = const [],
  }) : _keys = {
         for (final item in history)
           if (!item.isEpisode && item.progress >= 0.9)
             ...catalogWatchKeys(item),
       },
       _trackers = TrackerStatusStore(trackerStatuses);

  final Set<String> _keys;
  final TrackerStatusStore _trackers;

  bool isWatched(MediaItem item) {
    if (item.isEpisode) return false;
    if (item.progress >= 0.9) return true;
    for (final key in catalogWatchKeys(item)) {
      if (_keys.contains(key)) return true;
    }
    final hit = _trackers.lookup(
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
      anilistId: item.anilistId,
      simklId: item.simklId,
      title: item.title,
      year: item.year,
    );
    return hit?.status == TrackerStatusKind.completed;
  }
}

/// TMDB discovery order: trending first, then popular (lower = hotter).
Map<int, int> catalogPopularRankByTmdbId({
  Iterable<MediaItem> trending = const [],
  Iterable<MediaItem> popular = const [],
}) {
  final rank = <int, int>{};
  var i = 0;
  for (final item in [...trending, ...popular]) {
    final id = item.tmdbId;
    if (id == null || id <= 0 || rank.containsKey(id)) continue;
    rank[id] = i++;
  }
  return rank;
}

String catalogNormGenre(String raw) => raw.trim().toLowerCase();

Set<String> catalogNormGenreSet(Iterable<String> raw) => {
  for (final g in raw)
    if (catalogNormGenre(g).isNotEmpty) catalogNormGenre(g),
};

/// Genres on the row plus optional details-cache extras.
Set<String> catalogItemGenreSet(
  MediaItem item, {
  Iterable<String> extra = const [],
}) {
  return catalogNormGenreSet([...item.genres, ...extra]);
}

bool catalogItemMatchesBrowse(
  MediaItem item,
  CatalogBrowsePrefs prefs, {
  required CatalogWatchedIndex watched,
  Iterable<String> extraGenres = const [],
}) {
  if (prefs.hideWatched && watched.isWatched(item)) return false;
  final include = catalogNormGenreSet(prefs.includeGenres);
  final exclude = catalogNormGenreSet(prefs.excludeGenres);
  if (include.isEmpty && exclude.isEmpty) return true;
  final genres = catalogItemGenreSet(item, extra: extraGenres);
  if (include.isNotEmpty) {
    if (genres.isEmpty || genres.intersection(include).isEmpty) return false;
  }
  if (exclude.isNotEmpty && genres.intersection(exclude).isNotEmpty) {
    return false;
  }
  return true;
}

int compareCatalogBrowseSort(
  MediaItem a,
  MediaItem b,
  CatalogBrowseSort sort, {
  Map<int, int> popularRankByTmdbId = const {},
  Map<String, double> popularityNormByKey = const {},
}) {
  switch (sort) {
    case CatalogBrowseSort.popular:
      final ra = _tmdbRank(a, popularRankByTmdbId);
      final rb = _tmdbRank(b, popularRankByTmdbId);
      if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
      if (ra != null && rb == null) return -1;
      if (ra == null && rb != null) return 1;
      final pa = popularityNormByKey[catalogPopularityKey(a)];
      final pb = popularityNormByKey[catalogPopularityKey(b)];
      if (pa != null && pb != null && pa != pb) return pb.compareTo(pa);
      if (pa != null && pb == null) return -1;
      if (pa == null && pb != null) return 1;
      final byRating = (b.rating ?? -1).compareTo(a.rating ?? -1);
      if (byRating != 0) return byRating;
      final byYear = (b.year ?? 0).compareTo(a.year ?? 0);
      if (byYear != 0) return byYear;
      return VodGrouping.compareDisplayTitle(a, b);
    case CatalogBrowseSort.ratingDesc:
      final byRating = (b.rating ?? -1).compareTo(a.rating ?? -1);
      if (byRating != 0) return byRating;
      return VodGrouping.compareDisplayTitle(a, b);
    case CatalogBrowseSort.yearDesc:
      final byYear = (b.year ?? 0).compareTo(a.year ?? 0);
      if (byYear != 0) return byYear;
      return VodGrouping.compareDisplayTitle(a, b);
    case CatalogBrowseSort.titleAsc:
      return VodGrouping.compareDisplayTitle(a, b);
  }
}

int? _tmdbRank(MediaItem item, Map<int, int> rank) {
  final id = item.tmdbId;
  if (id == null || id <= 0) return null;
  return rank[id];
}

String catalogPopularityKey(MediaItem item) =>
    '${item.sourceId ?? ''}\x1f${item.id}';

/// Per-[MediaItem.sourceId] 0–1 percentile of [MediaItem.popularity].
///
/// Higher raw value → closer to 1. Each catalog is scaled on its own so
/// seeders vs 0–100 scores do not fight. Ties share a value. A single item
/// in a source maps to 1.0. Items without a finite non-negative popularity
/// are omitted (sort treats them as missing, after any scored row).
Map<String, double> catalogPopularityNorms(Iterable<MediaItem> items) {
  final bySource = <String, List<MediaItem>>{};
  for (final item in items) {
    final p = item.popularity;
    if (p == null || !p.isFinite || p < 0) continue;
    bySource.putIfAbsent(item.sourceId ?? '', () => []).add(item);
  }
  final out = <String, double>{};
  for (final group in bySource.values) {
    final values = [for (final i in group) i.popularity!]
      ..sort((a, b) => b.compareTo(a));
    final n = values.length;
    final cache = <double, double>{};
    for (final item in group) {
      final p = item.popularity!;
      final norm = cache.putIfAbsent(p, () {
        if (n <= 1) return 1.0;
        final i = values.indexOf(p);
        return (n - 1 - i) / (n - 1);
      });
      out[catalogPopularityKey(item)] = norm;
    }
  }
  return out;
}

/// Filter + sort + optional [limit] for Catalog shelves and See all.
List<MediaItem> applyCatalogBrowse(
  Iterable<MediaItem> items, {
  required CatalogBrowsePrefs prefs,
  required CatalogWatchedIndex watched,
  Map<int, int> popularRankByTmdbId = const {},
  Iterable<String> Function(MediaItem item)? extraGenres,
  int? limit,
}) {
  final list = items is List<MediaItem> ? items : items.toList();
  final popularityNormByKey = prefs.sort == CatalogBrowseSort.popular
      ? catalogPopularityNorms(list)
      : const <String, double>{};
  final out = <MediaItem>[
    for (final item in list)
      if (catalogItemMatchesBrowse(
        item,
        prefs,
        watched: watched,
        extraGenres: extraGenres?.call(item) ?? const [],
      ))
        item,
  ];
  out.sort(
    (a, b) => compareCatalogBrowseSort(
      a,
      b,
      prefs.sort,
      popularRankByTmdbId: popularRankByTmdbId,
      popularityNormByKey: popularityNormByKey,
    ),
  );
  if (limit != null && limit >= 0 && out.length > limit) {
    return out.sublist(0, limit);
  }
  return out;
}
