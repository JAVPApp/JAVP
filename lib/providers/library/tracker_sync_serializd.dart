part of '../library_provider.dart';

/// Serializd tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncSerializd on LibraryProvider {
  Future<void> syncSerializdActivity({bool force = false}) async {
    if (!serializd.isAuthenticated) return;
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.serializd, 'background');
      return;
    }
    final lastAttempt = _serializdLastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      TrackerLog.syncSkip(TrackerSources.serializd, 'rate-limit');
      return;
    }
    await _bgQueue.enqueue(
      id: 'serializd-sync',
      priority: BackgroundPriority.high,
      action: () => _syncSerializdActivityBody(force: force),
    );
  }

  MediaItem? resolveSerializdTap(MediaItem item) {
    if (!isSerializdWatchingShell(item) && !isSerializdWatchlistShell(item)) {
      return item;
    }
    return matchSimklIdsToLocal(
      SimklIds(tmdb: item.tmdbId),
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: _vodStreamCache.values,
      title: item.title,
      year: item.year,
    );
  }

  bool get isSerializdSyncing => _serializdSyncing;

  Future<void> saveSerializdCredentials(
    SerializdCredentials credentials,
  ) async {
    serializd = credentials;
    await _store.saveSerializd(credentials);
    final want = credentials.isAuthenticated;
    if (metadataSettings.wantSerializdLink != want) {
      await saveMetadataSettings(
        metadataSettings.copyWith(wantSerializdLink: want),
      );
    } else {
      notifyListeners();
    }
    if (want) {
      unawaited(clearTrackerLinkPromptDismissed());
      unawaited(syncSerializdActivity(force: true));
    } else {
      serializdWatching = [];
      serializdWatchlist = [];
      trackerStatuses = trackerStatuses
          .where((e) => e.source != TrackerSources.serializd)
          .toList();
      await Future.wait([
        _store.saveSerializdWatching(serializdWatching),
        _store.saveSerializdWatchlist(serializdWatchlist),
        _store.saveTrackerStatuses(trackerStatuses),
      ]);
      notifyListeners();
    }
  }

  Future<SerializdCredentials> loginSerializd({
    required String email,
    required String password,
  }) async {
    final direct = SerializdClient();
    try {
      final creds = await direct.login(email: email, password: password);
      await saveSerializdCredentials(creds);
      return creds;
    } finally {
      direct.close();
    }
  }

  Future<bool> testSerializd() => _serializd.validate(serializd);

  Future<void> _syncSerializdActivityBody({required bool force}) async {
    if (!serializd.isAuthenticated) return;
    if (_serializdSyncing) {
      TrackerLog.syncSkip(TrackerSources.serializd, 'in-flight');
      return;
    }
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.serializd, 'background');
      return;
    }
    _serializdSyncing = true;
    _serializdLastSyncAttempt = DateTime.now();
    _setTrackerSyncPhase(TrackerSyncPhase.fetching);
    var ok = true;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart(TrackerSources.serializd, force: force);
    try {
      final lists = await _serializd.getUserLists(serializd);
      if (lists.username != null &&
          lists.username!.isNotEmpty &&
          lists.username != serializd.username) {
        serializd = serializd.copyWith(username: lists.username);
        await _store.saveSerializd(serializd);
      }
      await Future<void>.delayed(Duration.zero);
      _setTrackerSyncPhase(TrackerSyncPhase.matching);
      serializdWatching = await resolveSerializdWatchingItemsAsync(
        lists.watching,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: _vodStreamCache.values,
      );
      serializdWatchlist = await resolveSerializdWatchlistItemsAsync(
        lists.watchlist,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: [..._vodStreamCache.values, ...serializdWatching],
      );
      await _store.saveSerializdWatching(serializdWatching);
      await _store.saveSerializdWatchlist(serializdWatchlist);
      TrackerLog.shelf(
        TrackerSources.serializd,
        'watching',
        count: serializdWatching.length,
      );
      TrackerLog.shelf(
        TrackerSources.serializd,
        'watchlist',
        count: serializdWatchlist.length,
      );

      _setTrackerSyncPhase(TrackerSyncPhase.merging);
      final incoming = lists.toStatusEntries();
      trackerStatuses = mergeTrackerStatuses(
        trackerStatuses,
        incoming,
        replaceSource: TrackerSources.serializd,
      );
      await _store.saveTrackerStatuses(trackerStatuses);
      final index = await _ensureTrackerMatchIndex();
      final wasQuiet = _uiQuiet;
      _uiQuiet = true;
      try {
        await _applyTrackerProgressEntries(
          incoming,
          index: index,
          logSource: TrackerSources.serializd,
        );
      } finally {
        _uiQuiet = wasQuiet;
      }

      serializdLastSyncAt = DateTime.now();
      await _store.saveSerializdLastSyncAt(serializdLastSyncAt!);
      _cachedRecommendations = null;
      _recommendationsStamp = -1;
      _notifyListenersAfterIdle();
      unawaited(_relinkSerializdShelves());
      unawaited(_flushPendingSerializdScrobbles());
    } catch (e) {
      ok = false;
      JavpLog.w('serializd', 'sync failed: $e', error: e);
    } finally {
      _serializdSyncing = false;
      _setTrackerSyncPhase(null);
      TrackerLog.syncEnd(
        TrackerSources.serializd,
        ms: watch.elapsedMilliseconds,
        ok: ok,
      );
      _notifyListenersAfterIdle();
    }
  }

  Future<void> _relinkSerializdShelves() {
    return _bgQueue.enqueue(
      id: 'serializd-relink',
      priority: BackgroundPriority.normal,
      action: () async {
        if (serializdWatching.isNotEmpty) {
          final linked = relinkSerializdShelf(
            serializdWatching,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            isShell: isSerializdWatchingShell,
            tag: serializdWatchingTag,
          );
          if (!identical(linked, serializdWatching) &&
              _watchingShelfChanged(serializdWatching, linked)) {
            serializdWatching = linked;
            await _store.saveSerializdWatching(serializdWatching);
            notifyListeners();
          }
        }
        if (serializdWatchlist.isNotEmpty) {
          final linked = relinkSerializdShelf(
            serializdWatchlist,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: [..._vodStreamCache.values, ...serializdWatching],
            isShell: isSerializdWatchlistShell,
            tag: serializdWatchlistTag,
          );
          if (!identical(linked, serializdWatchlist) &&
              _watchingShelfChanged(serializdWatchlist, linked)) {
            serializdWatchlist = linked;
            await _store.saveSerializdWatchlist(serializdWatchlist);
            notifyListeners();
          }
        }
      },
    );
  }

  Future<void> _maybeScrobbleSerializd(
    MediaItem item, {
    bool force = false,
  }) async {
    if (!serializd.isAuthenticated ||
        !metadataSettings.serializdScrobbleEnabled ||
        item.isLive ||
        item.kind == MediaKind.catchup) {
      if (force &&
          serializd.isAuthenticated &&
          !metadataSettings.serializdScrobbleEnabled &&
          !item.isLive &&
          item.kind != MediaKind.catchup) {
        TrackerLog.scrobble(
          TrackerSources.serializd,
          outcome: 'skip',
          title: item.title,
          id: TrackerLog.mediaId(tmdbId: item.tmdbId),
          season: item.seasonNumber,
          episode: item.episodeNumber,
          detail: 'reason=disabled',
        );
      }
      return;
    }
    if (item.progress < 0.9) return;
    final tmdbId = item.tmdbId;
    final season = item.seasonNumber;
    final episode = item.episodeNumber;
    if (tmdbId == null ||
        tmdbId <= 0 ||
        season == null ||
        season <= 0 ||
        episode == null ||
        episode <= 0) {
      TrackerLog.scrobble(
        TrackerSources.serializd,
        outcome: 'skip',
        title: item.title,
        detail: 'reason=no-ids',
      );
      return;
    }
    final key = '$tmdbId:$season:$episode';
    final now = DateTime.now();
    if (!force &&
        key == _lastSerializdScrobbleKey &&
        _lastSerializdScrobbleAt != null &&
        now.difference(_lastSerializdScrobbleAt!) <
            LibraryProvider._serializdScrobbleMinInterval) {
      return;
    }
    _lastSerializdScrobbleKey = key;
    _lastSerializdScrobbleAt = now;
    try {
      final seasonId = await _serializd.resolveSeasonId(
        showId: tmdbId,
        seasonNumber: season,
      );
      if (seasonId == null) {
        await _queueSerializdScrobble(
          PendingSerializdScrobble(
            showId: tmdbId,
            seasonNumber: season,
            episodeNumber: episode,
            title: item.title,
            queuedAt: now,
          ),
        );
        TrackerLog.scrobble(
          TrackerSources.serializd,
          outcome: 'queued',
          title: item.title,
          id: 'tmdb:$tmdbId',
          season: season,
          episode: episode,
          detail: 'reason=no-season-id',
        );
        return;
      }
      final ok = await _serializd.logEpisodes(
        creds: serializd,
        showId: tmdbId,
        seasonId: seasonId,
        episodeNumbers: [episode],
      );
      if (!ok) {
        await _queueSerializdScrobble(
          PendingSerializdScrobble(
            showId: tmdbId,
            seasonNumber: season,
            episodeNumber: episode,
            title: item.title,
            seasonId: seasonId,
            queuedAt: now,
          ),
        );
        TrackerLog.scrobble(
          TrackerSources.serializd,
          outcome: 'fail',
          title: item.title,
          id: 'tmdb:$tmdbId',
          season: season,
          episode: episode,
          detail: 'queued',
        );
      } else {
        TrackerLog.scrobble(
          TrackerSources.serializd,
          outcome: 'success',
          title: item.title,
          id: 'tmdb:$tmdbId',
          season: season,
          episode: episode,
        );
      }
    } catch (_) {
      await _queueSerializdScrobble(
        PendingSerializdScrobble(
          showId: tmdbId,
          seasonNumber: season,
          episodeNumber: episode,
          title: item.title,
          queuedAt: now,
        ),
      );
      TrackerLog.scrobble(
        TrackerSources.serializd,
        outcome: 'fail',
        title: item.title,
        id: 'tmdb:$tmdbId',
        season: season,
        episode: episode,
        detail: 'queued',
      );
    }
  }

  Future<void> _queueSerializdScrobble(PendingSerializdScrobble event) async {
    final existing = _pendingSerializdScrobbles.indexWhere(
      (e) =>
          e.showId == event.showId &&
          e.seasonNumber == event.seasonNumber &&
          e.episodeNumber == event.episodeNumber,
    );
    if (existing >= 0) {
      _pendingSerializdScrobbles[existing] = event;
    } else {
      _pendingSerializdScrobbles.add(event);
      if (_pendingSerializdScrobbles.length > 200) {
        _pendingSerializdScrobbles.removeRange(
          0,
          _pendingSerializdScrobbles.length - 200,
        );
      }
    }
    await _store.savePendingSerializdScrobbles(_pendingSerializdScrobbles);
  }

  Future<void> _flushPendingSerializdScrobbles() async {
    if (!serializd.isAuthenticated ||
        !metadataSettings.serializdScrobbleEnabled ||
        _flushingSerializdScrobbles ||
        _pendingSerializdScrobbles.isEmpty) {
      return;
    }
    _flushingSerializdScrobbles = true;
    try {
      final remaining = <PendingSerializdScrobble>[];
      var sent = 0;
      for (final event in List<PendingSerializdScrobble>.from(
        _pendingSerializdScrobbles,
      )) {
        try {
          final seasonId =
              event.seasonId ??
              await _serializd.resolveSeasonId(
                showId: event.showId,
                seasonNumber: event.seasonNumber,
              );
          if (seasonId == null) {
            remaining.add(event);
            continue;
          }
          final ok = await _serializd.logEpisodes(
            creds: serializd,
            showId: event.showId,
            seasonId: seasonId,
            episodeNumbers: [event.episodeNumber],
          );
          if (!ok) {
            remaining.add(event);
          } else {
            sent++;
          }
        } catch (_) {
          remaining.add(event);
        }
      }
      _pendingSerializdScrobbles
        ..clear()
        ..addAll(remaining);
      await _store.savePendingSerializdScrobbles(_pendingSerializdScrobbles);
      if (sent > 0 || remaining.isNotEmpty) {
        TrackerLog.scrobbleFlush(
          TrackerSources.serializd,
          sent: sent,
          remaining: remaining.length,
        );
      }
    } finally {
      _flushingSerializdScrobbles = false;
    }
  }
}
