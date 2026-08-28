part of '../library_provider.dart';

extension LibraryBootstrap on LibraryProvider {
  /// Restores lean Accueil shelves. Call before the first [notifyListeners] so
  /// Home can paint last-close content on frame 0 (no race with spinner).
  Future<void> _loadHomeShelfSnapshotEarly() async {
    if (_homeShelfSnapshot != null && _homeShelfSnapshot!.hasContent) return;
    try {
      final snap = await _store.loadHomeShelfSnapshot();
      if (_disposed || snap == null) return;
      _applyHomeShelfSnapshot(snap);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Await Accueil reveal settle (Drive sync / soft jobs). Times out → settle.
  Future<void> waitUntilHomeRevealSettled({
    Duration timeout = LibraryProvider._homeRevealSettleTimeout,
  }) async {
    if (_homeRevealSettled || _disposed) return;
    final c = _homeRevealSettledCompleter ??= Completer<void>();
    try {
      await c.future.timeout(timeout);
    } on TimeoutException {
      markHomeRevealSettled(reason: 'timeout');
    }
  }

  /// Home finished reveal 0→4 (or empty/timeout). Unlocks deferred cold work.
  void markHomeRevealSettled({String reason = 'reveal'}) {
    if (_homeRevealSettled || _disposed) return;
    _homeRevealSettled = true;
    _homeRevealSettleTimeoutTimer?.cancel();
    _homeRevealSettleTimeoutTimer = null;
    JavpLog.i('shelf', 'home reveal settled reason=$reason');
    JavpImageCache.instance.setStartupThrottle(false);
    _bgQueue.setColdStartMode(false);
    final waiters = _homeRevealSettledCompleter;
    _homeRevealSettledCompleter = null;
    if (waiters != null && !waiters.isCompleted) waiters.complete();
    if (_postRevealBootstrapArmed) {
      _postRevealBootstrapArmed = false;
      unawaited(_runPostRevealBootstrapWork(reason: reason));
    }
  }

  /// Loads profile state from disk.
  Future<void> bootstrap() async {
    loading = true;
    error = null;
    // Tiny JSON — await before first notify so Accueil paints last-close
    // shelves on frame 0 instead of racing a spinner (`snap=false`).
    await _loadHomeShelfSnapshotEarly();
    notifyListeners();
    // Startup lag is the thing users report, and it is invisible without a
    // timestamped record of where the pre-paint budget actually went.
    final watch = Stopwatch()..start();
    try {
      // --- Critical path: enough for Welcome routing + Home shelves ---
      // None of these depend on each other, and most spend their time waiting
      // on the keystore or a decode isolate rather than burning UI-isolate
      // CPU. Awaiting them one by one made the pre-Home stall the *sum* of
      // every stored list; starting them together makes it the slowest one.
      // Future.wait subscribes to all of them, so a single failure still lands
      // in the catch below without leaving unobserved errors behind.
      var downloadItems = const <MediaItem>[];
      final loadMs = <String, int>{};
      Future<T> timedLoad<T>(String name, Future<T> Function() load) async {
        final arm = Stopwatch()..start();
        final value = await load();
        loadMs[name] = arm.elapsedMilliseconds;
        return value;
      }

      await Future.wait<void>([
        timedLoad('proxy', _store.loadProxySettings).then((v) => proxy = v),
        timedLoad(
          'onboarding',
          _store.loadOnboardingCompleted,
        ).then((v) => onboardingCompleted = v),
        timedLoad(
          'torrentVpnTip',
          _store.loadTorrentVpnTipSeen,
        ).then((v) => torrentVpnTipSeen = v),
        timedLoad('sources', _store.loadSources).then((v) => sources = v),
        timedLoad('history', _store.loadHistory).then((v) => history = v),
        timedLoad(
          'historyDeleted',
          _store.loadHistoryDeleted,
        ).then((v) => _historyDeleted = v),
        timedLoad('watchlist', _store.loadWatchlist).then((v) => watchlist = v),
        timedLoad(
          'localMedia',
          _store.loadLocalMedia,
        ).then((v) => localMedia = v),
        timedLoad(
          'favoriteChannels',
          _store.loadFavoriteChannelIds,
        ).then((v) => favoriteChannelIds = v),
        timedLoad(
          'favoriteCategories',
          _store.loadFavoriteCategoryIds,
        ).then((v) => favoriteCategoryIds = v),
        timedLoad(
          'recentChannels',
          _store.loadRecentChannelIds,
        ).then((v) => recentChannelIds = v),
        // Cached Watching shelf — paint before network refresh.
        timedLoad('simkl', _store.loadSimkl).then((v) => simkl = v),
        timedLoad(
          'simklWatching',
          _store.loadSimklWatching,
        ).then((v) => simklWatching = v),
        timedLoad(
          'simklPlanToWatch',
          _store.loadSimklPlanToWatch,
        ).then((v) => simklPlanToWatch = v),
        timedLoad(
          'traktWatchlist',
          _store.loadTraktWatchlist,
        ).then((v) => traktWatchlist = v),
        timedLoad(
          'plexWatchlist',
          _store.loadPlexWatchlist,
        ).then((v) => plexWatchlist = v),
        timedLoad(
          'letterboxdWatchlist',
          _store.loadLetterboxdWatchlist,
        ).then((v) => letterboxdWatchlist = v),
        timedLoad('serializd', _store.loadSerializd).then((v) => serializd = v),
        timedLoad(
          'serializdWatching',
          _store.loadSerializdWatching,
        ).then((v) => serializdWatching = v),
        timedLoad(
          'serializdWatchlist',
          _store.loadSerializdWatchlist,
        ).then((v) => serializdWatchlist = v),
        timedLoad(
          'serializdLastSync',
          _store.loadSerializdLastSyncAt,
        ).then((v) => serializdLastSyncAt = v),
        timedLoad(
          'betaseries',
          _store.loadBetaseries,
        ).then((v) => betaseries = v),
        timedLoad(
          'betaseriesWatching',
          _store.loadBetaseriesWatching,
        ).then((v) => betaseriesWatching = v),
        timedLoad(
          'betaseriesPlan',
          _store.loadBetaseriesPlan,
        ).then((v) => betaseriesPlan = v),
        timedLoad(
          'betaseriesLastSync',
          _store.loadBetaseriesLastSyncAt,
        ).then((v) => betaseriesLastSyncAt = v),
        timedLoad(
          'trackerStatuses',
          _store.loadTrackerStatuses,
        ).then((v) => trackerStatuses = v),
        timedLoad(
          'letterboxdLastImport',
          _store.loadLetterboxdLastImportAt,
        ).then((v) => letterboxdLastImportAt = v),
        timedLoad(
          'simklLastSync',
          _store.loadSimklLastSyncAt,
        ).then((v) => simklLastSyncAt = v),
        timedLoad(
          'downloads',
          _store.loadDownloads,
        ).then((v) => downloadItems = v),
      ]);
      var slowestField = '';
      if (loadMs.isNotEmpty) {
        final slowest = loadMs.entries.reduce(
          (a, b) => a.value >= b.value ? a : b,
        );
        if (slowest.value >= 100) {
          slowestField = ' slowest=${slowest.key}:${slowest.value}ms';
        }
      }
      JavpLog.i(
        'bootstrap',
        'storage read in ${watch.elapsedMilliseconds}ms '
            'sources=${sources.length} history=${history.length} '
            'watchlist=${watchlist.length} downloads=${downloadItems.length}'
            '$slowestField',
      );

      // SOCKS DNS is expensive; only rebuild before paint when a proxy is on.
      if (proxy.isActive) {
        await _rebuildNetworkClients();
      }
      _torrent.applyProxySettings(proxy);

      final hadPersistedSources = sources.isNotEmpty;
      _sourcesRestored = true;
      _pruneHomeShelfSnapshotToVisibleSources();

      _downloads.restoreCompletedItems(downloadItems);
      // Scanning localMedia per download is quadratic in two lists that both
      // grow with the library, and it lands squarely before first paint.
      final localIds = {for (final m in localMedia) m.id};
      final restored = <MediaItem>[];
      for (final item in downloadItems) {
        if (item.origin != MediaOrigin.download) continue;
        if (!localIds.add(item.id)) continue;
        restored.add(item);
      }
      if (restored.isNotEmpty) {
        localMedia = [...restored.reversed, ...localMedia];
      }
      _downloadsHydrated = true;
      // Retirer URL tombstones must win over stale soft-persist / Drive history
      // that still carries the same pasted stream under another title.
      _purgeTombstonedOwnedLibraryRows(persist: true);

      // Paint shell ASAP — catalog / reminders / caches hydrate after.
      loading = false;
      notifyListeners();
      JavpLog.i(
        'bootstrap',
        'critical path done in ${watch.elapsedMilliseconds}ms',
      );
      await Future<void>.delayed(const Duration(milliseconds: 48));

      unawaited(_bootstrapDeferred(hadPersistedSources: hadPersistedSources));
    } catch (e) {
      JavpLog.e(
        'bootstrap',
        'failed after ${watch.elapsedMilliseconds}ms',
        error: e,
      );
      error = e.toString();
      loading = false;
      notifyListeners();
    }
  }

  /// After profile sync writes storage: refresh syncable in-memory state
  /// without the full bootstrap (no loading flash, no catalog re-import).
  ///
  /// Call [rebuildCatalogFromSources] afterwards when sources may have arrived
  /// without their derived catalog cache (restore / first sync).
  ///
  /// When [changedSections] is non-empty, only those sections are re-read and
  /// Accueil live caches / VOD prune run only if sources actually moved.
  Future<void> reloadAfterSync({
    List<String> changedSections = const [],
  }) async {
    final watch = Stopwatch()..start();
    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    final beforeStamp = homeShelfContentStamp;
    final prevSourceIds = {for (final s in sources) s.id};
    final prevEnabledFinger = Object.hashAll([
      for (final s in sources) Object.hash(s.id, s.enabled, s.vodEnabled),
    ]);
    final sourcesTouched =
        changedSections.isEmpty ||
        changedSections.contains(SnapshotSections.sources);
    final proxyTouched =
        changedSections.isEmpty ||
        changedSections.contains(SnapshotSections.proxySettings);
    final livePinsTouched =
        sourcesTouched ||
        changedSections.contains(SnapshotSections.favoriteChannels) ||
        changedSections.contains(SnapshotSections.recentChannels);
    try {
      // Only wipe live/home caches when sources may have moved — history-only
      // Drive pulls used to null these and force Accueil rematerialize.
      if (sourcesTouched) {
        _cachedLiveChannels = null;
        _liveGroupCountsCache = null;
        _liveGroupNamesCache = null;
        _cachedOnNow = null;
        _serverSessions.clear();
      }
      final load = Stopwatch()..start();
      await _reloadSyncableSections(changedSections);
      if (proxyTouched) {
        await _rebuildNetworkClients();
        _torrent.applyProxySettings(proxy);
      }
      await Future<void>.delayed(Duration.zero);
      final loadMs = load.elapsedMilliseconds;
      final nextEnabledFinger = Object.hashAll([
        for (final s in sources) Object.hash(s.id, s.enabled, s.vodEnabled),
      ]);
      if (prevEnabledFinger != nextEnabledFinger) {
        _sourcesEnabledStamp++;
      }
      final prune = Stopwatch()..start();
      _purgeTombstonedOwnedLibraryRows(persist: true);
      final sourceIds = {for (final s in sources) s.id};
      if (sourcesTouched) {
        final pruned = catalog
            .where((m) => m.sourceId == null || sourceIds.contains(m.sourceId))
            .toList(growable: false);
        if (pruned.length != catalog.length) {
          catalog = pruned;
          unawaited(_store.saveCatalog(catalog));
        }
      }
      // Heavy VOD prune only when the source id set actually changed.
      final sourceSetChanged =
          prevSourceIds.length != sourceIds.length ||
          !prevSourceIds.containsAll(sourceIds);
      // History-only Drive pulls used to always run [_pruneUnknownSourceCaches]
      // (DELETE scan on ~200k FTS rows). That serialized sqflite behind Search
      // for minutes (local vod=…/693282ms while pruneMs=535158).
      final needsSourceCachePrune = sourcesTouched || sourceSetChanged;
      if (sourceSetChanged) {
        await _yieldToBrowse(reason: 'reloadAfterSync-vod-prune');
        await _pruneVodCacheToKnownSources(persist: true);
      }
      if (sourcesTouched) {
        await _refreshLiveDbSourceIds();
        if (_useVodDb) {
          await _refreshVodDbSourceIds();
          await _refreshVodDbGroupCache();
        }
      }
      if (needsSourceCachePrune) {
        await _yieldToBrowse(reason: 'reloadAfterSync-orphan-prune');
        await _healOrphanedSourceIds();
        await _pruneUnknownSourceCaches();
      } else {
        // History / prefs-only: still heal list sourceIds (cheap catalog walk).
        await _healOrphanedSourceIds();
      }
      final pruneMs = prune.elapsedMilliseconds;
      final afterStamp = homeShelfContentStamp;
      final contentChanged = beforeStamp != afterStamp;
      if (contentChanged) {
        _invalidateHomeShelfCaches();
      }
      if (sourcesTouched || sourceSetChanged) {
        _sourcesRestored = true;
        _pruneHomeShelfSnapshotToVisibleSources();
      }
      JavpLog.i(
        'sync',
        'reloadAfterSync in ${watch.elapsedMilliseconds}ms '
            'loadMs=$loadMs pruneMs=$pruneMs '
            'contentChanged=$contentChanged '
            'sections=${changedSections.isEmpty ? "all" : changedSections.join(",")}',
      );
      if (contentChanged) {
        _notifyListenersAfterIdle();
      } else {
        JavpLog.i('sync', 'reloadAfterSync skip notify (content unchanged)');
      }
    } finally {
      _uiQuiet = wasQuiet;
      if (livePinsTouched) {
        unawaited(_reloadPinnedLiveChannels());
      }
      _logSourcesFeatureSummary(reason: 'profile-sync');
    }
  }

  /// Heavy prefs, reminders, catalog, and live pins — after first paint.
  Future<void> _bootstrapDeferred({required bool hadPersistedSources}) async {
    final watch = Stopwatch()..start();
    try {
      // Disk writes from critical path (non-blocking for first frame).
      unawaited(_persistDownloads());
      unawaited(_store.saveLocalMedia(localMedia));

      var phase = Stopwatch()..start();
      categories = await _store.loadCategories();
      await pumpUi();
      await Future.wait<void>([
        _store.loadPreferredLiveQualities().then(
          (v) => preferredLiveQualities = v,
        ),
        _store.loadPreferredVodVariants().then((v) => preferredVodVariants = v),
        _store
            .loadLiveScrubMode(fallback: _defaultLiveScrubMode)
            .then((v) => liveScrubMode = v),
        _store.loadCyclePlaybackSpeeds().then((v) => cyclePlaybackSpeeds = v),
        _store.loadLiveQualityMode().then((v) => liveQualityMode = v),
      ]);
      final liveCatCount = categories
          .where((c) => c.kind == IptvCategoryKind.live)
          .length;
      JavpLog.i(
        'bootstrap',
        'phase=prefs in ${phase.elapsedMilliseconds}ms '
            'categories=${categories.length} liveCats=$liveCatCount',
      );
      if (liveCatCount > 0) {
        liveDbRevision++;
      }
      // Open live SQLite before credentials / VOD hydrate pile onto the shared
      // sqflite isolate. Waiting until phase=catalog left TV on the memory
      // path (from=memory) while Catalog's group-index starved behind VOD
      // GROUP BY + sort-title rewrite.
      if (!_useLiveDb && !kIsWeb) {
        try {
          if (await _liveDb.hasListings) {
            _useLiveDb = true;
            liveDbRevision++;
            await _refreshLiveDbSourceIds();
            JavpLog.i(
              'bootstrap',
              'live db early-enable listings=true '
                  'sources=${_liveDbSourceIds.length}',
            );
            notifyListeners();
          }
        } catch (e) {
          JavpLog.w('bootstrap', 'live db early-enable failed', error: e);
        }
      }
      await pumpUi();

      // Credentials may already be loaded on critical path; refresh stamps.
      phase = Stopwatch()..start();
      await Future.wait<void>([
        _store.loadSimkl().then((v) => simkl = v),
        if (simklWatching.isEmpty)
          _store.loadSimklWatching().then((v) => simklWatching = v),
        if (simklPlanToWatch.isEmpty)
          _store.loadSimklPlanToWatch().then((v) => simklPlanToWatch = v),
        if (traktWatchlist.isEmpty)
          _store.loadTraktWatchlist().then((v) => traktWatchlist = v),
        if (plexWatchlist.isEmpty)
          _store.loadPlexWatchlist().then((v) => plexWatchlist = v),
        if (letterboxdWatchlist.isEmpty)
          _store.loadLetterboxdWatchlist().then((v) => letterboxdWatchlist = v),
        if (trackerStatuses.isEmpty)
          _store.loadTrackerStatuses().then((v) => trackerStatuses = v),
        _store.loadSimklLastSyncAt().then((v) => simklLastSyncAt = v),
        _store.loadSimklActivities().then((v) => _simklActivities = v),
        _store.loadSimklSyncDateFrom().then((v) => _simklSyncDateFrom = v),
        _store.loadTraktLastSyncAt().then((v) => traktLastSyncAt = v),
        _store.loadTraktLastActivities().then((v) => _traktActivities = v),
        _store.loadLetterboxdLastImportAt().then(
          (v) => letterboxdLastImportAt = v,
        ),
        _store.loadTmdb().then((v) => tmdb = v),
        _store.loadTrakt().then((v) => trakt = v),
        _store.loadMetadataSettings().then((v) => metadataSettings = v),
        _store.loadDisplaySettings().then((v) => displaySettings = v),
      ]);
      // Existing linked installs: persist want* so other devices can prompt.
      final migrated = metadataSettings.copyWith(
        wantSimklLink: metadataSettings.wantSimklLink || simkl.isAuthenticated,
        wantTraktLink: metadataSettings.wantTraktLink || trakt.isAuthenticated,
        wantSerializdLink:
            metadataSettings.wantSerializdLink || serializd.isAuthenticated,
        wantBetaseriesLink:
            metadataSettings.wantBetaseriesLink || betaseries.isAuthenticated,
      );
      if (migrated.wantSimklLink != metadataSettings.wantSimklLink ||
          migrated.wantTraktLink != metadataSettings.wantTraktLink ||
          migrated.wantSerializdLink != metadataSettings.wantSerializdLink ||
          migrated.wantBetaseriesLink != metadataSettings.wantBetaseriesLink) {
        metadataSettings = migrated;
        await _store.saveMetadataSettings(migrated);
        _noteSyncableChange();
      }
      JavpLog.i(
        'bootstrap',
        'phase=credentials in ${phase.elapsedMilliseconds}ms',
      );
      await pumpUi();

      phase = Stopwatch()..start();
      detailsCache = await _store.loadDetailsCache();
      await pumpUi();
      collections = await _store.loadCollections();
      await pumpUi();
      playlists = await _store.loadPlaylists();
      await pumpUi();
      segmentCache = await _store.loadSegmentCache();
      JavpLog.i('bootstrap', 'phase=caches in ${phase.elapsedMilliseconds}ms');
      await pumpUi();

      phase = Stopwatch()..start();
      await Future.wait<void>([
        _store.loadSkipSettings().then((v) => skipSettings = v),
        _store.loadTrackLanguageSettings().then(
          (v) => trackLanguageSettings = v,
        ),
        _store.loadMediaServerStreamQuality().then(
          (v) => mediaServerStreamQuality = v,
        ),
        _store.loadDownloadSettings().then((v) => downloadSettings = v),
        _store.loadSoftwareVideoDecoder().then((v) => softwareVideoDecoder = v),
        _store.loadCastServerTranscodeFallback().then(
          (v) => castServerTranscodeFallback = v,
        ),
        _store.loadKnownEpisodeIds().then((v) => knownEpisodeIdsBySeries = v),
      ]);
      JavpLog.i(
        'bootstrap',
        'phase=settings in ${phase.elapsedMilliseconds}ms',
      );
      // Wi‑Fi-only gate is mobile-only; never block the desktop download queue.
      _downloads.wifiOnly = DesktopUi.enabled
          ? false
          : downloadSettings.wifiOnly;
      notifyListeners();

      final pendingRemoves = await _store.loadPendingRemoveAfterWatch();
      for (final item in pendingRemoves) {
        final task = _completedDownloadTaskFor(item);
        final key = task != null ? _removeScheduleKey(task, item) : item.id;
        _pendingRemoveWhenOnline[key] = item;
      }
      unawaited(_flushPendingRemoveAfterWatch());
      _pendingSimklScrobbles
        ..clear()
        ..addAll(await _store.loadPendingSimklScrobbles());
      unawaited(_flushPendingSimklScrobbles());
      _pendingSerializdScrobbles
        ..clear()
        ..addAll(await _store.loadPendingSerializdScrobbles());
      unawaited(_flushPendingSerializdScrobbles());

      // Reminder plugin + timezone DB — never block first paint.
      unawaited(_hydrateEpgReminders());

      // Yield so Home frames aren't fighting catalog decode.
      await pumpUi();

      if (await _liveDb.hasListings) {
        _useLiveDb = true;
        liveDbRevision++;
        await _refreshLiveDbSourceIds();
        // Pins before catalog decode — Home Watch live must not wait on VOD JSON.
        await _reloadPinnedLiveChannels();
        notifyListeners();
      }

      // VOD SQLite before catalog decode so Catalog can skip JSON hydrate.
      await _maybeMigrateVodJsonToDb();

      if (!kIsWeb) {
        try {
          if (await _epgDb.hasPrograms) {
            await _enableEpgDb(reason: 'existing-db');
            notifyListeners();
          }
        } catch (e) {
          JavpLog.w('epg', 'bootstrap db failed', error: e);
        }
      }

      phase = Stopwatch()..start();
      catalog = await _store.loadCatalog(
        skipLiveHydrate: _useLiveDb,
        onLiveStripped: (live) async {
          if (live.isEmpty || _useLiveDb) return;
          await _enableLiveDbFromChannels(live, reason: 'migrate');
        },
      );
      final sourceIds = {for (final s in sources) s.id};
      final pruned = catalog
          .where((m) => m.sourceId == null || sourceIds.contains(m.sourceId))
          .toList();
      if (pruned.length != catalog.length) {
        catalog = pruned;
        await _store.saveCatalog(catalog);
      }
      JavpLog.i(
        'bootstrap',
        'phase=catalog in ${phase.elapsedMilliseconds}ms '
            'items=${catalog.length} liveDb=$_useLiveDb '
            'at=${watch.elapsedMilliseconds}ms',
      );

      await pumpUi();
      phase = Stopwatch()..start();
      if (_useLiveDb) {
        await _pruneUnknownSourceCaches();
        await _reloadPinnedLiveChannels();
      } else if (await _liveDb.hasListings) {
        _useLiveDb = true;
        liveDbRevision++;
        await _pruneUnknownSourceCaches();
        await _refreshLiveDbSourceIds();
        await _reloadPinnedLiveChannels();
      } else {
        await _reloadPinnedLiveChannels();
      }
      // Collapse variant-sibling pins left over from before the fix so For you /
      // Watched recently stop listing multiple versions of the same channel.
      await _collapseLegacyLivePins();
      JavpLog.i(
        'bootstrap',
        'phase=livePins in ${phase.elapsedMilliseconds}ms',
      );
      notifyListeners();

      // Xtream VOD/series disk hydrate is huge (~200k rows / multi-second parse
      // + variant index). Do not compete with first paint or deferred catalog —
      // Catalog / Search demand-load it; Home schedules a late idle warm.
      JavpLog.i('bootstrap', 'phase=vodDisk deferred (idle/demand)');

      localMedia = await _purgeDemoSamples(localMedia);
      notifyListeners();

      if (!_useLiveDb) {
        unawaited(ensureLiveIndex(delay: const Duration(milliseconds: 400)));
      }

      if (!onboardingCompleted && hadPersistedSources) {
        await completeOnboarding();
      }

      // Simkl / soft sync / deep-sync / for-you wait for Accueil reveal settle
      // so they don't pile onto the ~1s post-reveal shelf hitch.
      _armPostRevealBootstrapWork();
      unawaited(_reindexLiveFamiliesAfterReveal());
      _agentSyncTrigger ??= AgentSyncTrigger(
        sources: () => sources,
        syncSource: syncSource,
      )..start();
      JavpLog.i('bootstrap', 'deferred done in ${watch.elapsedMilliseconds}ms');
      _logSourcesFeatureSummary(reason: 'bootstrap');
    } catch (e) {
      JavpLog.e(
        'bootstrap',
        'deferred failed after ${watch.elapsedMilliseconds}ms',
        error: e,
      );
      error = e.toString();
      notifyListeners();
    }
  }
}
