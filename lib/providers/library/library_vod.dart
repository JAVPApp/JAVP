part of '../library_provider.dart';

extension LibraryVod on LibraryProvider {
  Future<void> _enableVodDb({required String reason}) async {
    if (kIsWeb) {
      JavpLog.i('vod', 'db skipped on web reason=$reason');
      return;
    }
    if (_useVodDb) {
      // Already on — ingest callers refresh counts after the write. Re-running
      // COUNT / GROUP BY + a revision bump rematerialized Home on every
      // custom upsert during profile restore.
      final gate = _vodHydrateDelayGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      return;
    }
    try {
      await _vodDb.ensureOpen();
    } catch (e) {
      JavpLog.w('vod', 'db enable failed reason=$reason', error: e);
      return;
    }
    _useVodDb = true;
    _vodDiskHydrated = true;
    vodDbRevision++;
    // Unblock an idle JSON hydrate wait started before DB enable.
    final gate = _vodHydrateDelayGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    // Catalog / Search can query immediately; cache refresh follows.
    _notifyPierceQuiet();
    // Sort-title rewrite walks every VOD row on the UI isolate — never do it
    // on the enable critical path (that was the 20–40s HWND death before Sync),
    // and never while Catalog/TV still need the shared sqflite isolate.
    unawaited(_deferredVodSortTitleReindex());
    // Prefer a cheap EXISTS + cached meta over COUNT(*) of 200k rows.
    try {
      final cached = await _vodDb.cachedItemCount;
      if (cached != null) {
        _vodDbCountCache = cached;
      } else {
        await _refreshVodDbCountCache();
        await _vodDb.storeCachedItemCount(_vodDbCountCache);
      }
    } catch (_) {
      await _refreshVodDbCountCache();
    }
    await _refreshVodDbSourceIds();
    // Do NOT run listGroupsBySource here — GROUP BY on a fat Xtream catalog
    // freezes the Windows HWND before the user even opens Sources.
    // Chips / group index build on Catalog demand or deferred idle warm.
    JavpLog.i(
      'vod',
      'db enabled reason=$reason count=$_vodDbCountCache rev=$vodDbRevision'
          ' fts=${_vodDb.ftsEnabled}',
    );
  }

  Future<void> _deferredVodSortTitleReindex() async {
    // Wait out cold-start bootstrap + first Catalog group-index. A 3s timer
    // used to start rewriting ~200k sort_title rows while TV/Catalog still
    // needed sqflite — live stayed on memory and shelves never filled.
    await Future<void>.delayed(const Duration(seconds: 45));
    for (var i = 0; i < 30; i++) {
      if (_disposed) return;
      final catalogWriterBusy =
          DesktopUi.isDesktopOs && SyncScheduler.instance.isCatalogWriterBusy;
      final groupIndexBusy = _vodGroupIndexRebuild != null;
      final hydrateBusy =
          _vodHydrateFuture != null && !_vodHydrateIdleWaiting;
      if (!_vodGroupIndexAbort &&
          _allowIdleBackgroundWork &&
          !catalogWriterBusy &&
          !groupIndexBusy &&
          !hydrateBusy &&
          _vodDiskHydrated) {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (_disposed || _vodGroupIndexAbort || !_allowIdleBackgroundWork) return;
    JavpLog.i('vod', 'sort-title reindex begin (deferred idle)');
    await _maybeReindexVodSortTitles();
    JavpLog.i('vod', 'sort-title reindex end');
  }

  Future<void> _refreshVodDbSourceIds() async {
    if (!_useVodDb) {
      _vodDbSourceIds.clear();
      return;
    }
    try {
      // One DISTINCT scan — N× COUNT(*) for each source serialized the
      // shared sqflite_ffi isolate behind Synchroniser.
      final ids = await _vodDb.listSourceIds();
      _vodDbSourceIds
        ..clear()
        ..addAll(ids.where((id) {
          final s = _sourceById(id);
          return s != null && _sourceContributesVod(s);
        }));
    } catch (_) {}
  }

  /// Persist VOD rows: SQLite when active, JSON fallback otherwise.
  Future<void> _persistVodCache({
    String? replaceSourceId,
    Iterable<MediaItem>? sourceItems,
  }) async {
    if (_useVodDb) {
      if (replaceSourceId != null && sourceItems != null) {
        final list = sourceItems.toList(growable: false);
        await _vodDb.replaceSourceVod(sourceId: replaceSourceId, items: list);
        if (list.isEmpty) {
          _vodDbSourceIds.remove(replaceSourceId);
        } else {
          _vodDbSourceIds.add(replaceSourceId);
        }
      } else {
        // Full rewrite from the in-memory working set (rare / migrate path).
        final bySource = <String, List<MediaItem>>{};
        for (final item in _vodStreamCache.values) {
          if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
            continue;
          }
          final sid = item.sourceId ?? '__unknown__';
          bySource.putIfAbsent(sid, () => []).add(item);
        }
        for (final e in bySource.entries) {
          await _vodDb.replaceSourceVod(sourceId: e.key, items: e.value);
          if (e.value.isEmpty) {
            _vodDbSourceIds.remove(e.key);
          } else {
            _vodDbSourceIds.add(e.key);
          }
        }
      }
      await _refreshVodDbCountCache();
      return;
    }
    await _store.saveVodCache(_vodStreamCache.values);
  }

  /// One-shot JSON → SQLite migrate when the DB is empty.
  Future<void> _maybeMigrateVodJsonToDb() async {
    if (_useVodDb) return;
    try {
      if (await _vodDb.hasItems) {
        await _enableVodDb(reason: 'existing-db');
        return;
      }
      final known = {for (final s in sources) s.id};
      final items = await _store.loadVodCache(
        knownSourceIds: known,
        localSourceKey: LibraryProvider.localSourceKey,
      );
      if (items.isEmpty) return;
      JavpLog.i('vod', 'migrating json cache → sqlite n=${items.length}');
      await _vodDb.migrateFromMediaItems(items);
      await _vodDb.markMigratedFromJson();
      // Drop the giant JSON after a successful migrate.
      try {
        await _store.saveVodCache(const []);
      } catch (_) {}
      await _enableVodDb(reason: 'migrate-json');
    } catch (e) {
      JavpLog.w('vod', 'json→sqlite migrate failed', error: e);
    }
  }

  /// Page VOD from SQLite. Does **not** copy the page into [_vodStreamCache]
  /// — native catalogs stay in the DB (see `docs/architecture.md`).
  Future<List<MediaItem>> _pageVodFromDb({
    String? categoryName,
    bool? series,
    String? sourceKey,
    Set<String>? sourceKeys,
    int limit = 500,
    bool forShelfSample = false,
    VodCatalogOrder order = VodCatalogOrder.title,
  }) async {
    if (!_useVodDb) return const [];
    final allowed = _vodAllowedSourceIds(
      sourceKey: sourceKey,
      sourceKeys: sourceKeys,
    );
    return _vodDb.pageItems(
      series: series,
      groupName: categoryName,
      allowedSourceIds: allowed,
      excludeAdult: _parentalExcludeAdult(),
      // Shelf posters: skip correlated MAX(sync_generation) — warming ~180
      // fat Xtream groups with that subquery starved group-index / live DB.
      latestGenerationOnly: !forShelfSample,
      order: order,
      limit: LibraryProvider.vodDbWorkingSetFetchLimit(
        limit: limit,
        categoryScoped: categoryName != null,
        forShelfSample: forShelfSample,
      ),
      offset: 0,
    );
  }

  List<MediaItem> get vodItems {
    return queryVodCatalog();
  }

  /// Cached on-demand titles (Xtream movies/series + BYO catalog VOD).
  /// Prefer [categoryName] for large panels — unscoped queries are capped for
  /// progressive UI pagination only (See-all / infinite scroll), never as a
  /// silent catalog truncation of a known category.
  ///
  /// Category-scoped lookups collect the **full** group (via index when ready,
  /// otherwise a full cache walk), then A–Z + [limit]. Does not change live
  /// channel playlist order (live uses [pageLiveChannels] / [LiveListingSort]).
  List<MediaItem> queryVodCatalog({
    bool? series,
    String? categoryName,
    String? sourceKey,
    Set<String>? sourceKeys,
    String? query,
    int limit = 500,
    bool collapse = true,
    CatalogBrowsePrefs? browse,
  }) {
    final q = query?.trim() ?? '';
    final matches = <MediaItem>[];
    // Category “See all” must collect the full group before A–Z + limit.
    // Unscoped queries keep a rawCap so Home/All progressive pages stay cheap.
    final indexedCategory =
        categoryName != null &&
        _vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision;
    final int? rawCap = categoryName != null
        ? null
        : (collapse ? (limit < 80 ? 80 : limit * 3) : limit);

    final hayById =
        (_vodSearchHayById != null &&
            _vodSearchHayRevision == _vodCacheRevision)
        ? _vodSearchHayById
        : null;
    final qTokens = q.isEmpty ? const <String>[] : IptvSearchQuery.tokens(q);
    if (qTokens.isNotEmpty) {
      _scheduleVodSearchHayBuild();
    }
    final sourceFilter =
        sourceKeys ??
        (sourceKey == null || sourceKey.isEmpty ? null : <String>{sourceKey});

    void consider(MediaItem item) {
      if (rawCap != null && matches.length >= rawCap) return;
      if (!isSourceVodContentVisible(item.sourceId)) return;
      if (parentalLock?.isItemHidden(item) == true) return;
      if (series != null) {
        if (series && !item.isSeries) return;
        if (!series && item.isSeries) return;
      } else if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
        return;
      }
      if (sourceFilter != null &&
          sourceFilter.isNotEmpty &&
          (item.sourceId == null || !sourceFilter.contains(item.sourceId))) {
        return;
      }
      if (categoryName != null && (item.group ?? '') != categoryName) return;
      if (qTokens.isNotEmpty) {
        final cached = hayById?[item.id];
        if (cached != null) {
          if (!VodSearchIndex.matchesTokens(cached, qTokens)) return;
        } else if (!IptvSearchQuery.matchesFields(q, [
          item.title,
          item.group,
          item.subtitle,
          item.channelName,
          item.streamId,
        ])) {
          return;
        }
      }
      matches.add(item);
    }

    if (categoryName != null) {
      // Prefer index when ready; otherwise full walk (never prefix-cap a category).
      if (indexedCategory) {
        final bucket = _vodByGroupIndex![categoryName] ?? const <MediaItem>[];
        for (final item in bucket) {
          consider(item);
        }
      } else {
        _scheduleVodGroupIndexBuild();
        // Sync callers (widget build) must not walk 100k+ rows. Large
        // caches wait for the yielded index / [queryVodCatalogAsync].
        if (_vodStreamCache.length <= 2500) {
          for (final item in _vodStreamCache.values) {
            consider(item);
          }
        }
      }
    } else {
      for (final item in _vodStreamCache.values) {
        consider(item);
        if (rawCap != null && matches.length >= rawCap) break;
      }
    }
    if (rawCap == null || matches.length < rawCap) {
      for (final item in catalog) {
        if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
          continue;
        }
        if (_vodStreamCache.containsKey(item.id)) continue;
        consider(item);
        if (rawCap != null && matches.length >= rawCap) break;
      }
    }

    final list = collapse ? collapseVodVariants(matches) : matches;
    if (browse != null) {
      return applyCatalogBrowseItems(list, prefs: browse, limit: limit);
    }
    if (list.length <= 1) return list;
    list.sort(VodGrouping.compareDisplayTitle);
    if (list.length > limit) return list.sublist(0, limit);
    return list;
  }

  /// Lightweight shelf sample — never scans/collapses the full VOD universe
  /// on the UI isolate when the group/kind index is warm.
  ///
  /// Merges [_vodStreamCache] with [catalog] (same idea as [queryVodCatalog])
  /// so BYO/custom series still appear when the Xtream movie cache is warm.
  ///
  /// Display window is [limit] (intentional Home preview). When the async
  /// index has ranked the **full** movie/series sets, samples come from that
  /// ranked pool — not from a truncated cache prefix.
  List<MediaItem> vodPreview({required bool series, int limit = 18}) {
    final prefs = _preferredContentLangs;
    final stamp = Object.hash(
      series,
      limit,
      vodCacheRevision,
      homeVodShelfRevision,
      identityHashCode(catalog),
      catalog.length,
      sourcesEnabledRevision,
      Object.hashAll(prefs),
      parentalLock?.lockFilterStamp ?? 'none',
    );
    if (series) {
      if (_cachedVodPreviewSeries != null &&
          _vodPreviewSeriesStamp == stamp &&
          _vodPreviewSeriesLimit == limit) {
        return _cachedVodPreviewSeries!;
      }
    } else if (_cachedVodPreviewMovies != null &&
        _vodPreviewMoviesStamp == stamp &&
        _vodPreviewMoviesLimit == limit) {
      return _cachedVodPreviewMovies!;
    }

    final raw = <MediaItem>[];
    final rawCap = limit * 4;
    final seen = <String>{};

    bool accept(MediaItem item) {
      if (!isListedVodSourceVisible(item.sourceId)) return false;
      if (parentalLock?.isItemHidden(item) == true) return false;
      if (series) {
        if (!item.isSeries) return false;
      } else {
        if (item.isSeries || item.isLive || item.isEpisode) return false;
        if (item.kind != MediaKind.vod &&
            item.kind != MediaKind.local &&
            item.kind != MediaKind.network) {
          return false;
        }
      }
      return seen.add(item.id);
    }

    final indexed =
        _vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision;
    final rankedPool = series ? _vodHomeSeriesPreview : _vodHomeMoviePreview;
    // SQLite hydrate publishes Home previews before full group-index keys
    // exist. Waiting for [indexed] left Accueil on Plex/BYO [catalog] only
    // (empty [_vodStreamCache] cold walk) until indexes finished — often
    // deferred across blur/Synchroniser.
    if (rankedPool != null && rankedPool.isNotEmpty) {
      for (final item in rankedPool) {
        if (!accept(item)) continue;
        raw.add(item);
        if (raw.length >= rawCap) break;
      }
    } else if (indexed) {
      // Index ready but preview window empty — nothing to show for this kind.
    } else {
      // Temporary degraded path until [ensureVodGroupIndex] finishes: capped
      // walk so Accueil never freezes on a cold 100k cache. Schedule index.
      if (_useVodDb) {
        unawaited(rebuildVodGroupIndexCoalesced());
      } else {
        _scheduleVodGroupIndexBuild();
      }
      const maxScan =
          2500; // intentional cold-start bound, not a catalog policy
      var scanned = 0;
      for (final item in _vodStreamCache.values) {
        if (++scanned > maxScan) break;
        if (!accept(item)) continue;
        raw.add(item);
        if (raw.length >= rawCap) break;
      }
    }
    if (raw.length < rawCap) {
      for (final item in catalog) {
        if (!accept(item)) continue;
        raw.add(item);
        if (raw.length >= rawCap) break;
      }
    }
    final collapsed = collapseVodVariants(raw);
    collapsed.sort(
      (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
    );
    final result = collapsed.length <= limit
        ? collapsed
        : collapsed.sublist(0, limit);
    if (series) {
      _cachedVodPreviewSeries = result;
      _vodPreviewSeriesStamp = stamp;
      _vodPreviewSeriesLimit = limit;
    } else {
      _cachedVodPreviewMovies = result;
      _vodPreviewMoviesStamp = stamp;
      _vodPreviewMoviesLimit = limit;
    }
    return result;
  }

  int get vodCacheCount =>
      _useVodDb ? _vodDbCountCache : _vodStreamCache.length;

  /// True when VOD/series rows are served from [VodCatalogDb].
  bool get hasVodDb => _useVodDb;

  Future<void> loadVodCategory(IptvCategory category) async {
    activeVodCategoryId = category.id;
    error = null;

    // Synthesized shelves (media servers / custom catalog) are already local.
    if (category.id.startsWith('catalog-group:')) {
      vodCategoryItems = await queryVodCatalogAsync(
        categoryName: category.name,
        series: category.kind == IptvCategoryKind.series ? true : false,
        limit: 500,
      );
      notifyListeners();
      return;
    }

    vodLoading = true;
    _bumpVodBusy();
    try {
      await _fetchVodCategoryRows(category);
      // Unified sorted page — includes same-named groups from other sources.
      vodCategoryItems = await queryVodCatalogAsync(
        categoryName: category.name,
        series: category.kind == IptvCategoryKind.series ? true : false,
        limit: 500,
      );
    } catch (e) {
      error = e.toString();
      vodCategoryItems = [];
    } finally {
      vodLoading = false;
      _bumpVodBusy();
      notifyListeners();
    }
  }

  Future<void> _acquireVodCategoryNetworkSlot() async {
    if (_vodCategoryNetworkActive <
        LibraryProvider._maxVodCategoryNetworkFetches) {
      _vodCategoryNetworkActive++;
      return;
    }
    final waiter = Completer<void>();
    _vodCategoryNetworkWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseVodCategoryNetworkSlot() {
    if (_vodCategoryNetworkWaiters.isNotEmpty) {
      _vodCategoryNetworkWaiters.removeAt(0).complete();
      return;
    }
    _vodCategoryNetworkActive--;
  }

  Future<void> _fetchVodCategoryRows(IptvCategory category) async {
    final ownedSourceId = category.sourceId;
    final source = sources.cast<IptvSource?>().firstWhere((s) {
      if (s == null ||
          !_sourceContributesVod(s) ||
          (s.type != IptvSourceType.xtream &&
              s.type != IptvSourceType.stalker)) {
        return false;
      }
      if (ownedSourceId != null && ownedSourceId.isNotEmpty) {
        return s.id == ownedSourceId;
      }
      return true;
    }, orElse: () => null);
    if (source == null) return;

    final key = '${source.id}|${category.kind.name}|${category.id}';
    final existing = _vodCategoryLoads[key];
    if (existing != null) return existing;
    late final Future<void> load;
    load = _runVodCategoryFetch(source, category).whenComplete(() {
      if (identical(_vodCategoryLoads[key], load)) {
        _vodCategoryLoads.remove(key);
      }
    });
    _vodCategoryLoads[key] = load;
    return load;
  }

  Future<void> _runVodCategoryFetch(
    IptvSource source,
    IptvCategory category,
  ) async {
    await _acquireVodCategoryNetworkSlot();
    try {
      final raw = await _runUserFacing(
        () => source.type == IptvSourceType.stalker
            ? _stalker.loadCategoryStreams(source, category: category)
            : _xtream.loadCategoryStreams(source, category: category),
      );
      final group = category.name;
      if (_useVodDb || raw.length > 400) {
        if (!_useVodDb) await _enableVodDb(reason: 'category-load');
        await _vodDb.upsertSourceGroupVod(
          sourceId: source.id,
          groupName: group,
          items: raw,
        );
        _vodDbSourceIds.add(source.id);
        await _refreshVodDbCountCache();
        vodDbRevision++;
        _vodCacheRevision++;
        _vodPoolCache = null;
        _vodSearchHayById = null;
        _vodSearchHayRevision = null;
        _invalidateHomeShelfCaches();
      } else {
        List<MediaItem>? bucket;
        if (_vodByGroupIndex != null &&
            _vodByGroupIndexRevision == _vodCacheRevision) {
          bucket = _vodByGroupIndex!.putIfAbsent(group, () => <MediaItem>[]);
        }
        const chunk = 120;
        final hay =
            (_vodSearchHayById != null &&
                _vodSearchHayRevision == _vodCacheRevision)
            ? _vodSearchHayById
            : null;
        for (var i = 0; i < raw.length; i += chunk) {
          final end = (i + chunk > raw.length) ? raw.length : i + chunk;
          for (var j = i; j < end; j++) {
            final item = raw[j];
            _vodStreamCache[item.id] = item;
            bucket?.add(item);
            hay?[item.id] = VodSearchIndex.hayFor(item);
          }
          await yieldAfterIsolateChunk();
        }
        _vodCacheRevision++;
        // Keep the in-place index if we updated buckets; otherwise invalidate.
        if (bucket == null) {
          _vodByGroupIndex = null;
          _vodByGroupIndexRevision = null;
        } else {
          _vodByGroupIndexRevision = _vodCacheRevision;
        }
        if (hay != null) {
          _vodSearchHayRevision = _vodCacheRevision;
        } else {
          _vodSearchHayById = null;
          _vodSearchHayRevision = null;
          _scheduleVodSearchHayBuild();
        }
        unawaited(_persistVodCache());
      }
      _notifyPierceQuiet();
    } finally {
      _releaseVodCategoryNetworkSlot();
    }
  }

  List<MediaItem> vodShelfSample({
    required String categoryName,
    bool? series,
    String? sourceKey,
    Set<String>? sourceKeys,
    int limit = 14,
    CatalogBrowsePrefs? browse,
  }) {
    if (categoryName.isEmpty || limit <= 0) return const [];
    // Over-collect then sort so multi-source shelves aren't sync-block order.
    // Small/medium indexed buckets: full A–Z. Huge buckets: capped window so
    // Catalog → Movies stays interactive (exact A–Z lives on See-all).
    //
    // SQLite path seeds empty buckets as category *keys* only — not a RAM
    // working set. Treat empty buckets as not indexed so Catalog probes disk
    // instead of spinning on a forever-empty shelf.
    final hasIndex =
        _vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision;
    final bucket = hasIndex ? _vodByGroupIndex![categoryName] : null;
    final indexed =
        hasIndex && (!_useVodDb || (bucket != null && bucket.isNotEmpty));
    final hugeIndexed =
        indexed &&
        bucket != null &&
        bucket.length > LibraryProvider._vodShelfFullSortLimit;
    final rawCap = (!indexed || hugeIndexed) ? limit * 32 : null;
    final out = <MediaItem>[];
    final seen = <String>{};
    final sourceFilter =
        sourceKeys ??
        (sourceKey == null || sourceKey.isEmpty ? null : <String>{sourceKey});

    bool take(MediaItem item) {
      if ((item.group ?? '') != categoryName) return false;
      if (series != null) {
        if (series && !item.isSeries) return false;
        if (!series && item.isSeries) return false;
      } else if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
        return false;
      }
      if (item.isLive || item.isEpisode) return false;
      if (!isSourceVodContentVisible(item.sourceId)) return false;
      if (sourceFilter != null &&
          sourceFilter.isNotEmpty &&
          (item.sourceId == null || !sourceFilter.contains(item.sourceId))) {
        return false;
      }
      if (!seen.add(item.id)) return false;
      out.add(item);
      return rawCap != null && out.length >= rawCap;
    }

    if (indexed) {
      if (bucket != null) {
        for (final item in bucket) {
          if (take(item)) break;
        }
      }
    } else {
      _scheduleVodGroupIndexBuild();
      // A full cache walk from Catalog [build] freezes Windows on 100k+
      // rows. Small caches can still answer immediately; large ones wait
      // for the yielded index (which then notifies and fills shelves).
      if (_vodStreamCache.length <= 2500) {
        for (final item in _vodStreamCache.values) {
          if (take(item)) break;
        }
      }
    }

    if (rawCap == null || out.length < rawCap) {
      for (final item in catalog) {
        if (take(item)) break;
      }
    }

    final collapsed = collapseVodVariants(out);
    if (browse != null) {
      return applyCatalogBrowseItems(collapsed, prefs: browse, limit: limit);
    }
    collapsed.sort(VodGrouping.compareDisplayTitle);
    if (collapsed.length <= limit) return collapsed;
    return collapsed.sublist(0, limit);
  }

  /// Awaitable VOD group + Home-preview index. Safe to call often.
  Future<void> ensureVodGroupIndex() async {
    await ensureVodDiskHydrated();
    if (_useVodDb) {
      // Catalog demand must not no-op while abort is only latched for
      // opportunistic Synchroniser deferral — clear when writers/guide idle.
      final guideOnUiIsolate =
          !DesktopUi.isDesktopOs ||
          Platform.environment['JAVP_SYNC_INPROCESS'] == '1';
      final blocked = _manualSyncFocusHold.isNotEmpty ||
          (guideOnUiIsolate &&
              (_epgReloadPendingSourceIds.isNotEmpty ||
                  _epgReloadInFlight != null)) ||
          (DesktopUi.isDesktopOs &&
              SyncScheduler.instance.isCatalogWriterBusy);
      if (!blocked) {
        _clearVodGroupIndexAbort();
      }
      await rebuildVodGroupIndexCoalesced();
      final inflight = _vodGroupIndexRebuild;
      if (inflight != null) await inflight;
      return;
    }
    // Loop: a build may abort+reschedule when the cache grows mid-pass.
    for (var attempt = 0; attempt < 8; attempt++) {
      if (_vodByGroupIndex != null &&
          _vodByGroupIndexRevision == _vodCacheRevision) {
        return;
      }
      if (_vodStreamCache.isEmpty) return;
      _scheduleVodGroupIndexBuild();
      final build = _vodIndexBuildFuture;
      if (build == null) return;
      await build;
    }
  }

  /// Page VOD from SQLite (or memory) for Catalog See-all / category screens.
  Future<List<MediaItem>> queryVodCatalogAsync({
    bool? series,
    String? categoryName,
    String? sourceKey,
    Set<String>? sourceKeys,
    String? query,
    int limit = 500,
    bool collapse = true,
    CatalogBrowsePrefs? browse,
  }) async {
    await ensureVodDiskHydrated();
    if (_useVodDb) {
      final q = query?.trim() ?? '';
      List<MediaItem> page;
      if (q.isNotEmpty) {
        final allowed = _vodAllowedSourceIds(
          sourceKey: sourceKey,
          sourceKeys: sourceKeys,
        );
        page = await _vodDb.searchFts(
          q,
          series: series,
          sourceId: sourceKey,
          allowedSourceIds:
              sourceKeys?.toList(growable: false) ??
              (sourceKey == null ? allowed : null),
          excludeAdult: _parentalExcludeAdult(),
          limit: limit * 2,
        );
        if (categoryName != null) {
          page = [
            for (final item in page)
              if ((item.group ?? '') == categoryName) item,
          ];
        }
      } else {
        page = await _pageVodFromDb(
          categoryName: categoryName,
          series: series,
          sourceKey: sourceKey,
          sourceKeys: sourceKeys,
          limit: limit,
          order: LibraryProvider._vodOrderForBrowse(browse),
        );
      }
      page = _mergeByoVodIntoPage(
        page,
        series: series,
        categoryName: categoryName,
        sourceKey: sourceKey,
        sourceKeys: sourceKeys,
        query: q.isEmpty ? null : q,
        cap: collapse ? (limit < 80 ? 80 : limit * 3) : limit,
      );
      if (browse != null) {
        return applyCatalogBrowseItems(
          collapse ? collapseVodVariants(page) : page,
          prefs: browse,
          limit: limit,
        );
      }
      final list = collapse ? collapseVodVariants(page) : page;
      if (list.length <= 1) return list;
      list.sort(VodGrouping.compareDisplayTitle);
      if (list.length > limit) return list.sublist(0, limit);
      return list;
    }
    return queryVodCatalog(
      series: series,
      categoryName: categoryName,
      sourceKey: sourceKey,
      sourceKeys: sourceKeys,
      query: query,
      limit: limit,
      collapse: collapse,
      browse: browse,
    );
  }

  /// Async shelf sample — pages SQLite directly (no RAM working-set copy).
  Future<List<MediaItem>> vodShelfSampleAsync({
    required String categoryName,
    bool? series,
    String? sourceKey,
    Set<String>? sourceKeys,
    int limit = 14,
    CatalogBrowsePrefs? browse,
  }) async {
    if (_useVodDb) {
      await ensureVodDiskHydrated();
      final prefs = browse;
      final fetchLimit = prefs != null && prefs.hideWatched
          ? 200
          : LibraryProvider.vodDbWorkingSetFetchLimit(
              limit: limit,
              categoryScoped: true,
              forShelfSample: true,
            );
      final page = await _pageVodFromDb(
        categoryName: categoryName,
        series: series,
        sourceKey: sourceKey,
        sourceKeys: sourceKeys,
        limit: fetchLimit,
        forShelfSample: true,
        order: LibraryProvider._vodOrderForBrowse(prefs),
      );
      final merged = _mergeByoVodIntoPage(
        page,
        series: series,
        categoryName: categoryName,
        sourceKey: sourceKey,
        sourceKeys: sourceKeys,
        cap: fetchLimit,
      );
      final collapsed = collapseVodVariants(merged);
      if (prefs != null) {
        return applyCatalogBrowseItems(collapsed, prefs: prefs, limit: limit);
      }
      collapsed.sort(VodGrouping.compareDisplayTitle);
      if (collapsed.length <= limit) return collapsed;
      return collapsed.sublist(0, limit);
    }
    return vodShelfSample(
      categoryName: categoryName,
      series: series,
      sourceKey: sourceKey,
      sourceKeys: sourceKeys,
      limit: limit,
      browse: browse,
    );
  }

  /// Custom / BYO rows still live in [catalog]; IPTV VOD does not.
  List<MediaItem> _mergeByoVodIntoPage(
    List<MediaItem> page, {
    bool? series,
    String? categoryName,
    String? sourceKey,
    Set<String>? sourceKeys,
    String? query,
    required int cap,
  }) {
    if (catalog.isEmpty) return page;
    final sourceFilter =
        sourceKeys ??
        (sourceKey == null || sourceKey.isEmpty ? null : <String>{sourceKey});
    final q = query?.trim() ?? '';
    final qTokens = q.isEmpty ? const <String>[] : IptvSearchQuery.tokens(q);
    final seen = {for (final item in page) item.id};
    final out = List<MediaItem>.from(page);
    for (final item in catalog) {
      if (out.length >= cap) break;
      if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
        continue;
      }
      if (!seen.add(item.id)) continue;
      if (!isSourceVodContentVisible(item.sourceId)) continue;
      if (parentalLock?.isItemHidden(item) == true) continue;
      if (series != null) {
        if (series && !item.isSeries) continue;
        if (!series && item.isSeries) continue;
      }
      if (sourceFilter != null &&
          sourceFilter.isNotEmpty &&
          (item.sourceId == null || !sourceFilter.contains(item.sourceId))) {
        continue;
      }
      if (categoryName != null && (item.group ?? '') != categoryName) {
        continue;
      }
      if (qTokens.isNotEmpty &&
          !IptvSearchQuery.matchesFields(q, [
            item.title,
            item.group,
            item.subtitle,
            item.channelName,
            item.streamId,
          ])) {
        continue;
      }
      out.add(item);
    }
    return out;
  }

  /// Awaitable Versions index. Safe to call often; large caches build off-UI.
  Future<void> ensureVodVariantIndex() async {
    await ensureVodDiskHydrated();
    // Loop: a build may abort+reschedule when the cache grows mid-pass.
    for (var attempt = 0; attempt < 8; attempt++) {
      final stamp = _vodPoolStamp;
      if (_vodVariantIndex != null && _vodVariantBuiltStamp == stamp) return;
      // Explicit awaiters (Catalog / detail) must not stay deferred on blur.
      _ensureVodVariantIndex(force: true);
      final build = _vodVariantIndexBuildFuture;
      if (build == null) return;
      await build;
    }
  }

  List<MediaItem> vodVariantsFor(MediaItem item) {
    // Live / episodes: no title-detail Versions family.
    if (!_isVodMovieFamilyItem(item)) {
      return isSourceVodContentVisible(item.sourceId) ? [item] : const [];
    }
    // Accueil first paint: don't scan 9k catalog rows per tile.
    if (!_homeRevealSettled &&
        catalog.length >= VodVariantIndex.isolateMinRows) {
      return isSourceVodContentVisible(item.sourceId) ? [item] : const [];
    }
    _ensureVodVariantIndex();
    final index = _activeVodIndex;
    final canonicalMap = _activeVodCanonical;
    final catalogLookup = _catalogIdentityLookup();
    final seedPrimary = VodGrouping.groupKey(item);

    final byId = <String, MediaItem>{};
    void add(MediaItem? m) {
      if (m == null) return;
      if (!_isVodMovieFamilyItem(m)) return;
      if (!isSourceVodContentVisible(m.sourceId)) return;
      byId[m.id] = m;
    }

    void addKey(String? key) {
      if (key == null || key.isEmpty) return;
      var mapped = canonicalMap?[key] ?? catalogLookup.aliasCanonical[key];
      if (mapped == key) mapped = null;
      final uniqueIdentity =
          mapped != null && VodGrouping.isIdentityGroupKey(mapped);
      for (final k in {key, ?mapped}) {
        final catalogMapped = catalogLookup.aliasCanonical[k];
        // Ambiguous title|year aliases are omitted from [aliasCanonical]
        // because more than one TMDB/IMDb family claimed them. Do not pull
        // that raw alias bucket — it mixes editions of different movies and
        // name-only rows that only share a cleaned title.
        if (k.startsWith('name:') &&
            catalogMapped == null &&
            !uniqueIdentity &&
            seedPrimary != k) {
          continue;
        }
        final indexed = index?[k];
        if (indexed != null) {
          for (final id in indexed) {
            add(_vodItemById(id));
          }
        }
        final extras = catalogLookup.byKey[k];
        if (extras == null) continue;
        for (final m in extras) {
          if (k.startsWith('name:') && catalogMapped == null) {
            final primary = VodGrouping.groupKey(m);
            if (primary != null &&
                VodGrouping.isIdentityGroupKey(primary) &&
                primary != mapped) {
              continue;
            }
          }
          add(m);
        }
      }
    }

    add(item);
    addKey(VodGrouping.groupKey(item));
    addKey(canonicalVodGroupKey(item));
    for (final alias in VodGrouping.nameGroupAliases(item)) {
      addKey(alias);
    }
    // Catalog TMDB rows found via a unique title|year should pull the rest of
    // that id. Do not expand name keys — an ambiguous alias must not hop into
    // another movie's identity family.
    for (final member in byId.values.toList(growable: false)) {
      final gk = VodGrouping.groupKey(member);
      if (gk != null && VodGrouping.isIdentityGroupKey(gk)) {
        addKey(gk);
      }
    }
    final overlay = _vodFamilyOverlay[item.id];
    if (overlay != null) {
      for (final m in overlay) {
        add(m);
      }
    }

    if (byId.isEmpty) {
      return isSourceVodContentVisible(item.sourceId) ? [item] : const [];
    }
    final visible = byId.values.toList()
      ..sort(
        (a, b) => VodGrouping.compareVariants(
          a,
          b,
          preferredLangs: _preferredContentLangs,
        ),
      );
    return visible;
  }

  /// Pull sqlite-only IPTV editions into the title-page / Home family.
  ///
  /// Custom catalogs are not in [vod_catalog.db]; FTS returns the panel rows,
  /// then [vodSearchFamilyIndex] joins them to the catalog TMDB copies.
  ///
  /// Home idle-hydrates visible shelf cards with [notify] off and fans out
  /// once per batch so Accueil is not rematerialized.
  Future<void> hydrateVodFamilyFromDb(
    MediaItem item, {
    bool notify = true,
  }) async {
    if (!_useVodDb || !_isVodMovieFamilyItem(item)) return;
    final key =
        canonicalVodGroupKey(item) ?? VodGrouping.groupKey(item) ?? item.id;
    if (_vodFamilyHydratedKeys.contains(key) ||
        _vodFamilyHydratingKeys.contains(key)) {
      return;
    }
    _vodFamilyHydratingKeys.add(key);
    try {
      final existing = _vodFamilyOverlay[item.id];
      if (existing != null &&
          existing.length > 1 &&
          existing.any(
            (m) =>
                m.origin == MediaOrigin.iptvXtream ||
                m.origin == MediaOrigin.iptvM3u,
          )) {
        _vodFamilyHydratedKeys.add(key);
        return;
      }
      final q = VodGrouping.displayTitle(item).trim();
      if (q.length < 2) return;
      final fts = await _vodDb.searchFts(
        q,
        series: item.isSeries,
        excludeAdult: _parentalExcludeAdult(),
        limit: 120,
      );
      if (fts.isEmpty) {
        _vodFamilyHydratedKeys.add(key);
        return;
      }
      mergeVodSearchFamilyOverlay(
        vodHydrateOverlayIndex(item, fts),
        notify: notify,
      );
      _vodFamilyHydratedKeys.add(key);
    } catch (e) {
      debugPrint('hydrateVodFamilyFromDb failed: $e');
    } finally {
      _vodFamilyHydratingKeys.remove(key);
    }
  }

  MediaItem resolveVodVariant(MediaItem item) {
    final variants = vodVariantsFor(item);
    if (variants.length <= 1) {
      return variants.isEmpty ? item : variants.first;
    }
    final key = VodGrouping.preferenceKey(item);
    final preferredId = preferredVodVariants[key];
    if (preferredId != null) {
      final match = variants.cast<MediaItem?>().firstWhere(
        (v) => v?.id == preferredId,
        orElse: () => null,
      );
      if (match != null && _vodVariantTitleCompatible(item, match)) {
        return match;
      }
    }
    // Prefer a preference stored under the canonical / name sibling key.
    final canonical = canonicalVodGroupKey(item);
    if (canonical != null && canonical != key) {
      final altId = preferredVodVariants[canonical];
      if (altId != null) {
        final match = variants.cast<MediaItem?>().firstWhere(
          (v) => v?.id == altId,
          orElse: () => null,
        );
        if (match != null && _vodVariantTitleCompatible(item, match)) {
          return match;
        }
      }
    }
    final prefs = _preferredContentLangs;
    final compatible = [
      for (final v in variants)
        if (_vodVariantTitleCompatible(item, v)) v,
    ];
    final pool = compatible.isNotEmpty ? compatible : variants;
    MediaItem best = pool.first;
    var bestRank = VodGrouping.rankFor(best, preferredLangs: prefs);
    for (var i = 1; i < pool.length; i++) {
      final candidate = pool[i];
      final rank = VodGrouping.rankFor(candidate, preferredLangs: prefs);
      if (rank > bestRank) {
        best = candidate;
        bestRank = rank;
      } else if (rank == bestRank &&
          VodGrouping.compareDisplayTitle(candidate, best) < 0) {
        best = candidate;
      }
    }
    return best;
  }

  /// Language / source editions of one title — not a differently named shelf.
  bool _vodVariantTitleCompatible(MediaItem seed, MediaItem candidate) {
    if (identical(seed, candidate) || seed.id == candidate.id) return true;
    if (SeriesWatchlistTitle.titlesMatch(seed.title, candidate.title)) {
      return true;
    }
    // House-named sibling of a real show (or the reverse) is a different card.
    if (SeriesWatchlistTitle.isPlatformLabel(seed.title) !=
        SeriesWatchlistTitle.isPlatformLabel(candidate.title)) {
      return false;
    }
    return SeriesWatchlistTitle.titlesMatch(
      VodGrouping.displayTitle(seed),
      VodGrouping.displayTitle(candidate),
    );
  }

  List<MediaItem> collapseVodVariants(List<MediaItem> items) {
    final seen = <String>{};
    final out = <MediaItem>[];
    _ensureVodVariantIndex();
    for (final item in items) {
      if (!_isVodMovieFamilyItem(item)) {
        out.add(item);
        continue;
      }
      final key = canonicalVodGroupKey(item);
      if (key == null) {
        out.add(item);
        continue;
      }
      if (!seen.add(key)) continue;
      out.add(resolveVodVariant(item));
    }
    return out;
  }

  Future<void> setPreferredVodVariant(MediaItem item) async {
    final keys = <String>{VodGrouping.preferenceKey(item)};
    final canonical = canonicalVodGroupKey(item);
    if (canonical != null) keys.add(canonical);
    // Catalog TMDB keys and IPTV name|year keys must all point at the same
    // stream — otherwise a Panel-opened title ignores a catalog chip tap.
    for (final sibling in vodVariantsFor(item)) {
      keys.add(VodGrouping.preferenceKey(sibling));
      final siblingCanonical = canonicalVodGroupKey(sibling);
      if (siblingCanonical != null) keys.add(siblingCanonical);
    }
    preferredVodVariants = {
      ...preferredVodVariants,
      for (final key in keys) key: item.id,
    };
    // Paint the selected chip before SharedPreferences I/O — waiting made
    // the title page feel like it reloaded on every version tap.
    notifyListeners();
    await _store.savePreferredVodVariants(preferredVodVariants);
  }

  /// Load Xtream VOD/series disk cache into memory.
  ///
  /// Safe to call often; shares one in-flight future. Catalog / Search / index
  /// ensure paths use zero [delay]; Home idle warm uses a long delay so first
  /// paint stays free. A later zero-delay caller opens the delay gate.
  Future<void> ensureVodDiskHydrated({Duration delay = Duration.zero}) =>
      _hydrateVodCacheFromDisk(delay: delay);

  Future<void> _hydrateVodCacheFromDisk({
    Duration delay = const Duration(seconds: 2),
  }) async {
    if (_vodDiskHydrated) return;
    // Catalog / Search open the existing SQLite catalog immediately. Home idle
    // warm can start before bootstrap knows sources, leaving [_useVodDb] false
    // and the in-flight hydrate on the JSON path for 45s — every shelf spins.
    if (delay <= Duration.zero && !_useVodDb && !kIsWeb) {
      await _maybeMigrateVodJsonToDb();
      if (_vodDiskHydrated) {
        final gate = _vodHydrateDelayGate;
        if (gate != null && !gate.isCompleted) gate.complete();
        return;
      }
    }
    // Demand (delay: zero) should not sit behind Home's idle paint delay.
    if (delay <= Duration.zero) {
      final gate = _vodHydrateDelayGate;
      if (gate != null && !gate.isCompleted) {
        JavpLog.i(
          'vod',
          'disk hydrate demand opens idle gate '
              'queue=${_bgQueue.pendingCount}',
        );
        gate.complete();
      }
    }
    final existing = _vodHydrateFuture;
    if (existing != null) {
      JavpLog.i(
        'vod',
        'disk hydrate join in-flight delayMs=${delay.inMilliseconds} '
            'idleWaiting=$_vodHydrateIdleWaiting '
            'queue=${_bgQueue.pendingCount}',
      );
      await existing;
      return;
    }

    final future = _runVodDiskHydrate(delay: delay);
    _vodHydrateFuture = future;
    // Don't bump Catalog busy for idle-delay-only — wait until parse starts.
    if (delay <= Duration.zero) {
      _bumpVodBusy();
    }
    try {
      await future;
    } finally {
      if (identical(_vodHydrateFuture, future)) {
        _vodHydrateFuture = null;
        _vodHydrateIdleWaiting = false;
        _bumpVodBusy();
      }
    }
  }
}
