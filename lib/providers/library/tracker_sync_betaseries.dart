part of '../library_provider.dart';

/// Betaseries tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncBetaseries on LibraryProvider {
  Future<void> syncBetaseriesLists({bool force = false}) async {
    if (!betaseries.isAuthenticated) return;
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.betaseries, 'background');
      return;
    }
    final lastAttempt = _betaseriesLastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      TrackerLog.syncSkip(TrackerSources.betaseries, 'rate-limit');
      return;
    }
    await _bgQueue.enqueue(
      id: 'betaseries-sync',
      priority: BackgroundPriority.high,
      action: () => _syncBetaseriesListsBody(force: force),
    );
  }

  bool get isBetaseriesSyncing => _betaseriesSyncing;

  Future<void> saveBetaseriesCredentials(
    BetaseriesCredentials credentials,
  ) async {
    betaseries = credentials;
    await _store.saveBetaseries(credentials);
    final want = credentials.isAuthenticated;
    if (metadataSettings.wantBetaseriesLink != want) {
      await saveMetadataSettings(
        metadataSettings.copyWith(wantBetaseriesLink: want),
      );
    } else {
      notifyListeners();
    }
    if (want) {
      unawaited(clearTrackerLinkPromptDismissed());
      unawaited(syncBetaseriesLists(force: true));
    } else {
      betaseriesWatching = [];
      betaseriesPlan = [];
      trackerStatuses = trackerStatuses
          .where((e) => e.source != TrackerSources.betaseries)
          .toList();
      await Future.wait([
        _store.saveBetaseriesWatching(betaseriesWatching),
        _store.saveBetaseriesPlan(betaseriesPlan),
        _store.saveTrackerStatuses(trackerStatuses),
      ]);
      notifyListeners();
    }
  }

  Future<bool> testBetaseries() => _betaseries.validate(betaseries);

  Future<BetaseriesDeviceSession> requestBetaseriesDeviceCode() {
    return _betaseries.requestDeviceCode(betaseries);
  }

  Future<BetaseriesTokenResult> waitForBetaseriesDeviceToken({
    required BetaseriesDeviceSession session,
    required bool Function() isCancelled,
  }) {
    return _betaseries.waitForDeviceToken(
      creds: betaseries,
      session: session,
      isCancelled: isCancelled,
    );
  }

  Future<void> _syncBetaseriesListsBody({required bool force}) async {
    if (!betaseries.isAuthenticated) return;
    if (_betaseriesSyncing) {
      TrackerLog.syncSkip(TrackerSources.betaseries, 'in-flight');
      return;
    }
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.betaseries, 'background');
      return;
    }
    _betaseriesSyncing = true;
    _betaseriesLastSyncAttempt = DateTime.now();
    _setTrackerSyncPhase(TrackerSyncPhase.fetching);
    notifyListeners();
    var ok = true;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart(TrackerSources.betaseries, force: force);
    try {
      final lists = await _betaseries.getUserLists(betaseries);
      await Future<void>.delayed(Duration.zero);
      _setTrackerSyncPhase(TrackerSyncPhase.matching);
      betaseriesWatching = await resolveBetaseriesWatchingItemsAsync(
        lists.watching,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: _vodStreamCache.values,
      );
      betaseriesPlan = await resolveBetaseriesPlanItemsAsync(
        lists.planToWatch,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: [..._vodStreamCache.values, ...betaseriesWatching],
      );
      await _store.saveBetaseriesWatching(betaseriesWatching);
      await _store.saveBetaseriesPlan(betaseriesPlan);
      TrackerLog.shelf(
        TrackerSources.betaseries,
        'watching',
        count: betaseriesWatching.length,
      );
      TrackerLog.shelf(
        TrackerSources.betaseries,
        'plan',
        count: betaseriesPlan.length,
      );

      _setTrackerSyncPhase(TrackerSyncPhase.merging);
      final incoming = TrackerImportMapper.fromBetaseriesLists(lists);
      trackerStatuses = mergeTrackerStatuses(
        trackerStatuses,
        incoming,
        replaceSource: TrackerSources.betaseries,
      );
      await _store.saveTrackerStatuses(trackerStatuses);
      final index = await _ensureTrackerMatchIndex();
      final wasQuiet = _uiQuiet;
      _uiQuiet = true;
      try {
        await _applyTrackerProgressEntries(
          incoming,
          index: index,
          logSource: TrackerSources.betaseries,
        );
      } finally {
        _uiQuiet = wasQuiet;
      }

      betaseriesLastSyncAt = DateTime.now();
      await _store.saveBetaseriesLastSyncAt(betaseriesLastSyncAt!);
      _cachedRecommendations = null;
      _recommendationsStamp = -1;
      _notifyListenersAfterIdle();
      unawaited(_relinkBetaseriesShelves());
    } catch (e) {
      ok = false;
      JavpLog.w('betaseries', 'sync failed: $e', error: e);
    } finally {
      _betaseriesSyncing = false;
      _setTrackerSyncPhase(null);
      TrackerLog.syncEnd(
        TrackerSources.betaseries,
        ms: watch.elapsedMilliseconds,
        ok: ok,
      );
      _notifyListenersAfterIdle();
    }
  }

  Future<void> _relinkBetaseriesShelves() {
    return _bgQueue.enqueue(
      id: 'betaseries-relink',
      priority: BackgroundPriority.normal,
      action: () async {
        if (betaseriesWatching.isNotEmpty) {
          final linked = await relinkBetaseriesWatchingItemsAsync(
            betaseriesWatching,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
          );
          if (!identical(linked, betaseriesWatching) &&
              _watchingShelfChanged(betaseriesWatching, linked)) {
            betaseriesWatching = linked;
            await _store.saveBetaseriesWatching(betaseriesWatching);
            notifyListeners();
          }
        }
        if (betaseriesPlan.isNotEmpty) {
          final linked = await relinkBetaseriesPlanItemsAsync(
            betaseriesPlan,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: [..._vodStreamCache.values, ...betaseriesWatching],
          );
          if (!identical(linked, betaseriesPlan) &&
              _watchingShelfChanged(betaseriesPlan, linked)) {
            betaseriesPlan = linked;
            await _store.saveBetaseriesPlan(betaseriesPlan);
            notifyListeners();
          }
        }
      },
    );
  }

  MediaItem? resolveBetaseriesTap(MediaItem item) {
    if (!isBetaseriesWatchingShell(item) && !isBetaseriesPlanShell(item)) {
      return item;
    }
    return matchSimklIdsToLocal(
      SimklIds(tmdb: item.tmdbId, imdb: item.imdbId, tvdb: item.tvdbId),
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: _vodStreamCache.values,
      title: item.title,
      year: item.year,
    );
  }
}
