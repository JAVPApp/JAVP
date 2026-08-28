part of '../library_provider.dart';

/// Simkl tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncSimkl on LibraryProvider {
  Future<void> saveSimklCredentials(SimklCredentials credentials) async {
    simkl = credentials;
    await _store.saveSimkl(credentials);
    final want = credentials.isAuthenticated;
    if (metadataSettings.wantSimklLink != want) {
      await saveMetadataSettings(
        metadataSettings.copyWith(wantSimklLink: want),
      );
    } else {
      notifyListeners();
    }
    if (want) {
      unawaited(clearTrackerLinkPromptDismissed());
      unawaited(syncSimklActivity(force: true));
    }
  }

  /// Pull Watching + Plan-to-Watch + paused playbacks (activities-gated).
  ///
  /// Queued at [BackgroundPriority.high] so catalog deep-sync / VOD warm wait.
  Future<void> syncSimklActivity({bool force = false}) async {
    if (!simkl.isAuthenticated) return;
    // Never start a heavy Watching+catalog pull while the user is AFK.
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.simkl, 'background');
      return;
    }
    final lastAttempt = _simklLastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      TrackerLog.syncSkip(TrackerSources.simkl, 'rate-limit');
      return;
    }

    await _bgQueue.enqueue(
      id: 'simkl-sync',
      priority: BackgroundPriority.high,
      action: () => _syncSimklActivityBody(force: force),
    );
  }

  /// Dedup keys for Simkl `/sync/history` (watching-once per show, completed per title).
  // Field lives on LibraryProvider — extensions cannot declare instance fields.

  Future<bool> testSimkl() => _simkl.validate(simkl);

  bool get isSimklSyncing => _simklSyncing;

  Future<void> _syncSimklActivityBody({required bool force}) async {
    if (!simkl.isAuthenticated) return;
    if (_simklSyncing) {
      TrackerLog.syncSkip(TrackerSources.simkl, 'in-flight');
      return;
    }
    if (!force && !_appForeground) {
      TrackerLog.syncSkip(TrackerSources.simkl, 'background');
      return;
    }

    _simklSyncing = true;
    _simklLastSyncAttempt = DateTime.now();
    _setTrackerSyncPhase(TrackerSyncPhase.fetching);
    // Quiet for the heavy apply — phase updates pierce via
    // [_setTrackerSyncPhase]; shelf/data notifies once after each batch stage.
    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    var syncableDirty = false;
    var ok = true;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart(TrackerSources.simkl, force: force);
    try {
      // Always activities first — never unconditional library pulls.
      final activities = await _simkl.getActivities(simkl);
      final prev = _simklActivities;
      final watchingChanged = force || !activities.watchingUnchanged(prev);
      final planChanged = force || !activities.planToWatchUnchanged(prev);
      final playbackChanged = force || !activities.playbackUnchanged(prev);
      final statusChanged = force || !activities.statusBucketsUnchanged(prev);

      SimklMatchIndex? index;
      if (watchingChanged ||
          planChanged ||
          playbackChanged ||
          statusChanged ||
          force) {
        index = await _ensureTrackerMatchIndex();
      }

      List<SimklLibraryItem> watchingRows = const [];
      if (watchingChanged) {
        watchingRows = await _simkl.getWatching(simkl);
        await Future<void>.delayed(Duration.zero);
        _setTrackerSyncPhase(TrackerSyncPhase.matching);
        // Phase 1: local catalog/VOD match only — apply quietly; Home paints
        // once after finally (idle notify).
        final prevWatching = simklWatching;
        var nextWatching = await resolveSimklWatchingItemsAsync(
          watchingRows,
          catalog: catalog,
          history: history,
          watchlist: watchlist,
          extra: _vodStreamCache.values,
          index: index,
        );
        // SQLite FTS — Xtream / packed catalogs are not in the RAM index.
        nextWatching = await _relinkTrackerShellsViaVodFts(
          nextWatching,
          isShell: isSimklWatchingShell,
        );
        final shelfChanged = _watchingShelfChanged(prevWatching, nextWatching);
        if (shelfChanged) {
          simklWatching = nextWatching;
          await _store.saveSimklWatching(simklWatching);
        }
        TrackerLog.shelf(
          TrackerSources.simkl,
          'watching',
          count: nextWatching.length,
          changed: shelfChanged,
        );
        // Unchanged content: keep prior list identity so Home stamp stays put.
      }

      if (planChanged) {
        final planRows = await _simkl.getPlanToWatch(simkl);
        await Future<void>.delayed(Duration.zero);
        _setTrackerSyncPhase(TrackerSyncPhase.matching);
        var nextPlan = await resolveSimklPlanToWatchItemsAsync(
          planRows,
          catalog: catalog,
          history: history,
          watchlist: watchlist,
          extra: _vodStreamCache.values,
          index: index,
        );
        nextPlan = await _relinkTrackerShellsViaVodFts(
          nextPlan,
          isShell: isSimklPlanShell,
        );
        simklPlanToWatch = nextPlan;
        await _store.saveSimklPlanToWatch(simklPlanToWatch);
        TrackerLog.shelf(
          TrackerSources.simkl,
          'plan',
          count: simklPlanToWatch.length,
        );
        // Plan shelf is My List only — defer notify to the end.
      }

      if (statusChanged || playbackChanged || watchingChanged || force) {
        _setTrackerSyncPhase(TrackerSyncPhase.merging);
        final mergeDirty = await _mergeSimklInboundStatuses(
          force: force,
          statusChanged: statusChanged,
          playbackChanged: playbackChanged || force,
          watchingRows: watchingChanged ? watchingRows : null,
          index: index,
          noteSyncable: false,
        );
        if (mergeDirty) syncableDirty = true;
      }

      _simklActivities = activities;
      _simklSyncDateFrom = activities.dateFromStamp ?? _simklSyncDateFrom;
      simklLastSyncAt = DateTime.now();
      await _store.saveSimklActivities(activities);
      await _store.saveSimklSyncDateFrom(_simklSyncDateFrom);
      await _store.saveSimklLastSyncAt(simklLastSyncAt!);
      if (syncableDirty) _noteSyncableChange();
    } catch (_) {
      ok = false;
      // Keep last good cache; never block the UI.
    } finally {
      _simklSyncing = false;
      _trackerSyncPhase = null;
      _uiQuiet = wasQuiet;
      TrackerLog.syncEnd(
        TrackerSources.simkl,
        ms: watch.elapsedMilliseconds,
        ok: ok,
      );
      // Idle — Settings clears Syncing…; Home stamp ignores isSimklSyncing and
      // only rematerializes when [simklWatchingShelfStamp] actually changed.
      _notifyListenersAfterIdle();
    }

    // Phase 2 runs after the sync flag clears so Home/Settings aren't stuck
    // on "Syncing…" while custom-catalog searches crawl.
    if (_appForeground) {
      if (simklWatching.any(isSimklWatchingShell)) {
        unawaited(_scheduleSimklRemoteShellLink(simklWatching));
      }
      if (simklPlanToWatch.any(isSimklPlanShell)) {
        unawaited(_scheduleSimklRemoteShellLink(simklPlanToWatch, plan: true));
      }
    }
  }

  /// Queue remote `/search` linking for leftover Simkl shells (custom catalogs).
  Future<void> _scheduleSimklRemoteShellLink(
    List<MediaItem> current, {
    bool plan = false,
  }) {
    final hasCustom = sources.any(
      (s) =>
          s.type == IptvSourceType.custom &&
          (s.playlistUrl ?? '').trim().isNotEmpty,
    );
    if (!hasCustom || !_appForeground) return Future<void>.value();
    final isShell = plan ? isSimklPlanShell : isSimklWatchingShell;
    if (!current.any(isShell)) return Future<void>.value();
    final shells = List<MediaItem>.from(current);
    return _bgQueue.enqueue(
      id: plan ? 'simkl-plan-anya-link' : 'simkl-anya-link',
      priority: BackgroundPriority.normal,
      action: () async {
        if (!_appForeground) return;
        final linkQuiet = _uiQuiet;
        _uiQuiet = true;
        var shelfChanged = false;
        try {
          final linked = await _linkSimklShellsViaRemoteSearch(
            shells,
            [
              for (final m in shells)
                if (isShell(m))
                  SimklLibraryItem(
                    title: m.title,
                    isShow: m.isSeries,
                    ids: SimklIds(
                      simkl: m.simklId,
                      tmdb: m.tmdbId,
                      imdb: m.imdbId,
                      tvdb: m.tvdbId,
                      anilist: m.anilistId,
                    ),
                    year: m.year,
                    posterUrl: m.posterUrl,
                    lastWatchedAt: m.lastWatchedAt,
                    status: plan ? 'plantowatch' : 'watching',
                  ),
            ],
            isShell: isShell,
            planTag: plan,
          );
          if (!_appForeground || !_watchingShelfChanged(shells, linked)) {
            return;
          }
          if (plan) {
            simklPlanToWatch = linked;
            await _store.saveSimklPlanToWatch(simklPlanToWatch);
          } else {
            simklWatching = linked;
            await _store.saveSimklWatching(simklWatching);
          }
          shelfChanged = true;
        } catch (_) {
        } finally {
          _uiQuiet = linkQuiet;
          if (shelfChanged && !_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }

  /// After catalog/VOD hydrate, swap Simkl shells for local playable rows.
  ///
  /// Local match + SQLite FTS only. Remote custom catalog search stays in
  /// [syncSimklActivity] so progressive catalog-growth relinks never re-queue
  /// network `/search` while Xtream is still filling SQLite.
  ///
  /// Post-hydrate callers pass [BackgroundPriority.low] so the ~200k
  /// match-index rebuild does not contend with Accueil settle.
  Future<void> _relinkSimklWatching({
    BackgroundPriority priority = BackgroundPriority.normal,
  }) {
    if (simklWatching.isEmpty) {
      JavpLog.i('bg', 'simkl-relink skip empty priority=${priority.name}');
      return Future<void>.value();
    }
    JavpLog.i(
      'bg',
      'simkl-relink queued priority=${priority.name} '
          'n=${simklWatching.length} queue=${_bgQueue.pendingCount}',
    );
    return _bgQueue.enqueue(
      id: 'simkl-relink',
      priority: priority,
      action: () async {
        if (simklWatching.isEmpty) return;
        if (priority == BackgroundPriority.low &&
            (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork)) {
          JavpLog.i(
            'bg',
            'simkl-relink deferred priority=low '
                'allowIdle=$_allowIdleBackgroundWork '
                'shouldDefer=${_bgQueue.shouldDeferIdleWork}',
          );
          return;
        }
        final watch = Stopwatch()..start();
        JavpLog.i(
          'bg',
          'simkl-relink start priority=${priority.name} '
              'n=${simklWatching.length} queue=${_bgQueue.pendingCount}',
        );
        final wasQuiet = _uiQuiet;
        _uiQuiet = true;
        try {
          final index = await _ensureTrackerMatchIndex();
          var linked = await relinkSimklWatchingItemsAsync(
            simklWatching,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            index: index,
          );
          // SQLite FTS covers Xtream rows that never entered the RAM index.
          linked = await _relinkTrackerShellsViaVodFts(
            linked,
            isShell: isSimklWatchingShell,
          );
          if (identical(linked, simklWatching)) {
            JavpLog.i(
              'bg',
              'simkl-relink done unchanged in ${watch.elapsedMilliseconds}ms',
            );
            return;
          }
          if (!_watchingShelfChanged(simklWatching, linked)) {
            JavpLog.i(
              'bg',
              'simkl-relink done no-shelf-change '
                  'in ${watch.elapsedMilliseconds}ms',
            );
            return;
          }
          simklWatching = linked;
          await _store.saveSimklWatching(simklWatching);
          JavpLog.i(
            'bg',
            'simkl-relink done updated in ${watch.elapsedMilliseconds}ms '
                'n=${simklWatching.length}',
          );
        } finally {
          _uiQuiet = wasQuiet;
          if (!_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }

  Future<void> _relinkSimklPlanToWatch({
    BackgroundPriority priority = BackgroundPriority.normal,
  }) {
    if (simklPlanToWatch.isEmpty) return Future<void>.value();
    return _bgQueue.enqueue(
      id: 'simkl-plan-relink',
      priority: priority,
      action: () async {
        if (simklPlanToWatch.isEmpty) return;
        if (priority == BackgroundPriority.low &&
            (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork)) {
          return;
        }
        final wasQuiet = _uiQuiet;
        _uiQuiet = true;
        try {
          final index = await _ensureTrackerMatchIndex();
          var linked = await relinkSimklPlanItemsAsync(
            simklPlanToWatch,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            index: index,
          );
          linked = await _relinkTrackerShellsViaVodFts(
            linked,
            isShell: isSimklPlanShell,
          );
          if (identical(linked, simklPlanToWatch)) return;
          if (!_watchingShelfChanged(simklPlanToWatch, linked)) return;
          simklPlanToWatch = linked;
          await _store.saveSimklPlanToWatch(simklPlanToWatch);
        } finally {
          _uiQuiet = wasQuiet;
          if (!_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }

  Future<List<MediaItem>> _linkSimklShellsViaRemoteSearch(
    List<MediaItem> resolved,
    List<SimklLibraryItem> rows, {
    bool Function(MediaItem)? isShell,
    bool planTag = false,
  }) async {
    if (!_appForeground) return resolved;
    final hasCustom = sources.any(
      (s) =>
          s.type == IptvSourceType.custom &&
          (s.playlistUrl ?? '').trim().isNotEmpty,
    );
    if (!hasCustom) return resolved;

    final shellOf = isShell ?? isSimklWatchingShell;
    final rowByTitle = {for (final r in rows) r.title.trim().toLowerCase(): r};
    final out = <MediaItem>[];
    var searches = 0;
    var catalogTouched = false;
    // Cap network round-trips — still high enough to cover a full Watching
    // shelf. Each search yields so Accueil keeps frames.
    const maxSearches = 48;

    for (final item in resolved) {
      if (!_appForeground) {
        out.addAll(resolved.skip(out.length));
        break;
      }
      if (!shellOf(item) || searches >= maxSearches) {
        out.add(item);
        continue;
      }
      searches++;
      // Let frames paint between custom catalog lookups.
      await Future<void>.delayed(Duration.zero);
      try {
        final hits = await searchRemoteCatalogs(
          item.title,
          limit: 8,
          persist: false,
          notify: false,
          touchVod: false,
        );
        if (hits.isEmpty) {
          out.add(item);
          continue;
        }
        catalogTouched = true;
        final row = rowByTitle[item.title.trim().toLowerCase()];
        final ids = SimklIds(
          simkl: item.simklId ?? row?.ids.simkl,
          tmdb: item.tmdbId ?? row?.ids.tmdb,
          imdb: item.imdbId ?? row?.ids.imdb,
          tvdb: item.tvdbId ?? row?.ids.tvdb,
          anilist: item.anilistId ?? row?.ids.anilist,
        );
        final matched =
            matchSimklIdsToLocal(
              ids,
              catalog: hits,
              history: const [],
              watchlist: const [],
              title: item.title,
              year: item.year ?? row?.year,
            ) ??
            hits.cast<MediaItem?>().firstWhere(
              (h) =>
                  h != null &&
                  !h.isLive &&
                  !h.isEpisode &&
                  // Series shells must link to series rows — not a random VOD
                  // (or episode-shaped) hit from a flat catalog dump.
                  (item.isSeries ? h.isSeries : true),
              orElse: () => null,
            );
        if (matched == null || matched.isEpisode) {
          out.add(item);
          continue;
        }
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
            tags: planTag
                ? [
                    ...matched.tags.where((t) => t != 'simkl-plantowatch'),
                    'simkl-plantowatch',
                  ]
                : matched.tags,
          ),
        );
      } catch (_) {
        out.add(item);
      }
    }
    // One VOD stamp + write-behind flush for the whole catalog batch.
    if (catalogTouched) {
      _touchVodCache();
      _schedulePersist(_PersistTarget.catalog);
    }
    return out;
  }

  /// Returns true when history/catalog/statuses were dirtied (caller may note
  /// syncable once at the end of the wave).
  Future<bool> _mergeSimklInboundStatuses({
    required bool force,
    required bool statusChanged,
    required bool playbackChanged,
    List<SimklLibraryItem>? watchingRows,
    SimklMatchIndex? index,
    bool noteSyncable = true,
  }) async {
    if (!simkl.isAuthenticated) return false;
    var dirty = false;
    try {
      final watching =
          watchingRows ??
          (statusChanged || force ? await _simkl.getWatching(simkl) : const []);
      final dropped = (statusChanged || force)
          ? await _simkl.getDropped(simkl)
          : const <SimklLibraryItem>[];
      final completed = (statusChanged || force)
          ? await _simkl.getCompleted(simkl)
          : const <SimklLibraryItem>[];
      final hold = (statusChanged || force)
          ? await _simkl.getHold(simkl)
          : const <SimklLibraryItem>[];
      final playbacks = (playbackChanged || force)
          ? await _simkl.getPlaybacks(simkl)
          : const <SimklPlayback>[];

      // When only playbacks moved, still refresh SIMKL rows that carry playheads.
      final incoming = TrackerImportMapper.fromSimklStatusLists(
        watching: watching,
        dropped: dropped,
        completed: completed,
        hold: hold,
        playbacks: playbacks,
      );
      if (statusChanged || force || playbacks.isNotEmpty) {
        // Full SIMKL replace when status buckets changed; otherwise merge
        // playbacks onto existing SIMKL rows without wiping dropped/hold.
        if (statusChanged || force) {
          trackerStatuses = mergeTrackerStatuses(
            trackerStatuses,
            incoming,
            replaceSource: TrackerSources.simkl,
          );
        } else {
          trackerStatuses = mergeTrackerStatuses(trackerStatuses, incoming);
        }
        await _store.saveTrackerStatuses(trackerStatuses);
        _cachedContinueWatching = null;
        _continueWatchingStamp = -1;
        _cachedRecommendations = null;
        _recommendationsStamp = -1;
        dirty = true;
        if (noteSyncable) _noteSyncableChange();
      }

      if (await _applyTrackerProgressEntries(
        incoming,
        index: index,
        noteSyncable: noteSyncable,
        logSource: TrackerSources.simkl,
      )) {
        dirty = true;
      }
    } catch (_) {
      // Fail soft — keep last good statuses / history.
    }
    return dirty;
  }

  /// PIN auth uses a direct (non-proxy) client — IPTV proxies often break
  /// DNS/TLS to Cloudflare (api.simkl.com) even when streams still work.
  Future<SimklPinSession> requestSimklPin(String clientId) async {
    final id = clientId.trim().isEmpty
        ? SimklCredentials.bundledClientId
        : clientId.trim();
    final direct = SimklClient();
    try {
      return await direct.requestPin(id);
    } on Object catch (e) {
      throw Exception(_simklNetworkError(e));
    } finally {
      direct.close();
    }
  }

  Future<String> waitForSimklPinToken({
    required String clientId,
    required SimklPinSession session,
    required bool Function() isCancelled,
  }) async {
    final id = clientId.trim().isEmpty
        ? SimklCredentials.bundledClientId
        : clientId.trim();
    final direct = SimklClient();
    try {
      return await direct.waitForPinToken(
        clientId: id,
        session: session,
        isCancelled: isCancelled,
      );
    } on Object catch (e) {
      final message = e.toString();
      if (message.contains('cancelled') || message.contains('expired')) {
        rethrow;
      }
      throw Exception(_simklNetworkError(e));
    } finally {
      direct.close();
    }
  }

  String _simklNetworkError(Object e) {
    final raw = e.toString();
    final host = RegExp(r"host lookup: '([^']+)'").firstMatch(raw)?.group(1);
    if (raw.contains('Failed host lookup') ||
        raw.contains('No address associated with hostname') ||
        raw.contains('Failed to resolve')) {
      final where = host == null ? 'SIMKL' : host;
      return 'Could not resolve $where. Check internet / DNS '
          '(Settings → Network: turn off a broken proxy if enabled).';
    }
    if (raw.contains('SocketException') || raw.contains('ClientException')) {
      return 'Could not reach SIMKL. Check internet'
          '${proxy.isActive ? ' or disable proxy (${proxy.displayLabel})' : ''}.';
    }
    return raw.replaceFirst('Exception: ', '');
  }

  Future<void> _maybeScrobble(MediaItem item, {bool force = false}) async {
    if (!simkl.isAuthenticated ||
        !metadataSettings.simklScrobbleEnabled ||
        item.isLive ||
        item.kind == MediaKind.catchup) {
      if (force &&
          simkl.isAuthenticated &&
          !metadataSettings.simklScrobbleEnabled &&
          !item.isLive &&
          item.kind != MediaKind.catchup) {
        TrackerLog.scrobble(
          TrackerSources.simkl,
          outcome: 'skip',
          title: item.title,
          id: TrackerLog.mediaId(
            tmdbId: item.tmdbId,
            imdbId: item.imdbId,
            tvdbId: item.tvdbId,
            anilistId: item.anilistId,
            simklId: item.simklId,
          ),
          season: item.seasonNumber,
          episode: item.episodeNumber,
          progress: item.progress,
          detail: 'reason=disabled',
        );
      }
      return;
    }

    // Simkl `/sync/history` has no playhead — only Watching membership and
    // watched marks. Skip mid-title spam (and never nest episodes early).
    final isShow = _simklIsShow(item);
    final completed = item.progress >= 0.9;
    if (!completed) {
      // Movies: Simkl rewrites movie "watching" → completed, so mid-play
      // history posts would mark the film watched. Shows: one Watching ping.
      if (!isShow || item.progress <= 0) return;
    }

    final status = completed
        ? SimklWatchStatus.completed
        : SimklWatchStatus.watching;
    final key = completed
        ? '${item.id}:completed'
        : '${_simklShowScrobbleKey(item)}:watching';
    // Watching is once-per-show. Completed may re-send when force (manual mark).
    if (_simklScrobbleSentKeys.contains(key) &&
        (!force || status != SimklWatchStatus.completed)) {
      return;
    }

    // Watching = status only (no episode). Completed = nest episode when known.
    final event = SimklScrobbleEvent(
      title: isShow ? _simklShowTitle(item) : item.title,
      progress: item.progress,
      status: status,
      year: item.year,
      simklId: item.simklId,
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
      seasonNumber: completed ? item.seasonNumber : null,
      episodeNumber: completed ? item.episodeNumber : null,
      isShow: isShow,
    );
    final id = TrackerLog.mediaId(
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
      anilistId: item.anilistId,
      simklId: item.simklId,
    );

    if (!await _hasNetworkConnectivity()) {
      await _enqueuePendingSimklScrobble(item.id, event);
      _simklScrobbleSentKeys.add(key);
      TrackerLog.scrobble(
        TrackerSources.simkl,
        outcome: 'queued',
        title: event.title,
        id: id,
        season: completed ? item.seasonNumber : null,
        episode: completed ? item.episodeNumber : null,
        progress: item.progress,
        detail: completed ? 'reason=offline' : 'reason=offline phase=watching',
      );
      return;
    }

    try {
      await _simkl.scrobble(simkl, event);
      _simklScrobbleSentKeys.add(key);
      TrackerLog.scrobble(
        TrackerSources.simkl,
        outcome: 'success',
        title: event.title,
        id: id,
        season: completed ? item.seasonNumber : null,
        episode: completed ? item.episodeNumber : null,
        progress: item.progress,
        detail: completed ? null : 'phase=watching',
      );
    } catch (_) {
      // Queue for later — never block playback.
      await _enqueuePendingSimklScrobble(item.id, event);
      _simklScrobbleSentKeys.add(key);
      TrackerLog.scrobble(
        TrackerSources.simkl,
        outcome: 'fail',
        title: event.title,
        id: id,
        season: completed ? item.seasonNumber : null,
        episode: completed ? item.episodeNumber : null,
        progress: item.progress,
        detail: 'queued',
      );
    }
  }

  /// Stable show identity so E02 does not re-send Watching after E01.
  String _simklShowScrobbleKey(MediaItem item) {
    final simkl = item.simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) return 'simkl:$simkl';
    if (item.tmdbId != null && item.tmdbId! > 0) return 'tmdb:${item.tmdbId}';
    if (item.tvdbId != null && item.tvdbId! > 0) return 'tvdb:${item.tvdbId}';
    if (item.anilistId != null && item.anilistId! > 0) {
      return 'al:${item.anilistId}';
    }
    final seriesId = item.seriesId?.trim();
    if (seriesId != null && seriesId.isNotEmpty) return 'series:$seriesId';
    return 'title:${_simklShowTitle(item).toLowerCase()}';
  }

  Future<void> _enqueuePendingSimklScrobble(
    String mediaId,
    SimklScrobbleEvent event,
  ) async {
    if (mediaId.isEmpty) return;
    final existing = _pendingSimklScrobbles.indexWhere(
      (p) => p.mediaId == mediaId,
    );
    final next = PendingSimklScrobble(
      mediaId: mediaId,
      event: event,
      queuedAt: DateTime.now(),
    );
    if (existing >= 0) {
      final prev = _pendingSimklScrobbles[existing];
      // Keep the furthest progress / completed status for the same title.
      if (event.progress < prev.event.progress &&
          event.status != SimklWatchStatus.completed) {
        return;
      }
      _pendingSimklScrobbles[existing] = next;
    } else {
      _pendingSimklScrobbles.add(next);
      // Cap queue so a long offline binge can't grow forever.
      if (_pendingSimklScrobbles.length > 200) {
        _pendingSimklScrobbles.removeRange(
          0,
          _pendingSimklScrobbles.length - 200,
        );
      }
    }
    await _store.savePendingSimklScrobbles(_pendingSimklScrobbles);
  }

  Future<void> _flushPendingSimklScrobbles() async {
    if (_flushingSimklScrobbles) return;
    if (_pendingSimklScrobbles.isEmpty) return;
    if (!simkl.isAuthenticated || !metadataSettings.simklScrobbleEnabled) {
      return;
    }
    if (!await _hasNetworkConnectivity()) return;

    _flushingSimklScrobbles = true;
    try {
      final remaining = <PendingSimklScrobble>[];
      var sent = 0;
      for (final pending in List<PendingSimklScrobble>.from(
        _pendingSimklScrobbles,
      )) {
        if (!await _hasNetworkConnectivity()) {
          remaining.add(pending);
          continue;
        }
        try {
          await _simkl.scrobble(simkl, pending.event);
          sent++;
        } catch (_) {
          remaining.add(pending);
        }
      }
      _pendingSimklScrobbles
        ..clear()
        ..addAll(remaining);
      await _store.savePendingSimklScrobbles(_pendingSimklScrobbles);
      if (sent > 0 || remaining.isNotEmpty) {
        TrackerLog.scrobbleFlush(
          TrackerSources.simkl,
          sent: sent,
          remaining: remaining.length,
        );
      }
    } finally {
      _flushingSimklScrobbles = false;
    }
  }

  /// TMDB movie/TV ids share numeric space — pick show when episode/series cues exist.
  bool _simklIsShow(MediaItem item) {
    if (item.kind == MediaKind.series) return true;
    if (item.seasonNumber != null || item.episodeNumber != null) return true;
    if (item.seriesId != null && item.seriesId!.isNotEmpty) return true;
    final detailsId = item.detailsId ?? '';
    if (detailsId.startsWith('tmdb-tv-')) return true;
    if (detailsId.startsWith('tmdb-movie-')) return false;
    return false;
  }

  /// Episode rows use episode title; Simkl needs the series name for fuzzy match.
  String _simklShowTitle(MediaItem item) {
    final sub = item.subtitle?.trim();
    if (sub != null && sub.contains(' · ')) {
      final series = sub.split(' · ').first.trim();
      if (series.isNotEmpty) return series;
    }
    return item.title;
  }
}
