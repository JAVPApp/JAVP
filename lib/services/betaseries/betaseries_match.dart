import 'package:javp/models/betaseries_models.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/simkl/simkl_match.dart';

const betaseriesWatchingTag = 'betaseries-watching';
const betaseriesPlanTag = 'betaseries-plan';

SimklIds betaseriesHitToSimklIds(BetaseriesShowHit hit) => SimklIds(
      tmdb: hit.tmdbId,
      imdb: hit.imdbId,
      tvdb: hit.tvdbId,
    );

MediaItem betaseriesWatchingShell(BetaseriesShowHit hit) {
  final key = hit.id > 0
      ? '${hit.id}'
      : (hit.tvdbId != null
          ? 'tvdb-${hit.tvdbId}'
          : (hit.imdbId ??
              hit.title.toLowerCase().replaceAll(RegExp(r'\s+'), '-')));
  return MediaItem(
    id: 'betaseries:$key',
    title: hit.title,
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.url,
    year: hit.year,
    tmdbId: hit.tmdbId,
    imdbId: hit.imdbId,
    tvdbId: hit.tvdbId,
    posterUrl: hit.posterUrl,
    progress: hit.progress ?? 0,
    lastWatchedAt: hit.lastSeenAt,
    tags: const [betaseriesWatchingTag],
  );
}

MediaItem betaseriesPlanShell(BetaseriesShowHit hit) {
  final key = hit.id > 0
      ? '${hit.id}'
      : (hit.tvdbId != null
          ? 'tvdb-${hit.tvdbId}'
          : (hit.imdbId ??
              hit.title.toLowerCase().replaceAll(RegExp(r'\s+'), '-')));
  return MediaItem(
    id: 'betaseries-plan:$key',
    title: hit.title,
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.url,
    year: hit.year,
    tmdbId: hit.tmdbId,
    imdbId: hit.imdbId,
    tvdbId: hit.tvdbId,
    posterUrl: hit.posterUrl,
    progress: 0,
    lastWatchedAt: hit.lastSeenAt,
    tags: const [betaseriesPlanTag],
  );
}

bool isBetaseriesWatchingShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains(betaseriesWatchingTag) ||
      (item.id.startsWith('betaseries:') &&
          !item.id.startsWith('betaseries-plan:'));
}

bool isBetaseriesPlanShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains(betaseriesPlanTag) ||
      item.id.startsWith('betaseries-plan:');
}

MediaItem _applyWatchingMeta(MediaItem base, BetaseriesShowHit hit) {
  return base.copyWith(
    lastWatchedAt: hit.lastSeenAt ?? base.lastWatchedAt,
    progress: hit.progress ?? base.progress,
    tmdbId: base.tmdbId ?? hit.tmdbId,
    imdbId: base.imdbId ?? hit.imdbId,
    tvdbId: base.tvdbId ?? hit.tvdbId,
    posterUrl: base.posterUrl ?? hit.posterUrl,
    tags: [
      ...base.tags.where((t) => t != betaseriesWatchingTag && t != betaseriesPlanTag),
      betaseriesWatchingTag,
    ],
  );
}

MediaItem _applyPlanMeta(MediaItem base, BetaseriesShowHit hit) {
  return base.copyWith(
    lastWatchedAt: hit.lastSeenAt ?? base.lastWatchedAt,
    tmdbId: base.tmdbId ?? hit.tmdbId,
    imdbId: base.imdbId ?? hit.imdbId,
    tvdbId: base.tvdbId ?? hit.tvdbId,
    posterUrl: base.posterUrl ?? hit.posterUrl,
    tags: [
      ...base.tags.where((t) => t != betaseriesWatchingTag && t != betaseriesPlanTag),
      betaseriesPlanTag,
    ],
  );
}

Future<List<MediaItem>> resolveBetaseriesWatchingItemsAsync(
  List<BetaseriesShowHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  int yieldEvery = 12,
}) async {
  final index = SimklMatchIndex([
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
    final matched = index.match(
      betaseriesHitToSimklIds(row),
      title: row.title,
      year: row.year,
    );
    final item = matched == null
        ? betaseriesWatchingShell(row)
        : _applyWatchingMeta(matched, row);
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

Future<List<MediaItem>> resolveBetaseriesPlanItemsAsync(
  List<BetaseriesShowHit> rows, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  int yieldEvery = 12,
}) async {
  final index = SimklMatchIndex([
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
    final matched = index.match(
      betaseriesHitToSimklIds(row),
      title: row.title,
      year: row.year,
    );
    final item =
        matched == null ? betaseriesPlanShell(row) : _applyPlanMeta(matched, row);
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

Future<List<MediaItem>> relinkBetaseriesWatchingItemsAsync(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  int yieldEvery = 16,
}) =>
    _relink(
      current,
      isShell: isBetaseriesWatchingShell,
      tag: betaseriesWatchingTag,
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: extra,
      yieldEvery: yieldEvery,
    );

Future<List<MediaItem>> relinkBetaseriesPlanItemsAsync(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  int yieldEvery = 16,
}) =>
    _relink(
      current,
      isShell: isBetaseriesPlanShell,
      tag: betaseriesPlanTag,
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: extra,
      yieldEvery: yieldEvery,
    );

Future<List<MediaItem>> _relink(
  List<MediaItem> current, {
  required bool Function(MediaItem) isShell,
  required String tag,
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  int yieldEvery = 16,
}) async {
  if (current.isEmpty) return current;
  final index = SimklMatchIndex([
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
    if (!isShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = index.match(
        SimklIds(
          tmdb: item.tmdbId,
          imdb: item.imdbId,
          tvdb: item.tvdbId,
        ),
        title: item.title,
        year: item.year,
      );
      if (matched == null) {
        if (seen.add(item.id)) out.add(item);
      } else {
        changed = true;
        final linked = matched.copyWith(
          lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
          progress: item.progress > 0 ? item.progress : matched.progress,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          tvdbId: matched.tvdbId ?? item.tvdbId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          tags: [
            ...matched.tags.where((t) => t != tag),
            tag,
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
