import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:javp/compat/javp_compute.dart';
import 'package:javp/compat/json_file_isolate.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/custom_caption_font.dart';
import 'package:javp/models/epg_reminder.dart';
import 'package:javp/models/home_shelf_snapshot.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/library_collection.dart';
import 'package:javp/models/library_playlist.dart';
import 'package:javp/models/live_channel_index.dart';
import 'package:javp/models/live_quality_mode.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/models/display_settings.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/models/my_list_ui_prefs.dart';
import 'package:javp/models/betaseries_models.dart';
import 'package:javp/models/serializd_models.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/models/track_language_settings.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/log_redactor.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:javp/services/storage/channel_sources_bridge.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LibraryStore {
  LibraryStore({
    SharedPreferences? prefs,
    FlutterSecureStorage? secureStorage,
    String profileId = Profile.defaultId,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       profileId = profileId.isEmpty ? Profile.defaultId : profileId {
    _rawPrefs = prefs;
  }

  /// Which profile's data this store reads and writes.
  final String profileId;

  SharedPreferences? _rawPrefs;
  _ScopedPrefs? _scopedPrefs;
  Future<_ScopedPrefs>? _prefsFuture;
  final FlutterSecureStorage _secure;

  /// The default profile keeps the original, unprefixed keys and file names so
  /// installs that predate profiles need no migration.
  String get _keyPrefix =>
      profileId == Profile.defaultId ? '' : 'profile.$profileId.';

  static const _sourcesKey = 'iptv_sources';
  static const _sourcesUpdatedAtKey = 'iptv_sources_updated_at';
  static const _catalogKey = 'media_catalog';
  static const _historyKey = 'watch_history';
  static const _historyDeletedKey = 'watch_history_deleted';
  static const _localKey = 'local_media';
  static const _simklKey = 'simkl_credentials';
  static const _simklActivitiesKey = 'simkl_activities';
  static const _simklWatchingKey = 'simkl_watching_items';
  static const _simklPlanToWatchKey = 'simkl_plan_to_watch_items';
  static const _simklLastSyncKey = 'simkl_last_sync_at';
  static const _simklSyncDateFromKey = 'simkl_sync_date_from';
  static const _traktWatchlistKey = 'trakt_watchlist_items';
  static const _plexWatchlistKey = 'plex_watchlist_items';
  static const _traktLastActivitiesKey = 'trakt_last_activities';
  static const _traktLastSyncKey = 'trakt_last_sync_at';
  static const _serializdKey = 'serializd_credentials';
  static const _serializdWatchingKey = 'serializd_watching_items';
  static const _serializdWatchlistKey = 'serializd_watchlist_items';
  static const _serializdLastSyncKey = 'serializd_last_sync_at';
  static const _serializdPendingScrobblesKey = 'pending_serializd_scrobbles';
  static const _betaseriesKey = 'betaseries_credentials';
  static const _betaseriesWatchingKey = 'betaseries_watching_items';
  static const _betaseriesPlanKey = 'betaseries_plan_items';
  static const _betaseriesLastSyncKey = 'betaseries_last_sync_at';
  static const _letterboxdWatchlistKey = 'letterboxd_watchlist_items';
  static const _letterboxdLastImportKey = 'letterboxd_last_import_at';
  static const _trackerStatusesKey = 'tracker_status_entries';
  static const _captionStyleKey = 'caption_style';
  static const _customCaptionFontsKey = 'caption_custom_fonts';
  static const _categoriesKey = 'iptv_categories';
  static const _watchlistKey = 'watchlist';
  static const _favoriteChannelsKey = 'favorite_channel_ids';
  static const _favoriteCategoriesKey = 'favorite_category_ids';
  static const _recentChannelsKey = 'recent_channel_ids';
  static const _preferredQualitiesKey = 'preferred_live_qualities';
  static const _preferredVodVariantsKey = 'preferred_vod_variants';
  static const _liveScrubModeKey = 'live_scrub_mode';
  static const _cyclePlaybackSpeedsKey = 'cycle_playback_speeds';
  static const _liveQualityModeKey = 'live_quality_mode';
  static const _epgRemindersKey = 'epg_reminders';
  static const _deepSyncedSourcesKey = 'deep_synced_sources';
  static const _catalogFileName = 'media_catalog.json';
  static const _vodCacheFileName = 'vod_stream_cache.json';
  static const _liveIndexFileName = 'live_channel_index.json';
  static const _homeShelfSnapshotFileName = 'home_shelf_snapshot.json';
  static const _sourcePasswordKeyPrefix = 'iptv_source_password.';
  static const _sourcePlexAccountKeyPrefix = 'iptv_source_plex_account.';
  static const _plexActiveUrlKeyPrefix = 'plex_active_url.';

  String _sourcePasswordKey(String sourceId) =>
      _secureKey('$_sourcePasswordKeyPrefix$sourceId');

  String _sourcePlexAccountKey(String sourceId) =>
      _secureKey('$_sourcePlexAccountKeyPrefix$sourceId');

  /// Callers now load in parallel, so the in-flight future is cached too —
  /// otherwise every concurrent first caller opens its own wrapper.
  Future<_ScopedPrefs> _ensurePrefs() {
    final ready = _scopedPrefs;
    if (ready != null) return Future.value(ready);
    return _prefsFuture ??= () async {
      final raw = _rawPrefs ??= await SharedPreferences.getInstance();
      return _scopedPrefs = _ScopedPrefs(raw, _keyPrefix);
    }();
  }

  String _secureKey(String key) => '$_keyPrefix$key';

  /// `{Documents}/JAVP` for the active profile; non-default profiles get a
  /// subdir. Legacy files at the Documents root are moved on first access.
  ///
  /// On web there is no real filesystem — callers that write catalog/VOD files
  /// must catch and fall back to SharedPreferences (see [saveCatalog]).
  Future<Directory> profileDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('Profile disk directory is unavailable on web');
    }
    return AppDocuments.profileDirectory(profileId);
  }

  Future<File> _catalogFile() async {
    final dir = await profileDirectory();
    return File('${dir.path}/$_catalogFileName');
  }

  Future<File> _vodCacheFile() async {
    final dir = await profileDirectory();
    return File('${dir.path}/$_vodCacheFileName');
  }

  Future<File> _homeShelfSnapshotFile() async {
    final dir = await profileDirectory();
    return File('${dir.path}/$_homeShelfSnapshotFileName');
  }

  /// Last Accueil shelf paint — small file, safe on the cold-start critical path.
  Future<HomeShelfSnapshot?> loadHomeShelfSnapshot() async {
    try {
      final file = await _homeShelfSnapshotFile();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      return HomeShelfSnapshot.tryDecode(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHomeShelfSnapshot(HomeShelfSnapshot snapshot) async {
    try {
      final file = await _homeShelfSnapshotFile();
      final encoded = jsonEncode(snapshot.toJson());
      await file.writeAsString(encoded, flush: true);
    } catch (_) {
      // Best-effort cold-start paint cache.
    }
  }

  /// Drop the last-close Accueil cache (catalog removed / shelves empty).
  Future<void> clearHomeShelfSnapshot() async {
    try {
      final file = await _homeShelfSnapshotFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort.
    }
  }

  Future<List<IptvSource>> loadSources() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null) {
      final adopted = await _adoptSiblingSourcesIfNeeded(
        local: const [],
        localUpdatedAt: null,
      );
      if (adopted != null) return adopted;
      return [];
    }
    final list = await _decodeMapList(raw);
    final sources = list
        .map(IptvSource.tryFromJson)
        .whereType<IptvSource>()
        .toList();
    var needsResave = sources.length != list.length;
    // One keystore round-trip per source adds up on a big install, and they
    // don't depend on each other. Reads are safe to overlap; the migration
    // writes below stay serialized.
    final passwords = await Future.wait([
      for (final source in sources)
        _secure.read(key: _sourcePasswordKey(source.id)),
    ]);
    final plexAccounts = await Future.wait([
      for (final source in sources)
        source.type == IptvSourceType.plex
            ? _secure.read(key: _sourcePlexAccountKey(source.id))
            : Future<String?>.value(null),
    ]);
    final hydrated = <IptvSource>[];
    for (var i = 0; i < sources.length; i++) {
      var source = sources[i];
      final securePass = passwords[i];
      if (securePass != null && securePass.isNotEmpty) {
        source = source.copyWith(password: securePass);
        // Legacy prefs still held a password — strip on save.
        if (sources[i].password != null && sources[i].password!.isNotEmpty) {
          needsResave = true;
        }
      } else if (source.password != null && source.password!.isNotEmpty) {
        // Migrate plaintext prefs password into secure storage.
        await _secure.write(
          key: _sourcePasswordKey(source.id),
          value: source.password!,
        );
        needsResave = true;
      }
      final securePlex = plexAccounts[i];
      if (securePlex != null && securePlex.isNotEmpty) {
        source = source.copyWith(plexAccountToken: securePlex);
        if (sources[i].plexAccountToken != null &&
            sources[i].plexAccountToken!.isNotEmpty) {
          needsResave = true;
        }
      } else if (source.plexAccountToken != null &&
          source.plexAccountToken!.isNotEmpty) {
        await _secure.write(
          key: _sourcePlexAccountKey(source.id),
          value: source.plexAccountToken!,
        );
        needsResave = true;
      }
      hydrated.add(source);
    }
    // Drop removed/unknown types (e.g. legacy AniZone) and strip migrated
    // passwords from SharedPreferences.
    if (needsResave) {
      await saveSources(hydrated);
    }

    final localUpdatedAt = _readSourcesUpdatedAt(prefs);
    final adopted = await _adoptSiblingSourcesIfNeeded(
      local: hydrated,
      localUpdatedAt: localUpdatedAt,
    );
    final result = adopted ?? hydrated;

    // Panels require raw credentials inside stream URLs, so the exact values
    // have to be known to the log redactor before anything can print one.
    LogRedactor.instance.registerSecrets([
      for (final s in result) ...[s.password, s.plexAccountToken],
    ]);
    return result;
  }

  Future<void> saveSources(List<IptvSource> sources) async {
    final prefs = await _ensurePrefs();
    for (final source in sources) {
      final key = _sourcePasswordKey(source.id);
      final password = source.password;
      if (password != null && password.isNotEmpty) {
        await _secure.write(key: key, value: password);
      } else {
        await _secure.delete(key: key);
      }
      final plexKey = _sourcePlexAccountKey(source.id);
      final plexToken = source.plexAccountToken;
      if (source.type == IptvSourceType.plex &&
          plexToken != null &&
          plexToken.isNotEmpty) {
        await _secure.write(key: plexKey, value: plexToken);
      } else {
        await _secure.delete(key: plexKey);
      }
    }
    // Never persist passwords / plex.tv tokens in SharedPreferences JSON.
    final encoded = sources.map((s) {
      final json = s.toJson();
      json.remove('password');
      json.remove('plexAccountToken');
      return json;
    }).toList();
    await prefs.setString(_sourcesKey, jsonEncode(encoded));
    final updatedAt = DateTime.now().toUtc();
    await prefs.setString(_sourcesUpdatedAtKey, updatedAt.toIso8601String());
    LogRedactor.instance.registerSecrets([
      for (final s in sources) ...[s.password, s.plexAccountToken],
    ]);
    // Best-effort Stable ↔ Dev mirror on Android (no-op elsewhere).
    unawaited(
      ChannelSourcesBridge.instance.publish(
        profileId: profileId,
        sources: sources,
        updatedAt: updatedAt,
      ),
    );
  }

  DateTime? _readSourcesUpdatedAt(_ScopedPrefs prefs) {
    final raw = prefs.getString(_sourcesUpdatedAtKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// When Android Dev/Stable sandboxes differ, adopt a newer sibling snapshot.
  Future<List<IptvSource>?> _adoptSiblingSourcesIfNeeded({
    required List<IptvSource> local,
    required DateTime? localUpdatedAt,
  }) async {
    // Empty local: take sibling whenever it has anything.
    // Non-empty local: only a strictly newer sibling stamp wins (Windows-like
    // last-write-wins). Missing local stamp keeps local to avoid clobbering
    // installs that predate this bridge.
    final requireNewer = local.isNotEmpty;
    final snap = await ChannelSourcesBridge.instance.pullSibling(
      profileId: profileId,
      localUpdatedAt: requireNewer ? localUpdatedAt : null,
    );
    if (snap == null) return null;
    if (local.isEmpty && snap.sources.isEmpty) return null;
    if (requireNewer) {
      if (localUpdatedAt == null) return null;
      if (!snap.updatedAt.isAfter(localUpdatedAt)) return null;
    }
    JavpLog.i(
      'channel_sources',
      'adopting sibling sources count=${snap.sources.length} '
          'profile=$profileId',
    );
    await saveSources(snap.sources);
    return snap.sources;
  }

  /// Drops the secure password/token for a removed source.
  Future<void> deleteSourcePassword(String sourceId) async {
    await _secure.delete(key: _sourcePasswordKey(sourceId));
    await _secure.delete(key: _sourcePlexAccountKey(sourceId));
    final prefs = await _ensurePrefs();
    await prefs.remove('$_plexActiveUrlKeyPrefix$sourceId');
  }

  /// Last Plex base that answered `/identity` on this device (not Drive-synced).
  Future<String?> loadPlexActiveUrl(String sourceId) async {
    final prefs = await _ensurePrefs();
    final url = prefs.getString('$_plexActiveUrlKeyPrefix$sourceId')?.trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<void> savePlexActiveUrl(String sourceId, String url) async {
    final prefs = await _ensurePrefs();
    final normalized = normalizeMediaServerBase(url);
    if (normalized.isEmpty) {
      await prefs.remove('$_plexActiveUrlKeyPrefix$sourceId');
      return;
    }
    await prefs.setString('$_plexActiveUrlKeyPrefix$sourceId', normalized);
  }

  Future<List<IptvCategory>> loadCategories() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_categoriesKey);
    if (raw == null) return [];
    final list = await _decodeMapList(raw);
    return mapYielding(
      list,
      IptvCategory.fromJson,
      label: 'catalog-categories-map',
    );
  }

  Future<void> saveCategories(List<IptvCategory> categories) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _categoriesKey,
      jsonEncode(categories.map((c) => c.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadCatalog({
    Future<void> Function(List<MediaItem> live)? onLiveStripped,
    bool skipLiveHydrate = false,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final file = await _catalogFile();
      if (await file.exists()) {
        final length = await file.length();
        final readMs = watch.elapsedMilliseconds;
        if (length <= 0) {
          JavpLog.i('catalog', 'load in ${readMs}ms items=0 read=$readMs');
          return [];
        }
        watch.reset();
        final decoded = await _decodeCatalogInIsolate(
          sourcePath: file.path,
          rewritePath: file.path,
          fileLength: length,
        );
        final decodeMs = watch.elapsedMilliseconds;
        watch.reset();
        final items = await _hydrateCatalogMaps(
          decoded,
          onLiveStripped: onLiveStripped,
          skipLiveHydrate: skipLiveHydrate,
        );
        final hydrateMs = watch.elapsedMilliseconds;
        JavpLog.i(
          'catalog',
          'load in ${readMs + decodeMs + hydrateMs}ms '
              'items=${items.length} read=$readMs decode=$decodeMs '
              'hydrate=$hydrateMs skipLive=$skipLiveHydrate',
        );
        return items;
      }
    } catch (_) {
      // Tests / unsupported platforms fall back to SharedPreferences.
    }

    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_catalogKey);
    if (raw == null) {
      JavpLog.i(
        'catalog',
        'load in ${watch.elapsedMilliseconds}ms items=0 source=prefs',
      );
      return [];
    }
    final bytes = utf8.encode(raw);
    final readMs = watch.elapsedMilliseconds;
    watch.reset();
    final decoded = await _decodeCatalogInIsolate(bytes: bytes);
    final decodeMs = watch.elapsedMilliseconds;
    watch.reset();
    final items = await _hydrateCatalogMaps(
      decoded,
      onLiveStripped: onLiveStripped,
      skipLiveHydrate: skipLiveHydrate,
    );
    final hydrateMs = watch.elapsedMilliseconds;
    JavpLog.i(
      'catalog',
      'load in ${readMs + decodeMs + hydrateMs}ms '
          'items=${items.length} read=$readMs decode=$decodeMs '
          'hydrate=$hydrateMs source=prefs',
    );
    return items;
  }

  /// Spread fromJson across frames so a large catalog doesn't freeze startup.
  Future<List<MediaItem>> _hydrateCatalogMaps(
    _DecodedCatalog parsed, {
    Future<void> Function(List<MediaItem> live)? onLiveStripped,
    bool skipLiveHydrate = false,
  }) async {
    if (parsed.liveMaps.isNotEmpty) {
      if (kIsWeb || onLiveStripped == null) {
        // Web has no LiveChannelDb — keep live rows in the catalog list.
        return _hydrateInSlices([
          ...parsed.maps,
          ...parsed.liveMaps,
        ], MediaItem.fromJson);
      }
      // Native + SQLite already authoritative: skip fromJson of liveMaps.
      if (!skipLiveHydrate) {
        await onLiveStripped(
          await _hydrateInSlices(parsed.liveMaps, MediaItem.fromJson),
        );
      }
    }

    return _hydrateInSlices(parsed.maps, MediaItem.fromJson);
  }

  Future<void> saveCatalog(List<MediaItem> items) async {
    // Never persist Xtream VOD/series into the live catalog file again.
    // Snapshot toJson maps with frequent yields, then jsonEncode off-isolate so
    // a large library never monopolizes the UI isolate for a full encode.
    final watch = Stopwatch()..start();
    final maps = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind == MediaKind.live && !kIsWeb) continue;
      if (item.origin == MediaOrigin.iptvXtream &&
          (item.kind == MediaKind.vod || item.kind == MediaKind.series)) {
        continue;
      }
      maps.add(item.toJson());
      await yieldUiSlice(
        slice,
        i: i,
        checkMask: 31,
        label: 'catalog-save-maps',
      );
    }
    final mapMs = watch.elapsedMilliseconds;
    watch.reset();
    if (!kIsWeb) {
      try {
        final file = await _catalogFile();
        await writeJsonMapsToFileInIsolate(path: file.path, maps: maps);
        final prefs = await _ensurePrefs();
        await prefs.remove(_catalogKey);
        final writeMs = watch.elapsedMilliseconds;
        JavpLog.i(
          'catalog',
          'save in ${mapMs + writeMs}ms '
              'items=${maps.length} map=$mapMs encode+write=$writeMs',
        );
        return;
      } catch (_) {
        // Fall back below.
      }
    }
    final encoded = kIsWeb
        ? jsonEncode(maps)
        : await javpCompute(() => jsonEncode(maps), debugLabel: 'catalog-json');
    final prefs = await _ensurePrefs();
    await prefs.setString(_catalogKey, encoded);
    final writeMs = watch.elapsedMilliseconds;
    JavpLog.i(
      'catalog',
      'save in ${mapMs + writeMs}ms '
          'items=${maps.length} map=$mapMs encode+write=$writeMs '
          'source=prefs',
    );
  }

  /// Persisted Xtream movies/series cache (separate from the live catalog file).
  ///
  /// JSON decode + [MediaItem.fromJson] run on a worker isolate. Results are
  /// streamed in chunks so the UI isolate can yield between receives — a single
  /// 200k+ item handoff was freezing Windows ("Not Responding") for ~1 minute.
  Future<List<MediaItem>> loadVodCache({
    Set<String>? knownSourceIds,
    String localSourceKey = '__local__',
  }) async {
    try {
      final file = await _vodCacheFile();
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return const [];
      final watch = Stopwatch()..start();
      final known = knownSourceIds == null
          ? null
          : List<String>.from(knownSourceIds, growable: false);
      final items = await _parseVodCacheBytesChunked(
        bytes,
        knownSourceIds: known,
        localSourceKey: localSourceKey,
      );
      JavpLog.i(
        'vod',
        'disk cache parse ${watch.elapsedMilliseconds}ms items=${items.length} '
            'bytes=${bytes.length}',
      );
      return items;
    } catch (e) {
      JavpLog.w('vod', 'disk cache parse failed', error: e);
      return const [];
    }
  }

  /// Maps per isolate→UI message. [MediaItem] graphs used to crash the
  /// Windows embedder on copy-back; maps + [fromJson] on this isolate with
  /// yields stay inside a frame.
  static const _vodParseChunkSize = kIsolateListChunk;

  static Future<List<MediaItem>> _parseVodCacheBytesChunked(
    Uint8List bytes, {
    List<String>? knownSourceIds,
    required String localSourceKey,
  }) async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    final args = _VodCacheParseArgs(
      reply: receive.sendPort,
      bytes: bytes,
      chunkSize: _vodParseChunkSize,
      knownSourceIds: knownSourceIds,
      localSourceKey: localSourceKey,
    );
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _vodCacheParseIsolateMain,
        args,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      receive.close();
      errors.close();
      rethrow;
    }

    final items = <MediaItem>[];
    Object? isolateError;
    final errorSub = errors.listen((msg) {
      isolateError ??= msg;
    });
    final slice = Stopwatch()..start();
    try {
      await for (final message in receive) {
        if (isolateError != null) {
          throw isolateError!;
        }
        if (message == null) break;
        if (message is List) {
          for (final row in message) {
            if (row is! Map) continue;
            try {
              items.add(MediaItem.fromJson(Map<String, dynamic>.from(row)));
            } catch (_) {}
            await yieldUiIfDue(slice, label: 'vod-cache-hydrate');
          }
          await yieldAfterIsolateChunk();
        }
      }
      if (isolateError != null) throw isolateError!;
      return items;
    } finally {
      await errorSub.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  }

  @pragma('vm:entry-point')
  static void _vodCacheParseIsolateMain(_VodCacheParseArgs args) {
    try {
      final decoded = jsonDecode(utf8.decode(args.bytes));
      if (decoded is! List) {
        args.reply.send(null);
        return;
      }
      final known = args.knownSourceIds == null
          ? null
          : {...args.knownSourceIds!};
      final localKey = args.localSourceKey;
      final chunk = <Map<String, dynamic>>[];
      void flush() {
        if (chunk.isEmpty) return;
        args.reply.send(List<Map<String, dynamic>>.from(chunk));
        chunk.clear();
      }

      for (final entry in decoded) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        if (known != null) {
          final sid = '${map['sourceId'] ?? ''}';
          if (sid.isNotEmpty && sid != localKey && !known.contains(sid)) {
            continue;
          }
        }
        chunk.add(map);
        if (chunk.length >= args.chunkSize) flush();
      }
      flush();
    } finally {
      args.reply.send(null);
    }
  }

  Future<void> saveVodCache(Iterable<MediaItem> items) async {
    // Snapshot toJson with yields — a tight 200k-row loop ANRs Windows.
    final maps = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    var i = 0;
    for (final item in items) {
      if (item.kind != MediaKind.vod && item.kind != MediaKind.series) continue;
      maps.add(item.toJson());
      await yieldUiSlice(slice, i: i++, label: 'vod-cache-save-maps');
    }
    try {
      final file = await _vodCacheFile();
      await writeJsonMapsToFileInIsolate(path: file.path, maps: maps);
    } catch (_) {}
  }

  Future<File> _liveIndexFile() async {
    final dir = await profileDirectory();
    return File('${dir.path}/$_liveIndexFileName');
  }

  Future<LiveChannelIndex?> loadLiveChannelIndex() async {
    try {
      final file = await _liveIndexFile();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      return await javpCompute(() {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        return LiveChannelIndex.fromJson(Map<String, dynamic>.from(decoded));
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLiveChannelIndex(LiveChannelIndex index) async {
    try {
      final file = await _liveIndexFile();
      await writeJsonValueToFileInIsolate(
        path: file.path,
        value: index.toJson(),
      );
    } catch (_) {
      // Index is a speed cache — failure is non-fatal.
    }
  }

  Future<List<MediaItem>> loadHistory() async {
    return _loadMediaItemList(_historyKey);
  }

  Future<void> saveHistory(List<MediaItem> items) async {
    // Snapshot maps with yields, then encode off-isolate — history is ≤200
    // rows but toJson on the UI isolate still hitchs mid-playback flushes.
    final maps = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < items.length; i++) {
      maps.add(items[i].toJson());
      await yieldUiSlice(
        slice,
        i: i,
        checkMask: 31,
        label: 'history-save-maps',
      );
    }
    final prefs = await _ensurePrefs();
    await prefs.setString(_historyKey, await _encodeJson(maps, maps.length));
  }

  /// Per-id tombstones for watch history so sync cannot resurrect a removal.
  Future<Map<String, DateTime>> loadHistoryDeleted() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_historyDeletedKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, DateTime>{};
      for (final e in decoded.entries) {
        final id = '${e.key}'.trim();
        if (id.isEmpty) continue;
        final at = DateTime.tryParse('${e.value}')?.toUtc();
        if (at == null) continue;
        out[id] = at;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveHistoryDeleted(Map<String, DateTime> deleted) async {
    final prefs = await _ensurePrefs();
    if (deleted.isEmpty) {
      await prefs.remove(_historyDeletedKey);
      return;
    }
    final map = {
      for (final e in deleted.entries) e.key: e.value.toUtc().toIso8601String(),
    };
    await prefs.setString(_historyDeletedKey, jsonEncode(map));
  }

  Future<List<MediaItem>> loadLocalMedia() async {
    return _loadMediaItemList(_localKey);
  }

  Future<void> saveLocalMedia(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    final maps = items.map((i) => i.toJson()).toList();
    await prefs.setString(_localKey, await _encodeJson(maps, maps.length));
  }

  Future<List<MediaItem>> _loadMediaItemList(String key) async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return _hydrateInSlices(await _decodeMapList(raw), MediaItem.fromJson);
    } catch (_) {
      return [];
    }
  }

  Future<SimklCredentials> loadSimkl() async {
    final raw = await _secure.read(key: _secureKey(_simklKey));
    if (raw == null) return const SimklCredentials(clientId: '');
    final credentials = SimklCredentials.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    LogRedactor.instance.registerSecret(credentials.accessToken);
    return credentials;
  }

  Future<void> saveSimkl(SimklCredentials credentials) async {
    await _secure.write(
      key: _secureKey(_simklKey),
      value: jsonEncode(credentials.toJson()),
    );
  }

  Future<SimklActivities?> loadSimklActivities() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_simklActivitiesKey);
    if (raw == null) return null;
    try {
      return SimklActivities.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSimklActivities(SimklActivities activities) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_simklActivitiesKey, jsonEncode(activities.toJson()));
  }

  /// The cached Watching shelf is read before first paint, so it gets the same
  /// off-isolate decode and chunked hydration as history and the watchlist.
  Future<List<MediaItem>> loadSimklWatching() async {
    return _loadMediaItemList(_simklWatchingKey);
  }

  Future<void> saveSimklWatching(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _simklWatchingKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadSimklPlanToWatch() async {
    return _loadMediaItemList(_simklPlanToWatchKey);
  }

  Future<void> saveSimklPlanToWatch(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _simklPlanToWatchKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadTraktWatchlist() async {
    return _loadMediaItemList(_traktWatchlistKey);
  }

  Future<void> saveTraktWatchlist(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _traktWatchlistKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadPlexWatchlist() async {
    return _loadMediaItemList(_plexWatchlistKey);
  }

  Future<void> savePlexWatchlist(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _plexWatchlistKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<TraktLastActivities?> loadTraktLastActivities() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_traktLastActivitiesKey);
    if (raw == null) return null;
    try {
      return TraktLastActivities.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTraktLastActivities(TraktLastActivities activities) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _traktLastActivitiesKey,
      jsonEncode(activities.toJson()),
    );
  }

  Future<DateTime?> loadTraktLastSyncAt() async {
    final prefs = await _ensurePrefs();
    return DateTime.tryParse(prefs.getString(_traktLastSyncKey) ?? '');
  }

  Future<List<MediaItem>> loadLetterboxdWatchlist() async {
    return _loadMediaItemList(_letterboxdWatchlistKey);
  }

  Future<void> saveLetterboxdWatchlist(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _letterboxdWatchlistKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<DateTime?> loadLetterboxdLastImportAt() async {
    final prefs = await _ensurePrefs();
    return DateTime.tryParse(prefs.getString(_letterboxdLastImportKey) ?? '');
  }

  Future<void> saveLetterboxdLastImportAt(DateTime at) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_letterboxdLastImportKey, at.toIso8601String());
  }

  Future<void> clearLetterboxdLastImportAt() async {
    final prefs = await _ensurePrefs();
    await prefs.remove(_letterboxdLastImportKey);
  }

  Future<List<TrackerStatusEntry>> loadTrackerStatuses() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_trackerStatusesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map<String, dynamic>)
            TrackerStatusEntry.fromJson(e)
          else if (e is Map)
            TrackerStatusEntry.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveTrackerStatuses(List<TrackerStatusEntry> entries) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _trackerStatusesKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  Future<SerializdCredentials> loadSerializd() async {
    final raw = await _secure.read(key: _secureKey(_serializdKey));
    if (raw == null || raw.isEmpty) return const SerializdCredentials();
    try {
      final credentials = SerializdCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      LogRedactor.instance.registerSecret(credentials.accessToken);
      return credentials;
    } catch (_) {
      return const SerializdCredentials();
    }
  }

  Future<void> saveSerializd(SerializdCredentials credentials) async {
    await _secure.write(
      key: _secureKey(_serializdKey),
      value: jsonEncode(credentials.toJson()),
    );
  }

  Future<List<MediaItem>> loadSerializdWatching() async {
    return _loadMediaItemList(_serializdWatchingKey);
  }

  Future<void> saveSerializdWatching(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _serializdWatchingKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadSerializdWatchlist() async {
    return _loadMediaItemList(_serializdWatchlistKey);
  }

  Future<void> saveSerializdWatchlist(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _serializdWatchlistKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<DateTime?> loadSerializdLastSyncAt() async {
    final prefs = await _ensurePrefs();
    return DateTime.tryParse(prefs.getString(_serializdLastSyncKey) ?? '');
  }

  Future<void> saveSerializdLastSyncAt(DateTime at) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_serializdLastSyncKey, at.toIso8601String());
  }

  Future<List<PendingSerializdScrobble>> loadPendingSerializdScrobbles() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_serializdPendingScrobblesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map<String, dynamic>)
            PendingSerializdScrobble.fromJson(e)
          else if (e is Map)
            PendingSerializdScrobble.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePendingSerializdScrobbles(
    List<PendingSerializdScrobble> events,
  ) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _serializdPendingScrobblesKey,
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }

  Future<BetaseriesCredentials> loadBetaseries() async {
    final raw = await _secure.read(key: _secureKey(_betaseriesKey));
    if (raw == null || raw.isEmpty) return const BetaseriesCredentials();
    try {
      final credentials = BetaseriesCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      LogRedactor.instance.registerSecrets([
        credentials.apiSecret,
        credentials.accessToken,
      ]);
      return credentials;
    } catch (_) {
      return const BetaseriesCredentials();
    }
  }

  Future<void> saveBetaseries(BetaseriesCredentials credentials) async {
    await _secure.write(
      key: _secureKey(_betaseriesKey),
      value: jsonEncode(credentials.toJson()),
    );
  }

  Future<List<MediaItem>> loadBetaseriesWatching() async {
    return _loadMediaItemList(_betaseriesWatchingKey);
  }

  Future<void> saveBetaseriesWatching(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _betaseriesWatchingKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadBetaseriesPlan() async {
    return _loadMediaItemList(_betaseriesPlanKey);
  }

  Future<void> saveBetaseriesPlan(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _betaseriesPlanKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<DateTime?> loadBetaseriesLastSyncAt() async {
    final prefs = await _ensurePrefs();
    return DateTime.tryParse(prefs.getString(_betaseriesLastSyncKey) ?? '');
  }

  Future<void> saveBetaseriesLastSyncAt(DateTime at) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_betaseriesLastSyncKey, at.toIso8601String());
  }

  Future<void> saveTraktLastSyncAt(DateTime at) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_traktLastSyncKey, at.toIso8601String());
  }

  Future<DateTime?> loadSimklLastSyncAt() async {
    final prefs = await _ensurePrefs();
    return DateTime.tryParse(prefs.getString(_simklLastSyncKey) ?? '');
  }

  Future<void> saveSimklLastSyncAt(DateTime at) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_simklLastSyncKey, at.toIso8601String());
  }

  Future<String?> loadSimklSyncDateFrom() async {
    final prefs = await _ensurePrefs();
    return prefs.getString(_simklSyncDateFromKey);
  }

  Future<void> saveSimklSyncDateFrom(String? stamp) async {
    final prefs = await _ensurePrefs();
    if (stamp == null || stamp.isEmpty) {
      await prefs.remove(_simklSyncDateFromKey);
    } else {
      await prefs.setString(_simklSyncDateFromKey, stamp);
    }
  }

  Future<CaptionStyleSettings> loadCaptionStyle() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_captionStyleKey);
    if (raw == null) return CaptionStyleSettings.outline;
    return CaptionStyleSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> saveCaptionStyle(CaptionStyleSettings style) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_captionStyleKey, jsonEncode(style.toJson()));
  }

  Future<List<CustomCaptionFont>> loadCustomCaptionFonts() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_customCaptionFontsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            CustomCaptionFont.fromJson(item)
          else if (item is Map)
            CustomCaptionFont.fromJson(Map<String, dynamic>.from(item)),
      ].where((f) => f.family.isNotEmpty).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveCustomCaptionFonts(List<CustomCaptionFont> fonts) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _customCaptionFontsKey,
      jsonEncode([for (final f in fonts) f.toJson()]),
    );
  }

  /// Directory scanned by libass for imported caption font files.
  Future<Directory> captionFontsDirectory() async {
    final root = await getApplicationSupportDirectory();
    final segment = profileId == Profile.defaultId
        ? 'caption_fonts'
        : 'caption_fonts${Platform.pathSeparator}$profileId';
    final dir = Directory('${root.path}${Platform.pathSeparator}$segment');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<LiveScrubMode> loadLiveScrubMode({
    LiveScrubMode fallback = LiveScrubMode.timeline,
  }) async {
    final prefs = await _ensurePrefs();
    return LiveScrubModeX.fromStorage(
      prefs.getString(_liveScrubModeKey),
      fallback: fallback,
    );
  }

  Future<void> saveLiveScrubMode(LiveScrubMode mode) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_liveScrubModeKey, mode.storageValue);
  }

  Future<List<double>> loadCyclePlaybackSpeeds() async {
    final prefs = await _ensurePrefs();
    return cyclePlaybackSpeedsFromStorage(
      prefs.getStringList(_cyclePlaybackSpeedsKey),
    );
  }

  Future<void> saveCyclePlaybackSpeeds(List<double> speeds) async {
    final prefs = await _ensurePrefs();
    await prefs.setStringList(
      _cyclePlaybackSpeedsKey,
      cyclePlaybackSpeedsToStorage(speeds),
    );
  }

  Future<LiveQualityMode> loadLiveQualityMode() async {
    final prefs = await _ensurePrefs();
    return LiveQualityModeX.fromStorage(prefs.getString(_liveQualityModeKey));
  }

  Future<void> saveLiveQualityMode(LiveQualityMode mode) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_liveQualityModeKey, mode.storageValue);
  }

  Future<List<MediaItem>> loadWatchlist() async {
    return _loadMediaItemList(_watchlistKey);
  }

  Future<void> saveWatchlist(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _watchlistKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<String>> loadFavoriteChannelIds() async {
    final prefs = await _ensurePrefs();
    return prefs.getStringList(_favoriteChannelsKey) ?? [];
  }

  Future<void> saveFavoriteChannelIds(List<String> ids) async {
    final prefs = await _ensurePrefs();
    await prefs.setStringList(_favoriteChannelsKey, ids);
  }

  /// Sources whose catalog has been paged all the way through, so a restart
  /// doesn't re-download pages the app already holds.
  Future<List<String>> loadDeepSyncedSourceIds() async {
    final prefs = await _ensurePrefs();
    return prefs.getStringList(_deepSyncedSourcesKey) ?? [];
  }

  Future<void> saveDeepSyncedSourceIds(List<String> ids) async {
    final prefs = await _ensurePrefs();
    await prefs.setStringList(_deepSyncedSourcesKey, ids);
  }

  Future<List<String>> loadFavoriteCategoryIds() async {
    final prefs = await _ensurePrefs();
    return prefs.getStringList(_favoriteCategoriesKey) ?? [];
  }

  Future<void> saveFavoriteCategoryIds(List<String> ids) async {
    final prefs = await _ensurePrefs();
    await prefs.setStringList(_favoriteCategoriesKey, ids);
  }

  Future<List<String>> loadRecentChannelIds() async {
    final prefs = await _ensurePrefs();
    return prefs.getStringList(_recentChannelsKey) ?? [];
  }

  Future<void> saveRecentChannelIds(List<String> ids) async {
    final prefs = await _ensurePrefs();
    await prefs.setStringList(_recentChannelsKey, ids);
  }

  /// Map of `sourceId|name:…` or `sourceId|epg:…` → preferred `streamId`.
  Future<Map<String, String>> loadPreferredLiveQualities() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_preferredQualitiesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in map.entries)
          if (e.value != null) e.key: '${e.value}',
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> savePreferredLiveQualities(Map<String, String> map) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_preferredQualitiesKey, jsonEncode(map));
  }

  Future<Map<String, String>> loadPreferredVodVariants() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_preferredVodVariantsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in map.entries)
          if (e.value != null) e.key: '${e.value}',
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> savePreferredVodVariants(Map<String, String> map) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_preferredVodVariantsKey, jsonEncode(map));
  }

  static const _proxyKey = 'network_proxy';
  static const _tmdbKey = 'tmdb_credentials';
  static const _traktKey = 'trakt_credentials';
  static const _metadataSettingsKey = 'metadata_settings';
  static const _displaySettingsKey = 'display_settings';
  static const _browsePanelCollapsedKey = 'browse_panel_collapsed';
  static const _myListUiPrefsKey = 'my_list_ui_prefs';
  static const _catalogBrowsePrefsKey = 'catalog_browse_prefs';
  static const _sportsFollowsKey = 'sports_follows';

  /// Pre-per-profile Sports follows (device-global). Default-profile fallback.
  static const _legacySportsPrefsKey = 'sports_prefs_v1';

  /// Local-only: user dismissed "link tracker on this device" for this profile.
  static const _trackerLinkPromptDismissedKey = 'tracker_link_prompt_dismissed';

  /// Local-only: soft "Set up trackers?" already offered / dismissed.
  static const _softTrackerSetupDismissedKey = 'soft_tracker_setup_dismissed';
  static const _plexClientIdKey = 'plex_client_identifier';
  static const _mediaServerStreamQualityKey = 'media_server_stream_quality';
  static const _detailsKey = 'media_details_cache';
  static const _collectionsKey = 'library_collections';
  static const _playlistsKey = 'library_playlists';
  static const _segmentsKey = 'media_segments_cache';
  static const _skipSettingsKey = 'skip_segment_settings';
  static const _trackLanguageKey = 'track_language_settings';
  static const _downloadSettingsKey = 'download_settings';
  static const _softwareVideoDecoderKey = 'software_video_decoder';
  static const _castServerTranscodeFallbackKey =
      'cast_server_transcode_fallback';
  static const _knownEpisodeIdsKey = 'known_series_episode_ids';
  static const _downloadsKey = 'offline_downloads';
  static const _pendingRemoveAfterWatchKey = 'pending_remove_after_watch';
  static const _pendingSimklScrobblesKey = 'pending_simkl_scrobbles';
  static const _onboardingCompletedKey = 'onboarding_completed';
  static const _torrentVpnTipSeenKey = 'torrent_vpn_tip_seen';
  static const _syncStateKey = 'sync_section_stamps';

  Future<bool> loadOnboardingCompleted() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_onboardingCompletedKey) ?? false;
  }

  Future<void> saveOnboardingCompleted(bool completed) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_onboardingCompletedKey, completed);
  }

  Future<bool> loadTorrentVpnTipSeen() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_torrentVpnTipSeenKey) ?? false;
  }

  Future<void> saveTorrentVpnTipSeen(bool seen) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_torrentVpnTipSeenKey, seen);
  }

  /// Stable X-Plex-Client-Identifier for plex.tv PIN auth / resources.
  Future<String?> loadPlexClientId() async {
    final prefs = await _ensurePrefs();
    final id = prefs.getString(_plexClientIdKey)?.trim();
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> savePlexClientId(String clientId) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_plexClientIdKey, clientId.trim());
  }

  Future<MediaServerStreamQuality> loadMediaServerStreamQuality() async {
    final prefs = await _ensurePrefs();
    return MediaServerStreamQualityX.fromName(
      prefs.getString(_mediaServerStreamQualityKey),
    );
  }

  Future<void> saveMediaServerStreamQuality(
    MediaServerStreamQuality quality,
  ) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_mediaServerStreamQualityKey, quality.name);
  }

  Future<ProxySettings> loadProxySettings() async {
    final raw = await _secure.read(key: _secureKey(_proxyKey));
    if (raw == null || raw.isEmpty) return ProxySettings.disabled;
    try {
      final settings = ProxySettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      LogRedactor.instance.registerSecret(settings.password);
      return settings;
    } catch (_) {
      return ProxySettings.disabled;
    }
  }

  Future<void> saveProxySettings(ProxySettings settings) async {
    await _secure.write(
      key: _secureKey(_proxyKey),
      value: jsonEncode(settings.toJson()),
    );
  }

  Future<TmdbCredentials> loadTmdb() async {
    final raw = await _secure.read(key: _secureKey(_tmdbKey));
    if (raw == null || raw.isEmpty) return const TmdbCredentials();
    try {
      final credentials = TmdbCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      LogRedactor.instance.registerSecret(credentials.apiKey);
      return credentials;
    } catch (_) {
      return const TmdbCredentials();
    }
  }

  Future<void> saveTmdb(TmdbCredentials credentials) async {
    await _secure.write(
      key: _secureKey(_tmdbKey),
      value: jsonEncode(credentials.toJson()),
    );
  }

  Future<TraktCredentials> loadTrakt() async {
    final raw = await _secure.read(key: _secureKey(_traktKey));
    if (raw == null || raw.isEmpty) return const TraktCredentials();
    try {
      final credentials = TraktCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      LogRedactor.instance.registerSecrets([
        credentials.clientSecret,
        credentials.accessToken,
        credentials.refreshToken,
      ]);
      return credentials;
    } catch (_) {
      return const TraktCredentials();
    }
  }

  Future<void> saveTrakt(TraktCredentials credentials) async {
    await _secure.write(
      key: _secureKey(_traktKey),
      value: jsonEncode(credentials.toJson()),
    );
  }

  Future<MetadataSettings> loadMetadataSettings() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_metadataSettingsKey);
    if (raw == null || raw.isEmpty) return MetadataSettings.defaults;
    try {
      return MetadataSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return MetadataSettings.defaults;
    }
  }

  Future<void> saveMetadataSettings(MetadataSettings settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_metadataSettingsKey, jsonEncode(settings.toJson()));
  }

  Future<DisplaySettings> loadDisplaySettings() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_displaySettingsKey);
    if (raw == null || raw.isEmpty) return DisplaySettings.defaults;
    try {
      return DisplaySettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DisplaySettings.defaults;
    }
  }

  Future<void> saveDisplaySettings(DisplaySettings settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_displaySettingsKey, jsonEncode(settings.toJson()));
  }

  /// Last watch+browse panel state (hidden vs shown). Local chrome, not synced.
  Future<bool> loadBrowsePanelCollapsed() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_browsePanelCollapsedKey) ?? false;
  }

  Future<void> saveBrowsePanelCollapsed(bool collapsed) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_browsePanelCollapsedKey, collapsed);
  }

  Future<MyListUiPrefs> loadMyListUiPrefs() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_myListUiPrefsKey);
    if (raw == null || raw.isEmpty) return MyListUiPrefs.defaults;
    try {
      return MyListUiPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return MyListUiPrefs.defaults;
    }
  }

  Future<void> saveMyListUiPrefs(MyListUiPrefs settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_myListUiPrefsKey, jsonEncode(settings.toJson()));
  }

  Future<CatalogBrowsePrefs> loadCatalogBrowsePrefs() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_catalogBrowsePrefsKey);
    if (raw == null || raw.isEmpty) return CatalogBrowsePrefs.defaults;
    try {
      return CatalogBrowsePrefs.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return CatalogBrowsePrefs.defaults;
    }
  }

  Future<void> saveCatalogBrowsePrefs(CatalogBrowsePrefs settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _catalogBrowsePrefsKey,
      jsonEncode(settings.toJson()),
    );
  }

  /// Followed leagues / teams. TheSportsDB API key stays device-global.
  Future<SportsPrefs> loadSportsFollows() async {
    final prefs = await _ensurePrefs();
    // An explicit per-profile value — including an empty follow list — must
    // win over the pre-profiles device-global key. Missing ≠ cleared.
    if (prefs.containsKey(_sportsFollowsKey)) {
      final raw = prefs.getString(_sportsFollowsKey);
      if (raw == null || raw.isEmpty) return SportsPrefs.empty;
      return _sportsFollowsFromRaw(raw) ?? SportsPrefs.empty;
    }
    // Pre-per-profile follows were device-global. Only the default profile
    // inherits them so other profiles start clean.
    if (profileId == Profile.defaultId) {
      final rawPrefs = _rawPrefs ??= await SharedPreferences.getInstance();
      final legacy = rawPrefs.getString(_legacySportsPrefsKey);
      if (legacy != null && legacy.isNotEmpty) {
        return _sportsFollowsFromRaw(legacy) ?? SportsPrefs.empty;
      }
    }
    return SportsPrefs.empty;
  }

  Future<void> saveSportsFollows(SportsPrefs settings) async {
    final prefs = await _ensurePrefs();
    final json = settings.copyWith(apiKey: '').toFollowsJson();
    // Persist even `{}` so the next load does not fall back to
    // sports_prefs_v1 after the user (or a synced section) clears follows.
    await prefs.setString(_sportsFollowsKey, jsonEncode(json));
  }

  static SportsPrefs? _sportsFollowsFromRaw(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SportsPrefs.fromJson(
        Map<String, dynamic>.from(decoded),
      ).copyWith(apiKey: '');
    } catch (_) {
      return null;
    }
  }

  Future<bool> loadTrackerLinkPromptDismissed() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_trackerLinkPromptDismissedKey) ?? false;
  }

  Future<void> saveTrackerLinkPromptDismissed(bool dismissed) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_trackerLinkPromptDismissedKey, dismissed);
  }

  Future<bool> loadSoftTrackerSetupDismissed() async {
    final prefs = await _ensurePrefs();
    if (prefs.containsKey(_softTrackerSetupDismissedKey)) {
      return prefs.getBool(_softTrackerSetupDismissedKey) ?? false;
    }
    // Existing installs already past Welcome: don't re-nag on upgrade.
    final onboarded = prefs.getBool(_onboardingCompletedKey) ?? false;
    if (onboarded) {
      await prefs.setBool(_softTrackerSetupDismissedKey, true);
      return true;
    }
    return false;
  }

  Future<void> saveSoftTrackerSetupDismissed(bool dismissed) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_softTrackerSetupDismissedKey, dismissed);
  }

  Future<Map<String, MediaDetails>> loadDetailsCache() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_detailsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = await decodeJsonObjectMapsInIsolate(raw);
      if (decoded.isEmpty) return {};
      final out = <String, MediaDetails>{};
      final slice = Stopwatch()..start();
      var i = 0;
      for (final e in decoded.entries) {
        out[e.key] = MediaDetails.fromJson(e.value);
        await yieldUiSlice(slice, i: i++, label: 'catalog-details-decode');
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveDetailsCache(Map<String, MediaDetails> cache) async {
    final prefs = await _ensurePrefs();
    final maps = {for (final e in cache.entries) e.key: e.value.toJson()};
    await prefs.setString(_detailsKey, await _encodeJson(maps, maps.length));
  }

  /// Encoding a few hundred KB of JSON costs tens of milliseconds; past a
  /// handful of entries that belongs on a worker isolate, not in a frame.
  /// Web cannot spawn dart:io-backed isolates (`Unsupported operation: _Namespace`).
  static Future<String> _encodeJson(Object? value, int entryCount) {
    if (kIsWeb || entryCount < 64) return Future.value(jsonEncode(value));
    return javpCompute(() => jsonEncode(value));
  }

  /// Decodes a stored JSON array into sendable maps, off the UI isolate once
  /// the blob is big enough to be worth the handoff.
  static Future<List<Map<String, dynamic>>> _decodeMapList(String raw) {
    if (raw.isEmpty) return Future.value(const []);
    return decodeJsonListMapsInIsolate(raw);
  }

  /// Builds models from decoded maps, yielding once a slice has used up its
  /// share of a frame.
  ///
  /// Decoding already happens on a worker isolate, but `fromJson` has to run
  /// here — the models go straight into provider state.
  static Future<List<T>> _hydrateInSlices<T>(
    List<Map<String, dynamic>> maps,
    T Function(Map<String, dynamic> json) parse,
  ) => mapYielding(maps, parse, label: 'store-hydrate-items');

  Future<List<LibraryCollection>> loadCollections() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_collectionsKey);
    if (raw == null) return [];
    final list = await _decodeMapList(raw);
    return list.map(LibraryCollection.fromJson).toList();
  }

  Future<void> saveCollections(List<LibraryCollection> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _collectionsKey,
      jsonEncode(items.map((c) => c.toJson()).toList()),
    );
  }

  Future<List<LibraryPlaylist>> loadPlaylists() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_playlistsKey);
    if (raw == null) return [];
    final list = await _decodeMapList(raw);
    return list.map(LibraryPlaylist.fromJson).toList();
  }

  Future<void> savePlaylists(List<LibraryPlaylist> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _playlistsKey,
      jsonEncode(items.map((p) => p.toJson()).toList()),
    );
  }

  Future<Map<String, MediaSegmentBundle>> loadSegmentCache() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_segmentsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = await decodeJsonObjectMapsInIsolate(raw);
      if (decoded.isEmpty) return {};
      final out = <String, MediaSegmentBundle>{};
      final slice = Stopwatch()..start();
      var i = 0;
      for (final e in decoded.entries) {
        out[e.key] = MediaSegmentBundle.fromJson(e.value);
        await yieldUiSlice(slice, i: i++, label: 'playback-segments-decode');
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSegmentCache(Map<String, MediaSegmentBundle> cache) async {
    final prefs = await _ensurePrefs();
    final maps = {for (final e in cache.entries) e.key: e.value.toJson()};
    await prefs.setString(_segmentsKey, await _encodeJson(maps, maps.length));
  }

  Future<SkipSegmentSettings> loadSkipSettings() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_skipSettingsKey);
    if (raw == null || raw.isEmpty) return SkipSegmentSettings.defaults;
    try {
      return SkipSegmentSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return SkipSegmentSettings.defaults;
    }
  }

  Future<void> saveSkipSettings(SkipSegmentSettings settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_skipSettingsKey, jsonEncode(settings.toJson()));
  }

  Future<TrackLanguageSettings> loadTrackLanguageSettings() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_trackLanguageKey);
    if (raw == null || raw.isEmpty) return TrackLanguageSettings.defaults;
    try {
      return TrackLanguageSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return TrackLanguageSettings.defaults;
    }
  }

  Future<void> saveTrackLanguageSettings(TrackLanguageSettings settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_trackLanguageKey, jsonEncode(settings.toJson()));
  }

  Future<DownloadSettings> loadDownloadSettings() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_downloadSettingsKey);
    if (raw == null || raw.isEmpty) return DownloadSettings.defaults;
    try {
      return DownloadSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DownloadSettings.defaults;
    }
  }

  Future<void> saveDownloadSettings(DownloadSettings settings) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_downloadSettingsKey, jsonEncode(settings.toJson()));
  }

  Future<bool> loadSoftwareVideoDecoder() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_softwareVideoDecoderKey) ?? false;
  }

  Future<void> saveSoftwareVideoDecoder(bool enabled) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_softwareVideoDecoderKey, enabled);
  }

  Future<bool> loadCastServerTranscodeFallback() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_castServerTranscodeFallbackKey) ?? false;
  }

  Future<void> saveCastServerTranscodeFallback(bool enabled) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_castServerTranscodeFallbackKey, enabled);
  }

  Future<Map<String, List<String>>> loadKnownEpisodeIds() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_knownEpisodeIdsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return await javpCompute(() {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        return {
          for (final e in map.entries)
            if (e.value is List)
              e.key: (e.value as List).map((v) => '$v').toList(),
        };
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> saveKnownEpisodeIds(Map<String, List<String>> map) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_knownEpisodeIdsKey, jsonEncode(map));
  }

  Future<List<EpgReminder>> loadEpgReminders() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_epgRemindersKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(EpgReminder.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveEpgReminders(List<EpgReminder> reminders) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _epgRemindersKey,
      jsonEncode(reminders.map((r) => r.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadDownloads() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_downloadsKey);
    if (raw == null) return [];
    final list = await _decodeMapList(raw);
    final items = list.map(MediaItem.fromJson).toList();
    var changed = false;
    final relocated = <MediaItem>[];
    for (final item in items) {
      if (item.origin != MediaOrigin.download) {
        relocated.add(item);
        continue;
      }
      final next = await AppDocuments.relocateIfMoved(item.playUrl);
      if (next != item.playUrl) {
        changed = true;
        relocated.add(item.copyWith(playUrl: next));
      } else {
        relocated.add(item);
      }
    }
    if (changed) {
      await saveDownloads(relocated);
    }
    return relocated;
  }

  Future<void> saveDownloads(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _downloadsKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> loadPendingRemoveAfterWatch() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_pendingRemoveAfterWatchKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(MediaItem.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePendingRemoveAfterWatch(List<MediaItem> items) async {
    final prefs = await _ensurePrefs();
    if (items.isEmpty) {
      await prefs.remove(_pendingRemoveAfterWatchKey);
      return;
    }
    await prefs.setString(
      _pendingRemoveAfterWatchKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  Future<List<PendingSimklScrobble>> loadPendingSimklScrobbles() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_pendingSimklScrobblesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(PendingSimklScrobble.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePendingSimklScrobbles(
    List<PendingSimklScrobble> items,
  ) async {
    final prefs = await _ensurePrefs();
    if (items.isEmpty) {
      await prefs.remove(_pendingSimklScrobblesKey);
      return;
    }
    await prefs.setString(
      _pendingSimklScrobblesKey,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }

  /// Opaque per-profile sync bookkeeping (which section changed, and when).
  /// Lives in the profile namespace so it travels with the profile's data.
  Future<String?> loadSyncState() async {
    final prefs = await _ensurePrefs();
    return prefs.getString(_syncStateKey);
  }

  Future<void> saveSyncState(String json) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_syncStateKey, json);
  }

  /// Wipes everything this store owns. Refuses on the default profile, whose
  /// keys are shared with the pre-profiles layout.
  Future<void> deleteProfileData() async {
    if (profileId == Profile.defaultId) return;
    final raw = _rawPrefs ??= await SharedPreferences.getInstance();
    final prefix = _keyPrefix;
    for (final key in raw.getKeys().where((k) => k.startsWith(prefix))) {
      await raw.remove(key);
    }
    for (final key in [
      _simklKey,
      _proxyKey,
      _tmdbKey,
      _traktKey,
      _serializdKey,
      _betaseriesKey,
    ]) {
      try {
        await _secure.delete(key: _secureKey(key));
      } catch (_) {
        // Secure storage is unavailable in tests / some desktop setups.
      }
    }
    try {
      final dir = await profileDirectory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Leftover cache files are harmless.
    }
  }
}

/// Isolate payload for [LibraryStore._vodCacheParseIsolateMain].
class _VodCacheParseArgs {
  const _VodCacheParseArgs({
    required this.reply,
    required this.bytes,
    required this.chunkSize,
    required this.localSourceKey,
    this.knownSourceIds,
  });

  final SendPort reply;
  final Uint8List bytes;
  final int chunkSize;
  final String localSourceKey;
  final List<String>? knownSourceIds;
}

/// SharedPreferences view that transparently prefixes every key, so the rest
/// of [LibraryStore] can stay unaware of profiles.
class _ScopedPrefs {
  _ScopedPrefs(this._prefs, this._prefix);

  final SharedPreferences _prefs;
  final String _prefix;

  String _k(String key) => _prefix.isEmpty ? key : '$_prefix$key';

  String? getString(String key) => _prefs.getString(_k(key));

  Future<bool> setString(String key, String value) =>
      _prefs.setString(_k(key), value);

  List<String>? getStringList(String key) => _prefs.getStringList(_k(key));

  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(_k(key), value);

  bool? getBool(String key) => _prefs.getBool(_k(key));

  Future<bool> setBool(String key, bool value) =>
      _prefs.setBool(_k(key), value);

  bool containsKey(String key) => _prefs.containsKey(_k(key));

  Future<bool> remove(String key) => _prefs.remove(_k(key));
}

class SkipSegmentSettings {
  const SkipSegmentSettings({
    this.autoSkipIntro = false,
    this.autoSkipRecap = false,
    this.autoSkipCredits = false,
  });

  static const defaults = SkipSegmentSettings();

  final bool autoSkipIntro;
  final bool autoSkipRecap;
  final bool autoSkipCredits;

  SkipSegmentSettings copyWith({
    bool? autoSkipIntro,
    bool? autoSkipRecap,
    bool? autoSkipCredits,
  }) {
    return SkipSegmentSettings(
      autoSkipIntro: autoSkipIntro ?? this.autoSkipIntro,
      autoSkipRecap: autoSkipRecap ?? this.autoSkipRecap,
      autoSkipCredits: autoSkipCredits ?? this.autoSkipCredits,
    );
  }

  Map<String, dynamic> toJson() => {
    'autoSkipIntro': autoSkipIntro,
    'autoSkipRecap': autoSkipRecap,
    'autoSkipCredits': autoSkipCredits,
  };

  factory SkipSegmentSettings.fromJson(Map<String, dynamic> json) {
    return SkipSegmentSettings(
      autoSkipIntro: json['autoSkipIntro'] as bool? ?? false,
      autoSkipRecap: json['autoSkipRecap'] as bool? ?? false,
      autoSkipCredits: json['autoSkipCredits'] as bool? ?? false,
    );
  }
}

class DownloadSettings {
  const DownloadSettings({
    this.downloadAheadWhileWatching = false,
    this.downloadAheadCount = 2,
    this.wifiOnly = true,
    this.removeAfterWatch = false,
    this.downloadNewOnUpdate = false,
    this.dvrPadBefore = const Duration(minutes: 5),
    this.dvrPadAfter = const Duration(minutes: 10),
  });

  static const defaults = DownloadSettings();

  final bool downloadAheadWhileWatching;
  final int downloadAheadCount;
  final bool wifiOnly;
  final bool removeAfterWatch;
  final bool downloadNewOnUpdate;
  final Duration dvrPadBefore;
  final Duration dvrPadAfter;

  int get aheadCountClamped => downloadAheadCount.clamp(1, 10);

  DownloadSettings copyWith({
    bool? downloadAheadWhileWatching,
    int? downloadAheadCount,
    bool? wifiOnly,
    bool? removeAfterWatch,
    bool? downloadNewOnUpdate,
    Duration? dvrPadBefore,
    Duration? dvrPadAfter,
  }) {
    return DownloadSettings(
      downloadAheadWhileWatching:
          downloadAheadWhileWatching ?? this.downloadAheadWhileWatching,
      downloadAheadCount: downloadAheadCount ?? this.downloadAheadCount,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      removeAfterWatch: removeAfterWatch ?? this.removeAfterWatch,
      downloadNewOnUpdate: downloadNewOnUpdate ?? this.downloadNewOnUpdate,
      dvrPadBefore: dvrPadBefore ?? this.dvrPadBefore,
      dvrPadAfter: dvrPadAfter ?? this.dvrPadAfter,
    );
  }

  Map<String, dynamic> toJson() => {
    'downloadAheadWhileWatching': downloadAheadWhileWatching,
    'downloadAheadCount': downloadAheadCount,
    'wifiOnly': wifiOnly,
    'removeAfterWatch': removeAfterWatch,
    'downloadNewOnUpdate': downloadNewOnUpdate,
    'dvrPadBeforeMinutes': dvrPadBefore.inMinutes,
    'dvrPadAfterMinutes': dvrPadAfter.inMinutes,
  };

  factory DownloadSettings.fromJson(Map<String, dynamic> json) {
    return DownloadSettings(
      downloadAheadWhileWatching:
          json['downloadAheadWhileWatching'] as bool? ?? false,
      downloadAheadCount: (json['downloadAheadCount'] as num?)?.toInt() ?? 2,
      wifiOnly: json['wifiOnly'] as bool? ?? true,
      removeAfterWatch: json['removeAfterWatch'] as bool? ?? false,
      downloadNewOnUpdate: json['downloadNewOnUpdate'] as bool? ?? false,
      dvrPadBefore: Duration(
        minutes: (json['dvrPadBeforeMinutes'] as num?)?.toInt() ?? 5,
      ),
      dvrPadAfter: Duration(
        minutes: (json['dvrPadAfterMinutes'] as num?)?.toInt() ?? 10,
      ),
    );
  }
}

class _DecodedCatalog {
  const _DecodedCatalog({
    required this.maps,
    this.liveMaps = const [],
    this.rewrittenJson,
  });

  final List<Map<String, dynamic>> maps;

  /// Live rows stripped from the JSON catalog (migrate into SQLite once).
  final List<Map<String, dynamic>> liveMaps;
  final String? rewrittenJson;
}

/// Decode catalog JSON off the UI isolate, streaming maps in chunks.
///
/// A one-shot [javpCompute] of ~10k maps was a 300ms+ copy-back during which
/// Windows dropped clicks without ever showing Not Responding. The worker
/// reads [sourcePath] itself so the UI isolate does not copy the file bytes.
Future<_DecodedCatalog> _decodeCatalogInIsolate({
  List<int>? bytes,
  String? sourcePath,
  String? rewritePath,
  int? fileLength,
}) async {
  final size = fileLength ?? bytes?.length ?? 0;
  if (kIsWeb || size < 32 * 1024) {
    final raw =
        bytes ??
        (sourcePath != null
            ? File(sourcePath).readAsBytesSync()
            : const <int>[]);
    final parsed = _decodeCatalogMaps(raw);
    if (rewritePath != null && parsed.rewrittenJson != null) {
      try {
        File(rewritePath).writeAsStringSync(parsed.rewrittenJson!);
      } catch (_) {}
    }
    return _DecodedCatalog(maps: parsed.maps, liveMaps: parsed.liveMaps);
  }
  return UiStallWatchdog.span('catalog-decode', () async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _catalogDecodeIsolateMain,
        receive.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      receive.close();
      errors.close();
      rethrow;
    }

    Object? isolateError;
    final errorSub = errors.listen((msg) {
      isolateError ??= msg;
    });
    final iter = StreamIterator(receive);
    try {
      if (!await iter.moveNext()) {
        throw StateError('catalog decode exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final port = iter.current as SendPort;
      port.send(<String, Object?>{
        'path': ?sourcePath,
        'bytes': ?bytes,
        'rewrite': rewritePath,
      });
      await yieldAfterIsolateChunk();

      final kept = <Map<String, dynamic>>[];
      final live = <Map<String, dynamic>>[];
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is Map) {
          final type = '${message['t'] ?? ''}';
          final raw = message['v'];
          if (raw is List) {
            final dest = type == 'l' ? live : kept;
            for (final row in raw) {
              if (row is Map) dest.add(Map<String, dynamic>.from(row));
            }
          }
        }
        await yieldAfterIsolateChunk();
      }
      if (isolateError != null) throw isolateError!;
      return _DecodedCatalog(maps: kept, liveMaps: live);
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  });
}

/// Decode catalog bytes off the UI isolate.
/// Drops live + Xtream VOD/series dumps from the kept catalog.
_DecodedCatalog _decodeCatalogMaps(List<int> bytes) {
  final raw = utf8.decode(bytes);
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    return const _DecodedCatalog(maps: []);
  }
  final kept = <Map<String, dynamic>>[];
  final liveMaps = <Map<String, dynamic>>[];
  var stripped = 0;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final m = Map<String, dynamic>.from(entry);
    final kind = m['kind'] as String?;
    final origin = m['origin'] as String?;
    if (kind == MediaKind.live.name) {
      liveMaps.add(m);
      stripped++;
      continue;
    }
    final isXtreamVod =
        origin == MediaOrigin.iptvXtream.name &&
        (kind == MediaKind.vod.name || kind == MediaKind.series.name);
    if (isXtreamVod) {
      stripped++;
      continue;
    }
    kept.add(m);
  }
  return _DecodedCatalog(
    maps: kept,
    liveMaps: liveMaps,
    rewrittenJson: stripped > 0 ? jsonEncode(kept) : null,
  );
}

@pragma('vm:entry-point')
void _catalogDecodeIsolateMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! Map) {
      reply.send(null);
      inbox.close();
      return;
    }
    try {
      final path = message['path'] as String?;
      final rewritePath = message['rewrite'] as String?;
      final rawBytes = message['bytes'];
      final bytes = path != null
          ? File(path).readAsBytesSync()
          : rawBytes is Uint8List
          ? rawBytes
          : Uint8List.fromList(List<int>.from(rawBytes as List));
      final parsed = _decodeCatalogMaps(bytes);
      if (rewritePath != null && parsed.rewrittenJson != null) {
        File(rewritePath).writeAsStringSync(parsed.rewrittenJson!);
      }
      const chunk = kIsolateListChunk;
      void send(String type, List<Map<String, dynamic>> maps) {
        for (var i = 0; i < maps.length; i += chunk) {
          final end = i + chunk > maps.length ? maps.length : i + chunk;
          reply.send({'t': type, 'v': maps.sublist(i, end)});
        }
      }

      send('k', parsed.maps);
      send('l', parsed.liveMaps);
      reply.send(null);
    } catch (_) {
      reply.send(null);
    }
    inbox.close();
  });
}
