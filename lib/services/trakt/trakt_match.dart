import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/simkl/simkl_match.dart';

/// Reuses [SimklMatchIndex] id/title matching for Trakt watchlist rows.
SimklIds traktHitToSimklIds(TraktIdHit hit) =>
    SimklIds(tmdb: hit.tmdb, imdb: hit.imdb, tvdb: hit.tvdb);

MediaItem traktWatchlistShell(TraktIdHit hit) {
  final key = hit.trakt != null
      ? '${hit.trakt}'
      : (hit.tmdb != null
            ? 'tmdb-${hit.tmdb}'
            : (hit.imdb ??
                  hit.slug ??
                  hit.title.toLowerCase().replaceAll(RegExp(r'\s+'), '-')));
  return MediaItem(
    id: 'trakt:$key',
    title: hit.title,
    playUrl: '',
    kind: hit.isShow ? MediaKind.series : MediaKind.vod,
    origin: MediaOrigin.url,
    year: hit.year,
    tmdbId: hit.tmdb,
    imdbId: hit.imdb,
    tvdbId: hit.tvdb,
    traktId: hit.trakt != null ? '${hit.trakt}' : null,
    lastWatchedAt: hit.listedAt,
    tags: const ['trakt-watchlist'],
  );
}

bool isTraktWatchlistShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains('trakt-watchlist') || item.id.startsWith('trakt:');
}

MediaItem _applyTraktMeta(MediaItem base, TraktIdHit hit) {
  return base.copyWith(
    lastWatchedAt: hit.listedAt ?? base.lastWatchedAt,
    tmdbId: base.tmdbId ?? hit.tmdb,
    imdbId: base.imdbId ?? hit.imdb,
    tvdbId: base.tvdbId ?? hit.tvdb,
    traktId: base.traktId ?? (hit.trakt != null ? '${hit.trakt}' : null),
    tags: [
      ...base.tags.where((t) => t != 'trakt-watchlist'),
      'trakt-watchlist',
    ],
  );
}

List<MediaItem> resolveTraktWatchlistItems(
  List<TraktIdHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
}) {
  final idx =
      index ??
      SimklMatchIndex([...catalog, ...history, ...watchlist, ...extra]);
  final out = <MediaItem>[];
  final seen = <String>{};
  for (final row in rows) {
    final ids = traktHitToSimklIds(row);
    final matched = idx.match(ids, title: row.title, year: row.year);
    final item = matched == null
        ? traktWatchlistShell(row)
        : _applyTraktMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
  }
  out.sort((a, b) {
    final aAt = a.lastWatchedAt;
    final bAt = b.lastWatchedAt;
    if (aAt == null && bAt == null) return a.title.compareTo(b.title);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return bAt.compareTo(aAt);
  });
  return out;
}

Future<List<MediaItem>> resolveTraktWatchlistItemsAsync(
  List<TraktIdHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
  int yieldEvery = 12,
}) async {
  final idx =
      index ??
      await SimklMatchIndex.buildAsync([
        ...catalog,
        ...history,
        ...watchlist,
        ...extra,
      ]);
  await Future<void>.delayed(Duration.zero);

  final out = <MediaItem>[];
  final seen = <String>{};
  var n = 0;
  for (final row in rows) {
    final ids = traktHitToSimklIds(row);
    final matched = idx.match(ids, title: row.title, year: row.year);
    final item = matched == null
        ? traktWatchlistShell(row)
        : _applyTraktMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  out.sort((a, b) {
    final aAt = a.lastWatchedAt;
    final bAt = b.lastWatchedAt;
    if (aAt == null && bAt == null) return a.title.compareTo(b.title);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return bAt.compareTo(aAt);
  });
  return out;
}

Future<List<MediaItem>> relinkTraktWatchlistItemsAsync(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
  int yieldEvery = 16,
}) async {
  if (current.isEmpty) return current;
  final idx =
      index ??
      await SimklMatchIndex.buildAsync([
        ...catalog,
        ...history,
        ...watchlist,
        ...extra,
      ]);
  await Future<void>.delayed(Duration.zero);

  final out = <MediaItem>[];
  var changed = false;
  final seen = <String>{};
  var n = 0;
  for (final item in current) {
    if (!isTraktWatchlistShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = idx.match(
        SimklIds(tmdb: item.tmdbId, imdb: item.imdbId, tvdb: item.tvdbId),
        title: item.title,
        year: item.year,
      );
      if (matched == null) {
        if (seen.add(item.id)) out.add(item);
      } else {
        changed = true;
        final linked = matched.copyWith(
          lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          tvdbId: matched.tvdbId ?? item.tvdbId,
          traktId: matched.traktId ?? item.traktId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          tags: [
            ...matched.tags.where((t) => t != 'trakt-watchlist'),
            'trakt-watchlist',
          ],
        );
        if (seen.add(linked.id)) out.add(linked);
      }
    }
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return changed ? out : current;
}

MediaItem? matchTraktHitToLocal(
  TraktIdHit hit, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
}) {
  return matchSimklIdsToLocal(
    traktHitToSimklIds(hit),
    catalog: catalog,
    history: history,
    watchlist: watchlist,
    extra: extra,
    title: hit.title,
    year: hit.year,
    index: index,
  );
}
