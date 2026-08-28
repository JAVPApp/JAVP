part of '../library_provider.dart';

/// Plex tracker sync / auth / shelves for [LibraryProvider].
extension TrackerSyncPlex on LibraryProvider {
  Future<void> syncPlexWatchlist({bool force = false}) async {
    if (_plexWatchlistToken() == null) return;
    if (!force && !_appForeground) {
      TrackerLog.syncSkip('plex', 'background');
      return;
    }
    final lastAttempt = _plexWatchlistLastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      TrackerLog.syncSkip('plex', 'rate-limit');
      return;
    }
    await _bgQueue.enqueue(
      id: 'plex-watchlist-sync',
      priority: BackgroundPriority.high,
      action: () => _syncPlexWatchlistBody(force: force),
    );
  }

  String? _plexWatchlistToken() {
    IptvSource? fast;
    IptvSource? plex;
    for (final source in sources) {
      if (source.type != IptvSourceType.plex) continue;
      final token = (source.password ?? '').trim();
      if (token.isEmpty) continue;
      plex ??= source;
      if (PlexClient.isFastProvider(source)) {
        fast = source;
        break;
      }
    }
    final token = (fast ?? plex)?.password?.trim();
    return (token == null || token.isEmpty) ? null : token;
  }

  IptvSource? _plexFastSource() {
    for (final source in sources) {
      if (PlexClient.isFastProvider(source)) return source;
    }
    return null;
  }

  bool get hasPlexWatchlistSource => _plexWatchlistToken() != null;

  Future<void> _syncPlexWatchlistBody({required bool force}) async {
    final token = _plexWatchlistToken();
    if (token == null) return;
    if (_plexWatchlistSyncing) {
      TrackerLog.syncSkip('plex', 'in-flight');
      return;
    }
    if (!force && !_appForeground) {
      TrackerLog.syncSkip('plex', 'background');
      return;
    }

    _plexWatchlistSyncing = true;
    _plexWatchlistLastSyncAttempt = DateTime.now();
    notifyListeners();
    var ok = true;
    final watch = Stopwatch()..start();
    TrackerLog.syncStart('plex', force: force);
    try {
      final clientId = await _plexClientIdentifier();
      final rows = await _plexAccount.fetchWatchlist(
        token,
        clientIdentifier: clientId,
      );
      await Future<void>.delayed(Duration.zero);
      final index = await _ensureTrackerMatchIndex();
      plexWatchlist = await resolvePlexWatchlistItemsAsync(
        rows,
        catalog: catalog,
        history: history,
        watchlist: watchlist,
        extra: _vodStreamCache.values,
        fastSource: _plexFastSource(),
        index: index,
      );
      await _store.savePlexWatchlist(plexWatchlist);
      TrackerLog.shelf('plex', 'watchlist', count: plexWatchlist.length);
    } catch (_) {
      ok = false;
    } finally {
      _plexWatchlistSyncing = false;
      TrackerLog.syncEnd('plex', ms: watch.elapsedMilliseconds, ok: ok);
      notifyListeners();
    }
  }

  Future<void> _relinkPlexWatchlist({
    BackgroundPriority priority = BackgroundPriority.normal,
  }) {
    if (plexWatchlist.isEmpty) return Future<void>.value();
    return _bgQueue.enqueue(
      id: 'plex-watchlist-relink',
      priority: priority,
      action: () async {
        if (plexWatchlist.isEmpty) return;
        if (priority == BackgroundPriority.low &&
            (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork)) {
          return;
        }
        final wasQuiet = _uiQuiet;
        _uiQuiet = true;
        try {
          final index = await _ensureTrackerMatchIndex();
          final linked = await relinkPlexWatchlistItemsAsync(
            plexWatchlist,
            catalog: catalog,
            history: history,
            watchlist: watchlist,
            extra: _vodStreamCache.values,
            fastSource: _plexFastSource(),
            index: index,
          );
          if (identical(linked, plexWatchlist)) return;
          if (!_watchingShelfChanged(plexWatchlist, linked)) return;
          plexWatchlist = linked;
          await _store.savePlexWatchlist(plexWatchlist);
        } finally {
          _uiQuiet = wasQuiet;
          if (!_disposed) _notifyListenersAfterIdle();
        }
      },
    );
  }
}
