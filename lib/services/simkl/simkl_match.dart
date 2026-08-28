import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';

/// ID + title indexes so Watching sync is O(rows) instead of O(rows × catalog).
class SimklMatchIndex {
  SimklMatchIndex([Iterable<MediaItem> pools = const []]) {
    addAll(pools);
  }

  final Map<int, List<MediaItem>> _byAnilist = {};
  final Map<int, List<MediaItem>> _byTmdb = {};
  final Map<String, List<MediaItem>> _bySimkl = {};
  final Map<int, List<MediaItem>> _byTvdb = {};
  final Map<String, List<MediaItem>> _byImdb = {};
  final Map<String, MediaItem> _seriesById = {};
  final Map<String, List<MediaItem>> _byNormTitle = {};

  /// First-5-char buckets so loose title fallback is not O(all titles).
  final Map<String, List<String>> _normTitleKeysByPrefix = {};

  void add(MediaItem item) {
    // Episode rows inherit show AniList/TMDB ids and often have a playUrl —
    // indexing them makes Watching link to "Episode 7" instead of the series.
    if (item.isEpisode) return;
    if (item.isLive) return;

    if (item.anilistId != null) {
      _byAnilist.putIfAbsent(item.anilistId!, () => []).add(item);
    }
    if (item.tmdbId != null) {
      _byTmdb.putIfAbsent(item.tmdbId!, () => []).add(item);
    }
    if (item.simklId != null) {
      _bySimkl.putIfAbsent(item.simklId!, () => []).add(item);
    }
    if (item.tvdbId != null) {
      _byTvdb.putIfAbsent(item.tvdbId!, () => []).add(item);
    }
    final imdb = item.imdbId?.toLowerCase();
    if (imdb != null && imdb.isNotEmpty) {
      _byImdb.putIfAbsent(imdb, () => []).add(item);
    }
    if (item.isSeries) {
      _seriesById[item.id] = item;
      final streamId = item.streamId;
      if (streamId != null && streamId.isNotEmpty) {
        _seriesById[streamId] = item;
      }
    }
    final key = _normTitle(item.title);
    if (key.isNotEmpty) {
      _addNormTitleKey(key, item);
    }
    final original = item.originalTitle;
    if (original != null) {
      final ok = _normTitle(original);
      if (ok.isNotEmpty) {
        _addNormTitleKey(ok, item);
      }
    }
  }

  /// Parent series for an episode [seriesId] / stream id, if indexed.
  MediaItem? seriesById(String? id) {
    final key = id?.trim();
    if (key == null || key.isEmpty) return null;
    return _seriesById[key];
  }

  void addAll(Iterable<MediaItem> pools) {
    for (final item in pools) {
      add(item);
    }
  }

  void _addNormTitleKey(String key, MediaItem item) {
    final list = _byNormTitle.putIfAbsent(key, () => []);
    list.add(item);
    if (list.length == 1) {
      _normTitleKeysByPrefix.putIfAbsent(_titlePrefix(key), () => []).add(key);
    }
  }

  /// Frame-yielding build for large VOD/catalog pools (UI isolate safe).
  ///
  /// Time-sliced (~[sliceMs]) so Accueil keeps getting frames while indexing
  /// ~200k VOD rows after disk hydrate (unconditional yield-every-N still
  /// produced multi-second build=0 stalls under GC pressure).
  static Future<SimklMatchIndex> buildAsync(
    Iterable<MediaItem> pools, {
    int yieldEvery = 256,
    int sliceMs = 8,
  }) async {
    final index = SimklMatchIndex();
    var n = 0;
    final slice = Stopwatch()..start();
    for (final item in pools) {
      index.add(item);
      if (yieldEvery > 0 && (++n % yieldEvery) == 0) {
        if (sliceMs <= 0 || slice.elapsedMilliseconds >= sliceMs) {
          await yieldAfterIsolateChunk();
          slice.reset();
        }
      }
    }
    return index;
  }

  MediaItem? match(SimklIds ids, {String? title, int? year}) {
    MediaItem? best;
    var bestRanked = 0;
    void consider(MediaItem item, int score) {
      if (score <= 0) return;
      if (item.isEpisode || item.isLive) return;
      // Prefer series shells over playable movie rows when scores tie; playUrl
      // still breaks ties so a real catalog hit beats an empty shell.
      final ranked =
          score * 10 +
          (item.isSeries ? 4 : 0) +
          (item.playUrl.trim().isNotEmpty ? 3 : 0);
      if (ranked > bestRanked) {
        best = item;
        bestRanked = ranked;
      }
    }

    void considerPool(Iterable<MediaItem>? pool) {
      if (pool == null) return;
      for (final item in pool) {
        consider(item, _scoreMatch(item, ids));
      }
    }

    considerPool(ids.anilist != null ? _byAnilist[ids.anilist!] : null);
    considerPool(ids.tmdb != null ? _byTmdb[ids.tmdb!] : null);
    considerPool(ids.simkl != null ? _bySimkl[ids.simkl!] : null);
    considerPool(ids.tvdb != null ? _byTvdb[ids.tvdb!] : null);
    final imdb = ids.imdb?.toLowerCase();
    if (imdb != null && imdb.isNotEmpty) considerPool(_byImdb[imdb]);

    // Title (+ optional year) when local rows lack TMDB/IMDB/AniList yet.
    if (best == null && title != null && title.trim().isNotEmpty) {
      final needle = _normTitle(title);
      if (needle.isNotEmpty) {
        void considerTitleHits(Iterable<MediaItem> pool) {
          for (final item in pool) {
            if (year != null &&
                item.year != null &&
                (item.year! - year).abs() > 1) {
              continue;
            }
            consider(item, 1);
          }
        }

        final exact = _byNormTitle[needle];
        if (exact != null) considerTitleHits(exact);

        if (best == null && needle.length >= 5) {
          final keys = _normTitleKeysByPrefix[_titlePrefix(needle)];
          if (keys != null) {
            for (final key in keys) {
              if (!_normKeysLooselyMatch(key, needle)) continue;
              final pool = _byNormTitle[key];
              if (pool != null) considerTitleHits(pool);
            }
          }
        }
      }
    }

    final hit = best;
    if (hit == null || hit.isEpisode) return null;
    return hit;
  }
}

/// Promote a wrongly linked episode Watching card to its series (or a shell).
MediaItem? promoteWatchingEpisodeHit(
  MediaItem episode, {
  required SimklMatchIndex index,
}) {
  if (!episode.isEpisode) return null;
  final series =
      index.seriesById(episode.seriesId) ??
      index.seriesById(episode.streamId) ??
      index.match(
        SimklIds(
          simkl: episode.simklId,
          tmdb: episode.tmdbId,
          imdb: episode.imdbId,
          tvdb: episode.tvdbId,
          anilist: episode.anilistId,
        ),
      );
  if (series == null || series.isEpisode) return null;
  return series.copyWith(
    lastWatchedAt: episode.lastWatchedAt ?? series.lastWatchedAt,
    simklId: series.simklId ?? episode.simklId,
    tmdbId: series.tmdbId ?? episode.tmdbId,
    imdbId: series.imdbId ?? episode.imdbId,
    tvdbId: series.tvdbId ?? episode.tvdbId,
    anilistId: series.anilistId ?? episode.anilistId,
    posterUrl: series.posterUrl ?? episode.posterUrl,
    thumbnailUrl: series.thumbnailUrl ?? episode.thumbnailUrl,
    progress: episode.progress > series.progress
        ? episode.progress
        : series.progress,
    subtitle: episode.subtitle ?? series.subtitle,
  );
}

/// Tracker shell when an episode was linked but no parent series is local yet.
MediaItem watchingShellFromOrphanEpisode(MediaItem episode) {
  final key =
      episode.simklId ??
      (episode.anilistId != null ? 'al-${episode.anilistId}' : null) ??
      (episode.tmdbId != null ? 'tmdb-${episode.tmdbId}' : null) ??
      episode.seriesId?.trim() ??
      episode.id;
  var title = episode.title.trim();
  final bareEpisode = RegExp(
    r'^(episode|épisode|ep)\s*\d+$',
    caseSensitive: false,
  ).hasMatch(title);
  // Prefer "Show Name" from "Show · S01E07 · …" over bare "Episode 7".
  if (title.isEmpty || bareEpisode) {
    final sub = episode.subtitle?.trim() ?? '';
    final head = sub.contains(' · ') ? sub.split(' · ').first.trim() : '';
    if (head.isNotEmpty &&
        !RegExp(r'\d+\s*/\s*\d+\s*eps', caseSensitive: false).hasMatch(head) &&
        !RegExp(
          r'^(episode|épisode|ep)\s*\d+$',
          caseSensitive: false,
        ).hasMatch(head)) {
      title = head;
    }
  }
  // Never persist a Watching shell titled "Episode 7" (Simkl progress-only
  // subtitles leave no show name — fall back to seriesId / tracker key).
  if (title.isEmpty ||
      RegExp(
        r'^(episode|épisode|ep)\s*\d+$',
        caseSensitive: false,
      ).hasMatch(title)) {
    final sid = episode.seriesId?.trim();
    title = (sid != null && sid.isNotEmpty) ? sid : key;
  }
  return MediaItem(
    id: 'simkl:$key',
    title: title,
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.url,
    posterUrl: episode.posterUrl,
    thumbnailUrl: episode.thumbnailUrl,
    backdropUrl: episode.backdropUrl,
    year: episode.year,
    simklId: episode.simklId,
    tmdbId: episode.tmdbId,
    imdbId: episode.imdbId,
    tvdbId: episode.tvdbId,
    anilistId: episode.anilistId,
    lastWatchedAt: episode.lastWatchedAt,
    progress: episode.progress,
    subtitle: episode.subtitle,
    tags: const ['simkl-watching'],
  );
}

String _titlePrefix(String norm) =>
    norm.length <= 5 ? norm : norm.substring(0, 5);

/// Prefer catalog / history / watchlist / VOD hits over Simkl-only shells.
MediaItem? matchSimklIdsToLocal(
  SimklIds ids, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  String? title,
  int? year,
  SimklMatchIndex? index,
}) {
  final idx =
      index ??
      SimklMatchIndex([...catalog, ...history, ...watchlist, ...extra]);
  return idx.match(ids, title: title, year: year);
}

int _scoreMatch(MediaItem item, SimklIds ids) {
  var score = 0;
  if (ids.anilist != null && item.anilistId == ids.anilist) score += 5;
  if (ids.tmdb != null && item.tmdbId == ids.tmdb) score += 4;
  if (ids.imdb != null &&
      item.imdbId != null &&
      item.imdbId!.toLowerCase() == ids.imdb!.toLowerCase()) {
    score += 3;
  }
  if (ids.simkl != null && item.simklId == ids.simkl) score += 3;
  if (ids.tvdb != null && item.tvdbId == ids.tvdb) score += 2;
  return score;
}

String _normTitle(String title) {
  var t = title.toLowerCase();
  // Strip common IPTV noise before comparing.
  t = t.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  t = t.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  t = t.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
  t = t.replaceAll(
    RegExp(r'\b(s\d{1,2}e\d{1,2}|season\s*\d+|complete|pack)\b'),
    ' ',
  );
  return t.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

bool _normKeysLooselyMatch(String na, String nb) {
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;
  // Allow IPTV titles that append language/quality tokens after the real name.
  if (na.length >= 5 && nb.length >= 5) {
    if (na.startsWith(nb) || nb.startsWith(na)) return true;
  }
  return false;
}

MediaItem _applySimklWatchingMeta(MediaItem base, SimklLibraryItem row) {
  final next = row.progressSubtitle;
  final remoteProgress = row.episodeProgress;
  // Prefer Simkl series progress when local playhead is empty / negligible.
  final progress = remoteProgress != null && base.progress <= 0.02
      ? remoteProgress
      : (remoteProgress != null && remoteProgress > base.progress
            ? remoteProgress
            : base.progress);
  return base.copyWith(
    lastWatchedAt: row.lastWatchedAt ?? base.lastWatchedAt,
    simklId: base.simklId ?? row.ids.simkl,
    tmdbId: base.tmdbId ?? row.ids.tmdb,
    imdbId: base.imdbId ?? row.ids.imdb,
    tvdbId: base.tvdbId ?? row.ids.tvdb,
    anilistId: base.anilistId ?? row.ids.anilist,
    posterUrl: base.posterUrl ?? row.posterUrl,
    thumbnailUrl: base.thumbnailUrl ?? row.posterUrl,
    progress: progress,
    subtitle: next ?? base.subtitle,
  );
}

/// Non-playable placeholder when no local catalog match exists.
MediaItem simklLibraryShell(
  SimklLibraryItem item, {
  String tag = 'simkl-watching',
}) {
  final key =
      item.ids.simkl ??
      (item.ids.anilist != null ? 'al-${item.ids.anilist}' : null) ??
      (item.ids.tmdb != null ? 'tmdb-${item.ids.tmdb}' : null) ??
      item.ids.imdb ??
      item.title.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  final idPrefix = tag == 'simkl-plantowatch' ? 'simkl-plan' : 'simkl';
  return MediaItem(
    id: '$idPrefix:$key',
    title: item.title,
    playUrl: '',
    kind: item.isShow ? MediaKind.series : MediaKind.vod,
    origin: MediaOrigin.url,
    posterUrl: item.posterUrl,
    thumbnailUrl: item.posterUrl,
    year: item.year,
    simklId: item.ids.simkl,
    tmdbId: item.ids.tmdb,
    imdbId: item.ids.imdb,
    tvdbId: item.ids.tvdb,
    anilistId: item.ids.anilist,
    lastWatchedAt: item.lastWatchedAt,
    progress: item.episodeProgress ?? 0,
    subtitle: item.progressSubtitle,
    tags: [tag],
  );
}

bool isSimklWatchingShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  if (item.tags.contains('simkl-plantowatch') ||
      item.tags.contains('trakt-watchlist')) {
    return false;
  }
  if (item.tags.contains('plex-watchlist')) {
    return false;
  }
  return item.tags.contains('simkl-watching') || item.id.startsWith('simkl:');
}

bool isSimklPlanShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return item.tags.contains('simkl-plantowatch') ||
      item.id.startsWith('simkl-plan:');
}

bool isTrackerListShell(MediaItem item) {
  if (item.playUrl.trim().isNotEmpty) return false;
  return isSimklWatchingShell(item) ||
      isSimklPlanShell(item) ||
      item.tags.contains('trakt-watchlist') ||
      item.id.startsWith('trakt:') ||
      ((item.tags.contains('plex-watchlist') ||
              item.id.startsWith('plex-watchlist:')) &&
          !(item.origin == MediaOrigin.plex &&
              (item.serverItemId ?? '').isNotEmpty &&
              (item.sourceId ?? '').isNotEmpty)) ||
      item.tags.contains('serializd-watching') ||
      item.tags.contains('serializd-watchlist') ||
      item.id.startsWith('serializd:') ||
      item.tags.contains('betaseries-watching') ||
      item.tags.contains('betaseries-plan') ||
      item.id.startsWith('betaseries:') ||
      item.id.startsWith('betaseries-plan:') ||
      item.tags.contains('letterboxd-watchlist') ||
      item.id.startsWith('letterboxd:');
}

List<MediaItem> resolveSimklWatchingItems(
  List<SimklLibraryItem> rows, {
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
    if (!row.isWatchingStatus) continue;
    final matched = idx.match(row.ids, title: row.title, year: row.year);
    final item = matched == null
        ? simklLibraryShell(row)
        : _applySimklWatchingMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
  }
  _sortWatchingShelf(out);
  return out;
}

/// Same as [resolveSimklWatchingItems] but yields so the UI isolate can paint.
Future<List<MediaItem>> resolveSimklWatchingItemsAsync(
  List<SimklLibraryItem> rows, {
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
    if (!row.isWatchingStatus) continue;
    final matched = idx.match(row.ids, title: row.title, year: row.year);
    final item = matched == null
        ? simklLibraryShell(row)
        : _applySimklWatchingMeta(matched, row);
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  _sortWatchingShelf(out);
  return out;
}

void _sortWatchingShelf(List<MediaItem> out) {
  out.sort((a, b) {
    final aAt = a.lastWatchedAt;
    final bAt = b.lastWatchedAt;
    if (aAt == null && bAt == null) return a.title.compareTo(b.title);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return bAt.compareTo(aAt);
  });
}

/// Resolve SIMKL Plan-to-Watch rows to local catalog (or shells).
List<MediaItem> resolveSimklPlanToWatchItems(
  List<SimklLibraryItem> rows, {
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
    final status = row.status?.trim().toLowerCase();
    if (status != null && status.isNotEmpty && !row.isPlanToWatchStatus) {
      continue;
    }
    final matched = idx.match(row.ids, title: row.title, year: row.year);
    final item = matched == null
        ? simklLibraryShell(row, tag: 'simkl-plantowatch')
        : _applySimklWatchingMeta(matched, row).copyWith(
            tags: [
              ...matched.tags.where((t) => t != 'simkl-plantowatch'),
              'simkl-plantowatch',
            ],
          );
    if (!seen.add(item.id)) continue;
    out.add(item);
  }
  _sortWatchingShelf(out);
  return out;
}

Future<List<MediaItem>> resolveSimklPlanToWatchItemsAsync(
  List<SimklLibraryItem> rows, {
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
    final status = row.status?.trim().toLowerCase();
    if (status != null && status.isNotEmpty && !row.isPlanToWatchStatus) {
      continue;
    }
    final matched = idx.match(row.ids, title: row.title, year: row.year);
    final item = matched == null
        ? simklLibraryShell(row, tag: 'simkl-plantowatch')
        : _applySimklWatchingMeta(matched, row).copyWith(
            tags: [
              ...matched.tags.where((t) => t != 'simkl-plantowatch'),
              'simkl-plantowatch',
            ],
          );
    if (!seen.add(item.id)) continue;
    out.add(item);
    if (++n % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  _sortWatchingShelf(out);
  return out;
}

Future<List<MediaItem>> relinkSimklPlanItemsAsync(
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
    if (!isSimklPlanShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = idx.match(
        SimklIds(
          simkl: item.simklId,
          tmdb: item.tmdbId,
          imdb: item.imdbId,
          tvdb: item.tvdbId,
          anilist: item.anilistId,
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
          simklId: matched.simklId ?? item.simklId,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          tvdbId: matched.tvdbId ?? item.tvdbId,
          anilistId: matched.anilistId ?? item.anilistId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          progress: item.progress > matched.progress
              ? item.progress
              : matched.progress,
          subtitle: item.subtitle ?? matched.subtitle,
          tags: [
            ...matched.tags.where((t) => t != 'simkl-plantowatch'),
            'simkl-plantowatch',
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

/// Re-link cached Watching shells after catalog / VOD hydrate.
List<MediaItem> relinkSimklWatchingItems(
  List<MediaItem> current, {
  required List<MediaItem> catalog,
  required List<MediaItem> history,
  required List<MediaItem> watchlist,
  Iterable<MediaItem> extra = const [],
  SimklMatchIndex? index,
}) {
  if (current.isEmpty) return current;
  final idx =
      index ??
      SimklMatchIndex([...catalog, ...history, ...watchlist, ...extra]);
  final out = <MediaItem>[];
  var changed = false;
  final seen = <String>{};
  for (final item in current) {
    // Heal episode cards that snuck into Watching (e.g. "Episode 7").
    if (item.isEpisode) {
      changed = true;
      final promoted =
          promoteWatchingEpisodeHit(item, index: idx) ??
          watchingShellFromOrphanEpisode(item);
      if (seen.add(promoted.id)) out.add(promoted);
      continue;
    }
    if (!isSimklWatchingShell(item)) {
      if (seen.add(item.id)) out.add(item);
      continue;
    }
    final matched = idx.match(
      SimklIds(
        simkl: item.simklId,
        tmdb: item.tmdbId,
        imdb: item.imdbId,
        tvdb: item.tvdbId,
        anilist: item.anilistId,
      ),
      title: item.title,
      year: item.year,
    );
    if (matched == null) {
      if (seen.add(item.id)) out.add(item);
      continue;
    }
    changed = true;
    final linked = matched.copyWith(
      lastWatchedAt: item.lastWatchedAt ?? matched.lastWatchedAt,
      simklId: matched.simklId ?? item.simklId,
      tmdbId: matched.tmdbId ?? item.tmdbId,
      imdbId: matched.imdbId ?? item.imdbId,
      tvdbId: matched.tvdbId ?? item.tvdbId,
      anilistId: matched.anilistId ?? item.anilistId,
      posterUrl: matched.posterUrl ?? item.posterUrl,
      thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
      progress: item.progress > matched.progress
          ? item.progress
          : matched.progress,
      subtitle: item.subtitle ?? matched.subtitle,
    );
    if (seen.add(linked.id)) out.add(linked);
  }
  return changed ? out : current;
}

/// Async relink with frame yields (bootstrap / queue jobs).
Future<List<MediaItem>> relinkSimklWatchingItemsAsync(
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
    if (item.isEpisode) {
      changed = true;
      final promoted =
          promoteWatchingEpisodeHit(item, index: idx) ??
          watchingShellFromOrphanEpisode(item);
      if (seen.add(promoted.id)) out.add(promoted);
    } else if (!isSimklWatchingShell(item)) {
      if (seen.add(item.id)) out.add(item);
    } else {
      final matched = idx.match(
        SimklIds(
          simkl: item.simklId,
          tmdb: item.tmdbId,
          imdb: item.imdbId,
          tvdb: item.tvdbId,
          anilist: item.anilistId,
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
          simklId: matched.simklId ?? item.simklId,
          tmdbId: matched.tmdbId ?? item.tmdbId,
          imdbId: matched.imdbId ?? item.imdbId,
          tvdbId: matched.tvdbId ?? item.tvdbId,
          anilistId: matched.anilistId ?? item.anilistId,
          posterUrl: matched.posterUrl ?? item.posterUrl,
          thumbnailUrl: matched.thumbnailUrl ?? item.thumbnailUrl,
          progress: item.progress > matched.progress
              ? item.progress
              : matched.progress,
          subtitle: item.subtitle ?? matched.subtitle,
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
