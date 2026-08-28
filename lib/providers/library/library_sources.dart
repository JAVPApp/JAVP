part of '../library_provider.dart';

extension LibrarySources on LibraryProvider {
  /// Refetch playlists / catalogs for sources that have no local rows yet.
  ///
  /// Profile sync deliberately omits the catalog cache (too large / churny).
  /// After restore, sources land with an empty shelf until each is synced —
  /// this walks them in the background so Home fills in without a manual tap.
  ///
  /// Live-only M3U / Xtream / media-server rows live in SQLite (or stamped
  /// [IptvSource.channelCount] / [IptvSource.lastSyncedAt]) — counting
  /// [catalog] alone used to treat every warm IPTV source as empty and
  /// soft-sync m3u+xtream (+ EPG + live-category storm) after every Drive pull.
  Future<void> rebuildCatalogFromSources({bool onlyIfEmpty = true}) async {
    // Don't soft-sync under Accueil stagger / Drive merge paint.
    await waitUntilHomeRevealSettled();
    if (_disposed) return;
    // Profile sync can run before JSON→SQLite migrate latches [_useVodDb].
    // Without this, a warm custom dump looks empty and re-fetches (UI freeze).
    if (!kIsWeb) await _maybeMigrateVodJsonToDb();
    await _refreshLiveDbSourceIds();
    if (_useVodDb) await _refreshVodDbSourceIds();
    await _pruneUnknownSourceCaches();

    final counts = <String, int>{};
    for (final m in catalog) {
      final sid = m.sourceId;
      if (sid == null) continue;
      counts[sid] = (counts[sid] ?? 0) + 1;
    }

    final pending = <IptvSource>[];
    for (final source in sources) {
      if (!source.enabled) continue;
      if (source.id == LibraryProvider.demoSourceId) continue;
      if (onlyIfEmpty && !_sourceShelfLooksEmpty(source, counts)) continue;
      if (onlyIfEmpty &&
          skipRecentEmptyHeavySyncRetry(
            type: source.type,
            looksEmpty: true,
            lastSyncedAt: source.lastSyncedAt,
            now: DateTime.now(),
            staleAfter: LibraryProvider._idleSourceSyncStale,
          )) {
        continue;
      }
      pending.add(source);
    }
    if (pending.isEmpty) {
      JavpLog.i(
        'source',
        'rebuildCatalog skip reason=profile-sync (shelves warm) '
            'sources=${sources.where((s) => s.enabled).length}',
      );
      // Catalog already present (e.g. partial local cache) — still try to
      // re-link history that arrived via sync with stale source ids.
      await _healOrphanedSourceIds();
      return;
    }

    // Accueil-facing catalogs first; live IPTV / XMLTV can wait a beat.
    pending.sort((a, b) {
      int rank(IptvSource s) {
        if (s.type == IptvSourceType.custom || s.type.isMediaServer) return 0;
        if (s.type == IptvSourceType.xmltv) return 2;
        return 1;
      }

      final d = rank(a).compareTo(rank(b));
      if (d != 0) return d;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    JavpLog.i(
      'source',
      'rebuildCatalog start reason=profile-sync n=${pending.length} '
          'kinds=${pending.map((s) => s.type.name).join(",")}',
    );

    // One at a time so restore doesn't stampede IPTV / Drive / media servers.
    for (var i = 0; i < pending.length; i++) {
      final source = pending[i];
      if (_sourceById(source.id) == null) continue;
      try {
        // Force VOD only when the shelf is actually empty — profile sync used
        // to stampede soft-sync → force prefetch even with a fresh DB.
        // IPTV live fill first after Drive restore. Xtream VOD (100k+) waits
        // for idle warm so profile sync does not ingest the catalog on the
        // same wave as the live list.
        final needVod =
            !_hasVodCacheFor(source) &&
            source.type != IptvSourceType.xtream &&
            source.type != IptvSourceType.stalker;
        await syncSource(
          source.id,
          blockUi: false,
          refreshVod: needVod,
          reason: 'rebuild-catalog',
        );
      } catch (_) {
        // Partial catalogs are fine; Sources → Sync retries.
      }
      // Yield between sources so Accueil / EPG / Drive paint can breathe.
      if (i + 1 < pending.length) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
    JavpLog.i(
      'source',
      'rebuildCatalog done reason=profile-sync n=${pending.length}',
    );
    await _healOrphanedSourceIds();
  }

  Future<void> addM3uSource({
    required String name,
    required String playlistUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool acceptXtreamPlaylistExport = false,
  }) async {
    final url = playlistUrl.trim();
    await _probeM3uPlaylist(
      url,
      acceptXtreamPlaylistExport: acceptXtreamPlaylistExport,
    );
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? 'M3U Source' : name.trim(),
      type: IptvSourceType.m3u,
      createdAt: DateTime.now(),
      playlistUrl: url,
      epgUrl: epgUrl?.trim().isEmpty == true ? null : epgUrl?.trim(),
      epgSourceId: epgSourceId?.trim().isEmpty == true
          ? null
          : epgSourceId?.trim(),
      epgEnabled: epgEnabled,
    );
    // Full playlist download/parse can take minutes — don't block the add sheet.
    // Also defer until Accueil settle so TV pairing → Home doesn't race sync.
    await _upsertSourceByDedupe(source, reason: 'add-m3u');
  }

  Future<void> addXmltvSource({
    required String name,
    required String epgUrl,
  }) async {
    final url = epgUrl.trim();
    if (url.isEmpty) throw Exception('Enter an EPG / XMLTV URL or local file');
    await _probeEpgLocation(url);
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? 'EPG / XMLTV' : name.trim(),
      type: IptvSourceType.xmltv,
      createdAt: DateTime.now(),
      epgUrl: url,
    );
    await _upsertSourceByDedupe(source, reason: 'add-xmltv');
  }

  Future<void> addXtreamSource({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
    String? alternateServerUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool vodEnabled = true,
  }) async {
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? 'Xtream Source' : name.trim(),
      type: IptvSourceType.xtream,
      createdAt: DateTime.now(),
      serverUrl: serverUrl.trim(),
      alternateServerUrl: alternateServerUrl?.trim(),
      username: username.trim(),
      password: password,
      epgUrl: epgUrl?.trim().isEmpty == true ? null : epgUrl?.trim(),
      epgSourceId: epgSourceId?.trim().isEmpty == true
          ? null
          : epgSourceId?.trim(),
      epgEnabled: epgEnabled,
      vodEnabled: vodEnabled,
    );
    // Auth is the validity check; channel indexing continues in the background.
    final auth = await _xtream.authenticate(source);
    final resolved = '${auth['_resolved_server_url'] ?? serverUrl}'.trim();
    final ready = source.copyWith(serverUrl: resolved);
    await _upsertSourceByDedupe(ready, reason: 'add-xtream');
  }

  Future<void> addStalkerSource({
    required String name,
    required String portalUrl,
    required String macAddress,
    String? serial,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
  }) async {
    final mac = StalkerClient.normalizeMac(macAddress);
    final serialTrim = serial?.trim();
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? 'Stalker Source' : name.trim(),
      type: IptvSourceType.stalker,
      createdAt: DateTime.now(),
      serverUrl: portalUrl.trim(),
      username: mac,
      password: (serialTrim == null || serialTrim.isEmpty) ? null : serialTrim,
      epgUrl: epgUrl?.trim().isEmpty == true ? null : epgUrl?.trim(),
      epgSourceId: epgSourceId?.trim().isEmpty == true
          ? null
          : epgSourceId?.trim(),
      epgEnabled: epgEnabled,
    );
    await _stalker.authenticate(source);
    await _upsertSourceByDedupe(source, reason: 'add-stalker');
  }

  Future<void> addCustomCatalogSource({
    required String name,
    required String catalogUrl,
    String? authToken,
    String? vastUrl,
  }) async {
    final location = catalogUrl.trim();
    final token = authToken?.trim();
    await _probeCatalogLocation(location, authToken: token);
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? 'Custom catalog' : name.trim(),
      type: IptvSourceType.custom,
      createdAt: DateTime.now(),
      playlistUrl: location,
      password: (token == null || token.isEmpty) ? null : token,
      vastUrl: LibraryProvider._readSourceVastUrl(vastUrl),
    );
    // Soft + deferred: pairing HTTP must return before catalog sync.
    await _upsertSourceByDedupe(source, reason: 'add-custom');
  }

  /// Seeds [LibraryProvider.demoSourceId] from the bundled asset (idempotent).
  Future<void> loadDemoCatalog() async {
    final existing = sources
        .where((s) => s.id == LibraryProvider.demoSourceId)
        .toList();
    if (existing.isEmpty) {
      final source = IptvSource(
        id: LibraryProvider.demoSourceId,
        name: 'Demo — open media',
        type: IptvSourceType.custom,
        createdAt: DateTime.now(),
        playlistUrl: LibraryProvider.demoCatalogUrl,
        color: nextDefaultSourceColor(
          sources.map((s) => s.color),
          existingCount: sources.length,
        ),
      );
      sources = [...sources, source];
      await _store.saveSources(sources);
      _noteSyncableChange(urgent: true);
      _logSourcesFeatureSummary(reason: 'add');
    }
    await syncSource(LibraryProvider.demoSourceId);
  }

  Future<void> addMediaServerSource({
    required String name,
    required IptvSourceType type,
    required String serverUrl,
    String? username,
    String? password,
    String? alternateServerUrl,
    List<String> extraServerUrls = const [],
    String? plexAccountToken,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
  }) async {
    assert(type.isMediaServer);
    final attached = epgSourceId?.trim();
    final inline = epgUrl?.trim();
    final source = IptvSource(
      id: LibraryProvider._uuid.v4(),
      name: name.trim().isEmpty ? type.name : name.trim(),
      type: type,
      createdAt: DateTime.now(),
      serverUrl: serverUrl.trim(),
      alternateServerUrl: alternateServerUrl?.trim().isEmpty == true
          ? null
          : alternateServerUrl?.trim(),
      extraServerUrls: extraServerUrls,
      username: username?.trim(),
      password: password,
      plexAccountToken: plexAccountToken,
      epgUrl: (inline == null || inline.isEmpty) ? null : inline,
      epgSourceId: (attached == null || attached.isEmpty) ? null : attached,
      epgEnabled: epgEnabled,
    );
    final client = _clientFor(type);
    if (type == IptvSourceType.plex) {
      _plex.clientIdentifier = await _plexClientIdentifier();
    }
    final session = type == IptvSourceType.plex
        ? await _plex.authenticate(
            source,
            preferredBase: await _store.loadPlexActiveUrl(source.id),
          )
        : await client.authenticate(source);
    final ready = source.copyWith(name: session.serverName ?? source.name);
    // Soft + deferred: pairing must not await full media-server sync.
    // Soft-sync end schedules XMLTV reload when the source contributes a feed.
    final saved = await _upsertSourceByDedupe(
      ready,
      reason: 'add-media-server',
    );
    _serverSessions[saved.id] = session;
    if (type == IptvSourceType.plex) {
      final base = session.baseUrl;
      if (base != null && base.isNotEmpty) {
        _plex.rememberResolvedBase(saved.id, base);
        await _store.savePlexActiveUrl(saved.id, base);
      }
      unawaited(syncPlexWatchlist(force: true));
    }
  }

  /// Updates the display name only; catalog items key off [sourceId].
  Future<void> renameSource(String sourceId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    if (sources[index].name == trimmed) return;
    final next = [...sources];
    next[index] = sources[index].copyWith(name: trimmed);
    sources = next;
    _sourceNameById = null;
    _sourceNameIndexRef = null;
    _sourcesAppearanceStamp++;
    // Pierce one notify like [_bumpVodBusy] — do not drop [_uiQuiet], or
    // ingest/prefetch notifies rematerialize Home / Catalog / TV mid-work.
    _notifyPierceQuiet();
    await _store.saveSources(sources);
    _noteSyncableChange(urgent: true);
  }

  /// Updates connection details for an existing source and re-syncs.
  ///
  /// Empty [password] keeps the stored secret. Catalog / live rows stay keyed
  /// by [sourceId] so history and watchlist keep working after edits.
  ///
  /// Pass [epgSourceId] / [epgUrl] / [epgEnabled] for M3U / Xtream / media-server
  /// EPG attach. Empty [epgSourceId] clears the attachment; empty [epgUrl]
  /// clears inline URL (including on Plex / Jellyfin / Emby).
  Future<void> updateSourceDetails({
    required String sourceId,
    required String name,
    String? playlistUrl,
    String? epgUrl,
    String? epgSourceId,
    bool? epgEnabled,
    bool? vodEnabled,
    String? serverUrl,
    String? alternateServerUrl,
    List<String>? extraServerUrls,
    String? username,
    String password = '',
    String? plexAccountToken,
    bool acceptXtreamPlaylistExport = false,
    String? vastUrl,
    bool clearVastUrl = false,
  }) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) throw Exception('Source not found');
    final current = sources[index];
    final label = name.trim().isEmpty ? current.name : name.trim();
    final nextPassword = password.isEmpty ? current.password : password;

    late final IptvSource probed;
    MediaServerSession? mediaSession;
    switch (current.type) {
      case IptvSourceType.m3u:
        final url = (playlistUrl ?? current.playlistUrl ?? '').trim();
        if (url.isEmpty) throw Exception('Enter a playlist URL or local file');
        await _probeM3uPlaylist(
          url,
          acceptXtreamPlaylistExport: acceptXtreamPlaylistExport,
        );
        final epg = epgUrl?.trim();
        final attached = epgSourceId?.trim();
        probed = IptvSource(
          id: current.id,
          name: label.isEmpty ? 'M3U Source' : label,
          type: IptvSourceType.m3u,
          createdAt: current.createdAt,
          playlistUrl: url,
          epgUrl: epgUrl == null
              ? current.epgUrl
              : ((epg == null || epg.isEmpty) ? null : epg),
          epgSourceId: epgSourceId == null
              ? current.epgSourceId
              : ((attached == null || attached.isEmpty) ? null : attached),
          epgEnabled: epgEnabled ?? current.epgEnabled,
          lastSyncedAt: current.lastSyncedAt,
          lastVodSyncedAt: current.lastVodSyncedAt,
          channelCount: current.channelCount,
          vodCount: current.vodCount,
          enabled: current.enabled,
        );
      case IptvSourceType.xmltv:
        final epg = (epgUrl ?? current.epgUrl ?? '').trim();
        if (epg.isEmpty) {
          throw Exception('Enter an EPG / XMLTV URL or local file');
        }
        await _probeEpgLocation(epg);
        probed = IptvSource(
          id: current.id,
          name: label.isEmpty ? 'EPG / XMLTV' : label,
          type: IptvSourceType.xmltv,
          createdAt: current.createdAt,
          epgUrl: epg,
          lastSyncedAt: current.lastSyncedAt,
          enabled: current.enabled,
        );
      case IptvSourceType.custom:
        final url = (playlistUrl ?? current.playlistUrl ?? '').trim();
        if (url.isEmpty) {
          throw Exception('Enter a catalog URL or local .json file path');
        }
        await _probeCatalogLocation(url, authToken: nextPassword);
        probed = IptvSource(
          id: current.id,
          name: label.isEmpty ? 'Custom catalog' : label,
          type: IptvSourceType.custom,
          createdAt: current.createdAt,
          playlistUrl: url,
          password: nextPassword,
          epgUrl: current.epgUrl,
          epgSourceId: current.epgSourceId,
          epgEnabled: current.epgEnabled,
          lastSyncedAt: current.lastSyncedAt,
          lastVodSyncedAt: current.lastVodSyncedAt,
          channelCount: current.channelCount,
          vodCount: current.vodCount,
          catalogVersion: current.catalogVersion,
          catalogCapabilities: current.catalogCapabilities,
          catalogItemCount: current.catalogItemCount,
          enabled: current.enabled,
          vastUrl: current.vastUrl,
        );
      case IptvSourceType.xtream:
        final server = (serverUrl ?? current.serverUrl ?? '').trim();
        if (server.isEmpty) throw Exception('Enter a server URL');
        final user = (username ?? current.username ?? '').trim();
        if (user.isEmpty) throw Exception('Enter a username');
        if ((nextPassword ?? '').isEmpty) {
          throw Exception('Enter a password');
        }
        final alt = alternateServerUrl?.trim();
        final epg = epgUrl?.trim();
        final attached = epgSourceId?.trim();
        final candidate = IptvSource(
          id: current.id,
          name: label.isEmpty ? 'Xtream Source' : label,
          type: IptvSourceType.xtream,
          createdAt: current.createdAt,
          serverUrl: server,
          alternateServerUrl: (alt == null || alt.isEmpty) ? null : alt,
          username: user,
          password: nextPassword,
          epgUrl: epgUrl == null
              ? current.epgUrl
              : ((epg == null || epg.isEmpty) ? null : epg),
          epgSourceId: epgSourceId == null
              ? current.epgSourceId
              : ((attached == null || attached.isEmpty) ? null : attached),
          epgEnabled: epgEnabled ?? current.epgEnabled,
          lastSyncedAt: current.lastSyncedAt,
          lastVodSyncedAt: current.lastVodSyncedAt,
          channelCount: current.channelCount,
          vodCount: current.vodCount,
          enabled: current.enabled,
          vodEnabled: vodEnabled ?? current.vodEnabled,
        );
        final auth = await _xtream.authenticate(candidate);
        final resolved = '${auth['_resolved_server_url'] ?? server}'.trim();
        probed = candidate.copyWith(serverUrl: resolved);
      case IptvSourceType.stalker:
        final portal = (serverUrl ?? current.serverUrl ?? '').trim();
        if (portal.isEmpty) throw Exception('Enter a portal URL');
        final macRaw = (username ?? current.username ?? '').trim();
        if (macRaw.isEmpty) throw Exception('Enter a MAC address');
        final mac = StalkerClient.normalizeMac(macRaw);
        final serialOpt = nextPassword?.trim();
        final epg = epgUrl?.trim();
        final attached = epgSourceId?.trim();
        final candidate = IptvSource(
          id: current.id,
          name: label.isEmpty ? 'Stalker Source' : label,
          type: IptvSourceType.stalker,
          createdAt: current.createdAt,
          serverUrl: portal,
          username: mac,
          password: (serialOpt == null || serialOpt.isEmpty) ? null : serialOpt,
          epgUrl: epgUrl == null
              ? current.epgUrl
              : ((epg == null || epg.isEmpty) ? null : epg),
          epgSourceId: epgSourceId == null
              ? current.epgSourceId
              : ((attached == null || attached.isEmpty) ? null : attached),
          epgEnabled: epgEnabled ?? current.epgEnabled,
          lastSyncedAt: current.lastSyncedAt,
          lastVodSyncedAt: current.lastVodSyncedAt,
          channelCount: current.channelCount,
          vodCount: current.vodCount,
          enabled: current.enabled,
        );
        await _stalker.authenticate(candidate);
        probed = candidate;
      case IptvSourceType.jellyfin:
      case IptvSourceType.emby:
      case IptvSourceType.plex:
        final server = (serverUrl ?? current.serverUrl ?? '').trim();
        if (server.isEmpty) throw Exception('Enter a server URL');
        if ((nextPassword ?? '').isEmpty) {
          throw Exception(
            current.type == IptvSourceType.plex
                ? 'Enter an X-Plex-Token'
                : 'Enter a password',
          );
        }
        final epg = epgUrl?.trim();
        final attached = epgSourceId?.trim();
        final candidate = IptvSource(
          id: current.id,
          name: label.isEmpty ? current.type.name : label,
          type: current.type,
          createdAt: current.createdAt,
          serverUrl: server,
          alternateServerUrl: extraServerUrls != null
              ? alternateServerUrl
              : (alternateServerUrl ?? current.alternateServerUrl),
          extraServerUrls: extraServerUrls ?? current.extraServerUrls,
          username: (username ?? current.username)?.trim(),
          password: nextPassword,
          plexAccountToken: plexAccountToken ?? current.plexAccountToken,
          epgUrl: epgUrl == null
              ? current.epgUrl
              : ((epg == null || epg.isEmpty) ? null : epg),
          epgSourceId: epgSourceId == null
              ? current.epgSourceId
              : ((attached == null || attached.isEmpty) ? null : attached),
          epgEnabled: epgEnabled ?? current.epgEnabled,
          lastSyncedAt: current.lastSyncedAt,
          lastVodSyncedAt: current.lastVodSyncedAt,
          channelCount: current.channelCount,
          vodCount: current.vodCount,
          enabled: current.enabled,
        );
        if (current.type == IptvSourceType.plex) {
          _plex.clientIdentifier = await _plexClientIdentifier();
          mediaSession = await _plex.authenticate(
            candidate,
            preferredBase: await _store.loadPlexActiveUrl(current.id),
          );
        } else {
          mediaSession = await _clientFor(current.type).authenticate(candidate);
        }
        probed = candidate.copyWith(
          name: mediaSession.serverName ?? candidate.name,
        );
    }

    _serverSessions.remove(sourceId);
    if (mediaSession != null) {
      _serverSessions[sourceId] = mediaSession;
      final base = mediaSession.baseUrl;
      if (probed.type == IptvSourceType.plex &&
          base != null &&
          base.isNotEmpty) {
        _plex.rememberResolvedBase(sourceId, base);
        await _store.savePlexActiveUrl(sourceId, base);
      }
    }
    // Drop deep-sync bookkeeping so a new URL is walked again.
    if (_deepSyncedSourceIds.remove(sourceId)) {
      await _store.saveDeepSyncedSourceIds(_deepSyncedSourceIds.toList());
    }

    final next = [...sources];
    next[index] = probed.copyWith(
      color: current.color,
      vastUrl: clearVastUrl
          ? null
          : (LibraryProvider._readSourceVastUrl(vastUrl) ?? current.vastUrl),
      clearVastUrl: clearVastUrl,
    );
    sources = next;
    await _store.saveSources(sources);
    notifyListeners();
    _noteSyncableChange(urgent: true);

    if (probed.type == IptvSourceType.m3u ||
        probed.type == IptvSourceType.xtream ||
        probed.type == IptvSourceType.stalker ||
        probed.type == IptvSourceType.xmltv) {
      unawaited(syncSource(sourceId, blockUi: false, refreshVod: true));
    } else {
      await syncSource(sourceId, refreshVod: true);
    }
    if (probed.type.canAttachEpg ||
        probed.type == IptvSourceType.xmltv ||
        probed.type == IptvSourceType.custom) {
      unawaited(_reloadMergedXmltvEpg());
    }
  }

  /// Hide a source from browse/search without deleting its cache.
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    if (sources[index].enabled == enabled) return;
    final next = [...sources];
    next[index] = sources[index].copyWith(enabled: enabled);
    sources = next;
    _sourcesEnabledStamp++;
    _cachedLiveChannels = null;
    _liveGroupCountsCache = null;
    _liveGroupNamesCache = null;
    _invalidateHomeShelfCaches();
    _sourcesRestored = true;
    _pruneHomeShelfSnapshotToVisibleSources();
    _cachedOnNow = null;
    await _store.saveSources(sources);
    // Prefetch/EPG quiet-mode can latch and swallow notifies — same as remove.
    _uiQuiet = false;
    notifyListeners();
    _noteSyncableChange(urgent: true);
    _logSourcesFeatureSummary(reason: 'enable');
    if (sources[index].type == IptvSourceType.xmltv ||
        sources[index].type.canAttachEpg) {
      unawaited(_reloadMergedXmltvEpg());
    }
  }

  /// Build a portable sources document for share/save (see [SourcesExportDocument]).
  ///
  /// When [sourceIds] is set, only those sources are included (unknown ids skipped).
  Future<SourcesExportDocument> buildSourcesExport({
    required SourcesSecretsMode secretsMode,
    String? passphrase,
    Set<String>? sourceIds,
  }) {
    final list = sourceIds == null
        ? sources
        : sources
              .where((s) => sourceIds.contains(s.id))
              .toList(growable: false);
    return SourcesExportDocument.create(
      sources: list,
      secretsMode: secretsMode,
      passphrase: passphrase,
    );
  }

  /// Replace or merge sources from an export file, then kick background syncs.
  Future<int> importSourcesDocument({
    required SourcesExportDocument document,
    required SourcesImportMode mode,
    String? passphrase,
  }) async {
    final imported = await document.materialize(passphrase: passphrase);
    final next = assignMissingSourceColors(
      mergeImportedSources(existing: sources, imported: imported, mode: mode),
    );
    // Drop secure entries for sources removed by replace.
    if (mode == SourcesImportMode.replace) {
      final keep = next.map((s) => s.id).toSet();
      for (final s in sources) {
        if (!keep.contains(s.id)) {
          await _store.deleteSourcePassword(s.id);
        }
      }
    }
    sources = next;
    await _store.saveSources(sources);
    _sourcesEnabledStamp++;
    _cachedLiveChannels = null;
    _liveGroupCountsCache = null;
    _liveGroupNamesCache = null;
    _invalidateHomeShelfCaches();
    _sourcesRestored = true;
    _pruneHomeShelfSnapshotToVisibleSources();
    notifyListeners();
    _noteSyncableChange(urgent: true);
    _logSourcesFeatureSummary(reason: 'import');
    final importedIds = {for (final s in imported) s.id};
    final importedKeys = {
      for (final s in imported)
        if (s.dedupeKey.isNotEmpty) s.dedupeKey,
    };
    for (final s in sources.where((s) => s.enabled)) {
      final touched =
          importedIds.contains(s.id) ||
          (s.dedupeKey.isNotEmpty && importedKeys.contains(s.dedupeKey));
      if (touched) {
        _kickSoftSyncAfterHomeReady(s.id, reason: 'import');
      }
    }
    return sources.length;
  }

  Future<void> removeSource(String sourceId) async {
    // Drop quiet-mode so this always reaches the UI (prefetch/sync can leave
    // `_uiQuiet` latched and swallow notifies).
    _uiQuiet = false;
    // Abort any in-flight VOD disk hydrate so a stale chunk loop cannot
    // re-merge rows for this source into Movies after we clear them.
    _vodHydrateEpoch++;
    _firstCatalogSyncIds.remove(sourceId);

    final removedIds = <String>{
      for (final m in catalog)
        if (m.sourceId == sourceId) m.id,
      for (final m in _vodStreamCache.values)
        if (m.sourceId == sourceId) m.id,
      for (final m in history)
        if (m.sourceId == sourceId) m.id,
      for (final m in watchlist)
        if (m.sourceId == sourceId) m.id,
    };

    sources = [
      for (final s in sources)
        if (s.id != sourceId)
          s.epgSourceId == sourceId ? s.copyWith(clearEpgSourceId: true) : s,
    ];
    catalog = catalog.where((m) => m.sourceId != sourceId).toList();
    history = history.where((m) => m.sourceId != sourceId).toList();
    watchlist = watchlist.where((m) => m.sourceId != sourceId).toList();
    localMedia = localMedia.where((m) => m.sourceId != sourceId).toList();
    _vodStreamCache.removeWhere((_, item) => item.sourceId == sourceId);
    _touchVodCache();
    if (removedIds.isNotEmpty) {
      detailsCache.removeWhere((id, _) => removedIds.contains(id));
      segmentCache.removeWhere((id, _) => removedIds.contains(id));
    }
    preferredLiveQualities.removeWhere(
      (key, _) => key.startsWith('$sourceId|'),
    );
    _sessionLiveQualities.removeWhere((key, _) => key.startsWith('$sourceId|'));
    preferredVodVariants.removeWhere((key, _) => key.contains(sourceId));

    if (sources.every(
      (s) =>
          s.type != IptvSourceType.xtream && s.type != IptvSourceType.stalker,
    )) {
      categories = [];
    } else {
      categories = categories.where((c) => c.sourceId != sourceId).toList();
    }
    vodCategoryItems = [];
    activeVodCategoryId = null;
    _epgByStreamId.clear();
    _liveIndex = null;
    _liveIndexLoadAttempted = false;
    _liveFamilyIndex = null;
    _liveFamilyKeyById = null;
    _liveGroupCountsCache = null;
    _liveGroupNamesCache = null;
    _cachedOnNow = null;
    _invalidateHomeShelfCaches();
    _sourcesRestored = true;
    _pruneHomeShelfSnapshotToVisibleSources();
    _sourceNameById = null;
    _sourceColorById = null;
    _sourceNameIndexRef = null;
    _serverSessions.remove(sourceId);

    // Immediate UI refresh (Sources list, shelves) before disk/DB work.
    notifyListeners();

    try {
      await _replaceLiveSourceInDb(sourceId: sourceId, live: const []);
      // Drop pins that no longer resolve to a channel.
      final pinned = <String>{...favoriteChannelIds, ...recentChannelIds};
      if (pinned.isNotEmpty) {
        final stillThere = await _liveDb.channelsByIds(pinned.toList());
        final alive = stillThere.map((c) => c.id).toSet();
        final nextFav = favoriteChannelIds
            .where(alive.contains)
            .toList(growable: false);
        final nextRecent = recentChannelIds
            .where(alive.contains)
            .toList(growable: false);
        if (nextFav.length != favoriteChannelIds.length ||
            nextRecent.length != recentChannelIds.length) {
          favoriteChannelIds = nextFav;
          recentChannelIds = nextRecent;
          await _store.saveFavoriteChannelIds(favoriteChannelIds);
          await _store.saveRecentChannelIds(recentChannelIds);
        }
      }
      await _reloadPinnedLiveChannels();
    } catch (_) {
      // Live DB may be empty / unused for catalog-only sources.
      _liveDbSourceIds.remove(sourceId);
      liveDbRevision++;
    }

    await Future.wait([
      _store.saveSources(sources),
      _store.deleteSourcePassword(sourceId),
      _store.saveCatalog(catalog),
      _store.saveHistory(history),
      _store.saveWatchlist(watchlist),
      _store.saveLocalMedia(localMedia),
      _store.saveCategories(categories),
      if (_useVodDb)
        _vodDb.deleteSource(sourceId).then((_) async {
          _vodDbSourceIds.remove(sourceId);
          _vodDbMovieGroupsBySource.remove(sourceId);
          _vodDbSeriesGroupsBySource.remove(sourceId);
          await _refreshVodDbCountCache();
        })
      else
        _store.saveVodCache(_vodStreamCache.values),
      _store.savePreferredLiveQualities(preferredLiveQualities),
      _store.savePreferredVodVariants(preferredVodVariants),
      _store.saveDetailsCache(detailsCache),
      _store.saveSegmentCache(segmentCache),
    ]);
    _noteSyncableChange(urgent: true);
    _logSourcesFeatureSummary(reason: 'remove');
    notifyListeners();
    unawaited(_reloadMergedXmltvEpg());
  }

  bool isSourceSyncing(String sourceId) => _syncingSourceIds.contains(sourceId);

  Future<void> syncSource(
    String sourceId, {
    bool refreshVod = false,

    /// Default false — sync must never flip global loading / wait cursor.
    /// Pass true only for rare flows that intentionally pause the shell.
    bool blockUi = false,
    String reason = 'unspecified',

    /// When true, failures (and already-running skips) propagate to the caller
    /// instead of only setting [error]. Use for UI that must show retry.
    bool rethrowErrors = false,
  }) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) {
      if (rethrowErrors) {
        throw Exception('Source not found');
      }
      return;
    }
    // Claim early so Sources shows busy while waiting for a soft slot
    // (otherwise a hung peer sync makes this look idle forever).
    if (!_syncingSourceIds.add(sourceId)) {
      JavpLog.i(
        'source',
        'sync skip already-running id=$sourceId '
            'reason=$reason blockUi=$blockUi',
      );
      HwndSyncTrace.of(sourceId)?.mark(
        'sync-skip-already-running',
        'reason=$reason',
      );
      if (rethrowErrors) {
        throw Exception('Source is already syncing');
      }
      return;
    }
    // Soft / non-button sync: still need a T0. Manual already logged click.
    if (HwndSyncTrace.of(sourceId) == null) {
      HwndSyncTrace.begin('sync-$reason', sourceId: sourceId);
    } else {
      HwndSyncTrace.of(sourceId)?.mark(
        'syncSource-enter',
        'reason=$reason blockUi=$blockUi refreshVod=$refreshVod',
      );
    }
    if (reason == 'manual') {
      _beginManualSyncFocusHold(sourceId);
      _abortOpportunisticWorkForManualSync(sourceId: sourceId);
    }
    _markFirstCatalogSyncIfNeeded(sources[index]);
    // Cap concurrent soft syncs (1 until Accueil settle, then 2) so Drive
    // rebuild + idle-source-sync never stampede the UI isolate.
    var heldSoftSlot = false;
    // Background sync already runs under [_uiQuiet] from idle warm; when
    // callers pass blockUi=false without that, still suppress shell rebuilds
    // during heavy parse/DB/save work (status text pierces via idle notify).
    final ownQuiet = !blockUi && !_uiQuiet;
    if (ownQuiet) _uiQuiet = true;
    final watch = Stopwatch()..start();
    var fetchMs = 0;
    var liveDbMs = 0;
    var saveMs = 0;
    var liveCount = 0;
    var vodCount = 0;
    var catalogTouched = true;
    IptvSource? sourceForLog;
    var syncPhase = 'start';
    final syncGen = _idleWorkGeneration;
    try {
      if (!blockUi) {
        if (_activeSoftSourceSyncs >= _maxSoftSourceSyncs) {
          _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncWaitingOther);
        }
        await _acquireSoftSourceSyncSlot(reason: reason);
        heldSoftSlot = true;
        if (_disposed || sources.indexWhere((s) => s.id == sourceId) < 0) {
          if (rethrowErrors) {
            throw Exception('Source not found');
          }
          return;
        }
      }
      final source = sources.firstWhere((s) => s.id == sourceId);
      sourceForLog = source;
      error = null;
      // Never flip global [loading] — Accueil / Catalog must stay interactive
      // during soft sync, Drive apply, and manual Sources "Sync". Per-source
      // [syncStatus] still drives the Sources row + TV status strip.
      JavpLog.i(
        'source',
        'sync start id=$sourceId type=${source.type.name} '
            'reason=$reason blockUi=$blockUi refreshVod=$refreshVod '
            'queue=${_bgQueue.pendingCount} softActive=$_activeSoftSourceSyncs',
      );
      _debugSyncPhase = '${source.type.name}:start';
      syncPhase = 'connecting';
      _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncConnecting);
      // Soft path: quiet latch swallows this; manual Sync still paints Sources.
      if (blockUi) notifyListeners();

      List<MediaItem> imported;
      String? discoveredEpg;
      var updated = source;
      var packedVodCount = -1;

      final fetch = Stopwatch()..start();
      if (source.type == IptvSourceType.m3u) {
        final playlistLocation = source.playlistUrl!;
        final local = M3uPlaylistIo.tryLocalFilePath(playlistLocation) != null;
        _setSourceSyncStatus(
          sourceId,
          local ? _uiL10n.sourceSyncReadingM3u : _uiL10n.sourceSyncFetchingM3u,
        );
        if (blockUi) {
          notifyListeners();
        } else {
          await pumpUi();
        }
        final bytes = await _loadM3uPlaylistBytes(
          playlistLocation,
          onProgress: local
              ? null
              : (n) {
                  _setSourceSyncStatus(
                    sourceId,
                    _uiL10n.sourceSyncFetchingM3uBytes(
                      LibraryProvider._formatByteSize(n),
                    ),
                  );
                },
        );
        if (!await _yieldSoftSyncToShell(
          blockUi: blockUi,
          reason: reason,
          generation: syncGen,
        )) {
          return;
        }
        _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncParsingPlaylist);
        if (blockUi) notifyListeners();
        // Large M3Us easily ANR if parsed on the UI isolate. Native sync
        // keeps live and VOD as packed SQL maps (parse + index in one worker).
        // Web has no SQLite — fall back to MediaItem hydrate.
        if (kIsWeb) {
          final parsed = await parseM3uBytesInIsolate(
            bytes,
            sourceId: source.id,
            baseDir: M3uPlaylistIo.localBaseDir(playlistLocation),
          );
          imported = parsed.items;
          _setSourceSyncStatus(
            sourceId,
            _uiL10n.sourceSyncParsedItems('${imported.length}'),
          );
          discoveredEpg = source.epgSourceId != null
              ? source.epgUrl
              : (source.epgUrl ?? parsed.epgUrl);
        } else {
          final ingested = await ingestM3uBytesInIsolate(
            bytes,
            sourceId: source.id,
            baseDir: M3uPlaylistIo.localBaseDir(playlistLocation),
            epgDisplayNames: epgChannelNames,
            preferredLiveQualities: preferredLiveQualities,
          );
          imported = const [];
          packedVodCount = ingested.vodCount;
          // Always replace live (including empty) so a playlist that dropped
          // all live rows clears SQLite ghosts and channelCount — same as VOD.
          if (ingested.liveCount > 0) {
            _setSourceSyncStatus(
              sourceId,
              _uiL10n.sourceSyncIndexingLive('${ingested.liveCount}'),
            );
            if (blockUi) notifyListeners();
          }
          final liveDb = Stopwatch()..start();
          await _replaceLiveSourceFromPacked(
            sourceId: source.id,
            plan: ingested.live,
          );
          liveDbMs = liveDb.elapsedMilliseconds;
          updated = updated.copyWith(channelCount: ingested.liveCount);
          if (ingested.vodCount > 0 || _vodDbSourceIds.contains(source.id)) {
            _setSourceSyncStatus(
              sourceId,
              _uiL10n.sourceSyncSavingVod('${ingested.vodCount}'),
            );
            if (blockUi) notifyListeners();
          }
          await _applyVodPlan(
            sourceId: source.id,
            plan: ingested.vod,
            replace: true,
          );
          _setSourceSyncStatus(
            sourceId,
            _uiL10n.sourceSyncParsedItems(
              '${ingested.liveCount + ingested.vodCount}',
            ),
          );
          discoveredEpg = source.epgSourceId != null
              ? source.epgUrl
              : (source.epgUrl ?? ingested.epgUrl);
        }
      } else if (source.type == IptvSourceType.xmltv) {
        final url = source.epgUrl?.trim();
        if (url == null || url.isEmpty) {
          throw Exception('EPG / XMLTV URL is missing');
        }
        _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncLoadingXmltv);
        if (blockUi) notifyListeners();
        imported = const [];
        discoveredEpg = null;
        fetchMs = fetch.elapsedMilliseconds;
        updated = updated.copyWith(lastSyncedAt: DateTime.now());
        final latestIndex = sources.indexWhere((s) => s.id == sourceId);
        if (latestIndex >= 0) {
          updated = updated.copyWith(enabled: sources[latestIndex].enabled);
          sources = [...sources]..[latestIndex] = updated;
        }
        await _store.saveSources(sources);
        _scheduleEpgReloadForSource(sourceId, reason: 'soft-sync:xmltv');
        JavpLog.i(
          'source',
          'sync done in ${watch.elapsedMilliseconds}ms type=xmltv',
        );
        return;
      } else if (source.type == IptvSourceType.custom) {
        final url = source.playlistUrl;
        if (url == null || url.isEmpty) {
          throw Exception('Custom catalog URL is missing');
        }
        final localPath = LocalSourcePath.tryLocalFilePath(url);
        final isLocal = localPath != null;
        _setSourceSyncStatus(
          sourceId,
          isLocal
              ? _uiL10n.sourceSyncReadingCustomCatalog
              : LibraryProvider.isAssetCatalogUrl(url)
              ? _uiL10n.sourceSyncLoadingDemoCatalog
              : _uiL10n.sourceSyncFetchingCustomCatalog,
        );
        if (blockUi) {
          notifyListeners();
        } else {
          await pumpUi();
        }
        syncPhase = 'custom-profile';
        final clientProfile = await _catalogClientProfile();
        _customCatalog.profile = clientProfile;
        final appVersion = clientProfile.appVersion;
        syncPhase = LibraryProvider.isAssetCatalogUrl(url)
            ? 'custom-asset'
            : isLocal
            ? 'custom-local'
            : 'custom-fetch';
        final parsed = LibraryProvider.isAssetCatalogUrl(url)
            ? await _parseAssetCatalog(
                url,
                sourceId: source.id,
                appVersion: appVersion,
                profile: clientProfile,
              )
            : isLocal
            ? await _parseLocalCatalog(
                url,
                sourceId: source.id,
                appVersion: appVersion,
                profile: clientProfile,
              )
            : await _customCatalog.fetchRoot(
                url,
                sourceId: source.id,
                headers: _customCatalogHeaders(source),
                appVersion: appVersion,
                profile: clientProfile,
              );
        syncPhase = 'custom-apply';
        if (!await _yieldSoftSyncToShell(
          blockUi: blockUi,
          reason: reason,
          generation: syncGen,
        )) {
          return;
        }
        final catalogLabel = _preferredCustomCatalogName(
          source: source,
          parsedName: parsed.name,
        );
        var renamedFromDefault = false;
        if (catalogLabel != null && catalogLabel != source.name) {
          updated = updated.copyWith(name: catalogLabel);
          renamedFromDefault = true;
        }
        updated = updated.copyWith(
          catalogVersion: parsed.version,
          catalogCapabilities: parsed.capabilities,
          catalogItemCount: parsed.itemCount,
        );
        discoveredEpg = source.epgSourceId != null
            ? source.epgUrl
            : (resolveCatalogEpgUrl(
                    parsed.epgUrl,
                    catalogUrl: source.playlistUrl,
                  ) ??
                  source.epgUrl);
        final catalogVast = parsed.vastUrl?.trim();
        if (catalogVast != null && catalogVast.isNotEmpty) {
          updated = updated.copyWith(vastUrl: catalogVast);
        }
        // Name upgrades used to stay device-local — the other device kept
        // seeing the placeholder "Custom catalog" after sync.
        if (renamedFromDefault) {
          _noteSyncableChange();
        }

        final fallbackGroup = () {
          final fromJson = parsed.name?.trim();
          if (fromJson != null && fromJson.isNotEmpty) return fromJson;
          return updated.name.trim();
        }();

        final packedDump = parsed.vod;
        final hasPackedDump = packedDump != null && packedDump.vodCount > 0;
        if (!kIsWeb &&
            packedDump != null &&
            (hasPackedDump || !parsed.isQueryApi)) {
          stampEmptyVodGroupNames(
            packedDump.rows,
            fallbackGroup: fallbackGroup,
          );
          _setSourceSyncStatus(
            sourceId,
            _uiL10n.sourceSyncSavingVod('${packedDump.vodCount}'),
          );
          if (blockUi) notifyListeners();
          await _applyVodPlan(
            sourceId: source.id,
            plan: packedDump,
            replace: true,
          );
          packedVodCount = packedDump.vodCount;
        }

        if (parsed.isQueryApi &&
            parsed.items.isEmpty &&
            !hasPackedDump &&
            !LibraryProvider.isAssetCatalogUrl(url) &&
            !isLocal) {
          // v2 descriptor with no warm cache — seed from /browse when available.
          try {
            final page = await _customCatalog.browse(
              baseUrl: url,
              sourceId: source.id,
              limit: 120,
              locale: _catalogLocaleParam,
              headers: _customCatalogHeaders(source),
            );
            imported = page.items;
            if (page.details.isNotEmpty) {
              detailsCache = {...detailsCache, ...page.details};
              _schedulePersist(_PersistTarget.detailsCache);
            }
            _setSourceSyncStatus(
              sourceId,
              imported.isEmpty
                  ? _uiL10n.sourceSyncQueryCatalogSearchToLoad(
                      '${parsed.version}',
                      parsed.itemCount?.toString() ?? _uiL10n.sourceSyncRemote,
                    )
                  : _uiL10n.sourceSyncSeededFromBrowse('${imported.length}'),
            );
          } catch (_) {
            imported = catalog.where((m) => m.sourceId == source.id).toList();
            _setSourceSyncStatus(
              sourceId,
              _uiL10n.sourceSyncQueryCatalog(
                '${parsed.version}',
                parsed.itemCount?.toString() ?? _uiL10n.sourceSyncRemote,
              ),
            );
          }
        } else {
          imported = parsed.items;
          // Seed details (cast / trailer / seasons) from the dump.
          if (parsed.details.isNotEmpty) {
            detailsCache = LibraryProvider.mergeCatalogDetails(
              detailsCache,
              parsed.details,
            );
            _schedulePersist(_PersistTarget.detailsCache);
          }
          // Prefer catalog-provided skip segments.
          Map<String, MediaSegmentBundle>? nextSegments;
          final segmentNow = DateTime.now();
          for (final item in imported) {
            if (!item.hasCatalogSegments) continue;
            nextSegments ??= Map<String, MediaSegmentBundle>.of(segmentCache);
            final key = 'catalog:${item.id}';
            nextSegments[key] = MediaSegmentBundle(
              key: key,
              segments: item.segments,
              fetchedAt: segmentNow,
            );
          }
          if (nextSegments != null) {
            segmentCache = nextSegments;
            _schedulePersist(_PersistTarget.segmentCache);
          }
          _setSourceSyncStatus(
            sourceId,
            LibraryProvider.isAssetCatalogUrl(url)
                ? _uiL10n.sourceSyncDemoItems('${imported.length}')
                : _uiL10n.nItems('${imported.length}'),
          );
        }
        if (!kIsWeb && packedVodCount < 0) {
          if (fallbackGroup.isNotEmpty) {
            imported = [
              for (final item in imported)
                (item.kind == MediaKind.vod || item.kind == MediaKind.series) &&
                        (item.group == null || item.group!.trim().isEmpty)
                    ? item.copyWith(group: fallbackGroup)
                    : item,
            ];
          }
          final taken = await _takeImportedVodToSqlite(
            sourceId: source.id,
            imported: imported,
            replace: !parsed.isQueryApi,
          );
          imported = taken.rest;
          if (taken.count >= 0) packedVodCount = taken.count;
        }
      } else if (source.type.isMediaServer) {
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncConnectingTo(source.type.name),
        );
        notifyListeners();
        _lastMediaServerLiveFetchOk = null;
        imported = await _syncMediaServerLibraries(source);
        if (!kIsWeb) {
          final taken = await _takeImportedVodToSqlite(
            sourceId: source.id,
            imported: imported,
            replace: true,
          );
          imported = taken.rest;
          if (taken.count >= 0) packedVodCount = taken.count;
        }
        final liveCount = imported
            .where((m) => m.kind == MediaKind.live)
            .length;
        final titleCount = packedVodCount >= 0
            ? packedVodCount
            : imported.length - liveCount;
        final liveFailed =
            source.type.isMediaServer && _lastMediaServerLiveFetchOk == false;
        _setSourceSyncStatus(
          sourceId,
          liveFailed
              ? _uiL10n.sourceSyncTitlesLiveFailed('$titleCount')
              : liveCount > 0
              ? _uiL10n.sourceSyncTitlesAndLive('$titleCount', '$liveCount')
              : _uiL10n.sourceSyncTitlesPagedLibraries('$titleCount'),
        );
      } else if (source.type == IptvSourceType.stalker) {
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncLiveChannelsCategories,
        );
        notifyListeners();
        final result = await _stalker.syncCatalog(source);
        discoveredEpg = source.epgSourceId != null
            ? source.epgUrl
            : source.epgUrl;
        final incoming = [
          ...result.liveCategories,
          ...result.vodCategories,
          ...result.seriesCategories,
        ];
        categories = [
          ...categories.where(
            (c) => c.sourceId != null && c.sourceId != source.id,
          ),
          ...incoming,
        ];
        await _store.saveCategories(categories);
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncIndexingLiveCategories(
            '${result.live.length}',
            '${result.liveCategories.length}',
          ),
        );
        if (blockUi) notifyListeners();
        if (!await _yieldSoftSyncToShell(
          blockUi: blockUi,
          reason: reason,
          generation: syncGen,
        )) {
          return;
        }
        final liveDb = Stopwatch()..start();
        await _replaceLiveSourceInDb(sourceId: source.id, live: result.live);
        liveDbMs = liveDb.elapsedMilliseconds;
        imported = const [];
        updated = updated.copyWith(channelCount: result.live.length);
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncLiveCount('${result.live.length}'),
        );
      } else {
        _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncLiveCategories);
        notifyListeners();
        // Categories now — full live dump merges in the background. TV can
        // still demand-load one group via get_live_streams?category_id=.
        final result = await _xtream.syncCatalog(
          source,
          includeLiveStreams: false,
        );
        HwndSyncTrace.of(sourceId)?.mark('syncCatalog-apply-start');
        // Paint "categories done" before any follow-on work so Sources matches
        // the log timeline (status used to stay on catégories until EPG finished).
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncLiveCategoriesCount(
            '${result.liveCategories.length}',
          ),
        );
        await pumpUi(label: 'sync-cats-painted');
        // Prefer a known guide URL. Full download used to run here and freeze
        // the HWND while status still said "Synchronisation des catégories".
        discoveredEpg = source.epgSourceId != null
            ? source.epgUrl
            : (source.epgUrl != null && source.epgUrl!.trim().isNotEmpty
                  ? source.epgUrl
                  : await _resolveXtreamEpgUrl(
                      source.copyWith(
                        serverUrl: result.activeServerUrl ?? source.serverUrl,
                      ),
                      fallback: result.epgUrl ?? source.epgUrl,
                    ));
        HwndSyncTrace.of(sourceId)?.mark('syncCatalog-epg-done');
        // Merge this source's categories; keep other sources' lists so
        // multi-Xtream panels don't wipe each other (ids collide across panels).
        final incoming = [
          ...result.liveCategories,
          if (source.vodEnabled) ...result.vodCategories,
          if (source.vodEnabled) ...result.seriesCategories,
        ];
        final nextCategories = [
          // Drop other rows for this source, and legacy rows without sourceId
          // (pre-multi-source) so they don't shadow the tagged list forever.
          ...categories.where(
            (c) => c.sourceId != null && c.sourceId != source.id,
          ),
          ...incoming,
        ];
        // Keep list identity when soft sync returns the same chip set — TV
        // listens to categories.length / liveDbRevision and rematerializes.
        if (!_iptvCategoriesEquivalent(categories, nextCategories)) {
          categories = nextCategories;
          HwndSyncTrace.of(sourceId)?.mark('save-categories-start');
          await _store.saveCategories(categories);
          await pumpUi(label: 'sync-save-categories');
          HwndSyncTrace.of(sourceId)?.mark('save-categories-done');
          // Direct's scoped stamp used to ignore category rows, so chips
          // stayed empty until a live DB write. Bump so TV reloads groups.
          liveDbRevision++;
          _notifyListenersAfterIdle();
        }

        if (result.activeServerUrl != null &&
            result.activeServerUrl != source.serverUrl) {
          updated = updated.copyWith(serverUrl: result.activeServerUrl);
        }
        HwndSyncTrace.of(sourceId)?.mark('count-channels-start');
        // Never block Synchroniser on COUNT(*) — a fat VOD DB job on the
        // shared sqflite_ffi isolate made this wait 20–40s with no status
        // paint, then jump to "Démarrage du cache VOD" when it unblocked.
        final cachedLive = updated.channelCount;
        late final int liveCount;
        if (cachedLive > 0) {
          liveCount = cachedLive;
          HwndSyncTrace.of(sourceId)?.mark(
            'count-channels-cached',
            'n=$liveCount',
          );
        } else {
          final hb = Timer.periodic(const Duration(milliseconds: 50), (_) {
            unawaited(pumpUi(label: 'count-channels'));
          });
          try {
            liveCount = await _liveDb.countChannels(sourceId: source.id);
          } finally {
            hb.cancel();
          }
          await pumpUi(label: 'sync-count-channels');
          HwndSyncTrace.of(sourceId)?.mark(
            'count-channels-done',
            'n=$liveCount',
          );
        }
        imported = const [];
        updated = updated.copyWith(
          channelCount: liveCount > 0 ? liveCount : updated.channelCount,
        );
        // Manual Synchroniser always re-checks get_live_streams (fingerprint
        // skip still avoids rewrite when unchanged). Soft/idle may skip when
        // the SQLite dump is within [_liveCategoryFreshness].
        final refreshLive = reason == 'manual' ||
            await _shouldNetworkRefreshLive(
              updated,
              liveCount: liveCount,
            );
        if (refreshLive) {
          _xtreamLiveCategoriesEpoch[source.id] =
              (_xtreamLiveCategoriesEpoch[source.id] ?? 0) + 1;
          _liveCategoryFilledEpoch.removeWhere(
            (key, _) => key.startsWith('${source.id}|'),
          );
          unawaited(prefetchXtreamLiveCategories(updated));
        } else {
          final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
          for (final cat in categories) {
            if (cat.kind != IptvCategoryKind.live ||
                cat.sourceId != source.id) {
              continue;
            }
            _liveCategoryFilledEpoch['${source.id}|${cat.id}'] = epoch;
          }
          JavpLog.i(
            'tv',
            'soft sync skip live dump — cache fresh '
                'source=${source.id} n=$liveCount',
          );
          HwndSyncTrace.of(sourceId)?.mark(
            'live-skip-fresh',
            'n=$liveCount soft=true',
          );
        }
        HwndSyncTrace.of(sourceId)?.mark('syncCatalog-apply-done');
      }
      fetchMs = fetch.elapsedMilliseconds;

      if (!await _yieldSoftSyncToShell(
        blockUi: blockUi,
        reason: reason,
        generation: syncGen,
      )) {
        return;
      }

      final liveImported = <MediaItem>[];
      final nonLiveImported = <MediaItem>[];
      final split = Stopwatch()..start();
      for (var i = 0; i < imported.length; i++) {
        final m = imported[i];
        if (m.kind == MediaKind.live) {
          liveImported.add(m);
        } else {
          nonLiveImported.add(m);
        }
        await yieldUiSlice(
          split,
          i: i,
          checkMask: 255,
          label: 'sync-split-live',
        );
      }
      // Media servers replace Live only after a successful listing
      // (empty = clear). A failed listing keeps the previous Live DB.
      final shouldReplaceLive =
          liveImported.isNotEmpty ||
          (source.type.isMediaServer && _lastMediaServerLiveFetchOk == true);
      if (shouldReplaceLive) {
        _setSourceSyncStatus(
          sourceId,
          _uiL10n.sourceSyncIndexingLive('${liveImported.length}'),
        );
        if (blockUi) notifyListeners();
        final liveDb = Stopwatch()..start();
        if (kIsWeb) {
          // No SQLite on web — leave live rows in [imported]/[catalog].
          JavpLog.i(
            'live',
            'web catalog live keep count=${liveImported.length} '
                'sourceId=${source.id}',
          );
        } else {
          await _replaceLiveSourceInDb(sourceId: source.id, live: liveImported);
          imported = nonLiveImported;
        }
        liveDbMs = liveDb.elapsedMilliseconds;
        updated = updated.copyWith(channelCount: liveImported.length);
        // Let frames run before a possible full-catalog rewrite.
        await yieldAfterIsolateChunk();
      } else {
        imported = nonLiveImported;
      }

      final preservedOnDemand =
          source.type == IptvSourceType.xtream ||
              source.type == IptvSourceType.stalker
          ? await filterYielding(
              catalog,
              (m) =>
                  m.sourceId == source.id &&
                  (m.kind == MediaKind.vod || m.kind == MediaKind.series),
              label: 'sync-preserved-ondemand',
            )
          : const <MediaItem>[];

      // Live-only M3U/Xtream updates must not rewrite the whole VOD/catalog
      // file — that was ~4s of UI-isolate toJson for zero content change.
      final priorCatalogIds = <String>{};
      final idSlice = Stopwatch()..start();
      for (var i = 0; i < catalog.length; i++) {
        final m = catalog[i];
        if (m.sourceId == source.id) priorCatalogIds.add(m.id);
        await yieldUiSlice(idSlice, i: i, label: 'sync-prior-catalog-ids');
      }
      final nextCatalogIds = <String>{
        for (final m in imported) m.id,
        for (final m in preservedOnDemand) m.id,
      };
      catalogTouched =
          priorCatalogIds.length != nextCatalogIds.length ||
          !priorCatalogIds.containsAll(nextCatalogIds);

      if (catalogTouched) {
        final kept = await filterYielding(
          catalog,
          (m) => m.sourceId != source.id,
          label: 'sync-catalog-keep',
        );
        catalog = [...kept, ...imported, ...preservedOnDemand];
      }
      if (source.type == IptvSourceType.xtream ||
          source.type == IptvSourceType.stalker) {
        vodCategoryItems = [];
        activeVodCategoryId = null;
      }

      final vodImported = !catalogTouched
          ? source.vodCount
          : catalog
                .where(
                  (m) => m.sourceId == source.id && m.kind == MediaKind.vod,
                )
                .length;
      final seriesImported = !catalogTouched
          ? 0
          : catalog
                .where(
                  (m) => m.sourceId == source.id && m.kind == MediaKind.series,
                )
                .length;
      // Custom / media-server catalogs are mostly series shells; count both.
      final onDemandCount = catalogTouched
          ? vodImported + seriesImported
          : source.vodCount;
      // Xtream movies/series live in [_vodStreamCache], not [catalog]. Live-only
      // sync must not clobber the last prefetch count with catalog zeros.
      final iptvVodCount =
          source.type == IptvSourceType.xtream ||
              source.type == IptvSourceType.stalker
          ? _vodCountForSource(source.id, fallback: source.vodCount)
          : onDemandCount;
      updated = updated.copyWith(
        lastSyncedAt: DateTime.now(),
        channelCount: updated.channelCount > 0
            ? updated.channelCount
            : liveImported.length,
        vodCount: packedVodCount >= 0
            ? packedVodCount
            : source.type == IptvSourceType.m3u
            ? (catalogTouched ? vodImported : source.vodCount)
            : iptvVodCount,
        lastVodSyncedAt: packedVodCount >= 0
            ? DateTime.now()
            : updated.lastVodSyncedAt,
        epgUrl: discoveredEpg ?? updated.epgUrl,
      );
      final latestIndex = sources.indexWhere((s) => s.id == sourceId);
      if (latestIndex >= 0) {
        // Keep enable/disable (and Xtream VOD) toggled while this sync was running.
        final latest = sources[latestIndex];
        updated = updated.copyWith(
          enabled: latest.enabled,
          vodEnabled: latest.vodEnabled,
        );
        sources = [...sources]..[latestIndex] = updated;
      }

      syncPhase = 'save-sources';
      await _store.saveSources(sources);
      syncPhase = 'save-catalog';
      final save = Stopwatch()..start();
      if (catalogTouched) {
        await _store.saveCatalog(catalog);
      }
      saveMs = save.elapsedMilliseconds;

      // Re-link continue-watching / My List rows that still point at a source
      // id from another device (or a re-added catalog with a new UUID).
      if (source.type == IptvSourceType.custom || source.type.isMediaServer) {
        syncPhase = 'heal-orphans';
        await _healOrphanedSourceIds();
      }

      // EPG + VOD are deferred — never start them mid-sync notify storm.
      // Debounced so m3u + xtream soft syncs share one guide reload.
      // Only latch "Updating guide…" when this source actually feeds XMLTV
      // (guide-off / provider-only with no URL stay off the coalesced reload).
      var followOnStatus = false;
      if (_sourceContributesMergedXmltv(updated)) {
        // Playlist Synchroniser (manual or soft) skips a warm guide — the old
        // manual path re-downloaded (~3s fetchMs) then reused parse, which
        // froze HWND under « Mise à jour du guide ». Dedicated XMLTV Sync
        // still refreshes.
        final epgReason = reason == 'manual'
            ? 'manual-sync:${source.type.name}'
            : 'soft-sync:${source.type.name}';
        if (shouldSkipWarmXmltvReloadAfterPlaylistSync(
          reason: epgReason,
          urls: _collectMergedEpgUrls(),
          appliedFeedUrls: _epgWarmFeedUrls,
          hasPrograms: _epgHasAppliedPrograms,
        )) {
          JavpLog.i(
            'epg',
            'skip guide already-warm source=$sourceId '
                'reason=$epgReason',
          );
        } else {
          await pumpUi();
          // Manual Sync + VOD: do not start XMLTV while "Récupération du
          // catalogue VOD" is downloading/decoding — nested epg-ingest GC
          // stalls Windows input even when frames still paint.
          final deferEpgForVod = reason == 'manual' &&
              refreshVod &&
              (source.type == IptvSourceType.xtream ||
                  source.type == IptvSourceType.stalker) &&
              (source.type != IptvSourceType.xtream || updated.vodEnabled);
          if (deferEpgForVod) {
            _pendingEpgAfterVod[sourceId] = epgReason;
            JavpLog.i(
              'epg',
              'defer guide until after VOD prefetch source=$sourceId '
                  'reason=$epgReason',
            );
            followOnStatus = true;
          } else {
            _scheduleEpgReloadForSource(sourceId, reason: epgReason);
            followOnStatus = true;
          }
        }
      }
      if (!_useLiveDb) {
        _liveIndex = null;
        _liveIndexLoadAttempted = true;
        unawaited(ensureLiveIndex(delay: const Duration(seconds: 1)));
      }
      // Manual Sync may force VOD; soft sync must NOT start disk hydrate
      // (even delayed) — that latched Catalog "Loading…" for 45s+. Idle warm
      // / Catalog demand own hydrate; Accueil stays free of ~200k rows.
      if (source.type == IptvSourceType.xtream ||
          source.type == IptvSourceType.stalker) {
        final contributeVod =
            source.type != IptvSourceType.xtream || updated.vodEnabled;
        if (contributeVod) {
          if (refreshVod) {
            // Manual Synchroniser always re-fetches VOD/series; fingerprint
            // skip still avoids rewrite when the dump is unchanged.
            JavpLog.i(
              'vod',
              'manual sync -> force prefetch source=${source.id} '
                  'delayMs=2000 queue=${_bgQueue.pendingCount}',
            );
            // Do not stamp "Démarrage du cache VOD" here — that label sat on
            // screen during live fill / EPG / SQLite stalls and looked like
            // the VOD cache start itself froze the HWND.
            followOnStatus = true;
            // Hold focus across the 2s delay before [_vodPrefetching] is set.
            _expectManualSyncVod(updated.id);
            unawaited(() async {
              try {
                await Future<void>.delayed(const Duration(seconds: 2));
                if (_disposed || _sourceById(updated.id) == null) return;
                // In-process live dump + VOD on the UI isolate overlapped and
                // killed the HWND. Desktop live is SyncEngine now — start VOD
                // without waiting. Other platforms still serialize.
                if (!DesktopUi.isDesktopOs) {
                  final hwnd = HwndSyncTrace.of(updated.id);
                  var waited = 0;
                  while (_liveCategoryPrefetching.contains(updated.id)) {
                    if (waited == 0 || waited % 5 == 0) {
                      hwnd?.mark(
                        'vod-wait-live-fill',
                        'waited=${waited}s',
                      );
                    }
                    await Future<void>.delayed(const Duration(seconds: 1));
                    await pumpUi(label: 'vod-wait-live');
                    waited++;
                    if (_disposed || _sourceById(updated.id) == null) return;
                  }
                }
                if (updated.type == IptvSourceType.xtream) {
                  await prefetchXtreamOnDemand(updated);
                } else {
                  await prefetchStalkerOnDemand(updated);
                }
              } finally {
                _clearManualSyncExpectVod(updated.id);
              }
            }());
          } else {
            JavpLog.i(
              'vod',
              'soft-sync end -> schedule idle warm (no hydrate latch) '
                  'source=${source.id} hydrated=$_vodDiskHydrated '
                  'queue=${_bgQueue.pendingCount}',
            );
            unawaited(
              scheduleIdleVodWarm(reason: 'soft-sync-end:${source.id}'),
            );
          }
        }
      }
      // Keep paging the rest of this source in the background so the catalog
      // ends up complete rather than stopping at the first page.
      if (LibraryProvider._supportsDeepSync(source.type)) {
        if (!followOnStatus) {
          _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncPagingRemaining);
          followOnStatus = true;
        }
        unawaited(_deepSyncSource(source.id));
      }
      if (!followOnStatus && _liveCategoryPrefetching.contains(sourceId)) {
        _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncFillingLiveChannels);
        followOnStatus = true;
      }
      if (!followOnStatus) {
        _setSourceSyncStatus(sourceId, null);
      }
      unawaited(refreshWatchlistSeriesDownloads(sourceId: source.id));
      liveCount = updated.channelCount;
      vodCount = updated.vodCount;
      final totalMs = watch.elapsedMilliseconds;
      final summary =
          'sync done in ${totalMs}ms type=${source.type.name} '
          'reason=$reason live=$liveCount vod=$vodCount blockUi=$blockUi '
          'fetchMs=$fetchMs liveDbMs=$liveDbMs saveMs=$saveMs '
          'catalogTouched=$catalogTouched';
      if (totalMs >= 5000) {
        JavpLog.w('source', summary);
      } else {
        JavpLog.i('source', summary);
      }
      JavpLog.i(
        'sync',
        'phase=source-done type=${source.type.name} reason=$reason '
            'totalMs=$totalMs fetchMs=$fetchMs liveDbMs=$liveDbMs '
            'saveMs=$saveMs catalogTouched=$catalogTouched '
            'blockUi=$blockUi',
      );
      // VOD / live-fill / deep-sync often continue after this return — do not
      // end the hwnd trace here or SYNC_BUTTON_CLICK → freeze loses its spine.
      if (followOnStatus) {
        HwndSyncTrace.of(sourceId)?.mark(
          'syncSource-return',
          'followOn=true totalMs=$totalMs fetchMs=$fetchMs '
              'liveDbMs=$liveDbMs saveMs=$saveMs '
              'live=$liveCount vod=$vodCount',
        );
      } else {
        HwndSyncTrace.of(sourceId)?.end(
          'ok totalMs=$totalMs fetchMs=$fetchMs liveDbMs=$liveDbMs '
          'saveMs=$saveMs live=$liveCount vod=$vodCount',
        );
      }
      return;
    } catch (e, st) {
      error = e.toString();
      _setSourceSyncStatus(sourceId, null);
      // Stamp even on failure so empty-shelf M3U 404s are not retried every
      // idle/SWR/rebuild wave (that overlay used to hitch Windows focus).
      final failedIdx = sources.indexWhere((s) => s.id == sourceId);
      if (failedIdx >= 0) {
        sources = [...sources]
          ..[failedIdx] = sources[failedIdx].copyWith(
            lastSyncedAt: DateTime.now(),
          );
        unawaited(_store.saveSources(sources));
      }
      HwndSyncTrace.of(sourceId)?.end(
        'FAIL phase=$syncPhase after=${watch.elapsedMilliseconds}ms err=$e',
      );
      JavpLog.w(
        'source',
        'sync failed after ${watch.elapsedMilliseconds}ms '
            'type=${sourceForLog?.type.name ?? '?'} reason=$reason '
            'blockUi=$blockUi phase=$syncPhase',
        error: e,
      );
      JavpLog.e('source', 'sync stack phase=$syncPhase', error: e, stack: st);
      if (rethrowErrors) rethrow;
    } finally {
      _debugSyncPhase = '-';
      _syncingSourceIds.remove(sourceId);
      _clearSourceSyncStatusIfIdle(sourceId);
      if (ownQuiet) _uiQuiet = false;
      if (heldSoftSlot) _releaseSoftSourceSyncSlot();
      // Soft sync: idle notify so Accueil doesn't rematerialize mid-scroll.
      if (blockUi) {
        notifyListeners();
      } else {
        _notifyListenersAfterIdle();
      }
      // Xtream / custom may have finished while Simkl shells were unresolved.
      _scheduleTrackerRelinkOnCatalogGrowth(
        reason: 'source-sync-done:$sourceId',
      );
      // Keep group-index aborted across the whole Synchroniser follow-on
      // (live fill + delayed VOD). Clearing here when prefetch had not
      // started yet let GROUP BY race the VOD writer and froze Win32 input
      // while frames still painted (stall=xtream-vod-stream>vod-group-index).
      if (reason == 'manual' &&
          !_vodPrefetching.contains(sourceId) &&
          !_manualSyncExpectVod.contains(sourceId) &&
          !_manualSyncFocusHold.contains(sourceId)) {
        _clearVodGroupIndexAbort();
      }
      if (reason == 'manual') {
        _scheduleEndManualSyncFocusHold(sourceId);
      }
    }
  }
}
