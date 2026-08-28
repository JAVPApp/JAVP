import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/media_server/plex_account_client.dart';
import 'package:javp/services/simkl/simkl_match.dart';

const plexWatchlistTag = 'plex-watchlist';
const plexWatchlistIdPrefix = 'plex-watchlist:';

SimklIds plexHitToSimklIds(PlexWatchlistHit hit) =>
    SimklIds(tmdb: hit.tmdb, imdb: hit.imdb);

/// Playable from a Plex source (PMS library or FAST/VOD rating key).
bool isPlexWatchlistPlayable(MediaItem item) {
  return item.origin == MediaOrigin.plex &&
      (item.serverItemId ?? '').isNotEmpty &&
      (item.sourceId ?? '').isNotEmpty;
}

bool isPlexWatchlistShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  if (isPlexWatchlistPlayable(item)) return false;
  return item.tags.contains(plexWatchlistTag) ||
      item.id.startsWith(plexWatchlistIdPrefix);
}

MediaItem plexWatchlistShell(PlexWatchlistHit hit, {IptvSource? fastSource}) {
  final attach = fastSource != null;
  return MediaItem(
    id: '$plexWatchlistIdPrefix${hit.ratingKey}',
    title: hit.title,
    playUrl: '',
    kind: hit.isShow ? MediaKind.series : MediaKind.vod,
    origin: attach ? MediaOrigin.plex : MediaOrigin.url,
    year: hit.year,
    tmdbId: hit.tmdb,
    imdbId: hit.imdb,
    lastWatchedAt: hit.listedAt,
    thumbnailUrl: hit.thumbUrl,
    posterUrl: hit.thumbUrl,
    sourceId: attach ? fastSource.id : null,
    serverItemId: attach ? hit.ratingKey : null,
    tags: const [plexWatchlistTag],
    httpHeaders: attach
        ? const {
            'Origin': 'https://watch.plex.tv',
            'Referer': 'https://watch.plex.tv/',
          }
        : const {},
  );
}

MediaItem _applyPlexWatchlistMeta(MediaItem base, PlexWatchlistHit hit) {
  return base.copyWith(
    lastWatchedAt: hit.listedAt ?? base.lastWatchedAt,
    tmdbId: base.tmdbId ?? hit.tmdb,
    imdbId: base.imdbId ?? hit.imdb,
    posterUrl: base.posterUrl ?? hit.thumbUrl,
    thumbnailUrl: base.thumbnailUrl ?? hit.thumbUrl,
    tags: [...base.tags.where((t) => t != plexWatchlistTag), plexWatchlistTag],
  );
}

String? _ratingKeyFromWatchlistItem(MediaItem item) {
  if (item.id.startsWith(plexWatchlistIdPrefix)) {
    return item.id.substring(plexWatchlistIdPrefix.length);
  }
  return item.serverItemId;
}

List<MediaItem> resolvePlexWatchlistItems(
  List<PlexWatchlistHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  IptvSource? fastSource,
  SimklMatchIndex? index,
}) {
  final idx =
      index ??
      SimklMatchIndex([...catalog, ...history, ...watchlist, ...extra]);
  final out = <MediaItem>[];
  final seen = <String>{};
  for (final row in rows) {
    final matched = idx.match(
      plexHitToSimklIds(row),
      title: row.title,
      year: row.year,
    );
    final item = matched == null
        ? plexWatchlistShell(row, fastSource: fastSource)
        : _applyPlexWatchlistMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
  }
  _sortWatchlist(out);
  return out;
}

Future<List<MediaItem>> resolvePlexWatchlistItemsAsync(
  List<PlexWatchlistHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  IptvSource? fastSource,
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
    final matched = idx.match(
      plexHitToSimklIds(row),
      title: row.title,
      year: row.year,
    );
    final item = matched == null
        ? plexWatchlistShell(row, fastSource: fastSource)
        : _applyPlexWatchlistMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  _sortWatchlist(out);
  return out;
}

Future<List<MediaItem>> relinkPlexWatchlistItemsAsync(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  IptvSource? fastSource,
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
    if (!isPlexWatchlistShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = idx.match(
        SimklIds(tmdb: item.tmdbId, imdb: item.imdbId),
        title: item.title,
        year: item.year,
      );
      if (matched != null) {
        changed = true;
        final linked = matched.copyWith(
          lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          tags: [
            ...matched.tags.where((t) => t != plexWatchlistTag),
            plexWatchlistTag,
          ],
        );
        if (seen.add(linked.id)) out.add(linked);
      } else if (fastSource != null && !isPlexWatchlistPlayable(item)) {
        final key = _ratingKeyFromWatchlistItem(item);
        if (key != null && key.isNotEmpty) {
          changed = true;
          final attached = item.copyWith(
            origin: MediaOrigin.plex,
            sourceId: fastSource.id,
            serverItemId: key,
            httpHeaders: const {
              'Origin': 'https://watch.plex.tv',
              'Referer': 'https://watch.plex.tv/',
            },
            tags: [
              ...item.tags.where((t) => t != plexWatchlistTag),
              plexWatchlistTag,
            ],
          );
          if (seen.add(attached.id)) out.add(attached);
        } else if (seen.add(item.id)) {
          out.add(item);
        }
      } else if (seen.add(item.id)) {
        out.add(item);
      }
    }
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return changed ? out : current;
}

void _sortWatchlist(List<MediaItem> out) {
  out.sort((a, b) {
    final aAt = a.lastWatchedAt;
    final bAt = b.lastWatchedAt;
    if (aAt == null && bAt == null) return a.title.compareTo(b.title);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return bAt.compareTo(aAt);
  });
}
