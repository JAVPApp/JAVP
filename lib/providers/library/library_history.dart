part of '../library_provider.dart';

extension LibraryHistory on LibraryProvider {
  /// Writes everything marked dirty. Safe to call at any time.
  Future<void> flushPendingWrites() async {
    _writeBehindTimer?.cancel();
    _writeBehindTimer = null;
    _softPersistTimer?.cancel();
    _softPersistTimer = null;
    if (_catalogProgressDirty) {
      // Catalog encode is IPTV-scale. Doing it mid-play (auto-sync flush)
      // is `phase=compute` and freezes the player. Leave it dirty.
      if (!_playbackActive) {
        _catalogProgressDirty = false;
        _pendingWrites.add(_PersistTarget.catalog);
      }
    }
    if (_pendingWrites.isEmpty) {
      await _persistHomeShelfSnapshotNow();
      return;
    }
    final targets = _pendingWrites.toList();
    _pendingWrites.clear();
    for (final target in targets) {
      try {
        switch (target) {
          case _PersistTarget.catalog:
            if (_playbackActive) {
              _catalogProgressDirty = true;
              continue;
            }
            await _store.saveCatalog(catalog);
          case _PersistTarget.localMedia:
            await _persistLocalMediaNow(localMedia);
          case _PersistTarget.history:
            await _persistHistoryNow(history);
          case _PersistTarget.detailsCache:
            await _store.saveDetailsCache(detailsCache);
          case _PersistTarget.segmentCache:
            await _store.saveSegmentCache(segmentCache);
          case _PersistTarget.vodCache:
            await _persistVodCache();
        }
      } catch (_) {
        // A failed write retries on the next dirty mark.
      }
    }
    if (targets.contains(_PersistTarget.history)) {
      _noteSyncableChange();
    }
    await _persistHomeShelfSnapshotNow();
  }

  /// On-device watch history, newest first. Independent of SIMKL/other trackers.
  List<MediaItem> get recentHistory => List.unmodifiable(history);

  /// Records that playback started. Works for Live, VOD, local, and URLs.
  /// Always stored on-device; SIMKL is optional and separate.
  ///
  /// This is the structural "opened this title" path (once per session). The
  /// periodic resume-point path is [recordProgress], which must stay cheap
  /// enough that it never stalls the UI / playback isolate.
  Future<void> recordWatch(
    MediaItem item, {
    double? progress,
    Duration? duration,
  }) async {
    final updated = item.copyWith(
      progress: (progress ?? item.progress).clamp(0.0, 1.0),
      lastWatchedAt: DateTime.now(),
      duration: duration ?? item.duration,
    );

    // Patch catalog in place when present so Home tiles can show progress.
    // Do not schedule a catalog rewrite from the watch path — that re-encodes
    // the whole library and must wait for [flushPendingWrites] (background).
    final catalogIndex = catalog.indexWhere((m) => m.id == item.id);
    if (catalogIndex >= 0) {
      catalog[catalogIndex] = updated;
      _catalogProgressDirty = true;
    }

    _patchLocalMediaProgress(updated);
    _upsertHistory(updated);
    // Watching again after a remove cancels the sync tombstone.
    await _clearHistoryTombstone(item.id, playUrl: item.playUrl);

    // Keep download-task metadata in sync so offline resumes keep progress.
    _downloads.syncItemProgress(
      item,
      progress: updated.progress,
      duration: updated.duration,
    );

    _schedulePersist(_PersistTarget.history);
    if (item.isLive || item.kind == MediaKind.catchup) {
      await recordChannelVisit(item);
    } else {
      _notifyWatchProgress(updated, structural: true);
    }
  }

  /// After an episode finishes, keep the series on Continue watching by
  /// queuing [next] at progress 0 (no scrub bar) until the user starts it.
  Future<void> seedContinueWatchingNext(MediaItem next) async {
    if (!next.isEpisode) return;
    for (final h in history) {
      if (h.id != next.id) continue;
      // Already mid-episode or finished — don't clobber.
      if (h.progress > 0.02) return;
      break;
    }
    final tags = [
      ...next.tags.where((t) => t != LocalRecommender.continueUpNextTag),
      LocalRecommender.continueUpNextTag,
    ];
    final seeded = next.copyWith(
      progress: 0,
      lastWatchedAt: DateTime.now(),
      tags: tags,
    );
    _upsertHistory(seeded);
    await _clearHistoryTombstone(next.id, playUrl: next.playUrl);
    _continueWatchingStamp = -1;
    _schedulePersist(_PersistTarget.history);
    _notifyWatchProgress(seeded, structural: true);
  }

  /// Periodic resume-point update (~every 5s while playing).
  ///
  /// Must not scan/rewrite the catalog, touch prefs tombstones, or await
  /// network — those hitch the UI isolate and freeze playback. Resume lives
  /// in [history] (+ local media when present); both are soft write-behind
  /// (≈45s, or flush on pause/stop/background). SIMKL is throttled separately.
  Future<void> recordProgress(
    MediaItem item,
    double progress, {
    Duration? duration,
    bool forceScrobble = false,
  }) async {
    final clamped = progress.clamp(0.0, 1.0);
    // Real watch progress clears the synthetic "up next" marker.
    final tags = clamped > 0.02
        ? item.tags
              .where((t) => t != LocalRecommender.continueUpNextTag)
              .toList(growable: false)
        : item.tags;
    final updated = item.copyWith(
      progress: clamped,
      lastWatchedAt: DateTime.now(),
      duration: duration ?? item.duration,
      tags: tags,
    );

    _patchLocalMediaProgress(updated, softPersist: true);
    _upsertHistory(updated);
    _downloads.syncItemProgress(
      item,
      progress: updated.progress,
      duration: updated.duration,
      notify: false,
    );
    _scheduleSoftPersist(_PersistTarget.history);
    _notifyWatchProgress(updated);
    unawaited(_maybeScrobble(updated, force: forceScrobble));
    unawaited(_maybeScrobbleSerializd(updated, force: forceScrobble));
  }

  Future<void> removeFromHistory(String id) async {
    MediaItem? target;
    for (final h in history) {
      if (h.id == id) {
        target = h;
        break;
      }
    }
    // Align with Library Retirer: same pasted URL under another title must not
    // linger (or come back via Drive) after the user clears one history row.
    final removeIds = <String>{id};
    final playUrl = target?.playUrl.trim() ?? '';
    if (target != null &&
        LibraryProvider._isUserOwnedLibraryOrigin(target) &&
        playUrl.isNotEmpty) {
      for (final h in history) {
        if (!LibraryProvider._isUserOwnedLibraryOrigin(h)) continue;
        if (h.playUrl.trim() == playUrl) removeIds.add(h.id);
      }
    }

    _historyEpoch++;
    _cancelPendingHistoryPersist();
    history = history.where((m) => !removeIds.contains(m.id)).toList();
    // Notify before disk I/O — awaiting SharedPreferences on desktop made the
    // Continue Watching shelf feel stuck. Drop quiet-mode so prefetch/sync
    // can't latch and swallow this user-facing update (see removeSource).
    _uiQuiet = false;
    _watchProgressNotifyTimer?.cancel();
    _watchProgressNotifyTimer = null;
    _lastWatchNotifyKey = null;
    _cachedContinueWatching = null;
    _continueWatchingStamp = -1;
    watchHistoryRevision++;
    notifyListeners();
    await _persistHistoryNow(history);
    await _tombstoneHistoryIds(
      removeIds,
      playUrls: playUrl.isEmpty ? const <String>[] : <String>[playUrl],
    );
    _noteSyncableChange();
  }

  /// Drop a continue-watching card (series-aware: clears in-progress episode rows).
  Future<void> removeFromContinueWatching(MediaItem item) async {
    final before = history;
    var next = history;
    if (item.isSeries ||
        (item.seriesId != null && item.seriesId!.trim().isNotEmpty)) {
      next = history.where((h) {
        if (!_historyBelongsToSeries(h, item)) return true;
        // Only the in-progress / up-next rows that feed the continue-watching shelf.
        if (LocalRecommender.isContinueWatchingCandidate(h)) return false;
        return true;
      }).toList();
    } else if (_isVodMovieWatchItem(item)) {
      next = history.where((h) {
        if (!_sameMovieWatchFamily(h, item)) return true;
        if (LocalRecommender.isContinueWatchingCandidate(h)) return false;
        return true;
      }).toList();
    }
    if (next.length == before.length) {
      next = history.where((m) => m.id != item.id).toList();
    }
    if (next.length == before.length) return;
    final removed = [
      for (final h in before)
        if (!next.any((m) => m.id == h.id)) h,
    ];
    final removedIds = {for (final h in removed) h.id};
    final removedUrls = {
      for (final h in removed)
        if (LibraryProvider._isUserOwnedLibraryOrigin(h) &&
            h.playUrl.trim().isNotEmpty)
          h.playUrl.trim(),
    };
    history = next;
    _historyEpoch++;
    _cancelPendingHistoryPersist();
    _uiQuiet = false;
    _watchProgressNotifyTimer?.cancel();
    _watchProgressNotifyTimer = null;
    _lastWatchNotifyKey = null;
    _cachedContinueWatching = null;
    _continueWatchingStamp = -1;
    watchHistoryRevision++;
    notifyListeners();
    await _persistHistoryNow(history);
    await _tombstoneHistoryIds(removedIds, playUrls: removedUrls);
    _noteSyncableChange();
  }

  Future<void> clearHistory() async {
    _historyEpoch++;
    _cancelPendingHistoryPersist();
    history = [];
    _historyDeleted = {};
    _uiQuiet = false;
    watchHistoryRevision++;
    notifyListeners();
    await _persistHistoryNow(history);
    await _store.saveHistoryDeleted({});
    _noteSyncableChange();
  }
}
