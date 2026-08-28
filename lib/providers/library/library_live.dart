part of '../library_provider.dart';

extension LibraryLive on LibraryProvider {
  List<MediaItem> get liveChannels {
    if (_useLiveDb) return const [];
    final lockStamp = parentalLock?.lockFilterStamp ?? 'none';
    if (!identical(_liveChannelsCatalogRef, catalog) ||
        _cachedLiveChannels == null ||
        _liveChannelsEnabledStamp != _sourcesEnabledStamp ||
        _liveChannelsLockStamp != lockStamp) {
      _cachedLiveChannels = catalog
          .where(
            (m) =>
                m.kind == MediaKind.live && isSourceContentVisible(m.sourceId),
          )
          .toList(growable: false);
      _liveChannelsCatalogRef = catalog;
      _liveChannelsEnabledStamp = _sourcesEnabledStamp;
      _liveChannelsLockStamp = lockStamp;
      _liveFamilyIndex = null;
      _liveFamilyKeyById = null;
      _liveByGroup = null;
      _liveById = null;
    }
    return _cachedLiveChannels!;
  }

  bool get hasLiveDb => _useLiveDb;

  Future<int> liveListingCount({String? groupName, String? sourceId}) {
    if (parentalLock?.ready == false) {
      return Future.value(0);
    }
    if (!_useLiveDb) {
      return Future.value(
        groupName == null || groupName.isEmpty
            ? liveChannelsInGroup(null).length
            : liveChannelsInGroup(groupName).length,
      );
    }
    if (sourceId != null &&
        sourceId.isNotEmpty &&
        !isSourceContentVisible(sourceId)) {
      return Future.value(0);
    }
    _syncParentalLiveCategoryNames();
    return _liveDb.countListings(
      groupName: groupName,
      sourceId: sourceId,
      allowedSourceIds: _liveAllowedSourceIds,
      excludedGroupNames: _parentalExcludedGroupNames(),
      excludeAdult: _parentalExcludeAdult(),
    );
  }

  /// Paged collapsed live rows from SQLite (preferred TV path).
  ///
  /// Defaults to [LiveListingSort.position] (provider/playlist order).
  Future<List<MediaItem>> pageLiveChannels({
    String? groupName,
    String? sourceId,
    Iterable<String>? sourceIds,
    String? query,
    int offset = 0,
    int limit = 80,
    bool catchupFirst = false,
    bool catchupOnly = false,
    LiveListingSort sort = LiveListingSort.position,
  }) {
    return UiStallWatchdog.span('live-page', () async {
      _syncParentalLiveCategoryNames();
      if (parentalLock?.ready == false) {
        // Avoid paginating unfiltered DB rows before prefs load.
        return const [];
      }
      if (parentalLock?.isGroupNameHidden(groupName) == true) {
        return const [];
      }
      final filter = _resolveLiveSourceFilter(
        sourceId: sourceId,
        sourceIds: sourceIds,
      );
      if (filter.empty) return const [];
      final resolvedSort = catchupFirst ? LiveListingSort.catchupFirst : sort;
      if (!_useLiveDb) {
        // Legacy in-memory fallback.
        var items = liveChannelsInGroup(groupName);
        final want = filter.sourceId != null
            ? {filter.sourceId!}
            : (filter.allowedSourceIds?.toSet());
        if (want != null && want.isNotEmpty) {
          items = items
              .where((c) => c.sourceId != null && want.contains(c.sourceId))
              .toList();
        }
        if (query != null && query.trim().isNotEmpty) {
          final q = query.trim();
          items = items
              .where(
                (c) => iptvMatchesQuery(q, [
                  c.title,
                  c.channelName,
                  c.group,
                  c.streamId,
                ]),
              )
              .toList();
        }
        items = collapseLiveQualities(items);
        if (catchupOnly) {
          items = [
            for (final c in items)
              if (liveSupportsCatchup(c)) c,
          ];
        }
        items = [...items]
          ..sort((a, b) {
            switch (resolvedSort) {
              case LiveListingSort.catchupFirst:
                final c =
                    (liveSupportsCatchup(b) ? 1 : 0) -
                    (liveSupportsCatchup(a) ? 1 : 0);
                if (c != 0) return c;
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
              case LiveListingSort.category:
                final g = (a.group ?? '').compareTo(b.group ?? '');
                if (g != 0) return g;
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
              case LiveListingSort.position:
                return 0;
              case LiveListingSort.name:
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
            }
          });
        if (offset >= items.length) return const [];
        final end = (offset + limit > items.length)
            ? items.length
            : offset + limit;
        return items.sublist(offset, end);
      }

      final page = await _liveDb.pageListings(
        groupName: groupName,
        sourceId: filter.sourceId,
        allowedSourceIds: filter.allowedSourceIds,
        excludedGroupNames: _parentalExcludedGroupNames(),
        excludeAdult: _parentalExcludeAdult(),
        query: query,
        offset: offset,
        limit: limit,
        sort: resolvedSort,
        catchupFirst: catchupFirst,
        catchupOnly: catchupOnly,
      );
      final out = <MediaItem>[];
      for (final row in page) {
        // Belt-and-suspenders if a name map race left a row through SQL.
        if (parentalLock?.isLiveChannelHidden(row.item) == true) {
          continue;
        }
        final titled = row.item.copyWith(title: officialLiveTitle(row.item));
        _liveVariantCountById[titled.id] = row.variantCount;
        _rememberFamilyCatchupDays(titled.id, row.familyCatchupDays);
        out.add(titled);
      }
      return out;
    });
  }

  Future<void> _enableLiveDbFromChannels(
    List<MediaItem> live, {
    required String reason,
  }) async {
    if (kIsWeb) {
      JavpLog.i('live', 'db enable skipped on web reason=$reason');
      return;
    }
    if (live.isEmpty && !await _liveDb.hasListings) return;
    if (live.isNotEmpty) {
      await _liveDb.migrateFromMediaItems(
        live,
        epgDisplayNames: epgChannelNames,
        preferredLiveQualities: preferredLiveQualities,
      );
    }
    _useLiveDb = true;
    _cachedLiveChannels = const [];
    _liveChannelsCatalogRef = catalog;
    liveDbRevision++;
    await _refreshLiveDbSourceIds();
    await _reloadPinnedLiveChannels();
  }

  Future<void> _refreshLiveDbSourceIds() async {
    if (!_useLiveDb) {
      _liveDbSourceIds.clear();
      return;
    }
    try {
      final ids = await _liveDb.listSourceIds();
      _liveDbSourceIds
        ..clear()
        ..addAll(ids);
    } catch (_) {
      // Keep the last warm set; a failed list must not look empty.
    }
  }

  Future<void> _replaceLiveSourceFromPacked({
    required String sourceId,
    required LiveIngestPlan plan,
  }) async {
    if (kIsWeb) return;
    final watch = Stopwatch()..start();
    final written = await _liveDb.replaceSourceLivePacked(
      sourceId: sourceId,
      channels: plan.channelRows,
      plan: plan,
      epgDisplayNames: epgChannelNames,
      preferredLiveQualities: preferredLiveQualities,
    );
    if (!written) {
      JavpLog.i(
        'live',
        'replaceSource packed unchanged channels=${plan.liveCount} '
            'sourceId=$sourceId',
      );
      return;
    }
    _useLiveDb = true;
    _cachedLiveChannels = const [];
    if (plan.liveCount > 0) {
      _liveDbSourceIds.add(sourceId);
    } else {
      _liveDbSourceIds.remove(sourceId);
    }
    liveDbRevision++;
    await _reloadPinnedLiveChannels();
    await yieldAfterIsolateChunk();
    JavpLog.i(
      'live',
      'replaceSource packed in ${watch.elapsedMilliseconds}ms '
          'channels=${plan.liveCount} sourceId=$sourceId',
    );
  }

  Future<void> _replaceLiveSourceInDb({
    required String sourceId,
    required List<MediaItem> live,
  }) async {
    if (kIsWeb) {
      // SQLite live DB is unavailable on web — callers keep live rows in
      // [catalog] and [liveChannels] instead.
      JavpLog.i(
        'live',
        'replaceSource skipped on web channels=${live.length} '
            'sourceId=$sourceId',
      );
      return;
    }
    final watch = Stopwatch()..start();
    final written = await _liveDb.replaceSourceLive(
      sourceId: sourceId,
      channels: live,
      epgDisplayNames: epgChannelNames,
      preferredLiveQualities: preferredLiveQualities,
    );
    if (!written) {
      JavpLog.i(
        'live',
        'replaceSource unchanged channels=${live.length} '
            'sourceId=$sourceId',
      );
      return;
    }
    _useLiveDb = true;
    _cachedLiveChannels = const [];
    if (live.isNotEmpty) {
      _liveDbSourceIds.add(sourceId);
    } else {
      _liveDbSourceIds.remove(sourceId);
    }
    liveDbRevision++;
    await _reloadPinnedLiveChannels();
    await yieldAfterIsolateChunk();
    JavpLog.i(
      'live',
      'replaceSource in ${watch.elapsedMilliseconds}ms '
          'channels=${live.length} sourceId=$sourceId',
    );
  }

  /// Collapsed live page from the precomputed index (empty when not ready).
  List<MediaItem> indexedLivePage({
    String? groupName,
    int offset = 0,
    int limit = 80,
  }) {
    if (!hasLiveIndex || limit <= 0) return const [];
    final ids = _liveIndex!.idsForGroup(groupName);
    if (offset >= ids.length) return const [];
    final end = (offset + limit > ids.length) ? ids.length : offset + limit;
    _ensureLiveById();
    final out = <MediaItem>[];
    for (var i = offset; i < end; i++) {
      final presented = _presentIndexedLive(ids[i]);
      if (presented != null) out.add(presented);
    }
    return out;
  }

  Future<void> ensureLiveIndex({Duration delay = Duration.zero}) async {
    if (_useLiveDb) return;
    if (liveChannels.isEmpty) return;
    if (hasLiveIndex) return;
    if (_liveIndexBuilding) return;

    if (!_liveIndexLoadAttempted) {
      _liveIndexLoadAttempted = true;
      final cached = await _store.loadLiveChannelIndex();
      if (cached != null && cached.fingerprint == this.liveIndexFingerprint()) {
        await _applyLiveIndex(cached);
        notifyListeners();
        return;
      }
    }

    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
      if (hasLiveIndex || _liveIndexBuilding) return;
    }

    await rebuildLiveIndex();
  }

  List<MediaItem> get catchupChannels =>
      liveChannels.where((m) => m.supportsCatchup).toList();

  /// Resolve a live catalog/pinned row for [item], then [officialLiveTitle].
  ///
  /// User-visible live / catchup channel names should go through this (or
  /// [officialLiveTitle] for pure live rows). Catchup programme titles
  /// (`… (Catchup)`) are kept; DVR channel snapshots become `$official (DVR)`.
  String liveOrCatchupDisplayTitle(MediaItem item) {
    final resolved = _resolvedLiveForDisplay(item);
    final official = officialLiveTitle(resolved);
    if (item.isLive) return official;

    final title = item.title.trim();
    if (RegExp(r'\(Catchup\)\s*$').hasMatch(title)) return title;
    if (RegExp(r'\(DVR\)\s*$').hasMatch(title)) return '$official (DVR)';
    return official;
  }

  /// Other live streams that share this channel's family (quality variants).
  List<MediaItem> qualityVariantsFor(MediaItem channel) {
    final key = liveFamilyKey(channel) ?? _liveFamilyKeyById?[channel.id];
    if (key != null) {
      final cached = _liveFamilyIndex?[key];
      if (cached != null && cached.isNotEmpty) return cached;
    }

    if (key == null) return [channel];

    // Prefer a prebuilt index when we already paid for it.
    if (_liveFamilyIndex != null &&
        identical(_liveFamilyIndexNamesRef, epgChannelNames) &&
        _liveFamilyKeyById != null) {
      final variants = _liveFamilyIndex![key];
      if (variants == null || variants.isEmpty) return [channel];
      return variants;
    }

    // SQLite path: sync callers should use [qualityVariantsForAsync].
    if (_useLiveDb) return [channel];

    // Lazy: match by family key (name- or epg-based). Do not match on tvg-id
    // alone — quality variants often share a cleaned title / EPG display name
    // while carrying different tvg-ids, and the list collapse already groups
    // them by [liveFamilyKey]. The player overlay asks for this on every
    // position tick, so results are memoized until the channel list itself is
    // replaced.
    final channels = liveChannels;
    if (!identical(_lazyVariantChannelsRef, channels)) {
      _lazyVariantCache.clear();
      _lazyVariantChannelsRef = channels;
    }
    final memo = _lazyVariantCache[key];
    if (memo != null) return memo.isEmpty ? [channel] : memo;

    final matches = <MediaItem>[];
    for (final c in channels) {
      if (liveFamilyKey(c) == key) matches.add(c);
    }
    if (matches.isEmpty) {
      _lazyVariantCache[key] = const [];
      return [channel];
    }
    matches.sort(ChannelQuality.compareVariants);
    _lazyVariantCache[key] = matches;
    return matches;
  }

  Future<List<MediaItem>> qualityVariantsForAsync(MediaItem channel) async {
    if (_useLiveDb) {
      final variants = await _liveDb.variantsForChannel(channel);
      if (variants.isNotEmpty) {
        _rememberLiveVariants(channel, variants);
        return variants;
      }
      // Empty = not indexed yet (or stale id). Fall through rather than
      // caching a fake single-variant family.
    }
    return qualityVariantsFor(channel);
  }

  /// Preferred (or best) stream for a channel family.
  ///
  /// Order: session override → explicit remembered pref → Auto
  /// ([ChannelQuality.compareVariants] sort, already applied to variants).
  /// Auto skips UHD/4K when the display is not UHD-capable.
  MediaItem resolveLiveChannel(MediaItem channel) {
    final variants = qualityVariantsFor(channel);
    if (variants.isEmpty) return channel;
    final key = liveFamilyKey(channel) ?? _liveFamilyKeyById?[channel.id];
    return ChannelQuality.pickVariant(
      variants,
      sessionStreamId: key == null ? null : _sessionLiveQualities[key],
      preferredStreamId: key == null ? null : preferredLiveQualities[key],
      allowUhd: DisplayCapability.supportsUhd(),
    );
  }

  Future<MediaItem> resolveLiveChannelAsync(MediaItem channel) async {
    final variants = await qualityVariantsForAsync(channel);
    if (variants.isEmpty) return channel;
    final key =
        liveFamilyKey(channel) ??
        _liveFamilyKeyById?[channel.id] ??
        await _liveDb.familyKeyFor(channel.id);
    return ChannelQuality.pickVariant(
      variants,
      sessionStreamId: key == null ? null : _sessionLiveQualities[key],
      preferredStreamId: key == null ? null : preferredLiveQualities[key],
      allowUhd: DisplayCapability.supportsUhd(),
    );
  }

  /// Stream to use for timeshift / DVR / start-over URLs.
  ///
  /// Prefers [channel] when it has catchup; otherwise the best catchup-capable
  /// sibling in the live family (highest quality, then longest archive days).
  /// Returns null when no sibling can archive.
  MediaItem? resolveCatchupChannel(MediaItem channel) {
    if (channel.supportsCatchup && (channel.streamId ?? '').isNotEmpty) {
      return channel;
    }
    return ChannelQuality.pickCatchupSibling(qualityVariantsFor(channel));
  }

  Future<MediaItem?> resolveCatchupChannelAsync(MediaItem channel) async {
    if (channel.supportsCatchup && (channel.streamId ?? '').isNotEmpty) {
      return channel;
    }
    final variants = await qualityVariantsForAsync(channel);
    return ChannelQuality.pickCatchupSibling(variants);
  }

  /// Whether this channel or a live-family sibling supports catchup/DVR.
  bool liveSupportsCatchup(MediaItem channel) {
    if (channel.supportsCatchup) return true;
    if (liveFamilyCatchupDays(channel) > 0) return true;
    return resolveCatchupChannel(channel) != null;
  }

  Future<bool> liveSupportsCatchupAsync(MediaItem channel) async =>
      (await resolveCatchupChannelAsync(channel)) != null;

  /// Persist an explicit per-channel-family quality (opt-in "Remember").
  Future<void> setPreferredLiveQuality(MediaItem channel) async {
    final key =
        liveFamilyKey(channel) ?? await _liveDb.familyKeyFor(channel.id);
    final streamId = channel.streamId;
    if (key == null || streamId == null) return;
    preferredLiveQualities = {...preferredLiveQualities, key: streamId};
    _sessionLiveQualities = {..._sessionLiveQualities, key: streamId};
    await _store.savePreferredLiveQualities(preferredLiveQualities);
    notifyListeners();
  }

  /// Whether the user already picked a remembered stream for this family.
  bool hasPreferredLiveQuality(MediaItem channel) {
    final key = liveFamilyKey(channel) ?? _liveFamilyKeyById?[channel.id];
    if (key == null) return false;
    final preferredId = preferredLiveQualities[key];
    return preferredId != null && preferredId.isNotEmpty;
  }

  Future<bool> hasPreferredLiveQualityAsync(MediaItem channel) async {
    if (hasPreferredLiveQuality(channel)) return true;
    final key =
        liveFamilyKey(channel) ?? await _liveDb.familyKeyFor(channel.id);
    if (key == null) return false;
    final preferredId = preferredLiveQualities[key];
    return preferredId != null && preferredId.isNotEmpty;
  }

  /// Collapse filtered live rows so each channel family appears once.
  List<MediaItem> collapseLiveQualities(List<MediaItem> channels) {
    final counts = <String, int>{};
    // Small/medium lists (category-scoped): collapse locally — building the
    // full 28k family index on first TV open is a multi-frame hitch.
    if (channels.length <= 800) {
      final seen = <String>{};
      final out = <MediaItem>[];
      final byKey = <String, List<MediaItem>>{};
      for (final channel in channels) {
        final key = liveFamilyKey(channel);
        if (key == null) {
          final row = channel.copyWith(title: officialLiveTitle(channel));
          counts[row.id] = 1;
          out.add(row);
          continue;
        }
        byKey.putIfAbsent(key, () => []).add(channel);
      }
      for (final entry in byKey.entries) {
        if (!seen.add(entry.key)) continue;
        final variants = [...entry.value]..sort(ChannelQuality.compareVariants);
        final preferredId = preferredLiveQualities[entry.key];
        final resolved = ChannelQuality.pickVariant(
          variants,
          preferredStreamId: preferredId,
          allowUhd: DisplayCapability.supportsUhd(),
        );
        final row = resolved.copyWith(
          title: ChannelQuality.familyDisplayTitle(
            resolved,
            variants,
            officialNameOf: epgDisplayNameFor,
          ),
        );
        counts[row.id] = variants.length;
        _rememberFamilyCatchupFromVariants(variants);
        out.add(row);
      }
      _liveVariantCountById = counts;
      return out;
    }

    _ensureLiveFamilyIndex();
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final channel in channels) {
      final key = _liveFamilyKeyById![channel.id] ?? liveFamilyKey(channel);
      if (key == null) {
        final row = channel.copyWith(title: officialLiveTitle(channel));
        counts[row.id] = 1;
        out.add(row);
        continue;
      }
      if (!seen.add(key)) continue;
      final variants = _liveFamilyIndex![key] ?? const <MediaItem>[];
      final resolved = resolveLiveChannel(channel);
      final row = resolved.copyWith(
        title: variants.length > 1
            ? ChannelQuality.familyDisplayTitle(
                resolved,
                variants,
                officialNameOf: epgDisplayNameFor,
              )
            : officialLiveTitle(resolved),
      );
      counts[row.id] = variants.isEmpty ? 1 : variants.length;
      if (variants.isNotEmpty) {
        _rememberFamilyCatchupFromVariants(variants);
      }
      out.add(row);
    }
    _liveVariantCountById = counts;
    return out;
  }

  /// Fetch one live category when TV needs it and the local group is empty/stale.
  ///
  /// Warm SQLite listings return immediately (restart-safe). A stale group
  /// still paints from cache and refreshes in the background without clearing.
  Future<void> ensureLiveCategoryAvailable(IptvCategory category) async {
    if (category.kind != IptvCategoryKind.live) return;
    if (category.id.isEmpty) return;
    final ownedSourceId = category.sourceId;
    final source = sources.cast<IptvSource?>().firstWhere((s) {
      if (s == null || s.type != IptvSourceType.xtream || !s.enabled) {
        return false;
      }
      if (ownedSourceId != null && ownedSourceId.isNotEmpty) {
        return s.id == ownedSourceId;
      }
      return true;
    }, orElse: () => null);
    if (source == null) return;

    final key = '${source.id}|${category.id}';
    final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
    if (_liveCategoryFilledEpoch[key] == epoch) return;

    final listings = await _liveDb.countListingsInGroup(
      sourceId: source.id,
      groupName: category.name,
    );
    if (listings > 0) {
      final stale = await _liveDb.groupIsStale(
        sourceId: source.id,
        groupName: category.name,
        maxAge: LibraryProvider._liveCategoryFreshness,
      );
      if (stale) {
        // Paint from SQLite; refresh without clearing. Do not stamp the
        // session fill mark yet — [loadLiveCategory] with background/fromPrefetch
        // would no-op on that mark before hitting the network.
        unawaited(loadLiveCategory(category, background: true));
      } else {
        _liveCategoryFilledEpoch[key] = epoch;
        unawaited(
          _liveDb.touchGroupFilledIfMissing(
            sourceId: source.id,
            groupName: category.name,
          ),
        );
      }
      return;
    }
    await loadLiveCategory(category);
  }

  /// Fetch Xtream live streams for one category and upsert into the live DB.
  Future<void> loadLiveCategory(
    IptvCategory category, {
    bool background = false,
  }) async {
    if (category.kind != IptvCategoryKind.live) return;
    final ownedSourceId = category.sourceId;
    final source = sources.cast<IptvSource?>().firstWhere((s) {
      if (s == null || s.type != IptvSourceType.xtream || !s.enabled) {
        return false;
      }
      if (ownedSourceId != null && ownedSourceId.isNotEmpty) {
        return s.id == ownedSourceId;
      }
      return true;
    }, orElse: () => null);
    if (source == null) return;

    final key = '${source.id}|${category.id}';
    final existing = _liveCategoryLoads[key];
    if (existing != null) {
      if (background || _liveCategoryInteractiveLoads.contains(key)) {
        await existing;
        if (!background) {
          liveDbRevision++;
          await _reloadPinnedLiveChannels();
          _notifyPierceQuiet();
        }
        return;
      }
      // Prefetch owns the in-flight load. Do not join that fetch: it may
      // still be queued in acquireBackgroundHttp, and wrapping the wait in
      // [_runUserFacing] would deadlock. Fetch interactively instead.
      final promoted = _runUserFacing(
        () => _loadLiveCategoryBody(source, category, key, fromPrefetch: false),
      );
      _liveCategoryLoads[key] = promoted;
      _liveCategoryInteractiveLoads.add(key);
      try {
        await promoted;
      } finally {
        _liveCategoryInteractiveLoads.remove(key);
        if (identical(_liveCategoryLoads[key], promoted)) {
          _liveCategoryLoads.remove(key);
        }
      }
      return;
    }

    Future<void> run() =>
        _loadLiveCategoryBody(source, category, key, fromPrefetch: background);
    final future = background ? run() : _runUserFacing(run);
    _liveCategoryLoads[key] = future;
    if (!background) _liveCategoryInteractiveLoads.add(key);
    try {
      await future;
    } finally {
      if (!background) _liveCategoryInteractiveLoads.remove(key);
      if (identical(_liveCategoryLoads[key], future)) {
        _liveCategoryLoads.remove(key);
      }
    }
  }

  MediaItem? catchupItem({
    required MediaItem channel,
    required EpgProgram program,
  }) {
    final archive = resolveCatchupChannel(channel);
    if (archive == null && !program.hasArchive) return null;
    return liveDvrItem(
      channel: archive ?? channel,
      start: program.start,
      duration: program.duration,
      title: '${program.title} (Catchup)',
      allowWithoutCatchup: program.hasArchive,
    );
  }

  /// Like [catchupItem], but loads live-family siblings from SQLite when the
  /// in-memory index is cold (Home On now / start-over).
  Future<MediaItem?> catchupItemAsync({
    required MediaItem channel,
    required EpgProgram program,
  }) async {
    final archive = await resolveCatchupChannelAsync(channel);
    if (archive == null && !program.hasArchive) return null;
    return liveDvrItem(
      channel: archive ?? channel,
      start: program.start,
      duration: program.duration,
      title: '${program.title} (Catchup)',
      allowWithoutCatchup: program.hasArchive,
    );
  }

  /// Timeshift clip for live DVR scrubbing / EPG catchup.
  ///
  /// When [clampToLive] is true (default), duration is capped at the time
  /// remaining until the live edge — fine for archive programme clips and
  /// media-server Start Over (Plex/Jellyfin/Emby ignore clip duration; they
  /// retune live at an offset). Pass false for Xtream interactive DVR so a
  /// −10s rewind is not a 10s clip that ends at the old live edge.
  ///
  /// When [channel] lacks catchup, a catchup-capable family sibling is used for
  /// stream id / archive window (live Auto can stay on best quality).
  MediaItem? liveDvrItem({
    required MediaItem channel,
    required DateTime start,
    Duration? duration,
    String? title,
    bool allowWithoutCatchup = false,
    bool clampToLive = true,
  }) {
    final archive =
        resolveCatchupChannel(channel) ??
        (allowWithoutCatchup ? channel : null);
    if (archive == null) return null;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == archive.sourceId,
      orElse: () => null,
    );
    if (source == null || archive.streamId == null) return null;
    if (!archive.supportsCatchup && !allowWithoutCatchup) return null;

    final now = DateTime.now();
    final maxWindow = Duration(days: archive.catchupDays.clamp(1, 14));
    final earliest = now.subtract(maxWindow);
    var safeStart = start.isAfter(now) ? now : start;
    if (safeStart.isBefore(earliest)) safeStart = earliest;

    // Panels often reject huge windows; request a scrub-sized slice from start.
    final untilLive = now.difference(safeStart);
    final playDuration = duration ?? untilLive;
    var safeDuration = playDuration.inSeconds <= 0
        ? const Duration(minutes: 1)
        : playDuration;
    if (safeDuration > const Duration(hours: 3)) {
      safeDuration = const Duration(hours: 3);
    }
    if (clampToLive && safeDuration > untilLive && untilLive.inSeconds > 0) {
      safeDuration = untilLive;
    }

    if (source.type.isMediaServer) {
      final serverItemId = _mediaServerTimeshiftServerItemId(
        archive,
        safeStart,
      );
      if (serverItemId == null) return null;
      return MediaItem(
        id: 'dvr-${archive.streamId}-${safeStart.millisecondsSinceEpoch}',
        title: title ?? '${channel.title} (DVR)',
        playUrl: '',
        kind: MediaKind.catchup,
        origin: archive.origin,
        subtitle: channel.title,
        thumbnailUrl: channel.thumbnailUrl ?? archive.thumbnailUrl,
        group: channel.group ?? archive.group,
        duration: safeDuration,
        channelId: archive.channelId,
        streamId: archive.streamId,
        epgChannelId: channel.epgChannelId ?? archive.epgChannelId,
        catchupDays: archive.catchupDays,
        sourceId: archive.sourceId,
        serverItemId: serverItemId,
        resolution: mediaServerStreamQuality.name,
      );
    }

    if (source.type != IptvSourceType.xtream) return null;

    final url = _xtream.catchupUrl(
      source: source,
      streamId: archive.streamId!,
      start: safeStart,
      duration: safeDuration,
    );

    return MediaItem(
      id: 'dvr-${archive.streamId}-${safeStart.millisecondsSinceEpoch}',
      title: title ?? '${channel.title} (DVR)',
      playUrl: url,
      kind: MediaKind.catchup,
      origin: MediaOrigin.iptvXtream,
      subtitle: channel.title,
      thumbnailUrl: channel.thumbnailUrl ?? archive.thumbnailUrl,
      group: channel.group ?? archive.group,
      duration: safeDuration,
      channelId: archive.channelId,
      streamId: archive.streamId,
      epgChannelId: channel.epgChannelId ?? archive.epgChannelId,
      catchupDays: archive.catchupDays,
      sourceId: archive.sourceId,
    );
  }
}
