import 'package:javp/models/media_item.dart';
import 'package:javp/models/serializd_models.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/simkl/simkl_match.dart';

const serializdWatchingTag = 'serializd-watching';
const serializdWatchlistTag = 'serializd-watchlist';

SimklIds serializdHitToSimklIds(SerializdShowHit hit) => SimklIds(
      tmdb: hit.showId > 0 ? hit.showId : null,
    );

MediaItem serializdWatchingShell(SerializdShowHit hit) {
  return MediaItem(
    id: 'serializd:watching:${hit.showId}',
    title: hit.title,
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.url,
    tmdbId: hit.showId > 0 ? hit.showId : null,
    posterUrl: hit.posterUrl,
    backdropUrl: hit.posterUrl,
    lastWatchedAt: hit.dateAdded,
    tags: const [serializdWatchingTag],
  );
}

MediaItem serializdWatchlistShell(SerializdShowHit hit) {
  return MediaItem(
    id: 'serializd:watchlist:${hit.showId}',
    title: hit.title,
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.url,
    tmdbId: hit.showId > 0 ? hit.showId : null,
    posterUrl: hit.posterUrl,
    backdropUrl: hit.posterUrl,
    lastWatchedAt: hit.dateAdded,
    tags: const [serializdWatchlistTag],
  );
}

bool isSerializdWatchingShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains(serializdWatchingTag) ||
      item.id.startsWith('serializd:watching:');
}

bool isSerializdWatchlistShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains(serializdWatchlistTag) ||
      item.id.startsWith('serializd:watchlist:');
}

MediaItem _applySerializdMeta(
  MediaItem base,
  SerializdShowHit hit, {
  required String tag,
}) {
  return base.copyWith(
    lastWatchedAt: hit.dateAdded ?? base.lastWatchedAt,
    tmdbId: base.tmdbId ?? (hit.showId > 0 ? hit.showId : null),
    posterUrl: base.posterUrl ?? hit.posterUrl,
    backdropUrl: base.backdropUrl ?? hit.posterUrl,
    tags: [
      ...base.tags.where((t) => t != tag),
      tag,
    ],
  );
}

Future<List<MediaItem>> resolveSerializdWatchingItemsAsync(
  List<SerializdShowHit> rows, {
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
    if (row.status != TrackerStatusKind.watching) continue;
    final ids = serializdHitToSimklIds(row);
    final matched = idx.match(ids, title: row.title);
    final item = matched == null
        ? serializdWatchingShell(row)
        : _applySerializdMeta(matched, row, tag: serializdWatchingTag);
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  out.sort(_byDateThenTitle);
  return out;
}

Future<List<MediaItem>> resolveSerializdWatchlistItemsAsync(
  List<SerializdShowHit> rows, {
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
    final ids = serializdHitToSimklIds(row);
    final matched = idx.match(ids, title: row.title);
    final item = matched == null
        ? serializdWatchlistShell(row)
        : _applySerializdMeta(matched, row, tag: serializdWatchlistTag);
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  out.sort(_byDateThenTitle);
  return out;
}

List<MediaItem> relinkSerializdShelf(
  List<MediaItem> shelf, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
  required bool Function(MediaItem) isShell,
  required String tag,
}) {
  if (shelf.isEmpty) return shelf;
  final idx = index ??
      SimklMatchIndex([
        ...catalog,
        ...history,
        ...watchlist,
        ...extra,
      ]);
  final out = <MediaItem>[];
  var changed = false;
  for (final item in shelf) {
    if (!isShell(item)) {
      out.add(item);
      continue;
    }
    final ids = SimklIds(tmdb: item.tmdbId);
    final matched = idx.match(ids, title: item.title, year: item.year);
    if (matched == null || matched.id == item.id) {
      out.add(item);
      continue;
    }
    changed = true;
    out.add(
      matched.copyWith(
        lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
        tmdbId: matched.tmdbId ?? item.tmdbId,
        posterUrl: matched.posterUrl ?? item.posterUrl,
        tags: [
          ...matched.tags.where((t) => t != tag),
          tag,
        ],
      ),
    );
  }
  return changed ? out : shelf;
}

int _byDateThenTitle(MediaItem a, MediaItem b) {
  final aAt = a.lastWatchedAt;
  final bAt = b.lastWatchedAt;
  if (aAt == null && bAt == null) return a.title.compareTo(b.title);
  if (aAt == null) return 1;
  if (bAt == null) return -1;
  return bAt.compareTo(aAt);
}
