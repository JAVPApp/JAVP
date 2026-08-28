part of '../library_provider.dart';

/// Trakt tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncTrakt on LibraryProvider {
  Future<void> saveTraktCredentials(TraktCredentials credentials) async {
    trakt = credentials;
    await _store.saveTrakt(credentials);
    final want = credentials.isAuthenticated;
    if (metadataSettings.wantTraktLink != want) {
      await saveMetadataSettings(
        metadataSettings.copyWith(wantTraktLink: want),
      );
    } else {
      notifyListeners();
    }
    if (want) {
      unawaited(clearTrackerLinkPromptDismissed());
      unawaited(syncTraktWatchlist(force: true));
    }
  }

  /// Pull Trakt watchlist when linked (last-activities gated).
  Future<void> syncTraktWatchlist({bool force = false}) async {
    if (!trakt.isAuthenticated) return;
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.trakt, 'background');
      return;
    }
    final lastAttempt = _traktLastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      TrackerLog.syncSkip(TrackerSources.trakt, 'rate-limit');
      return;
    }

    await _bgQueue.enqueue(
      id: 'trakt-watchlist-sync',
      priority: BackgroundPriority.high,
      action: () => _syncTraktWatchlistBody(force: force),
    );
  }

  bool get isTraktSyncing => _traktSyncing;

  Future<void> _syncTraktWatchlistBody({required bool force}) async {
    if (!trakt.isAuthenticated) return;
    if (_traktSyncing) {
      TrackerLog.syncSkip(TrackerSources.trakt, 'in-flight');
      return;
    }
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.trakt, 'background');
      return;
    }

    _traktSyncing = true;
    _traktLastSyncAttempt = DateTime.now();
    _setTrackerSyncPhase(TrackerSyncPhase.fetching);
    notifyListeners();
    var ok = true;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart(TrackerSources.trakt, force: force);
    try {
      final activities = await _trakt.getLastActivities(trakt);
      final prev = _traktActivities;
      final watchlistChanged =
          force || activities == null || !activities.watchlistUnchanged(prev);
      final playbackChanged =
          force || activities == null || !activities.playbackUnchanged(prev);
      final droppedChanged =
          force || activities == null || !activities.droppedUnchanged(prev);
      if (watchlistChanged) {
        final rows = await _trakt.getWatchlist(trakt);
        await Future<void>.delayed(Duration.zero);
        final index = await _ensureTrackerMatchIndex();
        _setTrackerSyncPhase(TrackerSyncPhase.matching);
        traktWatchlist = await resolveTraktWatchlistItemsAsync(
          rows,
          catalog: catalog,
          history: history,
          watchlist: watchlist,
          extra: _vodStreamCache.values,
          index: index,
        );
        await _store.saveTraktWatchlist(traktWatchlist);
        TrackerLog.shelf(
          TrackerSources.trakt,
          'watchlist',
          count: traktWatchlist.length,
        );
        notifyListeners();
      }
      if (playbackChanged || droppedChanged || force) {
        _setTrackerSyncPhase(TrackerSyncPhase.merging);
        final index = await _ensureTrackerMatchIndex();
        await _mergeTraktInboundStatuses(
          playbackChanged: playbackChanged || force,
          droppedChanged: droppedChanged || force,
          index: index,
        );
      }
      if (activities != null) {
        _traktActivities = activities;
        await _store.saveTraktLastActivities(activities);
      }
      traktLastSyncAt = DateTime.now();
      await _store.saveTraktLastSyncAt(traktLastSyncAt!);
    } catch (_) {
      ok = false;
      // Keep last good cache; never block the UI.
    } finally {
      _traktSyncing = false;
      _trackerSyncPhase = null;
      TrackerLog.syncEnd(
        TrackerSources.trakt,
        ms: watch.elapsedMilliseconds,
        ok: ok,
      );
      notifyListeners();
    }
  }

  Future<void> _relinkTraktWatchlist({
    BackgroundPriority priority = BackgroundPriority.normal,
  }) {
    if (traktWatchlist.isEmpty) return Future<void>.value();
    return _bgQueue.enqueue(
      id: 'trakt-watchlist-relink',
      priority: priority,
      action: () async {
        if (traktWatchlist.isEmpty) return;
        if (priority == BackgroundPriority.low &&
            (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork)) {
          return;
        }
        final wasQuiet = _uiQuiet;
        _uiQuiet = true;
        try {
          final index = await _ensureTrackerMatchIndex();
          final linked = await relinkTraktWatchlistItemsAsync(
            traktWatchlist,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            index: index,
          );
          if (identical(linked, traktWatchlist)) return;
          if (!_watchingShelfChanged(traktWatchlist, linked)) return;
          traktWatchlist = linked;
          await _store.saveTraktWatchlist(traktWatchlist);
        } finally {
          _uiQuiet = wasQuiet;
          if (!_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }

  Future<void> _mergeTraktInboundStatuses({
    required bool playbackChanged,
    required bool droppedChanged,
    SimklMatchIndex? index,
  }) async {
    if (!trakt.isAuthenticated) return;
    try {
      final dropped = droppedChanged
          ? await _trakt.getDroppedShows(trakt)
          : const <TraktIdHit>[];
      final playbacks = playbackChanged
          ? await _trakt.getPlaybacks(trakt)
          : const <TraktPlayback>[];
      if (dropped.isEmpty && playbacks.isEmpty) return;

      final incoming = TrackerImportMapper.fromTraktInbound(
        dropped: dropped,
        playbacks: playbacks,
      );
      if (droppedChanged) {
        // Keep prior Trakt playbacks when only dropped changed? Safer: rebuild
        // from this pull — playbacks empty means drop Trakt watching playheads.
        final priorPlayheads = droppedChanged && !playbackChanged
            ? [
                for (final e in trackerStatuses)
                  if (e.source == TrackerSources.trakt &&
                      e.status == TrackerStatusKind.watching)
                    e,
              ]
            : const <TrackerStatusEntry>[];
        trackerStatuses = mergeTrackerStatuses(trackerStatuses, [
          ...priorPlayheads,
          ...incoming,
        ], replaceSource: TrackerSources.trakt);
      } else {
        trackerStatuses = mergeTrackerStatuses(trackerStatuses, incoming);
      }
      await _store.saveTrackerStatuses(trackerStatuses);
      _cachedContinueWatching = null;
      _continueWatchingStamp = -1;
      _cachedRecommendations = null;
      _recommendationsStamp = -1;
      _noteSyncableChange();

      await _applyTrackerProgressEntries(
        incoming,
        index: index,
        writeBehind: false,
        logSource: TrackerSources.trakt,
      );
    } catch (_) {}
  }
}
