import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/letterboxd/letterboxd_export.dart';
import 'package:javp/services/simkl/simkl_match.dart';

const letterboxdWatchlistTag = 'letterboxd-watchlist';
const letterboxdSourceId = 'letterboxd';

MediaItem letterboxdWatchlistShell(LetterboxdFilmRow row) {
  final key = row.stableKey
      .replaceAll(RegExp(r'[^a-zA-Z0-9:_./\-]+'), '-')
      .toLowerCase();
  return MediaItem(
    id: 'letterboxd:$key',
    title: row.title,
    playUrl: '',
    kind: MediaKind.vod,
    origin: MediaOrigin.url,
    year: row.year,
    tmdbId: row.tmdbId,
    imdbId: row.imdbId,
    lastWatchedAt: row.listedAt ?? row.watchedAt,
    tags: const [letterboxdWatchlistTag],
  );
}

bool isLetterboxdWatchlistShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains(letterboxdWatchlistTag) ||
      item.id.startsWith('letterboxd:');
}

MediaItem _applyLetterboxdMeta(MediaItem base, LetterboxdFilmRow row) {
  return base.copyWith(
    lastWatchedAt: row.listedAt ?? row.watchedAt ?? base.lastWatchedAt,
    tmdbId: base.tmdbId ?? row.tmdbId,
    imdbId: base.imdbId ?? row.imdbId,
    tags: [
      ...base.tags.where((t) => t != letterboxdWatchlistTag),
      letterboxdWatchlistTag,
    ],
  );
}

SimklIds _rowIds(LetterboxdFilmRow row) => SimklIds(
      tmdb: row.tmdbId,
      imdb: row.imdbId,
    );

/// Resolve Letterboxd watchlist rows to catalog movies (or shells).
List<MediaItem> resolveLetterboxdWatchlistItems(
  List<LetterboxdFilmRow> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
}) {
  final idx = index ??
      SimklMatchIndex([
        ...catalog,
        ...history,
        ...watchlist,
        ...extra,
      ]);
  final out = <MediaItem>[];
  final seen = <String>{};
  for (final row in rows) {
    final matched = idx.match(_rowIds(row), title: row.title, year: row.year);
    MediaItem item;
    if (matched == null || matched.isSeries || matched.isEpisode) {
      item = letterboxdWatchlistShell(row);
    } else {
      item = _applyLetterboxdMeta(matched, row);
    }
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

Future<List<MediaItem>> resolveLetterboxdWatchlistItemsAsync(
  List<LetterboxdFilmRow> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
  int yieldEvery = 12,
}) async {
  final idx = index ??
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
    final matched = idx.match(_rowIds(row), title: row.title, year: row.year);
    MediaItem item;
    if (matched == null || matched.isSeries || matched.isEpisode) {
      item = letterboxdWatchlistShell(row);
    } else {
      item = _applyLetterboxdMeta(matched, row);
    }
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

Future<List<MediaItem>> relinkLetterboxdWatchlistItemsAsync(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
  int yieldEvery = 16,
}) async {
  if (current.isEmpty) return current;
  final idx = index ??
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
    if (!isLetterboxdWatchlistShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = idx.match(
        SimklIds(tmdb: item.tmdbId, imdb: item.imdbId),
        title: item.title,
        year: item.year,
      );
      if (matched == null || matched.isSeries || matched.isEpisode) {
        if (seen.add(item.id)) out.add(item);
      } else {
        changed = true;
        final linked = matched.copyWith(
          lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          tags: [
            ...matched.tags.where((t) => t != letterboxdWatchlistTag),
            letterboxdWatchlistTag,
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
