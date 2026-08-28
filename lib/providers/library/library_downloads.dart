part of '../library_provider.dart';

extension LibraryDownloads on LibraryProvider {
  /// Completed downloads available offline (excludes imported / opened local files).
  List<MediaItem> get offlineLibraryItems {
    final seen = <String>{};
    final out = <MediaItem>[];
    void add(MediaItem item) {
      if (!seen.add(item.id)) return;
      final path = item.playUrl.trim();
      if (path.isEmpty) return;
      if (path.startsWith('http://') ||
          path.startsWith('https://') ||
          looksLikeTorrentPlayUrl(path)) {
        return;
      }
      out.add(item);
    }

    for (final item in _downloads.completedItems) {
      add(item);
    }
    // Mirrored download rows in localMedia (imports / open-with stay on Library).
    for (final item in localMedia) {
      if (item.origin == MediaOrigin.download) {
        add(item);
      }
    }
    return out;
  }

  /// Series shells (deduped) that have at least one downloaded episode.
  ///
  /// Each episode is mapped to its parent series shell via
  /// [seriesShellForEpisode], so a show with a whole season offline appears
  /// once rather than as one row per episode. Order follows first episode seen.
  List<MediaItem> get downloadedSeriesItems {
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final item in offlineLibraryItems) {
      if (!item.isEpisode) continue;
      final shell = seriesShellForEpisode(item);
      if (shell == null) continue;
      if (!seen.add(seriesKeyFor(shell))) continue;
      out.add(shell);
    }
    return out;
  }

  /// Completed offline copy for [episode], if the file is still on disk.
  ///
  /// Matches the catalog stub after a restart (persisted downloads keep
  /// seriesId + S/E, not the original catalog item id).
  MediaItem? offlineItemForEpisode({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    final probe = MediaItem(
      id: episode.id,
      title: episode.title,
      playUrl: episode.playUrl ?? '',
      kind: MediaKind.vod,
      origin: series.origin,
      sourceId: series.sourceId,
      seriesId: series.streamId ?? series.seriesId ?? series.id,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNum,
    );
    final path = offlinePlayPathFor(probe);
    if (path != null) {
      final local = downloadTaskFor(probe)?.asLocalItem();
      if (local != null) return local;
      return MediaItem(
        id: probe.id,
        title: probe.title,
        playUrl: path,
        kind: MediaKind.local,
        origin: MediaOrigin.download,
        sourceId: probe.sourceId,
        seriesId: probe.seriesId,
        seasonNumber: probe.seasonNumber,
        episodeNumber: probe.episodeNumber,
      );
    }
    for (final item in downloadedEpisodesForSeries(series)) {
      if ((item.seasonNumber ?? 0) != episode.seasonNumber) continue;
      if ((item.episodeNumber ?? 0) != episode.episodeNum) continue;
      if (offlinePlayPathFor(item) != null) return item;
    }
    return null;
  }

  bool hasOfflineCopyForEpisode({
    required MediaItem series,
    required SeriesEpisode episode,
  }) => offlineItemForEpisode(series: series, episode: episode) != null;

  Future<bool> enqueueDownload(MediaItem item) async {
    try {
      _wireDownloadTorrentBridge();
      var url = item.playUrl;
      if (url.isEmpty || item.serverItemId != null) {
        url = await resolveServerStreamUrl(item) ?? url;
      } else if (item.origin == MediaOrigin.iptvXtream) {
        url = resolveXtreamStreamUrl(item);
      }
      if (!DownloadManager.isEligible(item, url)) return false;
      if (item.origin == MediaOrigin.torrent || looksLikeTorrentPlayUrl(url)) {
        final proceed = await maybePromptTorrentVpnTip();
        if (!proceed) return false;
      }
      // Progress notifications need POST_NOTIFICATIONS on Android 13+.
      unawaited(
        DownloadNotificationService.instance.requestPermissionsIfNeeded(),
      );
      await _downloads.enqueue(item: item, remoteUrl: url);
      await _persistDownloads();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> enqueueEpisodeDownloads(
    MediaItem series,
    Iterable<SeriesEpisode> episodes,
  ) async {
    var queued = 0;
    for (final ep in episodes) {
      final item =
          await ensureEpisodePlayable(series: series, episode: ep) ??
          episodeMediaItem(series: series, episode: ep);
      if (item == null || item.playUrl.trim().isEmpty) continue;
      final existing = _downloads.taskForItemId(item.id);
      if (existing != null && existing.status != DownloadStatus.failed) {
        continue;
      }
      if (await enqueueDownload(item)) queued++;
    }
    return queued;
  }

  Future<bool> enqueueCatchupDownload({
    required MediaItem channel,
    required EpgProgram program,
    Duration? padBefore,
    Duration? padAfter,
  }) async {
    final before = padBefore ?? downloadSettings.dvrPadBefore;
    final after = padAfter ?? downloadSettings.dvrPadAfter;
    final item = liveDvrItemForDownload(
      channel: channel,
      program: program,
      padBefore: before,
      padAfter: after,
    );
    if (item == null) return false;
    return enqueueDownload(item);
  }

  /// Queue offline-file deletion after a short grace period (and only online).
  ///
  /// Returns `true` if a deletion was scheduled (or already pending).
  Future<bool> scheduleRemoveDownloadAfterWatch(MediaItem item) async {
    if (!downloadSettings.removeAfterWatch) return false;
    if (_removeAfterWatchTriggered.contains(item.id)) return false;

    final task = _completedDownloadTaskFor(item);
    if (task == null) return false;

    final key = _removeScheduleKey(task, item);
    if (_removeAfterWatchTriggered.contains(key) ||
        _removeAfterWatchTriggered.contains(task.item.id)) {
      return false;
    }

    _scheduledRemoveAfterWatch[key]?.cancel();
    _scheduledRemoveItems[key] = item;
    if (_pendingRemoveWhenOnline.remove(key) != null) {
      unawaited(_persistPendingRemoveAfterWatch());
    }
    _scheduledRemoveAfterWatch[key] = Timer(
      LibraryProvider.removeAfterWatchGrace,
      () {
        unawaited(_runScheduledRemoveAfterWatch(key));
      },
    );
    return true;
  }

  /// Remove a user-owned library entry (stream URL, import, torrent, or download).
  ///
  /// Also drops matching watch-history / watchlist rows and writes history
  /// tombstones (by id + play URL) so Drive merge / soft-persist cannot
  /// resurrect the same pasted URL as a Films "URL" ghost. Remote catalogs
  /// that still offer the stream are left untouched.
  Future<void> removeOfflineLibraryItem(MediaItem item) async {
    // Drop quiet-mode so prefetch/sync can't swallow the Library list update
    // (same latch bug as [removeSource] / [removeFromHistory]).
    _uiQuiet = false;
    cancelScheduledRemoveDownload(item);
    final playUrl = item.playUrl.trim();
    final removeIds = <String>{item.id};

    bool sameOwnedStream(MediaItem other) {
      if (other.id == item.id) return true;
      if (!LibraryProvider._isUserOwnedLibraryOrigin(other)) return false;
      if (playUrl.isEmpty) return false;
      return other.playUrl.trim() == playUrl;
    }

    // Invalidate write-behind before any await so soft-persist cannot rewrite
    // a pre-Retirer localMedia/history snapshot after we persist [].
    _localMediaEpoch++;
    _cancelPendingLocalMediaPersist();
    _historyEpoch++;
    _cancelPendingHistoryPersist();

    final task =
        _completedDownloadTaskFor(item) ??
        _downloads.bestTaskFor(item, completedOnly: true);
    if (task != null) {
      removeIds.add(task.asLocalItem().id);
      removeIds.add(task.item.id);
    }

    localMedia = localMedia.where((m) => !sameOwnedStream(m)).toList();

    final historyBefore = history;
    history = history.where((h) => !sameOwnedStream(h)).toList();
    for (final h in historyBefore) {
      if (!history.any((m) => m.id == h.id)) removeIds.add(h.id);
    }
    final historyChanged = history.length != historyBefore.length;
    if (historyChanged) {
      _watchProgressNotifyTimer?.cancel();
      _watchProgressNotifyTimer = null;
      _lastWatchNotifyKey = null;
      _cachedContinueWatching = null;
      _continueWatchingStamp = -1;
    }

    final watchlistBefore = watchlist.length;
    watchlist = watchlist.where((w) => !sameOwnedStream(w)).toList();
    final watchlistChanged = watchlist.length != watchlistBefore;

    // Immediate UI refresh before disk I/O so the Library list doesn't feel stuck.
    _cachedRecommendations = null;
    _recommendationsStamp = -1;
    notifyListeners();

    if (task != null) {
      await _downloads.remove(task.id, deleteFile: true);
    } else if (item.origin == MediaOrigin.download && playUrl.isNotEmpty) {
      try {
        final f = File(item.playUrl);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    await _persistDownloads();
    await _persistLocalMediaNow(localMedia);
    await _persistHistoryNow(history);
    await _tombstoneHistoryIds(
      removeIds,
      playUrls: playUrl.isEmpty ? const <String>[] : <String>[playUrl],
    );
    if (watchlistChanged) {
      await _store.saveWatchlist(watchlist);
    }
    _noteSyncableChange();
    notifyListeners();
  }
}
