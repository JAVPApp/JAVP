part of '../library_provider.dart';

extension LibraryEpg on LibraryProvider {
  /// Whether Guide / now-playing should use EPG for this channel's source.
  bool isEpgEnabledForChannel(MediaItem channel) {
    final sid = channel.sourceId;
    if (sid == null || sid.isEmpty) return true;
    final source = _sourceById(sid);
    if (source == null) return true;
    if (!source.type.canAttachEpg) return true;
    return source.epgEnabled;
  }

  /// Resolve XMLTV URL for a live list: attached EPG source, else inline.
  ///
  /// When unset, live IPTV uses playlist `url-tvg` / Xtream auto-discovery
  /// during sync; custom catalogs use root `epgUrl`; media servers fall back
  /// to the provider programme guide in [fetchChannelGuide].
  String? resolvedEpgUrlFor(IptvSource source) {
    if (!source.type.canAttachEpg &&
        source.type != IptvSourceType.xmltv &&
        source.type != IptvSourceType.custom) {
      return null;
    }
    if (source.type == IptvSourceType.xmltv) {
      final url = source.epgUrl?.trim();
      return (url == null || url.isEmpty) ? null : url;
    }
    String? attachedUrl;
    final attachedId = source.epgSourceId?.trim();
    if (attachedId != null && attachedId.isNotEmpty) {
      final epgSource = _sourceById(attachedId);
      if (epgSource != null &&
          epgSource.enabled &&
          epgSource.type == IptvSourceType.xmltv) {
        attachedUrl = epgSource.epgUrl;
      }
    }
    return xmltvUrlForLiveSource(source, attachedXmltvUrl: attachedUrl);
  }

  /// Programme titles in the next ~36h (and recent catchup), scored like catalog rows.
  List<MediaItem> searchEpgHits(
    String query, {
    int limit = 40,
    Iterable<MediaItem>? seedChannels,
  }) {
    final tokens = IptvSearchQuery.tokens(query);
    if (tokens.isEmpty) return const [];
    if (limit < 1) return const [];
    final now = DateTime.now();
    final horizon = now.add(const Duration(hours: 36));
    final pastFloor = now.subtract(const Duration(hours: 36));
    final scored = <({int score, MediaItem item})>[];

    void consider(MediaItem channel, EpgProgram program) {
      if (parentalLock?.isItemHidden(channel) == true) return;
      if (!isSourceContentVisible(channel.sourceId)) return;
      final hasCatchup = liveSupportsCatchup(channel) || program.hasArchive;
      if (program.start.isAfter(horizon)) return;
      if (!program.end.isAfter(now)) {
        if (!hasCatchup) return;
        if (program.start.isBefore(pastFloor)) return;
      }
      final hay = IptvSearchQuery.hay(
        title: program.title,
        subtitle: program.description,
        channelName: channel.title,
      );
      final score = IptvSearchQuery.scoreNorm(hay, tokens);
      if (score <= 0) return;
      scored.add((
        score: score,
        item: _epgSearchItem(channel, program, now, hasCatchup: hasCatchup),
      ));
    }

    for (final pair in onNowChannels(limit: 120)) {
      consider(pair.channel, pair.program);
    }
    var scanned = 0;
    for (final channel in [...favoriteChannels, ...recentChannels]) {
      if (scanned >= 80) break;
      scanned++;
      for (final program in guideFor(channel)) {
        consider(channel, program);
      }
    }
    if (seedChannels != null) {
      for (final channel in seedChannels) {
        final nowProgram = nowPlayingFor(channel);
        if (nowProgram != null) consider(channel, nowProgram);
        if (liveSupportsCatchup(channel)) {
          final previous = previousProgramFor(channel);
          if (previous != null) consider(channel, previous);
        }
        final next = nextProgramFor(channel);
        if (next != null) consider(channel, next);
        if (scored.length >= limit * 4) break;
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final row in scored) {
      if (!seen.add(row.item.id)) continue;
      out.add(row.item);
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<List<EpgProgram>> fetchChannelGuide(
    MediaItem channel, {
    bool notify = true,
  }) async {
    if (!isEpgEnabledForChannel(channel)) return const [];
    final cacheKey = _guideCacheKey(channel);

    final cached = _epgByStreamId[cacheKey];
    // Catchup channels: a short-only cache (~now window) is too thin — refetch
    // so the longer archive table can be merged in.
    if (cached != null) {
      final thinCatchup = channel.supportsCatchup && cached.length < 40;
      if (!thinCatchup) return cached;
    }

    final fromXmltv = _useEpgDb
        ? await _ensureXmltvGuide(channel)
        : guideFor(channel);
    if (fromXmltv.isNotEmpty) {
      // Precedence: attached / merged XMLTV wins over provider API when it
      // matches this channel. Otherwise fall through to Xtream / media-server
      // live guide endpoints.
      final wasMissing = !_epgByStreamId.containsKey(cacheKey);
      _epgByStreamId[cacheKey] = fromXmltv;
      if (_useEpgDb && wasMissing) {
        _bumpEpgRevision();
        if (notify) notifyListeners();
      }
      return fromXmltv;
    }

    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == channel.sourceId,
      orElse: () => null,
    );
    if (source == null) return const [];
    if (source.type != IptvSourceType.xtream && !source.type.isMediaServer) {
      _epgByStreamId[cacheKey] = const [];
      return const [];
    }
    final streamId = channel.streamId;
    if (source.type == IptvSourceType.xtream &&
        (streamId == null || streamId.isEmpty)) {
      _epgByStreamId[cacheKey] = const [];
      return const [];
    }

    if (_epgLoading.contains(cacheKey)) {
      return const [];
    }
    _epgLoading.add(cacheKey);
    try {
      List<EpgProgram> programs = const [];
      if (source.type == IptvSourceType.xtream) {
        programs = await _runUserFacing(
          () => _xtream.fetchChannelEpg(
            source,
            streamId: streamId!,
            preferArchive: channel.supportsCatchup,
          ),
        );
      } else if (source.type == IptvSourceType.plex) {
        final live = PlexClient.parseLiveServerItemId(
          channel.serverItemId ?? '',
        );
        final fast = PlexClient.parseFastServerItemId(
          channel.serverItemId ?? '',
        );
        final gridKey = channel.epgChannelId?.trim();
        if (gridKey != null && gridKey.isNotEmpty) {
          _plex.clientIdentifier = await _plexClientIdentifier();
          if (live != null) {
            programs = await _runUserFacing(
              () => _plex.liveGuide(
                source,
                dvrId: live.dvrId,
                channelGridKey: gridKey,
              ),
            );
          } else if (fast != null || PlexClient.isFastProvider(source)) {
            programs = await _runUserFacing(
              () => _plex.liveGuide(source, dvrId: '', channelGridKey: gridKey),
            );
          }
        }
      } else {
        final channelId =
            channel.epgChannelId?.trim() ?? channel.streamId?.trim() ?? '';
        if (channelId.isNotEmpty) {
          final session = await _sessionFor(source);
          final jf = source.type == IptvSourceType.emby ? _emby : _jellyfin;
          programs = await _runUserFacing(
            () => jf.liveGuide(source, session, channelId: channelId),
          );
        }
      }
      _epgByStreamId[cacheKey] = programs;
      // Keep per-channel rows in [_epgByStreamId] only. Copying the full
      // XMLTV list on every visible-row prefetch froze Windows and could
      // OOM — [programAt] / [guideFor] already prefer the stream cache.
      if (programs.isNotEmpty) {
        _bumpEpgRevision();
        if (notify) notifyListeners();
      }
      return programs;
    } catch (_) {
      // Cache empty so visible-row prefetch does not retry forever.
      _epgByStreamId[cacheKey] = const [];
      return const [];
    } finally {
      _epgLoading.remove(cacheKey);
    }
  }

  /// Parallel guide fetch with a single [notifyListeners] when done.
  Future<void> fetchChannelGuides(
    Iterable<MediaItem> channels, {
    int concurrency = 6,
  }) async {
    final list = channels.toList();
    if (list.isEmpty) return;
    final workers = concurrency.clamp(1, list.length);
    var next = 0;
    final before = epgRevision;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= list.length) return;
        await fetchChannelGuide(list[index], notify: false);
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    if (epgRevision != before) {
      notifyListeners();
    }
  }

  /// Programme airing at [at] (defaults to now), from stream cache or XMLTV.
  EpgProgram? programAt(MediaItem channel, {DateTime? at}) {
    if (!isEpgEnabledForChannel(channel)) return null;
    final moment = (at ?? DateTime.now()).toUtc();
    final cached = _epgByStreamId[_guideCacheKey(channel)];
    if (cached != null) {
      for (final program in cached) {
        if (program.isAiringAt(moment)) return program;
      }
    }

    final tvgId = channel.epgChannelId?.trim();
    if (tvgId == null || tvgId.isEmpty) {
      // Still allow unique name match from XMLTV when no tvg-id.
      final named = _xmltvProgrammesFor(channel);
      for (final program in named) {
        if (program.isAiringAt(moment)) return program;
      }
      return null;
    }
    final programs = _xmltvProgrammesFor(channel);
    if (programs.isEmpty) return null;
    for (final program in programs) {
      if (program.isAiringAt(moment)) return program;
    }
    return null;
  }

  EpgProgram? nowPlayingFor(MediaItem channel) {
    return programAt(channel);
  }

  /// Live channels that currently have an airing EPG programme (Home “On now”).
  List<({MediaItem channel, EpgProgram program})> onNowChannels({
    int limit = 24,
  }) {
    if (limit <= 0) return const [];
    if (_epgByStreamId.isEmpty &&
        !_epgHasAppliedPrograms &&
        _epgXmltvByExactId.isEmpty) {
      return const [];
    }

    final lockStamp = parentalLock?.lockFilterStamp ?? 'none';
    if (_cachedOnNow != null &&
        _cachedOnNowEpgRev == epgRevision &&
        identical(_cachedOnNowLiveRef, _cachedLiveChannels) &&
        _cachedOnNowLockStamp == lockStamp &&
        _cachedOnNow!.length >= limit) {
      return _cachedOnNow!.take(limit).toList(growable: false);
    }

    // Never collapse/scan the full 20k+ live list for a Home shelf.
    final seed = <MediaItem>[...favoriteChannels, ...recentChannels];
    if (!_useLiveDb) {
      final live = liveChannels;
      var added = 0;
      for (final channel in live) {
        if (added >= 180) break;
        if (parentalLock?.isLiveChannelHidden(channel) == true) continue;
        final tvg = channel.epgChannelId?.trim();
        final hasStreamCache =
            channel.streamId != null &&
            _epgByStreamId.containsKey(channel.streamId);
        if (!hasStreamCache && (tvg == null || tvg.isEmpty)) continue;
        seed.add(channel);
        added++;
      }
    }

    final out = <({MediaItem channel, EpgProgram program})>[];
    final seen = <String>{};
    final collapsed = _useLiveDb ? seed : collapseLiveQualities(seed);
    for (final channel in collapsed) {
      if (!seen.add(channel.id)) continue;
      final program = nowPlayingFor(channel);
      if (program == null) continue;
      out.add((channel: channel, program: program));
      if (out.length >= limit) break;
    }
    _cachedOnNow = out;
    _cachedOnNowEpgRev = epgRevision;
    _cachedOnNowLiveRef = _cachedLiveChannels;
    _cachedOnNowLockStamp = lockStamp;
    return out;
  }

  /// Nearby guide slice for the player sheet: recent past + now + upcoming.
  List<EpgProgram> nearbyPrograms(
    MediaItem channel, {
    DateTime? at,
    int before = 8,
    int after = 4,
  }) {
    final moment = at ?? DateTime.now();
    final programs = [...guideFor(channel)]
      ..sort((a, b) => a.start.compareTo(b.start));
    if (programs.isEmpty) return const [];

    var currentIndex = programs.indexWhere((p) => p.isAiringAt(moment));
    if (currentIndex < 0) {
      currentIndex = programs.lastIndexWhere((p) => !p.start.isAfter(moment));
      if (currentIndex < 0) currentIndex = 0;
    }

    final start = (currentIndex - before).clamp(0, programs.length);
    final end = (currentIndex + after + 1).clamp(0, programs.length);
    return programs.sublist(start, end);
  }

  List<EpgProgram> guideFor(MediaItem channel, {DateTime? from, DateTime? to}) {
    if (!isEpgEnabledForChannel(channel)) return const [];
    final windowFrom =
        from ??
        DateTime.now().subtract(
          Duration(days: channel.catchupDays > 0 ? channel.catchupDays : 7),
        );
    final windowTo = to ?? DateTime.now().add(const Duration(hours: 24));

    List<EpgProgram> filter(List<EpgProgram> programs) {
      return [
        for (final p in programs)
          if (!p.end.isBefore(windowFrom) && !p.start.isAfter(windowTo)) p,
      ];
    }

    final streamCached = _epgByStreamId[_guideCacheKey(channel)];
    if (streamCached != null && streamCached.isNotEmpty) {
      return filter(streamCached);
    }

    final indexed = _xmltvProgrammesFor(channel);
    if (indexed.isEmpty) return const [];
    return filter(indexed);
  }

  Future<bool> scheduleProgramReminder({
    required MediaItem channel,
    required EpgProgram program,
  }) async {
    if (!program.start.isAfter(DateTime.now())) return false;
    await _reminders.ensureInitialized();
    final permitted = await _reminders.requestPermissions();
    if (!permitted) return false;

    final reminder = EpgReminder.fromProgram(
      mediaItemId: channel.id,
      channelTitle: channel.title,
      program: program,
    );
    epgReminders = [
      reminder,
      ...epgReminders.where((r) => r.id != reminder.id && !r.isPast),
    ];
    if (epgReminders.length > LibraryProvider._maxEpgReminders) {
      epgReminders = epgReminders.sublist(0, LibraryProvider._maxEpgReminders);
    }
    await _reminders.schedule(reminder);
    await _store.saveEpgReminders(epgReminders);
    _noteSyncableChange();
    notifyListeners();
    return true;
  }

  Future<void> cancelProgramReminder({
    required MediaItem channel,
    required EpgProgram program,
  }) async {
    final key = EpgProgram.reminderKey(
      mediaItemId: channel.id,
      program: program,
    );
    final existing = epgReminders.where((r) => r.id == key).toList();
    epgReminders = [
      for (final r in epgReminders)
        if (r.id != key) r,
    ];
    for (final r in existing) {
      await _reminders.cancel(r);
    }
    await _store.saveEpgReminders(epgReminders);
    _noteSyncableChange();
    notifyListeners();
  }

  bool get hasEpgDb => _useEpgDb;

  bool get _epgHasAppliedPrograms =>
      _useEpgDb ? _epgProgramCount > 0 : epg.isNotEmpty;

  bool _epgFeedIsWarm(String url) => _useEpgDb
      ? _epgDbFeedUrls.contains(url)
      : _epgParsedByUrl.containsKey(url);

  String _guideCacheKey(MediaItem channel) => channel.streamId ?? channel.id;

  String? _resolveXmltvChannelId(MediaItem channel) {
    return _epgAliasIndex?.resolve(
      epgChannelId: channel.epgChannelId,
      channelTitle: channel.title,
      channelName: channel.channelName,
    );
  }

  void _rememberXmltvGuide(String exactId, List<EpgProgram> programs) {
    _epgXmltvByExactId[exactId] = programs;
    _epgXmltvLru.remove(exactId);
    _epgXmltvLru.add(exactId);
    while (_epgXmltvLru.length > LibraryProvider._epgXmltvLruCap) {
      final evict = _epgXmltvLru.removeAt(0);
      _epgXmltvByExactId.remove(evict);
    }
  }

  ({int fromMs, int toMs}) _xmltvWindowMs(MediaItem channel) {
    final from = DateTime.now().subtract(
      Duration(days: channel.catchupDays > 0 ? channel.catchupDays : 7),
    );
    final to = DateTime.now().add(const Duration(hours: 24));
    return (
      fromMs: from.toUtc().millisecondsSinceEpoch,
      toMs: to.toUtc().millisecondsSinceEpoch,
    );
  }

  Future<void> _enableEpgDb({required String reason}) async {
    if (kIsWeb) {
      JavpLog.i('epg', 'db skipped on web reason=$reason');
      return;
    }
    try {
      await _epgDb.ensureOpen();
    } catch (e) {
      JavpLog.w('epg', 'db enable failed reason=$reason', error: e);
      return;
    }
    _useEpgDb = true;
    _epgProgramCount = await _epgDb.countPrograms();
    epgChannelNames = await _epgDb.loadChannelNames();
    _epgAliasIndex = EpgChannelAliasIndex.fromChannelNames(epgChannelNames);
    _epgDbFeedUrls
      ..clear()
      ..addAll(await _epgDb.listFeedUrls());
    _epgAppliedUrls = {..._epgDbFeedUrls};
    epg = [];
    _epgLookupIndex = null;
    _epgParsedByUrl.clear();
    _bumpEpgRevision();
    JavpLog.i(
      'epg',
      'db enabled reason=$reason programs=$_epgProgramCount '
          'channels=${epgChannelNames.length} feeds=${_epgDbFeedUrls.length}',
    );
    unawaited(_prefetchPinnedXmltvGuides());
  }

  bool get _shouldLoadEpgViaSyncEngine {
    if (kIsWeb) return false;
    if (!DesktopUi.isDesktopOs) return false;
    if (Platform.environment['JAVP_SYNC_INPROCESS'] == '1') return false;
    return true;
  }

  SyncReason _syncReasonForEpgTrigger(String reason) {
    final r = reason.toLowerCase();
    if (r.contains('idle')) return SyncReason.idle;
    if (r.contains('soft')) return SyncReason.soft;
    if (r.contains('deep')) return SyncReason.deep;
    if (r.contains('rebuild')) return SyncReason.rebuild;
    return SyncReason.manual;
  }

  Future<void> _loadEpgUrlsIntoDb(
    List<String> urls, {
    required String reason,
  }) async {
    await _epgDb.ensureOpen();
    _useEpgDb = true;

    if (_shouldLoadEpgViaSyncEngine) {
      await _loadEpgUrlsIntoDbViaSyncEngine(urls, reason: reason);
      return;
    }

    await _loadEpgUrlsIntoDbInProcess(urls, reason: reason);
  }

  /// Desktop: download + SQLite write in SyncEngine (same process as live/VOD).
  Future<void> _loadEpgUrlsIntoDbViaSyncEngine(
    List<String> urls, {
    required String reason,
  }) async {
    final watch = Stopwatch()..start();
    final warm = <String>[];
    final cold = <String>[];
    for (final epgUrl in urls) {
      if (shouldReuseWarmXmltvFeed(
        reason: reason,
        url: epgUrl,
        appliedFeedUrls: _epgWarmFeedUrls,
      )) {
        warm.add(epgUrl);
        _epgDbFeedUrls.add(epgUrl);
      } else {
        cold.add(epgUrl);
      }
    }

    final urlSet = urls.toSet();
    if (cold.isEmpty) {
      if (_epgProgramCount > 0 &&
          _epgAppliedUrls.length == urlSet.length &&
          _epgAppliedUrls.containsAll(urlSet)) {
        JavpLog.i(
          'epg',
          'db load skip unchanged (oop warm) in '
              '${watch.elapsedMilliseconds}ms feeds=${urls.length} '
              'reused=${warm.length} reason=$reason',
        );
        return;
      }
      await _epgDb.keepFeeds(urlSet);
      await _refreshEpgDbUiState(urlSet: urlSet);
      JavpLog.i(
        'epg',
        'db load warm-only (ui keep) in ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} programs=$_epgProgramCount reason=$reason',
      );
      unawaited(_prefetchPinnedXmltvGuides());
      return;
    }

    // Keep Catalog indexes deferred through OOP guide — resume from
    // [_scheduleEpgReloadForSource] whenComplete / focus-hold end.
    _vodGroupIndexAbort = true;
    _postHydrateIndexesPending = true;

    _setEpgReloadProgress(_uiL10n.sourceSyncUpdatingGuide);
    final client = SyncClient();
    _syncClients['epg'] = client;
    late final SyncJobResult dumped;
    try {
      dumped = await client.runXmltvEpg(
        profileId: profileId,
        epgUrls: urls,
        warmEpgUrls: warm,
        trigger: reason,
        reason: _syncReasonForEpgTrigger(reason),
        onProgress: (event) {
          if (event.type != 'progress') return;
          final committed = event.committed;
          final total = event.total;
          if (committed == null || total == null || total <= 1) {
            if (event.status == 'parsing') {
              _setEpgReloadProgress(_uiL10n.sourceSyncUpdatingGuide);
            }
            return;
          }
          _setEpgReloadProgress(
            _uiL10n.sourceSyncUpdatingGuideProgress(
              '$committed',
              '$total',
            ),
          );
        },
      );
    } finally {
      _syncClients.remove('epg');
    }

    if (dumped.sqlCount == 0 && cold.isNotEmpty) {
      JavpLog.w(
        'epg',
        'db load empty (oop) after ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} cold=${cold.length} reason=$reason',
      );
      return;
    }

    await _refreshEpgDbUiState(urlSet: urlSet);
    JavpLog.i(
      'epg',
      'db load (oop) in ${watch.elapsedMilliseconds}ms feeds=${urls.length} '
          'programs=$_epgProgramCount channels=${epgChannelNames.length} '
          'cold=${cold.length} warm=${warm.length} '
          'skipped=${dumped.skipped} written=${dumped.written} '
          'reason=$reason',
    );
    unawaited(_prefetchPinnedXmltvGuides());
  }

  Future<void> _refreshEpgDbUiState({required Set<String> urlSet}) async {
    _epgDbFeedUrls
      ..clear()
      ..addAll(await _epgDb.listFeedUrls());
    epgChannelNames = await _epgDb.loadChannelNames();
    _epgAliasIndex = EpgChannelAliasIndex.fromChannelNames(epgChannelNames);
    _epgProgramCount = await _epgDb.countPrograms();
    _epgAppliedUrls = urlSet;
    epg = [];
    _epgLookupIndex = null;
    _epgParsedByUrl.clear();
    _epgXmltvByExactId.clear();
    _epgXmltvLru.clear();
    _epgXmltvPrefetching.clear();
    _epgByStreamId.clear();
    _bumpEpgRevision();
  }

  Future<void> _loadEpgUrlsIntoDbInProcess(
    List<String> urls, {
    required String reason,
  }) async {
    var any = false;
    var fetchMs = 0;
    var parseMs = 0;
    var reused = 0;
    var parsedFeeds = 0;
    var ingested = 0;
    final watch = Stopwatch()..start();
    final totalFeeds = urls.length;
    var feedIndex = 0;

    for (final epgUrl in urls) {
      feedIndex++;
      await _yieldToBrowse(reason: 'epg');
      if (shouldReuseWarmXmltvFeed(
        reason: reason,
        url: epgUrl,
        appliedFeedUrls: _epgWarmFeedUrls,
      )) {
        _epgDbFeedUrls.add(epgUrl);
        reused++;
        any = true;
        continue;
      }
      _setEpgReloadProgress(
        totalFeeds == 1
            ? _uiL10n.sourceSyncUpdatingGuide
            : _uiL10n.sourceSyncUpdatingGuideProgress(
                '$feedIndex',
                '$totalFeeds',
              ),
      );
      try {
        final fetch = Stopwatch()..start();
        final loaded = await _loadEpgBytes(epgUrl);
        fetchMs += fetch.elapsedMilliseconds;
        await pumpUi(label: 'epg-fetched');
        if (loaded == null) continue;
        final bytes = loaded.bytes;
        if (bytes.isEmpty || bytes.length > kMaxEpgDownloadBytes) continue;

        if (loaded.notModified &&
            (_epgDbFeedUrls.contains(epgUrl) || await _epgDb.hasFeed(epgUrl))) {
          _epgDbFeedUrls.add(epgUrl);
          reused++;
          any = true;
          continue;
        }

        _setEpgReloadProgress(
          totalFeeds == 1
              ? _uiL10n.sourceSyncParsingGuide(
                  LibraryProvider._formatByteSize(bytes.length),
                )
              : _uiL10n.sourceSyncParsingGuideProgress(
                  '$feedIndex',
                  '$totalFeeds',
                  LibraryProvider._formatByteSize(bytes.length),
                ),
        );
        await pumpUi(label: 'epg-parse-start');
        final parse = Stopwatch()..start();
        await _epgDb.clearFeed(epgUrl);
        final ingestedFeed = await ingestEpgPackedInIsolate(
          bytes: bytes,
          url: epgUrl,
          contentEncoding: loaded.contentEncoding,
          onChunk: (rows) => _epgDb.insertPrograms(epgUrl, rows),
        );
        parseMs += parse.elapsedMilliseconds;
        await pumpUi(label: 'epg-parse-done');
        parsedFeeds++;
        if (ingestedFeed.programCount == 0 &&
            ingestedFeed.channelNames.isEmpty) {
          continue;
        }
        await _epgDb.insertChannels(epgUrl, ingestedFeed.channelNames);
        await _epgDb.touchFeed(epgUrl, ingestedFeed.programCount);
        _epgDbFeedUrls.add(epgUrl);
        ingested += ingestedFeed.programCount;
        any = true;
      } catch (e) {
        JavpLog.w('epg', 'feed failed url=$epgUrl', error: e);
      }
    }

    if (!any) {
      JavpLog.w(
        'epg',
        'db load empty after ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} fetchMs=$fetchMs parseMs=$parseMs '
            'reason=$reason',
      );
      return;
    }

    final urlSet = urls.toSet();
    if (reused == urls.length &&
        parsedFeeds == 0 &&
        _epgProgramCount > 0 &&
        _epgAppliedUrls.length == urlSet.length &&
        _epgAppliedUrls.containsAll(urlSet)) {
      JavpLog.i(
        'epg',
        'db load skip unchanged in ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} reused=$reused fetchMs=$fetchMs '
            'reason=$reason',
      );
      return;
    }

    await _epgDb.keepFeeds(urlSet);
    await _refreshEpgDbUiState(urlSet: urlSet);
    JavpLog.i(
      'epg',
      'db load in ${watch.elapsedMilliseconds}ms feeds=${urls.length} '
          'programs=$_epgProgramCount channels=${epgChannelNames.length} '
          'fetchMs=$fetchMs parseMs=$parseMs ingested=$ingested '
          'reused=$reused parsed=$parsedFeeds reason=$reason',
    );
    unawaited(_prefetchPinnedXmltvGuides());
  }

  void _scheduleXmltvGuidePrefetch(MediaItem channel) {
    if (!_useEpgDb || _disposed) return;
    final exact = _resolveXmltvChannelId(channel);
    if (exact == null) return;
    if (_epgXmltvByExactId.containsKey(exact)) return;
    if (_epgXmltvPrefetching.length >= LibraryProvider._epgXmltvPrefetchCap) {
      return;
    }
    if (!_epgXmltvPrefetching.add(exact)) return;
    unawaited(() async {
      try {
        await _ensureXmltvGuide(channel);
        if (_disposed) return;
        _bumpEpgRevision();
        notifyListeners();
      } finally {
        _epgXmltvPrefetching.remove(exact);
      }
    }());
  }

  Future<List<EpgProgram>> _ensureXmltvGuide(MediaItem channel) async {
    final exact = _resolveXmltvChannelId(channel);
    if (exact == null) return const [];
    final cached = _epgXmltvByExactId[exact];
    if (cached != null) return cached;
    if (!_useEpgDb) return const [];
    final window = _xmltvWindowMs(channel);
    final programs = await _epgDb.programsForChannel(
      channelId: exact,
      fromMs: window.fromMs,
      toMs: window.toMs,
    );
    _rememberXmltvGuide(exact, programs);
    return programs;
  }

  Future<void> _prefetchPinnedXmltvGuides() async {
    if (!_useEpgDb || _epgProgramCount <= 0) return;
    final seed = <MediaItem>[...favoriteChannels, ...recentChannels];
    if (seed.isEmpty) return;
    await fetchChannelGuides(seed.take(24), concurrency: 4);
  }

  Future<List<EpgProgram>> guideForAsync(
    MediaItem channel, {
    DateTime? from,
    DateTime? to,
  }) async {
    if (_useEpgDb) {
      await _ensureXmltvGuide(channel);
    }
    return guideFor(channel, from: from, to: to);
  }

  Future<List<MediaItem>> searchEpgHitsAsync(
    String query, {
    int limit = 40,
    Iterable<MediaItem>? seedChannels,
  }) async {
    if (!_useEpgDb) {
      return searchEpgHits(query, limit: limit, seedChannels: seedChannels);
    }
    final tokens = IptvSearchQuery.tokens(query);
    if (tokens.isEmpty || limit < 1) return const [];
    final now = DateTime.now();
    final fromMs = now
        .subtract(const Duration(hours: 36))
        .toUtc()
        .millisecondsSinceEpoch;
    final toMs = now
        .add(const Duration(hours: 36))
        .toUtc()
        .millisecondsSinceEpoch;
    List<EpgProgram> programs;
    try {
      programs = await _epgDb.searchTitles(
        needle: query,
        fromMs: fromMs,
        toMs: toMs,
        limit: (limit * 4).clamp(16, 160),
      );
    } catch (e) {
      JavpLog.w('epg', 'title search failed', error: e);
      return searchEpgHits(query, limit: limit, seedChannels: seedChannels);
    }
    if (programs.isEmpty) {
      return searchEpgHits(query, limit: limit, seedChannels: seedChannels);
    }

    final byExact = <String, MediaItem>{};
    void remember(MediaItem channel) {
      final exact = _resolveXmltvChannelId(channel);
      if (exact == null) return;
      byExact.putIfAbsent(exact, () => channel);
      final tvg = channel.epgChannelId?.trim();
      if (tvg != null && tvg.isNotEmpty) {
        byExact.putIfAbsent(tvg, () => channel);
      }
    }

    for (final channel in favoriteChannels) {
      remember(channel);
    }
    for (final channel in recentChannels) {
      remember(channel);
    }
    if (seedChannels != null) {
      for (final channel in seedChannels) {
        remember(channel);
      }
    }
    if (_useLiveDb) {
      final missing = <String>{
        for (final program in programs)
          if (!byExact.containsKey(program.channelId)) program.channelId,
      };
      if (missing.isNotEmpty) {
        try {
          for (final channel in await _liveDb.channelsByEpgChannelIds(
            missing.toList(growable: false),
          )) {
            remember(channel);
          }
        } catch (_) {}
      }
    }

    final scored = <({int score, MediaItem item})>[];
    for (final program in programs) {
      final channel = byExact[program.channelId];
      if (channel == null) continue;
      if (parentalLock?.isItemHidden(channel) == true) continue;
      if (!isSourceContentVisible(channel.sourceId)) continue;
      final hasCatchup = liveSupportsCatchup(channel) || program.hasArchive;
      final hay = IptvSearchQuery.hay(
        title: program.title,
        subtitle: program.description,
        channelName: channel.title,
      );
      final score = IptvSearchQuery.scoreNorm(hay, tokens);
      if (score <= 0) continue;
      scored.add((
        score: score,
        item: _epgSearchItem(channel, program, now, hasCatchup: hasCatchup),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final row in scored) {
      if (!seen.add(row.item.id)) continue;
      out.add(row.item);
      if (out.length >= limit) break;
    }
    return out;
  }
}
