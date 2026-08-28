part of '../library_provider.dart';

/// Letterboxd tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncLetterboxd on LibraryProvider {
  /// Import official Letterboxd account export (ZIP) or a single CSV.
  ///
  /// Movies only — Letterboxd has no TV lists. No network scrape; user-provided
  /// export only (API remains partner-gated).
  Future<LetterboxdImportResult> importLetterboxdExport() async {
    if (_letterboxdImporting) {
      return const LetterboxdImportResult(error: 'busy');
    }
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['zip', 'csv'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) {
      return const LetterboxdImportResult(cancelled: true);
    }
    final file = picked.files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) {
      return const LetterboxdImportResult(error: 'empty');
    }
    return importLetterboxdExportBytes(bytes, fileNameHint: file.name);
  }

  Future<void> _relinkLetterboxdWatchlist({
    BackgroundPriority priority = BackgroundPriority.normal,
  }) {
    if (letterboxdWatchlist.isEmpty) return Future<void>.value();
    return _bgQueue.enqueue(
      id: 'letterboxd-watchlist-relink',
      priority: priority,
      action: () async {
        if (letterboxdWatchlist.isEmpty) return;
        if (priority == BackgroundPriority.low &&
            (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork)) {
          return;
        }
        final wasQuiet = _uiQuiet;
        _uiQuiet = true;
        try {
          final index = await _ensureTrackerMatchIndex();
          final linked = await relinkLetterboxdWatchlistItemsAsync(
            letterboxdWatchlist,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            index: index,
          );
          if (identical(linked, letterboxdWatchlist)) return;
          if (!_watchingShelfChanged(letterboxdWatchlist, linked)) return;
          letterboxdWatchlist = linked;
          await _store.saveLetterboxdWatchlist(letterboxdWatchlist);
        } finally {
          _uiQuiet = wasQuiet;
          if (!_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }

  bool get isLetterboxdImporting => _letterboxdImporting;

  bool get hasLetterboxdImport =>
      letterboxdWatchlist.isNotEmpty ||
      trackerStatuses.any((e) => e.source == 'letterboxd');

  Future<LetterboxdImportResult> importLetterboxdExportBytes(
    Uint8List bytes, {
    String? fileNameHint,
  }) async {
    if (_letterboxdImporting) {
      TrackerLog.syncSkip(TrackerSources.letterboxd, 'in-flight');
      return const LetterboxdImportResult(error: 'busy');
    }
    _letterboxdImporting = true;
    _setTrackerSyncPhase(TrackerSyncPhase.fetching);
    notifyListeners();
    var ok = true;
    String? endDetail;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart(TrackerSources.letterboxd, force: true);
    try {
      final data = parseLetterboxdExportBytes(
        bytes,
        fileNameHint: fileNameHint,
      );
      if (data.isEmpty) {
        ok = false;
        endDetail = 'empty';
        return const LetterboxdImportResult(error: 'empty');
      }
      final index = await _ensureTrackerMatchIndex();
      _setTrackerSyncPhase(TrackerSyncPhase.matching);
      final resolved = await resolveLetterboxdWatchlistItemsAsync(
        data.watchlist,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: _vodStreamCache.values,
        index: index,
      );
      letterboxdWatchlist = resolved;
      await _store.saveLetterboxdWatchlist(letterboxdWatchlist);
      TrackerLog.shelf(
        TrackerSources.letterboxd,
        'watchlist',
        count: letterboxdWatchlist.length,
      );

      _setTrackerSyncPhase(TrackerSyncPhase.merging);
      final lbStatuses = letterboxdStatusesFromExport(data);
      trackerStatuses = mergeTrackerStatuses(
        trackerStatuses,
        lbStatuses,
        replaceSource: 'letterboxd',
      );
      await _store.saveTrackerStatuses(trackerStatuses);
      final wasQuiet = _uiQuiet;
      _uiQuiet = true;
      try {
        await _applyTrackerProgressEntries(
          lbStatuses,
          index: index,
          logSource: TrackerSources.letterboxd,
        );
      } finally {
        _uiQuiet = wasQuiet;
      }

      letterboxdLastImportAt = DateTime.now();
      await _store.saveLetterboxdLastImportAt(letterboxdLastImportAt!);
      _cachedRecommendations = null;
      _recommendationsStamp = -1;
      _notifyListenersAfterIdle();
      return LetterboxdImportResult(
        watchlistCount: letterboxdWatchlist.length,
        completedCount: lbStatuses
            .where((e) => e.status == TrackerStatusKind.completed)
            .length,
      );
    } catch (_) {
      ok = false;
      endDetail = 'parse';
      return const LetterboxdImportResult(error: 'parse');
    } finally {
      _letterboxdImporting = false;
      _trackerSyncPhase = null;
      TrackerLog.syncEnd(
        TrackerSources.letterboxd,
        ms: watch.elapsedMilliseconds,
        ok: ok,
        detail: endDetail,
      );
      notifyListeners();
    }
  }

  Future<void> clearLetterboxdImport() async {
    letterboxdWatchlist = [];
    trackerStatuses = trackerStatuses
        .where((e) => e.source != TrackerSources.letterboxd)
        .toList();
    letterboxdLastImportAt = null;
    await Future.wait([
      _store.saveLetterboxdWatchlist(letterboxdWatchlist),
      _store.saveTrackerStatuses(trackerStatuses),
      _store.clearLetterboxdLastImportAt(),
    ]);
    _cachedRecommendations = null;
    _recommendationsStamp = -1;
    notifyListeners();
  }

  /// Best local hit for a Letterboxd shell tile (movies only).
  MediaItem? resolveLetterboxdWatchlistTap(MediaItem item) {
    if (!isLetterboxdWatchlistShell(item)) return item;
    return matchSimklIdsToLocal(
      SimklIds(tmdb: item.tmdbId, imdb: item.imdbId),
      catalog: catalog,
      history: history,
      watchlist: watchlist,
      extra: _vodStreamCache.values,
      title: item.title,
      year: item.year,
    );
  }
}
