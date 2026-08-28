part of '../library_provider.dart';

/// Shared tracker sync helpers (phase, match index, inbound progress, tap router).
///
/// Per-tracker bodies: `tracker_sync_{simkl,trakt,plex,letterboxd,serializd,betaseries}.dart`.
extension TrackerSyncShared on LibraryProvider {
  /// Shared SIMKL/Trakt (and future tracker) Sync Now stage for light UI progress.
  TrackerSyncPhase? get trackerSyncPhase => _trackerSyncPhase;

  /// Best local hit for a Watching / Plan / Trakt shell tile.
  MediaItem? resolveSimklWatchingTap(MediaItem item) {
    if (!isTrackerListShell(item)) return item;
    if (isLetterboxdWatchlistShell(item)) {
      return resolveLetterboxdWatchlistTap(item);
    }
    if (isSerializdWatchingShell(item) || isSerializdWatchlistShell(item)) {
      return resolveSerializdTap(item);
    }
    if (isBetaseriesWatchingShell(item) || isBetaseriesPlanShell(item)) {
      return resolveBetaseriesTap(item);
    }
    return matchSimklIdsToLocal(
      SimklIds(
        simkl: item.simklId,
        tmdb: item.tmdbId,
        imdb: item.imdbId,
        tvdb: item.tvdbId,
        anilist: item.anilistId,
      ),
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: _vodStreamCache.values,
      title: item.title,
      year: item.year,
    );
  }

  /// Search custom catalogs when a tracker shell has no local hit.
  Future<MediaItem?> resolveSimklWatchingTapAsync(MediaItem item) async {
    final local = resolveSimklWatchingTap(item);
    if (local != null) return local;
    if (!isTrackerListShell(item)) return item;
    // Prefer SQLite FTS (Xtream / packed catalogs) before remote /search.
    final ftsHit = await _matchTrackerShellViaVodFts(item);
    if (ftsHit != null && !isTrackerListShell(ftsHit)) return ftsHit;
    final hits = await searchRemoteCatalogs(item.title, limit: 16);
    if (hits.isEmpty) return null;
    return matchSimklIdsToLocal(
          SimklIds(
            simkl: item.simklId,
            tmdb: item.tmdbId,
            imdb: item.imdbId,
            tvdb: item.tvdbId,
            anilist: item.anilistId,
          ),
          catalog: hits,
          history: const [],
          watchlist: const [],
          title: item.title,
          year: item.year,
        ) ??
        hits.cast<MediaItem?>().firstWhere(
          (h) =>
              h != null &&
              !h.isLive &&
              !h.isEpisode &&
              (item.isSeries ? h.isSeries : true),
          // Never fall back to hits.first — that resurfaced "Episode 7" vod rows.
          orElse: () => null,
        );
  }

  bool get isTrackerSyncing =>
      _simklSyncing || _traktSyncing || _letterboxdImporting;

  void _setTrackerSyncPhase(TrackerSyncPhase? phase) {
    if (_trackerSyncPhase == phase) return;
    _trackerSyncPhase = phase;
    // Pierce quiet-mode like [_setSourceSyncStatus]: Settings selects phase /
    // isSimklSyncing only; Home's shelf stamp uses content fingerprint (not
    // syncing / list identity), so Sync Now banner refreshes without
    // rematerializing IndexedStack tabs mid-match.
    SchedulerBinding.instance.scheduleTask(() {
      if (_disposed) return;
      if (_trackerSyncPhase != phase) return;
      JavpLog.noteNotify();
      _notifyPierceQuiet();
    }, Priority.idle);
  }

  TrackerMatchPools _trackerMatchPools() => TrackerMatchPools(
    catalog: catalog,
    history: history,
    watchlist: watchlist,
    extra: _vodStreamCache.values,
    extraCount: _vodStreamCache.length,
  );

  int get _trackerMatchStamp => Object.hash(
    _vodCacheRevision,
    catalog.length,
    history.length,
    watchlist.length,
  );

  /// One chunked index per sync/relink wave — never rebuild per tracker row.
  Future<SimklMatchIndex> _ensureTrackerMatchIndex({
    bool forceRebuild = false,
  }) async {
    final stamp = _trackerMatchStamp;
    final cached = _trackerMatchIndex;
    if (!forceRebuild && cached != null && _trackerMatchIndexStamp == stamp) {
      return cached;
    }
    _setTrackerSyncPhase(TrackerSyncPhase.indexing);
    final index = await buildTrackerMatchIndex(_trackerMatchPools());
    _trackerMatchIndex = index;
    _trackerMatchIndexStamp = stamp;
    return index;
  }

  bool _watchingShelfChanged(List<MediaItem> a, List<MediaItem> b) {
    if (identical(a, b)) return false;
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].progress != b[i].progress) return true;
    }
    return false;
  }

  /// Letterboxd (and future trackers) completed/dropped rows for CW / For You.
  Iterable<TrackerStatusEntry> trackerStatusesFor(String source) =>
      trackerStatuses.where((e) => e.source == source);

  /// Mark local episodes watched from [trackerStatuses] when a series opens.
  ///
  /// Prefer exact next-to-watch / watched counts over crude %. Quiet + idle
  /// notify so Accueil shelves are not rematerialized.
  Future<void> _applyInboundTrackerEpisodeProgress(
    MediaItem series,
    SeriesInfo info,
  ) async {
    if (trackerStatuses.isEmpty || info.seasons.isEmpty) return;
    final entry = TrackerStatusStore(trackerStatuses).lookup(
      tmdbId: series.tmdbId,
      imdbId: series.imdbId,
      tvdbId: series.tvdbId,
      anilistId: series.anilistId,
      simklId: series.simklId,
      title: series.title,
      year: series.year,
    );
    if (entry == null) return;
    if (entry.status == TrackerStatusKind.dropped ||
        entry.status == TrackerStatusKind.hold ||
        entry.status == TrackerStatusKind.planToWatch ||
        entry.status == TrackerStatusKind.watchlist) {
      return;
    }

    final episodes = <TrackerEpisodeRef>[
      for (final season in info.seasons)
        for (final ep in season.episodes)
          TrackerEpisodeRef(
            id: ep.id,
            seasonNumber: ep.seasonNumber,
            episodeNumber: ep.episodeNum,
            title: ep.title,
            playUrl: ep.playUrl ?? '',
          ),
    ];
    if (episodes.isEmpty) return;

    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    var dirty = false;
    try {
      final merged = TrackerProgressMerger.applySeriesEpisodes(
        series: series,
        entry: entry,
        episodes: episodes,
        history: history,
        catalog: catalog,
      );
      TrackerLog.mergeResult(entry.source, merged, entries: 1);
      if (!merged.changed) return;
      history = merged.history;
      catalog = merged.catalog;
      _cachedContinueWatching = null;
      _continueWatchingStamp = -1;
      _schedulePersist(_PersistTarget.history);
      dirty = true;
    } finally {
      _uiQuiet = wasQuiet;
      if (dirty && !_disposed) _notifyListenersAfterIdle();
    }
  }

  bool _trackerEntryHasProgress(TrackerStatusEntry e) {
    if (e.status == TrackerStatusKind.completed) return true;
    if (e.watchedEpisodes != null && e.watchedEpisodes! > 0) return true;
    if (e.seasonNumber != null && e.episodeNumber != null) return true;
    return e.progress != null && e.progress! > 0.02;
  }

  /// Shared inbound playhead / episode-watched merge for all trackers.
  Future<bool> _applyTrackerProgressEntries(
    List<TrackerStatusEntry> incoming, {
    SimklMatchIndex? index,
    bool noteSyncable = true,
    bool writeBehind = true,
    String? logSource,
  }) async {
    final progressEntries = [
      for (final e in incoming)
        if (_trackerEntryHasProgress(e)) e,
    ];
    if (progressEntries.isEmpty) return false;
    final source = logSource ?? progressEntries.first.source;
    final idx = index ?? await _ensureTrackerMatchIndex();
    final merged = await TrackerProgressMerger.applyEntriesAsync(
      entries: progressEntries,
      history: history,
      catalog: catalog,
      watchlist: watchlist,
      extra: _vodStreamCache.values,
      index: idx,
    );
    TrackerLog.mergeResult(source, merged, entries: progressEntries.length);
    if (!merged.changed) return false;
    history = merged.history;
    catalog = merged.catalog;
    _cachedContinueWatching = null;
    _continueWatchingStamp = -1;
    if (writeBehind) {
      // Write-behind — awaiting a full catalog rewrite freezes the UI.
      _schedulePersist(_PersistTarget.history);
      _schedulePersist(_PersistTarget.catalog);
    } else {
      await _store.saveHistory(history);
      await _store.saveCatalog(catalog);
    }
    if (noteSyncable) _noteSyncableChange();
    return true;
  }

  /// True when any tracker shelf still has an unmatched shell (no playUrl).
  bool get hasUnmatchedTrackerShells {
    for (final item in simklWatching) {
      if (isSimklWatchingShell(item)) return true;
    }
    for (final item in simklPlanToWatch) {
      if (isSimklPlanShell(item)) return true;
    }
    for (final item in traktWatchlist) {
      if (isTrackerListShell(item)) return true;
    }
    for (final item in plexWatchlist) {
      if (isTrackerListShell(item)) return true;
    }
    for (final item in letterboxdWatchlist) {
      if (isTrackerListShell(item)) return true;
    }
    return false;
  }

  /// Display names of sources currently syncing / prefetching (Search status).
  List<String> syncingSourceLabels({String? onlySourceId, int limit = 3}) {
    final out = <String>[];
    for (final source in sources) {
      if (!source.enabled) continue;
      if (onlySourceId != null && source.id != onlySourceId) continue;
      if (!isSourceSyncActivity(source.id)) continue;
      final name = source.name.trim();
      if (name.isEmpty) continue;
      out.add(name);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Debounced relink after VOD rows land mid-sync (Xtream progressive ingest).
  ///
  /// Match index only covers RAM pools — SQLite FTS is queried per remaining
  /// shell inside [_relinkTrackerShellsViaVodFts]. Does not queue remote
  /// custom `/search` (that stays in Simkl activity sync) so mid-ingest
  /// growth waves do not stampede the network.
  void _scheduleTrackerRelinkOnCatalogGrowth({String reason = 'vod-growth'}) {
    if (_disposed || !hasUnmatchedTrackerShells) return;
    _trackerRelinkAfterVodTimer?.cancel();
    _trackerRelinkAfterVodTimer = Timer(const Duration(seconds: 2), () {
      _trackerRelinkAfterVodTimer = null;
      if (_disposed || !hasUnmatchedTrackerShells) return;
      JavpLog.i(
        'bg',
        'tracker-relink after catalog growth reason=$reason '
            'queue=${_bgQueue.pendingCount}',
      );
      // Stamp changed via vodCacheRevision — drop cached index so FTS can win.
      _trackerMatchIndex = null;
      unawaited(_relinkSimklWatching(priority: BackgroundPriority.low));
      unawaited(_relinkSimklPlanToWatch(priority: BackgroundPriority.low));
      unawaited(_relinkTraktWatchlist(priority: BackgroundPriority.low));
      unawaited(_relinkPlexWatchlist(priority: BackgroundPriority.low));
      unawaited(_relinkLetterboxdWatchlist(priority: BackgroundPriority.low));
    });
  }

  /// FTS / LIKE lookup in vod_catalog.db for one tracker shell title.
  Future<List<MediaItem>> _vodFtsHitsForTrackerTitle(
    String title, {
    bool? series,
    int limit = 24,
  }) async {
    final q = title.trim();
    if (q.isEmpty || !_useVodDb) return const [];
    try {
      return await _vodDb.searchFts(
        q,
        series: series,
        excludeAdult: _parentalExcludeAdult(),
        limit: limit,
      );
    } catch (e) {
      JavpLog.w('bg', 'tracker FTS lookup failed', error: e);
      return const [];
    }
  }

  /// Match a shell against SQLite VOD when the RAM index missed it.
  Future<MediaItem?> _matchTrackerShellViaVodFts(MediaItem shell) async {
    if (!isTrackerListShell(shell)) return null;
    // Constrain kind: movie shells must not bind a same-titled series row.
    final hits = await _vodFtsHitsForTrackerTitle(
      shell.title,
      series: shell.isSeries,
    );
    if (hits.isEmpty) return null;
    return matchSimklIdsToLocal(
          SimklIds(
            simkl: shell.simklId,
            tmdb: shell.tmdbId,
            imdb: shell.imdbId,
            tvdb: shell.tvdbId,
            anilist: shell.anilistId,
          ),
          catalog: hits,
          history: const [],
          watchlist: const [],
          title: shell.title,
          year: shell.year,
        ) ??
        hits.cast<MediaItem?>().firstWhere(
          (h) =>
              h != null &&
              !h.isLive &&
              !h.isEpisode &&
              h.isSeries == shell.isSeries,
          orElse: () => null,
        );
  }

  /// After index relink, try SQLite FTS for leftover Simkl Watching shells.
  Future<List<MediaItem>> _relinkTrackerShellsViaVodFts(
    List<MediaItem> current, {
    required bool Function(MediaItem) isShell,
  }) async {
    if (!_useVodDb || current.isEmpty) return current;
    final out = <MediaItem>[];
    var changed = false;
    var n = 0;
    for (final item in current) {
      if (!isShell(item)) {
        out.add(item);
        continue;
      }
      final matched = await _matchTrackerShellViaVodFts(item);
      if (matched == null || isTrackerListShell(matched)) {
        out.add(item);
      } else {
        changed = true;
        out.add(
          matched.copyWith(
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
            tags: item.tags.contains('simkl-plantowatch')
                ? [
                    ...matched.tags.where((t) => t != 'simkl-plantowatch'),
                    'simkl-plantowatch',
                  ]
                : matched.tags,
          ),
        );
      }
      if (++n % 4 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return changed ? out : current;
  }

  bool _trackerExcludesContinueWatching(
    TrackerStatusStore store,
    MediaItem item,
  ) {
    return store.excludesContinueWatching(
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
      anilistId: item.anilistId,
      simklId: item.simklId,
      title: item.title,
      year: item.year,
    );
  }
}
