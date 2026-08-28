import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Color, Locale, PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/compat/defer_notify.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/epg_reminder.dart';
import 'package:javp/models/home_shelf_snapshot.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_epg_input.dart';
import 'package:javp/models/library_collection.dart';
import 'package:javp/models/library_playlist.dart';
import 'package:javp/models/live_channel_index.dart';
import 'package:javp/models/live_quality_mode.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/platform/display_capability.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/models/betaseries_models.dart';
import 'package:javp/models/serializd_models.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/display_settings.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/models/my_list_ui_prefs.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/models/track_language_settings.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/services/catalog/catalog_browse.dart';
import 'package:javp/services/catalog/catalog_client_identity.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';
import 'package:javp/services/catalog/custom_catalog_client.dart';
import 'package:javp/services/cast/cast_service.dart';
import 'package:javp/services/background/interactive_work_gate.dart';
import 'package:javp/services/diagnostics/agent_sync_trigger.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:javp/services/diagnostics/library_work_debug.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/diagnostics/sources_feature_summary.dart';
import 'package:javp/sync_worker/sync_client.dart';
import 'package:javp/sync_worker/sync_protocol.dart';
import 'package:javp/sync_worker/sync_scheduler.dart';
import 'package:javp/services/download/android_download_keepalive.dart';
import 'package:javp/services/download/catchup_air_date.dart' as catchup_air;
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/download/dvr_download_math.dart';
import 'package:javp/services/download/episode_download_helpers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/epg_channel_matcher.dart';
import 'package:javp/services/iptv/epg_parser.dart';
import 'package:javp/services/iptv/epg_reload_policy.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';
import 'package:javp/services/iptv/live_category_page.dart';
import 'package:javp/services/iptv/live_channel_indexer.dart';
import 'package:javp/services/iptv/live_ingest_plan.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/iptv/m3u_playlist_io.dart';
import 'package:javp/services/iptv/m3u_parser.dart';
import 'package:javp/services/iptv/source_shelf.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/iptv/vod_search_index.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';
import 'package:javp/services/library/series_watchlist.dart';
import 'package:javp/services/local_source_path.dart';
import 'package:javp/services/first_catalog_sync.dart';
import 'package:javp/services/source_content_sniff.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/services/playback/audio_stream.dart';
import 'package:javp/services/iptv/stalker_client.dart';
import 'package:javp/services/iptv/xtream_client.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/iptv/xtream_url_detect.dart';
import 'package:javp/services/media_server/emby_client.dart';
import 'package:javp/services/media_server/jellyfin_client.dart';
import 'package:javp/services/media_server/media_server_client.dart';
import 'package:javp/services/media_server/plex_account_client.dart';
import 'package:javp/services/media_server/plex_client.dart';
import 'package:javp/services/network/app_http_client.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';
import 'package:javp/services/network/fallback_http_client.dart';
import 'package:javp/services/network/prioritized_http_client.dart';
import 'package:javp/services/network/proxy_probe.dart';
import 'package:javp/services/notifications/download_notification_service.dart';
import 'package:javp/services/notifications/epg_reminder_service.dart';
import 'package:javp/models/for_you_shelf.dart';
import 'package:javp/services/recommendations/for_you_live_recommender.dart';
import 'package:javp/services/recommendations/for_you_remote_enricher.dart';
import 'package:javp/services/recommendations/home_continue_watching.dart';
import 'package:javp/services/recommendations/home_type_affinity.dart';
import 'package:javp/services/recommendations/local_recommender.dart';
import 'package:javp/services/recommendations/tmdb_local_discovery.dart';
import 'package:javp/services/segments/segment_resolver.dart';
import 'package:javp/services/background/background_action_queue.dart';
import 'package:javp/services/external_media_open.dart';
import 'package:javp/services/simkl/simkl_client.dart';
import 'package:javp/services/simkl/simkl_enricher.dart';
import 'package:javp/services/simkl/simkl_match.dart';
import 'package:javp/services/betaseries/betaseries_client.dart';
import 'package:javp/services/betaseries/betaseries_match.dart';
import 'package:javp/services/serializd/serializd_client.dart';
import 'package:javp/services/serializd/serializd_match.dart';
import 'package:javp/services/trackers/tracker_sync_runner.dart';
import 'package:javp/services/trackers/tracker_import_mapper.dart';
import 'package:javp/services/trackers/tracker_log.dart';
import 'package:javp/services/trackers/tracker_progress_merger.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/trackers/tracker_link_intent.dart';
import 'package:javp/services/storage/epg_program_db.dart';
import 'package:javp/services/storage/live_channel_db.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';
import 'package:javp/services/storage/sources_export.dart';
import 'package:javp/services/sync/profile_snapshot.dart';
import 'package:javp/services/images/javp_image_cache.dart';
import 'package:javp/services/metadata/episode_art_overlay.dart';
import 'package:javp/services/metadata/external_ids.dart';
import 'package:javp/services/metadata/metadata_match.dart';
import 'package:javp/services/metadata/metadata_provider.dart';
import 'package:javp/services/tmdb/tmdb_client.dart';
import 'package:javp/services/tmdb/tmdb_enricher.dart';
import 'package:javp/services/tmdb/tmdb_episode_stills.dart';
import 'package:javp/services/letterboxd/letterboxd_export.dart';
import 'package:javp/services/letterboxd/letterboxd_match.dart';
import 'package:javp/services/trakt/trakt_client.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:javp/services/trakt/trakt_enricher.dart';
import 'package:javp/services/trakt/trakt_match.dart';
import 'package:javp/services/media_server/plex_watchlist_match.dart';
import 'package:javp/services/torrent/torrent_stream_service.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

/// App-wide library façade: sources, catalog, live, EPG, VOD, home, downloads,
/// history, and tracker sync.
///
/// Persistence already lives in [LibraryStore], [LiveChannelDb],
/// [VodCatalogDb], and [EpgProgramDb]. This class still *orchestrates*
/// those domains — it is not the place to add a new product area. Extract a
/// service and keep a thin forwarder. Map: `docs/architecture.md`.
///
/// Search these names (line numbers rot):
/// - Write-behind / epochs — `_pendingWrites`, `_historyEpoch`
/// - Home reveal — `markHomeRevealSettled`, `_loadHomeShelfSnapshotEarly`
/// - Live SQLite — `_useLiveDb`, `ensureLiveIndex`, `indexedLivePage`
/// - VOD SQLite — `_useVodDb`, `queryVodCatalog`, `ensureVodVariantIndex`
/// - EPG SQLite — `_useEpgDb`, `guideFor`, `fetchChannelGuide`
/// - Bootstrap — `bootstrap`, `_bootstrapDeferred`
/// - Sources — `addM3uSource`, `removeSource`, `syncSource`
/// - EPG — `fetchChannelGuide`, `guideFor`
/// - Downloads — `enqueueDownload`
/// - History — `recordWatch`, `recordProgress`
/// - Trackers — `library/tracker_sync_*.dart` (shared + per source)
///
/// Domain methods live in `lib/providers/library/*.dart` (same-library
/// extensions). Public names stay on [LibraryProvider].
part 'library/library_vod.dart';
part 'library/library_live.dart';
part 'library/library_epg.dart';
part 'library/library_sources.dart';
part 'library/tracker_sync_coordinator.dart';
part 'library/tracker_sync_simkl.dart';
part 'library/tracker_sync_trakt.dart';
part 'library/tracker_sync_plex.dart';
part 'library/tracker_sync_letterboxd.dart';
part 'library/tracker_sync_serializd.dart';
part 'library/tracker_sync_betaseries.dart';
part 'library/library_history.dart';
part 'library/library_bootstrap.dart';
part 'library/library_downloads.dart';

class LibraryProvider extends ChangeNotifier with DeferNotifyIfBuilding {
  LibraryProvider({
    LibraryStore? store,
    M3uParser? m3uParser,
    XtreamClient? xtreamClient,
    CustomCatalogClient? customCatalogClient,
    SimklClient? simklClient,
    TmdbClient? tmdbClient,
    TraktClient? traktClient,
    SerializdClient? serializdClient,
    BetaseriesClient? betaseriesClient,
    LocalRecommender? recommender,
    http.Client? httpClient,
    TorrentStreamService? torrentStreamService,
    DownloadManager? downloadManager,
    CastService? castService,
    SegmentResolver? segmentResolver,
    EpgReminderService? epgReminderService,
    String profileId = Profile.defaultId,
    HomeShelfSnapshot? homeShelfSnapshot,
  }) : _store = store ?? LibraryStore(profileId: profileId),
       _liveDb = LiveChannelDb(profileId: profileId),
       _vodDb = VodCatalogDb(profileId: profileId),
       _epgDb = EpgProgramDb(profileId: profileId),
       _m3u = m3uParser ?? M3uParser(),
       _injectedCustomCatalog = customCatalogClient,
       _recommender = recommender ?? LocalRecommender(),
       _torrent = torrentStreamService ?? TorrentStreamService(),
       _downloads = downloadManager ?? DownloadManager(),
       _cast = castService ?? CastService(),
       _reminders = epgReminderService ?? EpgReminderService.instance,
       _injectedHttp = httpClient,
       _injectedXtream = xtreamClient,
       _injectedSimkl = simklClient,
       _injectedTmdb = tmdbClient,
       _injectedTrakt = traktClient,
       _injectedSerializd = serializdClient,
       _injectedBetaseries = betaseriesClient,
       _injectedSegments = segmentResolver {
    // One cheap shared client so `late` fields are safe; proxy rebuild is deferred.
    final injectedHttp = _injectedHttp;
    if (injectedHttp != null) {
      _attachScopedHttpClients(proxied: injectedHttp, direct: injectedHttp);
    } else {
      final direct = createDnsFallbackHttpClient();
      _ownedDirectHttp = direct;
      _attachScopedHttpClients(proxied: direct, direct: direct);
    }
    _wireDownloadTorrentBridge();
    _downloads.addListener(_onDownloadsChanged);
    _cast.addListener(notifyListeners);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      _downloads.onNetworkChanged();
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) {
        unawaited(_flushPendingRemoveAfterWatch());
        unawaited(_flushPendingSimklScrobbles());
        unawaited(_flushPendingSerializdScrobbles());
      }
    });
    // Accueil cold paint wins sockets / bg slots until reveal settles.
    JavpImageCache.instance.setStartupThrottle(true);
    _bgQueue.setColdStartMode(true);
    if (homeShelfSnapshot != null) {
      _applyHomeShelfSnapshot(homeShelfSnapshot);
    }
    UiStallWatchdog.addStallListener(_onUiStallDetected);
    UiStallWatchdog.desktopHintsProvider = _stallDesktopHints;
  }

  /// Desktop stall crumbs: VOD SQLite path + SyncEngine client handles.
  String _stallDesktopHints() {
    if (_disposed) return '';
    var workers = 0;
    for (final c in _syncClients.values) {
      if (c.hasWorker) workers++;
    }
    return 'useVodDb=$_useVodDb '
        'hydrated=$_vodDiskHydrated '
        'vodDbSources=${_vodDbSourceIds.length} '
        'syncClients=${_syncClients.length} '
        'syncWorkers=$workers '
        'shell=${_desktopShellActive ? 'fg' : 'bg'}';
  }

  AgentSyncTrigger? _agentSyncTrigger;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Keep torrent offline downloads wired (hot reload can leave callbacks null).
  void _wireDownloadTorrentBridge() {
    _downloads.isUnmeteredNetwork = _isUnmeteredNetwork;
    _downloads.torrentService = _torrent;
    _downloads.torrentOfflineDownload =
        ({
          required String jobId,
          required String magnetOrPath,
          required Directory saveDir,
          required MediaItem item,
          required void Function(double progress) onProgress,
          void Function(String name, int bytes)? onFileSelected,
          required bool Function() isCancelled,
        }) {
          return _torrent.downloadOffline(
            jobId: jobId,
            magnetOrPath: magnetOrPath,
            saveDir: saveDir,
            episodeNumber: item.episodeNumber,
            seasonNumber: item.seasonNumber,
            preferredFileName: item.torrentFile,
            onProgress: onProgress,
            onFileSelected: onFileSelected,
            isCancelled: isCancelled,
          );
        };
    _downloads.cancelTorrentOffline = _torrent.cancelOfflineDownload;
  }

  Future<bool> _isUnmeteredNetwork() async {
    // Desktop has no cellular metering; Wi‑Fi-only is a mobile concern.
    // Also, Windows often reports [other] for otherwise fine connections.
    if (DesktopUi.enabled) return true;
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty) return true;
      return results.any(
        (r) =>
            r == ConnectivityResult.wifi ||
            r == ConnectivityResult.ethernet ||
            r == ConnectivityResult.vpn ||
            r == ConnectivityResult.other,
      );
    } catch (_) {
      return true;
    }
  }

  void _onDownloadsChanged() {
    // Start the Android FGS immediately — do not wait on notification debounce,
    // or Home within ~250ms can freeze the isolate before keep-alive starts.
    unawaited(_syncAndroidDownloadKeepAlive());
    // Persist completed offline items when the queue mutates.
    unawaited(_syncCompletedDownloadsToLibrary());
    unawaited(_persistDownloads());
    unawaited(_syncDownloadNotifications());
    // Queue/status transitions (queued → downloading → done) must paint even
    // while catalog hydrate/prefetch has [_uiQuiet] latched — otherwise series
    // episode download icons stay stale until the page is remounted.
    final statusStamp = Object.hashAll(
      _downloads.tasks.map((t) => Object.hash(t.id, t.status)),
    );
    if (statusStamp != _downloadStatusNotifyStamp) {
      _downloadStatusNotifyStamp = statusStamp;
      notifyListenersIgnoringGate();
      return;
    }
    // Progress ticks must not rebuild Home/Catalog/Search every chunk, and
    // must stay gated by [_uiQuiet] (icons listen to [DownloadManager] directly).
    if (_downloadNotifyScheduled) return;
    _downloadNotifyScheduled = true;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        _downloadNotifyScheduled = false;
        notifyListeners();
      }),
    );
  }

  bool _downloadKeepAliveSyncScheduled = false;
  bool _downloadKeepAliveDirty = false;

  Future<void> _syncAndroidDownloadKeepAlive() async {
    // Serialize like notification sync: concurrent progress/completion ticks
    // must not let an in-flight start win over a later idle stop.
    _downloadKeepAliveDirty = true;
    if (_downloadKeepAliveSyncScheduled) return;
    _downloadKeepAliveSyncScheduled = true;
    try {
      while (_downloadKeepAliveDirty) {
        _downloadKeepAliveDirty = false;
        final keepAlive = AndroidDownloadKeepAlive.instance;
        if (!keepAlive.isSupported) return;
        DownloadTask? active;
        for (final task in _downloads.tasks) {
          if (task.status == DownloadStatus.downloading) {
            active = task;
            break;
          }
        }
        if (active == null) {
          await keepAlive.stop();
          continue;
        }
        final pct = (active.progress.clamp(0.0, 1.0) * 100).round();
        final detail = active.statusDetail?.trim();
        final body = (detail != null && detail.isNotEmpty)
            ? '$detail · $pct%'
            : _uiL10n.downloadingPercent(pct);
        await keepAlive.sync(
          _downloads,
          title: DownloadNotificationService.titleFor(active.item),
          body: body,
        );
      }
    } finally {
      _downloadKeepAliveSyncScheduled = false;
    }
  }

  bool _downloadNotifSyncScheduled = false;
  bool _downloadNotifDirty = false;

  Future<void> _syncDownloadNotifications() async {
    _downloadNotifDirty = true;
    if (_downloadNotifSyncScheduled) return;
    _downloadNotifSyncScheduled = true;
    try {
      while (_downloadNotifDirty) {
        _downloadNotifDirty = false;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await DownloadNotificationService.instance.sync(
          _downloads,
          l10n: _uiL10n,
        );
      }
    } catch (e) {
      debugPrint('Download notification sync failed: $e');
    } finally {
      _downloadNotifSyncScheduled = false;
    }
  }

  bool _downloadNotifyScheduled = false;
  int _downloadStatusNotifyStamp = 0;

  /// False until bootstrap restores persisted offline copies into the queue.
  bool _downloadsHydrated = false;

  /// Serializes heavy background work so SIMKL sync isn't crushed by catalog loads.
  final BackgroundActionQueue _bgQueue = BackgroundActionQueue();
  final InteractiveWorkGate _interactive = InteractiveWorkGate();

  final LibraryStore _store;
  final LiveChannelDb _liveDb;
  final VodCatalogDb _vodDb;
  final EpgProgramDb _epgDb;

  /// Which profile's data this provider is bound to.
  String get profileId => _store.profileId;

  /// App/device language for custom catalog `?locale=` (wired from [LocaleController]).
  String Function()? catalogLocale;

  /// Preferred content locales for Home ranking / version picking
  /// (wired from [LocaleController.preferredContentLanguageCodes]).
  List<String> Function()? preferredContentLocales;

  /// Parental PIN / hidden Live groups (wired from [ParentalLockProvider]).
  ParentalLockProvider? parentalLock;

  /// Language code sent on v2 catalog requests (`fr`, `en`, …).
  String? get _catalogLocaleParam {
    final raw =
        (catalogLocale?.call() ??
                PlatformDispatcher.instance.locale.languageCode)
            .trim();
    return raw.isEmpty ? null : raw;
  }

  /// UI copy for source-sync status (Sources row + Live TV strip).
  AppLocalizations get _uiL10n {
    final code = (_catalogLocaleParam ?? 'en')
        .toLowerCase()
        .split(RegExp(r'[_-]'))
        .first;
    final locale = LocaleController.supportedLocales.firstWhere(
      (l) => l.languageCode == code,
      orElse: () => const Locale('en'),
    );
    return lookupAppLocalizations(locale);
  }

  List<String> get _preferredContentLangs {
    final fromController = preferredContentLocales?.call();
    if (fromController != null && fromController.isNotEmpty) {
      return VodGrouping.normalizePreferredLangs(fromController);
    }
    final fallback = _catalogLocaleParam;
    if (fallback != null) return [fallback.toLowerCase()];
    return const ['en'];
  }

  final M3uParser _m3u;
  final CustomCatalogClient? _injectedCustomCatalog;
  final LocalRecommender _recommender;
  final TorrentStreamService _torrent;
  final EpgReminderService _reminders;
  final DownloadManager _downloads;
  final CastService _cast;
  final http.Client? _injectedHttp;
  final XtreamClient? _injectedXtream;
  final SimklClient? _injectedSimkl;
  final TmdbClient? _injectedTmdb;
  final TraktClient? _injectedTrakt;
  final SerializdClient? _injectedSerializd;
  final BetaseriesClient? _injectedBetaseries;
  final SegmentResolver? _injectedSegments;
  static const _uuid = Uuid();

  late http.Client _http;
  late CustomCatalogClient _customCatalog;
  late XtreamClient _xtream;
  late StalkerClient _stalker;
  late SimklClient _simkl;
  late TmdbClient _tmdb;
  late TraktClient _trakt;
  late SerializdClient _serializd;
  late BetaseriesClient _betaseries;
  late SimklEnricher _simklEnricher;
  late TraktEnricher _traktEnricher;
  late TmdbEnricher _tmdbEnricher;
  late SegmentResolver _segments;
  late JellyfinClient _jellyfin;
  late EmbyClient _emby;
  late PlexClient _plex;
  late PlexAccountClient _plexAccount;

  /// Owned DNS-fallback client used when a scope opts out of the proxy.
  http.Client? _ownedDirectHttp;

  /// Owned proxied client (null when proxy inactive or same as injected).
  http.Client? _ownedProxiedHttp;

  ProxySettings proxy = ProxySettings.disabled;

  /// Last proxy handshake failure since the last successful save/test.
  String? lastProxyFailureHost;
  String? lastProxyFailureDetail;
  bool lastProxyFailureIsAuth = false;

  bool loading = true;
  bool onboardingCompleted = false;

  /// One-time VPN/proxy tip before the first torrent peer session.
  bool torrentVpnTipSeen = false;

  /// Host (usually `JavpApp`) shows the tip dialog when torrents start.
  Future<bool> Function()? onTorrentPrivacyTipNeeded;
  String? error;
  String? syncStatus;

  /// Cached `PackageInfo` version including `+build` for catalog `min_version`.
  String? _cachedAppVersion;

  /// Last Accueil shelf paint (lean ids/posters) — cold-start before hydrate.
  HomeShelfSnapshot? _homeShelfSnapshot;
  int? _homeShelfSnapshotPersistedStamp;
  int? _homeShelfPaintFinger;
  bool _homeShelfSnapshotPersistScheduled = false;

  /// Sources JSON has been read (or tests seeded sources). Until then, last-close
  /// tiles must stay — a missing source id is "not loaded yet", not "gone".
  bool _sourcesRestored = false;

  /// Bumped only when a disk snapshot is restored (not on idle persist).
  int _homeShelfSnapshotRevision = 0;

  /// Source ids currently running [syncSource] (background or foreground).
  final Set<String> _syncingSourceIds = {};
  final Map<String, String> _sourceSyncStatus = {};
  /// Throttle hwnd `status` breadcrumbs — VOD progress used to log every chunk.
  final Map<String, int> _hwndStatusLogMs = {};
  List<IptvSource> sources = [];
  List<MediaItem> catalog = [];
  List<MediaItem> localMedia = [];
  List<MediaItem> history = [];
  List<EpgProgram> epg = [];

  /// XMLTV channel id → display-name.
  Map<String, String> epgChannelNames = {};
  List<IptvCategory> categories = [];
  final Map<String, List<EpgProgram>> _epgByStreamId = {};
  final Set<String> _epgLoading = {};

  /// Coalesce overlapping XMLTV reloads (idle multi-source sync used to kick
  /// one full guide fetch per source — same feeds, double apply jank).
  Future<void>? _epgReloadInflight;
  bool _epgReloadDirty = false;

  /// Cached live slice of [catalog] (legacy — empty when SQLite-backed).
  List<MediaItem>? _cachedLiveChannels;
  List<MediaItem>? _liveChannelsCatalogRef;
  int _liveChannelsEnabledStamp = -1;
  String? _liveChannelsLockStamp;

  /// Bumps when any source [IptvSource.enabled] flag changes.
  int _sourcesEnabledStamp = 0;

  /// Watch this from `context.select` so enable/disable rebuilds Home/TV/Sources
  /// immediately (list identity / length alone stay stable across toggles).
  int get sourcesEnabledRevision => _sourcesEnabledStamp;

  /// Bumps when a source name or badge color changes.
  ///
  /// Cheap `context.select` hashes often omit those fields (and quiet-mode can
  /// swallow a list-identity notify), so Sources cards / filter chips / badges
  /// would otherwise stay stale until you left and came back.
  int _sourcesAppearanceStamp = 0;
  int get sourcesAppearanceRevision => _sourcesAppearanceStamp;
  Map<String, MediaItem>? _liveById;
  List<MediaItem>? _liveByIdCatalogRef;

  /// SQLite live store is authoritative after migrate/sync.
  bool _useLiveDb = false;
  int liveDbRevision = 0;

  /// SQLite VOD/series store is authoritative after migrate/sync.
  bool _useVodDb = false;
  int vodDbRevision = 0;

  /// SQLite XMLTV store is authoritative after migrate/sync (native).
  bool _useEpgDb = false;
  int _epgProgramCount = 0;
  EpgChannelAliasIndex? _epgAliasIndex;
  final Set<String> _epgDbFeedUrls = {};
  final Map<String, List<EpgProgram>> _epgXmltvByExactId = {};
  final List<String> _epgXmltvLru = [];
  static const _epgXmltvLruCap = 96;
  final Set<String> _epgXmltvPrefetching = {};
  static const _epgXmltvPrefetchCap = 8;

  /// Cached COUNT(*) so sync [vodCacheCount] stays cheap.
  int _vodDbCountCache = 0;
  List<MediaItem> _favoriteChannelsCache = const [];
  List<MediaItem> _recentChannelsCache = const [];

  /// Bumped when pinned live caches gain/lose channel ids (Home Watch live).
  int _livePinsRevision = 0;
  int? _livePinsFinger;

  /// Precomputed collapsed live index (All + per-group) — legacy JSON path.
  LiveChannelIndex? _liveIndex;
  int liveIndexRevision = 0;
  bool _liveIndexBuilding = false;
  bool _liveIndexLoadAttempted = false;

  /// Family key → quality variants (sorted). Built once per catalog/EPG names.
  Map<String, List<MediaItem>>? _liveFamilyIndex;
  Map<String, String?>? _liveFamilyKeyById;
  Map<String, String>? _liveFamilyIndexNamesRef;

  /// Channel id → max catchup days in the live family (HD Auto may be 0).
  final Map<String, int> _liveFamilyCatchupById = {};

  /// XMLTV channel id → programmes (invalidated when [epg] identity changes).
  EpgLookupIndex? _epgLookupIndex;
  List<EpgProgram>? _epgChannelIndexRef;
  Map<String, String>? _epgChannelNamesIndexRef;

  /// Bumped when EPG caches change so guide UI can `select` without full rebuilds.
  int epgRevision = 0;
  List<EpgReminder> epgReminders = [];
  static const _maxEpgReminders = 50;
  List<MediaItem> vodCategoryItems = [];
  String? activeVodCategoryId;
  bool vodLoading = false;

  /// Bumped when VOD disk hydrate / prefetch / category-load busy state flips
  /// so Catalog can show a spinner without waiting for a quiet-mode ingest tick.
  int vodBusyRevision = 0;
  List<MediaItem> watchlist = [];
  List<String> favoriteChannelIds = [];
  List<String> favoriteCategoryIds = [];
  List<String> recentChannelIds = [];

  /// `sourceId|name:…` or `sourceId|epg:…` → preferred live `streamId`.
  /// Explicit "Remember for this channel" only — not written on every pick.
  Map<String, String> preferredLiveQualities = {};

  /// In-memory quality override for the current app session (not persisted).
  Map<String, String> _sessionLiveQualities = {};

  /// Global live SD/HD/4K pick rule (Auto by default).
  LiveQualityMode liveQualityMode = LiveQualityMode.auto;

  /// VOD group key (`tmdb:movie:…` / `imdb:…` / `name:…`) → preferred item id.
  Map<String, String> preferredVodVariants = {};

  /// Live scrubber: rolling DVR timeline vs current EPG programme.
  LiveScrubMode liveScrubMode = LiveScrubModeX.defaultFor(
    androidTv: TvPlatform.isAndroidTv,
  );

  /// Speeds a tap / `,` `.` on the player chip cycles through.
  List<double> cyclePlaybackSpeeds = List<double>.from(kPlaybackSpeeds);

  /// Cross-category VOD cache so EN/FR language rows can merge after both loads.
  final Map<String, MediaItem> _vodStreamCache = {};

  /// Bumped whenever [_vodStreamCache] mutates (Catalog list stamp / index).
  int _vodCacheRevision = 0;

  /// Accueil Films/Series shelf stamp — bumped when ranked Home previews publish
  /// (group index), not on raw disk hydrate. Hydrate used to bump
  /// [vodCacheRevision] + wipe shelf caches and force a ~700ms rematerialize
  /// with identical shelf counts (`tags=shelf`).
  int _homeVodShelfRevision = 0;

  /// Lazy `group` → titles index; avoids scanning the full VOD universe per query.
  Map<String, List<MediaItem>>? _vodByGroupIndex;
  int? _vodByGroupIndexRevision;

  /// Home Films/Series rails: top posters ranked from the **full** movie/series
  /// sets during [ensureVodGroupIndex] (not a truncated cache prefix).
  List<MediaItem>? _vodHomeMoviePreview;
  List<MediaItem>? _vodHomeSeriesPreview;

  /// In-flight group-index build; awaited by See-all / shelf warm paths.
  Future<void>? _vodIndexBuildFuture;

  /// Precomputed lowercase haystacks for Search (id → text). Cleared on
  /// [_touchVodCache]; rebuilt with frame yields so typing stays responsive.
  Map<String, String>? _vodSearchHayById;
  int? _vodSearchHayRevision;
  bool _vodSearchHayBuilding = false;
  Future<void>? _vodSearchHayBuildFuture;

  /// ~8ms UI slices (same idea as Catalog Movies / Versions index warm).
  static const _vodSearchSliceMs = 8;

  /// Bumped on each [searchRemoteSources] so superseded keystrokes abort early
  /// instead of stacking custom catalog + media-server GETs + catalog saves.
  int _remoteSearchGen = 0;

  /// Bumped on each [searchLocalLibrary] so superseded keystrokes stop waiting
  /// on a slow FTS / RAM scan instead of stacking 4s timeouts (typing lag).
  int _localSearchGen = 0;

  /// Serializes interactive local search so abandoned FTS futures cannot pile
  /// up on the sqflite queue (`.timeout` does not cancel the DB work).
  Future<void>? _localSearchTail;

  /// Interactive FTS budget — waiting the full sqflite busy window freezes
  /// Search keystrokes (see `fts timeout` + `local in 4297ms` in javp.log).
  static const _interactiveFtsTimeout = Duration(milliseconds: 450);

  /// After an FTS timeout the sqflite isolate may still be chewing the MATCH;
  /// skip further FTS until this instant so typing does not queue more.
  DateTime? _ftsCooldownUntil;
  static const _ftsCooldown = Duration(seconds: 2);

  /// After disk hydrate: hay + tracker relinks wait; indexes may defer on blur.
  Timer? _postHydrateFollowupsTimer;

  /// True when post-hydrate group/Versions indexes were skipped (blur/AFK).
  bool _postHydrateIndexesPending = false;

  /// Let Accueil settle before search hay / Simkl match-index over ~200k rows.
  static const _postHydrateSettleDelay = Duration(seconds: 4);

  final Set<String> _vodPrefetching = {};
  /// Desktop out-of-process VOD writers (cancel on abort / dispose).
  final Map<String, SyncClient> _syncClients = {};

  /// Shelf/category demand fetches: dedupe by source+category and cap network
  /// concurrency without sharing the category-page loading/selection state.
  final Map<String, Future<void>> _vodCategoryLoads = {};
  final List<Completer<void>> _vodCategoryNetworkWaiters = [];
  int _vodCategoryNetworkActive = 0;
  static const _maxVodCategoryNetworkFetches = 3;

  /// Xtream sources currently filling live categories in the background.
  final Set<String> _liveCategoryPrefetching = {};

  /// Sources whose idle live-category fill was paused on blur/AFK — resume
  /// after focus at low priority (TV open still demand-loads via
  /// [ensureLiveCategoryAvailable]).
  final Set<String> _liveCategoryPrefetchPaused = {};

  /// Bumped when Xtream live categories are refreshed (invalidates fill marks).
  /// Session-only — SQLite occupancy is the restart-safe source of truth.
  final Map<String, int> _xtreamLiveCategoriesEpoch = {};

  /// `${sourceId}|${categoryId}` → epoch when that live group was last filled.
  /// Session-only. After restart, [LiveChannelDb] listing counts decide skip.
  final Map<String, int> _liveCategoryFilledEpoch = {};

  /// In-flight live category fills (dedupe concurrent TV opens).
  final Map<String, Future<void>> _liveCategoryLoads = {};
  final Set<String> _liveCategoryInteractiveLoads = {};
  Future<void>? _ensureLiveCategoryRowsInflight;

  /// Last successful EPG download bytes + validators (session cache for 304).
  final Map<String, _EpgHttpCacheEntry> _epgHttpCache = {};

  /// Web / fallback only. Native 304 reuse is [EpgProgramDb.hasFeed].
  final Map<String, EpgParseResult> _epgParsedByUrl = {};

  /// URL set last applied to [epg] (skip merge when unchanged + all reused).
  Set<String> _epgAppliedUrls = {};

  /// Feeds already on disk (native) or last merged into RAM (web fallback).
  Set<String> get _epgWarmFeedUrls =>
      _useEpgDb && _epgDbFeedUrls.isNotEmpty ? _epgDbFeedUrls : _epgAppliedUrls;

  Timer? _epgReloadDebounce;
  Completer<void>? _epgReloadWaiters;
  String _epgReloadReason = 'unspecified';
  Future<void>? _epgReloadInFlight;

  /// Sources that finished playlist sync and are waiting on the coalesced
  /// XMLTV reload — keeps Sources "busy" through guide download/parse.
  final Set<String> _epgReloadPendingSourceIds = {};

  /// Idle Xtream live fill dirtied SQLite without bumping [liveDbRevision].
  bool _prefetchLiveDbDirty = false;

  /// Drop re-fetchable session scratch under OS memory pressure.
  ///
  /// Raw EPG HTTP bodies can be tens of MB. Native programmes live in
  /// [EpgProgramDb]; drop the HTTP cache and XMLTV LRU. Keep the alias
  /// index and per-stream API cache so Guide / 304 reuse still work.
  void dropTransientMemoryCaches() {
    _epgHttpCache.clear();
    _epgXmltvByExactId.clear();
    _epgXmltvLru.clear();
  }

  /// Manual Sync Now asked for VOD while live sync / prefetch was already busy.
  final Set<String> _pendingForceVodRefresh = {};

  /// When true, skip [notifyListeners] so IndexedStack tabs don't all rebuild.
  bool _uiQuiet = false;
  String _debugSyncPhase = '-';

  void _touchVodCache() {
    _vodCacheRevision++;
    _vodByGroupIndex = null;
    _vodByGroupIndexRevision = null;
    _vodHomeMoviePreview = null;
    _vodHomeSeriesPreview = null;
    _vodPoolCache = null;
    if (_vodVariantIndex != null) {
      _vodVariantStaleIndex = _vodVariantIndex;
      _vodVariantStaleCanonical = _vodGroupCanonical;
    }
    _vodVariantIndex = null;
    _vodGroupCanonical = null;
    _cachedGroupBuckets = null;
    _groupBucketsStamp = -1;
    _cachedVodPreviewMovies = null;
    _cachedVodPreviewSeries = null;
    _vodPreviewMoviesStamp = -1;
    _vodPreviewSeriesStamp = -1;
    _vodSearchHayById = null;
    _vodSearchHayRevision = null;
    _cachedVodCategories = null;
    _cachedSeriesCategories = null;
    _onDemandCategoriesStamp = -1;
  }

  void _invalidateHomeShelfCaches() {
    _cachedRecommendations = null;
    _recommendationsStamp = -1;
    _cachedGroupBuckets = null;
    _groupBucketsStamp = -1;
    _cachedContinueWatching = null;
    _continueWatchingStamp = -1;
    _cachedVodPreviewMovies = null;
    _cachedVodPreviewSeries = null;
    _vodPreviewMoviesStamp = -1;
    _vodPreviewSeriesStamp = -1;
    _cachedVodCategories = null;
    _cachedSeriesCategories = null;
    _onDemandCategoriesStamp = -1;
  }

  /// Replace a cached title without invalidating the group index (enrich path).
  void _replaceVodCacheItem(MediaItem item) {
    final prev = _vodStreamCache[item.id];
    _vodStreamCache[item.id] = item;
    final hay = _vodSearchHayById;
    if (hay != null && _vodSearchHayRevision == _vodCacheRevision) {
      hay[item.id] = VodSearchIndex.hayFor(item);
    }
    final index = _vodByGroupIndex;
    if (index == null) return;
    final group = item.group ?? prev?.group ?? '';
    final bucket = index[group];
    if (bucket == null) return;
    // DB group-index seeds empty shelves as const [] (category rails only).
    // Search / detail enrich must grow those buckets — copy before mutate.
    final next = List<MediaItem>.of(bucket);
    final i = next.indexWhere((m) => m.id == item.id);
    if (i >= 0) {
      next[i] = item;
    } else {
      next.add(item);
    }
    index[group] = next;
  }

  /// Test helper: install empty [const []] group buckets (DB group-index shape)
  /// then call [_replaceVodCacheItem] — must not throw / freeze.
  @visibleForTesting
  void debugReplaceVodCacheItemWithConstGroupBuckets(MediaItem item) {
    final group = item.group ?? '';
    _vodByGroupIndex = {group: const <MediaItem>[]};
    _vodByGroupIndexRevision = _vodCacheRevision;
    _replaceVodCacheItem(item);
  }

  /// Test helper: seed [_vodStreamCache] (+ optional group index) in insertion order.
  @visibleForTesting
  void debugSeedVodStreamCache(
    Iterable<MediaItem> items, {
    bool buildIndex = true,
  }) {
    _vodStreamCache
      ..clear()
      ..addEntries([for (final m in items) MapEntry(m.id, m)]);
    _vodCacheRevision++;
    if (buildIndex) {
      final map = <String, List<MediaItem>>{};
      final movies = <MediaItem>[];
      final series = <MediaItem>[];
      for (final item in items) {
        map.putIfAbsent(item.group ?? '', () => <MediaItem>[]).add(item);
        if (item.isSeries) {
          series.add(item);
        } else if (!item.isLive &&
            !item.isEpisode &&
            (item.kind == MediaKind.vod || item.kind == MediaKind.series)) {
          movies.add(item);
        }
      }
      final prefs = _preferredContentLangs;
      movies.sort(
        (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
      );
      series.sort(
        (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
      );
      _vodByGroupIndex = map;
      _vodByGroupIndexRevision = _vodCacheRevision;
      // Intentional Home preview window (display only) from the full ranked set.
      _vodHomeMoviePreview = movies.length <= 64
          ? movies
          : movies.sublist(0, 64);
      _vodHomeSeriesPreview = series.length <= 64
          ? series
          : series.sublist(0, 64);
    } else {
      _vodByGroupIndex = null;
      _vodByGroupIndexRevision = null;
      _vodHomeMoviePreview = null;
      _vodHomeSeriesPreview = null;
    }
    _vodSearchHayById = VodSearchIndex.buildHayMap(_vodStreamCache.values);
    _vodSearchHayRevision = _vodCacheRevision;
    _vodDiskHydrated = true;
    _invalidateHomeShelfCaches();
  }

  /// Test helper: drop one hay entry while keeping revision warm (incomplete map).
  @visibleForTesting
  void debugDropSearchHayEntry(String id) {
    _vodSearchHayById?.remove(id);
  }

  /// Test helper: latch quiet-mode the way hydrate / prefetch does.
  @visibleForTesting
  void debugSetUiQuiet(bool quiet) {
    _uiQuiet = quiet;
  }

  /// Test helper: SQLite group maps as Catalog would see them after ingest.
  ///
  /// RAM [_vodByGroupIndex] buckets stay empty on the native SQLite path;
  /// [vodCategories] must still list these names.
  @visibleForTesting
  void debugSeedVodDbGroupCache({
    required Map<String, Set<String>> movieGroupsBySource,
    Map<String, Set<String>> seriesGroupsBySource = const {},
  }) {
    _useVodDb = true;
    _vodDbMovieGroupsBySource = {
      for (final e in movieGroupsBySource.entries) e.key: {...e.value},
    };
    _vodDbSeriesGroupsBySource = {
      for (final e in seriesGroupsBySource.entries) e.key: {...e.value},
    };
    _vodDbGroupCacheRevision++;
    _cachedVodCategories = null;
    _cachedSeriesCategories = null;
    _onDemandCategoriesStamp = -1;
  }

  /// Test helper: whether hydrate / prefetch quiet-mode is latched.
  @visibleForTesting
  bool get debugUiQuiet => _uiQuiet;

  /// Test helper: drop the live Versions index the way TMDB enrich does.
  @visibleForTesting
  void debugInvalidateVodVariantIndex() => _invalidateVodVariantIndex();

  /// Test helper: mark a title-page sqlite hydrate as done.
  @visibleForTesting
  void debugMarkVodFamilyHydrated(String key) =>
      _vodFamilyHydratedKeys.add(key);

  /// Test helper: whether [hydrateVodFamilyFromDb] would skip [key].
  @visibleForTesting
  bool debugIsVodFamilyHydrated(String key) =>
      _vodFamilyHydratedKeys.contains(key);

  /// Test helper: idle Accueil sqlite-family hydrate queue.
  @visibleForTesting
  int get debugHomeFamilyHydrateQueueLength => _homeFamilyHydrateQueue.length;

  /// Test helper: live Versions map (null while a rebuild is in flight).
  @visibleForTesting
  Map<String, List<MediaItem>>? get debugVodVariantIndex {
    final index = _vodVariantIndex;
    if (index == null) return null;
    return {
      for (final e in index.entries)
        e.key: [
          for (final id in e.value)
            if (_vodItemById(id) case final m?) m,
        ],
    };
  }

  /// Test helper: whether restore/focus thaw is holding background apply.
  @visibleForTesting
  bool get debugShellThawing => _shellThawing;

  /// Test helper: idle catalog work is allowed (focused, not playing, not thawing).
  @visibleForTesting
  bool get debugAllowIdleBackgroundWork => _allowIdleBackgroundWork;

  /// Test helper: UI-heavy apply is allowed (focused, not thawing).
  @visibleForTesting
  bool get debugShellAllowsBackgroundApply => _shellAllowsBackgroundApply;

  /// Cap for parking a user Sync on a missed window-focus event.
  @visibleForTesting
  static const Duration debugSoftSyncShellWaitCap = Duration(seconds: 2);

  /// Live dump for the debug HUD / stall logs.
  LibraryWorkDebugSnapshot debugWorkSnapshot() {
    List<String> shorts(Set<String> ids) {
      final out = [for (final id in ids) shortSourceId(id)]..sort();
      return out;
    }

    return LibraryWorkDebugSnapshot(
      route: JavpLog.currentRoute ?? '-',
      stallPhase: UiStallWatchdog.phase,
      lastYieldMs: UiStallWatchdog.lastYieldAgeMs,
      foreground: _appForeground,
      shellActive: _desktopShellActive,
      thawing: _shellThawing,
      uiQuiet: _uiQuiet,
      playbackActive: _playbackActive,
      syncPhase: _debugSyncPhase,
      playlistSync: shorts(_syncingSourceIds),
      epgPending: shorts(_epgReloadPendingSourceIds),
      vodPrefetch: shorts(_vodPrefetching),
      liveFill: shorts(_liveCategoryPrefetching),
      deepSync: shorts(_deepSyncing),
      status: syncStatus,
    );
  }

  /// Test helper: generation bumped on blur / background.
  @visibleForTesting
  int get debugIdleWorkGeneration => _idleWorkGeneration;

  /// Test helper: stall watchdog recovery (drop queued idle work).
  @visibleForTesting
  void debugOnUiStall({int gapMs = 500, String phase = 'test'}) =>
      _onUiStallDetected(gapMs, phase);

  /// Drop queued idle catalog jobs so a covering route (Sources) can paint
  /// while a background sync is in flight. In-flight *manual* syncs continue.
  void pauseOpportunisticIdle({required String reason}) {
    if (_disposed) return;
    _dropOpportunisticIdle(reason: reason);
  }

  /// Test helper: cooperative yield used by soft [syncSource].
  @visibleForTesting
  Future<bool> debugYieldSoftSyncToShell({
    required String reason,
    required int generation,
    bool blockUi = false,
  }) => _yieldSoftSyncToShell(
    blockUi: blockUi,
    reason: reason,
    generation: generation,
  );

  /// Test helper: seed favorite / recent live caches for Home Watch live.
  @visibleForTesting
  void debugSetPinnedLiveChannels({
    List<MediaItem> favorites = const [],
    List<MediaItem> recents = const [],
  }) {
    favoriteChannelIds = [for (final c in favorites) c.id];
    recentChannelIds = [for (final c in recents) c.id];
    _favoriteChannelsCache = List<MediaItem>.from(favorites);
    _recentChannelsCache = List<MediaItem>.from(recents);
    _rememberLivePinsFinger(bump: true);
  }

  /// Test helper: restore last-close Watch live pins the way cold start does.
  @visibleForTesting
  void debugSeedHomeShelfSnapshot(HomeShelfSnapshot snap) {
    _homeShelfSnapshot = snap;
    _homeShelfSnapshotPersistedStamp = snap.contentStamp;
    _homeShelfPaintFinger = snap.contentStamp;
    _seedLivePinsFromHomeSnapshot(snap);
  }

  @override
  bool get notifyListenersDisposed => _disposed;

  @override
  bool get allowNotifyListeners => !_uiQuiet;

  @override
  void onBeforeNotifyListeners() => JavpLog.noteNotify();

  /// Pierce [_uiQuiet] from same-library extensions (`super` is illegal there).
  /// Still deferred if the widget tree is locked (build / layout).
  void _notifyPierceQuiet() => notifyListenersIgnoringGate();

  /// Settings toggles already paint optimistically; fan-out to IndexedStack
  /// shell listeners must not share a vsync with the switch settle frame.
  ///
  /// Coalesces bursts (reloadAfterSync + simkl + for-you) into one idle tick.
  bool _idleNotifyScheduled = false;
  void _notifyListenersAfterIdle() {
    if (_shellThawing) {
      _thawNotifyPending = true;
      return;
    }
    if (_idleNotifyScheduled) return;
    _idleNotifyScheduled = true;
    SchedulerBinding.instance.scheduleTask(() {
      _idleNotifyScheduled = false;
      if (_disposed || _uiQuiet) return;
      if (_shellThawing) {
        _thawNotifyPending = true;
        return;
      }
      notifyListeners();
    }, Priority.idle);
  }

  // ── Write-behind persistence ───────────────────────────────────────────
  // Playback reports progress every five seconds, and each report used to
  // re-encode and rewrite the whole catalog, local media and history inline.
  // On a large library that stalled the UI isolate for hundreds of
  // milliseconds at a time. Writes are now marked dirty and flushed once on a
  // short delay — and immediately when the app backgrounds or shuts down, so
  // nothing is lost.
  //
  // Progress ticks use a longer soft delay so SharedPreferences is not hit
  // every few seconds while video is playing; pause/stop/background flush now.
  final Set<_PersistTarget> _pendingWrites = {};
  Timer? _writeBehindTimer;
  Timer? _softPersistTimer;
  bool _disposed = false;
  static const _writeBehindDelay = Duration(seconds: 5);
  static const _softPersistDelay = Duration(seconds: 45);

  /// In-memory catalog rows patched from watch/progress; persisted only on
  /// flush/background so a session open never queues a full-library rewrite
  /// five seconds into playback.
  bool _catalogProgressDirty = false;

  /// True while PlaybackProvider has an active playing session — idle catalog
  /// sync / VOD warm must yield so they never compete with frames.
  bool _playbackActive = false;

  /// Bumped by clear/remove so an in-flight write-behind flush cannot rewrite
  /// a stale history snapshot after the user emptied it.
  int _historyEpoch = 0;

  /// Bumped on every watch/progress mutation so series episode grids rebuild
  /// even when [history.first] is unchanged (multi-version / older rows).
  int watchHistoryRevision = 0;

  /// Same idea as [_historyEpoch] for on-device library rows. Soft-persist after
  /// progress/metadata could otherwise rewrite a pre-Retirer [localMedia]
  /// snapshot and bring "azeaze"-style URL ghosts back from disk.
  int _localMediaEpoch = 0;

  /// In-memory copy of history/local URL tombstones (`watch_history_deleted`).
  Map<String, DateTime> _historyDeleted = {};

  /// Fired after syncable profile data is written (history, etc.) so the app
  /// shell can schedule a debounced profile sync.
  ///
  /// [urgent] is true for source list changes other devices cannot see until
  /// this device pushes (add / remove / edit / enable). Those skip the
  /// 5-minute local-dirty floor.
  void Function({bool urgent})? onSyncableChanged;

  void _noteSyncableChange({bool urgent = false}) {
    if (_disposed) return;
    onSyncableChanged?.call(urgent: urgent);
  }

  /// Called from [PlaybackProvider] so background jobs can defer mid-play.
  void setPlaybackActive(bool active) {
    _playbackActive = active;
  }

  bool get playbackActive => _playbackActive;

  void _schedulePersist(_PersistTarget target) {
    if (_disposed) return;
    _pendingWrites.add(target);
    _writeBehindTimer ??= Timer(_writeBehindDelay, () {
      _writeBehindTimer = null;
      unawaited(flushPendingWrites());
    });
  }

  /// History / local-media dirtied by progress ticks — coalesce for 45s so
  /// playback is not punctuated by prefs I/O every few seconds.
  void _scheduleSoftPersist(_PersistTarget target) {
    if (_disposed) return;
    _pendingWrites.add(target);
    _softPersistTimer ??= Timer(_softPersistDelay, () {
      _softPersistTimer = null;
      unawaited(flushPendingWrites());
    });
  }

  void _stopPersistTimersIfIdle() {
    if (_pendingWrites.isEmpty) {
      _writeBehindTimer?.cancel();
      _writeBehindTimer = null;
      _softPersistTimer?.cancel();
      _softPersistTimer = null;
    }
  }

  void _cancelPendingHistoryPersist() {
    _pendingWrites.remove(_PersistTarget.history);
    _stopPersistTimersIfIdle();
  }

  void _cancelPendingLocalMediaPersist() {
    _pendingWrites.remove(_PersistTarget.localMedia);
    _stopPersistTimersIfIdle();
  }

  Future<void> _persistHistoryNow(List<MediaItem> items) async {
    final epoch = _historyEpoch;
    final snapshot = List<MediaItem>.from(items);
    await _store.saveHistory(snapshot);
    if (epoch != _historyEpoch) {
      // A clear/remove landed while we were writing — keep the newer state.
      await _store.saveHistory(List<MediaItem>.from(history));
    }
  }

  Future<void> _persistLocalMediaNow(List<MediaItem> items) async {
    final epoch = _localMediaEpoch;
    final snapshot = List<MediaItem>.from(items);
    await _store.saveLocalMedia(snapshot);
    if (epoch != _localMediaEpoch) {
      await _store.saveLocalMedia(List<MediaItem>.from(localMedia));
    }
  }

  bool _isHistoryTombstoned(MediaItem item) {
    if (_historyDeleted.containsKey(item.id)) return true;
    if (!_isUserOwnedLibraryOrigin(item)) return false;
    final urlKey = HistorySyncData.urlTombstoneKey(item.playUrl);
    return urlKey != null && _historyDeleted.containsKey(urlKey);
  }

  /// Drop tombstoned URL/import rows from in-memory library + history.
  /// Catalog rows with the same stream are left alone.
  void _purgeTombstonedOwnedLibraryRows({bool persist = false}) {
    final nextLocal = localMedia
        .where((m) => !_isHistoryTombstoned(m))
        .toList(growable: false);
    final nextHistory = history
        .where((m) => !_isHistoryTombstoned(m))
        .toList(growable: false);
    if (nextLocal.length != localMedia.length) {
      localMedia = nextLocal;
      _localMediaEpoch++;
      _cancelPendingLocalMediaPersist();
      if (persist) unawaited(_persistLocalMediaNow(localMedia));
    }
    if (nextHistory.length != history.length) {
      history = nextHistory;
      _historyEpoch++;
      _cancelPendingHistoryPersist();
      _cachedContinueWatching = null;
      _continueWatchingStamp = -1;
      if (persist) unawaited(_persistHistoryNow(history));
    }
  }

  /// Records that [ids] / [playUrls] were intentionally removed so sync cannot
  /// resurrect them (id tombstones + `url:<playUrl>` for sibling ghosts).
  Future<void> _tombstoneHistoryIds(
    Iterable<String> ids, {
    Iterable<String> playUrls = const [],
  }) async {
    final now = DateTime.now().toUtc();
    final deleted = Map<String, DateTime>.from(_historyDeleted);
    var changed = false;
    for (final id in ids) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      deleted[trimmed] = now;
      changed = true;
    }
    for (final url in playUrls) {
      final key = HistorySyncData.urlTombstoneKey(url);
      if (key == null) continue;
      deleted[key] = now;
      changed = true;
    }
    if (!changed) return;
    _historyDeleted = deleted;
    await _store.saveHistoryDeleted(deleted);
  }

  Future<void> _clearHistoryTombstone(String id, {String? playUrl}) async {
    final deleted = Map<String, DateTime>.from(_historyDeleted);
    var changed = false;
    final trimmed = id.trim();
    if (trimmed.isNotEmpty && deleted.remove(trimmed) != null) {
      changed = true;
    }
    final urlKey = HistorySyncData.urlTombstoneKey(playUrl);
    if (urlKey != null && deleted.remove(urlKey) != null) {
      changed = true;
    }
    if (!changed) return;
    _historyDeleted = deleted;
    await _store.saveHistoryDeleted(deleted);
  }

  /// Home publishes live shelf lists after paint — persist for next cold start.
  void noteHomeShelfPaint({
    required List<MediaItem> continueWatching,
    required List<MediaItem> watching,
    required List<MediaItem> movies,
    required List<MediaItem> series,
    required List<MediaItem> forYou,
    required List<MediaItem> myList,
    required List<MediaItem> trending,
    required List<MediaItem> popular,
    List<MediaItem> recentLive = const [],
    bool watchLive = false,
    List<HomeContentType> typeOrder = const [],
  }) {
    if (_disposed) return;
    final finger = Object.hash(
      continueWatching.length,
      watching.length,
      movies.length,
      series.length,
      forYou.length,
      myList.length,
      trending.length,
      popular.length,
      recentLive.length,
      watchLive,
      Object.hashAll([for (final t in typeOrder) t.index]),
      Object.hashAll([
        for (final m in continueWatching.take(24))
          Object.hash(m.id, m.progress),
      ]),
      Object.hashAll([for (final m in watching.take(24)) m.id]),
      Object.hashAll([for (final m in movies.take(24)) m.id]),
      Object.hashAll([for (final m in series.take(24)) m.id]),
      Object.hashAll([for (final m in forYou.take(24)) m.id]),
      Object.hashAll([for (final m in myList.take(24)) m.id]),
      Object.hashAll([for (final m in trending.take(24)) m.id]),
      Object.hashAll([for (final m in popular.take(24)) m.id]),
      Object.hashAll([for (final m in recentLive.take(12)) m.id]),
    );
    _enqueueHomeFamilyHydrate([
      ...movies,
      ...series,
      ...forYou,
      ...myList,
      ...trending,
      ...popular,
    ]);
    if (_homeShelfPaintFinger == finger) return;
    _homeShelfPaintFinger = finger;
    final snap = HomeShelfSnapshot(
      savedAt: DateTime.now().toUtc(),
      continueWatching: _leanShelfItems(continueWatching),
      watching: _leanShelfItems(watching),
      movies: _leanShelfItems(movies),
      series: _leanShelfItems(series),
      forYou: _leanShelfItems(forYou),
      myList: _leanShelfItems(myList),
      trending: _leanShelfItems(trending),
      popular: _leanShelfItems(popular),
      recentLive: _leanShelfItems(recentLive, cap: 12),
      watchLive: watchLive,
      typeOrder: typeOrder,
    );
    if (!snap.hasContent) {
      _clearHomeShelfSnapshot(persist: true);
      return;
    }
    _homeShelfSnapshot = snap;
    _scheduleHomeShelfSnapshotPersist();
  }

  static List<MediaItem> _leanShelfItems(
    List<MediaItem> items, {
    int cap = 18,
  }) {
    if (items.isEmpty) return const [];
    final capped = items.length <= cap ? items : items.sublist(0, cap);
    // Round-trip via toSyncJson so disk stays lean (poster + identity + progress).
    return [for (final m in capped) MediaItem.fromJson(m.toSyncJson())];
  }

  void _scheduleHomeShelfSnapshotPersist() {
    if (_homeShelfSnapshotPersistScheduled) return;
    _homeShelfSnapshotPersistScheduled = true;
    SchedulerBinding.instance.scheduleTask(() {
      _homeShelfSnapshotPersistScheduled = false;
      if (_disposed) return;
      unawaited(_persistHomeShelfSnapshotNow());
    }, Priority.idle);
  }

  Future<void> _persistHomeShelfSnapshotNow() async {
    final snap = _homeShelfSnapshot;
    if (snap == null || !snap.hasContent) {
      try {
        await _store.clearHomeShelfSnapshot();
      } catch (_) {}
      return;
    }
    final stamp = snap.contentStamp;
    if (_homeShelfSnapshotPersistedStamp == stamp) return;
    _homeShelfSnapshotPersistedStamp = stamp;
    try {
      await _store.saveHomeShelfSnapshot(snap);
      JavpLog.i(
        'shelf',
        'home snapshot saved '
            'cw=${snap.continueWatching.length} '
            'movies=${snap.movies.length} '
            'series=${snap.series.length} '
            'forYou=${snap.forYou.length} '
            'live=${snap.recentLive.length} '
            'watchLive=${snap.watchLive}',
      );
    } catch (_) {
      _homeShelfSnapshotPersistedStamp = null;
    }
  }

  void _clearHomeShelfSnapshot({required bool persist}) {
    if (_homeShelfSnapshot == null && _homeShelfPaintFinger == null) return;
    _homeShelfSnapshot = null;
    _homeShelfPaintFinger = null;
    _homeShelfSnapshotPersistedStamp = persist ? 0 : null;
    _homeShelfSnapshotRevision++;
    if (persist) _scheduleHomeShelfSnapshotPersist();
  }

  /// Last-close tiles whose catalog/source is still on this device and visible.
  bool _homeSnapshotItemAllowed(MediaItem item) {
    final origin = item.origin;
    if (origin == MediaOrigin.localFile ||
        origin == MediaOrigin.download ||
        origin == MediaOrigin.url ||
        origin == MediaOrigin.torrent) {
      return true;
    }
    final sid = item.sourceId;
    if (sid == null || sid.isEmpty || sid == localSourceKey) return true;
    if (item.isLive || item.kind == MediaKind.catchup) {
      return isSourceContentVisible(sid) &&
          (!_sourcesRestored || _sourceById(sid) != null);
    }
    return isListedVodSourceVisible(sid);
  }

  HomeShelfSnapshot? _visibleHomeShelfSnapshot(HomeShelfSnapshot snap) {
    if (!_sourcesRestored) return snap;
    final pruned = snap.whereItems(_homeSnapshotItemAllowed);
    if (!pruned.hasContent) return null;
    return pruned;
  }

  /// Drop last-close Home tiles for catalogs that no longer exist / are hidden.
  void _pruneHomeShelfSnapshotToVisibleSources({bool persist = true}) {
    final snap = _homeShelfSnapshot;
    if (snap == null) return;
    if (!_sourcesRestored) return;
    final pruned = _visibleHomeShelfSnapshot(snap);
    if (pruned == null || !pruned.hasContent) {
      _clearHomeShelfSnapshot(persist: persist);
      return;
    }
    if (identical(pruned, snap) || pruned.contentStamp == snap.contentStamp) {
      return;
    }
    _homeShelfSnapshot = pruned;
    _homeShelfPaintFinger = null;
    _homeShelfSnapshotRevision++;
    if (persist) _scheduleHomeShelfSnapshotPersist();
  }

  void _applyHomeShelfSnapshot(HomeShelfSnapshot snap) {
    if (!snap.hasContent) return;
    _homeShelfSnapshot = snap;
    _homeShelfSnapshotPersistedStamp = snap.contentStamp;
    _homeShelfPaintFinger = snap.contentStamp;
    _homeShelfSnapshotRevision++;
    _seedLivePinsFromHomeSnapshot(snap);
    JavpLog.i(
      'shelf',
      'home snapshot restored '
          'cw=${snap.continueWatching.length} '
          'movies=${snap.movies.length} '
          'series=${snap.series.length} '
          'forYou=${snap.forYou.length} '
          'live=${snap.recentLive.length} '
          'watchLive=${snap.watchLive}',
    );
  }

  List<({MediaItem channel, EpgProgram program})>? _cachedOnNow;
  int _cachedOnNowEpgRev = -1;
  List<MediaItem>? _cachedOnNowLiveRef;
  String? _cachedOnNowLockStamp;
  List<MediaItem>? _cachedRecommendations;
  int _recommendationsStamp = -1;
  Map<String, double> _remoteRecBoosts = const {};
  String? _remoteRecFingerprint;
  bool _remoteRecInflight = false;
  ForYouRemoteEnricher _remoteRecEnricher = ForYouRemoteEnricher();
  TmdbLocalDiscovery _tmdbDiscovery = TmdbLocalDiscovery();
  List<MediaItem> _tmdbTrendingShelf = const [];
  List<MediaItem> _tmdbPopularShelf = const [];
  int _tmdbDiscoveryRevision = 0;
  String? _tmdbDiscoveryFingerprint;
  bool _tmdbDiscoveryInflight = false;
  bool _tmdbDiscoveryAttempted = false;

  /// Ranked catalog `group` buckets for Home rails (exclude applied on read).
  List<MapEntry<String, List<MediaItem>>>? _cachedGroupBuckets;
  int _groupBucketsStamp = -1;
  List<MediaItem>? _cachedContinueWatching;
  int _continueWatchingStamp = -1;
  List<MediaItem>? _cachedVodPreviewMovies;
  List<MediaItem>? _cachedVodPreviewSeries;
  int _vodPreviewMoviesStamp = -1;
  int _vodPreviewSeriesStamp = -1;
  int _vodPreviewMoviesLimit = -1;

  /// Catalog Movies/Series category rails — rebuilt from group index when ready.
  List<IptvCategory>? _cachedVodCategories;
  List<IptvCategory>? _cachedSeriesCategories;
  int _onDemandCategoriesStamp = -1;
  int _vodPreviewSeriesLimit = -1;
  SimklCredentials simkl = const SimklCredentials(clientId: '');

  /// Matched / shelled Simkl Watching list for Home + My List.
  List<MediaItem> simklWatching = [];

  /// Content fingerprint for Home freeze stamp — ignores list identity so a
  /// quiet re-resolve / identical relink does not rematerialize every shelf.
  int get simklWatchingShelfStamp {
    final items = simklWatching;
    if (items.isEmpty) return 0;
    return Object.hash(
      items.length,
      Object.hashAll([for (final m in items) Object.hash(m.id, m.progress)]),
    );
  }

  /// Accueil rematerialize stamp — content only (not list identity / sync flags).
  ///
  /// [reloadAfterSync] / simkl / for-you used to bump [identityHashCode] on
  /// history and rematerialize shelves when playheads were unchanged.
  int get homeShelfContentStamp {
    final hist = history;
    final histFinger = hist.isEmpty
        ? 0
        : Object.hash(
            hist.length,
            hist.first.id,
            hist.first.progress,
            hist.first.lastWatchedAt?.millisecondsSinceEpoch,
            hist.length > 1 ? Object.hash(hist[1].id, hist[1].progress) : 0,
          );
    return Object.hash(
      histFinger,
      watchlist.length,
      homeVodShelfRevision,
      catalog.length,
      localMedia.length,
      sources.length,
      sourcesEnabledRevision,
      // Do not include [loading] — flipping it rematerialized every shelf even
      // when history/CW were unchanged. Snapshot restore uses its own revision.
      favoriteChannelIds.length,
      recentChannelIds.length,
      downloads.activeCount,
      downloads.waitingForWifi,
      displaySettings.moviesCoverOrientation,
      simklWatchingShelfStamp,
      tmdbDiscoveryRevision,
      parentalLock?.lockFilterStamp ?? 'none',
      // Only bumps on disk restore — idle [noteHomeShelfPaint] must not
      // rematerialize Accueil (contentStamp would churn every persist).
      _homeShelfSnapshotRevision,
      // Watch live / recent-live row — SQLite pins after last-close seed.
      _livePinsRevision,
    );
  }

  /// Frozen Accueil shelves from last close (null when empty / not loaded).
  ///
  /// After sources are restored, tiles from deleted or disabled catalogs are
  /// omitted so Home does not resurrect them when live shelves are empty.
  HomeShelfSnapshot? get homeShelfSnapshot {
    final snap = _homeShelfSnapshot;
    if (snap == null || !snap.hasContent) return null;
    return _visibleHomeShelfSnapshot(snap);
  }

  /// Matched / shelled Simkl Plan-to-Watch for My List.
  List<MediaItem> simklPlanToWatch = [];

  /// Matched / shelled Trakt watchlist for My List.
  List<MediaItem> traktWatchlist = [];

  /// Matched / shelled Plex watchlist for My List.
  List<MediaItem> plexWatchlist = [];

  /// Matched / shelled Letterboxd watchlist (movies) from user export.
  List<MediaItem> letterboxdWatchlist = [];

  /// Matched / shelled Serializd Currently Watching for My List.
  List<MediaItem> serializdWatching = [];

  /// Matched / shelled Serializd watchlist for My List.
  List<MediaItem> serializdWatchlist = [];

  /// Matched / shelled BetaSeries Watching for My List.
  List<MediaItem> betaseriesWatching = [];

  /// Matched / shelled BetaSeries Plan-to-Watch for My List.
  List<MediaItem> betaseriesPlan = [];

  /// Agnostic tracker statuses (Letterboxd completed/watchlist, Serializd…).
  List<TrackerStatusEntry> trackerStatuses = [];
  DateTime? simklLastSyncAt;
  DateTime? traktLastSyncAt;
  DateTime? letterboxdLastImportAt;
  DateTime? serializdLastSyncAt;
  DateTime? betaseriesLastSyncAt;
  SimklActivities? _simklActivities;
  TraktLastActivities? _traktActivities;
  String? _simklSyncDateFrom;
  bool _simklSyncing = false;
  bool _traktSyncing = false;
  bool _plexWatchlistSyncing = false;
  bool _letterboxdImporting = false;
  bool _serializdSyncing = false;
  bool _betaseriesSyncing = false;
  TrackerSyncPhase? _trackerSyncPhase;
  SimklMatchIndex? _trackerMatchIndex;
  int? _trackerMatchIndexStamp;
  DateTime? _simklLastSyncAttempt;
  DateTime? _traktLastSyncAttempt;
  DateTime? _plexWatchlistLastSyncAttempt;
  DateTime? _serializdLastSyncAttempt;
  DateTime? _betaseriesLastSyncAttempt;

  /// False while Android has the app paused/hidden — skip catalog hammering.
  bool _appForeground = true;

  /// Desktop window focused (blur/focus). Independent of [AppLifecycleState]:
  /// minimize / alt-tab blur defers opportunistic VOD index work here. Windows
  /// long-blur playback pause lives in [PlaybackProvider.onDesktopShellBlurred]
  /// (texture / embedder safety); true AFK still uses [setAppForeground].
  bool _desktopShellActive = true;

  /// Manual Synchroniser session — ignore spurious Win32 blur and keep HWND
  /// focus until sync + live/VOD follow-ons for these sources go idle.
  final Set<String> _manualSyncFocusHold = {};

  /// VOD prefetch scheduled by manual Sync but not yet in [_vodPrefetching]
  /// (2s delay gap). Keep focus-hold across that gap.
  final Set<String> _manualSyncExpectVod = {};

  /// Manual Sync deferred guide reload until after VOD fingerprint/prefetch
  /// (reason string). Avoids `xtream-vod-stream>epg-ingest` overlap.
  final Map<String, String> _pendingEpgAfterVod = {};

  /// True while Synchroniser (and its follow-on live/VOD work) needs the
  /// window to keep OS focus. See [setDesktopShellActive] / app blur hook.
  bool get shouldHoldDesktopFocusForSync => _manualSyncFocusHold.isNotEmpty;

  void _beginManualSyncFocusHold(String sourceId) {
    if (_manualSyncFocusHold.add(sourceId)) {
      JavpLog.i('desktop', 'manual sync focus-hold begin source=$sourceId');
    }
  }

  void _expectManualSyncVod(String sourceId) {
    _manualSyncExpectVod.add(sourceId);
    _beginManualSyncFocusHold(sourceId);
  }

  void _clearManualSyncExpectVod(String sourceId) {
    _manualSyncExpectVod.remove(sourceId);
    // If prefetch never ran or aborted before its finally, still run guide.
    _flushPendingEpgAfterVod(sourceId);
  }

  void _scheduleEndManualSyncFocusHold(String sourceId) {
    unawaited(() async {
      for (var i = 0; i < 1200; i++) {
        if (_disposed) return;
        if (!_syncingSourceIds.contains(sourceId) &&
            !_liveCategoryPrefetching.contains(sourceId) &&
            !_vodPrefetching.contains(sourceId) &&
            !_manualSyncExpectVod.contains(sourceId)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      _clearManualSyncExpectVod(sourceId);
      if (_manualSyncFocusHold.remove(sourceId)) {
        JavpLog.i('desktop', 'manual sync focus-hold end source=$sourceId');
        // Prefer idle coalesce for in-process paths that still defer indexes.
        // If focus already landed before pending flipped, resume now.
        if (_postHydrateIndexesPending) {
          JavpLog.i(
            'vod',
            'manual-sync end -> resume deferred indexes',
          );
          _resumePostHydrateIndexesIfNeeded();
        }
      }
    }());
  }

  /// Bumped when the shell blurs / backgrounds so in-flight idle sync can abort
  /// before a heavy apply lands on the UI isolate (Windows restore otherwise
  /// ghosts as "Not Responding" and clicks do nothing).
  int _idleWorkGeneration = 0;

  /// True for a short beat after focus / foreground so restore frames and
  /// pointer events win over catalog apply / Live TV rematerialize.
  bool _shellThawing = false;
  Timer? _shellThawTimer;
  bool _thawNotifyPending = false;

  /// Opportunistic Versions index was skipped while AFK / blurred.
  bool _vodVariantIndexDeferred = false;

  /// When the desktop shell last blurred (alt-tab / unfocus).
  DateTime? _desktopShellBlurredAt;

  /// Delayed resume of a deferred Versions index after long blur / AFK.
  Timer? _vodVariantIndexResumeTimer;

  /// Quiet reschedule of coalesced idle jobs after focus / foreground.
  Timer? _idleJobsQuietResumeTimer;

  /// Soft re-attempt for deep-sync when deferred (no tight re-enqueue loop).
  Timer? _deepSyncSoftDeferTimer;

  /// After progressive VOD commits / source sync, retry unmatched tracker shells
  /// once SQLite FTS rows (and remote catalogs) can answer title lookups.
  Timer? _trackerRelinkAfterVodTimer;

  /// Accueil reveal 0→4 finished + short settle — gates Drive / soft sync /
  /// for-you / simkl-relink so they don't pile onto the post-reveal hitch.
  bool _homeRevealSettled = false;
  Completer<void>? _homeRevealSettledCompleter;
  bool _postRevealBootstrapArmed = false;
  Timer? _homeRevealSettleTimeoutTimer;

  /// Source ids from add/import waiting for Accueil settle before soft sync.
  /// Avoids pairing / Welcome → Home racing a full playlist sync on the UI isolate.
  final Set<String> _deferredAddSyncIds = {};
  Future<void>? _deferredAddSyncFlush;

  /// Fallback if Home never reports settle (onboarding / empty).
  static const _homeRevealSettleTimeout = Duration(seconds: 14);

  /// Extra beat after Home marks reveal done before enqueueing heavy work.
  static const _postRevealWorkGrace = Duration(milliseconds: 700);

  /// True after Accueil staggered shelves finished (or timeout).
  bool get isHomeRevealSettled => _homeRevealSettled;

  /// Source ids waiting for Accueil settle before soft sync (add/import).
  @visibleForTesting
  Set<String> get debugDeferredAddSyncIds =>
      Set<String>.unmodifiable(_deferredAddSyncIds);

  /// Soft-sync after add/import — wait for Accueil settle when Home is still
  /// revealing (TV pairing / first onboard) so shelves stay interactive.
  void _kickSoftSyncAfterHomeReady(String sourceId, {String reason = 'add'}) {
    if (_disposed) return;
    if (isHomeRevealSettled) {
      unawaited(syncSource(sourceId, blockUi: false, reason: reason));
      return;
    }
    _deferredAddSyncIds.add(sourceId);
    JavpLog.i(
      'source',
      'defer soft-sync until home reveal id=$sourceId '
          'pending=${_deferredAddSyncIds.length} reason=$reason',
    );
    _deferredAddSyncFlush ??= _flushDeferredAddSoftSync();
  }

  Future<void> _flushDeferredAddSoftSync() async {
    try {
      await waitUntilHomeRevealSettled();
      if (_disposed) return;
      final ids = List<String>.from(_deferredAddSyncIds);
      _deferredAddSyncIds.clear();
      JavpLog.i('source', 'flush deferred soft-sync count=${ids.length}');
      for (final id in ids) {
        if (_disposed) return;
        unawaited(syncSource(id, blockUi: false, reason: 'add-deferred'));
      }
    } finally {
      _deferredAddSyncFlush = null;
      if (_deferredAddSyncIds.isNotEmpty && !_disposed) {
        final leftover = List<String>.from(_deferredAddSyncIds);
        _deferredAddSyncIds.clear();
        for (final id in leftover) {
          _kickSoftSyncAfterHomeReady(id, reason: 'add-deferred');
        }
      }
    }
  }

  void _armPostRevealBootstrapWork() {
    _postRevealBootstrapArmed = true;
    if (_homeRevealSettled) {
      _postRevealBootstrapArmed = false;
      unawaited(_runPostRevealBootstrapWork(reason: 'already-settled'));
      return;
    }
    JavpLog.i('bootstrap', 'post-reveal work armed (waiting Accueil settle)');
    _homeRevealSettleTimeoutTimer?.cancel();
    _homeRevealSettleTimeoutTimer = Timer(_homeRevealSettleTimeout, () {
      _homeRevealSettleTimeoutTimer = null;
      markHomeRevealSettled(reason: 'timeout');
    });
  }

  Future<void> _runPostRevealBootstrapWork({required String reason}) async {
    // Let the last reveal paint + poster decode breathe before bg stampede.
    await Future<void>.delayed(_postRevealWorkGrace);
    if (_disposed) return;
    JavpLog.i('bootstrap', 'post-reveal work start reason=$reason');

    if (simkl.isAuthenticated) {
      unawaited(syncSimklActivity());
      unawaited(_relinkSimklWatching(priority: BackgroundPriority.low));
      unawaited(_relinkSimklPlanToWatch(priority: BackgroundPriority.low));
    } else {
      unawaited(_relinkSimklWatching(priority: BackgroundPriority.low));
      unawaited(_relinkSimklPlanToWatch(priority: BackgroundPriority.low));
    }
    if (trakt.isAuthenticated) {
      unawaited(syncTraktWatchlist());
      unawaited(_relinkTraktWatchlist());
    } else {
      unawaited(_relinkTraktWatchlist());
    }
    unawaited(syncPlexWatchlist());
    unawaited(_relinkPlexWatchlist());
    unawaited(_relinkLetterboxdWatchlist());
    if (serializd.isAuthenticated) {
      unawaited(syncSerializdActivity());
      unawaited(_relinkSerializdShelves());
    } else {
      unawaited(_relinkSerializdShelves());
    }
    if (betaseries.isAuthenticated) {
      unawaited(syncBetaseriesLists());
      unawaited(_relinkBetaseriesShelves());
    } else {
      unawaited(_relinkBetaseriesShelves());
    }

    _deepSyncedSourceIds = (await _store.loadDeepSyncedSourceIds()).toSet();
    unawaited(_deepSyncPendingSources());
    unawaited(_scheduleIdleSourceSync(reason: 'bootstrap'));
    // Reveal may have skipped remote for-you while unsettled — kick once now.
    unawaited(_ensureRemoteRecommendations());
  }

  DateTime? _vodVariantIndexLastBuiltAt;

  /// Blur/AFK longer than this → don't start the isolate index on the first
  /// focus frame (journals: 76–113s builds hitch Home).
  static const _vodVariantIndexLongBlur = Duration(seconds: 20);

  /// Extra delay after a long blur before opportunistic index resume.
  static const _vodVariantIndexResumeDelay = Duration(seconds: 20);

  /// Short alt-tab still waits a beat so focus paint isn't contested.
  static const _vodVariantIndexShortResumeDelay = Duration(seconds: 5);

  /// Skip opportunistic resume when a current-enough index was just built.
  static const _vodVariantIndexResumeTtl = Duration(minutes: 8);

  /// After focus/foreground, wait this long before re-queuing idle warm/sync.
  static const _idleJobsQuietResumeDelay = Duration(seconds: 18);

  /// Keep background apply off the UI isolate until restore has painted.
  static const _shellThawDuration = Duration(milliseconds: 400);

  /// Test helper: [setDesktopShellActive] / [setAppForeground] thaw window.
  @visibleForTesting
  static const debugShellThawDuration = _shellThawDuration;

  /// Distinct low idle jobs that stack on AFK thaw / alt-tab (same-id already
  /// deduped by the queue — these are different ids).
  static const _coalescableIdleJobIds = {
    'idle-vod-warm',
    'idle-source-sync',
    'deep-sync-pending',
    'for-you-remote',
    'tmdb-discovery',
    // Post-hydrate tracker relinks (low) — cancel on blur so Accueil settle
    // is not contested by a pending ~200k match-index rebuild.
    'simkl-relink',
    'simkl-plan-relink',
    'trakt-watchlist-relink',
    'plex-watchlist-relink',
    'letterboxd-watchlist-relink',
  };
  TmdbCredentials tmdb = const TmdbCredentials();
  TraktCredentials trakt = const TraktCredentials();
  SerializdCredentials serializd = const SerializdCredentials();
  BetaseriesCredentials betaseries = const BetaseriesCredentials();
  MetadataSettings metadataSettings = MetadataSettings.defaults;
  DisplaySettings displaySettings = DisplaySettings.defaults;
  Map<String, MediaDetails> detailsCache = {};
  List<LibraryCollection> collections = [];
  List<LibraryPlaylist> playlists = [];
  Map<String, MediaSegmentBundle> segmentCache = {};
  SkipSegmentSettings skipSettings = SkipSegmentSettings.defaults;
  TrackLanguageSettings trackLanguageSettings = TrackLanguageSettings.defaults;
  MediaServerStreamQuality mediaServerStreamQuality =
      MediaServerStreamQuality.original;
  DownloadSettings downloadSettings = DownloadSettings.defaults;

  /// Force libmpv software decode (`hwdec=no`) — fixes black video on some
  /// devices / emulators; heavier on CPU.
  bool softwareVideoDecoder = false;

  /// After Chromecast direct/proxy fail, ask Jellyfin/Emby/Plex for H.264.
  bool castServerTranscodeFallback = false;
  Map<String, List<String>> knownEpisodeIdsBySeries = {};
  final Map<String, MediaServerSession> _serverSessions = {};
  final Set<String> _downloadAheadTriggered = {};
  final Set<String> _removeAfterWatchTriggered = {};

  /// Grace delay before deleting an offline copy after watch/advance.
  static const removeAfterWatchGrace = Duration(minutes: 2);
  final Map<String, Timer> _scheduledRemoveAfterWatch = {};
  final Map<String, MediaItem> _scheduledRemoveItems = {};
  final Map<String, MediaItem> _pendingRemoveWhenOnline = {};
  final List<PendingSimklScrobble> _pendingSimklScrobbles = [];
  bool _flushingSimklScrobbles = false;

  /// Dedup keys for Simkl `/sync/history` (watching-once per show, completed per title).
  final Set<String> _simklScrobbleSentKeys = {};
  final List<PendingSerializdScrobble> _pendingSerializdScrobbles = [];
  bool _flushingSerializdScrobbles = false;
  String? _lastSerializdScrobbleKey;
  DateTime? _lastSerializdScrobbleAt;
  static const _serializdScrobbleMinInterval = Duration(seconds: 45);

  /// In-flight `GET /items/{id}` for series shells — dedupes double open fetches.
  final Map<String, Future<MediaDetails?>> _customCatalogShellInflight = {};

  /// Shell keys that already completed `/items/{id}` (+ optional `/episodes`).
  final Set<String> _customCatalogShellHydrated = {};

  /// Resolved episode rows from `GET /items/{episodeId}` (key: sourceId|episodeId).
  final Map<String, SeriesEpisode> _customCatalogEpisodeResolveCache = {};

  /// In-flight per-episode resolves so Versions/Play/scroll don't stampede catalog.
  final Map<String, Future<SeriesEpisode?>> _customCatalogEpisodeInflight = {};

  /// Series that had at least one successful magnet fill this session
  /// (key: sourceId|series|{seriesId}) — raises prefetch concurrency after cold.
  final Set<String> _customCatalogSeriesBridgeWarm = {};

  /// Sources that already logged a missing `/search` (404) this session.
  final Set<String> _catalogSearch404Warned = {};

  /// In-flight bulk `episodes?resolve=1` per series+season.
  final Map<String, Future<int>> _customCatalogBulkResolveInflight = {};

  /// TMDB `/tv/{id}/season/{n}` stills (key: `tmdbId|season`).
  final Map<String, List<TmdbSeasonEpisode>> _tmdbSeasonStillsCache = {};
  final Map<String, Future<List<TmdbSeasonEpisode>>> _tmdbSeasonStillsInflight =
      {};

  /// SIMKL `/tv|anime/episodes/{id}` (key: `simklId|anime`).
  final Map<String, List<SeasonEpisodeArt>> _simklEpisodeArtCache = {};
  final Map<String, Future<List<SeasonEpisodeArt>>> _simklEpisodeArtInflight =
      {};

  /// Trakt `/shows/{id}/seasons/{n}/episodes` (key: `traktId|season`).
  final Map<String, List<SeasonEpisodeArt>> _traktSeasonArtCache = {};
  final Map<String, Future<List<SeasonEpisodeArt>>> _traktSeasonArtInflight =
      {};

  /// Bumps when an episode resolve merges into the series shell cache.
  int customCatalogResolveRevision = 0;

  /// How long a series shell (episode list) stays fresh before a soft re-fetch.
  /// Simulcasts add episodes over time; we paint cache first, then revalidate.
  static const customCatalogShellTtl = Duration(minutes: 30);

  /// Delay after stub `/episodes` before background fill (bridge pool warm).
  static const customCatalogColdPrefetchDelay = Duration(milliseconds: 1000);

  /// Prefetch workers once a series is bridge-warm (never stampede cold catalog).
  static const customCatalogWarmPrefetchConcurrency = 3;

  DownloadManager get downloads => _downloads;
  CastService get cast => _cast;
  TorrentStreamService get torrents => _torrent;

  /// Downloaded episodes belonging to [series].
  List<MediaItem> downloadedEpisodesForSeries(MediaItem series) {
    final targetKey = seriesKeyFor(series);
    final out = <MediaItem>[];
    for (final item in offlineLibraryItems) {
      if (!item.isEpisode) continue;
      final shell = seriesShellForEpisode(item);
      if (shell == null || seriesKeyFor(shell) != targetKey) continue;
      out.add(item);
    }
    return out;
  }

  // These three are read from build methods and `context.select` callbacks, so
  // they run on every notification. Rebuilding a merged list (or re-scanning
  // five lists) each time showed up directly as dropped frames on large
  // libraries; all three are memoized against the identity of their inputs,
  // which the provider already swaps wholesale on every mutation.
  List<MediaItem>? _allContentCache;
  List<MediaItem>? _allContentLocalRef;
  List<MediaItem>? _allContentCatalogRef;
  int _allContentDownloadCount = -1;

  /// Do not mutate — callers share one cached list.
  List<MediaItem> get allContent {
    final downloaded = _downloads.completedItems;
    if (_allContentCache == null ||
        !identical(_allContentLocalRef, localMedia) ||
        !identical(_allContentCatalogRef, catalog) ||
        _allContentDownloadCount != downloaded.length) {
      _allContentCache = [...localMedia, ...catalog, ...downloaded];
      _allContentLocalRef = localMedia;
      _allContentCatalogRef = catalog;
      _allContentDownloadCount = downloaded.length;
    }
    return _allContentCache!;
  }

  List<String>? _allGenresCache;
  List<MediaItem>? _allGenresContentRef;
  Map<String, MediaDetails>? _allGenresDetailsRef;

  List<String> get allGenres {
    final content = allContent;
    if (_allGenresCache != null &&
        identical(_allGenresContentRef, content) &&
        identical(_allGenresDetailsRef, detailsCache)) {
      return _allGenresCache!;
    }
    final set = <String>{};
    for (final item in content) {
      set.addAll(item.genres);
    }
    for (final details in detailsCache.values) {
      set.addAll(details.genres);
    }
    _allGenresCache = set.toList()..sort();
    _allGenresContentRef = content;
    _allGenresDetailsRef = detailsCache;
    return _allGenresCache!;
  }

  Map<String, MediaItem>? _itemIndex;
  List<MediaItem>? _itemIndexCatalogRef;
  List<MediaItem>? _itemIndexLocalRef;
  List<MediaItem>? _itemIndexHistoryRef;
  List<MediaItem>? _itemIndexWatchlistRef;
  List<MediaItem>? _itemIndexVodCategoryRef;

  MediaItem? itemById(String id) {
    final vodCategory = vodCategoryItems;
    if (_itemIndex == null ||
        !identical(_itemIndexCatalogRef, catalog) ||
        !identical(_itemIndexLocalRef, localMedia) ||
        !identical(_itemIndexHistoryRef, history) ||
        !identical(_itemIndexWatchlistRef, watchlist) ||
        !identical(_itemIndexVodCategoryRef, vodCategory)) {
      // Later lists must not shadow earlier ones — insert in reverse priority.
      final index = <String, MediaItem>{};
      for (final list in [
        vodCategory,
        watchlist,
        history,
        localMedia,
        catalog,
      ]) {
        for (final item in list) {
          index[item.id] = item;
        }
      }
      _itemIndex = index;
      _itemIndexCatalogRef = catalog;
      _itemIndexLocalRef = localMedia;
      _itemIndexHistoryRef = history;
      _itemIndexWatchlistRef = watchlist;
      _itemIndexVodCategoryRef = vodCategory;
    }
    final hit = _itemIndex![id];
    if (hit != null) return hit;
    final cached = _vodStreamCache[id];
    if (cached != null) return cached;
    final overlayFamily = _vodFamilyOverlay[id];
    if (overlayFamily != null) {
      for (final item in overlayFamily) {
        if (item.id == id) return item;
      }
    }
    for (final item in _downloads.completedItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Async id lookup — hits SQLite when the VOD DB is active and RAM missed.
  Future<MediaItem?> itemByIdAsync(String id) async {
    final sync = itemById(id);
    if (sync != null) return sync;
    if (!_useVodDb) return null;
    return _vodDb.itemById(id);
  }

  List<String>? _parentalExcludedGroupNames() {
    final lock = parentalLock;
    if (lock == null || !lock.isContentLocked) return null;
    final names = lock.hiddenLiveGroupNames;
    return names.isEmpty ? null : names;
  }

  bool _parentalExcludeAdult() {
    final lock = parentalLock;
    return lock != null && lock.isContentLocked && lock.hideSourceAdult;
  }

  void invalidateParentalLiveCaches() {
    _liveGroupCountsCache = null;
    _liveGroupNamesCache = null;
    _cachedOnNow = null;
    _liveByGroup = null;
    _cachedLiveChannels = null;
    _liveChannelsCatalogRef = null;
    _liveChannelsLockStamp = null;
    _liveById = null;
    _liveByIdCatalogRef = null;
    _liveFamilyIndex = null;
    _liveFamilyKeyById = null;
    _liveFamilyCatchupById.clear();
    _invalidateHomeShelfCaches();
  }

  List<({String name, int count})>? _liveGroupCountsCache;
  String? _liveGroupCountsSourceId;
  int _liveGroupCountsRev = -1;
  List<String>? _liveGroupNamesCache;
  String? _liveGroupNamesSourceId;
  int _liveGroupNamesRev = -1;

  /// Resolve a live DB source filter: single equality id and/or allow-list.
  ///
  /// [sourceIds] (multi-select) wins over [sourceId] when non-empty.
  /// Empty / null request → all enabled sources ([_liveAllowedSourceIds]).
  ({String? sourceId, List<String>? allowedSourceIds, bool empty})
  _resolveLiveSourceFilter({String? sourceId, Iterable<String>? sourceIds}) {
    final requested = <String>{
      if (sourceIds != null)
        for (final id in sourceIds)
          if (id.trim().isNotEmpty) id.trim(),
      if ((sourceIds == null || sourceIds.isEmpty) &&
          sourceId != null &&
          sourceId.trim().isNotEmpty)
        sourceId.trim(),
    };
    if (requested.isEmpty) {
      final allowed = _liveAllowedSourceIds;
      return (
        sourceId: null,
        allowedSourceIds: allowed,
        empty: allowed.isEmpty,
      );
    }
    final enabled = <String>{
      for (final s in sources)
        if (s.enabled) s.id,
    };
    final picked = <String>[
      for (final id in requested)
        if (enabled.contains(id) && isSourceContentVisible(id)) id,
    ];
    if (picked.isEmpty) {
      return (sourceId: null, allowedSourceIds: const <String>[], empty: true);
    }
    if (picked.length == 1) {
      return (
        sourceId: picked.single,
        allowedSourceIds: _liveAllowedSourceIds,
        empty: false,
      );
    }
    final allow = _liveAllowedSourceIds.toSet();
    final intersected = <String>[
      for (final id in picked)
        if (allow.contains(id)) id,
    ];
    if (intersected.isEmpty) {
      return (sourceId: null, allowedSourceIds: const <String>[], empty: true);
    }
    return (sourceId: null, allowedSourceIds: intersected, empty: false);
  }

  Future<List<String>> liveGroupNames({
    String? sourceId,
    Iterable<String>? sourceIds,
  }) async {
    if (!_useLiveDb) {
      final rows = await liveGroupCounts(
        sourceId: sourceId,
        sourceIds: sourceIds,
      );
      return [for (final row in rows) row.name];
    }
    final filter = _resolveLiveSourceFilter(
      sourceId: sourceId,
      sourceIds: sourceIds,
    );
    if (filter.empty) return const [];
    _syncParentalLiveCategoryNames();
    final lockStamp = parentalLock?.lockFilterStamp ?? 'none';
    final key =
        '${filter.sourceId}|${filter.allowedSourceIds?.join(',')}|$_sourcesEnabledStamp|$lockStamp';
    if (_liveGroupNamesCache != null &&
        _liveGroupNamesSourceId == key &&
        _liveGroupNamesRev == liveDbRevision) {
      return _liveGroupNamesCache!;
    }
    final names = await _liveDb.listGroupNames(
      sourceId: filter.sourceId,
      allowedSourceIds: filter.allowedSourceIds,
      excludeAdult: _parentalExcludeAdult(),
    );
    final filtered = parentalLock == null || !parentalLock!.isContentLocked
        ? names
        : [
            for (final n in names)
              if (!parentalLock!.isGroupNameHidden(n)) n,
          ];
    _liveGroupNamesCache = filtered;
    _liveGroupNamesSourceId = key;
    _liveGroupNamesRev = liveDbRevision;
    return filtered;
  }

  /// Live category names with channel counts (collapsed listings).
  Future<List<({String name, int count})>> liveGroupCounts({
    String? sourceId,
    Iterable<String>? sourceIds,
  }) async {
    final filter = _resolveLiveSourceFilter(
      sourceId: sourceId,
      sourceIds: sourceIds,
    );
    if (!_useLiveDb) {
      if (filter.empty) return const [];
      final want = filter.sourceId != null
          ? {filter.sourceId!}
          : (filter.allowedSourceIds?.toSet());
      final counts = <String, int>{};
      for (final channel in liveChannels) {
        if (want != null &&
            want.isNotEmpty &&
            (channel.sourceId == null || !want.contains(channel.sourceId))) {
          continue;
        }
        if (parentalLock?.isLiveChannelHidden(channel) == true) continue;
        final group = channel.group?.trim();
        if (group == null || group.isEmpty) continue;
        counts[group] = (counts[group] ?? 0) + 1;
      }
      final names = counts.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return [for (final name in names) (name: name, count: counts[name]!)];
    }
    if (filter.empty) return const [];
    _syncParentalLiveCategoryNames();
    final lockStamp = parentalLock?.lockFilterStamp ?? 'none';
    final key =
        '${filter.sourceId}|${filter.allowedSourceIds?.join(',')}|$_sourcesEnabledStamp|$lockStamp';
    if (_liveGroupCountsCache != null &&
        _liveGroupCountsSourceId == key &&
        _liveGroupCountsRev == liveDbRevision) {
      return _liveGroupCountsCache!;
    }
    final rows = await _liveDb.listGroupCounts(
      sourceId: filter.sourceId,
      allowedSourceIds: filter.allowedSourceIds,
      excludeAdult: _parentalExcludeAdult(),
    );
    final filtered = parentalLock == null || !parentalLock!.isContentLocked
        ? rows
        : [
            for (final row in rows)
              if (!parentalLock!.isGroupNameHidden(row.name)) row,
          ];
    _liveGroupCountsCache = filtered;
    _liveGroupCountsSourceId = key;
    _liveGroupCountsRev = liveDbRevision;
    return filtered;
  }

  void _syncParentalLiveCategoryNames() {
    final lock = parentalLock;
    if (lock == null) return;
    lock.syncCategoryNames([
      for (final c in categories)
        if (c.kind == IptvCategoryKind.live) c,
    ]);
  }

  static const _forYouLive = ForYouLiveRecommender();

  /// Favorites / recents / on-now / affinity / locale shelves for TV For you.
  Future<List<ForYouShelf>> buildForYouLiveShelves({
    String? sourceId,
    Iterable<String>? sourceIds,
    Locale? locale,
    int perShelf = 12,
    bool includeLocaleSamples = true,
  }) async {
    final selected = <String>{
      if (sourceIds != null)
        for (final id in sourceIds)
          if (id.isNotEmpty) id,
      if ((sourceIds == null || !sourceIds.any((e) => e.isNotEmpty)) &&
          sourceId != null &&
          sourceId.isNotEmpty)
        sourceId,
    };
    bool matches(MediaItem c) =>
        selected.isEmpty ||
        (c.sourceId != null && selected.contains(c.sourceId));

    List<MediaItem> titled(Iterable<MediaItem> channels) => [
      for (final c in channels)
        if (matches(c)) c.copyWith(title: officialLiveTitle(c)),
    ];

    final favorites = titled(favoriteChannels);
    final recents = titled(recentChannels);
    final loc = locale ?? const Locale('en');

    final localeSamples = <MediaItem>[];
    final categorySamples = <MediaItem>[];
    final seen = <String>{
      for (final c in favorites) c.id,
      for (final c in recents) c.id,
    };

    // Channels from favorited categories (loaded with the locale enrich pass).
    if (includeLocaleSamples) {
      for (final catId in favoriteCategoryIds.take(6)) {
        if (categorySamples.length >= perShelf) break;
        final page = await pageLiveChannels(
          groupName: catId,
          sourceId: sourceId,
          sourceIds: sourceIds,
          limit: 8,
        );
        for (final channel in page) {
          if (!seen.add(channel.id)) continue;
          categorySamples.add(
            channel.copyWith(title: officialLiveTitle(channel)),
          );
          if (categorySamples.length >= perShelf) break;
        }
      }
    }

    if (includeLocaleSamples) {
      // Locale shelf is discovery-heavy — pull more groups/channels than
      // the default per-shelf row used for favorites / jump-back.
      final localeCap = perShelf * 2;
      final allGroups = await liveGroupNames(
        sourceId: sourceId,
        sourceIds: sourceIds,
      );
      var groups = IptvLocaleHints.rankGroups(allGroups, loc);
      // Direct's For you used to stay empty when group names scored 0 for
      // the device locale (e.g. "Entertainment" on a French Fire TV).
      if (groups.isEmpty) groups = [for (final name in allGroups) name];
      for (final group in groups.take(8)) {
        if (localeSamples.length >= localeCap) break;
        final page = await pageLiveChannels(
          groupName: group,
          sourceId: sourceId,
          sourceIds: sourceIds,
          limit: 16,
        );
        for (final channel in page) {
          if (!seen.add(channel.id)) continue;
          localeSamples.add(
            channel.copyWith(title: officialLiveTitle(channel)),
          );
          if (localeSamples.length >= localeCap) break;
        }
      }
    }

    final shelves = _forYouLive.build(
      favorites: favorites,
      recents: recents,
      localeSamples: localeSamples,
      locale: loc,
      nowPlaying: nowPlayingFor,
      perShelf: perShelf,
    );

    if (categorySamples.isEmpty) return shelves;

    final favCatShelf = ForYouShelf(
      id: 'fav_categories',
      title: 'From favorite categories',
      subtitle: favoriteCategoryIds.take(3).join(' · '),
      channels: categorySamples,
    );
    var insertAt = 0;
    for (var i = 0; i < shelves.length; i++) {
      final id = shelves[i].id;
      if (id == 'jump_back' || id == 'favorites') insertAt = i + 1;
    }
    return [
      ...shelves.sublist(0, insertAt),
      favCatShelf,
      ...shelves.sublist(insertAt),
    ];
  }

  /// Flat For you list (favorites + recents + locale samples).
  Future<List<MediaItem>> buildForYouLive({
    String? sourceId,
    Locale? locale,
    int limit = 80,
  }) async {
    final shelves = await buildForYouLiveShelves(
      sourceId: sourceId,
      locale: locale,
      perShelf: 12,
    );
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final shelf in shelves) {
      for (final channel in shelf.channels) {
        if (out.length >= limit) return out;
        if (!seen.add(channel.id)) continue;
        out.add(channel);
      }
    }
    return out;
  }

  /// Paged live channels from locale-ranked groups (For you → In your language).
  Future<List<MediaItem>> pageLocaleLiveChannels({
    required Locale locale,
    String? sourceId,
    Iterable<String>? sourceIds,
    String? query,
    int offset = 0,
    int limit = 80,
  }) async {
    if (limit <= 0) return const [];
    final groups = IptvLocaleHints.rankGroups(
      await liveGroupNames(sourceId: sourceId, sourceIds: sourceIds),
      locale,
    );
    if (groups.isEmpty) return const [];

    final out = <MediaItem>[];
    final seen = <String>{};
    var skipped = 0;
    const chunk = 80;

    for (final group in groups) {
      var groupOffset = 0;
      while (true) {
        final page = await pageLiveChannels(
          groupName: group,
          sourceId: sourceId,
          sourceIds: sourceIds,
          query: query,
          offset: groupOffset,
          limit: chunk,
        );
        if (page.isEmpty) break;
        groupOffset += page.length;
        for (final channel in page) {
          if (!seen.add(channel.id)) continue;
          if (skipped < offset) {
            skipped++;
            continue;
          }
          out.add(channel);
          if (out.length >= limit) return out;
        }
        if (page.length < chunk) break;
      }
    }
    return out;
  }

  Future<void> _refreshVodDbCountCache() async {
    if (!_useVodDb) {
      _vodDbCountCache = _vodStreamCache.length;
      _vodDbMovieGroupsBySource = {};
      _vodDbSeriesGroupsBySource = {};
      return;
    }
    try {
      _vodDbCountCache = await _vodDb.countItems();
    } catch (_) {
      _vodDbCountCache = _vodStreamCache.length;
    }
  }

  /// Catalog source chips: group names per source without a RAM working set.
  Future<void> _refreshVodDbGroupCache() async {
    if (!_useVodDb) {
      _vodDbMovieGroupsBySource = {};
      _vodDbSeriesGroupsBySource = {};
      _vodDbGroupCacheRevision++;
      return;
    }
    try {
      await _fillEmptyVodGroupsFromSourceNames();
      final excludeAdult = _parentalExcludeAdult();
      _vodDbMovieGroupsBySource = await _vodDb.listGroupsBySource(
        series: false,
        excludeAdult: excludeAdult,
      );
      _vodDbSeriesGroupsBySource = await _vodDb.listGroupsBySource(
        series: true,
        excludeAdult: excludeAdult,
      );
      _vodDbGroupCacheRevision++;
    } catch (_) {
      // Keep the last warm map; next persist / enable retries.
    }
  }

  /// Custom / M3U / media-server titles with no `group` inherit the source name
  /// so Catalog shelves exist. Xtream/Stalker keep provider category lists.
  Future<void> _fillEmptyVodGroupsFromSourceNames() async {
    if (!_useVodDb) return;
    final names = <String, String>{};
    for (final source in sources) {
      if (!source.enabled || source.type.isEpgOnly) continue;
      if (source.type == IptvSourceType.xtream ||
          source.type == IptvSourceType.stalker) {
        continue;
      }
      final name = source.name.trim();
      if (name.isEmpty) continue;
      names[source.id] = name;
    }
    if (names.isEmpty) return;
    await _vodDb.fillEmptyGroups(namesBySourceId: names);
  }

  /// Rebuild VOD [sort_title] after normalize / year hay changes.
  Future<void> _maybeReindexVodSortTitles() async {
    if (!_useVodDb) return;
    try {
      if (!await _vodDb.needsSortTitleReindex) return;
      await _vodDb.reindexSortTitles();
      vodDbRevision++;
    } catch (_) {
      // Keep serving the previous sort_title; next source sync will rewrite.
    }
  }

  List<String>? _vodAllowedSourceIds({
    String? sourceKey,
    Set<String>? sourceKeys,
  }) {
    final filter =
        sourceKeys ??
        (sourceKey == null || sourceKey.isEmpty ? null : <String>{sourceKey});
    if (filter != null) {
      return filter.toList(growable: false);
    }
    // Respect per-source VOD visibility + enabled flags.
    final ids = <String>[];
    for (final s in sources) {
      if (_sourceContributesVod(s) && isSourceVodContentVisible(s.id)) {
        ids.add(s.id);
      }
    }
    // null = no SQL filter (every row). After restore that resurrects a
    // just-removed catalog while [deleteSource] is still in flight, and it
    // keeps Movies filled when the only remaining sources are live-only.
    if (ids.isEmpty) return _sourcesRestored ? const <String>[] : null;
    return ids;
  }

  /// SQLite page size for Catalog / shelf queries.
  ///
  /// Shelf samples (~14 posters) stay at `limit × 3`. See-all / unscoped
  /// pages keep the larger over-fetch so collapse still has headroom.
  @visibleForTesting
  static int vodDbWorkingSetFetchLimit({
    required int limit,
    required bool categoryScoped,
    bool forShelfSample = false,
  }) {
    if (limit <= 0) return 0;
    if (forShelfSample) {
      final over = limit * 3;
      return over > 96 ? 96 : over;
    }
    if (categoryScoped) {
      final over = limit * 3;
      return over < 1500 ? 1500 : over;
    }
    return limit * 3;
  }

  Future<void>? _vodGroupIndexRebuild;
  bool _vodGroupIndexRebuildAgain = false;

  /// Manual Sources Sync aborts in-flight group-index / hydrate followups so
  /// they cannot pin the UI isolate (stall=vod-group-index) during Synchroniser.
  bool _vodGroupIndexAbort = false;

  /// Rebuild the group index, collapsing an ingest storm into one extra pass.
  ///
  /// [ensureVodGroupIndexFromDb] is several full-table GROUP BY scans plus two
  /// Home preview pages. A cold catalog applies dozens of ingest chunks, and
  /// running the whole thing per chunk is what makes Catalog crawl while
  /// sources sync. Callers still get a future that completes only once an
  /// index covering their write has been built.
  Future<void> rebuildVodGroupIndexCoalesced() {
    // Never GROUP BY / page vod_catalog while SyncEngine is writing that DB,
    // while manual Synchroniser still owns the shell, or while in-process
    // guide reload owns the UI isolate. Desktop OOP XMLTV does not block.
    final writerBusy =
        DesktopUi.isDesktopOs && SyncScheduler.instance.isCatalogWriterBusy;
    final guideOnUiIsolate =
        !DesktopUi.isDesktopOs ||
        Platform.environment['JAVP_SYNC_INPROCESS'] == '1';
    final guideBusy = guideOnUiIsolate &&
        (_epgReloadPendingSourceIds.isNotEmpty ||
            _epgReloadInFlight != null);
    if (_vodGroupIndexAbort ||
        _manualSyncFocusHold.isNotEmpty ||
        writerBusy ||
        guideBusy) {
      _postHydrateIndexesPending = true;
      return Future<void>.value();
    }
    final inFlight = _vodGroupIndexRebuild;
    if (inFlight != null) {
      _vodGroupIndexRebuildAgain = true;
      return inFlight;
    }
    final future = _runVodGroupIndexRebuild();
    _vodGroupIndexRebuild = future;
    return future;
  }

  Future<void> _runVodGroupIndexRebuild() async {
    try {
      do {
        if (_vodGroupIndexAbort) break;
        _vodGroupIndexRebuildAgain = false;
        await ensureVodGroupIndexFromDb();
      } while (_vodGroupIndexRebuildAgain &&
          !_disposed &&
          !_vodGroupIndexAbort);
    } finally {
      _vodGroupIndexRebuild = null;
      _vodGroupIndexRebuildAgain = false;
    }
  }

  /// Rebuild the in-memory group index from SQLite group counts + lazy pages.
  Future<void> ensureVodGroupIndexFromDb() =>
      UiStallWatchdog.span('vod-group-index', _ensureVodGroupIndexFromDb);

  Future<void> _ensureVodGroupIndexFromDb() async {
    if (!_useVodDb || _vodGroupIndexAbort) return;
    final sw = Stopwatch()..start();
    JavpLog.i('vod', 'group-index from-db start');
    await pumpUi(label: 'vod-group-index-enter');
    if (_vodGroupIndexAbort) {
      JavpLog.i('vod', 'group-index from-db abort after enter');
      return;
    }
    final allowed = _vodAllowedSourceIds();
    final excludeAdult = _parentalExcludeAdult();
    JavpLog.i(
      'vod',
      'group-index counts query begin allowed=${allowed?.length ?? "all"}',
    );
    final counts = await _vodDb.listGroupCounts(
      allowedSourceIds: allowed,
      excludeAdult: excludeAdult,
    );
    if (_vodGroupIndexAbort) {
      JavpLog.i('vod', 'group-index from-db abort after counts');
      return;
    }
    JavpLog.i(
      'vod',
      'group-index counts n=${counts.length} '
          'ms=${sw.elapsedMilliseconds}',
    );
    await pumpUi(label: 'vod-group-index-counts');
    final index = <String, List<MediaItem>>{};
    for (final entry in counts) {
      // Seed empty growable buckets so Catalog rails know the category exists;
      // shelves call [vodShelfSampleAsync] (SQLite page, not a RAM working set).
      // Never reuse a leftover const [] — Search/detail [_replaceVodCacheItem]
      // used to mutate in place and freeze the Windows HWND on enrich.
      final prevBucket = _vodByGroupIndex?[entry.name];
      if (prevBucket == null || prevBucket.isEmpty) {
        index[entry.name] = <MediaItem>[];
      } else {
        index[entry.name] = prevBucket;
      }
    }
    // Preserve already-loaded group lists, but drop titles whose catalog is gone.
    final prev = _vodByGroupIndex;
    if (prev != null) {
      for (final e in prev.entries) {
        if (e.value.isEmpty) continue;
        final kept = [
          for (final m in e.value)
            if (isListedVodSourceVisible(m.sourceId)) m,
        ];
        if (kept.isNotEmpty) index[e.key] = kept;
      }
    }
    _vodByGroupIndex = index;
    _vodByGroupIndexRevision = _vodCacheRevision;
    if (_vodGroupIndexAbort) return;
    await pumpUi(label: 'vod-group-index-cache');
    await UiStallWatchdog.span('vod-group-cache', _refreshVodDbGroupCache);
    if (_vodGroupIndexAbort) return;
    await pumpUi(label: 'vod-group-index-previews');
    await UiStallWatchdog.span(
      'vod-home-previews',
      _refreshVodHomePreviewsFromDb,
    );
    // SQLite path used to skip notify — Catalog/Home stayed on empty shelves
    // even after counts were ready (RAM path notifies via idle).
    _invalidateHomeShelfCaches();
    if (!_disposed) _notifyListenersAfterIdle();
    JavpLog.i(
      'vod',
      'group-index from-db done groups=${index.length} '
          'ms=${sw.elapsedMilliseconds}',
    );
  }

  /// Stop opportunistic VOD index / idle warm that races Synchroniser and
  /// freezes the Windows HWND (focus/click death while frames still tick).
  void _abortOpportunisticWorkForManualSync({String? sourceId}) {
    _vodGroupIndexAbort = true;
    _vodGroupIndexRebuildAgain = false;
    _postHydrateIndexesPending = true;
    final dropped = _bgQueue.cancelPending(
      ids: {
        ..._coalescableIdleJobIds,
        'deep-sync-pending',
      },
    );
    _vodWarmScheduled = false;
    _idleSourceSyncScheduled = false;
    _deepSyncSoftDeferTimer?.cancel();
    _deepSyncSoftDeferTimer = null;
    if (_appForeground && !_desktopShellActive) {
      JavpLog.w(
        'desktop',
        'recover shell on manual sync (fg=true shell=false)',
      );
      setDesktopShellActive(true);
    }
    HwndSyncTrace.of(sourceId ?? '')?.mark(
      'abort-opportunistic',
      'droppedIdle=$dropped shell=$_desktopShellActive fg=$_appForeground',
    );
    JavpLog.i(
      'hwnd',
      'manual-sync abort opportunistic work droppedIdle=$dropped '
          'groupIndexAbort=true shell=$_desktopShellActive '
          'fg=$_appForeground',
    );
  }

  void _clearVodGroupIndexAbort() {
    _vodGroupIndexAbort = false;
  }

  /// Home Films / Series rails — page SQLite, do not walk [_vodStreamCache].
  Future<void> _refreshVodHomePreviewsFromDb() async {
    if (!_useVodDb) return;
    final epoch = _vodHydrateEpoch;
    final enabledStamp = _sourcesEnabledStamp;
    final allowed = _vodAllowedSourceIds();
    final excludeAdult = _parentalExcludeAdult();
    final prefs = _preferredContentLangs;
    try {
      // Per-source rowid quotas — never a single unscoped ORDER BY rowid LIMIT
      // (that let a tiny BYO catalog monopolize Accueil after Xtream replace).
      final movies = await _vodDb.pageHomePreviewItems(
        series: false,
        allowedSourceIds: allowed,
        excludeAdult: excludeAdult,
        limit: 64,
      );
      final shows = await _vodDb.pageHomePreviewItems(
        series: true,
        allowedSourceIds: allowed,
        excludeAdult: excludeAdult,
        limit: 64,
      );
      if (epoch != _vodHydrateEpoch || enabledStamp != _sourcesEnabledStamp) {
        return;
      }
      movies.sort(
        (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
      );
      shows.sort(
        (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
      );
      _vodHomeMoviePreview = movies;
      _vodHomeSeriesPreview = shows;
      // Home selects [homeVodShelfRevision], not [vodCacheRevision]. The RAM
      // index path bumps this when previews publish; SQLite must do the same
      // or Accueil Films/Series stay on the last hydrate snapshot.
      _homeVodShelfRevision++;
    } catch (_) {
      // Leave previous preview windows; next index rebuild retries.
    }
  }

  /// Rebuild collapsed live families after preferenceKey grouping changes.
  Future<void> _maybeReindexLiveFamilyKeys() async {
    if (!_useLiveDb) return;
    try {
      if (!await _liveDb.needsFamilyKeyReindex) return;
      await _liveDb.reindexFamilyKeys(
        epgDisplayNames: epgChannelNames,
        preferredLiveQualities: preferredLiveQualities,
      );
      _liveFamilyIndex = null;
      _liveFamilyKeyById = null;
      _lazyVariantCache.clear();
      liveDbRevision++;
    } catch (_) {
      // Keep serving the previous listings; next source sync will rewrite.
    }
  }

  Future<void> _reloadPinnedLiveChannels() async {
    if (!_useLiveDb && liveChannels.isEmpty) {
      // Listings still cold — keep last-close snapshot pins for Home Watch live.
      return;
    }
    final List<MediaItem> nextFav;
    final List<MediaItem> nextRecent;
    if (!_useLiveDb) {
      final byId = {for (final c in liveChannels) c.id: c};
      nextFav = [
        for (final id in favoriteChannelIds)
          if (byId[id] case final channel?) channel,
      ];
      nextRecent = [
        for (final id in recentChannelIds)
          if (byId[id] case final channel?) channel,
      ];
    } else {
      final fav = await _liveDb.channelsByIds(favoriteChannelIds);
      final recent = await _liveDb.channelsByIds(recentChannelIds);
      final favById = {for (final c in fav) c.id: c};
      final recentById = {for (final c in recent) c.id: c};
      nextFav = [
        for (final id in favoriteChannelIds)
          if (favById[id] case final c?)
            c.copyWith(title: officialLiveTitle(c)),
      ];
      nextRecent = [
        for (final id in recentChannelIds)
          if (recentById[id] case final c?)
            c.copyWith(title: officialLiveTitle(c)),
      ];
    }
    _favoriteChannelsCache = nextFav;
    _recentChannelsCache = nextRecent;
    _rememberLivePinsFinger(bump: true);
  }

  /// Idempotent cleanup of historically polluted pins: users who starred/zapped
  /// HD/FHD/SD siblings before the collapse fix have raw variant ids stored.
  /// Rewrites them to canonical listing ids so recents/favorites/For you stop
  /// showing multiple versions of the same channel. Only writes when changed.
  ///
  /// Ids that no longer resolve (e.g. a temporarily disabled source) are kept
  /// as-is so this never silently drops a user's pins.
  Future<void> _collapseLegacyLivePins() async {
    final Map<String, MediaItem> byId;
    if (_useLiveDb) {
      final pinned = [...favoriteChannelIds, ...recentChannelIds];
      byId = {for (final c in await _liveDb.channelsByIds(pinned)) c.id: c};
    } else {
      byId = {for (final c in liveChannels) c.id: c};
    }

    Future<List<String>> collapse(List<String> ids) async {
      final seen = <String>{};
      final out = <String>[];
      for (final id in ids) {
        final channel = byId[id];
        if (channel == null) {
          if (seen.add(id)) out.add(id);
          continue;
        }
        final canonical = await _canonicalLivePin(channel);
        if (seen.add(canonical.id)) out.add(canonical.id);
      }
      return out;
    }

    final favIds = await collapse(favoriteChannelIds);
    final recentIds = await collapse(recentChannelIds);

    var changed = false;
    if (!listEquals(favIds, favoriteChannelIds)) {
      favoriteChannelIds = favIds;
      await _store.saveFavoriteChannelIds(favoriteChannelIds);
      changed = true;
    }
    if (!listEquals(recentIds, recentChannelIds)) {
      recentChannelIds = recentIds;
      await _store.saveRecentChannelIds(recentChannelIds);
      changed = true;
    }
    if (changed) {
      await _reloadPinnedLiveChannels();
    }
  }

  void _seedLivePinsFromHomeSnapshot(HomeShelfSnapshot snap) {
    if (snap.recentLive.isEmpty) return;
    if (_recentChannelsCache.isNotEmpty || _favoriteChannelsCache.isNotEmpty) {
      return;
    }
    _recentChannelsCache = List<MediaItem>.from(snap.recentLive);
    _rememberLivePinsFinger(bump: false);
  }

  void _rememberLivePinsFinger({required bool bump}) {
    final finger = Object.hash(
      Object.hashAll([for (final c in _recentChannelsCache) c.id]),
      Object.hashAll([for (final c in _favoriteChannelsCache) c.id]),
    );
    if (_livePinsFinger == finger) return;
    _livePinsFinger = finger;
    if (bump) _livePinsRevision++;
  }

  void _ensureLiveById() {
    if (_liveById != null && identical(_liveByIdCatalogRef, catalog)) return;
    _liveById = {for (final c in liveChannels) c.id: c};
    _liveByIdCatalogRef = catalog;
  }

  String liveIndexFingerprint() {
    final live = liveChannels;
    if (live.isEmpty) return '0';
    return '${live.length}|${live.first.id}|${live.last.id}|${epgChannelNames.length}';
  }

  bool get hasLiveIndex {
    final index = _liveIndex;
    if (index == null) return false;
    return index.fingerprint == liveIndexFingerprint();
  }

  bool get liveIndexBuilding => _liveIndexBuilding;

  int indexedLiveCount({String? groupName}) {
    if (!hasLiveIndex) return 0;
    return _liveIndex!.countForGroup(groupName);
  }

  MediaItem? _presentIndexedLive(String id) {
    _ensureLiveById();
    final byId = _liveById!;
    final seed = byId[id];
    if (seed == null) return null;

    final family = _liveIndex!.familyByChannelId[id];
    MediaItem channel = seed;
    if (family != null) {
      final variantIds = _liveIndex!.variantIdsByFamily[family];
      if (variantIds != null && variantIds.isNotEmpty) {
        final variants = <MediaItem>[
          for (final vid in variantIds)
            if (byId[vid] != null) byId[vid]!,
        ];
        if (variants.isNotEmpty) {
          channel = ChannelQuality.pickVariant(
            variants,
            sessionStreamId: _sessionLiveQualities[family],
            preferredStreamId: preferredLiveQualities[family],
          );
        }
      }
    }

    final row = channel.copyWith(title: officialLiveTitle(channel));
    final count =
        _liveIndex!.variantCountById[id] ??
        _liveIndex!.variantCountById[channel.id] ??
        1;
    _liveVariantCountById[row.id] = count;
    return row;
  }

  Future<void> rebuildLiveIndex() async {
    if (_liveIndexBuilding) return;
    final live = liveChannels;
    if (live.isEmpty) {
      _liveIndex = null;
      return;
    }

    _liveIndexBuilding = true;
    final fingerprint = liveIndexFingerprint();
    final watch = Stopwatch()..start();
    try {
      // Snapshot rows off the UI thread; yield while packing the payload.
      final rows = <Map<String, dynamic>>[];
      final slice = Stopwatch()..start();
      for (var i = 0; i < live.length; i++) {
        final c = live[i];
        rows.add({
          'id': c.id,
          'title': c.title,
          'group': c.group,
          'sourceId': c.sourceId,
          'streamId': c.streamId,
          'epgChannelId': c.epgChannelId,
          'channelName': c.channelName,
          'catchupDays': c.catchupDays,
        });
        await yieldUiSlice(
          slice,
          i: i,
          checkMask: 127,
          label: 'live-index-pack',
        );
      }
      if (fingerprint != liveIndexFingerprint()) {
        return; // Catalog changed mid-build.
      }

      final epgNames = Map<String, String>.from(epgChannelNames);
      final index = await buildLiveChannelIndexInIsolate(
        fingerprint: fingerprint,
        epgNames: epgNames,
        rows: rows,
      );
      if (fingerprint != liveIndexFingerprint()) return;
      await _applyLiveIndex(index);
      unawaited(_store.saveLiveChannelIndex(index));
      notifyListeners();
      JavpLog.i(
        'live',
        'ensureLiveIndex in ${watch.elapsedMilliseconds}ms '
            'channels=${live.length}',
      );
    } catch (_) {
      // Keep progressive scan fallback.
    } finally {
      _liveIndexBuilding = false;
    }
  }

  Future<void> _applyLiveIndex(LiveChannelIndex index) async {
    _liveIndex = index;
    liveIndexRevision++;
    // Seed family maps so HQ pickers don't rescan 28k rows.
    _ensureLiveById();
    final byId = _liveById!;
    final familyIndex = <String, List<MediaItem>>{};
    final keys = <String, String?>{};
    final slice = Stopwatch()..start();
    var i = 0;
    for (final entry in index.variantIdsByFamily.entries) {
      final variants = <MediaItem>[for (final id in entry.value) ?byId[id]];
      if (variants.isNotEmpty) familyIndex[entry.key] = variants;
      await yieldUiSlice(slice, i: i++, label: 'live-index-family');
    }
    for (final entry in index.familyByChannelId.entries) {
      keys[entry.key] = entry.value;
      await yieldUiSlice(slice, i: i++, label: 'live-index-keys');
    }
    for (final id in index.allIds) {
      keys.putIfAbsent(id, () => null);
    }
    _liveFamilyIndex = familyIndex;
    _liveFamilyKeyById = keys;
    _liveFamilyIndexNamesRef = epgChannelNames;
    _liveVariantCountById = Map<String, int>.from(index.variantCountById);
  }

  Map<String, List<MediaItem>>? _liveByGroup;

  void _ensureLiveByGroup() {
    if (_liveByGroup != null) return;
    final map = <String, List<MediaItem>>{};
    for (final channel in liveChannels) {
      final group = channel.group ?? '';
      map.putIfAbsent(group, () => []).add(channel);
    }
    _liveByGroup = map;
  }

  /// Category-scoped live rows without scanning the full 28k list.
  List<MediaItem> liveChannelsInGroup(String? groupName) {
    if (parentalLock?.isGroupNameHidden(groupName) == true) {
      return const [];
    }
    if (groupName == null || groupName.isEmpty) {
      final all = liveChannels;
      final lock = parentalLock;
      if (lock == null || !lock.isContentLocked) return all;
      return [
        for (final c in all)
          if (!lock.isLiveChannelHidden(c)) c,
      ];
    }
    _ensureLiveByGroup();
    return _liveByGroup![groupName] ?? const [];
  }

  /// True when we already attempted a per-stream EPG fetch (even if empty).
  bool isGuideFetched(MediaItem channel) {
    if (!isEpgEnabledForChannel(channel)) return true;
    return _epgByStreamId.containsKey(_guideCacheKey(channel));
  }

  /// True when we have usable programme rows for this channel.
  bool hasChannelGuide(MediaItem channel) {
    if (!isEpgEnabledForChannel(channel)) return false;
    final cached = _epgByStreamId[_guideCacheKey(channel)];
    if (cached != null) return cached.isNotEmpty;
    if (_useEpgDb) {
      final exact = _resolveXmltvChannelId(channel);
      if (exact == null) return false;
      final lru = _epgXmltvByExactId[exact];
      if (lru != null) return lru.isNotEmpty;
      return true;
    }
    _ensureEpgChannelIndex();
    return _epgLookupIndex!
        .programmesFor(
          epgChannelId: channel.epgChannelId,
          channelTitle: channel.title,
          channelName: channel.channelName,
        )
        .isNotEmpty;
  }

  void _ensureLiveFamilyIndex() {
    // Family keys depend on EPG display names; rebuild when those change too.
    if (_liveFamilyIndex != null &&
        identical(_liveFamilyIndexNamesRef, epgChannelNames) &&
        _liveFamilyKeyById != null) {
      return;
    }
    final channels = liveChannels;
    final index = <String, List<MediaItem>>{};
    final keys = <String, String?>{};
    for (final channel in channels) {
      final key = liveFamilyKey(channel);
      keys[channel.id] = key;
      if (key == null) continue;
      index.putIfAbsent(key, () => []).add(channel);
    }
    for (final variants in index.values) {
      variants.sort(ChannelQuality.compareVariants);
    }
    _liveFamilyIndex = index;
    _liveFamilyKeyById = keys;
    _liveFamilyIndexNamesRef = epgChannelNames;
  }

  void _ensureEpgChannelIndex() {
    if (identical(_epgChannelIndexRef, epg) &&
        identical(_epgChannelNamesIndexRef, epgChannelNames) &&
        _epgLookupIndex != null) {
      return;
    }
    _epgLookupIndex = EpgChannelMatcher.buildIndex(
      programs: epg,
      channelNames: epgChannelNames,
    );
    _epgChannelIndexRef = epg;
    _epgChannelNamesIndexRef = epgChannelNames;
  }

  List<EpgProgram> _xmltvProgrammesFor(MediaItem channel) {
    if (_useEpgDb) {
      final exact = _resolveXmltvChannelId(channel);
      if (exact == null) return const [];
      final cached = _epgXmltvByExactId[exact];
      if (cached != null) return cached;
      _scheduleXmltvGuidePrefetch(channel);
      return const [];
    }
    _ensureEpgChannelIndex();
    return _epgLookupIndex!.programmesFor(
      epgChannelId: channel.epgChannelId,
      channelTitle: channel.title,
      channelName: channel.channelName,
    );
  }

  /// Local + VOD-cache + live-channel search used by Search.
  ///
  /// Snapshots the VOD cache first so background ingest can't throw
  /// ConcurrentModificationError mid-scan. Live listings live in SQLite when
  /// [_useLiveDb] is on, so they are queried separately via [pageLiveChannels].
  ///
  /// Scans the **full** VOD snapshot (no prefix cap) using a precomputed
  /// lowercase haystack map ([ensureVodSearchHay]) so each keystroke does not
  /// re-allocate/toLowerCase every title. Collects matches from every source,
  /// then ranks for the UI page. Pass [collapse] `false` when the caller will
  /// cluster families itself (Search) so `EN|` / `FR|` hits are not dropped
  /// before [vodSearchFamilyIndex] runs.
  Future<List<MediaItem>> searchLocalLibrary(
    String query, {
    String? sourceKey,
    int limit = 60,
    bool collapse = true,
  }) {
    final q = query.trim();
    if (q.isEmpty) return Future.value(const []);
    final gen = ++_localSearchGen;
    // Mark interactive so SyncEngine / idle prune yields sockets + CPU.
    // Chain behind the previous local search — overlapping FTS calls on the
    // same sqflite queue is what made typing wait multi-second (timeout does
    // not cancel the in-flight query).
    final prev = _localSearchTail;
    final done = Completer<void>();
    _localSearchTail = done.future;
    return _runUserFacing(() async {
      try {
        if (prev != null) {
          try {
            await prev;
          } catch (_) {}
        }
        if (gen != _localSearchGen) return const <MediaItem>[];
        return await _searchLocalLibraryBody(
          q,
          sourceKey: sourceKey,
          limit: limit,
          collapse: collapse,
          gen: gen,
        );
      } finally {
        if (!done.isCompleted) done.complete();
        if (identical(_localSearchTail, done.future)) {
          _localSearchTail = null;
        }
      }
    });
  }

  Future<List<MediaItem>> _searchLocalLibraryBody(
    String q, {
    String? sourceKey,
    int limit = 60,
    bool collapse = true,
    required int gen,
  }) async {
    final watch = Stopwatch()..start();
    final out = <MediaItem>[];
    final seen = <String>{};
    final tokens = IptvSearchQuery.tokens(q);
    var liveHits = 0;
    var catalogHits = 0;
    var vodHits = 0;
    var liveMs = 0;
    var catalogMs = 0;
    var vodMs = 0;
    bool stillCurrent() => gen == _localSearchGen;

    // Live listings are already on disk — start that scan before any VOD
    // JSON hydrate so typing in Search is not gated on a 200k movie cache.
    // Single-character queries used to pull 200 live rows + EPG (logs: live=200
    // while FTS also waited 4s) — defer live/EPG until two+ chars.
    final Future<List<MediaItem>> liveFuture;
    if (sourceKey == localSourceKey || q.length < 2) {
      liveFuture = Future.value(const <MediaItem>[]);
    } else {
      liveFuture = () async {
        try {
          return await pageLiveChannels(
            sourceId: sourceKey,
            query: q,
            limit: (limit * 2).clamp(16, 120),
          );
        } catch (e) {
          debugPrint('Live search failed: $e');
          return const <MediaItem>[];
        }
      }();
    }

    // FTS reads vod_catalog.db directly. Only the in-memory fallback needs
    // a full disk hydrate before scanning.
    if (!_useVodDb) {
      await ensureVodDiskHydrated();
    }

    // Prefer a warm hay map. Do not await a cold rebuild here — that would
    // walk the library twice (build + scan) on the first keystroke after
    // hydrate. Background warm starts at disk hydrate / [_touchVodCache].
    _scheduleVodSearchHayBuild();
    final hayById =
        (_vodSearchHayById != null &&
            _vodSearchHayRevision == _vodCacheRevision)
        ? _vodSearchHayById
        : null;

    bool passesFilters(MediaItem m) {
      if (!seen.add(m.id)) return false;
      if (m.kind == MediaKind.vod || m.kind == MediaKind.series || m.isSeries) {
        if (!isSourceVodContentVisible(m.sourceId)) return false;
      } else if (!isSourceContentVisible(m.sourceId)) {
        return false;
      }
      if (parentalLock?.isItemHidden(m) == true) return false;
      if (sourceKey != null) {
        if (sourceKey == localSourceKey) {
          if (m.origin != MediaOrigin.localFile &&
              m.origin != MediaOrigin.url &&
              m.origin != MediaOrigin.torrent &&
              m.origin != MediaOrigin.download) {
            return false;
          }
        } else if (m.sourceId != sourceKey) {
          return false;
        }
      }
      return true;
    }

    bool matches(MediaItem m) {
      if (!passesFilters(m)) return false;
      final cached = hayById?[m.id];
      final hayLower = cached ?? VodSearchIndex.hayFor(m);
      if (cached == null &&
          hayById != null &&
          _vodSearchHayRevision == _vodCacheRevision) {
        hayById[m.id] = hayLower;
      }
      return VodSearchIndex.matchesTokens(hayLower, tokens);
    }

    List<MediaItem> finishAndLog({
      required int scanned,
      required bool hayWarm,
      required String vodMode,
    }) {
      if (q.length >= 3) {
        unawaited(_enrichMissingTmdbForSearchHits(out));
      }
      final ranked = collapse
          ? collapseSearchHits(out, limit: limit, query: q)
          : out;
      _logLocalSearch(
        watch: watch,
        q: q,
        tokens: tokens,
        raw: out.length,
        ranked: ranked.length,
        liveHits: liveHits,
        liveMs: liveMs,
        catalogHits: catalogHits,
        catalogMs: catalogMs,
        vodHits: vodHits,
        vodMs: vodMs,
        scanned: scanned,
        hayWarm: hayWarm,
        vodMode: vodMode,
        sourceKey: sourceKey,
      );
      return ranked;
    }

    // Live TV — channels are not in [allContent] when the live DB is on.
    // SQL already ranks by cleaned prefix; over-fetch so merge can still
    // prefer a strong VOD hit over an early live row.
    final liveWatch = Stopwatch()..start();
    final livePage = stillCurrent() ? await liveFuture : const <MediaItem>[];
    if (!stillCurrent()) {
      return finishAndLog(
        scanned: 0,
        hayWarm: hayById != null,
        vodMode: 'superseded',
      );
    }
    for (final m in livePage) {
      if (!matches(m)) continue;
      out.add(m);
      liveHits++;
    }
    liveMs = liveWatch.elapsedMilliseconds;

    try {
      if (sourceKey != localSourceKey && q.length >= 2) {
        for (final m in await searchEpgHitsAsync(
          q,
          limit: (limit * 2).clamp(16, 80),
          seedChannels: livePage,
        )) {
          if (!stillCurrent()) break;
          if (!passesFilters(m)) continue;
          out.add(m);
          liveHits++;
        }
      }
    } catch (e) {
      debugPrint('EPG search failed: $e');
    }
    if (!stillCurrent()) {
      return finishAndLog(
        scanned: 0,
        hayWarm: hayById != null,
        vodMode: 'superseded',
      );
    }

    final catalogWatch = Stopwatch()..start();
    final catalogSlice = Stopwatch()..start();
    final content = allContent;
    for (var i = 0; i < content.length; i++) {
      final m = content[i];
      if (m.isLive) continue; // already covered above / avoid dupes
      // SQLite FTS covers VOD/series — do not rescan the RAM catalog.
      if (_useVodDb &&
          (m.kind == MediaKind.vod || m.kind == MediaKind.series)) {
        continue;
      }
      if (!matches(m)) continue;
      out.add(m);
      catalogHits++;
      await yieldUiSlice(catalogSlice, i: i, label: 'search-catalog-scan');
    }
    catalogMs = catalogWatch.elapsedMilliseconds;

    // Copy before scan — ingest mutates [_vodStreamCache] concurrently.
    // Full snapshot walk: Xtream series often sit after tens of thousands of
    // movies. No prefix cap; UI [limit] applied only after relevance ranking.
    final vodWatch = Stopwatch()..start();
    // One-char MATCH (`k*`) on ~200k FTS rows is useless noise while typing;
    // Search UI already skips remote/live for qLen<2.
    if (_useVodDb && q.length < 2) {
      vodMs = vodWatch.elapsedMilliseconds;
      return finishAndLog(
        scanned: 0,
        hayWarm: hayById != null,
        vodMode: 'skip-short',
      );
    }
    // Desktop SyncEngine / long DELETE prune serialize on the same sqflite
    // queue as FTS — awaiting forever freezes Search ("instalagged"). Skip or
    // time out and fall through to the warm RAM snapshot instead.
    final catalogWriterBusy =
        DesktopUi.isDesktopOs && SyncScheduler.instance.isCatalogWriterBusy;
    final ftsCooling =
        _ftsCooldownUntil != null &&
        DateTime.now().isBefore(_ftsCooldownUntil!);
    if (_useVodDb && !catalogWriterBusy && !ftsCooling) {
      try {
        final allowed = sourceKey == null || sourceKey == localSourceKey
            ? _vodAllowedSourceIds()
            : <String>[sourceKey];
        final ftsHits = await _vodDb
            .searchFts(
              q,
              sourceId: sourceKey == localSourceKey ? null : sourceKey,
              allowedSourceIds: sourceKey == null ? allowed : null,
              excludeAdult: _parentalExcludeAdult(),
              limit: (limit * 3).clamp(60, 240),
            )
            .timeout(_interactiveFtsTimeout);
        if (!stillCurrent()) {
          vodMs = vodWatch.elapsedMilliseconds;
          return finishAndLog(
            scanned: ftsHits.length,
            hayWarm: true,
            vodMode: 'superseded',
          );
        }
        for (final m in ftsHits) {
          if (!passesFilters(m)) continue;
          out.add(m);
          vodHits++;
        }
        vodMs = vodWatch.elapsedMilliseconds;
        _ftsCooldownUntil = null;
        return finishAndLog(
          scanned: ftsHits.length,
          hayWarm: true,
          vodMode: _vodDb.ftsEnabled ? 'fts5' : 'like',
        );
      } on TimeoutException {
        _ftsCooldownUntil = DateTime.now().add(_ftsCooldown);
        JavpLog.w(
          'search',
          'fts timeout — cooldown ${_ftsCooldown.inMilliseconds}ms '
              'qLen=${q.length} writerBusy=$catalogWriterBusy',
        );
        // Do not burn the UI isolate walking a tiny SQLite-era RAM snapshot
        // after a timeout — return live/catalog already collected.
        if (!stillCurrent() || _useVodDb) {
          vodMs = vodWatch.elapsedMilliseconds;
          return finishAndLog(
            scanned: 0,
            hayWarm: hayById != null,
            vodMode: 'fts-timeout',
          );
        }
      } catch (e) {
        debugPrint('VOD FTS search failed, falling back: $e');
      }
    } else if (_useVodDb && (catalogWriterBusy || ftsCooling)) {
      JavpLog.i(
        'search',
        'fts skip ${catalogWriterBusy ? 'writer-busy' : 'cooldown'} '
            'qLen=${q.length}',
      );
      if (_useVodDb) {
        vodMs = vodWatch.elapsedMilliseconds;
        return finishAndLog(
          scanned: 0,
          hayWarm: hayById != null,
          vodMode: catalogWriterBusy ? 'writer-busy' : 'fts-cooldown',
        );
      }
    }
    final snapshot = _vodStreamCache.values.toList(growable: false);
    // Isolate packs only the hay map — require full coverage of the snapshot
    // so mid-ingest growth (same revision, new ids) cannot skip titles.
    final useIsolate =
        hayById != null &&
        snapshot.length >= VodSearchIndex.isolateFilterMinRows &&
        hayById.length >= snapshot.length;
    var vodMode = 'slice';
    if (useIsolate) {
      try {
        final flat = VodSearchIndex.packFlat(hayById);
        // Top-level entry — never Isolate.run from an instance method closure
        // (that captures LibraryProvider and fails sendability).
        final hitIds = await vodSearchFilterInIsolate(flat, tokens);
        final byId = <String, MediaItem>{for (final m in snapshot) m.id: m};
        for (final id in hitIds) {
          final m = byId[id];
          if (m == null) continue;
          if (!passesFilters(m)) continue;
          out.add(m);
          vodHits++;
        }
        vodMode = 'isolate';
        vodMs = vodWatch.elapsedMilliseconds;
        return finishAndLog(
          scanned: snapshot.length,
          hayWarm: hayById != null,
          vodMode: vodMode,
        );
      } catch (e) {
        debugPrint('Isolate VOD search failed, falling back: $e');
        // Fall through to UI-sliced scan.
      }
    }

    // Time-slice yields (~8ms) when hay is cold or isolate is unavailable.
    // Also yield every 2048 rows so a warm cheap scan cannot monopolize the UI.
    final slice = Stopwatch()..start();
    for (var i = 0; i < snapshot.length; i++) {
      final m = snapshot[i];
      if (matches(m)) {
        out.add(m);
        vodHits++;
      }
      final boundary = (i & 63) == 63;
      if ((boundary && slice.elapsedMilliseconds >= _vodSearchSliceMs) ||
          (i & 2047) == 2047) {
        await yieldAfterIsolateChunk();
        slice.reset();
      }
    }
    vodMs = vodWatch.elapsedMilliseconds;
    return finishAndLog(
      scanned: snapshot.length,
      hayWarm: hayById != null,
      vodMode: vodMode,
    );
  }

  static const epgSearchTag = 'epg';
  static const epgSearchCatchupTag = 'epg-catchup';
  static const epgSearchStartTagPrefix = 'epg-start:';
  static const epgSearchEndTagPrefix = 'epg-end:';

  MediaItem _epgSearchItem(
    MediaItem channel,
    EpgProgram program,
    DateTime now, {
    required bool hasCatchup,
  }) {
    final isNow = program.isAiringAt(now);
    final isPast = program.end.isBefore(now);
    final canPlayCatchup = hasCatchup && (isPast || isNow);
    final channelLabel = liveOrCatchupDisplayTitle(channel);
    final source = sourceLabelFor(channel);
    final when = [
      _epgSearchDayLabel(program.start, now),
      program.timeWindow,
      if (isNow) _uiL10n.liveBadge,
      if (canPlayCatchup) _uiL10n.catchup,
    ].join(' · ');
    return MediaItem(
      id: '${channel.id}|epg|${program.start.toUtc().millisecondsSinceEpoch}',
      title: program.title,
      playUrl: channel.playUrl,
      kind: MediaKind.live,
      origin: channel.origin,
      subtitle: [
        channelLabel,
        if (source.isNotEmpty && source != channelLabel) source,
        when,
      ].join(' · '),
      thumbnailUrl: program.imageUrl ?? channel.thumbnailUrl,
      sourceId: channel.sourceId,
      streamId: channel.streamId,
      channelId: channel.channelId,
      channelName: channel.channelName ?? channel.title,
      epgChannelId: channel.epgChannelId,
      plot: program.description,
      duration: program.duration,
      catchupDays: channel.catchupDays,
      httpHeaders: channel.httpHeaders,
      tags: [
        epgSearchTag,
        '$epgSearchStartTagPrefix${program.start.toUtc().millisecondsSinceEpoch}',
        '$epgSearchEndTagPrefix${program.end.toUtc().millisecondsSinceEpoch}',
        if (canPlayCatchup) epgSearchCatchupTag,
      ],
    );
  }

  String _epgSearchDayLabel(DateTime start, DateTime now) {
    final local = start.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final stamped =
        '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}';
    final diff = day.difference(today).inDays;
    if (diff == 0) return _uiL10n.todayStamp(stamped);
    if (diff == -1) return _uiL10n.yesterdayStamp(stamped);
    if (diff == 1) return _uiL10n.tomorrowStamp(stamped);
    return stamped;
  }

  EpgProgram? epgProgramFromSearchItem(MediaItem item) {
    if (!item.tags.contains(epgSearchTag)) return null;
    DateTime? start;
    DateTime? end;
    for (final tag in item.tags) {
      if (tag.startsWith(epgSearchStartTagPrefix)) {
        final ms = int.tryParse(tag.substring(epgSearchStartTagPrefix.length));
        if (ms != null) {
          start = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        }
      } else if (tag.startsWith(epgSearchEndTagPrefix)) {
        final ms = int.tryParse(tag.substring(epgSearchEndTagPrefix.length));
        if (ms != null) {
          end = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        }
      }
    }
    if (start == null) return null;
    end ??= item.duration != null ? start.add(item.duration!) : start;
    return EpgProgram(
      channelId: item.epgChannelId ?? item.streamId ?? item.id,
      title: item.title,
      start: start,
      end: end,
      description: item.plot,
      imageUrl: item.thumbnailUrl,
      hasArchive: item.tags.contains(epgSearchCatchupTag),
    );
  }

  void _logLocalSearch({
    required Stopwatch watch,
    required String q,
    required List<String> tokens,
    required int raw,
    required int ranked,
    required int liveHits,
    required int liveMs,
    required int catalogHits,
    required int catalogMs,
    required int vodHits,
    required int vodMs,
    required int scanned,
    required bool hayWarm,
    required String vodMode,
    String? sourceKey,
  }) {
    final ms = watch.elapsedMilliseconds;
    // Debounced UI search is coarse; still skip sub-frame scans.
    // No raw query text — length + phase timings only.
    final summary =
        'local in ${ms}ms qLen=${q.length} tokens=${tokens.length} '
        'raw=$raw n=$ranked '
        'live=$liveHits/${liveMs}ms '
        'catalog=$catalogHits/${catalogMs}ms '
        'vod=$vodHits/${vodMs}ms scanned=$scanned '
        'hay=${hayWarm ? 'warm' : 'cold'} mode=$vodMode'
        '${sourceKey == null ? '' : ' source=1'}';
    if (ms >= 500) {
      JavpLog.w('search', summary);
    } else {
      JavpLog.slow('search', summary, ms);
    }
  }

  /// Awaitable Search haystack map for [_vodStreamCache].
  ///
  /// Safe to call often. Small caches build synchronously; large Xtream caches
  /// use frame yields (same class of work as [ensureVodGroupIndex]).
  Future<void> ensureVodSearchHay() async {
    if (_vodSearchHayById != null &&
        _vodSearchHayRevision == _vodCacheRevision) {
      return;
    }
    if (_vodStreamCache.isEmpty) {
      // Mutable — [searchLocalLibrary] may backfill live/allContent misses.
      _vodSearchHayById = <String, String>{};
      _vodSearchHayRevision = _vodCacheRevision;
      return;
    }
    _scheduleVodSearchHayBuild();
    await (_vodSearchHayBuildFuture ?? Future<void>.value());
  }

  void _scheduleVodSearchHayBuild() {
    if (_vodSearchHayBuilding) return;
    if (_vodSearchHayById != null &&
        _vodSearchHayRevision == _vodCacheRevision) {
      return;
    }
    if (_vodStreamCache.isEmpty) {
      // Mutable — [searchLocalLibrary] may backfill live/allContent misses.
      _vodSearchHayById = <String, String>{};
      _vodSearchHayRevision = _vodCacheRevision;
      return;
    }
    _vodSearchHayBuilding = true;
    final revision = _vodCacheRevision;
    JavpLog.i(
      'vod',
      'search hay scheduled n=${_vodStreamCache.length} rev=$revision '
          'queue=${_bgQueue.pendingCount}',
    );
    final build = _finishVodSearchHayBuild(revision: revision);
    _vodSearchHayBuildFuture = build;
    unawaited(build);
  }

  Future<void> _finishVodSearchHayBuild({required int revision}) async {
    final watch = Stopwatch()..start();
    JavpLog.i(
      'vod',
      'search hay start n=${_vodStreamCache.length} rev=$revision',
    );
    try {
      UiStallWatchdog.enter('vod-search-hay');
      final map = <String, String>{};
      var i = 0;
      final slice = Stopwatch()..start();
      // Keys-only snapshot — a full MediaItem values list (~200k refs) after
      // hydrate allocated a parallel giant array and triggered GC stalls
      // (1–2s frames with build=0 / raster=0, hitch tags=vod).
      final keys = _vodStreamCache.keys.toList(growable: false);
      final n = keys.length;
      // Check yields more often on huge caches so Accueil keeps getting frames.
      final checkMask = n > 50000 ? 31 : 63;
      for (final id in keys) {
        if (revision != _vodCacheRevision) {
          JavpLog.i(
            'vod',
            'search hay cancelled rev-mismatch after ${watch.elapsedMilliseconds}ms',
          );
          return;
        }
        final item = _vodStreamCache[id];
        if (item == null) continue;
        map[id] = VodSearchIndex.hayFor(item);
        if ((++i & checkMask) == 0 &&
            slice.elapsedMilliseconds >= _vodSearchSliceMs) {
          await yieldAfterIsolateChunk();
          slice.reset();
        }
      }
      if (revision != _vodCacheRevision) {
        JavpLog.i(
          'vod',
          'search hay cancelled rev-mismatch at end '
              'after ${watch.elapsedMilliseconds}ms',
        );
        return;
      }
      _vodSearchHayById = map;
      _vodSearchHayRevision = revision;
      JavpLog.slow(
        'vod',
        'search hay done in ${watch.elapsedMilliseconds}ms n=${map.length}',
        watch.elapsedMilliseconds,
      );
    } catch (e) {
      JavpLog.w('vod', 'search hay build failed', error: e);
    } finally {
      UiStallWatchdog.leave();
      _vodSearchHayBuilding = false;
    }
  }

  /// Collapse language/quality VOD variants and duplicate series shells so
  /// Search does not show dozens of EN|/FR| rows for one title.
  ///
  /// Clusters the hit list itself (plus indexed siblings) so a catalog TMDB
  /// row and an IPTV `FR|` copy become one card even while the global Versions
  /// index is rebuilding after enrichment.
  ///
  /// When [query] is set, ranks cleaned prefix / word-start hits before A–Z
  /// so playlist order and `US|` / `HD` prefixes do not bury the obvious match.
  List<MediaItem> collapseSearchHits(
    List<MediaItem> items, {
    int? limit,
    String? query,
  }) {
    final vodHits = <MediaItem>[];
    final rest = <MediaItem>[];
    for (final item in items) {
      if ((item.kind == MediaKind.vod || item.isSeries) && !item.isEpisode) {
        vodHits.add(item);
      } else {
        rest.add(item);
      }
    }

    final byId = <String, MediaItem>{};
    for (final item in vodHits) {
      byId[item.id] = item;
      for (final sibling in vodVariantsFor(item)) {
        byId.putIfAbsent(sibling.id, () => sibling);
      }
    }
    final clustered = VodVariantIndex.clusterItems(byId.values.toList());
    final canonical = clustered.canonical;
    final liveCanonical = _activeVodCanonical;
    final catalogAliases = _catalogIdentityLookup().aliasCanonical;

    String familyKey(MediaItem item) {
      final primary = VodGrouping.groupKey(item);
      if (primary != null) {
        return 'vod:${canonical[primary] ?? liveCanonical?[primary] ?? catalogAliases[primary] ?? primary}';
      }
      for (final alias in VodGrouping.nameGroupAliases(item)) {
        final mapped =
            canonical[alias] ?? liveCanonical?[alias] ?? catalogAliases[alias];
        if (mapped != null) return 'vod:$mapped';
      }
      return 'id:${item.id}';
    }

    final seen = <String>{};
    final out = <MediaItem>[];
    for (final item in vodHits) {
      if (!seen.add(familyKey(item))) continue;
      out.add(resolveVodVariant(item));
    }
    for (final item in rest) {
      if (item.isLive && !item.tags.contains(epgSearchTag)) {
        final key = _searchLiveFamilyKey(item);
        if (!seen.add(key)) {
          _mergeSearchLiveCatchup(out, item);
          continue;
        }
        out.add(item);
        continue;
      }
      final key = _searchDedupeKey(item);
      if (!seen.add(key)) continue;
      out.add(item);
    }
    final q = query?.trim() ?? '';
    if (q.isNotEmpty) {
      out.sort((a, b) {
        final byScore = IptvSearchQuery.scoreItem(
          q,
          b,
        ).compareTo(IptvSearchQuery.scoreItem(q, a));
        if (byScore != 0) return byScore;
        return VodGrouping.compareDisplayTitle(a, b);
      });
    } else {
      out.sort(VodGrouping.compareDisplayTitle);
    }
    if (limit != null && out.length > limit) {
      return out.sublist(0, limit);
    }
    return out;
  }

  /// Same-title / multi-source identity used by Search, Films, and For you.
  String shelfIdentityKey(MediaItem item) => _searchDedupeKey(item);

  String _searchDedupeKey(MediaItem item) {
    if (item.isSeries || (item.kind == MediaKind.vod && !item.isEpisode)) {
      final g = canonicalVodGroupKey(item);
      if (g != null) return '${item.isSeries ? 'series' : 'vod'}:$g';
    }
    if (item.isSeries) {
      if (item.anilistId != null && item.anilistId! > 0) {
        return 'al:${item.anilistId}';
      }
      if (item.tmdbId != null && item.tmdbId! > 0) {
        return 'tmdb-tv:${item.tmdbId}';
      }
      return 'series:${VodGrouping.normalizeTitle(item.title)}|${item.year ?? ''}';
    }
    return 'id:${item.id}';
  }

  String _searchLiveFamilyKey(MediaItem item) {
    final raw = (item.channelName ?? item.title).trim();
    final base = ChannelQuality.baseTitle(raw);
    final norm = ChannelQuality.normalizeKey(base.isNotEmpty ? base : raw);
    if (norm.isEmpty) return 'id:${item.id}';
    return 'live:$norm';
  }

  /// Prefer a catchup-capable listing when collapsing same-name live hits.
  void _mergeSearchLiveCatchup(List<MediaItem> out, MediaItem incoming) {
    final incomingDays = incoming.supportsCatchup
        ? incoming.catchupDays
        : liveFamilyCatchupDays(incoming);
    if (incomingDays > 0) {
      _rememberFamilyCatchupDays(incoming.id, incomingDays);
    }
    for (var i = 0; i < out.length; i++) {
      final keep = out[i];
      if (!keep.isLive || keep.tags.contains(epgSearchTag)) continue;
      if (_searchLiveFamilyKey(keep) != _searchLiveFamilyKey(incoming)) {
        continue;
      }
      final keepDays = keep.supportsCatchup
          ? keep.catchupDays
          : liveFamilyCatchupDays(keep);
      final maxDays = incomingDays > keepDays ? incomingDays : keepDays;
      if (maxDays > 0) {
        _rememberFamilyCatchupDays(keep.id, maxDays);
        _rememberFamilyCatchupDays(incoming.id, maxDays);
      }
      // Prefer a real archive stream, else the listing whose family has catchup
      // so start-over / DVR resolve against the source that actually archives.
      if (!keep.supportsCatchup && incoming.supportsCatchup) {
        out[i] = incoming;
      } else if (incomingDays > keepDays && incomingDays > 0) {
        out[i] = incoming;
      }
      return;
    }
  }

  /// Extra Home rails from catalog `group` values (BYO / media-server shelves).
  ///
  /// Skips generic Movies/Series labels already covered by dedicated rails.
  /// The full catalog/VOD scan is memoized; [excludeIds] is applied on read.
  List<({String title, List<MediaItem> items})> catalogGroupPreviews({
    int maxGroups = 4,
    int perGroup = 12,
    Set<String> excludeIds = const {},
  }) {
    final ranked = _catalogGroupBuckets();
    final previews = <({String title, List<MediaItem> items})>[];
    for (final entry in ranked) {
      if (previews.length >= maxGroups) break;
      final filtered = excludeIds.isEmpty
          ? entry.value
          : [
              for (final m in entry.value)
                if (!excludeIds.contains(m.id)) m,
            ];
      if (filtered.length < 3) continue;
      previews.add((
        title: entry.key,
        items: filtered.length <= perGroup
            ? filtered
            : filtered.sublist(0, perGroup),
      ));
    }
    return previews;
  }

  List<MapEntry<String, List<MediaItem>>> _catalogGroupBuckets() {
    const reserved = {
      'movies',
      'movie',
      'films',
      'film',
      'vod',
      'series',
      'shows',
      'tv shows',
      'tv',
    };
    final prefs = _preferredContentLangs;
    final stamp = Object.hash(
      identityHashCode(catalog),
      catalog.length,
      vodCacheRevision,
      sourcesEnabledRevision,
      Object.hashAll(prefs),
    );
    if (_cachedGroupBuckets != null && _groupBucketsStamp == stamp) {
      return _cachedGroupBuckets!;
    }

    final buckets = <String, List<MediaItem>>{};
    void consider(MediaItem item) {
      if (item.isLive || item.kind == MediaKind.catchup || item.isEpisode) {
        return;
      }
      if (!isListedVodSourceVisible(item.sourceId)) return;
      if (item.kind != MediaKind.vod &&
          item.kind != MediaKind.series &&
          item.kind != MediaKind.local &&
          item.kind != MediaKind.network) {
        return;
      }
      final group = item.group?.trim() ?? '';
      if (group.isEmpty) return;
      if (reserved.contains(group.toLowerCase())) return;
      final list = buckets.putIfAbsent(group, () => <MediaItem>[]);
      if (list.any((m) => m.id == item.id)) return;
      // Cap per group early — Home only shows ~12.
      if (list.length >= 48) return;
      list.add(item);
    }

    for (final item in catalog) {
      consider(item);
    }
    final indexed =
        _vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision;
    if (indexed) {
      // Full group map — sample up to 48 per group (intentional Home preview).
      // Skip reserved buckets by key so a 100k "Films"/"VOD" group is not
      // walked item-by-item on every Home rebuild after index ready.
      for (final entry in _vodByGroupIndex!.entries) {
        final g = entry.key.trim();
        if (g.isEmpty || reserved.contains(g.toLowerCase())) continue;
        for (final item in entry.value) {
          consider(item);
        }
      }
    } else {
      // Cold path: capped walk + schedule index (Accueil must stay responsive).
      _scheduleVodGroupIndexBuild();
      const maxVodScan = 8000; // intentional cold-start bound
      var vodScanned = 0;
      for (final item in _vodStreamCache.values) {
        if (++vodScanned > maxVodScan) break;
        consider(item);
      }
    }

    final ranked = buckets.entries.toList()
      ..sort((a, b) {
        final byLocale =
            VodGrouping.groupHomeScore(
              b.key,
              b.value,
              preferredLangs: prefs,
            ).compareTo(
              VodGrouping.groupHomeScore(a.key, a.value, preferredLangs: prefs),
            );
        if (byLocale != 0) return byLocale;
        final byCount = b.value.length.compareTo(a.value.length);
        if (byCount != 0) return byCount;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    // Locale-matching titles first within each shelf; A–Z as tiebreaker.
    for (final entry in ranked) {
      entry.value.sort(
        (a, b) => VodGrouping.compareForHome(a, b, preferredLangs: prefs),
      );
    }
    _cachedGroupBuckets = ranked;
    _groupBucketsStamp = stamp;
    return ranked;
  }

  /// Monotonic stamp for Catalog / Search — changes when the VOD cache mutates.
  int get vodCacheRevision => _vodCacheRevision;

  /// Accueil Films/Series rails — changes when ranked Home VOD previews publish.
  int get homeVodShelfRevision => _homeVodShelfRevision;

  /// Bumped when per-source group-name maps refresh (Catalog chip/shelf warm).
  int get vodDbGroupCacheRevision => _vodDbGroupCacheRevision;

  /// True when SQLite group-index keys are published (buckets may still be empty).
  bool get hasVodGroupIndex =>
      _vodByGroupIndex != null &&
      _vodByGroupIndexRevision == _vodCacheRevision;

  /// True once [ensureVodDiskHydrated] has finished for this process (incl. empty).
  bool get isVodDiskHydrated => _vodDiskHydrated;

  /// True while disk hydrate is actively parsing/merging (not idle-delay wait).
  bool get isVodDiskHydrating =>
      _vodHydrateFuture != null && !_vodHydrateIdleWaiting;

  /// True while an idle-delayed hydrate is scheduled but not parsing yet.
  bool get isVodDiskHydrateIdleWaiting => _vodHydrateIdleWaiting;

  /// Catalog empty shelves: disk hydrate, on-demand prefetch, or category fetch.
  ///
  /// Idle-delayed hydrate (scheduled, not yet parsing) does **not** count —
  /// otherwise Catalog spins "Loading…" for the full Home paint delay.
  ///
  /// [sourceIds] empty/null = any source; otherwise only those ids (multi-pick).
  bool isVodCatalogLoading({Iterable<String>? sourceIds}) {
    // JSON parse/merge only. SQLite catalogs stay queryable mid-hydrate.
    if (!_useVodDb && _vodHydrateFuture != null && !_vodHydrateIdleWaiting) {
      return true;
    }
    if (vodLoading) return true;
    if (sourceIds == null) return _vodPrefetching.isNotEmpty;
    final ids = sourceIds is Set<String> ? sourceIds : sourceIds.toSet();
    if (ids.isEmpty) return _vodPrefetching.isNotEmpty;
    for (final id in ids) {
      if (_vodPrefetching.contains(id)) return true;
    }
    return false;
  }

  /// Why Catalog/See-all would show a spinner (for diagnostics).
  String vodCatalogLoadingReason({Iterable<String>? sourceIds}) {
    if (!_useVodDb && _vodHydrateFuture != null && !_vodHydrateIdleWaiting) {
      return 'hydrate-active';
    }
    if (_useVodDb && _vodHydrateFuture != null && !_vodHydrateIdleWaiting) {
      return 'hydrate-sqlite-ready';
    }
    if (_vodHydrateIdleWaiting) return 'hydrate-idle-wait';
    if (vodLoading) return 'category-fetch';
    if (sourceIds == null) {
      return _vodPrefetching.isEmpty
          ? 'idle'
          : 'prefetch n=${_vodPrefetching.length}';
    }
    final ids = sourceIds is Set<String> ? sourceIds : sourceIds.toSet();
    if (ids.isEmpty) {
      return _vodPrefetching.isEmpty
          ? 'idle'
          : 'prefetch n=${_vodPrefetching.length}';
    }
    final hit = ids.where(_vodPrefetching.contains).toList();
    if (hit.isNotEmpty) return 'prefetch sources=${hit.length}';
    return 'idle';
  }

  void _bumpVodBusy() {
    vodBusyRevision++;
    // Pierce quiet-mode so Catalog/Search can flip empty → spinner without
    // waiting for the next ingest notify (hydrate/prefetch latch [_uiQuiet]).
    // Deferred if the tree is locked — never `super.notifyListeners()`.
    _notifyPierceQuiet();
  }

  void clearVodCategorySelection() {
    if (vodCategoryItems.isEmpty && activeVodCategoryId == null) return;
    vodCategoryItems = [];
    activeVodCategoryId = null;
    notifyListeners();
  }

  /// Poster shelf sample for one Catalog category (~14 posters).
  ///
  /// Small/medium indexed buckets keep full A–Z. Huge IPTV buckets (journals:
  /// 50k+ Films) use a capped window so Catalog → Movies does not collapse the
  /// whole group on the UI isolate — exact A–Z lives on See-all
  /// ([queryVodCatalog]). Cold path (no index yet) may temporarily under-fill;
  /// callers that need correctness should [ensureVodGroupIndex] first.
  static const _vodShelfFullSortLimit = 600;

  /// True when [categoryName] has at least one on-demand title for [sourceKey].
  ///
  /// Used by Catalog to keep name-merged shelves when filtering by source.
  bool hasOnDemandInGroup({
    required String categoryName,
    required bool series,
    required String sourceKey,
  }) {
    if (categoryName.isEmpty || sourceKey.isEmpty) return false;
    if (_useVodDb) {
      final groups = series
          ? _vodDbSeriesGroupsBySource[sourceKey]
          : _vodDbMovieGroupsBySource[sourceKey];
      return groups != null && groups.contains(categoryName);
    }
    return vodShelfSample(
      categoryName: categoryName,
      series: series,
      sourceKey: sourceKey,
      limit: 1,
    ).isNotEmpty;
  }

  /// Whether a Catalog category row should appear for the active source filter.
  ///
  /// Provider categories may be name-merged across sources ([sourceId] is the
  /// first writer); still show the row when the selected source has titles.
  bool onDemandCategoryMatchesSource({
    required IptvCategory category,
    required String sourceId,
    required bool series,
  }) {
    final owned = category.sourceId;
    if (owned != null && owned.isNotEmpty && owned == sourceId) return true;
    return hasOnDemandInGroup(
      categoryName: category.name,
      series: series,
      sourceKey: sourceId,
    );
  }

  bool _vodIndexBuilding = false;

  void _scheduleVodGroupIndexBuild() {
    if (_vodIndexBuilding) return;
    if (_vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision) {
      return;
    }
    if (_vodStreamCache.isEmpty) return;
    _vodIndexBuilding = true;
    final revision = _vodCacheRevision;
    final prefs = List<String>.from(_preferredContentLangs);
    final build = _finishVodGroupIndexBuild(revision: revision, prefs: prefs);
    _vodIndexBuildFuture = build;
    unawaited(build);
  }

  /// Builds group + Home previews with frame yields. Avoids shipping ~200k
  /// [MediaItem]s through [Isolate.run]/[compute] (that transfer crashed the
  /// Windows embedder after hydrate).
  Future<void> _finishVodGroupIndexBuild({
    required int revision,
    required List<String> prefs,
  }) async {
    var reschedule = false;
    try {
      final map = <String, List<MediaItem>>{};
      final moviePreview = <MediaItem>[];
      final seriesPreview = <MediaItem>[];
      var i = 0;
      final slice = Stopwatch()..start();
      // Keys-only snapshot — a full values list after ~200k hydrate triggers
      // GC stalls (build=0 / raster=0 frames on Accueil).
      final keys = _vodStreamCache.keys.toList(growable: false);
      final checkMask = keys.length > 50000 ? 31 : 63;
      for (final id in keys) {
        if (revision != _vodCacheRevision) return;
        final item = _vodStreamCache[id];
        if (item == null) continue;
        final group = item.group ?? '';
        map.putIfAbsent(group, () => []).add(item);
        if (item.isSeries) {
          _vodPreviewInsert(seriesPreview, item, prefs: prefs);
        } else if (!item.isLive &&
            !item.isEpisode &&
            (item.kind == MediaKind.vod || item.kind == MediaKind.series)) {
          _vodPreviewInsert(moviePreview, item, prefs: prefs);
        }
        // Same ~8ms slices as Versions index — 1024-row chunks still janked.
        if ((++i & checkMask) == 0 &&
            slice.elapsedMilliseconds >= _vodVariantIndexSliceMs) {
          await yieldAfterIsolateChunk();
          slice.reset();
        }
      }
      if (revision != _vodCacheRevision) return;
      // Ingest can grow the cache without bumping revision mid-batch — do not
      // publish a partial snapshot; rebuild once the builder flag clears.
      if (_vodStreamCache.length != keys.length) {
        reschedule = true;
        return;
      }
      _vodByGroupIndex = map;
      _vodByGroupIndexRevision = revision;
      _vodHomeMoviePreview = moviePreview;
      _vodHomeSeriesPreview = seriesPreview;
      _homeVodShelfRevision++;
      _invalidateHomeShelfCaches();
      // Idle fan-out — avoid a full Home rematerialize on the scroll frame
      // that happens to land when the isolate publish completes.
      if (!_disposed) _notifyListenersAfterIdle();
    } catch (e) {
      JavpLog.w('vod', 'group index build failed', error: e);
    } finally {
      _vodIndexBuilding = false;
      if (reschedule) _scheduleVodGroupIndexBuild();
    }
  }

  /// Keeps a bounded Home window sorted by [VodGrouping.compareForHome].
  static void _vodPreviewInsert(
    List<MediaItem> preview,
    MediaItem item, {
    required List<String> prefs,
    int limit = 64,
  }) {
    var insertAt = preview.length;
    for (var i = 0; i < preview.length; i++) {
      if (VodGrouping.compareForHome(item, preview[i], preferredLangs: prefs) <
          0) {
        insertAt = i;
        break;
      }
    }
    if (insertAt >= limit) return;
    preview.insert(insertAt, item);
    if (preview.length > limit) preview.removeLast();
  }

  Future<MediaItem> enrichVodItem(
    MediaItem item, {
    bool discoverSiblings = true,
    bool awaitSiblings = false,
    bool userFacing = true,
  }) async {
    if (item.streamId == null || item.origin != MediaOrigin.iptvXtream) {
      return item;
    }
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || source.type != IptvSourceType.xtream) return item;
    try {
      Future<XtreamVodInfo?> fetch() =>
          _xtream.fetchVodInfo(source, vodId: item.streamId!);
      final info = userFacing ? await _runUserFacing(fetch) : await fetch();
      if (info == null) return item;
      final enriched = VodGrouping.decorate(_xtream.applyVodInfo(item, info));
      final identityChanged =
          enriched.tmdbId != item.tmdbId || enriched.imdbId != item.imdbId;
      _replaceVodCacheItem(enriched);
      if (_useVodDb) {
        unawaited(_vodDb.upsertItems([enriched]));
      }
      if (identityChanged) {
        _invalidateVodVariantIndex();
        if (discoverSiblings &&
            enriched.tmdbId != null &&
            enriched.tmdbId! > 0) {
          final siblings = _enrichXtreamTmdbSiblings(enriched);
          if (awaitSiblings) {
            await siblings;
          } else {
            unawaited(siblings);
          }
        }
      }
      vodCategoryItems = [
        for (final m in vodCategoryItems)
          if (m.id == enriched.id) enriched else m,
      ];
      if (info.tmdbId != null) {
        await _cacheDetails(
          MediaDetails(
            id: 'tmdb-movie-${info.tmdbId}',
            title: VodGrouping.displayTitle(enriched),
            mediaItemId: enriched.id,
            tmdbId: info.tmdbId,
            plot: info.plot,
            posterUrl: info.posterUrl,
            backdropUrl: info.backdropUrl,
            genres: info.genres,
            rating: info.rating,
            year: info.year,
            runtime: info.runtime,
            cast: info.cast,
            trailerKey: info.trailerKey,
            updatedAt: DateTime.now(),
          ),
        );
      }
      notifyListeners();
      return enriched;
    } catch (_) {
      return item;
    }
  }

  /// After one Xtream VOD gets a panel `tmdb_id`, pull info for same-source
  /// language editions with localized titles (PT/BR SampleTitle, …) so Search
  /// / Catalog can collapse onto the shared id. Confirmed only via API.
  Future<void> _enrichXtreamTmdbSiblings(MediaItem seed) async {
    final candidates = VodGrouping.likelyMissingTmdbSiblings(
      seed: seed,
      pool: _vodStreamCache.values,
    );
    if (candidates.isEmpty) return;
    var attached = false;
    for (final candidate in candidates) {
      await _yieldToBrowse(reason: 'xtream-tmdb-siblings');
      if (_disposed) return;
      final latest = _vodStreamCache[candidate.id] ?? candidate;
      final existing = ExternalIds.resolvedTmdbId(
        tmdbId: latest.tmdbId,
        title: latest.title,
        id: latest.id,
        tags: latest.tags,
        originalTitle: latest.originalTitle,
      );
      if (existing != null && existing > 0) continue;
      final enriched = await enrichVodItem(
        latest,
        discoverSiblings: false,
        userFacing: false,
      );
      if (enriched.tmdbId != null && enriched.tmdbId! > 0) {
        attached = true;
      }
    }
    if (!attached || _disposed) return;
    _invalidateVodVariantIndex();
    notifyListeners();
  }

  /// Seeds Search uses to attach panel TMDB ids without opening a title.
  ///
  /// One Xtream VOD per significant-token+year cluster, missing an id.
  @visibleForTesting
  static List<MediaItem> searchTmdbEnrichmentSeeds(
    Iterable<MediaItem> rawHits, {
    int limit = 4,
  }) {
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final item in rawHits) {
      if (out.length >= limit) break;
      if (item.origin != MediaOrigin.iptvXtream) continue;
      if (item.kind != MediaKind.vod || item.isSeries || item.isEpisode) {
        continue;
      }
      if (item.streamId == null || item.streamId!.isEmpty) continue;
      final existing = ExternalIds.resolvedTmdbId(
        tmdbId: item.tmdbId,
        title: item.title,
        id: item.id,
        tags: item.tags,
        originalTitle: item.originalTitle,
      );
      if (existing != null && existing > 0) continue;
      final year = item.year ?? VodGrouping.yearFromTitle(item.title);
      final tokens = VodGrouping.significantTitleTokens(item.title);
      if (year == null || tokens.isEmpty) continue;
      // Longest token clusters localized editions (PT extra subtitle) with EN.
      final primary = tokens.reduce((a, b) => a.length >= b.length ? a : b);
      final key = '$year:$primary';
      if (!seen.add(key)) continue;
      out.add(item);
    }
    return out;
  }

  int _searchTmdbEnrichGen = 0;

  /// Background: attach panel TMDB ids for Search hits so language editions
  /// collapse without opening a title first.
  Future<void> _enrichMissingTmdbForSearchHits(List<MediaItem> rawHits) async {
    final seeds = searchTmdbEnrichmentSeeds(rawHits);
    if (seeds.isEmpty) return;
    final gen = ++_searchTmdbEnrichGen;
    var attached = false;
    for (final seed in seeds) {
      if (_disposed || gen != _searchTmdbEnrichGen) return;
      await _yieldToBrowse(reason: 'search-tmdb-enrich');
      final latest = _vodStreamCache[seed.id] ?? seed;
      final existing = ExternalIds.resolvedTmdbId(
        tmdbId: latest.tmdbId,
        title: latest.title,
        id: latest.id,
        tags: latest.tags,
        originalTitle: latest.originalTitle,
      );
      if (existing != null && existing > 0) continue;
      final enriched = await enrichVodItem(
        latest,
        discoverSiblings: true,
        awaitSiblings: true,
        userFacing: false,
      );
      if (enriched.tmdbId != null && enriched.tmdbId! > 0) {
        attached = true;
      }
    }
    if (!attached || _disposed || gen != _searchTmdbEnrichGen) return;
    // Sibling pass already invalidated; bump again so Search remerges.
    _invalidateVodVariantIndex();
    notifyListeners();
  }

  List<MediaItem>? _vodPoolCache;
  int _vodPoolBuiltStamp = -1;
  Map<String, List<String>>? _vodVariantIndex;

  /// Last complete Versions map kept while [_invalidateVodVariantIndex] rebuilds.
  ///
  /// Clearing the live index without a fallback made title/search/home collapse
  /// to one edition the moment a version tap attached a TMDB id.
  Map<String, List<String>>? _vodVariantStaleIndex;
  Map<String, String>? _vodVariantStaleCanonical;

  /// Primary [VodGrouping.groupKey] → canonical family key after TMDB/name merge.
  Map<String, String>? _vodGroupCanonical;
  int _vodVariantBuiltStamp = -1;

  ({Map<String, List<MediaItem>> byKey, Map<String, String> aliasCanonical})?
  _catalogIdentityCache;
  int _catalogIdentityStamp = -1;

  /// Search / title-page / Home-idle families that include sqlite FTS hits the
  /// in-memory Versions index never loaded (Xtream VOD lives on disk when
  /// `_useVodDb`).
  ///
  /// Catalog TMDB rows join IPTV `EN|` / `FR|` siblings here so opening a
  /// catalog copy still lists the panel language editions. Accueil also
  /// hydrates visible shelf cards in the idle pump so "N sources" does not
  /// wait for a title tap.
  Map<String, List<MediaItem>> _vodFamilyOverlay = {};
  final Set<String> _vodFamilyHydratedKeys = {};
  final Set<String> _vodFamilyHydratingKeys = {};
  int _vodFamilyOverlayRevision = 0;

  /// Visible Home VOD cards waiting for sqlite family hydrate (idle pump).
  final List<MediaItem> _homeFamilyHydrateQueue = [];
  final Set<String> _homeFamilyHydrateQueuedIds = {};
  bool _homeFamilyHydratePumping = false;
  bool _homeFamilyHydrateScheduled = false;

  /// Search overlay is keyed per member id. A handful of title-page hydrates
  /// that stored every FTS hit family used to trip this and drop sqlite IPTV.
  static const _vodFamilyOverlayCap = 800;

  /// Bumped when title-page / Search sqlite families merge so Home tiles can
  /// refresh "N sources" without rematerializing Accueil.
  int get vodFamilyOverlayRevision => _vodFamilyOverlayRevision;

  /// Bumped by [_invalidateVodVariantIndex] so in-flight isolate builds see a
  /// new [_vodPoolStamp] and abort instead of republishing a pre-enrichment map.
  int _vodVariantEpoch = 0;
  bool _vodVariantIndexBuilding = false;
  Future<void>? _vodVariantIndexBuildFuture;

  /// Above this, building the Versions index sync freezes Home after a large
  /// Xtream VOD hydrate (journals: ~3–4s build jank on ~200k rows).
  static const _vodVariantIndexSyncLimit = VodVariantIndex.isolateMinRows;

  /// Keep UI packing / group-index slices under one frame. Heavy Versions
  /// grouping for large caches runs in [VodVariantIndex.buildInIsolate].
  static const _vodVariantIndexSliceMs = 8;

  bool get _allowOpportunisticVodIndex => _appForeground && _desktopShellActive;

  /// Bumped when VOD TMDB/IMDb identity changes (Search remerges collapsed hits).
  int get vodGroupingRevision => _vodVariantEpoch;

  int get _vodPoolStamp => Object.hash(
    _vodCacheRevision,
    catalog.length,
    vodCategoryItems.length,
    _sourcesEnabledStamp,
    _vodVariantEpoch,
  );

  /// Movie / series shells that may share a title-detail Versions family.
  ///
  /// Episodes stay out. Movie vs series name keys are prefixed (`name:` vs
  /// `name:tv:`) so a film and a show that share a title+year do not glue.
  bool _isVodMovieFamilyItem(MediaItem m) {
    if (m.isEpisode || m.isLive) return false;
    if (m.kind == MediaKind.catchup) return false;
    if (m.isSeries || m.kind == MediaKind.series) return true;
    return m.kind == MediaKind.vod ||
        m.kind == MediaKind.local ||
        m.kind == MediaKind.network;
  }

  List<MediaItem> _collectVodPoolItems() {
    final map = <String, MediaItem>{};
    void add(MediaItem m) {
      if (_isVodMovieFamilyItem(m)) map[m.id] = m;
    }

    for (final m in _vodStreamCache.values) {
      add(m);
    }
    for (final m in catalog) {
      add(m);
    }
    for (final m in vodCategoryItems) {
      add(m);
    }
    return map.values.toList(growable: false);
  }

  List<MediaItem> get _vodPool {
    final stamp = _vodPoolStamp;
    final cached = _vodPoolCache;
    if (cached != null && _vodPoolBuiltStamp == stamp) return cached;
    final list = _collectVodPoolItems();
    _vodPoolCache = list;
    _vodPoolBuiltStamp = stamp;
    return list;
  }

  /// Ensures the Versions / multi-source index is current.
  ///
  /// Small libraries stay synchronous (tests + detail stay correct immediately).
  /// Large Xtream caches schedule an isolate build so Home / minimize do not
  /// freeze for tens of seconds after disk hydrate — callers see single-edition
  /// rows until ready.
  void _ensureVodVariantIndex({bool force = false}) {
    final stamp = _vodPoolStamp;
    if (_vodVariantIndex != null && _vodVariantBuiltStamp == stamp) return;
    final approx = _vodStreamCache.length + catalog.length;
    if (approx <= _vodVariantIndexSyncLimit) {
      _buildVodVariantIndexSync(stamp: stamp, pool: _vodPool);
      return;
    }
    _scheduleVodVariantIndexBuild(force: force);
  }

  void _scheduleVodVariantIndexBuild({bool force = false}) {
    if (_vodVariantIndexBuilding) return;
    final stamp = _vodPoolStamp;
    if (_vodVariantIndex != null && _vodVariantBuiltStamp == stamp) return;
    if (_vodStreamCache.isEmpty && catalog.isEmpty) return;
    if (!force && !_allowOpportunisticVodIndex) {
      _vodVariantIndexDeferred = true;
      return;
    }
    // Explicit Catalog/detail awaits cancel a focus-deferred timer.
    _vodVariantIndexResumeTimer?.cancel();
    _vodVariantIndexResumeTimer = null;
    _vodVariantIndexDeferred = false;
    _vodVariantIndexBuilding = true;
    final build = _finishVodVariantIndexBuild(stamp: stamp);
    _vodVariantIndexBuildFuture = build;
    unawaited(build);
  }

  Future<void> _finishVodVariantIndexBuild({required int stamp}) async {
    final watch = Stopwatch()..start();
    final slice = Stopwatch()..start();
    var reschedule = false;
    Future<void> yieldIfNeeded() =>
        yieldUiIfDue(slice, label: 'vod-variant-index');

    try {
      await UiStallWatchdog.span('vod-index', () async {
        // Prefer finishing the group index first so Catalog Movies shelves can
        // use category buckets instead of full-cache walks during this build.
        final groupBuild = _vodIndexBuildFuture;
        if (groupBuild != null) await groupBuild;
        if (stamp != _vodPoolStamp) return;

        final map = <String, MediaItem>{};
        void add(MediaItem m) {
          if (_isVodMovieFamilyItem(m)) map[m.id] = m;
        }

        var i = 0;
        // Keys-only snapshot — avoid a parallel ~200k MediaItem list after hydrate.
        final keys = _vodStreamCache.keys.toList(growable: false);
        final checkMask = keys.length > 50000 ? 31 : 63;
        for (final id in keys) {
          if (stamp != _vodPoolStamp) return;
          final m = _vodStreamCache[id];
          if (m == null) continue;
          add(m);
          if ((++i & checkMask) == 0) await yieldIfNeeded();
        }
        i = 0;
        for (final m in catalog) {
          add(m);
          if ((++i & checkMask) == 0) await yieldIfNeeded();
        }
        i = 0;
        for (final m in vodCategoryItems) {
          add(m);
          if ((++i & checkMask) == 0) await yieldIfNeeded();
        }
        if (stamp != _vodPoolStamp) return;
        final pool = map.values.toList(growable: false);
        await pumpUi();
        slice.reset();
        if (stamp != _vodPoolStamp) return;

        // Pack only sendable fields — full MediaItem graphs crash Windows isolates.
        final rows = <Map<String, Object?>>[];
        i = 0;
        for (final item in pool) {
          if (stamp != _vodPoolStamp) return;
          rows.add(VodVariantIndex.packRow(item));
          if ((++i & checkMask) == 0) await yieldIfNeeded();
        }
        if (stamp != _vodPoolStamp) return;

        final packed = await VodVariantIndex.buildInIsolate(rows);
        slice.reset();
        await pumpUi();
        if (stamp != _vodPoolStamp) return;

        final rawFamilies = Map<Object?, Object?>.from(
          packed['families']! as Map,
        );
        final rawCanonical = Map<Object?, Object?>.from(
          packed['canonical']! as Map,
        );

        final index = <String, List<String>>{};
        i = 0;
        for (final entry in rawFamilies.entries) {
          if (stamp != _vodPoolStamp) return;
          final key = '${entry.key}';
          final ids = [
            for (final id in List<Object?>.from(entry.value! as List)) '$id',
          ];
          if (ids.isEmpty) continue;
          index[key] = ids;
          if ((++i & 127) == 0) await yieldIfNeeded();
        }
        final canonical = <String, String>{};
        i = 0;
        for (final e in rawCanonical.entries) {
          canonical['${e.key}'] = '${e.value}';
          if ((++i & 127) == 0) await yieldIfNeeded();
        }
        if (stamp != _vodPoolStamp) return;
        // Same mid-batch growth check as the group index — avoid publishing a
        // Versions map that omits rows added during this stamp.
        if (_vodStreamCache.length != keys.length) {
          reschedule = true;
          return;
        }

        _vodPoolCache = pool;
        _vodPoolBuiltStamp = stamp;
        _vodVariantIndex = index;
        _vodGroupCanonical = canonical;
        _vodVariantStaleIndex = null;
        _vodVariantStaleCanonical = null;
        _vodVariantBuiltStamp = stamp;
        _vodVariantIndexLastBuiltAt = DateTime.now();
        _vodVariantIndexDeferred = false;
        await pumpUi();
        _invalidateHomeShelfCaches();
        // Idle fan-out — publishing during Home scroll hitchs shelves (journals:
        // tags=vod with 20–50ms frames while scrolling after load).
        if (!_disposed) _notifyListenersAfterIdle();
        JavpLog.slow(
          'vod',
          'variant index in ${watch.elapsedMilliseconds}ms '
              'items=${pool.length} isolate=true',
          watch.elapsedMilliseconds,
        );
      });
    } catch (e) {
      JavpLog.w('vod', 'variant index build failed', error: e);
    } finally {
      _vodVariantIndexBuilding = false;
      // Stamp mismatch (enrichment / cache touch mid-build) must restart —
      // otherwise [_scheduleVodVariantIndexBuild] no-ops while building and
      // Catalog keeps a cleared or pre-identity index until a later revision.
      if (reschedule || stamp != _vodPoolStamp) {
        _scheduleVodVariantIndexBuild(force: true);
      } else if (_vodVariantIndexDeferred) {
        // Don't immediately restart a 160k build on the focus frame — coalesce.
        _scheduleDeferredVodVariantIndexResume(reason: 'index-finally');
      }
    }
  }

  void _buildVodVariantIndexSync({
    required int stamp,
    required List<MediaItem> pool,
  }) {
    final primary = <String, List<MediaItem>>{};
    final orphans = <MediaItem>[];
    for (final item in pool) {
      final key = VodGrouping.groupKey(item);
      if (key == null) {
        orphans.add(item);
      } else {
        primary.putIfAbsent(key, () => []).add(item);
      }
    }
    final built = _finalizeVodVariantIndex(primary: primary, orphans: orphans);
    for (final key in built.index.keys.toList()) {
      final members = built.index[key]!;
      if (members.length <= 1) continue;
      final byId = <String, MediaItem>{for (final m in members) m.id: m};
      final list = byId.values.toList()..sort(VodGrouping.compareVariants);
      built.index[key] = list;
    }
    _vodVariantIndex = {
      for (final e in built.index.entries)
        e.key: [for (final m in e.value) m.id],
    };
    _vodGroupCanonical = built.canonical;
    _vodVariantStaleIndex = null;
    _vodVariantStaleCanonical = null;
    _vodVariantBuiltStamp = stamp;
  }

  /// Alias merge + canonical map (sync path for small libraries).
  ({Map<String, List<MediaItem>> index, Map<String, String> canonical})
  _finalizeVodVariantIndex({
    required Map<String, List<MediaItem>> primary,
    required List<MediaItem> orphans,
    Map<String, Set<String>>? aliasClaimants,
  }) {
    // Identity families claim title aliases. Only honor an alias when exactly
    // one identity family claims it — otherwise "Belle" (many TMDB ids/years)
    // would glue unrelated films into one versions list.
    final claimants = aliasClaimants ?? <String, Set<String>>{};
    if (aliasClaimants == null) {
      for (final entry in primary.entries) {
        if (!VodGrouping.isIdentityGroupKey(entry.key)) continue;
        for (final item in entry.value) {
          for (final alias in VodGrouping.nameGroupAliases(item)) {
            claimants.putIfAbsent(alias, () => {}).add(entry.key);
          }
        }
      }
    }
    final nameToCanonical = <String, String>{
      for (final e in claimants.entries)
        if (e.value.length == 1) e.key: e.value.single,
    };

    String? identityTargetFor(Iterable<MediaItem> items, String primaryKey) {
      final direct = nameToCanonical[primaryKey];
      if (direct != null) return direct;
      String? target;
      for (final item in items) {
        for (final alias in VodGrouping.nameGroupAliases(item)) {
          final hit = nameToCanonical[alias];
          if (hit == null) continue;
          if (target != null && target != hit) {
            // Conflicting identity claims — keep the weaker primary key.
            return null;
          }
          target = hit;
        }
      }
      return target;
    }

    final canonical = <String, String>{};
    final index = <String, List<MediaItem>>{};
    for (final entry in primary.entries) {
      // Promote name / same-source keys into a unique identity family when
      // aliases agree; never invent cross-source title-only merges.
      final target = identityTargetFor(entry.value, entry.key) ?? entry.key;
      canonical[entry.key] = target;
      index.putIfAbsent(target, () => []).addAll(entry.value);
    }
    for (final e in nameToCanonical.entries) {
      canonical[e.key] = e.value;
    }

    // Attach yearless orphans only when a unique identity family claims
    // their bare title (e.g. one SampleTitle TMDB row + EN| SampleTitle IPTV).
    for (final item in orphans) {
      String? target;
      for (final alias in VodGrouping.nameGroupAliases(item)) {
        final hit = nameToCanonical[alias];
        if (hit != null) {
          target = hit;
          break;
        }
      }
      if (target == null) continue;
      index.putIfAbsent(target, () => []).add(item);
      for (final alias in VodGrouping.nameGroupAliases(item)) {
        canonical.putIfAbsent(alias, () => target!);
      }
    }

    return (index: index, canonical: canonical);
  }

  Map<String, String>? get _activeVodCanonical =>
      _vodGroupCanonical ?? _vodVariantStaleCanonical;

  Map<String, List<String>>? get _activeVodIndex =>
      _vodVariantIndex ?? _vodVariantStaleIndex;

  /// Resolve a Versions member without walking the full VOD graph.
  MediaItem? _vodItemById(String id) {
    return _vodStreamCache[id] ??
        _vodCategoryItemById(id) ??
        _catalogVodItemById(id);
  }

  MediaItem? _vodCategoryItemById(String id) {
    for (final m in vodCategoryItems) {
      if (m.id == id) return m;
    }
    return null;
  }

  MediaItem? _catalogVodItemById(String id) {
    for (final m in catalog) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Merge a worker-built Versions id index (M3U packed ingest).
  void _mergePackedVodVariantIndex(VodIngestPlan plan) {
    final index = <String, List<String>>{
      ...?_vodVariantStaleIndex,
      ...?_vodVariantIndex,
    };
    index.addAll(plan.families);
    _vodVariantIndex = index;
    final canonical = <String, String>{
      ...?_vodVariantStaleCanonical,
      ...?_vodGroupCanonical,
    };
    canonical.addAll(plan.canonical);
    _vodGroupCanonical = canonical;
    _vodVariantStaleIndex = null;
    _vodVariantStaleCanonical = null;
    _vodVariantBuiltStamp = _vodPoolStamp;
    _vodVariantIndexLastBuiltAt = DateTime.now();
    _vodVariantIndexDeferred = false;
  }

  /// Persist [plan] for [sourceId]. See [VodIngestPlan] for replace vs upsert.
  Future<void> _applyVodPlan({
    required String sourceId,
    required VodIngestPlan plan,
    required bool replace,
  }) => UiStallWatchdog.span(
    'vod-apply',
    () => _applyVodPlanInner(sourceId: sourceId, plan: plan, replace: replace),
  );

  Future<void> _applyVodPlanInner({
    required String sourceId,
    required VodIngestPlan plan,
    required bool replace,
  }) async {
    if (kIsWeb) return;
    if (!replace && plan.rows.isEmpty) return;
    await _enableVodDb(reason: replace ? 'vod-ingest' : 'vod-upsert');
    if (!_useVodDb) return;
    if (replace) {
      final publishWatch = Stopwatch()..start();
      var hasPublished = false;
      var lastPublishedMs = 0;
      var lastGroupCacheMs = 0;
      JavpLog.i(
        'vod',
        'progressive replace start source=$sourceId rows=${plan.rows.length}',
      );
      await _vodDb.replaceSourceVodPacked(
        sourceId: sourceId,
        rows: plan.rows,
        onProgress: (progress) {
          final elapsed = publishWatch.elapsedMilliseconds;
          if (!progress.finalized &&
              hasPublished &&
              elapsed - lastPublishedMs < 750) {
            return;
          }
          hasPublished = true;
          lastPublishedMs = elapsed;
          vodDbRevision++;
          _vodCacheRevision++;
          _vodPoolCache = null;
          _vodSearchHayById = null;
          _vodSearchHayRevision = null;
          _invalidateHomeShelfCaches();
          _setSourceSyncStatus(
            sourceId,
            _uiL10n.sourceSyncSavingVod(
              '${progress.committed} / ${progress.total}',
            ),
          );
          // Group chips / vodCacheCount stay stale if we wait for finalize.
          // SQLite FFI is sync, so do this less often than poster revisions.
          if (!progress.finalized &&
              (lastGroupCacheMs == 0 || elapsed - lastGroupCacheMs >= 2000)) {
            lastGroupCacheMs = elapsed;
            unawaited(() async {
              await _refreshVodDbCountCache();
              await _refreshVodDbGroupCache();
            }());
          }
          // Progressive commits are deliberately visible through quiet mode:
          // Catalog can retry page reads without waking every ingest listener
          // for every 400-row transaction.
          _notifyPierceQuiet();
          // Debounced — lets unmatched Simkl shells find titles mid-ingest.
          _scheduleTrackerRelinkOnCatalogGrowth(
            reason: 'vod-progress:$sourceId',
          );
        },
      );
      JavpLog.i(
        'vod',
        'progressive replace done source=$sourceId rows=${plan.rows.length} '
            'elapsedMs=${publishWatch.elapsedMilliseconds}',
      );
      if (plan.rows.isEmpty) {
        _vodDbSourceIds.remove(sourceId);
      } else {
        _vodDbSourceIds.add(sourceId);
      }
      _scheduleTrackerRelinkOnCatalogGrowth(reason: 'vod-replace:$sourceId');
    } else {
      await _vodDb.upsertItemsPacked(plan.rows);
      _vodDbSourceIds.add(sourceId);
      if (plan.rows.isNotEmpty) {
        _scheduleTrackerRelinkOnCatalogGrowth(reason: 'vod-upsert:$sourceId');
      }
    }
    await _refreshVodDbCountCache();
    vodDbRevision++;
    _vodCacheRevision++;
    _vodPoolCache = null;
    _vodSearchHayById = null;
    _vodSearchHayRevision = null;
    _mergePackedVodVariantIndex(plan);
    await rebuildVodGroupIndexCoalesced();
    _invalidateHomeShelfCaches();
    _notifyPierceQuiet();
  }

  /// Pack leftover [MediaItem] VOD/series into a [VodIngestPlan] and persist.
  ///
  /// Use this only when the fetch path still returns items (small custom
  /// dumps, media-server pages, query-API browse). Worker-packed plans go
  /// straight to [_applyVodPlan].
  Future<({List<MediaItem> rest, int count})> _takeImportedVodToSqlite({
    required String sourceId,
    required List<MediaItem> imported,
    required bool replace,
  }) async {
    if (kIsWeb) return (rest: imported, count: -1);
    final vod = <MediaItem>[];
    final rest = <MediaItem>[];
    for (final item in imported) {
      if (item.kind == MediaKind.vod || item.kind == MediaKind.series) {
        vod.add(item);
      } else {
        rest.add(item);
      }
    }
    if (vod.isEmpty && !replace) return (rest: imported, count: -1);
    await _enableVodDb(reason: 'vod-ingest');
    if (!_useVodDb) return (rest: imported, count: -1);
    final plan = await buildVodIngestPlanYielding(
      vod,
      fallbackSourceId: sourceId,
    );
    await _applyVodPlan(sourceId: sourceId, plan: plan, replace: replace);
    return (rest: rest, count: plan.vodCount);
  }

  /// Catalog rows keyed by TMDB/IMDb and year-qualified title aliases.
  ///
  /// Custom catalogs are usually thousands of rows, not the 100k Xtream cache,
  /// so this can join IPTV `name:title|year` families to catalog TMDB ids
  /// without waiting for a full isolate rebuild.
  ({Map<String, List<MediaItem>> byKey, Map<String, String> aliasCanonical})
  _catalogIdentityLookup() {
    final stamp = Object.hash(
      catalog.length,
      identityHashCode(catalog),
      sourcesEnabledRevision,
    );
    final cached = _catalogIdentityCache;
    if (cached != null && _catalogIdentityStamp == stamp) return cached;

    final byKey = <String, List<MediaItem>>{};
    final identityClaimants = <String, Set<String>>{};
    void addKey(String key, MediaItem m) {
      byKey.putIfAbsent(key, () => []).add(m);
    }

    for (final m in catalog) {
      if (!_isVodMovieFamilyItem(m)) continue;
      if (!isSourceVodContentVisible(m.sourceId)) continue;
      final primary = VodGrouping.groupKey(m);
      if (primary != null) addKey(primary, m);
      if (primary != null && VodGrouping.isIdentityGroupKey(primary)) {
        for (final alias in VodGrouping.nameGroupAliases(m)) {
          if (!alias.contains('|')) continue;
          identityClaimants.putIfAbsent(alias, () => {}).add(primary);
          addKey(alias, m);
        }
      } else {
        for (final alias in VodGrouping.nameGroupAliases(m)) {
          if (alias.contains('|')) addKey(alias, m);
        }
      }
    }
    final built = (
      byKey: byKey,
      aliasCanonical: <String, String>{
        for (final e in identityClaimants.entries)
          if (e.value.length == 1) e.key: e.value.single,
      },
    );
    _catalogIdentityCache = built;
    _catalogIdentityStamp = stamp;
    return built;
  }

  /// Family key after merging identity-enriched and name-only siblings.
  String? canonicalVodGroupKey(MediaItem item) {
    if (_homeRevealSettled || catalog.length < VodVariantIndex.isolateMinRows) {
      _ensureVodVariantIndex();
    }
    final canonicalMap = _activeVodCanonical;
    final catalogAliases =
        (_homeRevealSettled || catalog.length < VodVariantIndex.isolateMinRows)
        ? _catalogIdentityLookup().aliasCanonical
        : const <String, String>{};
    final primary = VodGrouping.groupKey(item);
    if (primary != null) {
      return canonicalMap?[primary] ?? catalogAliases[primary] ?? primary;
    }
    // Ambiguous yearless row: join only if a unique family claimed its alias.
    for (final alias in VodGrouping.nameGroupAliases(item)) {
      final mapped = canonicalMap?[alias] ?? catalogAliases[alias];
      if (mapped != null) return mapped;
    }
    return null;
  }

  /// Search chips: indexed family plus raw hits that share the same movie.
  ///
  /// Collapse removes sibling rows from the list; the picker still needs every
  /// `FR|` / catalog edition that matched the query. Call once per search
  /// update — not from each list row.
  Map<String, List<MediaItem>> vodSearchFamilyIndex(List<MediaItem> hits) {
    final byId = <String, MediaItem>{};
    for (final item in hits) {
      if (item.kind != MediaKind.vod || item.isSeries || item.isEpisode) {
        continue;
      }
      byId[item.id] = item;
      for (final sibling in vodVariantsFor(item)) {
        byId.putIfAbsent(sibling.id, () => sibling);
      }
    }
    if (byId.isEmpty) return const {};
    final clustered = VodVariantIndex.clusterItems(byId.values.toList());
    final out = <String, List<MediaItem>>{};
    for (final entry in clustered.families.entries) {
      final members = <MediaItem>[
        for (final id in entry.value)
          if (byId[id] != null) byId[id]!,
      ];
      if (members.isEmpty) continue;
      members.sort(
        (a, b) => VodGrouping.compareVariants(
          a,
          b,
          preferredLangs: _preferredContentLangs,
        ),
      );
      for (final m in members) {
        out[m.id] = members;
      }
    }
    return out;
  }

  /// Remember clustered Search/FTS families for [vodVariantsFor] / title page.
  ///
  /// Does not shrink an existing family. [notify] is off when Search is already
  /// inside `setState`; title-page sqlite hydrate turns it on.
  void mergeVodSearchFamilyOverlay(
    Map<String, List<MediaItem>> index, {
    bool notify = false,
  }) {
    if (index.isEmpty) return;
    var changed = false;
    if (_vodFamilyOverlay.length + index.length > _vodFamilyOverlayCap) {
      _vodFamilyOverlay = {};
      // Forget hydrate keys for the wiped families so sqlite-only IPTV
      // editions can return on the next title open instead of the early-out.
      _vodFamilyHydratedKeys.clear();
      changed = true;
    }
    for (final entry in index.entries) {
      final incoming = entry.value;
      if (incoming.isEmpty) continue;
      final prev = _vodFamilyOverlay[entry.key];
      if (prev == null) {
        _vodFamilyOverlay[entry.key] = incoming;
        changed = true;
        continue;
      }
      if (prev.length >= incoming.length) {
        var missing = false;
        final seen = {for (final m in prev) m.id};
        for (final m in incoming) {
          if (seen.add(m.id)) missing = true;
        }
        if (!missing) continue;
        final byId = {for (final m in prev) m.id: m};
        for (final m in incoming) {
          byId[m.id] = m;
        }
        _vodFamilyOverlay[entry.key] = byId.values.toList(growable: false);
        changed = true;
      } else {
        _vodFamilyOverlay[entry.key] = incoming;
        changed = true;
      }
    }
    if (changed) {
      _vodFamilyOverlayRevision++;
      if (notify) notifyListeners();
    }
  }

  /// Overlay payload for a title-page sqlite hydrate.
  ///
  /// [vodSearchFamilyIndex] clusters every FTS hit; storing all of those
  /// families is what used to trip the 800-entry cap after a few title opens.
  @visibleForTesting
  Map<String, List<MediaItem>> vodHydrateOverlayIndex(
    MediaItem item,
    List<MediaItem> ftsHits,
  ) {
    final clustered = vodSearchFamilyIndex([item, ...ftsHits]);
    final family = clustered[item.id];
    if (family == null || family.isEmpty) return const {};
    return {for (final m in family) m.id: family};
  }

  /// Idle sqlite family hydrate for cards already on Accueil.
  ///
  /// FTS runs off the UI isolate (sqflite). Overlay merge is cheap; tiles
  /// already [select] [vodFamilyOverlayRevision] so chips update without
  /// bumping [homeShelfContentStamp] / rematerializing the shelf tree.
  void _enqueueHomeFamilyHydrate(Iterable<MediaItem> items) {
    if (!_useVodDb || _disposed) return;
    var added = false;
    for (final item in items) {
      if (!_isVodMovieFamilyItem(item)) continue;
      if (_homeFamilyHydrateQueuedIds.contains(item.id)) continue;
      final key =
          canonicalVodGroupKey(item) ?? VodGrouping.groupKey(item) ?? item.id;
      if (_vodFamilyHydratedKeys.contains(key) ||
          _vodFamilyHydratingKeys.contains(key)) {
        continue;
      }
      _homeFamilyHydrateQueuedIds.add(item.id);
      _homeFamilyHydrateQueue.add(item);
      added = true;
    }
    if (added) _scheduleHomeFamilyHydratePump();
  }

  void _scheduleHomeFamilyHydratePump() {
    if (_disposed || _homeFamilyHydrateScheduled || _homeFamilyHydratePumping) {
      return;
    }
    if (_homeFamilyHydrateQueue.isEmpty) return;
    _homeFamilyHydrateScheduled = true;
    SchedulerBinding.instance.scheduleTask(() {
      _homeFamilyHydrateScheduled = false;
      if (_disposed) return;
      unawaited(_pumpHomeFamilyHydrate());
    }, Priority.idle);
  }

  Future<void> _pumpHomeFamilyHydrate() async {
    if (_homeFamilyHydratePumping || _disposed) return;
    _homeFamilyHydratePumping = true;
    final startRev = _vodFamilyOverlayRevision;
    var n = 0;
    try {
      while (_homeFamilyHydrateQueue.isNotEmpty && !_disposed) {
        if (!_allowIdleBackgroundWork) break;
        final item = _homeFamilyHydrateQueue.removeAt(0);
        _homeFamilyHydrateQueuedIds.remove(item.id);
        await hydrateVodFamilyFromDb(item, notify: false);
        n++;
        if (n % 4 == 0 && _vodFamilyOverlayRevision != startRev) {
          _notifyListenersAfterIdle();
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _homeFamilyHydratePumping = false;
    }
    if (_disposed) return;
    if (_vodFamilyOverlayRevision != startRev) {
      _notifyListenersAfterIdle();
    }
    if (_homeFamilyHydrateQueue.isNotEmpty && _allowIdleBackgroundWork) {
      _scheduleHomeFamilyHydratePump();
    }
  }

  /// Search chips for one collapsed card. Prefers [vodSearchFamilyIndex].
  List<MediaItem> vodVariantsForSearch(
    MediaItem item, {
    List<MediaItem> extraHits = const [],
    Map<String, List<MediaItem>>? familyIndex,
  }) {
    final indexed = familyIndex?[item.id];
    if (indexed != null && indexed.isNotEmpty) return indexed;
    if (extraHits.isEmpty) return vodVariantsFor(item);
    return vodSearchFamilyIndex([item, ...extraHits])[item.id] ??
        vodVariantsFor(item);
  }

  /// How many distinct playable editions share this Films/Search family.
  int vodVariantCountFor(MediaItem item) => vodVariantsFor(item).length;

  /// How many library sources contribute editions of this title.
  int vodSourceCountFor(MediaItem item) {
    final ids = <String>{};
    for (final v in vodVariantsFor(item)) {
      final sid = v.sourceId?.trim();
      if (sid != null && sid.isNotEmpty) ids.add(sid);
    }
    return ids.length;
  }

  /// Shelf chip: single source name, or "N sources" when editions span catalogs.
  ///
  /// Uses the same visible movie family as [vodVariantsFor] / title detail
  /// Versions — never advertise sources the detail screen will not list.
  ///
  /// Tracker shells and Simkl episode-progress rows never show a generic type
  /// label ("URL", "Custom catalog") — that falsely attributes tracker counts
  /// to a catalog the user may not have (or a pasted-URL origin on shells).
  String shelfSourceLabelFor(MediaItem item) {
    if (isTrackerListShell(item)) return sourceLabelFor(item);
    if (!_isVodMovieFamilyItem(item)) {
      return _shelfLabelAvoidingGenericTrackerAttribution(item);
    }
    final n = vodSourceCountFor(item);
    if (n > 1) return _uiL10n.nSources(n);
    return _shelfLabelAvoidingGenericTrackerAttribution(item);
  }

  VodFamilyLayout vodFamilyLayoutFor(MediaItem item) {
    return VodGrouping.familyLayout(
      vodVariantsFor(item),
      preferredLangs: _preferredContentLangs,
      sourceLabelFor: sourceLabelFor,
    );
  }

  List<MediaItem> distinctDownloadEditionsFor(MediaItem item) {
    return vodFamilyLayoutFor(item).editions;
  }

  String _shelfLabelAvoidingGenericTrackerAttribution(MediaItem item) {
    final label = sourceLabelFor(item);
    if (!_looksLikeSimklEpisodeProgress(item)) return label;
    if (!_isGenericOriginSourceLabel(label)) return label;
    // Linked catalog row still carrying Simkl "11/13 eps" — prefer SIMKL over
    // a placeholder type name when the real catalog display name is unknown.
    if (item.tags.contains('simkl-watching') ||
        item.id.startsWith('simkl:') ||
        item.simklId != null) {
      return 'SIMKL';
    }
    return label;
  }

  static bool _looksLikeSimklEpisodeProgress(MediaItem item) {
    final sub = item.subtitle?.trim() ?? '';
    if (RegExp(r'\d+\s*/\s*\d+\s*eps', caseSensitive: false).hasMatch(sub)) {
      return true;
    }
    // Progress-only shells / links without a subtitle still use Simkl ratios.
    return item.tags.contains('simkl-watching') &&
        item.progress > 0.02 &&
        item.progress < 0.99 &&
        item.isSeries;
  }

  bool _isGenericOriginSourceLabel(String label) {
    final l10n = _uiL10n;
    switch (label) {
      case 'Custom catalog':
      case 'URL':
      case 'M3U':
      case 'Xtream':
      case 'Stalker':
      case 'Local file':
      case 'Torrent':
      case 'Jellyfin':
      case 'Emby':
      case 'Plex':
      case 'Download':
        return true;
      default:
        return label == l10n.originCustomCatalog ||
            label == l10n.url ||
            label == l10n.originLocalFile ||
            label == l10n.originTorrent ||
            label == l10n.originDownload;
    }
  }

  /// Home Films/Series: collapse language/source siblings, keep order, cap size.
  ///
  /// Recommendations + My List + catalog preview used to dedupe by [MediaItem.id]
  /// only — so "SampleTitle" from two sources (or EN|/FR|) became separate cards.
  List<MediaItem> collapseHomeShelfItems(
    Iterable<MediaItem> items, {
    int limit = 18,
  }) {
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final item in items) {
      if (item.isLive || item.kind == MediaKind.catchup) {
        if (!isSourceContentVisible(item.sourceId)) continue;
      } else if (!isSourceVodContentVisible(item.sourceId)) {
        continue;
      }
      final key = _searchDedupeKey(item);
      if (!seen.add(key)) continue;
      if (_isVodMovieFamilyItem(item)) {
        out.add(resolveVodVariant(item));
      } else {
        out.add(item);
      }
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Open another encode in the family for [lang].
  ///
  /// Prefers the same quality (and source) as [current], then any encode
  /// that carries that audio/sub. Movies swap sibling URLs. Episodes prefer
  /// catalog [EpisodePlayVariant] rows, then a sibling series shell.
  Future<MediaItem?> switchToLanguageEdition({
    required MediaItem current,
    required String lang,
    required bool audio,
  }) async {
    final code = lang.trim().toLowerCase();
    if (code.isEmpty) return null;

    if (current.isEpisode) {
      final variants = playVariantsForEpisodeItem(current);
      EpisodePlayVariant? match;
      EpisodePlayVariant? multi;
      for (final v in variants) {
        final langs = audio ? v.audioLanguages : v.subtitleLanguages;
        final normalized = [
          for (final e in langs)
            if (e.trim().isNotEmpty) e.trim().toLowerCase(),
        ];
        if (normalized.contains(code)) {
          match = v;
          break;
        }
        if (multi == null && normalized.contains('multi')) multi = v;
      }
      final chosen = match ?? multi;
      if (chosen != null &&
          chosen.playUrl.trim().isNotEmpty &&
          chosen.playUrl != current.playUrl) {
        return switchEpisodeVariant(current, chosen);
      }

      final series =
          findSeriesShell(current.seriesId ?? '') ??
          _seriesShellByExternalIds(current);
      if (series == null) return null;
      final layout = vodFamilyLayoutFor(series);
      final siblingShell = audio
          ? layout.editionForAudio(
              code,
              preferNear: series,
              preferredLangs: _preferredContentLangs,
            )
          : layout.editionForSubtitle(
              code,
              preferNear: series,
              preferredLangs: _preferredContentLangs,
            );
      if (siblingShell == null || siblingShell.id == series.id) return null;
      final info = await loadSeriesInfo(siblingShell);
      final hit = info.episodeAt(
        seasonNumber: current.seasonNumber ?? 1,
        episodeNum: current.episodeNumber ?? 0,
      );
      if (hit == null) return null;
      await setPreferredVodVariant(siblingShell);
      return episodeMediaItem(series: siblingShell, episode: hit);
    }

    final layout = vodFamilyLayoutFor(current);
    final next = audio
        ? layout.editionForAudio(
            code,
            preferNear: current,
            preferredLangs: _preferredContentLangs,
          )
        : layout.editionForSubtitle(
            code,
            preferNear: current,
            preferredLangs: _preferredContentLangs,
          );
    if (next == null || next.id == current.id) return null;
    await setPreferredVodVariant(next);
    return next;
  }

  Future<SeriesInfo> loadSeriesInfo(MediaItem series) {
    return _runUserFacing(() async {
      final info = await _loadSeriesInfoRaw(series);
      // Tracker import progress → local episode watched flags (quiet).
      await _applyInboundTrackerEpisodeProgress(series, info);
      return info;
    });
  }

  /// Fill missing episode stills from the active metadata provider, then TMDB.
  ///
  /// Catalog / Xtream playUrls are unchanged. Fetches only seasons that still
  /// need stills (prefer [seasonNumber] when set).
  Future<SeriesInfo> enrichSeriesEpisodeArt(
    MediaItem series,
    SeriesInfo info, {
    int? seasonNumber,
  }) async {
    var next = info;
    if (metadataSettings.provider == MetadataProviderId.simkl) {
      next = await _overlaySimklEpisodeArt(
        series,
        next,
        seasonNumber: seasonNumber,
      );
    } else if (metadataSettings.provider == MetadataProviderId.trakt) {
      next = await _overlayTraktEpisodeArt(
        series,
        next,
        seasonNumber: seasonNumber,
      );
    }
    if (tmdb.isConfigured) {
      next = await enrichSeriesEpisodeArtFromTmdb(
        series,
        next,
        seasonNumber: seasonNumber,
      );
    }
    return next;
  }

  /// Fill missing episode stills from TMDB season payloads when a key is set.
  ///
  /// Catalog / Xtream playUrls are unchanged. No-op without a configured TMDB
  /// key or when every episode already has unique art. Fetches only seasons
  /// that still need stills (prefer [seasonNumber] when set).
  Future<SeriesInfo> enrichSeriesEpisodeArtFromTmdb(
    MediaItem series,
    SeriesInfo info, {
    int? seasonNumber,
  }) async {
    if (!tmdb.isConfigured) return info;
    if (info.seasons.every((s) => s.episodes.isEmpty)) return info;

    final tmdbId = await _resolveSeriesTmdbId(series);
    if (tmdbId == null) return info;

    final targets = <int>[];
    for (final season in info.seasons) {
      if (seasonNumber != null && season.seasonNumber != seasonNumber) {
        continue;
      }
      if (season.episodes.isEmpty) continue;
      final needs = season.episodes.any(
        (ep) =>
            TmdbEpisodeStills.episodeNeedsTmdb(ep, series: series, info: info) ||
            ep.airDate == null,
      );
      if (needs) targets.add(season.seasonNumber);
    }
    if (targets.isEmpty) return info;

    var next = info;
    for (final sn in targets) {
      final stills = await _tmdbSeasonStills(tmdbId, sn);
      if (stills.isEmpty) continue;
      next = TmdbEpisodeStills.mergeSeason(next, sn, stills, series: series);
    }
    return next;
  }

  Future<SeriesInfo> _overlaySimklEpisodeArt(
    MediaItem series,
    SeriesInfo info, {
    int? seasonNumber,
  }) async {
    if (!simkl.isConfigured) return info;
    if (info.seasons.every((s) => s.episodes.isEmpty)) return info;
    final simklId = await _resolveSeriesSimklId(series);
    if (simklId == null || simklId.isEmpty) return info;
    // Prefer the kind stamped by detail enrichment (may be simkl-tv-* even when
    // the catalog row is tagged/grouped as anime). Heuristic only when unknown.
    final detailsId = detailsFor(series)?.id ?? '';
    final bool? resolvedAnime;
    if (detailsId.startsWith('simkl-anime-')) {
      resolvedAnime = true;
    } else if (detailsId.startsWith('simkl-tv-') ||
        detailsId.startsWith('simkl-movie-')) {
      resolvedAnime = false;
    } else {
      resolvedAnime = null;
    }
    final anime = resolvedAnime ?? MetadataMatch.looksLikeAnime(series);
    var all = await _simklEpisodeArt(simklId, anime: anime);
    if (all.isEmpty && resolvedAnime == null) {
      all = await _simklEpisodeArt(simklId, anime: !anime);
    }
    if (all.isEmpty) return info;
    final bySeason = <int, List<SeasonEpisodeArt>>{};
    for (final ep in all) {
      bySeason.putIfAbsent(ep.seasonNumber, () => []).add(ep);
    }
    var next = info;
    for (final season in info.seasons) {
      if (seasonNumber != null && season.seasonNumber != seasonNumber) {
        continue;
      }
      if (season.episodes.isEmpty) continue;
      final needs = season.episodes.any(
        (ep) =>
            EpisodeArtOverlay.episodeNeedsArt(ep, series: series, info: next),
      );
      if (!needs) continue;
      final stills = bySeason[season.seasonNumber];
      if (stills == null || stills.isEmpty) continue;
      next = EpisodeArtOverlay.mergeSeason(
        next,
        season.seasonNumber,
        stills,
        series: series,
      );
    }
    return next;
  }

  Future<SeriesInfo> _overlayTraktEpisodeArt(
    MediaItem series,
    SeriesInfo info, {
    int? seasonNumber,
  }) async {
    if (!trakt.isConfigured) return info;
    if (info.seasons.every((s) => s.episodes.isEmpty)) return info;
    final traktId = await _resolveSeriesTraktId(series);
    if (traktId == null || traktId.isEmpty) return info;
    var next = info;
    for (final season in info.seasons) {
      if (seasonNumber != null && season.seasonNumber != seasonNumber) {
        continue;
      }
      if (season.episodes.isEmpty) continue;
      final needs = season.episodes.any(
        (ep) =>
            EpisodeArtOverlay.episodeNeedsArt(ep, series: series, info: next),
      );
      if (!needs) continue;
      final stills = await _traktSeasonArt(traktId, season.seasonNumber);
      if (stills.isEmpty) continue;
      next = EpisodeArtOverlay.mergeSeason(
        next,
        season.seasonNumber,
        stills,
        series: series,
      );
    }
    return next;
  }

  Future<String?> _resolveSeriesSimklId(MediaItem series) async {
    final direct = series.simklId ?? detailsFor(series)?.simklId;
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final fromKey = _idFromDetailsKey(detailsFor(series)?.id, prefix: 'simkl-');
    if (fromKey != null) return fromKey;
    if (!simkl.isConfigured) return null;
    if (!MetadataMatch.shouldEnrich(
      origin: series.origin,
      enrichMediaServers: metadataSettings.enrichMediaServers,
    )) {
      return null;
    }
    try {
      final enriched = await _simklEnricher.enrich(series);
      final id = enriched?.simklId?.trim();
      if (id == null || id.isEmpty) return null;
      if (enriched != null) {
        final existing = detailsFor(series);
        var merged = existing != null
            ? MetadataMatch.overlayPresentation(existing, enriched)
            : enriched;
        merged = await _supplementWithTmdb(series, merged);
        await _cacheDetails(merged, notify: false);
        await _applyDetailsToCatalog(series, merged);
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveSeriesTraktId(MediaItem series) async {
    final direct = series.traktId ?? detailsFor(series)?.traktId;
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final fromKey = _idFromDetailsKey(detailsFor(series)?.id, prefix: 'trakt-');
    if (fromKey != null) return fromKey;
    if (!trakt.isConfigured) return null;
    if (!MetadataMatch.shouldEnrich(
      origin: series.origin,
      enrichMediaServers: metadataSettings.enrichMediaServers,
    )) {
      return null;
    }
    try {
      final enriched = await _traktEnricher.enrich(series);
      final id = enriched?.traktId?.trim();
      if (id == null || id.isEmpty) return null;
      if (enriched != null) {
        final existing = detailsFor(series);
        var merged = existing != null
            ? MetadataMatch.overlayPresentation(existing, enriched)
            : enriched;
        merged = await _supplementWithTmdb(series, merged);
        await _cacheDetails(merged, notify: false);
        await _applyDetailsToCatalog(series, merged);
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  static String? _idFromDetailsKey(
    String? detailsId, {
    required String prefix,
  }) {
    final id = detailsId?.trim() ?? '';
    if (!id.startsWith(prefix)) return null;
    for (final kind in ['movie-', 'tv-', 'anime-', 'show-']) {
      final full = '$prefix$kind';
      if (id.startsWith(full) && id.length > full.length) {
        final value = id.substring(full.length).trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  Future<List<SeasonEpisodeArt>> _simklEpisodeArt(
    String simklId, {
    required bool anime,
  }) {
    final key = '$simklId|${anime ? 'anime' : 'tv'}';
    final cached = _simklEpisodeArtCache[key];
    if (cached != null) return Future.value(cached);
    final inflight = _simklEpisodeArtInflight[key];
    if (inflight != null) return inflight;
    final future = () async {
      try {
        final rows = await _simklEnricher.fetchEpisodeArt(
          simklId,
          anime: anime,
        );
        _simklEpisodeArtCache[key] = rows;
        return rows;
      } catch (_) {
        _simklEpisodeArtCache[key] = const [];
        return const <SeasonEpisodeArt>[];
      } finally {
        _simklEpisodeArtInflight.remove(key);
      }
    }();
    _simklEpisodeArtInflight[key] = future;
    return future;
  }

  Future<List<SeasonEpisodeArt>> _traktSeasonArt(
    String traktId,
    int seasonNumber,
  ) {
    final key = '$traktId|$seasonNumber';
    final cached = _traktSeasonArtCache[key];
    if (cached != null) return Future.value(cached);
    final inflight = _traktSeasonArtInflight[key];
    if (inflight != null) return inflight;
    final future = () async {
      try {
        final rows = await _traktEnricher.fetchEpisodeArt(
          traktId,
          seasonNumber: seasonNumber,
        );
        _traktSeasonArtCache[key] = rows;
        return rows;
      } catch (_) {
        _traktSeasonArtCache[key] = const [];
        return const <SeasonEpisodeArt>[];
      } finally {
        _traktSeasonArtInflight.remove(key);
      }
    }();
    _traktSeasonArtInflight[key] = future;
    return future;
  }

  Future<int?> _resolveSeriesTmdbId(MediaItem series) async {
    final direct = series.tmdbId ?? detailsFor(series)?.tmdbId;
    if (direct != null && direct > 0) return direct;
    if (!tmdb.isConfigured) return null;
    if (!MetadataMatch.shouldEnrich(
      origin: series.origin,
      enrichMediaServers: metadataSettings.enrichMediaServers,
    )) {
      return null;
    }
    try {
      final enriched = await _tmdbEnricher.enrich(series);
      final id = enriched?.tmdbId;
      if (id == null || id <= 0) return null;
      if (enriched != null) {
        final existing = detailsFor(series);
        final merged = existing != null
            ? MetadataMatch.overlayPresentation(existing, enriched)
            : enriched;
        await _cacheDetails(merged, notify: false);
        await _applyDetailsToCatalog(series, merged);
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  Future<List<TmdbSeasonEpisode>> _tmdbSeasonStills(
    int tmdbId,
    int seasonNumber,
  ) {
    final key = '$tmdbId|$seasonNumber';
    final cached = _tmdbSeasonStillsCache[key];
    if (cached != null) return Future.value(cached);
    final inflight = _tmdbSeasonStillsInflight[key];
    if (inflight != null) return inflight;
    final future = () async {
      try {
        final rows = await _tmdb.fetchTvSeason(
          tmdb,
          tmdbId,
          seasonNumber: seasonNumber,
          language: TmdbEnricher.languageTag(),
        );
        _tmdbSeasonStillsCache[key] = rows;
        return rows;
      } catch (_) {
        _tmdbSeasonStillsCache[key] = const [];
        return const <TmdbSeasonEpisode>[];
      } finally {
        _tmdbSeasonStillsInflight.remove(key);
      }
    }();
    _tmdbSeasonStillsInflight[key] = future;
    return future;
  }

  Future<SeriesInfo> _loadSeriesInfoRaw(MediaItem series) async {
    if (series.streamId != null) {
      final source = sources.cast<IptvSource?>().firstWhere(
        (s) => s?.id == series.sourceId,
        orElse: () => null,
      );
      if (source != null && source.type == IptvSourceType.xtream) {
        return _xtream.fetchSeriesInfo(source, seriesId: series.streamId!);
      }
      if (source != null && source.type == IptvSourceType.stalker) {
        final info = await _stalker.fetchSeriesInfo(
          source,
          seriesId: series.streamId!,
        );
        return SeriesInfo(
          seriesId: info.seriesId,
          title: series.title,
          seasons: info.seasons,
          plot: info.plot,
          coverUrl: info.coverUrl,
          genre: info.genre,
          releaseDate: info.releaseDate,
          rating: info.rating,
          backdropUrl: info.backdropUrl,
        );
      }
    }

    // Custom catalog: prefer cached details (nested seasons or sibling episodes).
    // Query APIs (AniList/catalog, etc.) only return shells from /search — seasons
    // come from GET /items/{id}. Progressive shells may omit playUrl on episodes.
    if (series.origin == MediaOrigin.customCatalog) {
      final fromCatalog = await _seriesInfoFromCatalog(series);
      if (fromCatalog != null) {
        return fromCatalog;
      }
    }

    // Non-Xtream: build SeriesInfo from MediaDetails / TMDB.
    // Skip for custom catalog when shell fetch already ran (avoids a second
    // GET /items/{id} on open).
    final details = series.origin == MediaOrigin.customCatalog
        ? detailsCache[series.detailsId ?? series.id] ??
              detailsCache[series.id] ??
              detailsCache[series.streamId ?? '']
        : await loadMediaDetails(series);
    if (details == null) {
      throw Exception('Series details unavailable');
    }
    return _seriesInfoFromDetails(series, details);
  }

  /// Re-fetch series shell episode list (simulcast / new episodes).
  ///
  /// [force] bypasses the shell TTL (pull-to-refresh). Otherwise only hits the
  /// network when the cached shell is missing or older than
  /// [customCatalogShellTtl]. Already-resolved episode playUrls are kept when
  /// the bridge still returns stubs for those ids.
  Future<SeriesInfo> refreshSeriesInfo(MediaItem series, {bool force = false}) {
    return _runUserFacing(() => _refreshSeriesInfoBody(series, force: force));
  }

  Future<SeriesInfo> _refreshSeriesInfoBody(
    MediaItem series, {
    bool force = false,
  }) async {
    if (series.origin != MediaOrigin.customCatalog) {
      return loadSeriesInfo(series);
    }
    final source = _customCatalogSourceFor(series);
    if (source == null) return loadSeriesInfo(series);

    final remoteId = _customCatalogRemoteId(series);
    final key = _customCatalogShellKey(source, remoteId);
    final existing =
        detailsCache[series.detailsId ?? series.id] ??
        detailsCache[series.id] ??
        detailsCache[remoteId];

    late final SeriesInfo info;
    if (!force &&
        existing != null &&
        _seasonsHaveEpisodeRows(existing) &&
        !_isCustomCatalogShellStale(existing)) {
      info = _seriesInfoFromDetails(series, existing);
    } else {
      _customCatalogShellHydrated.remove(key);
      final refreshed = await _fetchCustomCatalogShell(
        item: series,
        source: source,
        remoteId: remoteId,
        cached: existing,
        shellKey: key,
        forceRefresh: true,
        mergeWith: existing,
      );
      if (refreshed == null) {
        if (existing != null) {
          info = _seriesInfoFromDetails(series, existing);
        } else {
          return loadSeriesInfo(series);
        }
      } else {
        info = _seriesInfoFromDetails(series, refreshed);
      }
    }
    await _applyInboundTrackerEpisodeProgress(series, info);
    return info;
  }

  bool _isCustomCatalogShellStale(MediaDetails details) {
    final updated = details.updatedAt;
    if (updated == null) return true;
    return DateTime.now().difference(updated) >= customCatalogShellTtl;
  }

  SeriesInfo _seriesInfoFromDetails(MediaItem series, MediaDetails details) {
    // Do not invent an empty "Season 1" — that flashes "No episodes" before
    // the real list lands. UI shows a loader while seasons are still empty.
    final seasons = details.seasons
        .map(
          (s) => SeriesSeason(
            seasonNumber: s.seasonNumber,
            name: s.name,
            coverUrl: s.posterUrl,
            episodes: s.episodes
                .map((e) => _seriesEpisodeFromDetails(series, e))
                .toList(),
          ),
        )
        .toList();
    return SeriesInfo(
      seriesId: series.streamId ?? series.seriesId ?? series.id,
      title: details.title.isNotEmpty ? details.title : series.title,
      seasons: seasons,
      plot: details.plot ?? series.plot,
      coverUrl: details.posterUrl ?? series.posterUrl,
      genre: (details.genres.isNotEmpty ? details.genres : series.genres).join(
        ', ',
      ),
      releaseDate:
          details.releaseDate ?? details.year?.toString() ?? series.releaseDate,
      rating: details.rating ?? series.rating,
      backdropUrl: details.backdropUrl ?? series.backdropUrl,
    );
  }

  SeriesEpisode _seriesEpisodeFromDetails(
    MediaItem series,
    SeriesEpisodeDetails e,
  ) {
    final cached =
        _customCatalogEpisodeResolveCache[_customCatalogEpisodeCacheKey(
          series.sourceId,
          e.id,
        )];
    if (cached != null) {
      return cached;
    }
    return SeriesEpisode(
      id: e.id,
      episodeNum: e.episodeNumber,
      seasonNumber: e.seasonNumber,
      title: e.title,
      containerExtension: 'mp4',
      plot: e.plot,
      thumbnailUrl: e.thumbnailUrl,
      duration: e.duration,
      airDate: e.airDate,
      playUrl: e.playUrl,
      torrentFile: e.torrentFile,
      resolution: e.resolution,
      playVariants: e.playVariants,
      httpHeaders: e.httpHeaders,
    );
  }

  String _customCatalogShellKey(IptvSource source, String remoteId) =>
      '${source.id}|shell|$remoteId';

  String _customCatalogEpisodeCacheKey(String? sourceId, String episodeId) =>
      '${sourceId ?? ''}|ep|$episodeId';

  String _customCatalogSeriesWarmKey(String? sourceId, String seriesId) =>
      '${sourceId ?? ''}|series|$seriesId';

  String _customCatalogBulkKey(
    String? sourceId,
    String seriesId,
    int seasonNumber,
  ) => '${sourceId ?? ''}|bulk|$seriesId|$seasonNumber';

  /// `Authorization: Bearer …` when the custom source has an access token.
  Map<String, String>? _customCatalogHeaders(IptvSource? source) =>
      CustomCatalogClient.authHeaders(source?.catalogAuthToken);

  Future<CatalogClientProfile> _catalogClientProfile() async {
    final version = await _currentAppVersion();
    return catalogClientProfileForDevice(appVersion: version);
  }

  Future<void> _applyCatalogClientProfile() async {
    _customCatalog.profile = await _catalogClientProfile();
  }

  /// True once this series filled at least one magnet this session, or local
  /// cache already has a playable episode (app-hot ⇒ treat bridge as warm).
  bool isCustomCatalogSeriesWarm(MediaItem series) {
    if (series.origin != MediaOrigin.customCatalog) return true;
    final seriesId = series.streamId ?? series.id;
    final key = _customCatalogSeriesWarmKey(series.sourceId, seriesId);
    if (_customCatalogSeriesBridgeWarm.contains(key)) return true;
    if (_seriesHasCachedPlayableEpisode(series)) {
      _customCatalogSeriesBridgeWarm.add(key);
      return true;
    }
    return false;
  }

  void _markCustomCatalogSeriesWarm(MediaItem series) {
    final seriesId = series.streamId ?? series.id;
    _customCatalogSeriesBridgeWarm.add(
      _customCatalogSeriesWarmKey(series.sourceId, seriesId),
    );
  }

  bool _seriesHasCachedPlayableEpisode(MediaItem series) {
    final details =
        detailsCache[series.detailsId ?? series.id] ??
        detailsCache[series.id] ??
        detailsCache[series.streamId ?? ''];
    if (details != null) {
      for (final season in details.seasons) {
        for (final ep in season.episodes) {
          final hasUrl =
              (ep.playUrl?.trim().isNotEmpty ?? false) ||
              ep.playVariants.any((v) => v.playUrl.trim().isNotEmpty);
          if (hasUrl) return true;
          final cached =
              _customCatalogEpisodeResolveCache[_customCatalogEpisodeCacheKey(
                series.sourceId,
                ep.id,
              )];
          if (cached != null && !cached.needsPlaybackResolve) return true;
        }
      }
    }
    final prefix = '${series.sourceId ?? ''}|ep|';
    for (final entry in _customCatalogEpisodeResolveCache.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      if (!entry.value.needsPlaybackResolve) return true;
    }
    return false;
  }

  IptvSource? _customCatalogSourceFor(MediaItem item) {
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null ||
        source.type != IptvSourceType.custom ||
        source.playlistUrl == null ||
        source.playlistUrl!.isEmpty) {
      return null;
    }
    return source;
  }

  String _customCatalogRemoteId(MediaItem item) {
    final streamId = item.streamId?.trim();
    if (streamId != null && streamId.isNotEmpty) return streamId;
    return item.id;
  }

  bool _seasonsHaveEpisodeRows(MediaDetails details) =>
      details.seasons.any((s) => s.episodes.isNotEmpty);

  /// Fetch series shell (cast / plot / season stubs) from a JAVP query catalog.
  ///
  /// Dedupes concurrent callers so opening a title does not fire two Dart GETs
  /// for the same `/items/{id}`. Does not resolve per-episode magnets.
  Future<MediaDetails?> _ensureCustomCatalogDetails(MediaItem item) async {
    final source = _customCatalogSourceFor(item);
    if (source == null) return null;
    final remoteId = _customCatalogRemoteId(item);
    final key = _customCatalogShellKey(source, remoteId);

    final existing =
        detailsCache[item.detailsId ?? item.id] ??
        detailsCache[item.id] ??
        detailsCache[remoteId];
    if (existing != null &&
        _seasonsHaveEpisodeRows(existing) &&
        !_legacySeasonsMissingPlayVariants(existing)) {
      return existing;
    }
    if (existing != null &&
        _customCatalogShellHydrated.contains(key) &&
        !_legacySeasonsMissingPlayVariants(existing)) {
      return existing;
    }

    final inflight = _customCatalogShellInflight[key];
    if (inflight != null) return inflight;

    final future = _fetchCustomCatalogShell(
      item: item,
      source: source,
      remoteId: remoteId,
      cached: existing,
      shellKey: key,
    );
    _customCatalogShellInflight[key] = future;
    try {
      return await future;
    } finally {
      _customCatalogShellInflight.remove(key);
    }
  }

  Future<MediaDetails?> _fetchCustomCatalogShell({
    required MediaItem item,
    required IptvSource source,
    required String remoteId,
    required String shellKey,
    MediaDetails? cached,
    bool forceRefresh = false,
    MediaDetails? mergeWith,
  }) async {
    try {
      MediaDetails? details = cached;
      // Re-use a cached shell (cast/plot/season stubs). Only re-GET /items/{id}
      // when we have nothing yet, a forced refresh (simulcast), or a legacy
      // cache missing playVariants.
      final mustRefetchItem =
          forceRefresh ||
          details == null ||
          _legacySeasonsMissingPlayVariants(details);
      if (mustRefetchItem) {
        final result = await _customCatalog.fetchItem(
          baseUrl: source.playlistUrl!,
          sourceId: source.id,
          id: remoteId,
          locale: _catalogLocaleParam,
          headers: _customCatalogHeaders(source),
        );
        if (result == null && details == null) {
          _customCatalogShellHydrated.add(shellKey);
          return null;
        }

        if (result != null) {
          details = result.details ?? details;
          if (mergeWith != null && details != null) {
            details = _mergeSeriesShellDetails(mergeWith, details);
          }
          final detailsById = <String, MediaDetails>{
            ...result.detailsById,
            if (details != null) details.id: details,
          };
          if (detailsById.isNotEmpty) {
            detailsCache = {...detailsCache, ...detailsById};
          }

          final playable = result.allItems
              .where((m) => m.playUrl.trim().isNotEmpty)
              .toList();
          if (playable.isNotEmpty) {
            final ids = playable.map((e) => e.id).toSet();
            catalog = [
              ...catalog.where(
                (m) => m.sourceId != source.id || !ids.contains(m.id),
              ),
              ...playable,
            ];
            await _store.saveCatalog(catalog);
          }
        }
      }

      // Shell omitted nested episodes → optional lazy list endpoint.
      if (details != null && !_seasonsHaveEpisodeRows(details)) {
        try {
          final seasons = await _customCatalog.fetchEpisodes(
            baseUrl: source.playlistUrl!,
            id: remoteId,
            locale: _catalogLocaleParam,
            headers: _customCatalogHeaders(source),
          );
          if (seasons.isNotEmpty) {
            final next = details.copyWith(seasons: seasons);
            details = mergeWith != null
                ? _mergeSeriesShellDetails(mergeWith, next)
                : next;
          }
        } catch (e, st) {
          debugPrint(
            'Custom catalog /items/$remoteId/episodes failed: $e\n$st',
          );
        }
      }

      if (details != null) {
        // Stamp freshness so TTL soft-revalidate knows when we last synced.
        details = details.copyWith(updatedAt: DateTime.now());
        await _cacheDetails(details);
      } else {
        _schedulePersist(_PersistTarget.detailsCache);
        notifyListeners();
      }

      _customCatalogShellHydrated.add(shellKey);
      return details ?? detailsCache[item.id] ?? detailsCache[remoteId];
    } catch (e, st) {
      debugPrint('Custom catalog /items/$remoteId failed: $e\n$st');
      return cached;
    }
  }

  /// Merge a freshly fetched shell into a cached one.
  ///
  /// Remote season/episode ids win for the list (new simulcast eps appear).
  /// Locally resolved playUrl / playVariants are kept when the remote row is
  /// still a stub — so refreshing does not throw away catalog resolves.
  MediaDetails _mergeSeriesShellDetails(
    MediaDetails local,
    MediaDetails remote,
  ) {
    if (remote.seasons.isEmpty) {
      return local.copyWith(
        title: remote.title.isNotEmpty ? remote.title : local.title,
        plot: remote.plot ?? local.plot,
        posterUrl: remote.posterUrl ?? local.posterUrl,
        backdropUrl: remote.backdropUrl ?? local.backdropUrl,
        cast: remote.cast.isNotEmpty ? remote.cast : local.cast,
        genres: remote.genres.isNotEmpty ? remote.genres : local.genres,
        rating: remote.rating ?? local.rating,
        year: remote.year ?? local.year,
        trailerUrl: remote.trailerUrl ?? local.trailerUrl,
        trailerKey: remote.trailerKey ?? local.trailerKey,
        tags: remote.tags.isNotEmpty ? remote.tags : local.tags,
        contentRating: remote.contentRating ?? local.contentRating,
        studio: remote.studio ?? local.studio,
        originalTitle: remote.originalTitle ?? local.originalTitle,
        releaseDate: remote.releaseDate ?? local.releaseDate,
        anilistId: remote.anilistId ?? local.anilistId,
        tmdbId: remote.tmdbId ?? local.tmdbId,
        updatedAt: DateTime.now(),
      );
    }

    final localById = <String, SeriesEpisodeDetails>{};
    for (final season in local.seasons) {
      for (final ep in season.episodes) {
        localById[ep.id] = ep;
      }
    }

    final seasons = <SeriesSeasonDetails>[];
    for (final season in remote.seasons) {
      final episodes = <SeriesEpisodeDetails>[];
      for (final remoteEp in season.episodes) {
        episodes.add(
          _mergeEpisodeStub(local: localById[remoteEp.id], remote: remoteEp),
        );
      }
      seasons.add(
        SeriesSeasonDetails(
          seasonNumber: season.seasonNumber,
          name: season.name,
          posterUrl: season.posterUrl,
          episodes: episodes,
        ),
      );
    }

    return remote.copyWith(
      title: remote.title.isNotEmpty ? remote.title : local.title,
      plot: remote.plot ?? local.plot,
      posterUrl: remote.posterUrl ?? local.posterUrl,
      backdropUrl: remote.backdropUrl ?? local.backdropUrl,
      cast: remote.cast.isNotEmpty ? remote.cast : local.cast,
      genres: remote.genres.isNotEmpty ? remote.genres : local.genres,
      rating: remote.rating ?? local.rating,
      seasons: seasons,
      updatedAt: DateTime.now(),
    );
  }

  SeriesEpisode? _resolvedEpisodeCached(String episodeId) {
    final suffix = '|ep|$episodeId';
    for (final entry in _customCatalogEpisodeResolveCache.entries) {
      if (entry.key.endsWith(suffix)) return entry.value;
    }
    return null;
  }

  SeriesEpisodeDetails _mergeEpisodeStub({
    required SeriesEpisodeDetails? local,
    required SeriesEpisodeDetails remote,
  }) {
    final cachedPlay = _resolvedEpisodeCached(remote.id);
    final localHasPlay =
        local != null &&
        ((local.playUrl?.trim().isNotEmpty ?? false) ||
            local.playVariants.any((v) => v.playUrl.trim().isNotEmpty));
    final remoteHasPlay =
        (remote.playUrl?.trim().isNotEmpty ?? false) ||
        remote.playVariants.any((v) => v.playUrl.trim().isNotEmpty);
    final cacheHasPlay = cachedPlay != null && !cachedPlay.needsPlaybackResolve;

    if (remoteHasPlay) {
      return remote;
    }
    if (cacheHasPlay) {
      return remote.copyWith(
        playUrl: cachedPlay.playUrl,
        playVariants: cachedPlay.playVariants.isNotEmpty
            ? cachedPlay.playVariants
            : remote.playVariants,
        torrentFile: cachedPlay.torrentFile ?? remote.torrentFile,
        resolution: cachedPlay.resolution ?? remote.resolution,
      );
    }
    if (localHasPlay) {
      return remote.copyWith(
        playUrl: local.playUrl,
        playVariants: local.playVariants.isNotEmpty
            ? local.playVariants
            : remote.playVariants,
        torrentFile: local.torrentFile ?? remote.torrentFile,
        resolution: local.resolution ?? remote.resolution,
      );
    }
    return remote;
  }

  /// Old details caches stored episode playUrl but dropped playVariants.
  /// Progressive stubs (no playUrl yet) are NOT stale — leave them alone.
  bool _legacySeasonsMissingPlayVariants(MediaDetails details) {
    var sawPlayableWithoutVariants = false;
    for (final season in details.seasons) {
      for (final ep in season.episodes) {
        final hasUrl = (ep.playUrl?.trim().isNotEmpty ?? false);
        if (!hasUrl) continue;
        if (ep.playVariants.isNotEmpty) return false;
        sawPlayableWithoutVariants = true;
      }
    }
    return sawPlayableWithoutVariants;
  }

  Future<SeriesInfo?> _seriesInfoFromCatalog(MediaItem series) async {
    var details =
        detailsCache[series.detailsId ?? series.id] ??
        detailsCache[series.id] ??
        detailsCache[series.streamId ?? ''];

    final needsRemote =
        details == null ||
        !_seasonsHaveEpisodeRows(details) ||
        _legacySeasonsMissingPlayVariants(details);
    if (needsRemote) {
      final remote = await _ensureCustomCatalogDetails(series);
      if (remote != null) details = remote;
    }

    if (details == null || !_seasonsHaveEpisodeRows(details)) {
      // Build from sibling episode rows already synced into the catalog.
      // Include stubs (empty playUrl) — progressive rows are still listable.
      final sid = series.streamId ?? series.id;
      final episodes = catalog
          .where(
            (m) =>
                m.sourceId == series.sourceId &&
                m.seriesId == sid &&
                m.kind != MediaKind.series,
          )
          .toList();
      if (episodes.isNotEmpty) {
        final seasonMap = <int, List<SeriesEpisode>>{};
        for (final ep in episodes) {
          final sn = ep.seasonNumber ?? 1;
          seasonMap
              .putIfAbsent(sn, () => [])
              .add(
                SeriesEpisode(
                  id: ep.id,
                  episodeNum: ep.episodeNumber ?? 0,
                  seasonNumber: sn,
                  title: ep.title,
                  containerExtension: 'mp4',
                  plot: ep.plot,
                  thumbnailUrl: ep.artUrl,
                  duration: ep.duration,
                  airDate: SeriesEpisode.parseAirDate(ep.releaseDate),
                  playUrl: ep.playUrl.isEmpty ? null : ep.playUrl,
                  torrentFile: ep.torrentFile,
                  httpHeaders: ep.httpHeaders,
                ),
              );
        }
        final seasons =
            seasonMap.entries
                .map(
                  (e) => SeriesSeason(
                    seasonNumber: e.key,
                    name: 'Season ${e.key}',
                    episodes: e.value
                      ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum)),
                  ),
                )
                .toList()
              ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
        return SeriesInfo(
          seriesId: sid,
          title: series.title,
          seasons: seasons,
          plot: series.plot ?? details?.plot,
          coverUrl: series.posterUrl ?? details?.posterUrl,
          genre:
              (series.genres.isNotEmpty
                      ? series.genres
                      : details?.genres ?? const [])
                  .join(', '),
          releaseDate: series.releaseDate ?? details?.releaseDate,
          rating: series.rating ?? details?.rating,
          backdropUrl: series.backdropUrl ?? details?.backdropUrl,
        );
      }
    }
    if (details == null) {
      // Search shell only — still paint poster/plot while /items is unavailable.
      return SeriesInfo(
        seriesId: series.streamId ?? series.id,
        title: series.title,
        seasons: const [],
        plot: series.plot,
        coverUrl: series.posterUrl,
        genre: series.genres.join(', '),
        releaseDate: series.releaseDate ?? series.year?.toString(),
        rating: series.rating,
        backdropUrl: series.backdropUrl,
      );
    }
    // First paint from shell alone — even when episode playUrls are empty.
    return _seriesInfoFromDetails(series, details);
  }

  /// Lazy-fill a season via `GET /items/{id}/episodes?season=` when the shell
  /// omitted nested episode rows (or only returned season stubs).
  Future<SeriesInfo?> ensureSeasonEpisodes({
    required MediaItem series,
    required int seasonNumber,
  }) {
    return _runUserFacing(
      () =>
          _ensureSeasonEpisodesBody(series: series, seasonNumber: seasonNumber),
    );
  }

  Future<SeriesInfo?> _ensureSeasonEpisodesBody({
    required MediaItem series,
    required int seasonNumber,
  }) async {
    if (series.origin != MediaOrigin.customCatalog) {
      return loadSeriesInfo(series);
    }
    final source = _customCatalogSourceFor(series);
    if (source == null) return loadSeriesInfo(series);

    final remoteId = _customCatalogRemoteId(series);
    var details =
        detailsCache[series.detailsId ?? series.id] ??
        detailsCache[series.id] ??
        detailsCache[remoteId];
    if (details != null) {
      for (final season in details.seasons) {
        if (season.seasonNumber == seasonNumber && season.episodes.isNotEmpty) {
          return _seriesInfoFromDetails(series, details);
        }
      }
    }

    try {
      final fetched = await _customCatalog.fetchEpisodes(
        baseUrl: source.playlistUrl!,
        id: remoteId,
        season: seasonNumber,
        locale: _catalogLocaleParam,
        headers: _customCatalogHeaders(source),
      );
      if (fetched.isEmpty) {
        return details == null ? null : _seriesInfoFromDetails(series, details);
      }
      final base =
          details ??
          MediaDetails(
            id: remoteId,
            title: series.title,
            mediaItemId: series.id,
            tmdbId: series.tmdbId,
            anilistId: series.anilistId,
            imdbId: series.imdbId,
            tvdbId: series.tvdbId,
            plot: series.plot,
            posterUrl: series.posterUrl,
            backdropUrl: series.backdropUrl,
            genres: series.genres,
            rating: series.rating,
            year: series.year,
            tags: series.tags,
            contentRating: series.contentRating,
            studio: series.studio,
            originalTitle: series.originalTitle,
            releaseDate: series.releaseDate,
            updatedAt: DateTime.now(),
          );
      final bySeason = <int, SeriesSeasonDetails>{
        for (final s in base.seasons) s.seasonNumber: s,
      };
      for (final s in fetched) {
        bySeason[s.seasonNumber] = s;
      }
      final merged = base.copyWith(
        seasons: bySeason.values.toList()
          ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber)),
      );
      await _cacheDetails(merged);
      return _seriesInfoFromDetails(series, merged);
    } catch (e, st) {
      debugPrint(
        'Custom catalog /items/$remoteId/episodes?season=$seasonNumber '
        'failed: $e\n$st',
      );
      return details == null ? null : _seriesInfoFromDetails(series, details);
    }
  }

  String episodeVariantPreferenceKey({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    final sid = series.streamId ?? series.id;
    return 'ep:$sid:s${episode.seasonNumber}:e${episode.episodeNum}';
  }

  EpisodePlayVariant? preferredEpisodeVariant({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    final variants = episodePlayVariants(series: series, episode: episode);
    if (variants.isEmpty) return null;
    final key = episodeVariantPreferenceKey(series: series, episode: episode);
    final preferredId = preferredVodVariants[key];
    if (preferredId != null) {
      for (final v in variants) {
        if (v.id == preferredId) return v;
      }
    }
    // Default media-server quality to the global stream setting.
    if (variants.first.id.startsWith('msq-')) {
      final match = variants.cast<EpisodePlayVariant?>().firstWhere(
        (v) => v!.id == 'msq-${mediaServerStreamQuality.name}',
        orElse: () => null,
      );
      if (match != null) return match;
    }
    final prefs = _preferredContentLangs;
    EpisodePlayVariant best = variants.first;
    var bestScore = VodGrouping.languagesAffinity(
      audioLanguages: best.audioLanguages,
      subtitleLanguages: best.subtitleLanguages,
      title: best.label,
      preferredLangs: prefs,
    );
    for (var i = 1; i < variants.length; i++) {
      final candidate = variants[i];
      final score = VodGrouping.languagesAffinity(
        audioLanguages: candidate.audioLanguages,
        subtitleLanguages: candidate.subtitleLanguages,
        title: candidate.label,
        preferredLangs: prefs,
      );
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /// Live episode row after progressive resolve (details cache / resolve cache).
  SeriesEpisode resolvedEpisodeFor({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    final key = _customCatalogEpisodeCacheKey(series.sourceId, episode.id);
    final cached = _customCatalogEpisodeResolveCache[key];
    if (cached != null) return cached;
    final fromDetails = _episodeDetailsFromSeriesCache(series, episode.id);
    if (fromDetails != null) {
      return _seriesEpisodeFromDetails(series, fromDetails);
    }
    return episode;
  }

  SeriesEpisodeDetails? _episodeDetailsFromSeriesCache(
    MediaItem series,
    String episodeId,
  ) {
    final details =
        detailsCache[series.detailsId ?? series.id] ??
        detailsCache[series.id] ??
        detailsCache[series.streamId ?? ''];
    if (details == null) return null;
    for (final season in details.seasons) {
      for (final ep in season.episodes) {
        if (ep.id == episodeId) return ep;
      }
    }
    return null;
  }

  /// Catalog version rows, or Plex/Jellyfin/Emby quality presets for an episode.
  List<EpisodePlayVariant> episodePlayVariants({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    final live = resolvedEpisodeFor(series: series, episode: episode);
    final existing = live.effectiveVariants;
    final hasDirectUrls = existing.any((v) => v.playUrl.trim().isNotEmpty);
    if (hasDirectUrls) {
      return VodGrouping.collapseEpisodeVariantsByStream(existing);
    }

    // Media-server episodes resolve streams at play time — offer qualities.
    if (series.origin.isMediaServer) {
      return [
        for (final q in MediaServerStreamQuality.values)
          EpisodePlayVariant(
            id: 'msq-${q.name}',
            label: q.label,
            playUrl: '',
            subtitle: q.subtitle,
          ),
      ];
    }
    return existing;
  }

  Future<void> setPreferredEpisodeVariant({
    required MediaItem series,
    required SeriesEpisode episode,
    required EpisodePlayVariant variant,
  }) async {
    final key = episodeVariantPreferenceKey(series: series, episode: episode);
    preferredVodVariants = {...preferredVodVariants, key: variant.id};
    await _store.savePreferredVodVariants(preferredVodVariants);
    notifyListeners();
  }

  MediaItem? episodeMediaItem({
    required MediaItem series,
    required SeriesEpisode episode,
    EpisodePlayVariant? variant,
  }) {
    final live = resolvedEpisodeFor(series: series, episode: episode);
    final chosen =
        variant ?? preferredEpisodeVariant(series: series, episode: live);
    final direct = (chosen?.playUrl ?? live.playUrl)?.trim();
    if (direct != null && direct.isNotEmpty) {
      final existing = catalog.cast<MediaItem?>().firstWhere(
        (m) => m?.id == live.id,
        orElse: () => null,
      );
      final versionLabel = chosen?.displayLabel;
      return MediaItem(
        id: live.id,
        title: live.title,
        playUrl: direct,
        kind: MediaKind.vod,
        origin: series.origin,
        subtitle: [
          series.title,
          live.shortLabel,
          if (versionLabel != null && versionLabel.isNotEmpty) versionLabel,
        ].join(' · '),
        thumbnailUrl: live.thumbnailUrl ?? series.thumbnailUrl,
        posterUrl: series.posterUrl,
        backdropUrl: series.backdropUrl,
        group: series.group,
        duration: live.duration,
        streamId: live.id,
        sourceId: series.sourceId,
        seriesId: series.streamId ?? series.id,
        seasonNumber: live.seasonNumber,
        episodeNumber: live.episodeNum,
        tmdbId: series.tmdbId,
        anilistId: series.anilistId,
        imdbId: series.imdbId,
        torrentFile:
            chosen?.torrentFile ?? live.torrentFile ?? existing?.torrentFile,
        resolution: chosen?.resolution ?? live.resolution,
        videoCodec: chosen?.videoCodec,
        audioCodec: chosen?.audioCodec,
        hdr: chosen?.hdr,
        subtitles: existing?.subtitles ?? const [],
        audioTracks: existing?.audioTracks ?? const [],
        segments: existing?.segments ?? const [],
        audioLanguages: chosen?.audioLanguages.isNotEmpty == true
            ? chosen!.audioLanguages
            : (existing?.audioLanguages ?? series.audioLanguages),
        subtitleLanguages: chosen?.subtitleLanguages.isNotEmpty == true
            ? chosen!.subtitleLanguages
            : (existing?.subtitleLanguages ?? series.subtitleLanguages),
        httpHeaders: mergePlaybackHeaders(
          mergePlaybackHeaders(
            mergePlaybackHeaders(
              series.httpHeaders,
              existing?.httpHeaders ?? const {},
            ),
            live.httpHeaders,
          ),
          chosen?.httpHeaders ?? const {},
        ),
      );
    }

    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == series.sourceId,
      orElse: () => null,
    );
    if (source == null) return null;

    // Jellyfin / Emby / Plex: episode id is the remote item id (ratingKey / Id).
    if (source.type.isMediaServer) {
      final remoteId = live.id.trim();
      if (remoteId.isEmpty) return null;
      final prefix = switch (source.type) {
        IptvSourceType.jellyfin => 'jf',
        IptvSourceType.emby => 'emby',
        _ => 'plex',
      };
      final qualityName = chosen?.id.startsWith('msq-') == true
          ? chosen!.id.substring(4)
          : mediaServerStreamQuality.name;
      final qualityLabel = chosen?.id.startsWith('msq-') == true
          ? chosen!.label
          : MediaServerStreamQualityX.fromName(qualityName).label;
      return MediaItem(
        id: '$prefix-${series.sourceId}-$remoteId',
        title: live.title,
        playUrl: '',
        kind: MediaKind.vod,
        origin: series.origin,
        subtitle: [series.title, live.shortLabel, qualityLabel].join(' · '),
        thumbnailUrl: live.thumbnailUrl ?? series.thumbnailUrl,
        posterUrl: series.posterUrl,
        backdropUrl: series.backdropUrl,
        group: series.group,
        duration: live.duration,
        streamId: remoteId,
        sourceId: series.sourceId,
        serverItemId: remoteId,
        seriesId: series.serverItemId ?? series.streamId ?? series.id,
        seasonNumber: live.seasonNumber,
        episodeNumber: live.episodeNum,
        tmdbId: series.tmdbId,
        anilistId: series.anilistId,
        imdbId: series.imdbId,
        plot: live.plot,
        // Encodes chosen transcoder preset for [resolveServerStreamUrl].
        resolution: qualityName,
      );
    }

    if (source.type == IptvSourceType.stalker) {
      final cmd = live.playUrl?.trim() ?? '';
      if (cmd.isEmpty) return null;
      return MediaItem(
        id: 'stalker-ep-${series.sourceId}-${live.id}',
        title: live.title,
        playUrl: cmd,
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvStalker,
        subtitle: '${series.title} · ${live.shortLabel}',
        thumbnailUrl: live.thumbnailUrl ?? series.thumbnailUrl,
        group: series.group,
        duration: live.duration,
        streamId: live.id,
        sourceId: series.sourceId,
        seriesId: series.streamId ?? series.id,
        seasonNumber: live.seasonNumber,
        episodeNumber: live.episodeNum,
        tmdbId: series.tmdbId,
        anilistId: series.anilistId,
      );
    }

    // Custom catalog stubs (no magnet/URL yet): still return a MediaItem so
    // next/prev chrome stays enabled. [normalizeEpisodeForPlayback] /
    // [ensureEpisodePlayable] resolve on open.
    if (source.type == IptvSourceType.custom ||
        series.origin == MediaOrigin.customCatalog) {
      return MediaItem(
        id: live.id,
        title: live.title,
        playUrl: '',
        kind: MediaKind.vod,
        origin: MediaOrigin.customCatalog,
        subtitle: '${series.title} · ${live.shortLabel}',
        thumbnailUrl: live.thumbnailUrl ?? series.thumbnailUrl,
        posterUrl: series.posterUrl,
        backdropUrl: series.backdropUrl,
        group: series.group,
        duration: live.duration,
        streamId: live.id,
        sourceId: series.sourceId,
        seriesId: series.streamId ?? series.id,
        seasonNumber: live.seasonNumber,
        episodeNumber: live.episodeNum,
        tmdbId: series.tmdbId,
        anilistId: series.anilistId,
        imdbId: series.imdbId,
        plot: live.plot,
        torrentFile: live.torrentFile,
        resolution: live.resolution,
        httpHeaders: mergePlaybackHeaders(series.httpHeaders, live.httpHeaders),
      );
    }

    if (source.type != IptvSourceType.xtream) return null;

    final url = _xtream.seriesEpisodeUrl(
      source: source,
      episodeId: live.id,
      extension: live.containerExtension,
    );

    return MediaItem(
      id: 'xtream-ep-${series.sourceId}-${live.id}',
      title: live.title,
      playUrl: stripXtreamCredentials(url),
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      subtitle: '${series.title} · ${live.shortLabel}',
      thumbnailUrl: live.thumbnailUrl ?? series.thumbnailUrl,
      group: series.group,
      duration: live.duration,
      streamId: live.id,
      sourceId: series.sourceId,
      seriesId: series.streamId ?? series.id,
      seasonNumber: live.seasonNumber,
      episodeNumber: live.episodeNum,
      tmdbId: series.tmdbId,
      anilistId: series.anilistId,
    );
  }

  /// Resolve stub episodes (no playUrl yet) via `GET /items/{episodeId}`.
  ///
  /// Merges playUrl + playVariants into the series shell cache. Results are
  /// cached separately so scrolling / re-tapping does not re-hit the bridge.
  /// Play / Versions call this directly (priority); cold prefetch uses
  /// concurrency 1 until [isCustomCatalogSeriesWarm].
  Future<SeriesEpisode?> resolveEpisodePlayback({
    required MediaItem series,
    required SeriesEpisode episode,
  }) async {
    final live = resolvedEpisodeFor(series: series, episode: episode);
    if (!live.needsPlaybackResolve) {
      if (series.origin == MediaOrigin.customCatalog) {
        _markCustomCatalogSeriesWarm(series);
      }
      return live;
    }
    if (series.origin != MediaOrigin.customCatalog) return live;

    final source = _customCatalogSourceFor(series);
    if (source == null) return live;

    final cacheKey = _customCatalogEpisodeCacheKey(series.sourceId, episode.id);
    final cached = _customCatalogEpisodeResolveCache[cacheKey];
    if (cached != null && !cached.needsPlaybackResolve) {
      _markCustomCatalogSeriesWarm(series);
      return cached;
    }

    final inflight = _customCatalogEpisodeInflight[cacheKey];
    if (inflight != null) return inflight;

    final future = _resolveCustomCatalogEpisode(
      series: series,
      episode: live,
      source: source,
      cacheKey: cacheKey,
    );
    _customCatalogEpisodeInflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      _customCatalogEpisodeInflight.remove(cacheKey);
    }
  }

  /// Background-resolve stub episodes with a cold-series gate.
  ///
  /// While the series is cold (no successful fill yet), concurrency is forced
  /// to **1** and only the first pending episode is scheduled — callers should
  /// pass the focused/resume row. After the first success, visible stubs may
  /// prefetch at up to [customCatalogWarmPrefetchConcurrency].
  Future<void> prefetchEpisodePlayback({
    required MediaItem series,
    required Iterable<SeriesEpisode> episodes,
    int? concurrency,
  }) async {
    if (series.origin != MediaOrigin.customCatalog) return;

    final warm = isCustomCatalogSeriesWarm(series);
    final need = <SeriesEpisode>[];
    final seen = <String>{};
    for (final episode in episodes) {
      if (!seen.add(episode.id)) continue;
      final live = resolvedEpisodeFor(series: series, episode: episode);
      if (!live.needsPlaybackResolve) continue;
      if (hasOfflineCopyForEpisode(series: series, episode: live)) continue;
      final cacheKey = _customCatalogEpisodeCacheKey(
        series.sourceId,
        episode.id,
      );
      // Already being resolved (Play / Versions / prior wave) — skip.
      if (_customCatalogEpisodeInflight.containsKey(cacheKey)) continue;
      need.add(live);
      // Cold gate: one episode only until the bridge is likely warm.
      if (!warm) break;
    }
    if (need.isEmpty) return;

    final before = customCatalogResolveRevision;
    final maxWorkers = warm ? customCatalogWarmPrefetchConcurrency : 1;
    final requested = concurrency ?? maxWorkers;
    final workers = requested.clamp(1, maxWorkers).clamp(1, need.length);
    var next = 0;
    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    try {
      Future<void> worker() async {
        while (true) {
          final index = next++;
          if (index >= need.length) return;
          await resolveEpisodePlayback(series: series, episode: need[index]);
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
    } finally {
      _uiQuiet = wasQuiet;
    }
    if (customCatalogResolveRevision != before) {
      notifyListeners();
    }
  }

  /// Bulk-fill a season via `GET /items/{id}/episodes?resolve=1&limit=…`.
  ///
  /// Paint stubs first, then call this once for short cours (≤24) or a tight
  /// window on long shows. Merges filled magnets into the resolve cache +
  /// details shell; empty rows stay stubs for per-episode fallback.
  /// Returns how many episodes gained a playUrl.
  Future<int> bulkResolveSeasonEpisodes({
    required MediaItem series,
    required int seasonNumber,
    int? limit,
    int offset = 0,
  }) async {
    if (series.origin != MediaOrigin.customCatalog) return 0;
    final source = _customCatalogSourceFor(series);
    if (source == null) return 0;

    final remoteId = _customCatalogRemoteId(series);
    final bulkKey = _customCatalogBulkKey(
      series.sourceId,
      remoteId,
      seasonNumber,
    );
    final inflight = _customCatalogBulkResolveInflight[bulkKey];
    if (inflight != null) return inflight;

    final future = _bulkResolveSeasonEpisodes(
      series: series,
      source: source,
      remoteId: remoteId,
      seasonNumber: seasonNumber,
      limit: limit,
      offset: offset,
    );
    _customCatalogBulkResolveInflight[bulkKey] = future;
    try {
      return await future;
    } finally {
      _customCatalogBulkResolveInflight.remove(bulkKey);
    }
  }

  Future<int> _bulkResolveSeasonEpisodes({
    required MediaItem series,
    required IptvSource source,
    required String remoteId,
    required int seasonNumber,
    int? limit,
    int offset = 0,
  }) async {
    try {
      final capped = (limit ?? CustomCatalogClient.maxResolveLimit).clamp(
        1,
        CustomCatalogClient.maxResolveLimit,
      );
      final fetched = await _customCatalog.fetchEpisodes(
        baseUrl: source.playlistUrl!,
        id: remoteId,
        season: seasonNumber,
        locale: _catalogLocaleParam,
        resolve: true,
        limit: capped,
        offset: offset < 0 ? 0 : offset,
        headers: _customCatalogHeaders(source),
      );
      if (fetched.isEmpty) return 0;

      var filled = 0;
      final wasQuiet = _uiQuiet;
      _uiQuiet = true;
      try {
        for (final season in fetched) {
          for (final ep in season.episodes) {
            final hasUrl =
                (ep.playUrl?.trim().isNotEmpty ?? false) ||
                ep.playVariants.any((v) => v.playUrl.trim().isNotEmpty);
            if (!hasUrl) continue;
            final cacheKey = _customCatalogEpisodeCacheKey(
              series.sourceId,
              ep.id,
            );
            final priorEp = _customCatalogEpisodeResolveCache[cacheKey];
            final priorDetails = priorEp == null
                ? _episodeDetailsFromSeriesCache(series, ep.id)
                : null;
            final merged = SeriesEpisode(
              id: ep.id,
              episodeNum: ep.episodeNumber,
              seasonNumber: ep.seasonNumber,
              title: ep.title.trim().isNotEmpty
                  ? ep.title
                  : (priorEp?.title.trim().isNotEmpty == true
                        ? priorEp!.title
                        : (priorDetails?.title.trim().isNotEmpty == true
                              ? priorDetails!.title
                              : 'Episode ${ep.episodeNumber}')),
              containerExtension: 'mp4',
              plot: ep.plot ?? priorEp?.plot ?? priorDetails?.plot,
              thumbnailUrl:
                  ep.thumbnailUrl ??
                  priorEp?.thumbnailUrl ??
                  priorDetails?.thumbnailUrl,
              duration:
                  ep.duration ?? priorEp?.duration ?? priorDetails?.duration,
              airDate:
                  ep.airDate ?? priorEp?.airDate ?? priorDetails?.airDate,
              playUrl: ep.playUrl,
              torrentFile:
                  ep.torrentFile ??
                  priorEp?.torrentFile ??
                  priorDetails?.torrentFile,
              resolution:
                  ep.resolution ??
                  priorEp?.resolution ??
                  priorDetails?.resolution,
              playVariants: ep.playVariants,
              httpHeaders: ep.httpHeaders.isNotEmpty
                  ? ep.httpHeaders
                  : (priorEp?.httpHeaders ??
                        priorDetails?.httpHeaders ??
                        const {}),
            );
            _customCatalogEpisodeResolveCache[cacheKey] = merged;
            await _mergeEpisodeIntoSeriesDetails(series, merged);
            filled++;
          }
        }
      } finally {
        _uiQuiet = wasQuiet;
      }

      if (filled > 0) {
        _markCustomCatalogSeriesWarm(series);
        customCatalogResolveRevision++;
        notifyListeners();
      }
      return filled;
    } catch (e, st) {
      debugPrint(
        'Custom catalog bulk resolve $remoteId season $seasonNumber failed: '
        '$e\n$st',
      );
      return 0;
    }
  }

  Future<SeriesEpisode?> _resolveCustomCatalogEpisode({
    required MediaItem series,
    required SeriesEpisode episode,
    required IptvSource source,
    required String cacheKey,
  }) async {
    try {
      await _applyCatalogClientProfile();
      final result = await _customCatalog.fetchItem(
        baseUrl: source.playlistUrl!,
        sourceId: source.id,
        id: episode.id,
        locale: _catalogLocaleParam,
        headers: _customCatalogHeaders(source),
      );
      if (result == null) return episode;

      final variants = _variantsFromCatalogItemResult(result, episode);
      final primaryUrl = variants.isNotEmpty
          ? variants.first.playUrl
          : (result.item.playUrl.trim().isNotEmpty
                ? result.item.playUrl
                : result.allItems
                      .cast<MediaItem?>()
                      .firstWhere(
                        (m) => m != null && m.playUrl.trim().isNotEmpty,
                        orElse: () => null,
                      )
                      ?.playUrl);
      if ((primaryUrl == null || primaryUrl.trim().isEmpty) &&
          variants.isEmpty) {
        JavpLog.w(
          'catalog',
          'episode resolve empty id=${episode.id} source=${source.id}',
        );
        return episode;
      }

      final filledItem = result.allItems.cast<MediaItem?>().firstWhere(
        (m) => m?.id == episode.id,
        orElse: () => result.item,
      );

      final patched = episode.copyWith(
        title: (filledItem?.title.isNotEmpty == true)
            ? filledItem!.title
            : episode.title,
        plot: episode.plot ?? filledItem?.plot,
        thumbnailUrl: episode.thumbnailUrl ?? filledItem?.artUrl,
        duration: episode.duration ?? filledItem?.duration,
        playUrl: primaryUrl?.trim().isNotEmpty == true
            ? primaryUrl!.trim()
            : episode.playUrl,
        torrentFile:
            filledItem?.torrentFile ??
            (variants.isNotEmpty ? variants.first.torrentFile : null) ??
            episode.torrentFile,
        resolution:
            filledItem?.resolution ??
            (variants.isNotEmpty ? variants.first.resolution : null) ??
            episode.resolution,
        playVariants: variants.isNotEmpty ? variants : episode.playVariants,
      );

      _customCatalogEpisodeResolveCache[cacheKey] = patched;
      await _mergeEpisodeIntoSeriesDetails(series, patched);
      _markCustomCatalogSeriesWarm(series);

      final playableRows = result.allItems
          .where((m) => m.playUrl.trim().isNotEmpty)
          .toList();
      if (playableRows.isNotEmpty) {
        final ids = playableRows.map((e) => e.id).toSet();
        catalog = [
          ...catalog.where(
            (m) => m.sourceId != source.id || !ids.contains(m.id),
          ),
          ...playableRows,
        ];
        await _store.saveCatalog(catalog);
      }

      customCatalogResolveRevision++;
      notifyListeners();
      return patched;
    } catch (e, st) {
      JavpLog.w('catalog', 'episode ${episode.id} fill failed', error: e);
      debugPrint('Custom catalog episode ${episode.id} fill failed: $e\n$st');
      return episode;
    }
  }

  List<EpisodePlayVariant> _variantsFromCatalogItemResult(
    CustomCatalogItemResult result,
    SeriesEpisode episode,
  ) {
    final items = result.allItems;
    if (items.isEmpty) return const [];

    // Expanded playVariants → each catalog row is a version.
    if (items.length > 1 ||
        (items.length == 1 && items.first.id != episode.id)) {
      final out = <EpisodePlayVariant>[];
      for (final m in items) {
        if (m.playUrl.trim().isEmpty) continue;
        final sub = m.subtitle?.trim();
        final res = m.resolution?.trim();
        out.add(
          EpisodePlayVariant(
            id: m.id,
            label: (sub != null && sub.isNotEmpty)
                ? sub
                : (res != null && res.isNotEmpty)
                ? res
                : 'Version',
            playUrl: m.playUrl,
            resolution: m.resolution,
            videoCodec: m.videoCodec,
            audioCodec: m.audioCodec,
            hdr: m.hdr,
            torrentFile: m.torrentFile,
            audioLanguages: m.audioLanguages,
            subtitleLanguages: m.subtitleLanguages,
            httpHeaders: m.httpHeaders,
          ),
        );
      }
      return VodGrouping.collapseEpisodeVariantsByStream(out);
    }

    final m = items.first;
    if (m.playUrl.trim().isEmpty) return const [];
    return [
      EpisodePlayVariant(
        id: episode.id,
        label: m.resolution?.trim().isNotEmpty == true
            ? m.resolution!.trim()
            : 'Default',
        playUrl: m.playUrl,
        resolution: m.resolution,
        videoCodec: m.videoCodec,
        audioCodec: m.audioCodec,
        hdr: m.hdr,
        torrentFile: m.torrentFile,
        audioLanguages: m.audioLanguages,
        subtitleLanguages: m.subtitleLanguages,
        httpHeaders: m.httpHeaders,
      ),
    ];
  }

  Future<void> _mergeEpisodeIntoSeriesDetails(
    MediaItem series,
    SeriesEpisode episode,
  ) async {
    final sid = series.detailsId ?? series.streamId ?? series.id;
    final details =
        detailsCache[sid] ??
        detailsCache[series.id] ??
        detailsCache[series.streamId ?? ''];
    if (details == null || details.seasons.isEmpty) return;

    var touched = false;
    final seasons = <SeriesSeasonDetails>[];
    for (final season in details.seasons) {
      final eps = <SeriesEpisodeDetails>[];
      for (final ep in season.episodes) {
        if (ep.id == episode.id ||
            (ep.seasonNumber == episode.seasonNumber &&
                ep.episodeNumber == episode.episodeNum)) {
          touched = true;
          eps.add(
            ep.copyWith(
              title: episode.title,
              plot: episode.plot,
              thumbnailUrl: episode.thumbnailUrl,
              duration: episode.duration,
              playUrl: episode.playUrl,
              torrentFile: episode.torrentFile,
              resolution: episode.resolution,
              playVariants: episode.playVariants,
              httpHeaders: episode.httpHeaders,
            ),
          );
        } else {
          eps.add(ep);
        }
      }
      seasons.add(
        SeriesSeasonDetails(
          seasonNumber: season.seasonNumber,
          name: season.name,
          posterUrl: season.posterUrl,
          episodes: eps,
        ),
      );
    }
    if (!touched) return;
    await _cacheDetails(details.copyWith(seasons: seasons));
  }

  bool _episodeItemIsPlayable(MediaItem? item) {
    if (item == null) return false;
    return item.playUrl.trim().isNotEmpty || item.serverItemId != null;
  }

  Future<MediaItem?> ensureEpisodePlayable({
    required MediaItem series,
    required SeriesEpisode episode,
    EpisodePlayVariant? variant,
  }) async {
    // Already on disk — skip catalog version resolve (common after restart).
    if (variant == null) {
      final offline = offlineItemForEpisode(series: series, episode: episode);
      if (offline != null) return offline;
    }
    final resolved = await resolveEpisodePlayback(
      series: series,
      episode: episode,
    );
    final use = resolved ?? episode;
    final ready = episodeMediaItem(
      series: series,
      episode: use,
      variant: variant,
    );
    if (_episodeItemIsPlayable(ready)) return ready;
    // Explicit Versions pick stays on this catalog even if it has no URL.
    if (variant != null) return ready;

    for (final sibling in VodGrouping.siblingSeriesShells(
      current: series,
      editions: vodFamilyLayoutFor(series).editions,
    )) {
      try {
        var info = await loadSeriesInfo(sibling);
        var hit = info.episodeAt(
          seasonNumber: episode.seasonNumber,
          episodeNum: episode.episodeNum,
        );
        if (hit == null && sibling.origin == MediaOrigin.customCatalog) {
          info =
              await ensureSeasonEpisodes(
                series: sibling,
                seasonNumber: episode.seasonNumber,
              ) ??
              info;
          hit = info.episodeAt(
            seasonNumber: episode.seasonNumber,
            episodeNum: episode.episodeNum,
          );
        }
        if (hit == null) continue;
        final siblingResolved = await resolveEpisodePlayback(
          series: sibling,
          episode: hit,
        );
        final siblingReady = episodeMediaItem(
          series: sibling,
          episode: siblingResolved ?? hit,
        );
        if (!_episodeItemIsPlayable(siblingReady)) continue;
        await setPreferredVodVariant(sibling);
        return siblingReady;
      } catch (_) {
        continue;
      }
    }
    return ready;
  }

  /// Variants for a playing episode row (from series details cache).
  List<EpisodePlayVariant> playVariantsForEpisodeItem(MediaItem item) {
    if (!item.isEpisode) return const [];
    final sid = item.seriesId?.trim();
    if (sid == null || sid.isEmpty) return const [];
    final details =
        detailsCache[sid] ??
        detailsCache[item.detailsId ?? ''] ??
        detailsFor(
          MediaItem(
            id: sid,
            title: sid,
            playUrl: '',
            kind: MediaKind.series,
            origin: item.origin,
            sourceId: item.sourceId,
          ),
        );
    if (details == null) return const [];
    for (final season in details.seasons) {
      for (final ep in season.episodes) {
        if (ep.id == item.id || ep.id == item.streamId) {
          if (ep.playVariants.isNotEmpty) {
            return VodGrouping.collapseEpisodeVariantsByStream(ep.playVariants);
          }
          final url = ep.playUrl?.trim();
          if (url != null && url.isNotEmpty) {
            return [
              EpisodePlayVariant(
                id: ep.id,
                label: ep.resolution ?? 'Default',
                playUrl: url,
                resolution: ep.resolution,
                torrentFile: ep.torrentFile,
                httpHeaders: ep.httpHeaders,
              ),
            ];
          }
          return const [];
        }
      }
    }
    return const [];
  }

  Future<MediaItem?> switchEpisodeVariant(
    MediaItem item,
    EpisodePlayVariant variant,
  ) async {
    final series =
        findSeriesShell(item.seriesId ?? '') ??
        MediaItem(
          id: item.seriesId ?? item.id,
          title: _seriesTitleForOrphanEpisode(item) ?? item.title,
          playUrl: '',
          kind: MediaKind.series,
          origin: item.origin,
          sourceId: item.sourceId,
          streamId: item.seriesId,
          posterUrl: item.posterUrl,
          anilistId: item.anilistId,
          tmdbId: item.tmdbId,
        );
    final episode = SeriesEpisode(
      id: item.id,
      episodeNum: item.episodeNumber ?? 0,
      seasonNumber: item.seasonNumber ?? 1,
      title: item.title,
      containerExtension: 'mp4',
      plot: item.plot,
      thumbnailUrl: item.thumbnailUrl,
      duration: item.duration,
      playUrl: item.playUrl,
      torrentFile: item.torrentFile,
      resolution: item.resolution,
      playVariants: playVariantsForEpisodeItem(item),
      httpHeaders: item.httpHeaders,
    );
    await setPreferredEpisodeVariant(
      series: series,
      episode: episode,
      variant: variant,
    );
    return episodeMediaItem(series: series, episode: episode, variant: variant);
  }

  static final _bareEpisodeTitleRe = RegExp(
    r'^(episode|épisode|ep)\s*\d+$',
    caseSensitive: false,
  );

  bool _isBareEpisodeTitle(String title) =>
      _bareEpisodeTitleRe.hasMatch(title.trim());

  String? _seriesNameFromHistorySubtitle(MediaItem item) {
    final sub = item.subtitle?.trim();
    if (sub == null || !sub.contains(' · ')) return null;
    final head = sub.split(' · ').first.trim();
    if (head.isEmpty) return null;
    // Simkl progress lines ("11/13 eps") are not series titles.
    if (RegExp(r'\d+\s*/\s*\d+\s*eps', caseSensitive: false).hasMatch(head)) {
      return null;
    }
    if (_isBareEpisodeTitle(head)) return null;
    if (SeriesWatchlistTitle.isPlatformLabel(head)) return null;
    return head;
  }

  /// Show title from details cache / magnet dn when history subtitle is only
  /// a Simkl progress line ("11/13 eps · Next E12").
  String? _seriesTitleForOrphanEpisode(MediaItem episode) {
    final fromSub = _seriesNameFromHistorySubtitle(episode);
    if (fromSub != null) return fromSub;

    for (final key in [
      episode.id,
      if ((episode.seriesId ?? '').trim().isNotEmpty) episode.seriesId!.trim(),
      if ((episode.simklId ?? '').trim().isNotEmpty) ...[
        'simkl-anime-${episode.simklId}',
        'simkl-tv-${episode.simklId}',
        'simkl-movie-${episode.simklId}',
      ],
      if (episode.tmdbId != null) ...[
        'tmdb-tv-${episode.tmdbId}',
        'tmdb-movie-${episode.tmdbId}',
      ],
      if (episode.anilistId != null) 'anilist-${episode.anilistId}',
    ]) {
      final details = detailsCache[key];
      final title = details?.title.trim() ?? '';
      if (title.isEmpty || _isBareEpisodeTitle(title)) continue;
      if (SeriesWatchlistTitle.isPlatformLabel(title)) continue;
      return title;
    }

    // Details may be keyed only by mediaItemId / foreign ids — scan once.
    final al = episode.anilistId;
    final tmdb = episode.tmdbId;
    final simkl = episode.simklId?.trim();
    if (al != null || tmdb != null || (simkl != null && simkl.isNotEmpty)) {
      for (final details in detailsCache.values) {
        final title = details.title.trim();
        if (title.isEmpty || _isBareEpisodeTitle(title)) continue;
        if (SeriesWatchlistTitle.isPlatformLabel(title)) continue;
        if (al != null && details.anilistId == al) return title;
        if (tmdb != null && details.tmdbId == tmdb) return title;
        if (simkl != null &&
            simkl.isNotEmpty &&
            (details.id == 'simkl-anime-$simkl' ||
                details.id == 'simkl-tv-$simkl' ||
                details.id == 'simkl-movie-$simkl')) {
          return title;
        }
      }
    }

    final playUrl = episode.playUrl.trim();
    if (playUrl.isNotEmpty && isMagnetUri(playUrl)) {
      final dn = RegExp(
        r'[?&]dn=([^&]+)',
        caseSensitive: false,
      ).firstMatch(playUrl)?.group(1);
      if (dn != null && dn.isNotEmpty) {
        String decoded;
        try {
          decoded = Uri.decodeComponent(dn.replaceAll('+', ' '));
        } catch (_) {
          decoded = dn;
        }
        final fromMagnet = _showTitleFromReleaseName(decoded);
        if (fromMagnet != null) return fromMagnet;
      }
    }

    final title = episode.title.trim();
    if (title.isNotEmpty && !_isBareEpisodeTitle(title)) {
      return SeriesWatchlistTitle.showTitleFromReleaseName(title) ?? title;
    }
    return null;
  }

  /// Strip release-group / Sxx / codec noise from a torrent `dn=` name.
  String? _showTitleFromReleaseName(String raw) =>
      SeriesWatchlistTitle.showTitleFromReleaseName(raw);

  /// History row title: "Show · S01E07" instead of bare "Episode 7".
  ///
  /// Live / catchup rows remap via [officialLiveTitle] at display time so CW
  /// and History stay current when family naming changes (history keeps the
  /// snapshot title on disk).
  String historyDisplayTitle(MediaItem item) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      return liveOrCatchupDisplayTitle(item);
    }
    if (!item.isEpisode) return item.title;
    final ep = item.episodeNumber;
    final season = item.seasonNumber;
    final epCode = (season != null && ep != null)
        ? 'S${season.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}'
        : null;
    final seriesName = _seriesTitleForOrphanEpisode(item);
    if (seriesName != null) {
      return epCode != null ? '$seriesName · $epCode' : seriesName;
    }
    final title = item.title.trim();
    if (epCode != null && _isBareEpisodeTitle(title)) {
      return epCode;
    }
    return item.title;
  }

  /// Freshest live row for naming: catalog index → pinned caches → catchup
  /// match → history seed, then preferred quality via [resolveLiveChannel].
  MediaItem _resolvedLiveForDisplay(MediaItem item) {
    MediaItem seed = item;
    if (item.isLive) {
      _ensureLiveById();
      final byId = _liveById?[item.id];
      if (byId != null) {
        seed = byId;
      } else {
        for (final c in _recentChannelsCache) {
          if (c.id == item.id) {
            seed = c;
            break;
          }
        }
        if (identical(seed, item)) {
          for (final c in _favoriteChannelsCache) {
            if (c.id == item.id) {
              seed = c;
              break;
            }
          }
        }
      }
    } else if (item.kind == MediaKind.catchup) {
      seed = liveChannelForCatchup(item) ?? item;
    }
    return resolveLiveChannel(seed);
  }

  MediaItem _withLiveOrCatchupDisplayTitle(MediaItem item) {
    if (!item.isLive && item.kind != MediaKind.catchup) return item;
    final title = liveOrCatchupDisplayTitle(item);
    if (title == item.title) return item;
    return item.copyWith(title: title);
  }

  MediaItem? findSeriesShell(String seriesId) {
    if (seriesId.isEmpty) return null;
    // itemById can hit history/VOD rows — only accept a real series shell.
    final byId = itemById(seriesId);
    if (byId != null && byId.isSeries) return byId;
    return catalog.cast<MediaItem?>().firstWhere(
      (m) =>
          m != null &&
          m.isSeries &&
          (m.id == seriesId ||
              m.streamId == seriesId ||
              m.detailsId == seriesId),
      orElse: () => null,
    );
  }

  /// Catalog / My List series matched by AniList / TMDB / Simkl (not episodes).
  MediaItem? _seriesShellByExternalIds(MediaItem episode) {
    MediaItem? best;
    var bestScore = 0;
    final inferred = _seriesTitleForOrphanEpisode(episode);
    void consider(MediaItem item) {
      if (!item.isSeries) return;
      var score = 0;
      if (episode.anilistId != null &&
          item.anilistId != null &&
          item.anilistId == episode.anilistId) {
        score += 5;
      }
      if (episode.tmdbId != null &&
          item.tmdbId != null &&
          item.tmdbId == episode.tmdbId) {
        score += 4;
      }
      if (episode.simklId != null &&
          item.simklId != null &&
          item.simklId == episode.simklId) {
        score += 3;
      }
      if (episode.imdbId != null &&
          item.imdbId != null &&
          item.imdbId!.toLowerCase() == episode.imdbId!.toLowerCase()) {
        score += 3;
      }
      if (score <= 0) return;
      if (inferred != null &&
          SeriesWatchlistTitle.titlesMatch(item.title, inferred)) {
        score += 6;
      }
      if (_isPlatformSeriesShell(item, inferred: inferred)) {
        score -= 8;
      }
      if (score <= 0 || score < bestScore) return;
      // Prefer a real show title over a bare Episode N shell.
      if (score == bestScore &&
          best != null &&
          !_isBareEpisodeTitle(best!.title) &&
          _isBareEpisodeTitle(item.title)) {
        return;
      }
      best = item;
      bestScore = score;
    }

    // Catalog + watchlist only — Simkl Watching can carry stolen AniList/TMDB
    // ids on the wrong title (do not prefer those over details/magnet heal).
    for (final item in catalog) {
      consider(item);
    }
    for (final item in watchlist) {
      consider(item);
    }
    return best;
  }

  MediaItem _healSeriesShellTitle(MediaItem shell, MediaItem episode) {
    if (!_isBareEpisodeTitle(shell.title) &&
        !SeriesWatchlistTitle.isPlatformLabel(shell.title)) {
      return shell;
    }
    final better = _seriesTitleForOrphanEpisode(episode);
    if (better == null || better == shell.title) return shell;
    if (SeriesWatchlistTitle.isPlatformLabel(better)) return shell;
    return shell.copyWith(title: better);
  }

  /// True when [shell] is a streaming-house shelf, not the show [inferred].
  bool _looksLikeHouseShelf(MediaItem shell) {
    final title = shell.title.trim();
    if (SeriesWatchlistTitle.isPlatformLabel(title)) return true;
    final group = shell.group?.trim();
    return group != null &&
        group.isNotEmpty &&
        SeriesWatchlistTitle.titlesMatch(title, group) &&
        SeriesWatchlistTitle.isPlatformLabel(group);
  }

  bool _isPlatformSeriesShell(MediaItem shell, {String? inferred}) {
    if (!_looksLikeHouseShelf(shell)) return false;
    // Keep a show that is actually named after a house.
    if (inferred != null &&
        inferred.isNotEmpty &&
        SeriesWatchlistTitle.titlesMatch(shell.title, inferred)) {
      return false;
    }
    return true;
  }

  /// Parent series for a continue-watching / history episode row.
  MediaItem? seriesShellForEpisode(MediaItem episode) {
    final sid = episode.seriesId?.trim();
    final inferred = _seriesTitleForOrphanEpisode(episode);
    MediaItem? found;
    var sidPointsToPlatform = false;
    if (sid != null && sid.isNotEmpty) {
      found = findSeriesShell(sid) ?? seriesForEpisode(episode);
    }
    if (found != null && _looksLikeHouseShelf(found)) {
      final byIds = _seriesShellByExternalIds(episode);
      if (byIds != null && !_looksLikeHouseShelf(byIds)) {
        found = byIds;
      } else if (inferred != null &&
          inferred.isNotEmpty &&
          !SeriesWatchlistTitle.titlesMatch(found.title, inferred)) {
        sidPointsToPlatform = true;
        found = null;
      }
      // else keep a show that is actually named after a house
    } else {
      found ??= _seriesShellByExternalIds(episode);
      if (found != null && _isPlatformSeriesShell(found, inferred: inferred)) {
        found = null;
      }
    }
    if (found != null) return _healSeriesShellTitle(found, episode);
    final syntheticId =
        _syntheticSeriesIdForEpisode(episode) ??
        ((sid != null && sid.isNotEmpty && !sidPointsToPlatform) ? sid : null);
    final name =
        inferred ??
        ((sid != null && sid.isNotEmpty && !sidPointsToPlatform)
            ? sid
            : episode.title);
    if (name.trim().isEmpty ||
        (SeriesWatchlistTitle.isPlatformLabel(name) &&
            (inferred == null ||
                SeriesWatchlistTitle.isPlatformLabel(inferred)))) {
      return null;
    }
    final id =
        syntheticId ??
        (inferred != null && inferred.isNotEmpty
            ? 'series:${VodGrouping.normalizeTitle(inferred)}'
            : null);
    if (id == null) return null;
    return MediaItem(
      id: id,
      title: name,
      playUrl: '',
      kind: MediaKind.series,
      origin: episode.origin,
      sourceId: episode.sourceId,
      streamId: (sid != null && sid.isNotEmpty && !sidPointsToPlatform)
          ? sid
          : id,
      posterUrl: episode.posterUrl,
      backdropUrl: episode.backdropUrl,
      thumbnailUrl: episode.thumbnailUrl,
      anilistId: episode.anilistId,
      tmdbId: episode.tmdbId,
      imdbId: episode.imdbId,
      simklId: episode.simklId,
      tvdbId: episode.tvdbId,
      plot: episode.plot,
      genres: episode.genres,
      year: episode.year,
      group: episode.group,
      httpHeaders: episode.httpHeaders,
    );
  }

  /// Stable parent id when history has AniList / TMDB / Simkl but no seriesId
  /// and the catalog is not hydrated yet.
  String? _syntheticSeriesIdForEpisode(MediaItem episode) {
    final al = episode.anilistId;
    if (al != null && al > 0) return 'anilist-$al';
    final simkl = episode.simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) return 'simkl-$simkl';
    final tmdb = episode.tmdbId;
    if (tmdb != null && tmdb > 0) return 'tmdb-tv-$tmdb';
    return null;
  }

  List<IptvCategory> get liveCategories {
    final cats = categories
        .where((c) => c.kind == IptvCategoryKind.live)
        .toList();
    final lock = parentalLock;
    if (lock != null) {
      lock.syncCategoryNames(cats);
      return lock.filterLiveCategories(cats);
    }
    return cats;
  }

  /// Pasted radio URLs (not IPTV source rows).
  List<MediaItem> get localRadioStations => [
    for (final m in localMedia)
      if (m.isRadioStation && !_isHistoryTombstoned(m)) m,
  ];

  /// Live category names that look like radio / music (M3U groups, etc.).
  Set<String> get radioLiveGroupNames => {
    for (final c in liveCategories)
      if (looksLikeRadioGroup(c.name)) c.name,
  };

  /// Movies shelves: Xtream categories plus groups from catalog / VOD cache
  /// (Jellyfin, Emby, Plex, custom JSON, local).
  List<IptvCategory> get vodCategories {
    _ensureOnDemandCategoriesCache();
    final cats = _cachedVodCategories!;
    final lock = parentalLock;
    if (lock == null) return cats;
    return lock.filterCategories(cats);
  }

  /// Series shelves: same union as [vodCategories] for series groups.
  List<IptvCategory> get seriesCategories {
    _ensureOnDemandCategoriesCache();
    final cats = _cachedSeriesCategories!;
    final lock = parentalLock;
    if (lock == null) return cats;
    return lock.filterCategories(cats);
  }

  int get _onDemandCategoriesStampNow => Object.hash(
    _vodCacheRevision,
    catalog.length,
    categories.length,
    _sourcesEnabledStamp,
    _vodByGroupIndexRevision,
    _vodDbGroupCacheRevision,
    parentalLock?.lockFilterStamp,
  );

  void _ensureOnDemandCategoriesCache() {
    final stamp = _onDemandCategoriesStampNow;
    if (_cachedVodCategories != null &&
        _cachedSeriesCategories != null &&
        _onDemandCategoriesStamp == stamp) {
      return;
    }
    _cachedVodCategories = _unifiedOnDemandCategories(IptvCategoryKind.vod);
    _cachedSeriesCategories = _unifiedOnDemandCategories(
      IptvCategoryKind.series,
    );
    _onDemandCategoriesStamp = stamp;
  }

  /// Merge provider category lists with `group` values already on titles.
  List<IptvCategory> _unifiedOnDemandCategories(IptvCategoryKind kind) {
    assert(
      kind == IptvCategoryKind.vod || kind == IptvCategoryKind.series,
      'only vod/series',
    );
    final byKey = <String, IptvCategory>{};
    // Provider category lists come from Xtream sync — skip when none are active.
    final includeProviderCategories = sources.any(
      (s) =>
          _sourceContributesVod(s) &&
          (s.type == IptvSourceType.xtream || s.type == IptvSourceType.stalker),
    );
    for (final c in categories) {
      if (!includeProviderCategories) continue;
      if (c.kind != kind) continue;
      if (c.sourceId != null && !isSourceVodContentVisible(c.sourceId)) {
        continue;
      }
      final key = c.name.trim().toLowerCase();
      if (key.isEmpty) continue;
      byKey.putIfAbsent(key, () => c);
    }

    final fromItems = <String, String>{};
    void noteGroup(String rawGroup, MediaItem? sample) {
      if (sample != null && !isSourceVodContentVisible(sample.sourceId)) return;
      if (sample != null) {
        if (kind == IptvCategoryKind.series) {
          if (!sample.isSeries) return;
        } else {
          if (sample.isSeries || sample.isLive || sample.isEpisode) return;
          if (sample.kind != MediaKind.vod &&
              sample.kind != MediaKind.local &&
              sample.kind != MediaKind.network) {
            return;
          }
        }
      }
      final g = rawGroup.trim();
      if (g.isEmpty) return;
      fromItems.putIfAbsent(g.toLowerCase(), () => g);
    }

    void note(MediaItem item) {
      if (!isSourceVodContentVisible(item.sourceId)) return;
      if (kind == IptvCategoryKind.series) {
        if (!item.isSeries) return;
      } else {
        if (item.isSeries || item.isLive || item.isEpisode) return;
        if (item.kind != MediaKind.vod &&
            item.kind != MediaKind.local &&
            item.kind != MediaKind.network) {
          return;
        }
      }
      noteGroup(item.group ?? '', item);
    }

    // Native SQLite keeps titles off the UI isolate. [_vodByGroupIndex] is
    // then empty buckets — Catalog must use the per-kind SQLite group maps
    // or JSON sources never appear as shelves (Home still pages them).
    if (_useVodDb) {
      final bySource = kind == IptvCategoryKind.series
          ? _vodDbSeriesGroupsBySource
          : _vodDbMovieGroupsBySource;
      for (final entry in bySource.entries) {
        if (!isSourceVodContentVisible(entry.key)) continue;
        for (final group in entry.value) {
          noteGroup(group, null);
        }
      }
    }

    // Prefer group-index keys (~hundreds) over scanning ~200k VOD rows — Catalog
    // stamp selects vodCategories.length on every rebuild.
    final indexed =
        _vodByGroupIndex != null &&
        _vodByGroupIndexRevision == _vodCacheRevision;
    if (indexed) {
      for (final entry in _vodByGroupIndex!.entries) {
        MediaItem? sample;
        for (final item in entry.value) {
          if (kind == IptvCategoryKind.series) {
            if (item.isSeries) {
              sample = item;
              break;
            }
          } else if (!item.isSeries &&
              !item.isLive &&
              !item.isEpisode &&
              (item.kind == MediaKind.vod ||
                  item.kind == MediaKind.local ||
                  item.kind == MediaKind.network)) {
            sample = item;
            break;
          }
        }
        if (sample == null) continue;
        noteGroup(entry.key, sample);
      }
      for (final item in catalog) {
        note(item);
      }
    } else {
      for (final item in catalog) {
        note(item);
      }
      for (final item in _vodStreamCache.values) {
        note(item);
      }
    }

    // SQLite groups (Try demo / custom catalogs) are seeded as empty buckets
    // so Catalog pages posters from disk. Include those names even when no
    // RAM sample exists yet — otherwise Movies/Series stay "No categories yet".
    final dbGroups = kind == IptvCategoryKind.series
        ? _vodDbSeriesGroupsBySource
        : _vodDbMovieGroupsBySource;
    for (final names in dbGroups.values) {
      for (final name in names) {
        noteGroup(name, null);
      }
    }

    for (final e in fromItems.entries) {
      byKey.putIfAbsent(
        e.key,
        () => IptvCategory(
          id: 'catalog-group:${kind.name}:${e.value}',
          name: e.value,
          kind: kind,
        ),
      );
    }

    final list = byKey.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Human-readable origin for shelves, search, and tiles.
  String sourceLabelFor(MediaItem item) {
    // Simkl/Trakt/… shells use [MediaOrigin.url] with an empty playUrl — never
    // surface that as a "URL" catalog chip (tap → "no local stream yet").
    if (isTrackerListShell(item)) {
      return _trackerShellSourceLabel(item);
    }
    _ensureSourceNameIndex();
    final direct = item.sourceId;
    if (direct != null) {
      final named = _resolvedSourceDisplayName(direct);
      if (named != null) return named;
    }
    // Orphaned sourceId after device switch / re-add: recover from catalog.
    final recovered = _recoveredSourceIdFor(item);
    if (recovered != null) {
      final named = _resolvedSourceDisplayName(recovered);
      if (named != null) return named;
    }
    // Single source of that type — still the right label even before catalog
    // rows land (restore → history paints first). Prefer a real name / host
    // over the "Custom catalog" placeholder.
    final soleId = _soleSourceIdForOrigin(item.origin);
    if (soleId != null) {
      final named = _resolvedSourceDisplayName(soleId);
      if (named != null) return named;
    }
    // Continue Watching series shells often have an empty playUrl while the
    // resume history row still carries a magnet — probe that before falling
    // back to the generic "Custom catalog" type name.
    final playUrl = _playUrlForSourceLabel(item);
    final fromPlay = _guessCustomCatalogSourceIdFromPlayUrl(playUrl);
    if (fromPlay != null) {
      final named = _resolvedSourceDisplayName(fromPlay);
      if (named != null) return named;
    }
    if (item.origin == MediaOrigin.torrent ||
        looksLikeTorrentPlayUrl(playUrl)) {
      return _uiL10n.originTorrent;
    }
    return genericOriginLabel(_uiL10n, item.origin);
  }

  /// Play URL used for source badges — series CW cards may be shells without
  /// a stream, so fall back to the in-progress history episode.
  String _playUrlForSourceLabel(MediaItem item) {
    final own = item.playUrl.trim();
    if (own.isNotEmpty) return own;
    if (!item.isSeries) return '';
    final ep = resumeEpisodeForSeries(item);
    return ep?.playUrl.trim() ?? '';
  }

  /// When history still points at a removed custom-catalog UUID, infer the
  /// live source from magnet trackers / custom magnet catalogs.
  String? _guessCustomCatalogSourceIdFromPlayUrl(String playUrl) {
    final url = playUrl.trim();
    if (url.isEmpty || !looksLikeTorrentPlayUrl(url)) return null;
    final lower = url.toLowerCase();
    final wantsMagnetCatalog =
        lower.contains('tr=') || lower.contains('tracker');
    if (!wantsMagnetCatalog) return null;

    String? sole;
    for (final source in sources) {
      if (!source.enabled || source.type != IptvSourceType.custom) continue;
      final name = source.name.toLowerCase();
      final playlist = (source.playlistUrl ?? '').toLowerCase();
      final looksMagnetCatalog =
          name.contains('torrent') ||
          name.contains('magnet') ||
          name.contains('p2p') ||
          name.contains('tracker') ||
          playlist.contains('torrent') ||
          playlist.contains('magnet') ||
          playlist.contains('p2p') ||
          playlist.contains('tracker');
      if (!looksMagnetCatalog) continue;
      if (sole != null) return null; // Ambiguous across multiple magnet catalogs.
      sole = source.id;
    }
    return sole;
  }

  /// Label for non-playable tracker list shells (Watching / watchlist).
  String _trackerShellSourceLabel(MediaItem item) {
    if (item.tags.contains('simkl-watching') ||
        item.tags.contains('simkl-plantowatch') ||
        item.id.startsWith('simkl:') ||
        item.id.startsWith('simkl-plan:')) {
      return 'SIMKL';
    }
    if (item.tags.contains('trakt-watchlist') || item.id.startsWith('trakt:')) {
      return 'Trakt';
    }
    if (item.tags.contains('plex-watchlist') ||
        item.id.startsWith('plex-watchlist:')) {
      return 'Plex';
    }
    if (item.tags.contains('letterboxd-watchlist') ||
        item.id.startsWith('letterboxd:')) {
      return 'Letterboxd';
    }
    if (item.tags.contains('serializd-watching') ||
        item.tags.contains('serializd-watchlist') ||
        item.id.startsWith('serializd:')) {
      return 'Serializd';
    }
    if (item.tags.contains('betaseries-watching') ||
        item.tags.contains('betaseries-plan') ||
        item.id.startsWith('betaseries:') ||
        item.id.startsWith('betaseries-plan:')) {
      return 'BetaSeries';
    }
    return 'Watchlist';
  }

  /// Source settings name, or catalog URL host when the name is still the
  /// placeholder ("Custom catalog" / empty).
  String? _resolvedSourceDisplayName(String sourceId) {
    _ensureSourceNameIndex();
    final named = _sourceNameById![sourceId]?.trim();
    if (named != null && named.isNotEmpty && named != 'Custom catalog') {
      return named;
    }
    return _hostLabelForSourceId(sourceId);
  }

  String? _hostLabelForSourceId(String sourceId) {
    IptvSource? match;
    for (final source in sources) {
      if (source.id == sourceId) {
        match = source;
        break;
      }
    }
    final url = match?.playlistUrl?.trim() ?? '';
    if (url.isEmpty) return null;
    if (isAssetCatalogUrl(url)) return 'Demo — open media';
    final uri = Uri.tryParse(url);
    final host = uri?.host.trim() ?? '';
    if (host.isEmpty) return null;
    return host.replaceFirst(RegExp(r'^www\.'), '');
  }

  String? _soleSourceIdForOrigin(MediaOrigin origin) {
    final type = switch (origin) {
      MediaOrigin.customCatalog => IptvSourceType.custom,
      MediaOrigin.iptvM3u => IptvSourceType.m3u,
      MediaOrigin.iptvXtream => IptvSourceType.xtream,
      MediaOrigin.iptvStalker => IptvSourceType.stalker,
      MediaOrigin.jellyfin => IptvSourceType.jellyfin,
      MediaOrigin.emby => IptvSourceType.emby,
      MediaOrigin.plex => IptvSourceType.plex,
      _ => null,
    };
    if (type == null) return null;
    String? sole;
    for (final source in sources) {
      if (!source.enabled || source.type != type) continue;
      if (sole != null) return null;
      sole = source.id;
    }
    return sole;
  }

  /// When [item.sourceId] is missing or unknown (common after profile sync if
  /// the catalog was re-added), recover a live source id from catalog rows.
  String? _recoveredSourceIdFor(MediaItem item) {
    final known = {for (final s in sources) s.id};
    final current = item.sourceId;
    if (current != null && known.contains(current)) return current;

    final itemStream = item.streamId?.trim();
    final itemSeries = item.seriesId?.trim();
    final keys = <String>{
      item.id,
      if (itemStream != null && itemStream.isNotEmpty) itemStream,
      if (itemSeries != null && itemSeries.isNotEmpty) itemSeries,
    };
    if (keys.isEmpty) return null;

    String? match;
    for (final row in catalog) {
      final sid = row.sourceId;
      if (sid == null || !known.contains(sid)) continue;
      final rowStream = row.streamId?.trim();
      final rowSeries = row.seriesId?.trim();
      final rowKeys = <String>{
        row.id,
        if (rowStream != null && rowStream.isNotEmpty) rowStream,
        if (rowSeries != null && rowSeries.isNotEmpty) rowSeries,
      };
      if (!rowKeys.any(keys.contains)) continue;
      if (match == null) {
        match = sid;
      } else if (match != sid) {
        return null; // Ambiguous across multiple catalogs.
      }
    }
    return match;
  }

  MediaDetails? detailsFor(MediaItem item) {
    return detailsCache[item.detailsId ?? item.id] ??
        detailsCache[item.id] ??
        (item.streamId != null ? detailsCache[item.streamId!] : null) ??
        (item.tmdbId != null
            ? detailsCache['tmdb-movie-${item.tmdbId}'] ??
                  detailsCache['tmdb-tv-${item.tmdbId}']
            : null) ??
        (item.simklId != null
            ? detailsCache['simkl-movie-${item.simklId}'] ??
                  detailsCache['simkl-tv-${item.simklId}'] ??
                  detailsCache['simkl-anime-${item.simklId}']
            : null) ??
        (item.traktId != null
            ? detailsCache['trakt-movie-${item.traktId}'] ??
                  detailsCache['trakt-show-${item.traktId}']
            : null);
  }

  /// Related VOD/series for the player browse pane (not live EPG).
  ///
  /// Prefer [vodSuggestionsForAsync] when SQLite backs the catalog — sync
  /// group buckets stay empty and would skip same-category peers.
  List<MediaItem> vodSuggestionsFor(MediaItem item, {int limit = 12}) {
    final group = item.group?.trim();
    return _vodSuggestionsFor(
      item,
      limit: limit,
      groupPeers: group == null || group.isEmpty
          ? const <MediaItem>[]
          : vodShelfSample(categoryName: group, limit: limit * 2),
    );
  }

  /// Same as [vodSuggestionsFor], but pages same-group peers from SQLite.
  Future<List<MediaItem>> vodSuggestionsForAsync(
    MediaItem item, {
    int limit = 12,
  }) async {
    if (limit <= 0) return const [];
    final group = item.group?.trim();
    final groupPeers = (group != null && group.isNotEmpty)
        ? await vodShelfSampleAsync(categoryName: group, limit: limit * 2)
        : const <MediaItem>[];
    return _vodSuggestionsFor(item, limit: limit, groupPeers: groupPeers);
  }

  List<MediaItem> _vodSuggestionsFor(
    MediaItem item, {
    required int limit,
    required List<MediaItem> groupPeers,
  }) {
    if (limit <= 0) return const [];
    final exclude = <String>{
      item.id,
      if (item.seriesId != null) item.seriesId!,
    };
    final genres = item.genres.map((e) => e.toLowerCase()).toSet();
    final out = <MediaItem>[];
    final seen = <String>{...exclude};

    bool take(MediaItem m) {
      if (m.isLive || m.kind == MediaKind.catchup || m.isEpisode) return false;
      if (!seen.add(m.id)) return false;
      out.add(m);
      return out.length >= limit;
    }

    for (final m in groupPeers) {
      if (take(m)) return out;
    }
    for (final m in recommendations) {
      if (genres.isNotEmpty &&
          m.genres.every((g) => !genres.contains(g.toLowerCase()))) {
        continue;
      }
      if (take(m)) return out;
    }
    for (final m in [
      ...vodPreview(series: item.isSeries, limit: limit * 2),
      ...vodPreview(series: !item.isSeries, limit: limit),
    ]) {
      if (take(m)) return out;
    }
    return out;
  }

  Map<String, String>? _sourceNameById;
  Map<String, String?>? _sourceColorById;
  List<IptvSource>? _sourceNameIndexRef;

  void _ensureSourceNameIndex() {
    if (identical(_sourceNameIndexRef, sources) &&
        _sourceNameById != null &&
        _sourceColorById != null) {
      return;
    }
    _sourceNameById = {for (final source in sources) source.id: source.name};
    _sourceColorById = {for (final source in sources) source.id: source.color};
    _sourceNameIndexRef = sources;
  }

  /// Badge / filter color for a known source id, if the user set one.
  Color? colorForSourceId(String? sourceId) {
    if (sourceId == null || sourceId.isEmpty) return null;
    _ensureSourceNameIndex();
    return parseSourceColor(_sourceColorById?[sourceId]);
  }

  /// Color for a media row’s source badge. Null when multi-source or unset.
  Color? sourceColorFor(MediaItem item) {
    if (isTrackerListShell(item)) return null;
    if (_isVodMovieFamilyItem(item) && vodSourceCountFor(item) > 1) {
      return null;
    }
    final direct = item.sourceId;
    if (direct != null) {
      final color = colorForSourceId(direct);
      if (color != null) return color;
    }
    final recovered = _recoveredSourceIdFor(item);
    if (recovered != null) return colorForSourceId(recovered);
    return colorForSourceId(_soleSourceIdForOrigin(item.origin));
  }

  /// `null` / empty [sourceKeys] = all sources; `'__local__'` = local files /
  /// pasted URLs only. [sourceKey] is the single-id form of [sourceKeys].
  List<MediaItem> filterBySource(
    Iterable<MediaItem> items, {
    String? sourceKey,
    Set<String>? sourceKeys,
  }) {
    final keys =
        sourceKeys ??
        (sourceKey == null || sourceKey.isEmpty ? null : <String>{sourceKey});
    if (keys == null || keys.isEmpty) return items.toList();
    if (keys.length == 1 && keys.single == localSourceKey) {
      return items
          .where(
            (m) =>
                m.origin == MediaOrigin.localFile ||
                m.origin == MediaOrigin.url ||
                m.origin == MediaOrigin.torrent,
          )
          .toList();
    }
    return items
        .where((m) => m.sourceId != null && keys.contains(m.sourceId))
        .toList();
  }

  static const localSourceKey = '__local__';

  /// Live channels grouped by XMLTV / Xtream `epg_channel_id` (tvg-id).
  Map<String, List<MediaItem>> get liveByTvgId {
    final map = <String, List<MediaItem>>{};
    for (final channel in liveChannels) {
      final tvgId = channel.epgChannelId?.trim();
      if (tvgId == null || tvgId.isEmpty) continue;
      map.putIfAbsent(tvgId, () => []).add(channel);
    }
    for (final entry in map.entries) {
      entry.value.sort(ChannelQuality.compareVariants);
    }
    return map;
  }

  /// Official label: shared family base (no quality tag — Auto may differ).
  String officialLiveTitle(MediaItem channel) {
    final variants = qualityVariantsFor(channel);
    if (variants.length > 1) {
      return ChannelQuality.familyDisplayTitle(
        channel,
        variants,
        officialNameOf: epgDisplayNameFor,
      );
    }
    return ChannelQuality.displayTitle(
      channel,
      epgDisplayName: epgDisplayNameFor(channel),
    );
  }

  String? epgDisplayNameFor(MediaItem channel) {
    final alias = _epgAliasIndex;
    if (alias != null) {
      return alias.displayNameFor(
        epgChannelId: channel.epgChannelId,
        channelTitle: channel.title,
        channelName: channel.channelName,
      );
    }
    final tvg = channel.epgChannelId?.trim();
    if (tvg == null || tvg.isEmpty) return null;
    final name = epgChannelNames[tvg]?.trim();
    if (name == null || name.isEmpty) return null;
    return name;
  }

  /// Family key: EPG display-name when known, else cleaned title, else tvg-id.
  String? liveFamilyKey(MediaItem channel) {
    return ChannelQuality.preferenceKey(
      channel,
      officialName: epgDisplayNameFor(channel),
    );
  }

  final Map<String, List<MediaItem>> _lazyVariantCache = {};
  List<MediaItem>? _lazyVariantChannelsRef;

  /// Seed the in-memory family cache so sync pickers work after a DB lookup.
  void _rememberLiveVariants(MediaItem channel, List<MediaItem> variants) {
    if (variants.isEmpty) return;
    final key =
        liveFamilyKey(channel) ??
        liveFamilyKey(variants.first) ??
        _liveFamilyKeyById?[channel.id];
    if (key == null) return;
    _liveFamilyIndex ??= {};
    _liveFamilyKeyById ??= {};
    _liveFamilyIndexNamesRef = epgChannelNames;
    _liveFamilyIndex![key] = List<MediaItem>.from(variants);
    for (final v in variants) {
      _liveFamilyKeyById![v.id] = key;
      _liveVariantCountById[v.id] = variants.length;
    }
    _rememberFamilyCatchupFromVariants(variants);
  }

  /// Max archive days in the channel family (listing / sibling), not just Auto.
  int liveFamilyCatchupDays(MediaItem channel) {
    final cached = _liveFamilyCatchupById[channel.id];
    if (cached != null && cached > 0) return cached;
    if (channel.supportsCatchup) return channel.catchupDays;
    return 0;
  }

  void _rememberFamilyCatchupDays(String channelId, int days) {
    if (days <= 0) return;
    final prev = _liveFamilyCatchupById[channelId] ?? 0;
    if (days > prev) _liveFamilyCatchupById[channelId] = days;
  }

  void _rememberFamilyCatchupFromVariants(Iterable<MediaItem> variants) {
    var max = 0;
    for (final v in variants) {
      if (v.catchupDays > max) max = v.catchupDays;
    }
    if (max <= 0) return;
    for (final v in variants) {
      _rememberFamilyCatchupDays(v.id, max);
    }
  }

  /// Variant count from the last [collapseLiveQualities] pass (list UI).
  int liveVariantCount(MediaItem channel) =>
      _liveVariantCountById[channel.id] ?? 1;

  Map<String, int> _liveVariantCountById = {};

  /// In-session quality override — does not write [preferredLiveQualities].
  Future<void> setSessionLiveQuality(MediaItem channel) async {
    final key =
        liveFamilyKey(channel) ?? await _liveDb.familyKeyFor(channel.id);
    final streamId = channel.streamId;
    if (key == null || streamId == null) return;
    _sessionLiveQualities = {..._sessionLiveQualities, key: streamId};
    notifyListeners();
  }

  List<String> timeshiftUrlsFor({
    required MediaItem channel,
    required DateTime start,
    required Duration duration,
  }) {
    final archive = resolveCatchupChannel(channel) ?? channel;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == archive.sourceId,
      orElse: () => null,
    );
    if (source == null || archive.streamId == null) return const [];
    if (source.type == IptvSourceType.xtream) {
      return _xtream.catchupUrlCandidates(
        source: source,
        streamId: archive.streamId!,
        start: start,
        duration: duration,
      );
    }
    // Media-server catchup is resolved at play time via [serverItemId] + offset.
    if (source.type.isMediaServer &&
        (archive.serverItemId ?? '').trim().isNotEmpty) {
      return const ['media-server-timeshift'];
    }
    return const [];
  }

  /// History rows that may still back a Continue watching card.
  ///
  /// Same tombstone / source / catchup / tracker gates as [continueWatching],
  /// before series-shell promotion and dedupe — used so last-close snapshot
  /// fill cannot resurrect titles live CW intentionally hid.
  Iterable<MediaItem> get continueWatchingHistorySupport sync* {
    final statusStore = TrackerStatusStore(trackerStatuses);
    for (final item in history) {
      if (!LocalRecommender.isContinueWatchingCandidate(item)) continue;
      if (_isHistoryTombstoned(item)) continue;
      if (!isSourceContentVisible(item.sourceId)) continue;
      if (item.kind == MediaKind.catchup && !isCatchupAvailable(item)) {
        continue;
      }
      if (_trackerExcludesContinueWatching(statusStore, item)) continue;
      if (item.isEpisode) {
        final shell = seriesShellForEpisode(item);
        if (shell != null) {
          if (!isListedVodSourceVisible(shell.sourceId)) continue;
          if (_trackerExcludesContinueWatching(statusStore, shell)) continue;
        }
      } else if (!item.isLive &&
          item.kind != MediaKind.catchup &&
          !isListedVodSourceVisible(item.sourceId)) {
        continue;
      }
      yield item;
    }
  }

  List<MediaItem> get continueWatching {
    final stamp = Object.hash(
      identityHashCode(history),
      history.length,
      history.isEmpty ? null : history.first.id,
      identityHashCode(catalog),
      catalog.length,
      identityHashCode(detailsCache),
      detailsCache.length,
      sourcesEnabledRevision,
      vodCacheRevision,
      trackerStatuses.length,
      Object.hashAll(
        trackerStatuses
            .take(12)
            .map((e) => Object.hash(e.identityKey, e.status)),
      ),
      // Live/catchup CW titles remap via officialLiveTitle — bust when naming
      // inputs change without a history rewrite.
      identityHashCode(preferredLiveQualities),
      preferredLiveQualities.length,
      identityHashCode(epgChannelNames),
      epgChannelNames.length,
      identityHashCode(_recentChannelsCache),
      identityHashCode(_favoriteChannelsCache),
      identityHashCode(_liveFamilyIndex),
      parentalLock?.lockFilterStamp ?? 'none',
    );
    if (_cachedContinueWatching != null && _continueWatchingStamp == stamp) {
      return _cachedContinueWatching!;
    }
    final watch = Stopwatch()..start();
    final statusStore = TrackerStatusStore(trackerStatuses);
    final items = _recommender.continueWatching(history, limit: 36);
    final out = <MediaItem>[];
    for (final item in items) {
      if (_isHistoryTombstoned(item)) continue;
      if (!isSourceContentVisible(item.sourceId)) continue;
      if (item.kind == MediaKind.catchup && !isCatchupAvailable(item)) {
        continue;
      }
      if (_trackerExcludesContinueWatching(statusStore, item)) continue;
      // Surface the series (not each episode) so Home has one card per show.
      MediaItem card = item;
      if (item.isEpisode) {
        final shell = seriesShellForEpisode(item);
        if (shell != null) {
          if (!isListedVodSourceVisible(shell.sourceId)) continue;
          if (_trackerExcludesContinueWatching(statusStore, shell)) continue;
          card = _continueWatchingSeriesCard(shell, item);
        }
        // Keep untitled / catalog-missing episodes on the rail so Home does
        // not shrink to leftover movies/live until shells resolve.
      } else if (!item.isLive &&
          item.kind != MediaKind.catchup &&
          !isListedVodSourceVisible(item.sourceId)) {
        continue;
      }
      card = _withLiveOrCatchupDisplayTitle(card);
      // Collapse history series-shell + episode-promoted sibling (and bare
      // series rows that lack seriesId so the recommender key missed them).
      // Movie quality/language encodes share one card via family identity.
      final key = _continueWatchingDedupeKey(card);
      final idx = out.indexWhere(
        (m) =>
            _continueWatchingDedupeKey(m) == key ||
            HomeContinueWatching.overlaps(
              card,
              HomeContinueWatching.identityKeys(m),
            ),
      );
      if (idx >= 0) {
        if (_continueWatchingCardRicher(card, out[idx])) {
          out[idx] = card;
        }
        continue;
      }
      out.add(card);
    }
    _cachedContinueWatching = out;
    _continueWatchingStamp = stamp;
    JavpLog.slow(
      'shelf',
      'continueWatching in ${watch.elapsedMilliseconds}ms n=${out.length}',
      watch.elapsedMilliseconds,
      thresholdMs: 16,
    );
    return out;
  }

  /// Collapse key for one Continue Watching card per show.
  String _continueWatchingDedupeKey(MediaItem item) {
    if (item.anilistId != null && item.anilistId! > 0) {
      return 'al:${item.anilistId}';
    }
    if (item.simklId != null && item.simklId!.trim().isNotEmpty) {
      return 'simkl:${item.simklId!.trim()}';
    }
    if (item.tmdbId != null && item.tmdbId! > 0) {
      return 'tmdb:${item.tmdbId}';
    }
    final sid = item.seriesId?.trim();
    if (sid != null && sid.isNotEmpty) return 'series:$sid';
    final stream = item.streamId?.trim();
    if (stream != null &&
        stream.isNotEmpty &&
        (item.isSeries || item.isEpisode)) {
      return 'stream:$stream';
    }
    if (item.isSeries || item.kind == MediaKind.series || item.isEpisode) {
      return 'series-title:${VodGrouping.normalizeTitle(item.title)}|'
          '${item.year ?? ''}';
    }
    if (!item.isLive && item.kind != MediaKind.catchup) {
      final family = canonicalVodGroupKey(item);
      if (family != null) return 'vod:$family';
      final g = VodGrouping.groupKey(item);
      if (g != null) return 'vod:$g';
    }
    return 'id:${item.id}';
  }

  /// Movies only: quality / language encodes of one title.
  bool _isVodMovieWatchItem(MediaItem item) {
    return !item.isLive &&
        item.kind != MediaKind.catchup &&
        !item.isSeries &&
        !item.isEpisode;
  }

  /// True when [a] and [b] are encodes of the same movie (title page family).
  bool _sameMovieWatchFamily(MediaItem a, MediaItem b) {
    if (a.id == b.id) return true;
    if (!_isVodMovieWatchItem(a) || !_isVodMovieWatchItem(b)) return false;
    final ka = canonicalVodGroupKey(a);
    final kb = canonicalVodGroupKey(b);
    if (ka != null && ka == kb) return true;
    return HomeContinueWatching.overlaps(
      a,
      HomeContinueWatching.identityKeys(b),
    );
  }

  /// True when [a] and [b] are versions of the same series episode (SxxExx).
  ///
  /// Catalog variants / magnets can land under different history ids; keep one
  /// resume row per episode so the episodes list does not stack playtimes.
  bool _sameEpisodeWatchFamily(MediaItem a, MediaItem b) {
    if (a.id == b.id) return true;
    if (!a.isEpisode || !b.isEpisode) return false;
    final aSn = a.seasonNumber;
    final aEn = a.episodeNumber;
    final bSn = b.seasonNumber;
    final bEn = b.episodeNumber;
    if (aSn == null || aEn == null || bSn == null || bEn == null) return false;
    if (aSn != bSn || aEn != bEn) return false;
    final aSid = a.seriesId?.trim();
    final bSid = b.seriesId?.trim();
    if (aSid != null &&
        aSid.isNotEmpty &&
        bSid != null &&
        bSid.isNotEmpty &&
        aSid == bSid) {
      return true;
    }
    if (a.anilistId != null && a.anilistId! > 0 && a.anilistId == b.anilistId) {
      return true;
    }
    if (a.tmdbId != null && a.tmdbId! > 0 && a.tmdbId == b.tmdbId) {
      return true;
    }
    final aSimkl = a.simklId?.trim();
    final bSimkl = b.simklId?.trim();
    if (aSimkl != null &&
        aSimkl.isNotEmpty &&
        bSimkl != null &&
        bSimkl.isNotEmpty &&
        aSimkl == bSimkl) {
      return true;
    }
    return false;
  }

  /// Prefer the series card that carries next/progress episode meta.
  bool _continueWatchingCardRicher(MediaItem a, MediaItem b) {
    final aEp = a.seasonNumber != null || a.episodeNumber != null;
    final bEp = b.seasonNumber != null || b.episodeNumber != null;
    if (aEp != bEp) return aEp;
    if (a.progress != b.progress) return a.progress > b.progress;
    final aAt = a.lastWatchedAt;
    final bAt = b.lastWatchedAt;
    if (aAt != null && bAt != null) return aAt.isAfter(bAt);
    return aAt != null && bAt == null;
  }

  /// Series shelf card carrying the resume episode's playhead / SxxExx meta.
  MediaItem _continueWatchingSeriesCard(MediaItem shell, MediaItem episode) {
    final sn = episode.seasonNumber;
    final en = episode.episodeNumber;
    final epLabel = (sn != null || en != null)
        ? 'S${(sn ?? 1).toString().padLeft(2, '0')}'
              'E${(en ?? 0).toString().padLeft(2, '0')}'
        : null;
    final episodeTitle = episode.title.trim();
    final showTitle = shell.title.trim();
    // Same rule as series episode grid: hide generic "Episode N" — SxxExx is enough.
    final realEpisodeTitle =
        episodeTitle.isNotEmpty &&
            !_isBareEpisodeTitle(episodeTitle) &&
            episodeTitle.toLowerCase() != showTitle.toLowerCase() &&
            episodeTitle != epLabel
        ? episodeTitle
        : null;
    final meta = [
      if (epLabel != null) epLabel,
      if (realEpisodeTitle != null) realEpisodeTitle,
    ].join(' \u00b7 ');
    return shell.copyWith(
      progress: episode.progress,
      lastWatchedAt: episode.lastWatchedAt,
      duration: episode.duration,
      seasonNumber: sn,
      episodeNumber: en,
      seriesId: episode.seriesId ?? shell.streamId ?? shell.id,
      subtitle: meta.isNotEmpty ? meta : episode.subtitle,
    );
  }

  /// Ids that identify [series] across catalog / history episode rows.
  Set<String> _seriesIdentityKeys(MediaItem series) {
    return {
      series.id,
      if (series.streamId != null && series.streamId!.trim().isNotEmpty)
        series.streamId!.trim(),
      if (series.seriesId != null && series.seriesId!.trim().isNotEmpty)
        series.seriesId!.trim(),
      if (series.detailsId != null && series.detailsId!.trim().isNotEmpty)
        series.detailsId!.trim(),
      if (series.anilistId != null && series.anilistId! > 0)
        'al:${series.anilistId}',
      if (series.simklId != null && series.simklId!.trim().isNotEmpty)
        'simkl:${series.simklId!.trim()}',
      if (series.tmdbId != null && series.tmdbId! > 0) 'tmdb:${series.tmdbId}',
    };
  }

  bool _historyBelongsToSeries(MediaItem historyItem, MediaItem series) {
    final keys = _seriesIdentityKeys(series);
    final sid = historyItem.seriesId?.trim();
    if (sid != null && sid.isNotEmpty && keys.contains(sid)) return true;
    if (keys.contains(historyItem.id)) return true;
    // Continue watching promotes an episode to a catalog series shell matched
    // by AniList / TMDB / Simkl — those ids must count even when seriesId
    // on the episode does not equal the shell id.
    if (historyItem.anilistId != null &&
        historyItem.anilistId! > 0 &&
        keys.contains('al:${historyItem.anilistId}')) {
      return true;
    }
    if (historyItem.tmdbId != null &&
        historyItem.tmdbId! > 0 &&
        keys.contains('tmdb:${historyItem.tmdbId}')) {
      return true;
    }
    final simkl = historyItem.simklId?.trim();
    if (simkl != null && simkl.isNotEmpty && keys.contains('simkl:$simkl')) {
      return true;
    }
    return false;
  }

  /// In-progress episode to resume for a series (continue watching / detail CTA).
  MediaItem? resumeEpisodeForSeries(MediaItem series) {
    MediaItem? best;
    void consider(MediaItem candidate) {
      if (!candidate.isEpisode) return;
      if (!LocalRecommender.isContinueWatchingCandidate(candidate)) return;
      if (best == null ||
          (candidate.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .isAfter(
                best!.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
              )) {
        best = candidate;
      }
    }

    final preferSn = series.seasonNumber;
    final preferEn = series.episodeNumber;
    if (preferSn != null || preferEn != null) {
      for (final h in history) {
        if (!_historyBelongsToSeries(h, series)) continue;
        if (preferSn != null && h.seasonNumber != preferSn) continue;
        if (preferEn != null && h.episodeNumber != preferEn) continue;
        consider(h);
      }
      if (best != null) return best;
    }

    for (final h in history) {
      if (!_historyBelongsToSeries(h, series)) continue;
      consider(h);
    }
    return best;
  }

  /// Watch history row for a series episode, if any.
  MediaItem? historyForSeriesEpisode({
    required MediaItem series,
    required SeriesEpisode episode,
  }) {
    MediaItem? best;
    void consider(MediaItem candidate) {
      if (best == null ||
          (candidate.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .isAfter(
                best!.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
              )) {
        best = candidate;
      }
    }

    for (final h in history) {
      if (h.id == episode.id) {
        consider(h);
        continue;
      }
      if (!_historyBelongsToSeries(h, series)) continue;
      if (h.seasonNumber == episode.seasonNumber &&
          h.episodeNumber == episode.episodeNum) {
        consider(h);
      }
    }
    return best;
  }

  /// Best on-device resume snapshot for [item] (history / download metadata).
  MediaItem? resumeSnapshotFor(MediaItem item) {
    MediaItem? best;
    void consider(MediaItem candidate) {
      if (candidate.progress <= 0.02 || candidate.progress >= 0.95) return;
      if (best == null ||
          (candidate.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .isAfter(
                best!.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
              )) {
        best = candidate;
      }
    }

    for (final h in history) {
      if (h.id == item.id) {
        consider(h);
        continue;
      }
      if (item.seriesId != null &&
          item.seriesId == h.seriesId &&
          item.seasonNumber != null &&
          item.seasonNumber == h.seasonNumber &&
          item.episodeNumber != null &&
          item.episodeNumber == h.episodeNumber) {
        consider(h);
        continue;
      }
      if (_sameMovieWatchFamily(item, h)) consider(h);
    }
    final task = _downloads.bestTaskFor(item);
    if (task != null) consider(task.item);
    return best;
  }

  List<MediaItem> get recommendations {
    // Never score the full live/VOD universe on every Home rebuild.
    final stamp = Object.hash(
      history.length,
      history.isEmpty ? null : history.first.id,
      watchlist.length,
      watchlist.isEmpty ? null : watchlist.first.id,
      letterboxdWatchlist.length,
      letterboxdWatchlist.isEmpty ? null : letterboxdWatchlist.first.id,
      localMedia.length,
      vodCacheCount,
      catalog.length,
      sourcesEnabledRevision,
      preferredVodVariants.length,
      _remoteRecBoosts.length,
      Object.hashAll(_remoteRecBoosts.keys.take(8)),
      trackerStatuses.length,
    );
    if (_cachedRecommendations != null && _recommendationsStamp == stamp) {
      unawaited(_ensureRemoteRecommendations());
      return _cachedRecommendations!;
    }
    final watch = Stopwatch()..start();
    final pool = <MediaItem>[
      ...watchlist,
      ...localMedia.where((m) => !_isHistoryTombstoned(m)),
      ...vodPreview(series: false, limit: 48),
      ...vodPreview(series: true, limit: 48),
      // History seeds taste below; only surface URL/import rows that are still
      // in the on-device library (localMedia is not Drive-synced).
      ...history.take(40).where(_isLibraryBackedShelfItem),
    ];
    // Collapse EN|/FR| / multi-source siblings the same way Films does —
    // For you used to keep one card per stream id and show duplicates.
    final seen = <String>{};
    final deduped = <MediaItem>[];
    final statusStore = TrackerStatusStore(trackerStatuses);
    for (final item in pool) {
      if (item.isLive || item.kind == MediaKind.catchup || item.isEpisode) {
        continue;
      }
      if (!isListedVodSourceVisible(item.sourceId)) continue;
      if (statusStore.excludesForYou(
        tmdbId: item.tmdbId,
        imdbId: item.imdbId,
        tvdbId: item.tvdbId,
        anilistId: item.anilistId,
        simklId: item.simklId,
        title: item.title,
      )) {
        continue;
      }
      final key = _searchDedupeKey(item);
      if (!seen.add(key)) continue;
      if (item.kind == MediaKind.vod && !item.isSeries && !item.isEpisode) {
        deduped.add(resolveVodVariant(item));
      } else {
        deduped.add(item);
      }
    }
    _cachedRecommendations = _recommender.recommend(
      catalog: deduped,
      history: history,
      watchlist: [
        ...watchlist,
        // Letterboxd films as taste seeds (movies only; no live API).
        ...letterboxdWatchlist,
      ],
      remoteBoosts: _remoteRecBoosts,
    );
    _recommendationsStamp = stamp;
    JavpLog.slow(
      'shelf',
      'recommendations in ${watch.elapsedMilliseconds}ms '
          'n=${_cachedRecommendations!.length} '
          'remote=${_remoteRecBoosts.length}',
      watch.elapsedMilliseconds,
      thresholdMs: 16,
    );
    unawaited(_ensureRemoteRecommendations());
    return _cachedRecommendations!;
  }

  /// Background TMDB / SIMKL / Trakt enrich for For you (fail soft).
  Future<void> _ensureRemoteRecommendations() async {
    if (!_appForeground || _remoteRecInflight) return;
    // Don't contest Accueil reveal / post-reveal rematerialize.
    if (!_homeRevealSettled) return;
    final hasRemote =
        tmdb.isConfigured || simkl.isConfigured || trakt.isConfigured;
    if (!hasRemote) return;

    final seedFp = Object.hash(
      history.isEmpty ? null : history.first.id,
      history.length,
      watchlist.isEmpty ? null : watchlist.first.id,
      watchlist.length,
      simklWatching.length,
      tmdb.isConfigured,
      simkl.isAuthenticated,
      trakt.isAuthenticated,
    ).toString();
    if (_remoteRecFingerprint == seedFp) return;

    _remoteRecInflight = true;
    try {
      await _bgQueue.enqueue(
        id: 'for-you-remote',
        priority: BackgroundPriority.low,
        action: () async {
          if (!_appForeground) return;
          final pool = <MediaItem>[
            ...watchlist,
            ...localMedia.where((m) => !_isHistoryTombstoned(m)),
            ...vodPreview(series: false, limit: 64),
            ...vodPreview(series: true, limit: 64),
            ...history.take(40).where(_isLibraryBackedShelfItem),
            ...simklWatching,
            ..._vodStreamCache.values.take(200),
          ];
          final boosts = await _remoteRecEnricher.collectBoosts(
            catalogPool: pool,
            history: history,
            watchlist: watchlist,
            simklWatching: simklWatching,
            serializdWatching: serializdWatching,
            tmdb: tmdb,
            simkl: simkl,
            trakt: trakt,
          );
          if (!_appForeground) return;
          JavpLog.i(
            'shelf',
            'for-you-remote boosts=${boosts.length} pool=${pool.length}',
          );
          final changed =
              boosts.length != _remoteRecBoosts.length ||
              !boosts.keys.every(_remoteRecBoosts.containsKey);
          _remoteRecBoosts = boosts;
          _remoteRecFingerprint = seedFp;
          if (changed) {
            _cachedRecommendations = null;
            _recommendationsStamp = -1;
            // Idle — avoid hitching Accueil mid-paint (journals: 1s frames
            // tagged shelf right after for-you-remote).
            if (!_disposed) _notifyListenersAfterIdle();
          }
        },
      );
    } catch (_) {
      // Fail soft — local ranking remains.
    } finally {
      _remoteRecInflight = false;
    }
  }

  /// TMDB Popular / Trending ∩ local VOD (optional enrichment).
  int get tmdbDiscoveryRevision => _tmdbDiscoveryRevision;

  /// True after at least one fetch/match attempt (success or empty).
  bool get tmdbDiscoveryAttempted => _tmdbDiscoveryAttempted;

  List<MediaItem> get tmdbTrendingShelf {
    unawaited(_ensureTmdbDiscoveryShelves());
    return _filterDiscoveryShelf(_tmdbTrendingShelf);
  }

  List<MediaItem> get tmdbPopularShelf {
    unawaited(_ensureTmdbDiscoveryShelves());
    return _filterDiscoveryShelf(_tmdbPopularShelf);
  }

  List<MediaItem> _filterDiscoveryShelf(List<MediaItem> raw) {
    if (raw.isEmpty) return const [];
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final item in raw) {
      if (!isListedVodSourceVisible(item.sourceId)) continue;
      if (parentalLock?.isItemHidden(item) == true) continue;
      final key = shelfIdentityKey(item);
      if (!seen.add(key)) continue;
      if (item.kind == MediaKind.vod && !item.isSeries && !item.isEpisode) {
        out.add(resolveVodVariant(item));
      } else {
        out.add(item);
      }
    }
    return out;
  }

  Future<void> _ensureTmdbDiscoveryShelves() async {
    if (!_appForeground || _tmdbDiscoveryInflight) return;
    if (!tmdb.isConfigured) {
      if (_tmdbTrendingShelf.isNotEmpty ||
          _tmdbPopularShelf.isNotEmpty ||
          _tmdbDiscoveryAttempted) {
        _tmdbTrendingShelf = const [];
        _tmdbPopularShelf = const [];
        _tmdbDiscoveryAttempted = false;
        _tmdbDiscoveryFingerprint = null;
        _tmdbDiscoveryRevision++;
        if (!_disposed) _notifyListenersAfterIdle();
      }
      return;
    }

    final seedFp = Object.hash(
      tmdb.apiKey.trim(),
      vodCacheCount,
      homeVodShelfRevision,
      sourcesEnabledRevision,
      parentalLock?.lockFilterStamp ?? 'none',
      _useVodDb,
    ).toString();
    if (_tmdbDiscoveryFingerprint == seedFp && _tmdbDiscoveryAttempted) {
      return;
    }

    _tmdbDiscoveryInflight = true;
    try {
      await _bgQueue.enqueue(
        id: 'tmdb-discovery',
        priority: BackgroundPriority.low,
        action: () async {
          if (!_appForeground || !tmdb.isConfigured) return;
          final lists = await _tmdbDiscovery.fetchLists(tmdb);
          if (!_appForeground) return;

          final allHits = <TmdbSearchHit>[...lists.trending, ...lists.popular];
          final tmdbIds = <int>{
            for (final h in allHits)
              if (h.id > 0) h.id,
          }.toList(growable: false);

          final pool = <MediaItem>[];
          if (_useVodDb && tmdbIds.isNotEmpty) {
            try {
              final dbHits = await _vodDb.itemsByTmdbIds(
                tmdbIds,
                allowedSourceIds: _vodAllowedSourceIds(),
                excludeAdult: _parentalExcludeAdult(),
              );
              pool.addAll(dbHits);
            } catch (_) {}
          }
          // Soft title/year fallback pool + non-DB catalogs.
          pool.addAll([
            ...watchlist,
            ...localMedia.where((m) => !_isHistoryTombstoned(m)),
            ...vodPreview(series: false, limit: 64),
            ...vodPreview(series: true, limit: 64),
            ..._vodStreamCache.values.take(400),
            ...catalog.where(
              (m) =>
                  m.kind == MediaKind.vod ||
                  m.kind == MediaKind.series ||
                  m.isSeries,
            ),
          ]);

          final index = await SimklMatchIndex.buildAsync(pool);
          bool accept(MediaItem item) {
            if (!isListedVodSourceVisible(item.sourceId)) return false;
            if (parentalLock?.isItemHidden(item) == true) return false;
            return true;
          }

          final trending = collapseHomeShelfItems(
            TmdbLocalDiscovery.matchHits(
              hits: lists.trending,
              index: index,
              limit: 24,
              accept: accept,
            ),
            limit: 18,
          );
          final popular = collapseHomeShelfItems(
            TmdbLocalDiscovery.matchHits(
              hits: lists.popular,
              index: index,
              limit: 24,
              accept: accept,
            ),
            limit: 18,
          );

          if (!_appForeground) return;
          final changed =
              trending.length != _tmdbTrendingShelf.length ||
              popular.length != _tmdbPopularShelf.length ||
              !_sameShelfIds(trending, _tmdbTrendingShelf) ||
              !_sameShelfIds(popular, _tmdbPopularShelf) ||
              !_tmdbDiscoveryAttempted;
          _tmdbTrendingShelf = trending;
          _tmdbPopularShelf = popular;
          _tmdbDiscoveryFingerprint = seedFp;
          _tmdbDiscoveryAttempted = true;
          JavpLog.i(
            'shelf',
            'tmdb-discovery trending=${trending.length} '
                'popular=${popular.length} hits='
                '${lists.trending.length}+${lists.popular.length}',
          );
          if (changed) {
            _tmdbDiscoveryRevision++;
            if (!_disposed) _notifyListenersAfterIdle();
          }
        },
      );
    } catch (_) {
      _tmdbDiscoveryAttempted = true;
    } finally {
      _tmdbDiscoveryInflight = false;
    }
  }

  static bool _sameShelfIds(List<MediaItem> a, List<MediaItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  List<MediaItem> get favoriteChannels => [
    for (final c in _favoriteChannelsCache)
      if (isSourceContentVisible(c.sourceId) &&
          parentalLock?.isLiveChannelHidden(c) != true)
        c,
  ];

  List<MediaItem> get recentChannels => [
    for (final c in _recentChannelsCache)
      if (isSourceContentVisible(c.sourceId) &&
          parentalLock?.isLiveChannelHidden(c) != true)
        c,
  ];

  /// Sync pick for Android TV Home “Watch live”: last zap, else first favorite,
  /// else first in-memory live channel (live-DB catalogs may need
  /// [resolvePreferredWatchLiveChannel]).
  MediaItem? get preferredWatchLiveChannel {
    if (recentChannels.isNotEmpty) {
      return resolveLiveChannel(recentChannels.first);
    }
    if (favoriteChannels.isNotEmpty) {
      return resolveLiveChannel(favoriteChannels.first);
    }
    final live = liveChannels;
    if (live.isNotEmpty) return resolveLiveChannel(live.first);
    return null;
  }

  /// Async fallback when pinned lists are empty but the live DB has rows.
  Future<MediaItem?> resolvePreferredWatchLiveChannel() async {
    final sync = preferredWatchLiveChannel;
    if (sync != null) return sync;
    final page = await pageLiveChannels(limit: 1);
    if (page.isEmpty) return null;
    return resolveLiveChannel(page.first);
  }

  /// Home “Recent live” row: last watched first, then other recents / favorites.
  List<MediaItem> recentLiveHomeRow({int limit = 12}) {
    final cap = limit.clamp(1, 24);
    final seen = <String>{};
    final out = <MediaItem>[];
    void addAll(Iterable<MediaItem> items) {
      for (final c in items) {
        if (out.length >= cap) return;
        final resolved = resolveLiveChannel(c);
        if (!seen.add(resolved.id)) continue;
        out.add(resolved.copyWith(title: officialLiveTitle(resolved)));
      }
    }

    addAll(recentChannels);
    addAll(favoriteChannels);
    return out;
  }

  /// True when [channel] (or any HD/FHD/SD sibling) is pinned.
  ///
  /// [toggleFavoriteChannel] stores the collapsed listing / preferred id via
  /// [_canonicalLivePinId], so membership must be family-aware — otherwise the
  /// star reads off for the variant the user is watching while the pin exists.
  bool isFavoriteChannel(MediaItem channel) {
    if (favoriteChannelIds.contains(channel.id)) return true;
    for (final v in qualityVariantsFor(channel)) {
      if (favoriteChannelIds.contains(v.id)) return true;
    }
    // Live-DB sync path may not have variants cached yet; match by family key
    // against already-resolved favorite pins (listing rows).
    final key = liveFamilyKey(channel) ?? _liveFamilyKeyById?[channel.id];
    if (key == null) return false;
    for (final fav in _favoriteChannelsCache) {
      final favKey = liveFamilyKey(fav) ?? _liveFamilyKeyById?[fav.id];
      if (favKey != null && favKey == key) return true;
    }
    return false;
  }

  bool isFavoriteCategory(IptvCategory category) =>
      favoriteCategoryIds.contains(category.id);

  bool isFavoriteCategoryId(String categoryId) =>
      favoriteCategoryIds.contains(categoryId);

  /// True when [item] or any VOD language/source sibling is already saved.
  ///
  /// Shelves and title detail resolve a preferred edition via
  /// [resolveVodVariant], so membership must be family-aware — otherwise
  /// "Remove from My List" on the displayed FR| card can miss the EN| row
  /// still stored in [watchlist] (or worse, add a second sibling).
  ///
  /// Episodes resolve to their parent series — My List is series/movies only.
  bool isInWatchlist(MediaItem item) {
    if (item.isEpisode) {
      final series = seriesShellForEpisode(item);
      if (series != null && series.isSeries) return isInWatchlist(series);
      return watchlist.any((w) => w.id == item.id);
    }
    if (watchlist.any((w) => w.id == item.id)) return true;
    if (item.isSeries) {
      final sid = item.id;
      final stream = item.streamId?.trim();
      if (watchlist.any((w) {
        if (!w.isEpisode) return false;
        final wSid = w.seriesId?.trim();
        return wSid == sid ||
            (stream != null && stream.isNotEmpty && wSid == stream);
      })) {
        return true;
      }
    }
    if (item.kind != MediaKind.vod || item.isSeries || item.isEpisode) {
      return false;
    }
    final key = canonicalVodGroupKey(item);
    if (key == null) return false;
    for (final w in watchlist) {
      if (w.kind != MediaKind.vod || w.isSeries || w.isEpisode) continue;
      if (canonicalVodGroupKey(w) == key) return true;
    }
    return false;
  }

  /// Canonical live item for recents/favorites so quality variants (HD/FHD/SD)
  /// collapse into the one parent listing row the UI already shows — never
  /// record each variant the user zapped to or starred.
  Future<MediaItem> _canonicalLivePin(MediaItem channel) async {
    if (_useLiveDb) {
      return (await _liveDb.listingForChannel(channel)) ?? channel;
    }
    if (channel.isLive) {
      return resolveLiveChannel(channel);
    }
    // Catchup clip: map back to the live row via stream/source, then collapse.
    final matched = liveChannels.cast<MediaItem?>().firstWhere(
      (c) => c?.streamId == channel.streamId && c?.sourceId == channel.sourceId,
      orElse: () => null,
    );
    if (matched != null) return resolveLiveChannel(matched);
    return channel;
  }

  /// Canonical id form of [_canonicalLivePin].
  Future<String> _canonicalLivePinId(MediaItem channel) async =>
      (await _canonicalLivePin(channel)).id;

  Future<void> toggleFavoriteChannel(MediaItem channel) async {
    final id = await _canonicalLivePinId(channel);
    if (favoriteChannelIds.contains(id)) {
      favoriteChannelIds = favoriteChannelIds.where((x) => x != id).toList();
    } else {
      favoriteChannelIds = [id, ...favoriteChannelIds];
    }
    // Drop quiet-mode so TV pins update during live/VOD prefetch (same latch
    // as [toggleWatchlist] / [removeFromHistory]).
    _uiQuiet = false;
    await _reloadPinnedLiveChannels();
    notifyListeners();
    await _store.saveFavoriteChannelIds(favoriteChannelIds);
    _noteSyncableChange();
  }

  Future<void> toggleFavoriteCategory(IptvCategory category) async {
    final id = category.id;
    if (favoriteCategoryIds.contains(id)) {
      favoriteCategoryIds = favoriteCategoryIds.where((x) => x != id).toList();
    } else {
      favoriteCategoryIds = [id, ...favoriteCategoryIds];
    }
    // Notify before disk I/O. Drop quiet-mode so Catalog/TV stars paint even
    // while VOD disk hydrate / on-demand prefetch has [_uiQuiet] latched
    // (Movies shelves warm first — favoriting felt like a no-op).
    _uiQuiet = false;
    notifyListeners();
    await _store.saveFavoriteCategoryIds(favoriteCategoryIds);
    _noteSyncableChange();
  }

  Future<void> toggleWatchlist(MediaItem item) async {
    // My List is series/movies — never store orphan "Episode N" rows.
    var target = item;
    if (item.isEpisode) {
      final series = seriesShellForEpisode(item);
      if (series != null && series.isSeries) {
        target = series;
      } else if (_isBareEpisodeTitle(item.title)) {
        return;
      }
      // Standalone title filed under a house `parentId` — keep the title.
    }

    bool isEpisodeOfTarget(MediaItem w) {
      if (!target.isSeries || !w.isEpisode) return false;
      final wSid = w.seriesId?.trim();
      if (wSid == null || wSid.isEmpty) return false;
      return wSid == target.id ||
          (target.streamId != null &&
              target.streamId!.trim().isNotEmpty &&
              wSid == target.streamId!.trim());
    }

    if (isInWatchlist(target)) {
      final key =
          (target.kind == MediaKind.vod &&
              !target.isSeries &&
              !target.isEpisode)
          ? canonicalVodGroupKey(target)
          : null;
      if (key == null) {
        watchlist = watchlist
            .where((w) => w.id != target.id && !isEpisodeOfTarget(w))
            .toList();
      } else {
        watchlist = watchlist.where((w) {
          if (w.id == target.id || isEpisodeOfTarget(w)) return false;
          if (w.kind != MediaKind.vod || w.isSeries || w.isEpisode) {
            return true;
          }
          return canonicalVodGroupKey(w) != key;
        }).toList();
      }
    } else {
      watchlist = [
        target,
        ...watchlist.where((w) => w.id != target.id && !isEpisodeOfTarget(w)),
      ];
    }
    // Notify before disk I/O — awaiting SharedPreferences on desktop made My
    // List feel stuck until relaunch. Drop quiet-mode so prefetch/sync can't
    // latch and swallow this user-facing update (see removeFromHistory).
    _uiQuiet = false;
    notifyListeners();
    await _store.saveWatchlist(watchlist);
    _noteSyncableChange();
  }

  Future<void> recordChannelVisit(MediaItem channel) async {
    if (!channel.isLive && channel.kind != MediaKind.catchup) return;
    final id = await _canonicalLivePinId(channel);
    recentChannelIds = [
      id,
      ...recentChannelIds.where((x) => x != id),
    ].take(40).toList();
    await _store.saveRecentChannelIds(recentChannelIds);
    await _reloadPinnedLiveChannels();
    notifyListeners();
  }

  /// Favorites then recents — a short “jump to” set, not the Guide channel list.
  ///
  /// The TV Guide grid uses the same filtered live list as the Channels tab
  /// (see `_TvGuideTab`). Prefer that list; this getter must not be used to
  /// decide which channels appear in the guide (it previously capped at 60 and
  /// dropped most channels when the live DB was enabled).
  List<MediaItem> get guideChannels {
    final seen = <String>{};
    final out = <MediaItem>[];
    void addAll(Iterable<MediaItem> items) {
      for (final item in items) {
        if (seen.add(item.id)) out.add(item);
      }
    }

    addAll(favoriteChannels);
    addAll(recentChannels);
    return out;
  }

  Map<String, List<MediaItem>> get historyByDay {
    final map = <String, List<MediaItem>>{};
    for (final item in history) {
      final at = item.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final key =
          '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(key, () => []).add(item);
    }
    return map;
  }

  /// Reloads syncable in-memory fields. When [changed] is empty, loads all.
  Future<void> _reloadSyncableSections(List<String> changed) async {
    final all = changed.isEmpty;
    bool need(String section) => all || changed.contains(section);
    final jobs = <Future<void>>[];
    if (need(SnapshotSections.sources)) {
      jobs.add(_store.loadSources().then((v) => sources = v));
    }
    if (need(SnapshotSections.history)) {
      jobs.add(_store.loadHistory().then((v) => history = v));
      jobs.add(_store.loadHistoryDeleted().then((v) => _historyDeleted = v));
    }
    if (need(SnapshotSections.watchlist)) {
      jobs.add(_store.loadWatchlist().then((v) => watchlist = v));
    }
    if (need(SnapshotSections.favoriteChannels)) {
      jobs.add(
        _store.loadFavoriteChannelIds().then((v) => favoriteChannelIds = v),
      );
    }
    if (need(SnapshotSections.favoriteCategories)) {
      jobs.add(
        _store.loadFavoriteCategoryIds().then((v) => favoriteCategoryIds = v),
      );
    }
    if (need(SnapshotSections.recentChannels)) {
      jobs.add(_store.loadRecentChannelIds().then((v) => recentChannelIds = v));
    }
    if (need(SnapshotSections.categories)) {
      jobs.add(_store.loadCategories().then((v) => categories = v));
    }
    if (need(SnapshotSections.preferredLiveQualities)) {
      jobs.add(
        _store.loadPreferredLiveQualities().then(
          (v) => preferredLiveQualities = v,
        ),
      );
    }
    if (need(SnapshotSections.preferredVodVariants)) {
      jobs.add(
        _store.loadPreferredVodVariants().then((v) => preferredVodVariants = v),
      );
    }
    if (need(SnapshotSections.collections)) {
      jobs.add(_store.loadCollections().then((v) => collections = v));
    }
    if (need(SnapshotSections.playlists)) {
      jobs.add(_store.loadPlaylists().then((v) => playlists = v));
    }
    if (need(SnapshotSections.skipSettings)) {
      jobs.add(_store.loadSkipSettings().then((v) => skipSettings = v));
    }
    if (need(SnapshotSections.trackLanguages)) {
      jobs.add(
        _store.loadTrackLanguageSettings().then(
          (v) => trackLanguageSettings = v,
        ),
      );
    }
    if (need(SnapshotSections.downloadSettings)) {
      jobs.add(_store.loadDownloadSettings().then((v) => downloadSettings = v));
    }
    if (need(SnapshotSections.metadataSettings)) {
      jobs.add(_store.loadMetadataSettings().then((v) => metadataSettings = v));
    }
    if (need(SnapshotSections.displaySettings)) {
      jobs.add(_store.loadDisplaySettings().then((v) => displaySettings = v));
    }
    if (need(SnapshotSections.proxySettings)) {
      jobs.add(_store.loadProxySettings().then((v) => proxy = v));
    }
    if (need(SnapshotSections.liveScrubMode)) {
      jobs.add(
        _store
            .loadLiveScrubMode(fallback: _defaultLiveScrubMode)
            .then((v) => liveScrubMode = v),
      );
    }
    if (need(SnapshotSections.liveQualityMode)) {
      jobs.add(_store.loadLiveQualityMode().then((v) => liveQualityMode = v));
    }
    if (need(SnapshotSections.mediaServerQuality)) {
      jobs.add(
        _store.loadMediaServerStreamQuality().then(
          (v) => mediaServerStreamQuality = v,
        ),
      );
    }
    if (need(SnapshotSections.cyclePlaybackSpeeds)) {
      jobs.add(
        _store.loadCyclePlaybackSpeeds().then((v) => cyclePlaybackSpeeds = v),
      );
    }
    if (need(SnapshotSections.epgReminders)) {
      jobs.add(_store.loadEpgReminders().then((v) => epgReminders = v));
    }
    if (need(SnapshotSections.trackerStatuses)) {
      jobs.add(_store.loadTrackerStatuses().then((v) => trackerStatuses = v));
    }
    if (jobs.isEmpty) return;
    await Future.wait<void>(jobs);
  }

  /// Rewrites history/watchlist rows whose [MediaItem.sourceId] no longer
  /// exists locally but clearly matches a current catalog title.
  ///
  /// Profile sync carries sources + history separately. Re-adding a catalog on
  /// a new device (new UUID) before sync, or a seed merge that keeps local
  /// sources, leaves history pointing at missing ids — tiles then fall back to
  /// "Custom catalog". Magnet rows (custom catalogs) also heal via tracker hosts
  /// when the series is not in the on-device catalog cache.
  Future<bool> _healOrphanedSourceIds() async {
    final known = {for (final s in sources) s.id};
    final idToSource = <String, String>{};
    final ambiguous = <String>{};

    void note(String? key, String sourceId) {
      final k = key?.trim();
      if (k == null || k.isEmpty || !known.contains(sourceId)) return;
      final existing = idToSource[k];
      if (existing == null) {
        idToSource[k] = sourceId;
      } else if (existing != sourceId) {
        ambiguous.add(k);
      }
    }

    for (final row in catalog) {
      final sid = row.sourceId;
      if (sid == null) continue;
      note(row.id, sid);
      note(row.streamId, sid);
      note(row.seriesId, sid);
    }
    for (final k in ambiguous) {
      idToSource.remove(k);
    }

    String? guessFor(MediaItem item) {
      final sid = item.sourceId;
      if (sid != null && known.contains(sid)) return null;
      return idToSource[item.id] ??
          (item.seriesId != null ? idToSource[item.seriesId!.trim()] : null) ??
          (item.streamId != null ? idToSource[item.streamId!.trim()] : null) ??
          _guessCustomCatalogSourceIdFromPlayUrl(item.playUrl);
    }

    var changed = false;
    List<MediaItem> healList(List<MediaItem> items) {
      var touched = false;
      final next = <MediaItem>[];
      for (final item in items) {
        final guess = guessFor(item);
        if (guess == null) {
          next.add(item);
          continue;
        }
        touched = true;
        next.add(item.copyWith(sourceId: guess));
      }
      if (touched) changed = true;
      return touched ? next : items;
    }

    history = healList(history);
    watchlist = healList(watchlist);

    if (!changed) return false;
    await Future.wait([
      _store.saveHistory(history),
      _store.saveWatchlist(watchlist),
    ]);
    _noteSyncableChange();
    return true;
  }

  /// How old a source's last sync can be before idle startup refresh picks it up.
  static const _idleSourceSyncStale = Duration(hours: 24);

  /// Soft-sync wave size after Accueil settle — remaining candidates requeue.
  static const _idleSourceSyncWaveCap = 2;

  bool _idleSourceSyncScheduled = false;

  /// Soft (non-blockUi) source syncs in flight — caps cold-start stampede when
  /// Drive rebuild + idle-source-sync + manual paths overlap.
  int _activeSoftSourceSyncs = 0;
  final List<Completer<void>> _softSourceSyncWaiters = [];

  /// Concurrent soft syncs: 1 until Accueil reveal settles, then 2.
  int get _maxSoftSourceSyncs => _homeRevealSettled ? 2 : 1;

  Future<void> _acquireSoftSourceSyncSlot({required String reason}) async {
    while (_activeSoftSourceSyncs >= _maxSoftSourceSyncs) {
      final c = Completer<void>();
      _softSourceSyncWaiters.add(c);
      JavpLog.i(
        'source',
        'soft-sync wait slot reason=$reason '
            'active=$_activeSoftSourceSyncs max=$_maxSoftSourceSyncs',
      );
      await c.future;
    }
    _activeSoftSourceSyncs++;
  }

  void _releaseSoftSourceSyncSlot() {
    if (_activeSoftSourceSyncs > 0) _activeSoftSourceSyncs--;
    final max = _maxSoftSourceSyncs;
    while (_softSourceSyncWaiters.isNotEmpty && _activeSoftSourceSyncs < max) {
      final c = _softSourceSyncWaiters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
  }

  /// Background refresh of empty / stale sources after Home is interactive.
  ///
  /// Low-priority, one source at a time; yields when SIMKL (or other high
  /// work) is waiting so cold start stays responsive. Mid-sync UI notifies
  /// are suppressed — large catalog merges otherwise rebuild every tab.
  bool get _shellAllowsBackgroundApply =>
      _appForeground && _desktopShellActive && !_shellThawing;

  bool get _allowIdleBackgroundWork =>
      _shellAllowsBackgroundApply && !_playbackActive;

  static bool _isOpportunisticSourceSync(String reason) {
    final root = _idleJobRootReason(reason);
    return root == 'idle-source-sync' || root == 'bootstrap' || root == 'swr';
  }

  /// Yield a frame, then wait out blur / restore thaw so Windows can take
  /// focus and clicks. Opportunistic idle syncs abort if the shell went away.
  Future<bool> _yieldSoftSyncToShell({
    required bool blockUi,
    required String reason,
    required int generation,
  }) async {
    // Duration.zero is not enough on Windows — the embedder needs a real
    // timer turn to pump WM_ACTIVATE / clicks while sync is running.
    await (blockUi ? Future<void>.delayed(Duration.zero) : pumpUi());
    if (_disposed) return false;
    if (blockUi) return true;
    await _yieldToBrowse(reason: reason);
    if (_isOpportunisticSourceSync(reason) &&
        generation != _idleWorkGeneration) {
      JavpLog.i(
        'source',
        'sync yield abort reason=$reason gen=$generation '
            'now=$_idleWorkGeneration (blur/background)',
      );
      return false;
    }
    var waited = false;
    var aborted = false;
    // Manual Synchroniser must not park on a stuck shell=false latch while
    // the user is foreground — that was "wait-shell timeout fg=true shell=false".
    if (reason == 'manual') {
      if (_appForeground && !_desktopShellActive) {
        JavpLog.w(
          'desktop',
          'recover shell before manual sync yield '
              '(fg=true shell=false)',
        );
        setDesktopShellActive(true);
      }
      await pumpUi(label: 'manual-sync-yield');
      return !_disposed;
    }
    final waitDeadline = DateTime.now().add(debugSoftSyncShellWaitCap);
    await UiStallWatchdog.span('wait-shell', () async {
      while (!_disposed && !_shellAllowsBackgroundApply) {
        if (_isOpportunisticSourceSync(reason) &&
            generation != _idleWorkGeneration) {
          JavpLog.i(
            'source',
            'sync yield abort reason=$reason gen=$generation '
                'now=$_idleWorkGeneration (blur/background)',
          );
          aborted = true;
          return;
        }
        waited = true;
        if (DateTime.now().isAfter(waitDeadline)) {
          JavpLog.w(
            'source',
            'sync wait-shell timeout reason=$reason '
                'fg=$_appForeground shell=$_desktopShellActive '
                'thaw=$_shellThawing — continue anyway',
          );
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 32));
      }
    });
    if (_disposed || aborted) return false;
    if (_isOpportunisticSourceSync(reason) &&
        generation != _idleWorkGeneration) {
      return false;
    }
    if (waited) {
      JavpLog.i(
        'source',
        'sync resume after shell wait reason=$reason '
            'shell=$_desktopShellActive thaw=$_shellThawing',
      );
    }
    return true;
  }

  void _cancelShellThaw() {
    _shellThawTimer?.cancel();
    _shellThawTimer = null;
    _shellThawing = false;
  }

  void _beginShellThaw({required String reason}) {
    _shellThawing = true;
    _shellThawTimer?.cancel();
    JavpLog.i('lifecycle', 'shell thaw start reason=$reason');
    _shellThawTimer = Timer(_shellThawDuration, () {
      _shellThawTimer = null;
      if (_disposed) return;
      _shellThawing = false;
      JavpLog.i('lifecycle', 'shell thaw done reason=$reason');
      if (_thawNotifyPending) {
        _thawNotifyPending = false;
        _notifyListenersAfterIdle();
        syncStatusListenable.tick();
      }
      // Focus starts thaw before indexes can resume (allowIdle=false while
      // thawing). Resume here so Accueil IPTV rails are not stuck on the
      // Plex/snapshot fallback until the next Synchroniser ends.
      _resumePostHydrateIndexesIfNeeded();
      _scheduleHomeFamilyHydratePump();
    });
  }

  /// Merge catalog dump details in one map copy (the old per-row spread was
  /// O(n²) on the UI isolate and froze Windows restore / clicks).
  @visibleForTesting
  static Map<String, MediaDetails> mergeCatalogDetails(
    Map<String, MediaDetails> existing,
    Map<String, MediaDetails> incoming,
  ) {
    if (incoming.isEmpty) return existing;
    final next = Map<String, MediaDetails>.of(existing);
    next.addAll(incoming);
    for (final entry in incoming.entries) {
      final mediaId = entry.value.mediaItemId;
      if (mediaId != null && mediaId.isNotEmpty) {
        next[mediaId] = entry.value;
      }
    }
    return next;
  }

  /// Category / title / Live group / search / play URL — jumps the HTTP queue
  /// so an in-flight source sync does not starve browsing.
  Future<T> _runUserFacing<T>(Future<T> Function() action) =>
      _interactive.run(action);

  /// Pause between background sync units while the user is fetching something.
  Future<void> _yieldToBrowse({String? reason}) async {
    if (!_interactive.isBusy) return;
    JavpLog.i(
      'bg',
      'yield to browse'
          '${reason != null ? ' reason=$reason' : ''}',
    );
    await _interactive.yieldToInteractive();
  }

  /// Strip stacked `defer:` / `coalesce:` so logs stay readable (no
  /// `defer:defer:…:bootstrap` spam while AFK/blur retries).
  static String _idleJobRootReason(String reason) {
    var r = reason;
    while (true) {
      if (r.startsWith('defer:')) {
        r = r.substring('defer:'.length);
        continue;
      }
      if (r.startsWith('coalesce:')) {
        r = r.substring('coalesce:'.length);
        continue;
      }
      if (r.startsWith('wave:')) {
        r = r.substring('wave:'.length);
        continue;
      }
      break;
    }
    return r.isEmpty ? 'unspecified' : r;
  }

  Future<void> _scheduleIdleSourceSync({String reason = 'unspecified'}) async {
    if (_idleSourceSyncScheduled) return;
    _idleSourceSyncScheduled = true;
    final root = _idleJobRootReason(reason);
    JavpLog.i(
      'source',
      'idle-source-sync enqueue reason=$root '
          'queue=${_bgQueue.pendingCount}',
    );
    await _bgQueue.enqueue(
      id: 'idle-source-sync',
      priority: BackgroundPriority.low,
      action: () async {
        // AFK / alt-tab / mid-watch — don't start a full catalog re-import.
        // Yield without a self-timer: focus coalesce re-enqueues. Timer retries
        // while blurred spammed `defer:defer:…` every 4s and fought cancel.
        if (!_allowIdleBackgroundWork) {
          _idleSourceSyncScheduled = false;
          JavpLog.i(
            'source',
            'idle-source-sync yield reason=$root '
                'fg=$_appForeground shell=$_desktopShellActive '
                'playback=$_playbackActive — resume on focus',
          );
          return;
        }
        if (_bgQueue.shouldDeferIdleWork) {
          _idleSourceSyncScheduled = false;
          JavpLog.i(
            'source',
            'idle-source-sync soft-defer reason=$root '
                'queue=${_bgQueue.pendingCount}',
          );
          unawaited(
            Future<void>.delayed(
              const Duration(seconds: 4),
              () => _scheduleIdleSourceSync(reason: 'defer:$root'),
            ),
          );
          return;
        }

        // Well after first paint, SIMKL, and VOD disk hydrate.
        await Future<void>.delayed(const Duration(seconds: 25));
        if (!_allowIdleBackgroundWork) {
          _idleSourceSyncScheduled = false;
          JavpLog.i(
            'source',
            'idle-source-sync yield after delay reason=$root — resume on focus',
          );
          return;
        }
        if (_bgQueue.shouldDeferIdleWork) {
          _idleSourceSyncScheduled = false;
          unawaited(
            Future<void>.delayed(
              const Duration(seconds: 4),
              () => _scheduleIdleSourceSync(reason: 'defer:$root'),
            ),
          );
          return;
        }

        // Belt-and-suspenders: only scheduled post-reveal, but Accueil trickle
        // must finish before any soft source import.
        await waitUntilHomeRevealSettled();
        if (!_allowIdleBackgroundWork) {
          _idleSourceSyncScheduled = false;
          return;
        }

        final work = Stopwatch()..start();
        final candidates = _idleSourceSyncCandidates();
        final wave = candidates.take(_idleSourceSyncWaveCap).toList();
        final remaining = candidates.length - wave.length;
        JavpLog.i(
          'bg',
          'idle-source-sync start reason=$root '
              'candidates=${candidates.length} wave=${wave.length} '
              'delayMs=25000',
        );
        for (final source in wave) {
          if (_sourceById(source.id) == null) continue;
          if (_syncingSourceIds.contains(source.id)) continue;
          if (!_allowIdleBackgroundWork) {
            _idleSourceSyncScheduled = false;
            JavpLog.i(
              'source',
              'idle-source-sync yield mid-loop reason=$root — resume on focus',
            );
            return;
          }
          if (_bgQueue.shouldDeferIdleWork) {
            // Don't block the single worker — release so high-priority work runs.
            _idleSourceSyncScheduled = false;
            unawaited(
              Future<void>.delayed(
                const Duration(seconds: 4),
                () => _scheduleIdleSourceSync(reason: 'defer:$root'),
              ),
            );
            return;
          }
          await _yieldToBrowse(reason: 'idle-source-sync');
          if (!_allowIdleBackgroundWork) {
            _idleSourceSyncScheduled = false;
            return;
          }
          final wasQuiet = _uiQuiet;
          _uiQuiet = true;
          try {
            // No forced VOD pull — idle warm / on-demand covers that.
            await syncSource(
              source.id,
              blockUi: false,
              reason: 'idle-source-sync',
            );
          } catch (_) {
            // Partial catalogs are fine; Sources → Sync retries.
          } finally {
            _uiQuiet = wasQuiet;
            _notifyListenersAfterIdle();
          }
          // Give frames / GC room before the next heavy import.
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        JavpLog.i(
          'bg',
          'idle-source-sync work in ${work.elapsedMilliseconds}ms '
              'wave=${wave.length} remaining=$remaining reason=$root',
        );
        _idleSourceSyncScheduled = false;
        if (remaining > 0 && _allowIdleBackgroundWork) {
          unawaited(
            Future<void>.delayed(
              const Duration(seconds: 8),
              () => _scheduleIdleSourceSync(reason: 'wave:$root'),
            ),
          );
        }
      },
    );
  }

  /// Enabled sources with an empty shelf or a stale [IptvSource.lastSyncedAt].
  /// Empty catalogs first, then oldest sync time.
  ///
  /// Stale M3U is skipped: a full playlist reparse stalls the UI isolate even
  /// when notifies are quiet — only re-import M3U when the shelf is empty.
  ///
  /// Live-only M3U / Xtream rows live in SQLite, not [catalog]. Counting catalog
  /// rows alone made every cold start treat them as empty and re-fetch (~40s).
  List<IptvSource> _idleSourceSyncCandidates() {
    final staleBefore = DateTime.now().subtract(_idleSourceSyncStale);
    final counts = <String, int>{};
    for (final m in catalog) {
      final sid = m.sourceId;
      if (sid == null) continue;
      counts[sid] = (counts[sid] ?? 0) + 1;
    }

    final empty = <IptvSource>[];
    final stale = <IptvSource>[];

    for (final source in sources) {
      if (!source.enabled) continue;
      if (source.id == demoSourceId) continue;
      if (_syncingSourceIds.contains(source.id)) continue;

      final isEmpty = _sourceShelfLooksEmpty(source, counts);
      final last = source.lastSyncedAt;
      final isStale = last == null || last.isBefore(staleBefore);
      if (!isEmpty && !isStale) continue;
      // Heavy full reparse — don't do this just for freshness on cold start.
      if (!isEmpty && source.type == IptvSourceType.m3u) continue;
      // XMLTV has no channels; only refresh when missing/stale.
      if (source.type == IptvSourceType.xmltv && !isStale) continue;

      // A 404/failed M3U has no SQLite rows, so it looks empty forever and
      // used to re-fetch on every idle/SWR/rebuild (status strip + UI hitch).
      if (skipRecentEmptyHeavySyncRetry(
        type: source.type,
        looksEmpty: isEmpty,
        lastSyncedAt: last,
        now: DateTime.now(),
        staleAfter: _idleSourceSyncStale,
      )) {
        continue;
      }

      if (isEmpty) {
        empty.add(source);
      } else {
        stale.add(source);
      }
    }

    stale.sort((a, b) {
      final aAt = a.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = b.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aAt.compareTo(bAt);
    });
    return [...empty, ...stale];
  }

  /// Whether idle sync should treat [source] as having no content yet.
  bool _sourceShelfLooksEmpty(
    IptvSource source,
    Map<String, int> catalogCounts,
  ) {
    return sourceShelfLooksEmpty(
      type: source.type,
      catalogCount: catalogCounts[source.id] ?? 0,
      hasLocalLiveRows: _liveDbSourceIds.contains(source.id),
      hasLocalVodRows: _vodDbSourceIds.contains(source.id),
      lastSyncedAt: source.lastSyncedAt,
    );
  }

  /// Full live-listing rewrite is IPTV-scale CPU. Never do it before Accueil
  /// has painted — [_itemFromRow] of ~28k channels froze Windows on startup.
  Future<void> _reindexLiveFamiliesAfterReveal() async {
    await waitUntilHomeRevealSettled();
    if (_disposed || !_useLiveDb) return;
    await pumpUi();
    await _maybeReindexLiveFamilyKeys();
  }

  Future<void> _hydrateEpgReminders() async {
    try {
      epgReminders = await _store.loadEpgReminders();
      epgReminders = [
        for (final r in epgReminders)
          if (!r.isPast) r,
      ];
      if (epgReminders.length > _maxEpgReminders) {
        epgReminders = epgReminders.sublist(0, _maxEpgReminders);
      }
      await _store.saveEpgReminders(epgReminders);
      await _reminders.ensureInitialized();
      await _reminders.rescheduleAll(epgReminders);
      notifyListeners();
    } catch (_) {
      // Reminders are best-effort; never fail bootstrap.
    }
  }

  /// One-line feature map for bug reports — no hosts, passwords, or tokens.
  ///
  /// Skips duplicate lines when the fingerprint is unchanged (e.g. profile
  /// sync with identical sources). Bootstrap always logs so a fresh session
  /// has a baseline.
  String? _lastSourcesFeatureSummaryFp;

  void _logSourcesFeatureSummary({required String reason}) {
    try {
      final lock = parentalLock;
      final pin = lock == null || !lock.ready ? null : lock.hasPin;
      final line = buildSourcesFeatureSummary(
        sources: sources,
        proxy: proxy,
        simklLinked: simkl.isAuthenticated,
        traktLinked: trakt.isAuthenticated,
        serializdLinked: serializd.isAuthenticated,
        betaseriesLinked: betaseries.isAuthenticated,
        letterboxdLinked:
            letterboxdLastImportAt != null || letterboxdWatchlist.isNotEmpty,
        tmdbConfigured: tmdb.isConfigured,
        parentalPin: pin,
      );
      if (reason != 'bootstrap' && line == _lastSourcesFeatureSummaryFp) {
        return;
      }
      _lastSourcesFeatureSummaryFp = line;
      JavpLog.i('sources', 'summary reason=$reason $line');
    } catch (_) {
      // Diagnostics must never break source add/remove/bootstrap.
    }
  }

  Future<void> _rebuildNetworkClients() async {
    final watch = Stopwatch()..start();
    final injectedHttp = _injectedHttp;
    if (injectedHttp != null) {
      _attachScopedHttpClients(proxied: injectedHttp, direct: injectedHttp);
      JavpLog.i(
        'net',
        'rebuild in ${watch.elapsedMilliseconds}ms proxy=injected',
      );
      return;
    }
    _closeOwnedHttpClients();
    final direct = createDnsFallbackHttpClient();
    final proxied = proxy.isActive ? await createAppHttpClient(proxy) : direct;
    _ownedDirectHttp = direct;
    _ownedProxiedHttp = identical(proxied, direct) ? null : proxied;
    _attachScopedHttpClients(proxied: proxied, direct: direct);
    JavpLog.i(
      'net',
      'rebuild in ${watch.elapsedMilliseconds}ms proxy=${proxy.isActive}',
    );
  }

  void _closeOwnedHttpClients() {
    final owned = <http.Client>{?_ownedDirectHttp, ?_ownedProxiedHttp};
    for (final client in owned) {
      try {
        client.close();
      } catch (_) {}
    }
    _ownedDirectHttp = null;
    _ownedProxiedHttp = null;
  }

  void _attachScopedHttpClients({
    required http.Client proxied,
    required http.Client direct,
  }) {
    final observed = identical(proxied, direct)
        ? proxied
        : FallbackHttpClient(
            primary: proxied,
            // Ticked scopes stay on the proxy. Direct retry is opt-in
            // (Settings → Network → retry without proxy if handshake fails).
            fallback: proxy.allowDirectFallback ? direct : null,
            onProxyFailure: _onProxyHandshakeFailure,
          );

    http.Client pick(ProxyTrafficScope scope) {
      if (!proxy.isActiveFor(scope)) return direct;
      return observed;
    }

    http.Client prioritize(http.Client inner) =>
        PrioritizedHttpClient(inner, gate: _interactive);

    final iptv = prioritize(pick(ProxyTrafficScope.iptv));
    final catalogs = prioritize(pick(ProxyTrafficScope.catalogs));
    final mediaServers = prioritize(pick(ProxyTrafficScope.mediaServers));

    _http = iptv;
    // Offline downloads share the proxy (or direct) path, not the interactive
    // priority gate: bulk transfers must not starve foreground browse requests.
    _downloads.setHttpClient(pick(ProxyTrafficScope.downloads));
    // Artwork must travel the same path as metadata that references it.
    // Not prioritized: poster CDNs are a different host (and have their own
    // visible-vs-prefetch queue).
    JavpImageCache.instance.attachHttpClient(pick(ProxyTrafficScope.metadata));
    _customCatalog =
        _injectedCustomCatalog ?? CustomCatalogClient(httpClient: catalogs);
    _customCatalog.profile = catalogClientProfileForDevice(
      appVersion: _cachedAppVersion,
    );
    _xtream = _injectedXtream ?? XtreamClient(httpClient: iptv);
    _stalker = StalkerClient(httpClient: iptv);
    _simkl =
        _injectedSimkl ??
        SimklClient(httpClient: pick(ProxyTrafficScope.metadata));
    _tmdb =
        _injectedTmdb ??
        TmdbClient(httpClient: pick(ProxyTrafficScope.metadata));
    _trakt =
        _injectedTrakt ??
        TraktClient(httpClient: pick(ProxyTrafficScope.metadata));
    _serializd =
        _injectedSerializd ??
        SerializdClient(httpClient: pick(ProxyTrafficScope.metadata));
    _betaseries =
        _injectedBetaseries ??
        BetaseriesClient(httpClient: pick(ProxyTrafficScope.metadata));
    _wireEnrichers();
    _segments =
        _injectedSegments ??
        SegmentResolver(httpClient: pick(ProxyTrafficScope.metadata));
    _jellyfin = JellyfinClient(httpClient: mediaServers);
    _emby = EmbyClient(httpClient: mediaServers);
    _plex = PlexClient(httpClient: mediaServers);
    _plexAccount = PlexAccountClient(httpClient: mediaServers);
  }

  void _wireEnrichers() {
    _simklEnricher = SimklEnricher(_simkl, credentials: () => simkl);
    _traktEnricher = TraktEnricher(_trakt, credentials: () => trakt);
    _tmdbEnricher = TmdbEnricher(_tmdb, credentials: () => tmdb);
    _remoteRecEnricher = ForYouRemoteEnricher(
      tmdbClient: _tmdb,
      simklClient: _simkl,
      traktClient: _trakt,
    );
    _tmdbDiscovery = TmdbLocalDiscovery(tmdbClient: _tmdb);
  }

  MetadataEnricher? get activeEnricher {
    switch (metadataSettings.provider) {
      case MetadataProviderId.off:
        return null;
      case MetadataProviderId.simkl:
        return _simklEnricher;
      case MetadataProviderId.trakt:
        return _traktEnricher;
      case MetadataProviderId.tmdb:
        return _tmdbEnricher;
    }
  }

  bool get isMetadataEnricherAvailable {
    final e = activeEnricher;
    return e != null && e.isAvailable;
  }

  Future<void> saveMetadataSettings(MetadataSettings settings) async {
    metadataSettings = settings;
    // Idle notify: switch tile already shows the new value; avoid settle hitch.
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveMetadataSettings(settings);
      _noteSyncableChange();
    });
  }

  Future<void> saveDisplaySettings(DisplaySettings settings) async {
    displaySettings = settings;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveDisplaySettings(settings);
      _noteSyncableChange();
    });
  }

  Future<bool> loadBrowsePanelCollapsed() => _store.loadBrowsePanelCollapsed();

  Future<void> saveBrowsePanelCollapsed(bool collapsed) =>
      _store.saveBrowsePanelCollapsed(collapsed);

  Future<MyListUiPrefs> loadMyListUiPrefs() => _store.loadMyListUiPrefs();

  Future<void> saveMyListUiPrefs(MyListUiPrefs prefs) =>
      _store.saveMyListUiPrefs(prefs);

  Future<CatalogBrowsePrefs> loadCatalogBrowsePrefs() async {
    if (_catalogBrowsePrefsLoaded) return _catalogBrowsePrefs;
    final loaded = await _store.loadCatalogBrowsePrefs();
    _catalogBrowsePrefsLoaded = true;
    if (loaded.stamp != _catalogBrowsePrefs.stamp) {
      _catalogBrowsePrefs = loaded;
      notifyListeners();
    } else {
      _catalogBrowsePrefs = loaded;
    }
    return _catalogBrowsePrefs;
  }

  CatalogBrowsePrefs get catalogBrowsePrefs => _catalogBrowsePrefs;

  CatalogBrowsePrefs _catalogBrowsePrefs = CatalogBrowsePrefs.defaults;
  bool _catalogBrowsePrefsLoaded = false;

  Future<void> setCatalogBrowsePrefs(CatalogBrowsePrefs prefs) async {
    if (_catalogBrowsePrefsLoaded && prefs.stamp == _catalogBrowsePrefs.stamp) {
      return;
    }
    _catalogBrowsePrefs = prefs;
    _catalogBrowsePrefsLoaded = true;
    notifyListeners();
    await _store.saveCatalogBrowsePrefs(prefs);
  }

  /// History + tracker stamp so Catalog can refresh hide-watched shelves.
  int get catalogBrowseStamp => Object.hash(
    _historyEpoch,
    identityHashCode(history),
    history.length,
    identityHashCode(trackerStatuses),
    trackerStatuses.length,
    tmdbDiscoveryRevision,
    _catalogBrowsePrefs.stamp,
  );

  CatalogWatchedIndex get catalogWatchedIndex {
    final stamp = catalogBrowseStamp;
    final cached = _catalogWatchedIndex;
    if (cached != null && stamp == _catalogWatchedStamp) return cached;
    final index = CatalogWatchedIndex(
      history: history,
      trackerStatuses: trackerStatuses,
    );
    _catalogWatchedIndex = index;
    _catalogWatchedStamp = stamp;
    return index;
  }

  CatalogWatchedIndex? _catalogWatchedIndex;
  int _catalogWatchedStamp = -1;

  Map<int, int> get catalogPopularTmdbRank => catalogPopularRankByTmdbId(
    trending: _tmdbTrendingShelf,
    popular: _tmdbPopularShelf,
  );

  Iterable<String> catalogItemExtraGenres(MediaItem item) {
    final details =
        detailsCache[item.detailsId ?? item.id] ?? detailsCache[item.id];
    return details?.genres ?? const [];
  }

  List<MediaItem> applyCatalogBrowseItems(
    Iterable<MediaItem> items, {
    required CatalogBrowsePrefs prefs,
    int? limit,
  }) {
    return applyCatalogBrowse(
      items,
      prefs: prefs,
      watched: catalogWatchedIndex,
      popularRankByTmdbId: catalogPopularTmdbRank,
      extraGenres: catalogItemExtraGenres,
      limit: limit,
    );
  }

  /// Genre chips for the Catalog filter sheet (loaded VOD + details cache).
  List<String> catalogBrowseGenreOptions({String? categoryName, bool? series}) {
    final set = <String>{};
    void addAll(Iterable<String> raw) {
      for (final g in raw) {
        final t = g.trim();
        if (t.isNotEmpty) set.add(t);
      }
    }

    addAll(allGenres);
    for (final item in _vodStreamCache.values) {
      if (categoryName != null && (item.group ?? '') != categoryName) continue;
      if (series != null) {
        if (series && !item.isSeries) continue;
        if (!series && item.isSeries) continue;
      }
      addAll(item.genres);
      addAll(catalogItemExtraGenres(item));
    }
    if (categoryName == null) {
      final index = _vodByGroupIndex;
      if (index != null) {
        for (final bucket in index.values) {
          for (final item in bucket.take(40)) {
            addAll(item.genres);
          }
        }
      }
    }
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (list.length > 48) return list.sublist(0, 48);
    return list;
  }

  static VodCatalogOrder _vodOrderForBrowse(CatalogBrowsePrefs? browse) {
    switch (browse?.sort) {
      case CatalogBrowseSort.yearDesc:
        return VodCatalogOrder.year;
      case CatalogBrowseSort.popular:
        return VodCatalogOrder.popularity;
      case CatalogBrowseSort.ratingDesc:
        return VodCatalogOrder.rating;
      case CatalogBrowseSort.titleAsc:
      case null:
        return VodCatalogOrder.title;
    }
  }

  /// Local watchlist + tracker shelves (SIMKL Watching / Plan, Trakt,
  /// Plex, Letterboxd) for My List.
  ///
  /// Dedupes VOD language/source siblings via [shelfIdentityKey]. Local wins;
  /// then Watching, Plan-to-Watch, Trakt, Letterboxd (first tracker to claim a
  /// key sticks). Episode rows are promoted to their series (or hidden).
  List<MediaItem> myListBrowseItems({
    MyListSourceFilter source = MyListSourceFilter.all,
  }) {
    final effective = source == MyListSourceFilter.simkl
        ? MyListSourceFilter.simklWatching
        : source;

    List<MediaItem> dedupe(Iterable<MediaItem> items) {
      final out = <MediaItem>[];
      final seen = <String>{};
      for (final raw in items) {
        final item = _myListBrowseRow(raw);
        if (item == null) continue;
        final key = shelfIdentityKey(item);
        if (!seen.add(key)) continue;
        out.add(item);
      }
      return out;
    }

    if (effective == MyListSourceFilter.simklWatching) {
      return dedupe(simklWatching);
    }
    if (effective == MyListSourceFilter.simklPlan) {
      return dedupe(simklPlanToWatch);
    }
    if (effective == MyListSourceFilter.trakt) {
      return dedupe(traktWatchlist);
    }
    if (effective == MyListSourceFilter.plex) {
      return dedupe(plexWatchlist);
    }
    if (effective == MyListSourceFilter.letterboxd) {
      return dedupe(letterboxdWatchlist);
    }
    if (effective == MyListSourceFilter.serializdWatching) {
      return dedupe(serializdWatching);
    }
    if (effective == MyListSourceFilter.serializdWatchlist) {
      return dedupe(serializdWatchlist);
    }
    if (effective == MyListSourceFilter.betaseriesWatching) {
      return dedupe(betaseriesWatching);
    }
    if (effective == MyListSourceFilter.betaseriesPlan) {
      return dedupe(betaseriesPlan);
    }

    final seen = <String>{};
    final local = <MediaItem>[];
    for (final raw in watchlist) {
      if (!isSourceContentVisible(raw.sourceId)) continue;
      final item = _myListBrowseRow(raw);
      if (item == null) continue;
      final key = shelfIdentityKey(item);
      if (!seen.add(key)) continue;
      if (item.kind == MediaKind.vod && !item.isSeries && !item.isEpisode) {
        local.add(resolveVodVariant(item));
      } else {
        local.add(item);
      }
    }

    if (effective == MyListSourceFilter.local) return local;

    final fromTrackers = <MediaItem>[];
    for (final raw in [
      ...simklWatching,
      ...simklPlanToWatch,
      ...traktWatchlist,
      ...plexWatchlist,
      ...letterboxdWatchlist,
      ...serializdWatching,
      ...serializdWatchlist,
      ...betaseriesWatching,
      ...betaseriesPlan,
    ]) {
      final item = _myListBrowseRow(raw);
      if (item == null) continue;
      final key = shelfIdentityKey(item);
      if (!seen.add(key)) continue;
      fromTrackers.add(item);
    }
    return [...local, ...fromTrackers];
  }

  /// My List shows series/movies — promote episode cards or drop orphans.
  MediaItem? _myListBrowseRow(MediaItem item) {
    if (!item.isEpisode) return item;
    final series = seriesShellForEpisode(item);
    if (series == null || !series.isSeries) return null;
    return series.copyWith(
      lastWatchedAt: item.lastWatchedAt ?? series.lastWatchedAt,
      progress: item.progress > series.progress
          ? item.progress
          : series.progress,
      subtitle: item.subtitle ?? series.subtitle,
      simklId: series.simklId ?? item.simklId,
    );
  }

  /// Synced intent says link, but this device has no token yet.
  bool get needsTrackerDeviceLink => trackerNeedsDeviceLink(
    settings: metadataSettings,
    simklAuthenticated: simkl.isAuthenticated,
    traktAuthenticated: trakt.isAuthenticated,
    serializdAuthenticated: serializd.isAuthenticated,
    betaseriesAuthenticated: betaseries.isAuthenticated,
  );

  Future<bool> isTrackerLinkPromptDismissed() =>
      _store.loadTrackerLinkPromptDismissed();

  Future<void> dismissTrackerLinkPrompt() =>
      _store.saveTrackerLinkPromptDismissed(true);

  Future<void> clearTrackerLinkPromptDismissed() =>
      _store.saveTrackerLinkPromptDismissed(false);

  Future<bool> isSoftTrackerSetupDismissed() =>
      _store.loadSoftTrackerSetupDismissed();

  Future<void> dismissSoftTrackerSetup() =>
      _store.saveSoftTrackerSetupDismissed(true);

  Future<void> clearSoftTrackerSetupDismissed() =>
      _store.saveSoftTrackerSetupDismissed(false);

  Future<bool> testTrakt() => _trakt.validate(trakt);

  Future<TraktDeviceSession> requestTraktDeviceCode() {
    return _trakt.requestDeviceCode(trakt);
  }

  Future<TraktTokenResult> waitForTraktDeviceToken({
    required TraktDeviceSession session,
    required bool Function() isCancelled,
  }) {
    return _trakt.waitForDeviceToken(
      creds: trakt,
      session: session,
      isCancelled: isCancelled,
    );
  }

  Future<void> completeOnboarding() async {
    if (onboardingCompleted) return;
    onboardingCompleted = true;
    await _store.saveOnboardingCompleted(true);
    notifyListeners();
  }

  Future<void> markTorrentVpnTipSeen() async {
    if (torrentVpnTipSeen) return;
    torrentVpnTipSeen = true;
    await _store.saveTorrentVpnTipSeen(true);
  }

  /// Shows the one-time VPN/proxy tip when needed.
  ///
  /// Returns `false` if the user chose Network settings (caller should abort
  /// the current torrent start). Skipped when a proxy is already active.
  Future<bool> maybePromptTorrentVpnTip() async {
    if (torrentVpnTipSeen || proxy.isActive) return true;
    final hook = onTorrentPrivacyTipNeeded;
    if (hook == null) return true;
    return hook();
  }

  void _onProxyHandshakeFailure(String host, Object error) {
    if (_disposed) return;
    final alreadyShowing = lastProxyFailureDetail != null;
    // Prefer configured proxy host over request destination (probe target).
    // Logging the destination made NordVPN users think example.com was saved.
    final proxyHost = proxy.host.trim();
    lastProxyFailureHost = proxyHost.isNotEmpty ? proxyHost : host;
    lastProxyFailureDetail = describeProxyError(error);
    lastProxyFailureIsAuth = isProxyAuthFailure(error);
    if (!alreadyShowing) notifyListeners();
  }

  void _clearProxyFailure() {
    lastProxyFailureHost = null;
    lastProxyFailureDetail = null;
    lastProxyFailureIsAuth = false;
  }

  Future<void> saveProxySettings(ProxySettings settings) async {
    proxy = settings;
    await _store.saveProxySettings(settings);
    await _rebuildNetworkClients();
    _torrent.applyProxySettings(settings);
    _clearProxyFailure();
    notifyListeners();
    _noteSyncableChange();
  }

  Future<ProxyProbeResult> testProxyConnection([
    ProxySettings? settings,
  ]) async {
    final target = settings ?? proxy;
    final result = await probeProxy(target);
    if (_disposed) return result;
    if (result.ok) {
      if (lastProxyFailureDetail != null) {
        _clearProxyFailure();
        notifyListeners();
      }
    } else {
      lastProxyFailureHost = target.host.trim();
      lastProxyFailureDetail = result.error;
      lastProxyFailureIsAuth = result.isAuthFailure;
      notifyListeners();
    }
    return result;
  }

  /// Drop first-run demo clips from older installs (no longer seeded).
  Future<List<MediaItem>> _purgeDemoSamples(List<MediaItem> local) async {
    bool isDemo(MediaItem m) => m.id.startsWith('demo-');

    final cleaned = local.where((m) => !isDemo(m)).toList();
    if (cleaned.length != local.length) {
      await _store.saveLocalMedia(cleaned);
    }

    final historyCleaned = history.where((m) => !isDemo(m)).toList();
    if (historyCleaned.length != history.length) {
      history = historyCleaned;
      await _store.saveHistory(history);
    }

    final watchlistCleaned = watchlist.where((m) => !isDemo(m)).toList();
    if (watchlistCleaned.length != watchlist.length) {
      watchlist = watchlistCleaned;
      await _store.saveWatchlist(watchlist);
    }

    return cleaned;
  }

  /// Insert [candidate] or update an existing source with the same
  /// [IptvSource.dedupeKey] (same playlist / panel / account).
  Future<IptvSource> _upsertSourceByDedupe(
    IptvSource candidate, {
    required String reason,
  }) async {
    final key = candidate.dedupeKey;
    final index = key.isEmpty
        ? -1
        : sources.indexWhere((s) => s.dedupeKey == key);
    late final IptvSource saved;
    if (index >= 0) {
      final existing = sources[index];
      saved = candidate.copyWith(
        id: existing.id,
        createdAt: existing.createdAt,
        channelCount: candidate.channelCount > 0
            ? candidate.channelCount
            : existing.channelCount,
        vodCount: candidate.vodCount > 0
            ? candidate.vodCount
            : existing.vodCount,
        lastSyncedAt: candidate.lastSyncedAt ?? existing.lastSyncedAt,
        lastVodSyncedAt: candidate.lastVodSyncedAt ?? existing.lastVodSyncedAt,
        // Keep badge color unless the incoming payload sets one.
        color: candidate.color ?? existing.color,
        vastUrl: candidate.vastUrl ?? existing.vastUrl,
      );
      sources = [...sources]..[index] = saved;
      JavpLog.i(
        'source',
        'upsert existing id=${saved.id} key=$key reason=$reason',
      );
    } else {
      // New source: pick an unused badge color unless the payload set one.
      final hasColor =
          candidate.color != null && candidate.color!.trim().isNotEmpty;
      saved = hasColor
          ? candidate
          : candidate.copyWith(
              color: nextDefaultSourceColor(
                sources.map((s) => s.color),
                existingCount: sources.length,
              ),
            );
      sources = [...sources, saved];
    }
    await _store.saveSources(sources);
    notifyListeners();
    _noteSyncableChange(urgent: true);
    _logSourcesFeatureSummary(reason: reason);
    _kickSoftSyncAfterHomeReady(saved.id, reason: reason);
    return saved;
  }

  Future<String> resolveStalkerStreamUrl(MediaItem item) async {
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || source.type != IptvSourceType.stalker) {
      throw Exception('Stalker source not found for this item');
    }
    return _stalker.createLink(
      source,
      cmd: item.playUrl,
      isLive: item.isLive,
      episode: item.isLive ? null : item.episodeNumber,
    );
  }

  String resolveXtreamStreamUrl(MediaItem item) {
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || source.type != IptvSourceType.xtream) {
      return item.playUrl;
    }
    return injectXtreamCredentials(item.playUrl, source);
  }

  /// Catalog JSON `name`, else the URL host — only when the source still has
  /// the placeholder label (or is the bundled demo).
  String? _preferredCustomCatalogName({
    required IptvSource source,
    String? parsedName,
  }) {
    final canReplace =
        source.name == 'Custom catalog' ||
        source.name.trim().isEmpty ||
        source.id == demoSourceId;
    if (!canReplace) return null;

    final fromJson = parsedName?.trim();
    if (fromJson != null && fromJson.isNotEmpty) return fromJson;

    final url = source.playlistUrl?.trim() ?? '';
    if (isAssetCatalogUrl(url)) return 'Demo — open media';
    final uri = Uri.tryParse(url);
    final host = uri?.host.trim() ?? '';
    if (host.isNotEmpty) return host;
    return null;
  }

  /// Fail fast when the catalog location is missing, empty, or the wrong kind.
  Future<void> _probeCatalogLocation(
    String catalogUrl, {
    String? authToken,
  }) async {
    final location = catalogUrl.trim();
    if (isAssetCatalogUrl(location)) return;

    final localPath = LocalSourcePath.tryLocalFilePath(location);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Catalog file not found');
      }
      final raf = await file.open();
      try {
        final peekBytes = await raf.read(4096);
        if (peekBytes.isEmpty) {
          throw Exception('Catalog file is empty');
        }
        _assertCatalogContent(utf8.decode(peekBytes, allowMalformed: true));
      } finally {
        await raf.close();
      }
      return;
    }

    final uri = Uri.tryParse(location);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('Enter a valid catalog URL or local .json file path');
    }

    final peekBytes = await _peekRemoteBytes(
      location,
      headers: CustomCatalogClient.authHeaders(authToken),
    );
    if (peekBytes.isEmpty) {
      throw Exception('Catalog URL returned an empty response');
    }
    _assertCatalogContent(utf8.decode(peekBytes, allowMalformed: true));
  }

  void _assertCatalogContent(String peek) {
    final kind = sniffSourceContent(peek);
    switch (kind) {
      case SourceContentKind.jsonCatalog:
        return;
      case SourceContentKind.iptvM3u:
      case SourceContentKind.hlsPlaylist:
      case SourceContentKind.xmlEpg:
      case SourceContentKind.html:
      case SourceContentKind.xtreamCodes:
        throw SourceKindMismatchException(
          expected: SourceContentExpectation.jsonCatalog,
          detected: kind,
          message: mismatchMessageFor(
            expected: SourceContentExpectation.jsonCatalog,
            detected: kind,
          ),
        );
      case SourceContentKind.unknown:
        // Truncated peeks may not match catalog heuristics; let sync parse.
        final trimmed = peek.trimLeft();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) return;
        throw SourceKindMismatchException(
          expected: SourceContentExpectation.jsonCatalog,
          detected: kind,
          message: mismatchMessageFor(
            expected: SourceContentExpectation.jsonCatalog,
            detected: kind,
          ),
        );
    }
  }

  Future<CustomCatalogParseResult> _parseLocalCatalog(
    String catalogUrl, {
    required String sourceId,
    String? appVersion,
    CatalogClientProfile? profile,
  }) async {
    final localPath = LocalSourcePath.tryLocalFilePath(catalogUrl);
    if (localPath == null) {
      throw Exception('Enter a valid catalog URL or local .json file path');
    }
    final file = File(localPath);
    if (!await file.exists()) {
      throw Exception('Catalog file not found: $localPath');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception('Catalog file is empty');
    }
    final sid = sourceId;
    final ver = appVersion;
    final captured = profile;
    final parsed = await parseCatalogBodyInIsolate(
      bytes,
      sourceId: sid,
      appVersion: ver,
      profile: captured,
    );
    if (parsed.isQueryApi &&
        parsed.items.isEmpty &&
        (parsed.vod == null || parsed.vod!.vodCount == 0)) {
      throw Exception(
        'Local catalogs must be a v1 bulk dump with an "items" array. '
        'Query API (v2) needs a hosted URL.',
      );
    }
    final baseDir = LocalSourcePath.localBaseDir(catalogUrl);
    final vod = parsed.vod;
    return CustomCatalogParseResult(
      name: parsed.name,
      version: parsed.version,
      minVersion: parsed.minVersion,
      capabilities: parsed.capabilities,
      itemCount: parsed.itemCount,
      namedSources: parsed.namedSources,
      vastUrl: parsed.vastUrl,
      epgUrl: parsed.epgUrl,
      playHeaders: parsed.playHeaders,
      items: LocalSourcePath.resolveEntryUrls(parsed.items, baseDir: baseDir),
      vod: vod == null
          ? null
          : VodIngestPlan(
              rows: LocalSourcePath.resolvePackedPlayUrls(
                vod.rows,
                baseDir: baseDir,
              ),
              families: vod.families,
              canonical: vod.canonical,
            ),
      details: parsed.details,
    );
  }

  /// Bundled Creative Commons / open-movie catalog for Play reviewers and demos.
  static const demoSourceId = 'demo-open-movies';
  static const demoCatalogAsset = 'assets/demo/catalog.json';
  static const demoCatalogUrl = 'asset://demo/catalog.json';

  static bool isAssetCatalogUrl(String? url) =>
      url != null && url.startsWith('asset://');

  Future<CustomCatalogParseResult> _parseAssetCatalog(
    String assetUrl, {
    required String sourceId,
    String? appVersion,
    CatalogClientProfile? profile,
  }) async {
    final assetPath = assetUrl == demoCatalogUrl
        ? demoCatalogAsset
        : assetUrl.replaceFirst('asset://', 'assets/');
    final body = await rootBundle.loadString(assetPath);
    return _customCatalog.parse(
      body,
      sourceId: sourceId,
      appVersion: appVersion,
      profile: profile,
    );
  }

  /// Running JAVP version (`0.4.3+57`, `0.4.3-dev+56`) for catalog `min_version`.
  Future<String?> _currentAppVersion() async {
    final cached = _cachedAppVersion;
    if (cached != null) return cached.isEmpty ? null : cached;
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      final full = version.isEmpty
          ? ''
          : (build.isEmpty ? version : '$version+$build');
      _cachedAppVersion = full;
      return full.isEmpty ? null : full;
    } catch (_) {
      _cachedAppVersion = '';
      return null;
    }
  }

  Future<String> _plexClientIdentifier() async {
    final existing = await _store.loadPlexClientId();
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4();
    await _store.savePlexClientId(id);
    return id;
  }

  /// Starts plex.tv PIN auth. Open [PlexPinRequest.authUrl] for the user.
  Future<PlexPinRequest> beginPlexSignIn() async {
    final clientId = await _plexClientIdentifier();
    return _plexAccount.createPin(clientId);
  }

  /// Polls until the PIN is authorized. Pass [isCancelled] to abort from UI.
  /// [wake] triggers an immediate status check (app resume / deep link).
  Future<String> completePlexSignIn(
    PlexPinRequest pin, {
    bool Function()? isCancelled,
    PlexAuthWake? wake,
  }) {
    return _plexAccount.waitForAuthToken(
      pin,
      isCancelled: isCancelled,
      wake: wake,
    );
  }

  /// One-shot PIN check after the user returns from the browser.
  Future<String?> checkPlexPin(PlexPinRequest pin) {
    return _plexAccount.checkPin(pin);
  }

  /// Lists owned/shared PMS instances for an account token.
  Future<List<PlexServerResource>> listPlexServers(String accountToken) async {
    final clientId = await _plexClientIdentifier();
    return _plexAccount.listServers(accountToken, clientIdentifier: clientId);
  }

  /// Probes connections for [server], then saves + syncs like a manual Plex source.
  Future<void> addPlexServerFromAccount({
    required PlexServerResource server,
    String? name,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    String? plexAccountToken,
  }) async {
    final clientId = await _plexClientIdentifier();
    final url = await _plexAccount.resolveReachableUrl(
      server,
      clientIdentifier: clientId,
    );
    final packed = PlexStoredConnections.fromResource(
      server,
      reachableUrl: url,
    );
    final label = (name ?? server.name).trim();
    await addMediaServerSource(
      name: label.isEmpty ? 'Plex' : label,
      type: IptvSourceType.plex,
      serverUrl: packed.serverUrl,
      alternateServerUrl: packed.alternateServerUrl,
      extraServerUrls: packed.extraServerUrls,
      username: server.machineId,
      password: server.accessToken,
      plexAccountToken: plexAccountToken,
      epgUrl: epgUrl,
      epgSourceId: epgSourceId,
      epgEnabled: epgEnabled,
    );
  }

  /// Adds plex.tv FAST / Live TV using the account token from PIN sign-in.
  Future<void> addPlexFastLiveFromAccount({
    required String accountToken,
    String? name,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
  }) async {
    final label = (name ?? '').trim();
    await addMediaServerSource(
      name: label.isEmpty ? 'Plex Live TV & Movies' : label,
      type: IptvSourceType.plex,
      serverUrl: PlexClient.fastProviderUrl,
      username: PlexClient.fastUsername,
      password: accountToken,
      epgUrl: epgUrl,
      epgSourceId: epgSourceId,
      epgEnabled: epgEnabled,
    );
  }

  MediaServerClient _clientFor(IptvSourceType type) {
    return switch (type) {
      IptvSourceType.jellyfin => _jellyfin,
      IptvSourceType.emby => _emby,
      IptvSourceType.plex => _plex,
      _ => throw StateError('Not a media server type: $type'),
    };
  }

  Future<MediaServerSession> _sessionFor(IptvSource source) async {
    final cached = _serverSessions[source.id];
    if (cached != null) return cached;
    if (source.type == IptvSourceType.plex) {
      return _plexSessionFor(source);
    }
    final session = await _clientFor(source.type).authenticate(source);
    _serverSessions[source.id] = session;
    return session;
  }

  Future<MediaServerSession> _plexSessionFor(IptvSource source) async {
    _plex.clientIdentifier = await _plexClientIdentifier();
    Future<MediaServerSession> auth(IptvSource next) async {
      final preferred = await _store.loadPlexActiveUrl(next.id);
      final session = await _plex.authenticate(next, preferredBase: preferred);
      _serverSessions[next.id] = session;
      final base = session.baseUrl;
      if (base != null && base.isNotEmpty) {
        _plex.rememberResolvedBase(next.id, base);
        await _store.savePlexActiveUrl(next.id, base);
      }
      return session;
    }

    try {
      return await auth(source);
    } catch (_) {
      final refreshed = await _refreshPlexConnections(source);
      if (refreshed == null) rethrow;
      return auth(refreshed);
    }
  }

  /// Re-fetch plex.tv connection URIs when the stored LAN URL is unreachable.
  Future<IptvSource?> _refreshPlexConnections(IptvSource source) async {
    final token = source.plexAccountToken?.trim() ?? '';
    final machineId = source.username?.trim() ?? '';
    if (token.isEmpty || machineId.isEmpty) return null;
    final clientId = await _plexClientIdentifier();
    final servers = await _plexAccount.listServers(
      token,
      clientIdentifier: clientId,
    );
    PlexServerResource? match;
    for (final server in servers) {
      if (server.machineId == machineId) {
        match = server;
        break;
      }
    }
    match ??= servers.cast<PlexServerResource?>().firstWhere(
      (s) => s!.accessToken == source.password,
      orElse: () => null,
    );
    if (match == null) return null;
    String reachable;
    try {
      reachable = await _plexAccount.resolveReachableUrl(
        match,
        clientIdentifier: clientId,
      );
    } catch (_) {
      reachable = '';
    }
    final packed = PlexStoredConnections.fromResource(
      match,
      reachableUrl: reachable.isEmpty ? null : reachable,
    );
    if (packed.serverUrl.isEmpty) return null;
    final next = source.copyWith(
      serverUrl: packed.serverUrl,
      alternateServerUrl: packed.alternateServerUrl,
      clearAlternateServerUrl: packed.alternateServerUrl == null,
      extraServerUrls: packed.extraServerUrls,
      username: match.machineId,
      password: match.accessToken,
      plexAccountToken: token,
    );
    final index = sources.indexWhere((s) => s.id == source.id);
    if (index >= 0) {
      final list = [...sources];
      list[index] = next;
      sources = list;
      await _store.saveSources(sources);
      _noteSyncableChange(urgent: true);
    }
    return next;
  }

  /// First page fetched per library during the blocking part of a sync. The
  /// rest is paged in by [_deepSyncSource] once the UI is interactive.
  static const _mediaServerFirstPage = 200;

  Future<List<MediaItem>> _syncMediaServerLibraries(IptvSource source) async {
    final client = _clientFor(source.type);
    final session = await _sessionFor(source);
    final libs = (await client.libraries(
      source,
      session,
    )).where(_isVideoMediaServerLibrary).toList();
    final l10n = _uiL10n;
    _setSourceSyncStatus(
      source.id,
      libs.isEmpty
          ? l10n.sourceSyncNoVideoLibraries
          : l10n.sourceSyncFetchingLibraries('${libs.length}'),
    );
    // Libraries are fetched together instead of one after another, so adding a
    // server with five libraries is one round trip's wait rather than five.
    final pages = await Future.wait([
      for (final lib in libs)
        client
            .browse(
              source,
              session,
              parentId: lib.id,
              limit: _mediaServerFirstPage,
            )
            .catchError((_) => const MediaServerPage(items: [])),
    ]);
    // Stamp library name as [MediaItem.group] so Catalog shelves match Views
    // instead of Jellyfin Type ("Movie" / "Series").
    final out = <MediaItem>[];
    for (var i = 0; i < libs.length; i++) {
      final libName = libs[i].name.trim();
      for (final item in pages[i].items) {
        out.add(
          item.isEpisode && (item.group?.isNotEmpty ?? false)
              ? item
              : item.copyWith(group: libName.isEmpty ? item.group : libName),
        );
      }
    }
    _setSourceSyncStatus(
      source.id,
      libs.isEmpty
          ? l10n.sourceSyncLoadedTitles('${out.length}')
          : l10n.sourceSyncLoadedTitlesLibraries(
              '${out.length}',
              '${libs.length}',
            ),
    );
    // Live TV + DVR recordings sit outside normal library browse.
    if (source.type.supportsLive && source.type.isMediaServer) {
      _setSourceSyncStatus(source.id, l10n.sourceSyncFetchingLiveTv);
      try {
        if (source.type == IptvSourceType.plex) {
          _plex.clientIdentifier = await _plexClientIdentifier();
          final live = await _plex.liveChannels(source, session);
          out.addAll(live);
          final recordings = await _plex.dvrRecordings(source, session);
          out.addAll(recordings);
        } else {
          final jf = source.type == IptvSourceType.emby ? _emby : _jellyfin;
          final live = await jf.liveChannels(source, session);
          out.addAll(live);
          final recordings = await jf.dvrRecordings(source, session);
          out.addAll(recordings);
        }
        _lastMediaServerLiveFetchOk = true;
      } catch (_) {
        // Keep prior Live DB rows; a transient failure must not wipe them.
        _lastMediaServerLiveFetchOk = false;
      }
    }
    return out;
  }

  /// Set during media-server sync: `true` = Live listing succeeded
  /// (including intentional empty), `false` = fetch failed, `null` = N/A.
  bool? _lastMediaServerLiveFetchOk;

  /// Skip Jellyfin/Emby/Plex views that aren't video (music, photos, etc.).
  static bool _isVideoMediaServerLibrary(MediaServerLibrary lib) {
    final type = (lib.collectionType ?? '').trim().toLowerCase();
    if (type.isEmpty) return true;
    const nonVideo = {'music', 'books', 'photos', 'playlists', 'livetv'};
    return !nonVideo.contains(type);
  }

  // ── Deep catalog sync ──────────────────────────────────────────────────
  // A sync only fetches the first page per library so the app is usable
  // immediately. These keep paging in the background until the catalog is
  // complete, merging a page at a time so browsing never blocks on it.
  final Set<String> _deepSyncing = {};
  static const _deepSyncPageSize = 200;
  static const _deepSyncMaxItems = 30000;
  static const _deepSyncMaxItemsPerLibrary = 12000;
  static const _deepSyncPauseBetweenPages = Duration(milliseconds: 150);

  bool isDeepSyncing(String sourceId) => _deepSyncing.contains(sourceId);

  Set<String> _deepSyncedSourceIds = {};

  static bool _supportsDeepSync(IptvSourceType type) {
    return type.isMediaServer || type == IptvSourceType.custom;
  }

  /// Pages any source that has never been fully walked. Runs once per source,
  /// so a returning user isn't stuck with whatever the first page held.
  bool _hasPendingDeepSync() {
    for (final source in sources) {
      if (!source.enabled) continue;
      if (!_supportsDeepSync(source.type)) continue;
      if (_deepSyncedSourceIds.contains(source.id)) continue;
      return true;
    }
    return false;
  }

  Future<void> _deepSyncPendingSources() {
    if (!_hasPendingDeepSync()) {
      JavpLog.i('sync', 'deep-sync-pending skip (none pending)');
      return Future<void>.value();
    }
    return _bgQueue.enqueue(
      id: 'deep-sync-pending',
      priority: BackgroundPriority.low,
      action: () async {
        for (final source in sources) {
          if (!source.enabled) continue;
          if (!_supportsDeepSync(source.type)) continue;
          if (_deepSyncedSourceIds.contains(source.id)) continue;
          // Don't block the single worker — soft-defer instead of tight requeue.
          if (!_allowIdleBackgroundWork ||
              _bgQueue.shouldDeferIdleWork ||
              _vodPrefetching.isNotEmpty ||
              _syncingSourceIds.isNotEmpty) {
            _softDeferDeepSync();
            return;
          }
          await _deepSyncSource(source.id, delay: const Duration(seconds: 6));
        }
      },
    );
  }

  void _softDeferDeepSync() {
    if (_deepSyncSoftDeferTimer?.isActive ?? false) return;
    _deepSyncSoftDeferTimer = Timer(const Duration(seconds: 12), () {
      _deepSyncSoftDeferTimer = null;
      if (!_allowIdleBackgroundWork) return;
      unawaited(_deepSyncPendingSources());
    });
  }

  Future<void> _deepSyncSource(
    String sourceId, {
    Duration delay = const Duration(seconds: 3),
  }) async {
    if (!_deepSyncing.add(sourceId)) return;
    _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncPagingRemaining);
    try {
      // Let the first paint and any EPG/VOD warm-up settle first.
      await Future<void>.delayed(delay);
      await waitUntilHomeRevealSettled();
      if (_disposed) return;
      final source = _sourceById(sourceId);
      if (source == null || !source.enabled) return;
      switch (source.type) {
        case IptvSourceType.jellyfin:
        case IptvSourceType.emby:
        case IptvSourceType.plex:
          await _deepSyncMediaServer(source);
        case IptvSourceType.custom:
          await _deepSyncCustomCatalog(source);
        case IptvSourceType.m3u:
        case IptvSourceType.xtream:
        case IptvSourceType.stalker:
        case IptvSourceType.xmltv:
          return;
      }
      _deepSyncedSourceIds = {..._deepSyncedSourceIds, sourceId};
      await _store.saveDeepSyncedSourceIds(_deepSyncedSourceIds.toList());
    } catch (_) {
      // Partial catalogs are fine; the next sync retries.
    } finally {
      _deepSyncing.remove(sourceId);
      _clearSourceSyncStatusIfIdle(sourceId);
    }
  }

  IptvSource? _sourceById(String sourceId) {
    for (final source in sources) {
      if (source.id == sourceId) return source;
    }
    return null;
  }

  /// VAST tag for [item]: per-title override, else the source tag.
  ///
  /// An explicit empty `MediaItem.vastUrl` disables ads for that title.
  String? vastUrlFor(MediaItem item) {
    final override = item.vastUrl;
    if (override != null) {
      final trimmed = override.trim();
      return trimmed.isEmpty ? null : _readSourceVastUrl(trimmed);
    }
    final sid = item.sourceId?.trim();
    if (sid == null || sid.isEmpty) return null;
    return _readSourceVastUrl(_sourceById(sid)?.vastUrl);
  }

  static String? _readSourceVastUrl(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return trimmed;
  }

  Future<void> _deepSyncMediaServer(IptvSource source) async {
    if (!kIsWeb) await _enableVodDb(reason: 'deep-sync');
    final client = _clientFor(source.type);
    final session = await _sessionFor(source);
    final libs = (await client.libraries(
      source,
      session,
    )).where(_isVideoMediaServerLibrary).toList();
    final seen = {for (final m in catalog) m.id};
    if (_useVodDb) {
      seen.addAll(await _vodDb.idsForSource(source.id));
    }
    final pending = <MediaItem>[];
    var total = 0;
    var catalogTotal = _useVodDb
        ? seen.length
        : catalog.where((m) => m.sourceId == source.id).length;

    for (var libIndex = 0; libIndex < libs.length; libIndex++) {
      final lib = libs[libIndex];
      var start = _mediaServerFirstPage;
      var added = 0;
      // Budget is per library so a huge Movies section can't starve the rest.
      while (added < _deepSyncMaxItemsPerLibrary && total < _deepSyncMaxItems) {
        // Bail out if the source was removed or re-synced under us.
        if (_sourceById(source.id) == null) return;
        final page = await client.browse(
          source,
          session,
          parentId: lib.id,
          startIndex: start,
          limit: _deepSyncPageSize,
        );
        if (page.consumedCount == 0) break;
        final libName = lib.name.trim();
        var pageNew = 0;
        for (final item in page.items) {
          final stamped = item.isEpisode && (item.group?.isNotEmpty ?? false)
              ? item
              : item.copyWith(group: libName.isEmpty ? item.group : libName);
          if (seen.add(stamped.id)) {
            pending.add(stamped);
            pageNew++;
          }
        }
        start += page.consumedCount;
        added += page.consumedCount;
        total += page.consumedCount;
        catalogTotal += pageNew;
        _setSourceSyncStatus(
          source.id,
          _uiL10n.sourceSyncPagingLibrary(
            lib.name,
            '$catalogTotal',
            '${libIndex + 1}',
            '${libs.length}',
          ),
        );
        // Flush in batches so the catalog grows visibly without a rebuild
        // storm, then breathe so scrolling stays smooth.
        if (pending.length >= 600) {
          await _appendDeepSynced(pending);
          pending.clear();
        }
        // Servers that don't report a total still stop once a page is short.
        if (!page.hasMore && page.consumedCount < _deepSyncPageSize) break;
        await Future<void>.delayed(_deepSyncPauseBetweenPages);
        await _yieldToBrowse(reason: 'deep-sync');
      }
    }
    if (pending.isNotEmpty) await _appendDeepSynced(pending);
    _setSourceSyncStatus(
      source.id,
      _uiL10n.sourceSyncPagedTitles('$catalogTotal'),
    );
  }

  Future<void> _deepSyncCustomCatalog(IptvSource source) async {
    if (!kIsWeb) await _enableVodDb(reason: 'deep-sync');
    final url = source.playlistUrl;
    if (url == null || url.isEmpty) return;
    // Local / bundled dumps are fully imported on the first sync.
    if (isAssetCatalogUrl(url) ||
        LocalSourcePath.tryLocalFilePath(url) != null) {
      return;
    }
    final seen = {for (final m in catalog) m.id};
    if (_useVodDb) {
      seen.addAll(await _vodDb.idsForSource(source.id));
    }
    final pending = <MediaItem>[];
    var added = 0;
    var page = 2; // Page 1 already landed during the blocking sync.
    var catalogTotal = _useVodDb
        ? seen.length
        : catalog.where((m) => m.sourceId == source.id).length;

    while (added < _deepSyncMaxItems) {
      if (_sourceById(source.id) == null) return;
      final result = await _customCatalog.browse(
        baseUrl: url,
        sourceId: source.id,
        page: page,
        limit: _deepSyncPageSize,
        locale: _catalogLocaleParam,
        headers: _customCatalogHeaders(source),
      );
      if (result.items.isEmpty) break;
      var pageNew = 0;
      for (final item in result.items) {
        if (seen.add(item.id)) {
          pending.add(item);
          pageNew++;
        }
      }
      if (result.details.isNotEmpty) {
        detailsCache = {...detailsCache, ...result.details};
        _schedulePersist(_PersistTarget.detailsCache);
      }
      added += result.items.length;
      catalogTotal += pageNew;
      _setSourceSyncStatus(
        source.id,
        _uiL10n.sourceSyncPagingCatalog('$catalogTotal', '$page'),
      );
      if (pending.length >= 600) {
        await _appendDeepSynced(pending);
        pending.clear();
      }
      if (result.items.length < _deepSyncPageSize) break;
      page++;
      await Future<void>.delayed(_deepSyncPauseBetweenPages);
      await _yieldToBrowse(reason: 'deep-sync');
    }
    if (pending.isNotEmpty) await _appendDeepSynced(pending);
  }

  Future<void> _appendDeepSynced(List<MediaItem> items) async {
    if (items.isEmpty) return;
    if (!kIsWeb) {
      final taken = await _takeImportedVodToSqlite(
        sourceId: items.first.sourceId ?? '',
        imported: items,
        replace: false,
      );
      if (taken.rest.isEmpty) {
        _notifyListenersAfterIdle();
        return;
      }
      catalog = [...catalog, ...taken.rest];
    } else {
      catalog = [...catalog, ...items];
    }
    _schedulePersist(_PersistTarget.catalog);
    // Idle — page batches must not rebuild every tab mid deep-sync.
    _notifyListenersAfterIdle();
  }

  Future<MediaServerPage> browseMediaServer({
    required String sourceId,
    String? parentId,
    String? search,
    int startIndex = 0,
    int limit = 50,
  }) async {
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == sourceId,
      orElse: () => null,
    );
    if (source == null) return const MediaServerPage(items: []);
    final client = _clientFor(source.type);
    final session = await _sessionFor(source);
    return _runUserFacing(
      () => client.browse(
        source,
        session,
        parentId: parentId,
        search: search,
        startIndex: startIndex,
        limit: limit,
      ),
    );
  }

  Future<String?> resolveServerStreamUrl(MediaItem item) async {
    if (item.serverItemId == null || item.sourceId == null) {
      return item.playUrl.isEmpty ? null : item.playUrl;
    }
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null) return item.playUrl.isEmpty ? null : item.playUrl;
    if (!source.type.isMediaServer) {
      return item.playUrl.isEmpty ? null : item.playUrl;
    }
    if (source.type == IptvSourceType.plex) {
      _plex.clientIdentifier = await _plexClientIdentifier();
    }
    final client = _clientFor(source.type);
    final session = await _sessionFor(source);
    final named = MediaServerStreamQuality.values.asNameMap()[item.resolution];
    final quality = named ?? mediaServerStreamQuality;
    return _runUserFacing(
      () => client.streamUrl(
        source,
        session,
        item.serverItemId!,
        quality: quality,
      ),
    );
  }

  /// Keepalive for an active Plex Live TV transcoder session.
  Future<void> pingPlexLiveSession(
    MediaItem item, {
    required String sessionKey,
    required bool isPaused,
    bool stopped = false,
  }) async {
    if (item.origin != MediaOrigin.plex || item.sourceId == null) return;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || source.type != IptvSourceType.plex) return;
    _plex.clientIdentifier = await _plexClientIdentifier();
    final state = stopped ? 'stopped' : (isPaused ? 'paused' : 'playing');
    await _plex.pingLiveSession(source, sessionKey: sessionKey, state: state);
    if (stopped) {
      await _plex.closeLiveSession(source, sessionKey: sessionKey);
    }
  }

  /// Close an active Jellyfin / Emby / Plex live tuner session (zap / leave).
  Future<void> closeMediaServerLiveSession(MediaItem item) async {
    if (!item.origin.isMediaServer || item.sourceId == null) return;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || !source.type.isMediaServer) return;
    try {
      final session = await _sessionFor(source);
      switch (source.type) {
        case IptvSourceType.plex:
          _plex.clientIdentifier = await _plexClientIdentifier();
          await _plex.closeLiveSession(source);
        case IptvSourceType.jellyfin:
          await _jellyfin.closeLiveStream(source, session);
        case IptvSourceType.emby:
          await _emby.closeLiveStream(source, session);
        case IptvSourceType.m3u:
        case IptvSourceType.xtream:
        case IptvSourceType.stalker:
        case IptvSourceType.custom:
        case IptvSourceType.xmltv:
          break;
      }
    } catch (_) {}
  }

  bool _isMediaServerItem(MediaItem item) {
    if (item.serverItemId == null || item.sourceId == null) return false;
    return item.origin.isMediaServer;
  }

  /// Push local playhead to Plex / Jellyfin / Emby Continue Watching.
  Future<void> reportServerProgress(
    MediaItem item, {
    required Duration position,
    required bool isPaused,
    Duration? duration,
    bool stopped = false,
  }) async {
    if (!_isMediaServerItem(item)) return;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || !source.type.isMediaServer) return;
    try {
      final client = _clientFor(source.type);
      final session = await _sessionFor(source);
      await client.reportProgress(
        source,
        session,
        itemId: item.serverItemId!,
        position: position,
        isPaused: isPaused,
        duration: duration ?? item.duration,
        stopped: stopped,
      );
    } catch (_) {}
  }

  /// Mark played / unplayed on the media server (best-effort).
  Future<void> _setServerPlayed(MediaItem item, {required bool played}) async {
    if (!_isMediaServerItem(item)) return;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || !source.type.isMediaServer) return;
    try {
      final client = _clientFor(source.type);
      final session = await _sessionFor(source);
      await client.setPlayed(
        source,
        session,
        item.serverItemId!,
        played: played,
      );
    } catch (_) {}
  }

  /// Manual "watched" from the library UI (episode long-press, etc.).
  Future<void> markAsWatched(MediaItem item) async {
    final tags = item.tags
        .where((t) => t != LocalRecommender.continueUpNextTag)
        .toList(growable: false);
    final base = item.copyWith(tags: tags);
    await recordWatch(base, progress: 1.0);
    final updated = base.copyWith(progress: 1.0, lastWatchedAt: DateTime.now());
    unawaited(_maybeScrobble(updated, force: true));
    unawaited(_maybeScrobbleSerializd(updated, force: true));
    unawaited(_setServerPlayed(item, played: true));
  }

  /// Manual "unwatched": reset progress to 0% and drop Continue watching.
  Future<void> markAsUnwatched(MediaItem item) async {
    final tags = item.tags
        .where((t) => t != LocalRecommender.continueUpNextTag)
        .toList(growable: false);
    await recordWatch(item.copyWith(tags: tags), progress: 0);
    unawaited(_setServerPlayed(item, played: false));
  }

  /// Merge remote Continue Watching into [item] (takes the farther playhead).
  Future<MediaItem> mergeRemoteProgress(MediaItem item) async {
    if (!_isMediaServerItem(item) || item.isLive) return item;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == item.sourceId,
      orElse: () => null,
    );
    if (source == null || !source.type.isMediaServer) return item;
    try {
      final client = _clientFor(source.type);
      final session = await _sessionFor(source);
      final remote = await client.remoteProgress(
        source,
        session,
        item.serverItemId!,
      );
      if (remote == null) return item;
      final mergedProgress = remote > item.progress ? remote : item.progress;
      if ((mergedProgress - item.progress).abs() < 0.005) return item;
      final updated = item.copyWith(progress: mergedProgress);
      catalog = catalog.map((m) => m.id == item.id ? updated : m).toList();
      history = [
        updated,
        ...history.where((m) => m.id != item.id),
      ].take(200).toList();
      await _store.saveCatalog(catalog);
      await _store.saveHistory(history);
      notifyListeners();
      return updated;
    } catch (_) {
      return item;
    }
  }

  /// Sets or clears the badge / filter color (`#RRGGBB`). Empty clears.
  Future<void> setSourceColor(String sourceId, String? colorHex) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    final trimmed = colorHex?.trim();
    final nextColor = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final current = sources[index];
    if (current.color == nextColor) return;
    final next = [...sources];
    next[index] = nextColor == null
        ? current.copyWith(clearColor: true)
        : current.copyWith(color: nextColor);
    sources = next;
    _sourceColorById = null;
    _sourceNameIndexRef = null;
    _sourcesAppearanceStamp++;
    // Pierce one notify like [_bumpVodBusy] — do not drop [_uiQuiet], or
    // ingest/prefetch notifies rematerialize Home / Catalog / TV mid-work.
    _notifyPierceQuiet();
    await _store.saveSources(sources);
    _noteSyncableChange(urgent: true);
  }

  /// Reorders the Sources list (also used by TV / Catalog pickers).
  ///
  /// [newIndex] is the destination index after removal (as with
  /// [ReorderableListView.onReorderItem]).
  Future<void> reorderSources(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= sources.length ||
        newIndex < 0 ||
        newIndex >= sources.length ||
        oldIndex == newIndex) {
      return;
    }
    final next = [...sources];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    sources = next;
    await _store.saveSources(sources);
    notifyListeners();
    _noteSyncableChange(urgent: true);
  }

  /// Move [sourceId] one step toward the start of the list.
  Future<void> moveSourceEarlier(String sourceId) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index <= 0) return;
    await reorderSources(index, index - 1);
  }

  /// Move [sourceId] one step toward the end of the list.
  Future<void> moveSourceLater(String sourceId) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0 || index >= sources.length - 1) return;
    await reorderSources(index, index + 1);
  }

  /// Per-list toggle: Guide / now-playing use EPG for this attachable source.
  Future<void> setSourceEpgEnabled(String sourceId, bool enabled) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    final current = sources[index];
    if (!current.type.canAttachEpg) return;
    if (current.epgEnabled == enabled) return;
    final next = [...sources];
    next[index] = current.copyWith(epgEnabled: enabled);
    sources = next;
    _cachedOnNow = null;
    _bumpEpgRevision();
    await _store.saveSources(sources);
    _uiQuiet = false;
    notifyListeners();
    _noteSyncableChange(urgent: true);
    if (enabled) {
      unawaited(_reloadMergedXmltvEpg());
    }
  }

  /// Xtream per-source toggle: include movies/series in Catalog / Search / VOD sync.
  Future<void> setSourceVodEnabled(String sourceId, bool enabled) async {
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    final current = sources[index];
    if (current.type != IptvSourceType.xtream) return;
    if (current.vodEnabled == enabled) return;
    final next = [...sources];
    next[index] = current.copyWith(vodEnabled: enabled);
    sources = next;
    _sourcesEnabledStamp++;
    _invalidateHomeShelfCaches();
    _sourcesRestored = true;
    _pruneHomeShelfSnapshotToVisibleSources();
    await _store.saveSources(sources);
    _uiQuiet = false;
    notifyListeners();
    _noteSyncableChange(urgent: true);
    _logSourcesFeatureSummary(reason: 'vod');
    if (enabled) {
      unawaited(ensureVodPrefetch(force: !_hasVodCacheFor(sources[index])));
    }
  }

  /// Replaces an existing Plex source with a server chosen via account sign-in.
  Future<void> updatePlexServerFromAccount({
    required String sourceId,
    required PlexServerResource server,
    String? name,
    String? epgUrl,
    String? epgSourceId,
    bool? epgEnabled,
    String? plexAccountToken,
  }) async {
    final clientId = await _plexClientIdentifier();
    final url = await _plexAccount.resolveReachableUrl(
      server,
      clientIdentifier: clientId,
    );
    final packed = PlexStoredConnections.fromResource(
      server,
      reachableUrl: url,
    );
    final label = (name ?? server.name).trim();
    await updateSourceDetails(
      sourceId: sourceId,
      name: label.isEmpty ? 'Plex' : label,
      serverUrl: packed.serverUrl,
      alternateServerUrl: packed.alternateServerUrl,
      extraServerUrls: packed.extraServerUrls,
      username: server.machineId,
      password: server.accessToken,
      plexAccountToken: plexAccountToken,
      epgUrl: epgUrl,
      epgSourceId: epgSourceId,
      epgEnabled: epgEnabled,
    );
  }

  /// Content from missing sources stays visible (e.g. local / downloads);
  /// known disabled sources are hidden until re-enabled.
  /// Parental hidden sources are omitted while the session is locked.
  bool isSourceContentVisible(String? sourceId) {
    if (sourceId == null || sourceId.isEmpty || sourceId == localSourceKey) {
      return true;
    }
    if (parentalLock?.isSourceIdHidden(sourceId) == true) return false;
    final source = _sourceById(sourceId);
    if (source == null) return true;
    return source.enabled;
  }

  /// Sources shown in Sources UI and pickers while parental lock is active.
  ///
  /// When unlocked (or no PIN), returns the full [sources] list. Hidden ids
  /// remain stored so they reappear after unlock.
  List<IptvSource> get parentalVisibleSources {
    final lock = parentalLock;
    if (lock == null || !lock.isContentLocked) return sources;
    return [
      for (final s in sources)
        if (!lock.isSourceIdHidden(s.id)) s,
    ];
  }

  /// Movies/series from this source may appear in Catalog / Search / VOD shelves.
  ///
  /// Xtream [IptvSource.vodEnabled] false keeps live TV but hides on-demand.
  bool isSourceVodContentVisible(String? sourceId) {
    if (sourceId == null || sourceId.isEmpty || sourceId == localSourceKey) {
      return true;
    }
    if (parentalLock?.isSourceIdHidden(sourceId) == true) return false;
    final source = _sourceById(sourceId);
    if (source == null) return true;
    if (!source.enabled) return false;
    if (source.type == IptvSourceType.xtream && !source.vodEnabled) {
      return false;
    }
    return true;
  }

  /// Home / Catalog listings after sources are restored.
  ///
  /// [isSourceVodContentVisible] still treats a missing source as visible so
  /// watchlist matching and downloads with a stale id keep working. Accueil
  /// must not — otherwise a gone catalog stays on Movies next to other
  /// catalogs.
  bool isListedVodSourceVisible(String? sourceId) {
    if (!isSourceVodContentVisible(sourceId)) return false;
    if (sourceId == null || sourceId.isEmpty || sourceId == localSourceKey) {
      return true;
    }
    if (!_sourcesRestored) return true;
    return _sourceById(sourceId) != null;
  }

  /// Whether [source] should participate in VOD network pulls / disk hydrate.
  bool _sourceContributesVod(IptvSource source) {
    if (!source.enabled) return false;
    if (source.type == IptvSourceType.xtream && !source.vodEnabled) {
      return false;
    }
    return true;
  }

  /// Enabled, parental-visible source ids.
  ///
  /// Always an allow-list — never null. A null filter used to mean "every
  /// live SQLite row", which kept dropped types (Twitch/Kick) on Live TV
  /// after the source JSON skipped them.
  List<String> get _liveAllowedSourceIds {
    return [
      for (final s in sources)
        if (s.enabled && parentalLock?.isSourceIdHidden(s.id) != true) s.id,
    ];
  }

  /// Follow-on work after playlist sync (EPG / VOD / live fill / deep page-in).
  ///
  /// Sources rows use this for the spinner and status line so VOD save and
  /// live fill stay visible after [_syncingSourceIds] clears.
  ///
  /// [_manualSyncExpectVod] covers the short delay before VOD prefetch enters
  /// [_vodPrefetching] so the row does not flash idle between playlist/live
  /// and Saving VOD.
  bool isSourceSyncActivity(String sourceId) =>
      _syncingSourceIds.contains(sourceId) ||
      _deepSyncing.contains(sourceId) ||
      _vodPrefetching.contains(sourceId) ||
      _manualSyncExpectVod.contains(sourceId) ||
      _liveCategoryPrefetching.contains(sourceId) ||
      _epgReloadPendingSourceIds.contains(sourceId);

  /// Sources whose first playlist / VOD catalog is still in flight.
  ///
  /// Latch survives [IptvSource.lastVodSyncedAt] being stamped before the
  /// long VOD save so Home can keep the first-sync notice up.
  final Set<String> _firstCatalogSyncIds = {};

  bool get isFirstCatalogSyncRunning => isFirstCatalogSyncRunningFor(
    sources: sources,
    isBusy: isSourceSyncActivity,
    latchedIds: _firstCatalogSyncIds,
  );

  void _markFirstCatalogSyncIfNeeded(IptvSource source) {
    if (!sourceAwaitsFirstCatalog(source)) return;
    if (_firstCatalogSyncIds.add(source.id)) {
      _scheduleSyncStatusTick();
    }
  }

  String? syncStatusFor(String sourceId) => _sourceSyncStatus[sourceId];

  /// Bumped on every sync status change so Sources can watch progress without
  /// subscribing to the whole provider.
  int syncStatusRevision = 0;

  /// Sources / Live strip only. Soft sync must not [notifyListeners] the
  /// whole library — that rematerializes IndexedStack tabs (Music `watch`,
  /// Library stamp) and Windows drops focus ("Récupération de la playlist M3U").
  final syncStatusListenable = LibrarySyncStatusTick();

  bool _syncStatusNotifyScheduled = false;
  int _lastSyncStatusTickMs = 0;
  Timer? _syncStatusCoalesceTimer;

  void _scheduleSyncStatusTick() {
    // During restore thaw, defer so Windows can take focus / clicks first.
    if (_shellThawing) {
      _thawNotifyPending = true;
      return;
    }
    // Active Sync must paint status, but immediate ticks on every progress /
    // label rewrite rematerialized every Sources card and made hover laggy.
    // Cap at ~2 Hz; always flush clears immediately.
    final busy = _syncingSourceIds.isNotEmpty ||
        _vodPrefetching.isNotEmpty ||
        _liveCategoryPrefetching.isNotEmpty ||
        _manualSyncFocusHold.isNotEmpty;
    if (busy) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final due = now - _lastSyncStatusTickMs >= 500;
      if (due) {
        _lastSyncStatusTickMs = now;
        _syncStatusCoalesceTimer?.cancel();
        _syncStatusCoalesceTimer = null;
        _syncStatusNotifyScheduled = false;
        syncStatusListenable.tick();
        return;
      }
      _syncStatusCoalesceTimer ??= Timer(const Duration(milliseconds: 500), () {
        _syncStatusCoalesceTimer = null;
        if (_disposed) return;
        _lastSyncStatusTickMs = DateTime.now().millisecondsSinceEpoch;
        syncStatusListenable.tick();
      });
      return;
    }
    if (_syncStatusNotifyScheduled) return;
    _syncStatusNotifyScheduled = true;
    SchedulerBinding.instance.scheduleTask(() {
      _syncStatusNotifyScheduled = false;
      if (_disposed) return;
      if (_shellThawing) {
        _thawNotifyPending = true;
        return;
      }
      syncStatusListenable.tick();
    }, Priority.idle);
  }

  void _setSourceSyncStatus(String sourceId, String? status) {
    if (status == null || status.isEmpty) {
      if (!_sourceSyncStatus.containsKey(sourceId)) return;
      _sourceSyncStatus.remove(sourceId);
      _hwndStatusLogMs.remove(sourceId);
      HwndSyncTrace.of(sourceId)?.mark('status-clear');
      // Drop coalesce so Sources clears the busy row without a 500ms wait.
      _lastSyncStatusTickMs = 0;
      _syncStatusCoalesceTimer?.cancel();
      _syncStatusCoalesceTimer = null;
    } else {
      // Skip no-op writes so coalesced idle notifies stay meaningful.
      if (_sourceSyncStatus[sourceId] == status) return;
      _sourceSyncStatus[sourceId] = status;
      // Compact status so logs stay greppable (UI strings can be long FR copy).
      final compact = status.length > 80 ? '${status.substring(0, 80)}…' : status;
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastLog = _hwndStatusLogMs[sourceId] ?? 0;
      if (now - lastLog >= 750) {
        _hwndStatusLogMs[sourceId] = now;
        HwndSyncTrace.of(sourceId)?.mark(
          'status',
          'ui="${compact.replaceAll('"', "'")}"',
        );
      }
    }
    syncStatus = _sourceSyncStatus.isEmpty
        ? null
        : _sourceSyncStatus.values.last;
    syncStatusRevision++;
    _scheduleSyncStatusTick();
  }

  void _clearSourceSyncStatusIfIdle(String sourceId) {
    if (isSourceSyncActivity(sourceId)) return;
    final latched = _firstCatalogSyncIds.remove(sourceId);
    _setSourceSyncStatus(sourceId, null);
    if (latched) _scheduleSyncStatusTick();
  }

  /// Quick reachability check before saving an M3U source.
  ///
  /// For remote URLs, fetches only the first few KB so huge playlists don't
  /// block the sheet. For local files, verifies the path exists and is non-empty.
  /// Sniffs the peek so JSON catalogs / HLS singles / Xtream API JSON are
  /// rejected with a [SourceKindMismatchException] the Sources UI can act on.
  ///
  /// Xtream-shaped URLs are confirmed by probing when possible (body sniff and,
  /// with credentials, a lightweight `player_api.php` peek) rather than
  /// blocking on URL shape alone. Playlist exports (`get.php`) stay saveable as
  /// M3U; set [acceptXtreamPlaylistExport] after the soft suggest CTA.
  Future<void> _probeM3uPlaylist(
    String playlistUrl, {
    bool acceptXtreamPlaylistExport = false,
  }) async {
    final location = playlistUrl.trim();
    final xtream = tryDetectXtreamUrl(location);
    final localPath = M3uPlaylistIo.tryLocalFilePath(location);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Playlist file not found');
      }
      final raf = await file.open();
      try {
        final peekBytes = await raf.read(4096);
        if (peekBytes.isEmpty) {
          throw Exception('Playlist file is empty');
        }
        _assertM3uContent(utf8.decode(peekBytes, allowMalformed: true));
      } finally {
        await raf.close();
      }
      return;
    }

    if (!M3uPlaylistIo.isRemotePlaylistUrl(location)) {
      throw Exception('Enter a valid playlist URL or local .m3u file path');
    }

    String? peek;
    Object? peekError;
    try {
      final peekBytes = await _peekRemoteBytes(location);
      if (peekBytes.isEmpty) {
        throw Exception('Playlist URL returned an empty response');
      }
      final decoded = utf8.decode(peekBytes, allowMalformed: true);
      if (decoded.trim().isEmpty) {
        throw Exception('Playlist URL returned an empty response');
      }
      peek = decoded;
    } catch (e) {
      peekError = e;
    }

    if (peek != null) {
      if (_peekLooksLikeM3uPlaylist(peek)) {
        if (xtream?.shape == XtreamUrlShape.playlistExport &&
            !acceptXtreamPlaylistExport) {
          throw _xtreamM3uMismatch(softSuggest: true);
        }
        return;
      }

      final kind = sniffSourceContent(peek);
      if (kind == SourceContentKind.xtreamCodes) {
        throw _xtreamM3uMismatch();
      }
      if (kind == SourceContentKind.jsonCatalog ||
          kind == SourceContentKind.hlsPlaylist ||
          kind == SourceContentKind.xmlEpg) {
        _assertM3uContent(peek);
        return;
      }

      // HTML / unknown body on an Xtream-shaped URL — confirm via player_api
      // when credentials are present, then hard-suggest Xtream.
      if (xtream != null && xtream.blocksM3uImport) {
        if (xtream.hasCredentials) {
          final confirmed = await _confirmXtreamPlayerApi(xtream);
          if (confirmed) throw _xtreamM3uMismatch();
        }
        throw _xtreamM3uMismatch();
      }

      _assertM3uContent(peek);
      return;
    }

    // Peek failed — try player_api when we have credentials; otherwise fall
    // back to shape for non-playlist Xtream URLs so save still guides correctly.
    if (xtream != null && xtream.blocksM3uImport) {
      if (xtream.hasCredentials) {
        final confirmed = await _confirmXtreamPlayerApi(xtream);
        if (confirmed) throw _xtreamM3uMismatch();
      }
      throw _xtreamM3uMismatch();
    }
    final error = peekError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception('$error');
    }
    throw Exception('Playlist URL probe failed');
  }

  SourceKindMismatchException _xtreamM3uMismatch({bool softSuggest = false}) {
    return SourceKindMismatchException(
      expected: SourceContentExpectation.m3uPlaylist,
      detected: SourceContentKind.xtreamCodes,
      softSuggest: softSuggest,
      message: mismatchMessageFor(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.xtreamCodes,
      ),
    );
  }

  bool _peekLooksLikeM3uPlaylist(String peek) {
    final kind = sniffSourceContent(peek);
    if (kind == SourceContentKind.iptvM3u) return true;
    if (kind != SourceContentKind.unknown) return false;
    return peek.toUpperCase().contains('#EXTINF') ||
        looksLikeBasicM3uPlaylist(peek);
  }

  /// Lightweight `player_api.php` sniff using credentials extracted from a URL.
  Future<bool> _confirmXtreamPlayerApi(DetectedXtreamUrl detected) async {
    if (!detected.hasCredentials) return false;
    final uri = Uri.parse('${detected.baseUrl}/player_api.php').replace(
      queryParameters: {
        'username': detected.username!,
        'password': detected.password!,
      },
    );
    try {
      final bytes = await _peekRemoteBytes(uri.toString());
      if (bytes.isEmpty) return false;
      return looksLikeXtreamPlayerApiResponse(
        utf8.decode(bytes, allowMalformed: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// Quick reachability / kind check before saving a standalone XMLTV source.
  Future<void> _probeEpgLocation(String epgUrl) async {
    final location = epgUrl.trim();
    final localPath = LocalSourcePath.tryLocalFilePath(location);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('EPG file not found');
      }
      final length = await file.length();
      if (length == 0) throw Exception('EPG file is empty');
      if (length > kMaxEpgDownloadBytes) {
        throw Exception('EPG file is too large');
      }
      final raf = await file.open();
      try {
        final peekBytes = await raf.read(4096);
        if (peekBytes.isEmpty) throw Exception('EPG file is empty');
        _assertEpgContent(peekBytes, location);
      } finally {
        await raf.close();
      }
      return;
    }

    if (!LocalSourcePath.isRemoteUrl(location)) {
      throw Exception('Enter a valid EPG / XMLTV URL or local file path');
    }

    final peekBytes = await _peekRemoteBytes(location);
    if (peekBytes.isEmpty) {
      throw Exception('EPG URL returned an empty response');
    }
    _assertEpgContent(peekBytes, location);
  }

  void _assertEpgContent(List<int> peekBytes, String location) {
    // Gzip guides often look like binary until inflated.
    final magicGzip =
        peekBytes.length >= 2 && peekBytes[0] == 0x1f && peekBytes[1] == 0x8b;
    final lower = location.toLowerCase();
    if (magicGzip || lower.endsWith('.gz') || lower.endsWith('.xml.gz')) {
      return;
    }
    final peek = utf8.decode(peekBytes, allowMalformed: true);
    final kind = sniffSourceContent(peek);
    switch (kind) {
      case SourceContentKind.xmlEpg:
      case SourceContentKind.unknown:
        // Unknown: some feeds start with whitespace / comments only in the peek.
        return;
      case SourceContentKind.iptvM3u:
      case SourceContentKind.hlsPlaylist:
      case SourceContentKind.jsonCatalog:
      case SourceContentKind.html:
      case SourceContentKind.xtreamCodes:
        throw SourceKindMismatchException(
          expected: SourceContentExpectation.xmltvEpg,
          detected: kind,
          message: mismatchMessageFor(
            expected: SourceContentExpectation.xmltvEpg,
            detected: kind,
          ),
        );
    }
  }

  void _assertM3uContent(String peek) {
    final kind = sniffSourceContent(peek);
    switch (kind) {
      case SourceContentKind.iptvM3u:
        return;
      case SourceContentKind.jsonCatalog:
      case SourceContentKind.hlsPlaylist:
      case SourceContentKind.xmlEpg:
      case SourceContentKind.html:
      case SourceContentKind.xtreamCodes:
        throw SourceKindMismatchException(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: kind,
          message: mismatchMessageFor(
            expected: SourceContentExpectation.m3uPlaylist,
            detected: kind,
          ),
        );
      case SourceContentKind.unknown:
        // Some providers omit `#EXTM3U` on the first line; accept `#EXTINF`
        // or a basic URL-only playlist.
        if (peek.toUpperCase().contains('#EXTINF') ||
            looksLikeBasicM3uPlaylist(peek)) {
          return;
        }
        throw SourceKindMismatchException(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: kind,
          message: mismatchMessageFor(
            expected: SourceContentExpectation.m3uPlaylist,
            detected: kind,
          ),
        );
    }
  }

  /// Fetch the first [maxBytes] of a remote URL for content sniffing.
  Future<Uint8List> _peekRemoteBytes(
    String url, {
    int maxBytes = 4096,
    Map<String, String>? headers,
  }) async {
    final probe = await _probeRemoteUrl(
      url,
      maxBytes: maxBytes,
      headers: headers,
    );
    return probe.bytes;
  }

  /// GET (with Range) and return body peek + response headers for classification.
  Future<({Uint8List bytes, Map<String, String> headers, int statusCode})>
  _probeRemoteUrl(
    String url, {
    int maxBytes = 4096,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url.trim());
    final request = http.Request('GET', uri);
    request.headers['Range'] = 'bytes=0-${maxBytes - 1}';
    request.headers['Accept'] = '*/*';
    // Ask Icecast-style servers for in-band metadata when available.
    request.headers['Icy-MetaData'] = '1';
    if (headers != null) {
      request.headers.addAll(headers);
    }

    late final http.StreamedResponse streamed;
    try {
      streamed = await _http
          .send(request)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw Exception('URL timed out'),
          );
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('Could not reach URL: $e');
    }

    try {
      if (streamed.statusCode == 401 || streamed.statusCode == 403) {
        throw Exception(
          'Catalog auth failed (${streamed.statusCode}) — check the access token',
        );
      }
      if (streamed.statusCode >= 400 && streamed.statusCode != 416) {
        throw Exception('URL returned ${streamed.statusCode}');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(
        const Duration(seconds: 15),
      )) {
        buffer.add(chunk);
        if (buffer.length >= maxBytes) break;
      }
      final raw = buffer.takeBytes();
      final bytes = raw.length > maxBytes
          ? Uint8List.fromList(raw.sublist(0, maxBytes))
          : Uint8List.fromList(raw);
      return (
        bytes: bytes,
        headers: Map<String, String>.from(streamed.headers),
        statusCode: streamed.statusCode,
      );
    } on TimeoutException {
      throw Exception('URL timed out');
    }
  }

  /// Load full M3U playlist bytes from a remote URL or local file path.
  ///
  /// Remote downloads use connect + idle + overall timeouts so a stalled
  /// provider cannot pin soft-sync slots forever (probe already timed out;
  /// the full GET used to hang with no deadline).
  static const _m3uConnectTimeout = Duration(seconds: 30);
  static const _m3uIdleTimeout = Duration(seconds: 45);
  static const _m3uOverallTimeout = Duration(minutes: 3);
  static const _m3uMaxDownloadBytes = 64 * 1024 * 1024;

  Future<Uint8List> _loadM3uPlaylistBytes(
    String playlistUrl, {
    void Function(int bytesReceived)? onProgress,
  }) async {
    final location = playlistUrl.trim();
    final localPath = M3uPlaylistIo.tryLocalFilePath(location);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Playlist file not found: $localPath');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Playlist file is empty');
      }
      onProgress?.call(bytes.length);
      return bytes;
    }

    if (!M3uPlaylistIo.isRemotePlaylistUrl(location)) {
      throw Exception('Enter a valid playlist URL or local .m3u file path');
    }

    late final http.StreamedResponse streamed;
    try {
      final request = http.Request('GET', Uri.parse(location));
      request.headers['Accept'] = '*/*';
      streamed = await _http
          .send(request)
          .timeout(
            _m3uConnectTimeout,
            onTimeout: () =>
                throw Exception('Playlist download timed out (connect)'),
          );
    } on TimeoutException {
      throw Exception('Playlist download timed out (connect)');
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('Could not reach playlist URL: $e');
    }

    if (streamed.statusCode >= 400) {
      // Do not buffer a 404 HTML body on the UI isolate.
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      throw Exception('Failed to fetch M3U (${streamed.statusCode})');
    }

    final buffer = BytesBuilder(copy: false);
    final overall = Stopwatch()..start();
    final slice = Stopwatch()..start();
    var lastProgress = 0;
    try {
      await for (final chunk in streamed.stream.timeout(
        _m3uIdleTimeout,
        onTimeout: (sink) {
          throw Exception('Playlist download stalled');
        },
      )) {
        if (overall.elapsed > _m3uOverallTimeout) {
          throw Exception('Playlist download timed out');
        }
        buffer.add(chunk);
        if (buffer.length > _m3uMaxDownloadBytes) {
          throw Exception('Playlist is too large');
        }
        await yieldUiIfDue(slice, label: 'm3u-download');
        final n = buffer.length;
        if (onProgress != null &&
            (n - lastProgress >= 256 * 1024 || n == chunk.length)) {
          lastProgress = n;
          onProgress(n);
          await pumpUi();
        }
      }
    } on TimeoutException {
      throw Exception('Playlist download stalled');
    }

    final bytes = buffer.takeBytes();
    if (bytes.isEmpty) {
      throw Exception('Playlist URL returned an empty response');
    }
    onProgress?.call(bytes.length);
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  static String _formatByteSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// True when this source can feed the merged XMLTV cache (same rules as
  /// [_collectMergedEpgUrls]). Custom catalogs qualify when Guide is on and
  /// they advertise an `epgUrl`.
  bool _sourceContributesMergedXmltv(IptvSource source) {
    return source.contributesMergedXmltv(
      resolvedEpgUrl: resolvedEpgUrlFor(source),
    );
  }

  /// Keep Sources busy through the coalesced XMLTV reload that follows a
  /// playlist sync (guide fetch is unawaited and used to look like a hang).
  void _scheduleEpgReloadForSource(String sourceId, {required String reason}) {
    _epgReloadPendingSourceIds.add(sourceId);
    _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncUpdatingGuide);
    unawaited(
      _reloadMergedXmltvEpg(reason: reason).whenComplete(() {
        _epgReloadPendingSourceIds.remove(sourceId);
        _restoreSourceSyncStatusAfterEpg(sourceId);
        // Catalog indexes deferred across VOD + guide — resume once both done.
        _resumePostHydrateIndexesIfNeeded();
      }),
    );
  }

  /// After guide reload, either clear or re-assert deep/VOD/live-fill status.
  ///
  /// EPG progress broadcasts overwrite follow-on labels; if we only cleared when
  /// fully idle, Sources stayed on "Updating guide…" until paging finished.
  void _restoreSourceSyncStatusAfterEpg(String sourceId) {
    if (_syncingSourceIds.contains(sourceId)) return;
    if (_deepSyncing.contains(sourceId)) {
      _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncPagingRemaining);
      return;
    }
    if (_vodPrefetching.contains(sourceId)) {
      _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncFetchingVodCatalog);
      return;
    }
    if (_manualSyncExpectVod.contains(sourceId)) {
      // Prefetch not started yet — keep live/guide status, not a fake
      // "Démarrage du cache VOD" that blamed VOD for SQLite stalls.
      if (_liveCategoryPrefetching.contains(sourceId)) {
        _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncFillingLiveChannels);
      }
      return;
    }
    if (_liveCategoryPrefetching.contains(sourceId)) {
      _setSourceSyncStatus(sourceId, _uiL10n.sourceSyncFillingLiveChannels);
      return;
    }
    _setSourceSyncStatus(sourceId, null);
  }

  void _flushPendingEpgAfterVod(String sourceId) {
    final reason = _pendingEpgAfterVod.remove(sourceId);
    if (reason == null || _disposed) return;
    if (_sourceById(sourceId) == null) return;
    // Stop any in-flight group-index so guide HTTP/SQLite owns the UI isolate.
    _vodGroupIndexAbort = true;
    _postHydrateIndexesPending = true;
    JavpLog.i(
      'epg',
      'flush deferred guide after VOD source=$sourceId reason=$reason',
    );
    _scheduleEpgReloadForSource(sourceId, reason: reason);
  }

  void _setEpgReloadProgress(String status) {
    if (_epgReloadPendingSourceIds.isEmpty) {
      // Idle/settings-triggered reload — still drive the Live TV strip.
      syncStatus = status;
      syncStatusRevision++;
      _scheduleSyncStatusTick();
      return;
    }
    for (final id in _epgReloadPendingSourceIds) {
      _setSourceSyncStatus(id, status);
    }
  }

  /// Collect XMLTV URLs from enabled EPG sources and epg-enabled live lists,
  /// then merge into the global guide cache.
  ///
  /// Debounces ~750ms so consecutive soft syncs (M3U then Xtream) share one
  /// reload; awaits any in-flight load and skips when the URL set is unchanged
  /// (parsed programmes already warm — [reused] climbs across soft-sync waves).
  Future<void> _reloadMergedXmltvEpg({String reason = 'unspecified'}) {
    _epgReloadReason = reason;
    final waiters = _epgReloadWaiters ??= Completer<void>();
    _epgReloadDebounce?.cancel();
    _epgReloadDebounce = Timer(const Duration(milliseconds: 750), () {
      final c = _epgReloadWaiters;
      _epgReloadWaiters = null;
      final r = _epgReloadReason;
      unawaited(() async {
        try {
          // Soft-sync waves often overlap: wait for the first load, then skip
          // when feeds are already applied (avoids a second ~3–5s parse).
          final inflight = _epgReloadInFlight;
          if (inflight != null) {
            try {
              await inflight;
            } catch (_) {}
            final urls = _collectMergedEpgUrls();
            if (urls.isNotEmpty &&
                _epgHasAppliedPrograms &&
                _epgAppliedUrls.length == urls.length &&
                _epgAppliedUrls.containsAll(urls) &&
                urls.every(_epgFeedIsWarm)) {
              JavpLog.i(
                'epg',
                'load skip coalesced unchanged feeds=${urls.length} '
                    'reason=$r',
              );
              if (c != null && !c.isCompleted) c.complete();
              return;
            }
          }
          final run = _reloadMergedXmltvEpgNow(reason: r);
          _epgReloadInFlight = run;
          try {
            await run;
            if (c != null && !c.isCompleted) c.complete();
          } catch (e, st) {
            if (c != null && !c.isCompleted) c.completeError(e, st);
          } finally {
            if (identical(_epgReloadInFlight, run)) {
              _epgReloadInFlight = null;
            }
          }
        } catch (e, st) {
          if (c != null && !c.isCompleted) c.completeError(e, st);
        }
      }());
    });
    return waiters.future;
  }

  Set<String> _collectMergedEpgUrls() {
    final urls = <String>{};
    for (final source in sources) {
      if (!_sourceContributesMergedXmltv(source)) continue;
      if (source.type == IptvSourceType.xmltv) {
        urls.add(source.epgUrl!.trim());
        continue;
      }
      final resolved = resolvedEpgUrlFor(source);
      if (resolved == null) continue;
      for (final part in splitEpgUrls(resolved)) {
        urls.add(part);
      }
    }
    return urls;
  }

  Future<void> _reloadMergedXmltvEpgNow({required String reason}) async {
    final phase = Stopwatch()..start();
    final urls = _collectMergedEpgUrls();
    if (urls.isEmpty) {
      if (epg.isNotEmpty ||
          epgChannelNames.isNotEmpty ||
          _epgProgramCount > 0 ||
          _epgDbFeedUrls.isNotEmpty) {
        epg = [];
        epgChannelNames = {};
        _epgAppliedUrls = {};
        _epgAliasIndex = null;
        _epgXmltvByExactId.clear();
        _epgXmltvLru.clear();
        _epgXmltvPrefetching.clear();
        _epgByStreamId.clear();
        _epgDbFeedUrls.clear();
        _epgProgramCount = 0;
        if (_useEpgDb) {
          try {
            await _epgDb.clear();
          } catch (_) {}
        }
        _bumpEpgRevision();
        _notifyListenersAfterIdle();
      }
      JavpLog.i('epg', 'load skip empty reason=$reason');
      return;
    }
    if (shouldSkipWarmXmltvReloadAfterPlaylistSync(
      reason: reason,
      urls: urls,
      appliedFeedUrls: _epgWarmFeedUrls,
      hasPrograms: _epgHasAppliedPrograms,
    )) {
      JavpLog.i(
        'epg',
        'load skip already-warm feeds=${urls.length} '
            'programs=$_epgProgramCount reason=$reason',
      );
      return;
    }
    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    try {
      await _loadEpgUrls(urls, reason: reason);
    } finally {
      _uiQuiet = wasQuiet;
      // Clear strip-only guide progress when no source is pending on it.
      if (_epgReloadPendingSourceIds.isEmpty) {
        final fromSources = _sourceSyncStatus.isEmpty
            ? null
            : _sourceSyncStatus.values.last;
        if (syncStatus != fromSources) {
          syncStatus = fromSources;
          syncStatusRevision++;
        }
      }
      _notifyListenersAfterIdle();
      if (!_useLiveDb) {
        unawaited(ensureLiveIndex(delay: const Duration(seconds: 2)));
      }
      JavpLog.i(
        'sync',
        'phase=epg reason=$reason totalMs=${phase.elapsedMilliseconds} '
            'feeds=${urls.length}',
      );
    }
  }

  /// True when two category lists match field-for-field (order-sensitive).
  bool _iptvCategoriesEquivalent(List<IptvCategory> a, List<IptvCategory> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.name != y.name ||
          x.kind != y.kind ||
          x.parentId != y.parentId ||
          x.sourceId != y.sourceId ||
          x.isAdult != y.isAdult) {
        return false;
      }
    }
    return true;
  }

  /// Full Xtream VOD/series list refresh policy:
  /// - [force]: manual Sync / explicit refresh
  /// - missing cache: light first fill (idle OK)
  /// - [lastVodSyncedAt] older than [_vodFreshness]: idle OK
  /// Otherwise skip — Catalog loads one category on demand.
  static const Duration _vodFreshness = Duration(hours: 24);

  /// Idle Xtream live group refresh — same window as VOD. Warm SQLite groups
  /// skip the network until this elapses; restart does not wipe them.
  static const Duration _liveCategoryFreshness =
      LiveChannelDb.defaultGroupFreshness;

  /// Late Home idle warm: keep huge disk parse off first paint / deferred
  /// catalog. Demand paths use [ensureVodDiskHydrated] with zero delay.
  static const Duration _vodIdleDiskHydrateDelay = Duration(seconds: 45);

  bool _vodWarmScheduled = false;
  bool _vodDiskHydrated = false;

  /// Shared so Home's idle warm and bootstrap await the same load instead of
  /// the second caller returning immediately while the first is still delayed.
  Future<void>? _vodHydrateFuture;

  /// Completes early when a later caller needs hydrate without the idle delay.
  Completer<void>? _vodHydrateDelayGate;

  /// True while [_vodHydrateFuture] is only waiting on the idle delay gate —
  /// not parsing yet. Catalog must not treat this as "Loading…".
  bool _vodHydrateIdleWaiting = false;

  /// Bumped when sources/VOD membership changes so an in-flight disk hydrate
  /// cannot re-insert rows for a source the user just deleted.
  int _vodHydrateEpoch = 0;

  /// Drop SQLite / pins for source ids that are no longer in [sources].
  ///
  /// Unknown types are omitted from source JSON (`IptvSource.tryFromJson`)
  /// without [removeSource], so live rows, categories, and pins used to remain.
  Future<void> _pruneUnknownSourceCaches() async {
    if (kIsWeb) return;
    final known = {for (final s in sources) s.id};
    Set<String> orphanLive = const {};
    try {
      orphanLive = await _liveDb.pruneUnknownSources(known);
    } catch (e) {
      JavpLog.w('live', 'prune unknown sources failed', error: e);
    }
    if (orphanLive.isNotEmpty) {
      _liveDbSourceIds.removeWhere(orphanLive.contains);
      liveDbRevision++;
      for (final id in orphanLive) {
        unawaited(_store.deleteSourcePassword(id));
      }
      JavpLog.i(
        'live',
        'pruned dropped sources n=${orphanLive.length} '
            'ids=${orphanLive.join(",")}',
      );
    }
    await _pruneVodCacheToKnownSources(persist: true);

    final nextCats = [
      for (final c in categories)
        if (known.contains(c.sourceId)) c,
    ];
    if (nextCats.length != categories.length) {
      categories = nextCats;
      unawaited(_store.saveCategories(categories));
    }

    _pruneHomeShelfSnapshotToVisibleSources();

    if (orphanLive.isEmpty) return;

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
    _invalidateHomeShelfCaches();
  }

  /// Drop VOD cache rows whose [MediaItem.sourceId] is no longer in [sources].
  ///
  /// After sources restore, Home listings hide missing ids via
  /// [isListedVodSourceVisible]. This prune still drops the SQLite / RAM rows
  /// so Catalog and disk stay clean.
  /// Local / download rows (null or [localSourceKey]) stay.
  Future<bool> _pruneVodCacheToKnownSources({bool persist = false}) async {
    final known = {for (final s in sources) s.id};
    if (_useVodDb) {
      final removed = await _vodDb.pruneUnknownSources(known);
      if (removed > 0) {
        _vodStreamCache.removeWhere((_, m) {
          final sid = m.sourceId;
          if (sid == null || sid.isEmpty || sid == localSourceKey) return false;
          return !known.contains(sid);
        });
        _touchVodCache();
        _invalidateHomeShelfCaches();
        await _refreshVodDbCountCache();
        return true;
      }
      return false;
    }
    final before = _vodStreamCache.length;
    _vodStreamCache.removeWhere((_, m) {
      final sid = m.sourceId;
      if (sid == null || sid.isEmpty || sid == localSourceKey) return false;
      return !known.contains(sid);
    });
    if (_vodStreamCache.length == before) return false;
    _touchVodCache();
    _invalidateHomeShelfCaches();
    if (persist) {
      await _store.saveVodCache(_vodStreamCache.values);
    }
    return true;
  }

  int _vodCountForSource(String sourceId, {int fallback = 0}) {
    var n = 0;
    for (final m in _vodStreamCache.values) {
      if (m.sourceId == sourceId &&
          (m.kind == MediaKind.vod || m.kind == MediaKind.series)) {
        n++;
      }
    }
    return n > 0 ? n : fallback;
  }

  Future<void> _runVodDiskHydrate({required Duration delay}) async {
    final epoch = _vodHydrateEpoch;
    final total = Stopwatch()..start();
    try {
      if (kIsWeb) {
        _vodDiskHydrated = true;
        JavpLog.i('vod', 'disk hydrate skipped on web');
        return;
      }
      JavpLog.i(
        'vod',
        'disk hydrate scheduled delayMs=${delay.inMilliseconds} '
            'hydrated=$_vodDiskHydrated useDb=$_useVodDb '
            'sources=${sources.where(_sourceContributesVod).length} '
            'queue=${_bgQueue.pendingCount}',
      );
      // Home idle warm must not COUNT a 200k-row DB on the first frames.
      // Wait first; Catalog demand (delay 0) probes immediately and opens
      // this gate once the existing SQLite catalog is live.
      if (delay > Duration.zero && !_useVodDb && !_vodDiskHydrated) {
        _vodHydrateIdleWaiting = true;
        final gate = Completer<void>();
        _vodHydrateDelayGate = gate;
        try {
          JavpLog.i(
            'vod',
            'disk hydrate idle-wait begin delayMs=${delay.inMilliseconds}',
          );
          await Future.any<void>([Future<void>.delayed(delay), gate.future]);
          final openedEarly = gate.isCompleted;
          JavpLog.i(
            'vod',
            'disk hydrate idle-wait end early=$openedEarly '
                'waitedMs=${total.elapsedMilliseconds}',
          );
        } finally {
          _vodHydrateIdleWaiting = false;
          if (identical(_vodHydrateDelayGate, gate)) {
            _vodHydrateDelayGate = null;
          }
        }
      }
      if (!_useVodDb && !kIsWeb) {
        await _maybeMigrateVodJsonToDb();
      }
      if (_useVodDb || _vodDiskHydrated) {
        if (_useVodDb) {
          await _finishVodDiskHydrateViaDb(epoch: epoch, total: total);
        } else {
          JavpLog.i(
            'vod',
            'disk hydrate skip after sqlite probe '
                'useDb=$_useVodDb hydrated=$_vodDiskHydrated '
                'totalMs=${total.elapsedMilliseconds}',
          );
        }
        return;
      }
      if (epoch != _vodHydrateEpoch) {
        JavpLog.i(
          'vod',
          'disk hydrate cancelled epoch-mismatch before-parse '
              'elapsedMs=${total.elapsedMilliseconds}',
        );
        return;
      }
      if (delay > Duration.zero) {
        // Catalog busy flips only when JSON parse starts (not idle wait).
        _bumpVodBusy();
      }
      JavpLog.i(
        'vod',
        'disk hydrate parse start elapsedMs=${total.elapsedMilliseconds} '
            'queue=${_bgQueue.pendingCount}',
      );
      // Parse + fromJson already ran off-UI (chunked). Filter known sources in
      // the worker so merge here is mostly map inserts + frame yields.
      final known = {
        for (final s in sources)
          if (_sourceContributesVod(s)) s.id,
      };
      final items = await _store.loadVodCache(
        knownSourceIds: known,
        localSourceKey: localSourceKey,
      );
      if (items.isEmpty) {
        _vodDiskHydrated = true;
        JavpLog.i(
          'vod',
          'disk hydrate done items=0 (empty/missing) '
              'totalMs=${total.elapsedMilliseconds}',
        );
        return;
      }
      if (epoch != _vodHydrateEpoch) {
        JavpLog.i(
          'vod',
          'disk hydrate cancelled epoch-mismatch after-parse '
              'items=${items.length}',
        );
        return;
      }
      var touched = false;
      _uiQuiet = true;
      try {
        // Large chunks + zero-delay yields: keep Windows pumping messages without
        // stretching hydrate across minutes (old 80@16ms ≈ 40s of sleep alone).
        const chunk = kIsolateListChunk;
        for (var i = 0; i < items.length; i += chunk) {
          if (epoch != _vodHydrateEpoch || _useVodDb) break;
          final end = (i + chunk > items.length) ? items.length : i + chunk;
          for (var j = i; j < end; j++) {
            final item = items[j];
            _vodStreamCache[item.id] = item;
            touched = true;
          }
          await yieldAfterIsolateChunk();
        }
        // Always prune when we may have raced with [removeSource] / sync.
        if (touched || epoch != _vodHydrateEpoch) {
          await _pruneVodCacheToKnownSources(persist: true);
        }
        if (epoch != _vodHydrateEpoch) {
          JavpLog.i(
            'vod',
            'disk hydrate cancelled epoch-mismatch during-merge '
                'items=${items.length}',
          );
          return;
        }
        if (_useVodDb) {
          JavpLog.i(
            'vod',
            'disk hydrate abandoned json merge after sqlite enable '
                'items=${items.length}',
          );
          return;
        }
        _touchVodCache();
      } finally {
        _uiQuiet = false;
      }
      if (epoch != _vodHydrateEpoch || _useVodDb) return;
      _vodDiskHydrated = true;
      // Keep Accueil shelf caches — [_bumpVodBusy] clears Catalog busy without
      // wiping Films/Series rails. Ranked previews + Accueil rematerialize wait
      // for group-index publish ([homeVodShelfRevision]).
      _schedulePostHydrateFollowups();
      JavpLog.i(
        'vod',
        'disk hydrate done items=${_vodStreamCache.length} '
            'totalMs=${total.elapsedMilliseconds} '
            'queue=${_bgQueue.pendingCount}',
      );
    } catch (e) {
      // Leave [_vodDiskHydrated] false so a later idle warm can retry.
      JavpLog.w(
        'vod',
        'disk hydrate failed totalMs=${total.elapsedMilliseconds}',
        error: e,
      );
    }
  }

  /// SQLite VOD path: no JSON blob — mark hydrated; defer heavy GROUP BY.
  Future<void> _finishVodDiskHydrateViaDb({
    required int epoch,
    required Stopwatch total,
  }) async {
    if (epoch != _vodHydrateEpoch) return;
    // Prefer meta cache — COUNT(*) of 200k rows blocked Synchroniser for 20s+.
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
    _vodDiskHydrated = true;
    // Light Home Films/Series rails only. Full group-index used to lag the
    // HWND for tens of seconds before Synchroniser — but Catalog needs the
    // per-source group-name map immediately or shelves stay empty.
    await pumpUi(label: 'vod-hydrate-previews');
    if (!_vodGroupIndexAbort) {
      await _refreshVodHomePreviewsFromDb();
      await pumpUi(label: 'vod-hydrate-group-cache');
      await _refreshVodDbGroupCache();
    }
    _homeVodShelfRevision++;
    _invalidateHomeShelfCaches();
    _schedulePostHydrateFollowups();
    JavpLog.i(
      'vod',
      'disk hydrate done via sqlite count=$_vodDbCountCache '
          'totalMs=${total.elapsedMilliseconds} '
          '(group-index deferred)',
    );
  }

  /// Source ids known to have at least one row in [VodCatalogDb].
  final Set<String> _vodDbSourceIds = {};

  /// Source ids known to have at least one row in [LiveChannelDb].
  final Set<String> _liveDbSourceIds = {};

  /// Group names per source from SQLite — Catalog chips without a RAM catalog.
  Map<String, Set<String>> _vodDbMovieGroupsBySource = {};
  Map<String, Set<String>> _vodDbSeriesGroupsBySource = {};
  int _vodDbGroupCacheRevision = 0;

  bool _hasVodCacheFor(IptvSource source) {
    if (_vodStreamCache.values.any(
      (m) =>
          m.sourceId == source.id &&
          (m.kind == MediaKind.vod || m.kind == MediaKind.series),
    )) {
      return true;
    }
    if (_useVodDb && _vodDbSourceIds.contains(source.id)) return true;
    return false;
  }

  bool _shouldNetworkRefreshVod(IptvSource source, {required bool force}) {
    if (force) return true;
    if (_vodPrefetching.contains(source.id)) return false;
    if (!_hasVodCacheFor(source)) return true;
    final last = source.lastVodSyncedAt;
    if (last == null) return false;
    return DateTime.now().difference(last) > _vodFreshness;
  }

  /// Soft/idle only: warm live SQLite skips `get_live_streams`.
  /// Manual Synchroniser always refreshes (see sync apply path).
  Future<bool> _shouldNetworkRefreshLive(
    IptvSource source, {
    required int liveCount,
  }) async {
    if (liveCount <= 0) return true;
    return !await _liveDb.sourceLiveDumpIsFresh(
      sourceId: source.id,
      maxAge: _liveCategoryFreshness,
    );
  }

  /// Warm VOD cache when UI asks (idle Home). Safe to call often.
  Future<void> ensureVodPrefetch({
    Duration delay = Duration.zero,
    bool force = false,
  }) async {
    JavpLog.i(
      'vod',
      'prefetch ensure begin delayMs=${delay.inMilliseconds} force=$force '
          'hydrated=$_vodDiskHydrated idleWaiting=$_vodHydrateIdleWaiting '
          'queue=${_bgQueue.pendingCount}',
    );
    // Disk must win over "missing memory ⇒ network refresh" when a prior
    // Xtream sync already wrote the on-disk cache.
    // Honor [delay] for disk too — previously only network waited, so soft
    // sync hydrated ~200k rows onto Accueil immediately (delayMs=0).
    final waited = Stopwatch()..start();
    await ensureVodDiskHydrated(delay: delay);
    if (delay > Duration.zero) {
      final left = delay - waited.elapsed;
      if (left > Duration.zero) {
        await Future<void>.delayed(left);
      }
    }
    var started = 0;
    var skipped = 0;
    for (final source in sources) {
      if (!_sourceContributesVod(source)) continue;
      if (source.type != IptvSourceType.xtream &&
          source.type != IptvSourceType.stalker) {
        continue;
      }
      if (!_shouldNetworkRefreshVod(source, force: force)) {
        skipped++;
        continue;
      }
      started++;
      if (source.type == IptvSourceType.xtream) {
        unawaited(prefetchXtreamOnDemand(source));
      } else {
        unawaited(prefetchStalkerOnDemand(source));
      }
    }
    JavpLog.i(
      'vod',
      'prefetch ensure end networkStart=$started skipped=$skipped '
          'elapsedMs=${waited.elapsedMilliseconds} '
          'queue=${_bgQueue.pendingCount}',
    );
  }

  /// After huge VOD disk hydrate: search hay + low-priority tracker relinks wait
  /// for settle. Accueil does **not** rematerialize here — [_bumpVodBusy] in
  /// [ensureVodDiskHydrated] clears Catalog busy; Home Films/Series wait for
  /// group-index publish ([homeVodShelfRevision]) so we avoid a ~700ms
  /// `tags=shelf` hitch with identical shelf counts. Group/Versions indexes
  /// defer further; Catalog still demand-loads via [ensureVodGroupIndex] /
  /// [ensureVodVariantIndex].
  ///
  /// Uses [Timer]s (not nested [Priority.idle] tasks) so followups still run
  /// when the UI isolate stays busy after hydrate.
  void _schedulePostHydrateFollowups() {
    _postHydrateFollowupsTimer?.cancel();
    _postHydrateIndexesPending = false;
    JavpLog.i(
      'vod',
      'post-hydrate followups scheduled settleMs='
          '${_postHydrateSettleDelay.inMilliseconds} '
          'accueilNotify=defer-to-group-index '
          'queue=${_bgQueue.pendingCount}',
    );

    _postHydrateFollowupsTimer = Timer(_postHydrateSettleDelay, () {
      if (_disposed) return;
      JavpLog.i(
        'vod',
        'post-hydrate settle -> hay + tracker relinks '
            'queue=${_bgQueue.pendingCount}',
      );
      _scheduleVodSearchHayBuild();
      unawaited(_relinkSimklWatching(priority: BackgroundPriority.low));
      unawaited(_relinkSimklPlanToWatch(priority: BackgroundPriority.low));
      unawaited(_relinkTraktWatchlist(priority: BackgroundPriority.low));
      unawaited(_relinkPlexWatchlist(priority: BackgroundPriority.low));
      unawaited(_relinkLetterboxdWatchlist(priority: BackgroundPriority.low));
      // Catalog indexes — Accueil rematerializes when group index publishes.
      // Desktop SyncEngine frees the UI isolate, so don't wait 60s (that left
      // Catalog/popular empty after cold start). Keep a short settle only.
      final indexDelay = DesktopUi.isDesktopOs
          ? const Duration(seconds: 2)
          : const Duration(seconds: 60);
      _postHydrateFollowupsTimer = Timer(indexDelay, () {
        _postHydrateFollowupsTimer = null;
        if (_disposed) return;
        if (!_allowIdleBackgroundWork || _vodGroupIndexAbort) {
          _postHydrateIndexesPending = true;
          JavpLog.i(
            'vod',
            'post-hydrate indexes deferred '
                'allowIdle=$_allowIdleBackgroundWork abort=$_vodGroupIndexAbort '
                '— resume on focus',
          );
          return;
        }
        _runPostHydrateIndexes();
      });
    });
  }

  void _runPostHydrateIndexes() {
    _postHydrateIndexesPending = false;
    if (_disposed || _vodGroupIndexAbort) return;
    JavpLog.i(
      'vod',
      'post-hydrate -> group+variant indexes '
          'queue=${_bgQueue.pendingCount} useDb=$_useVodDb',
    );
    if (_useVodDb) {
      unawaited(rebuildVodGroupIndexCoalesced());
    } else {
      _scheduleVodGroupIndexBuild();
    }
    _scheduleVodVariantIndexBuild();
  }

  /// Resume indexes skipped while alt-tabbed / AFK after disk hydrate.
  void _resumePostHydrateIndexesIfNeeded() {
    if (!_postHydrateIndexesPending || !_vodDiskHydrated || _disposed) {
      return;
    }
    if (!_allowIdleBackgroundWork) return;
    if (_manualSyncFocusHold.isNotEmpty) return;
    // Any SyncEngine job (live/VOD/EPG) — do not GROUP BY while a writer
    // process is still up, even on a different DB file (status + spawn hitch).
    if (DesktopUi.isDesktopOs && SyncScheduler.instance.isBusy) {
      return;
    }
    if (_epgReloadPendingSourceIds.isNotEmpty ||
        _epgReloadInFlight != null) {
      JavpLog.i('vod', 'post-hydrate indexes wait for guide');
      return;
    }
    JavpLog.i('vod', 'post-hydrate indexes resume after focus');
    // Abort was latched so Synchroniser could not race an in-flight build —
    // clear it before scheduling or [_runPostHydrateIndexes] no-ops.
    _clearVodGroupIndexAbort();
    _runPostHydrateIndexes();
  }

  /// Idle warm: network only when missing or stale — never on every Home paint.
  ///
  /// Disk hydrate waits for true idle + [_vodIdleDiskHydrateDelay] so it does
  /// not steal the first Home frames. Catalog / Search open the delay gate.
  /// When SQLite is already hydrated, skip the 45s empty-JSON warm and only
  /// network-refresh stale Xtream/Stalker sources.
  bool _needsIdleVodWarm() {
    if (!_vodDiskHydrated) return true;
    for (final source in sources) {
      if (!_sourceContributesVod(source)) continue;
      if (source.type != IptvSourceType.xtream &&
          source.type != IptvSourceType.stalker) {
        continue;
      }
      if (_shouldNetworkRefreshVod(source, force: false)) return true;
    }
    return false;
  }

  Future<void> scheduleIdleVodWarm({String reason = 'unspecified'}) async {
    if (_vodWarmScheduled) return;
    final root = _idleJobRootReason(reason);
    if (!_needsIdleVodWarm()) {
      JavpLog.i(
        'vod',
        'idle-vod-warm skip reason=$root (hydrated+fresh) '
            'queue=${_bgQueue.pendingCount}',
      );
      return;
    }
    _vodWarmScheduled = true;
    JavpLog.i(
      'vod',
      'idle-vod-warm enqueue reason=$root '
          'delayMs=${_vodIdleDiskHydrateDelay.inMilliseconds} '
          'hydrated=$_vodDiskHydrated queue=${_bgQueue.pendingCount}',
    );
    await _bgQueue.enqueue(
      id: 'idle-vod-warm',
      priority: BackgroundPriority.low,
      action: () async {
        // Alt-tab does not pause the queue — require shell focus too.
        // Shell inactive: yield (coalesce on focus). High-pri waiting: soft-defer.
        if (!_allowIdleBackgroundWork) {
          _vodWarmScheduled = false;
          JavpLog.i(
            'vod',
            'idle-vod-warm yield reason=$root '
                'fg=$_appForeground shell=$_desktopShellActive '
                'playback=$_playbackActive — resume on focus',
          );
          return;
        }
        if (_bgQueue.shouldDeferIdleWork) {
          JavpLog.i(
            'vod',
            'idle-vod-warm soft-defer reason=$root '
                'queue=${_bgQueue.pendingCount}',
          );
          _vodWarmScheduled = false;
          unawaited(
            Future<void>.delayed(
              const Duration(seconds: 2),
              () => scheduleIdleVodWarm(reason: 'defer:$root'),
            ),
          );
          return;
        }
        JavpLog.i(
          'vod',
          'idle-vod-warm start reason=$root hydrate+prefetch '
              'queue=${_bgQueue.pendingCount}',
        );
        // Bootstrap may have enabled SQLite after enqueue — skip empty JSON.
        if (!_needsIdleVodWarm()) {
          JavpLog.i(
            'vod',
            'idle-vod-warm skip at start (hydrated+fresh) reason=$root '
                'useDb=$_useVodDb hydrated=$_vodDiskHydrated',
          );
          return;
        }
        if (!_vodDiskHydrated) {
          await ensureVodDiskHydrated(delay: _vodIdleDiskHydrateDelay);
        }
        if (!_allowIdleBackgroundWork || _bgQueue.shouldDeferIdleWork) {
          JavpLog.i(
            'vod',
            'idle-vod-warm stop after hydrate (idle no longer allowed) '
                'reason=$root',
          );
          return;
        }
        if (!_needsIdleVodWarm()) return;
        await ensureVodPrefetch(delay: const Duration(seconds: 8));
      },
    );
  }

  /// Fetch Xtream live category chips when Direct is open and none are stored.
  ///
  /// Soft sync is idle/post-reveal; opening Categories must not wait on that
  /// if `iptv_categories` was empty (new profile, failed category-first save).
  Future<void> ensureXtreamLiveCategoryRows({
    Iterable<String>? sourceIds,
  }) async {
    final inflight = _ensureLiveCategoryRowsInflight;
    if (inflight != null) return inflight;
    final future = _ensureXtreamLiveCategoryRowsBody(sourceIds: sourceIds);
    _ensureLiveCategoryRowsInflight = future;
    try {
      await future;
    } finally {
      if (identical(_ensureLiveCategoryRowsInflight, future)) {
        _ensureLiveCategoryRowsInflight = null;
      }
    }
  }

  Future<void> _ensureXtreamLiveCategoryRowsBody({
    Iterable<String>? sourceIds,
  }) async {
    if (parentalLock?.ready == false) return;
    final want = sourceIds == null
        ? null
        : {
            for (final id in sourceIds)
              if (id.isNotEmpty) id,
          };
    final missing = <IptvSource>[
      for (final source in sources)
        if (source.enabled &&
            source.type == IptvSourceType.xtream &&
            (want == null || want.isEmpty || want.contains(source.id)) &&
            !categories.any(
              (c) => c.kind == IptvCategoryKind.live && c.sourceId == source.id,
            ))
          source,
    ];
    if (missing.isEmpty) return;

    var added = 0;
    for (final source in missing) {
      try {
        final liveCats = await _runUserFacing(
          () => _xtream.getCategories(source, IptvCategoryKind.live),
        );
        if (liveCats.isEmpty) {
          JavpLog.w('tv', 'ensure live categories empty source=${source.id}');
          continue;
        }
        categories = [
          ...categories.where(
            (c) =>
                !(c.sourceId == source.id && c.kind == IptvCategoryKind.live),
          ),
          ...liveCats,
        ];
        added += liveCats.length;
        JavpLog.i(
          'tv',
          'ensure live categories source=${source.id} n=${liveCats.length}',
        );
      } catch (e) {
        JavpLog.w(
          'live',
          'ensure live categories source=${source.id} failed: $e',
        );
      }
    }
    if (added == 0) return;
    await _store.saveCategories(categories);
    // Do not bump [liveDbRevision] — that rematerializes the channel list
    // while chips land. Category ids already participate in the TV stamp.
    await pumpUi();
    _notifyPierceQuiet();
  }

  /// Demand-fill Xtream live groups when Direct is open but SQLite is empty.
  ///
  /// Idle prefetch pauses during playback and waits on Home settle; opening
  /// Live must not sit on an empty list until that finishes.
  Future<void> ensureLiveListingsWarm({
    Iterable<String>? sourceIds,
    int maxCategories = 3,
  }) async {
    if (parentalLock?.ready == false) return;
    await ensureXtreamLiveCategoryRows(sourceIds: sourceIds);
    final probe = await pageLiveChannels(
      sourceIds: sourceIds,
      offset: 0,
      limit: 1,
    );
    if (probe.isNotEmpty) return;
    final rankedNames = IptvLocaleHints.rankGroups([
      for (final c in liveCategories) c.name,
    ], PlatformDispatcher.instance.locale);
    final cats = liveCategoriesToWarm(
      liveCategories,
      sourceIds: sourceIds,
      limit: maxCategories,
      preferGroupNames: rankedNames,
    );
    for (final category in cats) {
      await ensureLiveCategoryAvailable(category);
      final filled = await pageLiveChannels(
        sourceIds: sourceIds,
        offset: 0,
        limit: 1,
      );
      if (filled.isNotEmpty) return;
    }
  }

  /// Paint SQLite immediately; refresh one stale source without blocking the list.
  ///
  /// Joins [syncSource]'s in-flight set so Live / Search / idle sync share one job.
  void scheduleCatalogRevalidate({Iterable<String>? sourceIds}) {
    if (_disposed) return;
    final want = sourceIds == null || sourceIds.isEmpty
        ? null
        : {
            for (final id in sourceIds)
              if (id.isNotEmpty) id,
          };
    IptvSource? pick;
    for (final source in sources) {
      if (!source.enabled) continue;
      if (want != null && !want.contains(source.id)) continue;
      if (_syncingSourceIds.contains(source.id)) continue;
      final last = source.lastSyncedAt;
      final stale =
          last == null ||
          DateTime.now().difference(last) > _idleSourceSyncStale;
      if (!stale) continue;
      pick = source;
      break;
    }
    if (pick == null) return;
    unawaited(
      syncSource(pick.id, reason: 'swr', blockUi: false, refreshVod: false),
    );
  }

  DateTime? newestCatalogSyncAt({Iterable<String>? sourceIds}) {
    final want = sourceIds == null || sourceIds.isEmpty
        ? null
        : {
            for (final id in sourceIds)
              if (id.isNotEmpty) id,
          };
    DateTime? newest;
    for (final source in sources) {
      if (!source.enabled) continue;
      if (want != null && !want.contains(source.id)) continue;
      final at = source.lastSyncedAt;
      if (at == null) continue;
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return newest;
  }

  /// Compact age for list chrome (`3h ago`).
  static String formatCacheAge(DateTime at, {DateTime? now}) {
    final delta = (now ?? DateTime.now()).difference(at);
    if (delta.isNegative || delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inHours < 48) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }

  Future<void> _loadLiveCategoryBody(
    IptvSource source,
    IptvCategory category,
    String key, {
    required bool fromPrefetch,
  }) async {
    final watch = Stopwatch()..start();
    try {
      // Skip only when SQLite is still fresh. Epoch can already be marked
      // (ensure paints from cache then kicks a stale background refresh).
      final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
      if (fromPrefetch) {
        final listings = await _liveDb.countListingsInGroup(
          sourceId: source.id,
          groupName: category.name,
        );
        if (listings > 0 &&
            !await _liveDb.groupIsStale(
              sourceId: source.id,
              groupName: category.name,
              maxAge: _liveCategoryFreshness,
            )) {
          _liveCategoryFilledEpoch[key] = epoch;
          await _liveDb.touchGroupFilledIfMissing(
            sourceId: source.id,
            groupName: category.name,
          );
          return;
        }
      }
      final packed = await _xtream.loadCategoryLivePacked(
        source,
        category: category,
      );
      final dbWatch = Stopwatch()..start();
      final result = await _liveDb.upsertSourceGroupLivePacked(
        sourceId: source.id,
        groupName: category.name,
        channels: packed,
        epgDisplayNames: epgChannelNames,
        preferredLiveQualities: preferredLiveQualities,
      );
      final dbMs = dbWatch.elapsedMilliseconds;
      _liveCategoryFilledEpoch[key] = epoch;
      if (result != LiveGroupUpsertResult.written) {
        JavpLog.i(
          'tv',
          'live category keep cache in ${watch.elapsedMilliseconds}ms '
              'group=${category.name} channels=${packed.length} dbMs=$dbMs '
              'prefetch=$fromPrefetch reason=${result.name}',
        );
        return;
      }
      _useLiveDb = true;
      _liveDbSourceIds.add(source.id);
      // Idle prefetch coalesces one revision bump in its finally. Ensure-driven
      // background refresh reuses fromPrefetch but is not inside that loop, so
      // bump immediately or the open Live list keeps the old SQLite page.
      final coalescePrefetchRevision =
          fromPrefetch && _liveCategoryPrefetching.contains(source.id);
      if (coalescePrefetchRevision) {
        _prefetchLiveDbDirty = true;
      } else {
        liveDbRevision++;
        await _reloadPinnedLiveChannels();
      }
      final count = await _liveDb.countChannels(sourceId: source.id);
      final idx = sources.indexWhere((s) => s.id == source.id);
      if (idx >= 0 && sources[idx].channelCount != count) {
        sources = [...sources]
          ..[idx] = sources[idx].copyWith(channelCount: count);
        await _store.saveSources(sources);
      }
      JavpLog.i(
        'tv',
        'live category upsert in ${watch.elapsedMilliseconds}ms '
            'group=${category.name} channels=${packed.length} dbMs=$dbMs '
            'prefetch=$fromPrefetch',
      );
      if (!coalescePrefetchRevision) {
        // Pierce quiet-mode so TV paints the group the user just opened /
        // rematerializes after an ensure-driven stale refresh.
        _notifyPierceQuiet();
      } else if (!_uiQuiet) {
        notifyListeners();
      }
    } catch (e, st) {
      JavpLog.w('live', 'loadLiveCategory ${category.name} failed: $e\n$st');
    }
  }

  /// Background sync: one `get_live_streams` dump, merged into SQLite.
  ///
  /// TV still demand-loads a single group via [loadLiveCategory] while this
  /// runs. Returns false when the panel rejects an unscoped dump so the
  /// per-group prefetch can fill instead.
  Future<bool> _tryMergeXtreamLiveDump(
    IptvSource source,
    List<IptvCategory> liveCats,
  ) async {
    try {
      _setSourceSyncStatus(source.id, _uiL10n.sourceSyncFillingLiveChannels);

      // Desktop: live dump (~28k rows + listings) still hitch the HWND when
      // drained on the UI isolate — SyncEngine owns the writer.
      if (DesktopUi.isDesktopOs) {
        // Keep Catalog/Home indexes deferred for the whole Synchroniser
        // session — resuming mid-live OOP rematerialized shelves while
        // status ticks and felt like stutter on the main UI.
        _vodGroupIndexAbort = true;
        _postHydrateIndexesPending = true;
        final client = SyncClient();
        _syncClients['live:${source.id}'] = client;
        late final SyncJobResult dumped;
        try {
          dumped = await client.runXtreamLive(
            profileId: profileId,
            source: source,
            epgDisplayNames: Map<String, String>.from(epgChannelNames),
            preferredLiveQualities:
                Map<String, String>.from(preferredLiveQualities),
            liveCategories: liveCats,
            reason: SyncReason.manual,
            onProgress: (event) {
              if (event.type != 'progress') return;
              final committed = event.committed;
              final total = event.total;
              if (committed == null || total == null) return;
              _setSourceSyncStatus(
                source.id,
                _uiL10n.sourceSyncFillingLiveChannelsProgress(
                  '$committed',
                  '$total',
                ),
              );
            },
          );
        } finally {
          _syncClients.remove('live:${source.id}');
        }
        if (dumped.sqlCount == 0) return false;
        if (dumped.skipped) {
          await _liveDb.touchSourceLiveDumpAt(sourceId: source.id);
          final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
          for (final cat in liveCats) {
            _liveCategoryFilledEpoch['${source.id}|${cat.id}'] = epoch;
          }
          return true;
        }
        _useLiveDb = true;
        _liveDbSourceIds.add(source.id);
        final count = await _liveDb.countChannels(sourceId: source.id);
        final idx = sources.indexWhere((s) => s.id == source.id);
        if (idx >= 0 && sources[idx].channelCount != count) {
          sources = [...sources]
            ..[idx] = sources[idx].copyWith(channelCount: count);
          unawaited(_store.saveSources(sources));
        }
        final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
        for (final cat in liveCats) {
          _liveCategoryFilledEpoch['${source.id}|${cat.id}'] = epoch;
        }
        if (dumped.written) {
          liveDbRevision++;
          unawaited(_reloadPinnedLiveChannels());
        }
        JavpLog.i(
          'tv',
          'live dump merge (oop) source=${source.id} '
              'channels=${dumped.sqlCount} written=${dumped.written} '
              'skipped=${dumped.skipped}',
        );
        return true;
      }

      var expectedTotal = 0;
      final publishWatch = Stopwatch()..start();
      var lastPublishedMs = 0;
      var hasPublished = false;
      final session = await _liveDb.beginStreamingMerge(
        sourceId: source.id,
        onProgress: (committed, total) async {
          final elapsed = publishWatch.elapsedMilliseconds;
          if (hasPublished && elapsed - lastPublishedMs < 750) return;
          hasPublished = true;
          lastPublishedMs = elapsed;
          _setSourceSyncStatus(
            source.id,
            _uiL10n.sourceSyncFillingLiveChannelsProgress(
              '$committed',
              '$total',
            ),
          );
        },
      );
      XtreamPackedIngest dumped;
      try {
        dumped = await UiStallWatchdog.span(
          'xtream-live-stream',
          () => _xtream.streamLiveCatalog(
            source,
            liveCategories: liveCats,
            epgDisplayNames: epgChannelNames,
            preferredLiveQualities: preferredLiveQualities,
            skipIf: (fp, n) async {
              expectedTotal = n;
              return session.skipIfFingerprint(fp);
            },
            onSqlChunk: (chunk) =>
                session.addChannelChunk(chunk, total: expectedTotal),
            onListingChunk: session.addListingChunk,
            onVariantChunk: session.addVariantChunk,
          ),
        );
      } catch (e) {
        await session.abort();
        rethrow;
      }
      if (dumped.sqlCount == 0) return false;
      if (dumped.skipped) {
        // Content unchanged — refresh the 24h skip clock and keep epochs so
        // TV does not treat every group as unfilled after Synchroniser.
        await _liveDb.touchSourceLiveDumpAt(sourceId: source.id);
        final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
        for (final cat in liveCats) {
          _liveCategoryFilledEpoch['${source.id}|${cat.id}'] = epoch;
        }
        return true;
      }
      session.indexFingerprint = dumped.indexFingerprint;
      final written = await session.finish(fingerprint: dumped.fingerprint);
      _useLiveDb = true;
      _liveDbSourceIds.add(source.id);
      final count = await _liveDb.countChannels(sourceId: source.id);
      final idx = sources.indexWhere((s) => s.id == source.id);
      if (idx >= 0 && sources[idx].channelCount != count) {
        sources = [...sources]
          ..[idx] = sources[idx].copyWith(channelCount: count);
        unawaited(_store.saveSources(sources));
      }
      final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
      for (final cat in liveCats) {
        _liveCategoryFilledEpoch['${source.id}|${cat.id}'] = epoch;
      }
      if (written) {
        liveDbRevision++;
        unawaited(_reloadPinnedLiveChannels());
      }
      JavpLog.i(
        'tv',
        'live dump merge source=${source.id} channels=${dumped.sqlCount} '
            'written=$written skipped=${dumped.skipped}',
      );
      return true;
    } catch (e, st) {
      JavpLog.w(
        'tv',
        'live dump merge failed source=${source.id}; '
            'falling back to per-group fill: $e\n$st',
      );
      return false;
    }
  }

  /// Idle fill of Xtream live categories after sync (low priority).
  ///
  /// Pauses on desktop blur / AFK / playback — [setDesktopShellActive] clears
  /// [_liveCategoryPrefetching] so the loop exits; focus requeues via
  /// [_resumeLiveCategoryPrefetchAfterFocus].
  Future<void> prefetchXtreamLiveCategories(IptvSource source) async {
    if (source.type != IptvSourceType.xtream) return;
    if (!_liveCategoryPrefetching.add(source.id)) return;
    _liveCategoryPrefetchPaused.remove(source.id);
    _markFirstCatalogSyncIfNeeded(source);
    _setSourceSyncStatus(source.id, _uiL10n.sourceSyncFillingLiveChannels);
    // Never stampede Accueil trickle / tile expand with category upserts.
    await waitUntilHomeRevealSettled();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!_liveCategoryPrefetching.contains(source.id)) {
      _clearSourceSyncStatusIfIdle(source.id);
      return;
    }
    if (!_allowIdleBackgroundWork) {
      _liveCategoryPrefetching.remove(source.id);
      _liveCategoryPrefetchPaused.add(source.id);
      _clearSourceSyncStatusIfIdle(source.id);
      JavpLog.i(
        'tv',
        'prefetch live categories pause before start source=${source.id} '
            'shell=$_desktopShellActive fg=$_appForeground',
      );
      return;
    }
    final phase = Stopwatch()..start();
    var filled = 0;
    var skipped = 0;
    var catCount = 0;
    var paused = false;
    final wasQuiet = _uiQuiet;
    _uiQuiet = true;
    try {
      final cats = categories
          .where(
            (c) => c.kind == IptvCategoryKind.live && c.sourceId == source.id,
          )
          .toList();
      catCount = cats.length;
      if (await _tryMergeXtreamLiveDump(source, cats)) {
        filled = catCount;
        return;
      }
      if (catCount > 0) {
        _setSourceSyncStatus(
          source.id,
          _uiL10n.sourceSyncFillingLiveChannelsProgress('0', '$catCount'),
        );
      }
      final inflight = <Future<void>>{};
      final listingCounts = catCount == 0
          ? const <String, int>{}
          : await _liveDb.listingCountsByGroup(sourceId: source.id);
      for (final cat in cats) {
        if (!_liveCategoryPrefetching.contains(source.id)) {
          paused = true;
          break;
        }
        if (!_allowIdleBackgroundWork) {
          paused = true;
          break;
        }
        final key = '${source.id}|${cat.id}';
        final epoch = _xtreamLiveCategoriesEpoch[source.id] ?? 0;
        if (_liveCategoryFilledEpoch[key] == epoch) {
          skipped++;
          continue;
        }
        final n = listingCounts[cat.name] ?? 0;
        final stale =
            n > 0 &&
            await _liveDb.groupIsStale(
              sourceId: source.id,
              groupName: cat.name,
              maxAge: _liveCategoryFreshness,
            );
        if (n > 0 && !stale) {
          _liveCategoryFilledEpoch[key] = epoch;
          unawaited(
            _liveDb.touchGroupFilledIfMissing(
              sourceId: source.id,
              groupName: cat.name,
            ),
          );
          skipped++;
          continue;
        }
        await _yieldToBrowse(reason: 'live-prefetch');
        if (!_liveCategoryPrefetching.contains(source.id) ||
            !_allowIdleBackgroundWork) {
          paused = true;
          break;
        }
        final fill = loadLiveCategory(cat, background: true).then((_) {
          filled++;
          _setSourceSyncStatus(
            source.id,
            _uiL10n.sourceSyncFillingLiveChannelsProgress(
              '$filled',
              '$catCount',
            ),
          );
        });
        inflight.add(fill);
        fill.whenComplete(() => inflight.remove(fill));
        if (_interactive.isBusy) {
          await fill;
        } else if (inflight.length >= 2) {
          await Future.any(List<Future<void>>.of(inflight));
        }
      }
      if (inflight.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(inflight));
      }
    } finally {
      _uiQuiet = wasQuiet;
      if (_prefetchLiveDbDirty) {
        _prefetchLiveDbDirty = false;
        liveDbRevision++;
        unawaited(_reloadPinnedLiveChannels());
      }
      _liveCategoryPrefetching.remove(source.id);
      if (paused) {
        _liveCategoryPrefetchPaused.add(source.id);
      } else {
        _liveCategoryPrefetchPaused.remove(source.id);
      }
      _clearSourceSyncStatusIfIdle(source.id);
      JavpLog.i(
        'tv',
        'prefetch live categories in ${phase.elapsedMilliseconds}ms '
            'source=${source.id} filled=$filled skipped=$skipped '
            'cats=$catCount paused=$paused',
      );
      JavpLog.i(
        'sync',
        'phase=live-prefetch source=${source.id} '
            'totalMs=${phase.elapsedMilliseconds} filled=$filled '
            'skipped=$skipped paused=$paused',
      );
      if (!paused) _notifyListenersAfterIdle();
    }
  }

  /// After focus: resume blur-paused live category fill at low priority.
  void _resumeLiveCategoryPrefetchAfterFocus() {
    if (_liveCategoryPrefetchPaused.isEmpty) return;
    final ids = _liveCategoryPrefetchPaused.toList(growable: false);
    unawaited(
      _bgQueue.enqueue(
        id: 'live-category-prefetch-resume',
        priority: BackgroundPriority.low,
        action: () async {
          if (!_allowIdleBackgroundWork) return;
          // Quiet beat so Accueil settle / simkl-sync win the first frames.
          await Future<void>.delayed(const Duration(seconds: 8));
          if (!_allowIdleBackgroundWork) return;
          for (final id in ids) {
            if (!_allowIdleBackgroundWork) break;
            final source = _sourceById(id);
            if (source == null || source.type != IptvSourceType.xtream) {
              _liveCategoryPrefetchPaused.remove(id);
              continue;
            }
            if (_liveCategoryPrefetching.contains(id)) continue;
            unawaited(prefetchXtreamLiveCategories(source));
          }
        },
      ),
    );
  }

  /// Fetch one category when Catalog needs it and the local bucket is empty.
  Future<void> ensureVodCategoryAvailable(IptvCategory category) async {
    if (category.kind != IptvCategoryKind.vod &&
        category.kind != IptvCategoryKind.series) {
      return;
    }
    await ensureVodDiskHydrated();
    if (!_useVodDb) {
      await ensureVodGroupIndex();
    }
    // SQLite keeps group buckets empty in RAM; page disk before re-fetching.
    if ((await vodShelfSampleAsync(
      categoryName: category.name,
      series: category.kind == IptvCategoryKind.series,
      limit: 1,
    )).isNotEmpty) {
      return;
    }
    // Media-server / custom groups live in [catalog] — no Xtream fetch.
    if (category.id.startsWith('catalog-group:')) {
      return;
    }
    // Do not hammer Xtream while Synchroniser / SyncEngine owns the session —
    // empty probe is usually a transient lock, not a missing category.
    if (_manualSyncFocusHold.isNotEmpty ||
        (DesktopUi.isDesktopOs &&
            SyncScheduler.instance.isCatalogWriterBusy)) {
      return;
    }
    await _fetchVodCategoryRows(category);
  }

  /// Fetch full Xtream movies/series lists without blocking live UI.
  ///
  /// Packed rows go into [VodCatalogDb] (no RAM working-set copy). UI stays
  /// quiet during ingest; Home is notified after movies and again after series
  /// so both rails can fill on first load.
  Future<void> prefetchXtreamOnDemand(IptvSource source) async {
    if (source.type != IptvSourceType.xtream) return;
    if (!_sourceContributesVod(source)) return;
    if (!_vodPrefetching.add(source.id)) return;
    final hwnd = HwndSyncTrace.of(source.id) ??
        HwndSyncTrace.begin('vod-prefetch', sourceId: source.id);
    hwnd.mark('vod-prefetch-enter');
    _markFirstCatalogSyncIfNeeded(source);
    _bumpVodBusy();
    _setSourceSyncStatus(source.id, _uiL10n.sourceSyncFetchingVodCatalog);
    // First paint + live sync must win; VOD can wait briefly.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!_vodPrefetching.contains(source.id)) {
      hwnd.mark('vod-prefetch-aborted', 'after-delay');
      if (!_syncingSourceIds.contains(source.id)) {
        hwnd.end('vod-aborted-delay');
      }
      return;
    }
    await _yieldToBrowse(reason: 'vod-prefetch');
    if (!_vodPrefetching.contains(source.id)) {
      hwnd.mark('vod-prefetch-aborted', 'after-yield');
      if (!_syncingSourceIds.contains(source.id)) {
        hwnd.end('vod-aborted-yield');
      }
      return;
    }

    _uiQuiet = true;
    try {
      await _enableVodDb(reason: 'vod-ingest');
      if (!_useVodDb) {
        hwnd.mark('vod-prefetch-no-db');
        return;
      }

      // Desktop: fat Xtream dumps freeze the Win32 HWND even with isolate SQL
      // writers — run the catalog writer in a SyncEngine child process.
      if (DesktopUi.isDesktopOs) {
        hwnd.mark('vod-prefetch-oop');
        // Keep opportunistic indexes aborted — overlapping GROUP BY with the
        // SyncEngine writer (and later guide ingest) freezes Win32 input.
        _vodGroupIndexAbort = true;
        _postHydrateIndexesPending = true;
        final client = SyncClient();
        _syncClients[source.id] = client;
        late final SyncJobResult dumped;
        try {
          dumped = await client.runXtreamVod(
            profileId: profileId,
            source: source,
            reason: SyncReason.manual,
            onProgress: (event) {
              if (event.type != 'progress') return;
              final committed = event.committed;
              final total = event.total;
              if (committed == null) return;
              final label = event.finalized == true
                  ? '$committed'
                  : (total != null && total > 0
                        ? '$committed / $total'
                        : '$committed');
              _setSourceSyncStatus(
                source.id,
                _uiL10n.sourceSyncSavingVod(label),
              );
              if (event.finalized == true) {
                vodDbRevision++;
                _vodCacheRevision++;
                _vodPoolCache = null;
                _vodSearchHayById = null;
                _vodSearchHayRevision = null;
                _invalidateHomeShelfCaches();
                _notifyPierceQuiet();
                _scheduleTrackerRelinkOnCatalogGrowth(
                  reason: 'vod-progress:${source.id}',
                );
              }
            },
          );
        } finally {
          _syncClients.remove(source.id);
        }
        hwnd.mark(
          'vod-oop-done',
          'skipped=${dumped.skipped} n=${dumped.sqlCount}',
        );
        if (dumped.skipped) {
          return;
        }
        if (dumped.sqlCount == 0) {
          if (_hasVodCacheFor(source)) {
            JavpLog.w(
              'vod',
              'on-demand fetch empty for ${source.id} — keeping cache',
            );
            return;
          }
        }

        final before = catalog.length;
        catalog = [
          for (final m in catalog)
            if (!(m.sourceId == source.id &&
                (m.kind == MediaKind.vod || m.kind == MediaKind.series)))
              m,
        ];
        if (catalog.length != before) {
          await _store.saveCatalog(catalog);
        }

        _vodStreamCache.removeWhere(
          (_, item) =>
              item.sourceId == source.id &&
              (item.kind == MediaKind.vod || item.kind == MediaKind.series),
        );

        final syncedAt = DateTime.now();
        final index = sources.indexWhere((s) => s.id == source.id);
        if (index >= 0) {
          sources = [...sources]
            ..[index] = sources[index].copyWith(
              vodCount: dumped.sqlCount,
              lastVodSyncedAt: syncedAt,
            );
          await _store.saveSources(sources);
        }
        _setSourceSyncStatus(
          source.id,
          _uiL10n.sourceSyncSavingVod('${dumped.sqlCount}'),
        );
        if (dumped.sqlCount == 0) {
          _vodDbSourceIds.remove(source.id);
        } else {
          _vodDbSourceIds.add(source.id);
        }
        _invalidateVodVariantIndex();
        _vodDbCountCache = dumped.sqlCount > 0
            ? dumped.sqlCount
            : _vodDbCountCache;
        unawaited(_vodDb.storeCachedItemCount(_vodDbCountCache));
        vodDbRevision++;
        _vodCacheRevision++;
        _vodPoolCache = null;
        _vodSearchHayById = null;
        _vodSearchHayRevision = null;
        // Indexes wait until guide reload finishes — see
        // [_resumePostHydrateIndexesIfNeeded] / EPG whenComplete.
        _vodGroupIndexAbort = true;
        _postHydrateIndexesPending = true;
        JavpLog.i(
          'vod',
          'defer group-index until after guide n=${dumped.sqlCount}',
        );
        _invalidateHomeShelfCaches();
        _notifyPierceQuiet();
        _scheduleTrackerRelinkOnCatalogGrowth(reason: 'vod-replace:${source.id}');
        return;
      }

      var expectedTotal = 0;
      final publishWatch = Stopwatch()..start();
      var lastPublishedMs = 0;
      var hasPublished = false;
      final session = await _vodDb.beginStreamingReplace(
        sourceId: source.id,
        onProgress: (progress) {
          if (progress.finalized && progress.total == 0 && progress.committed == 0) {
            return;
          }
          final elapsed = publishWatch.elapsedMilliseconds;
          // Status text only — do not invalidate Home shelves / hay on every
          // chunk (that rematerialized Accueil and killed HWND during VOD).
          if (!progress.finalized &&
              hasPublished &&
              elapsed - lastPublishedMs < 1500) {
            return;
          }
          hasPublished = true;
          lastPublishedMs = elapsed;
          _setSourceSyncStatus(
            source.id,
            _uiL10n.sourceSyncSavingVod(
              progress.finalized
                  ? '${progress.committed}'
                  : '${progress.committed} / ${progress.total}',
            ),
          );
          if (progress.finalized) {
            vodDbRevision++;
            _vodCacheRevision++;
            _vodPoolCache = null;
            _vodSearchHayById = null;
            _vodSearchHayRevision = null;
            _invalidateHomeShelfCaches();
            _notifyPierceQuiet();
            _scheduleTrackerRelinkOnCatalogGrowth(
              reason: 'vod-progress:${source.id}',
            );
          }
        },
      );
      XtreamPackedIngest dumped;
      try {
        hwnd.mark('vod-stream-start');
        dumped = await UiStallWatchdog.span(
          'xtream-vod-stream',
          () => _xtream.streamOnDemandCatalog(
            source,
            hwnd: hwnd,
            openSqlSink: () async {
              final sink = await session.ensureSqlWriterSink();
              if (sink != null) hwnd.mark('vod-sql-writer-ready');
              return sink;
            },
            skipIf: (fp, n) async {
              expectedTotal = n;
              session.noteExpectedTotal(n);
              final skip = await session.skipIfFingerprint(fp);
              if (!skip) {
                _setSourceSyncStatus(
                  source.id,
                  _uiL10n.sourceSyncSavingVod('0 / $n'),
                );
              }
              return skip;
            },
            skipIfBody: (bodyFp) async {
              final skip = await session.skipIfBodyFingerprint(bodyFp);
              if (skip) {
                hwnd.mark('vod-skip-body-session');
              }
              return skip;
            },
            rememberBody: session.storeBodyFingerprint,
            onSqlChunk: (chunk) =>
                session.addChunk(chunk, total: expectedTotal),
          ),
        );
        hwnd.mark(
          'vod-stream-done',
          'skipped=${dumped.skipped} n=${dumped.sqlCount}',
        );
      } catch (e) {
        await session.abort();
        hwnd.mark('vod-stream-fail', 'err=$e');
        rethrow;
      }
      if (dumped.skipped) {
        return;
      }
      if (dumped.sqlCount == 0) {
        if (_hasVodCacheFor(source)) {
          JavpLog.w(
            'vod',
            'on-demand fetch empty for ${source.id} — keeping cache',
          );
          await session.abort();
          return;
        }
      }

      final before = catalog.length;
      catalog = [
        for (final m in catalog)
          if (!(m.sourceId == source.id &&
              (m.kind == MediaKind.vod || m.kind == MediaKind.series)))
            m,
      ];
      if (catalog.length != before) {
        await _store.saveCatalog(catalog);
      }

      _vodStreamCache.removeWhere(
        (_, item) =>
            item.sourceId == source.id &&
            (item.kind == MediaKind.vod || item.kind == MediaKind.series),
      );

      final syncedAt = DateTime.now();
      final index = sources.indexWhere((s) => s.id == source.id);
      if (index >= 0) {
        sources = [...sources]
          ..[index] = sources[index].copyWith(
            vodCount: dumped.sqlCount,
            lastVodSyncedAt: syncedAt,
          );
        await _store.saveSources(sources);
      }
      _setSourceSyncStatus(
        source.id,
        _uiL10n.sourceSyncSavingVod('${dumped.sqlCount}'),
      );
      await session.finish(
        fingerprint: dumped.fingerprint,
        total: dumped.sqlCount,
      );
      if (dumped.sqlCount == 0) {
        _vodDbSourceIds.remove(source.id);
      } else {
        _vodDbSourceIds.add(source.id);
      }
      // SQL-only stream: Versions families never crossed the UI isolate.
      // Rebuild from the catalog/cache when Catalog next needs them.
      _invalidateVodVariantIndex();
      // Trust the dump count — another COUNT(*) of 200k rows on the shared
      // sqflite_ffi isolate freezes Synchroniser completion.
      _vodDbCountCache = dumped.sqlCount > 0
          ? dumped.sqlCount
          : _vodDbCountCache;
      unawaited(_vodDb.storeCachedItemCount(_vodDbCountCache));
      vodDbRevision++;
      _vodCacheRevision++;
      _vodPoolCache = null;
      _vodSearchHayById = null;
      _vodSearchHayRevision = null;
      // GROUP BY + shelf rebuild on 200k rows right after Synchroniser was
      // the post-sync HWND lock (stall=vod-group-index). Defer to idle.
      _vodGroupIndexAbort = true;
      _postHydrateIndexesPending = true;
      JavpLog.i(
        'vod',
        'defer group-index after sync replace n=${dumped.sqlCount}',
      );
      _invalidateHomeShelfCaches();
      _notifyPierceQuiet();
      _scheduleTrackerRelinkOnCatalogGrowth(reason: 'vod-replace:${source.id}');
    } catch (e) {
      error = 'VOD cache: $e';
      hwnd.mark('vod-prefetch-error', 'err=$e');
    } finally {
      _uiQuiet = false;
      _vodPrefetching.remove(source.id);
      _syncClients.remove(source.id)?.cancel();
      _flushPendingEpgAfterVod(source.id);
      _clearSourceSyncStatusIfIdle(source.id);
      _bumpVodBusy();
      // Never clear abort here — focus-hold end / EPG whenComplete resume
      // indexes once. Clearing after fingerprint-skip let Catalog rebuild
      // while Synchroniser status was still painting.
      _vodGroupIndexAbort = true;
      _postHydrateIndexesPending = true;
      // Sync shell often already returned; this is usually the real end of
      // the Synchroniser → focus-death timeline.
      if (!_syncingSourceIds.contains(source.id)) {
        hwnd.end('vod-prefetch-complete');
      } else {
        hwnd.mark('vod-prefetch-complete', 'sync-still-running');
      }
      notifyListeners();
    }
  }

  /// Fetch full Stalker movies/series lists without blocking live UI.
  Future<void> prefetchStalkerOnDemand(IptvSource source) async {
    if (source.type != IptvSourceType.stalker) return;
    if (!_vodPrefetching.add(source.id)) return;
    _markFirstCatalogSyncIfNeeded(source);
    _bumpVodBusy();
    _setSourceSyncStatus(source.id, _uiL10n.sourceSyncFetchingVodCatalog);
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!_vodPrefetching.contains(source.id)) return;
    await _yieldToBrowse(reason: 'vod-prefetch');
    if (!_vodPrefetching.contains(source.id)) return;

    _uiQuiet = true;
    try {
      final plan = await _stalker.fetchOnDemandCatalogPlan(source);
      if (plan.vodCount == 0) {
        // Empty-keep (not M3U empty-clear). See [VodIngestPlan].
        if (_hasVodCacheFor(source)) {
          JavpLog.w(
            'vod',
            'Stalker on-demand fetch empty for ${source.id} — keeping cache',
          );
          return;
        }
      }

      final before = catalog.length;
      catalog = [
        for (final m in catalog)
          if (!(m.sourceId == source.id &&
              (m.kind == MediaKind.vod || m.kind == MediaKind.series)))
            m,
      ];
      if (catalog.length != before) {
        await _store.saveCatalog(catalog);
      }

      _vodStreamCache.removeWhere(
        (_, item) =>
            item.sourceId == source.id &&
            (item.kind == MediaKind.vod || item.kind == MediaKind.series),
      );

      final syncedAt = DateTime.now();
      final index = sources.indexWhere((s) => s.id == source.id);
      if (index >= 0) {
        sources = [...sources]
          ..[index] = sources[index].copyWith(
            vodCount: plan.vodCount,
            lastVodSyncedAt: syncedAt,
          );
        await _store.saveSources(sources);
      }
      _setSourceSyncStatus(
        source.id,
        _uiL10n.sourceSyncSavingVod('${plan.vodCount}'),
      );
      await _applyVodPlan(sourceId: source.id, plan: plan, replace: true);
    } catch (e) {
      error = 'VOD cache: $e';
    } finally {
      _uiQuiet = false;
      _vodPrefetching.remove(source.id);
      _flushPendingEpgAfterVod(source.id);
      _clearSourceSyncStatusIfIdle(source.id);
      _bumpVodBusy();
      notifyListeners();
    }
  }

  Future<void> _loadEpgUrls(
    Iterable<String> urlList, {
    String reason = 'unspecified',
  }) async {
    final urls = [
      for (final u in urlList)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    if (urls.isEmpty) return;

    if (!kIsWeb) {
      try {
        await _loadEpgUrlsIntoDb(urls, reason: reason);
        return;
      } catch (e) {
        JavpLog.w('epg', 'db ingest failed; using memory', error: e);
        _useEpgDb = false;
      }
    }

    var any = false;
    var fetchMs = 0;
    var parseMs = 0;
    var reused = 0;
    var parsedFeeds = 0;

    // Multi-URL x-tvg-url lists are common; load each guide and merge.
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
        if (loaded == null) continue;
        final bytes = loaded.bytes;
        if (bytes.isEmpty || bytes.length > kMaxEpgDownloadBytes) continue;

        if (loaded.notModified && _epgFeedIsWarm(epgUrl)) {
          reused++;
          any = true;
          continue;
        }

        _setEpgReloadProgress(
          totalFeeds == 1
              ? _uiL10n.sourceSyncParsingGuide(_formatByteSize(bytes.length))
              : _uiL10n.sourceSyncParsingGuideProgress(
                  '$feedIndex',
                  '$totalFeeds',
                  _formatByteSize(bytes.length),
                ),
        );
        final parse = Stopwatch()..start();
        final parsed = await parseEpgResponseInIsolate(
          bytes: bytes,
          url: epgUrl,
          contentEncoding: loaded.contentEncoding,
        );
        parseMs += parse.elapsedMilliseconds;
        parsedFeeds++;
        if (parsed.programs.isEmpty && parsed.channelNames.isEmpty) continue;
        _epgParsedByUrl[epgUrl] = parsed;
        any = true;
      } catch (_) {
        // Skip failed feeds; others in the list may still succeed.
      }
    }

    if (!any) {
      JavpLog.w(
        'epg',
        'load empty after ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} fetchMs=$fetchMs parseMs=$parseMs '
            'reason=$reason',
      );
      return;
    }

    final urlSet = urls.toSet();
    if (reused == urls.length &&
        parsedFeeds == 0 &&
        epg.isNotEmpty &&
        _epgAppliedUrls.length == urlSet.length &&
        _epgAppliedUrls.containsAll(urlSet)) {
      JavpLog.i(
        'epg',
        'load skip unchanged in ${watch.elapsedMilliseconds}ms '
            'feeds=${urls.length} reused=$reused fetchMs=$fetchMs '
            'reason=$reason',
      );
      return;
    }

    final mergedPrograms = <EpgProgram>[];
    final mergedNames = <String, String>{};
    final concat = Stopwatch()..start();
    var concatI = 0;
    for (final epgUrl in urls) {
      final cached = _epgParsedByUrl[epgUrl];
      if (cached == null) continue;
      for (final program in cached.programs) {
        mergedPrograms.add(program);
        await yieldUiSlice(concat, i: concatI++, label: 'epg-merge-concat');
      }
      mergedNames.addAll(cached.channelNames);
    }
    final merge = Stopwatch()..start();
    final merged = await EpgChannelMatcher.mergeProgrammesYielding(
      mergedPrograms,
    );
    final mergeMs = merge.elapsedMilliseconds;
    epg = merged;
    epgChannelNames = mergedNames;
    _epgAppliedUrls = urlSet;
    _epgLookupIndex = await EpgLookupIndex.buildYielding(
      programs: merged,
      channelNames: mergedNames,
    );
    _epgChannelIndexRef = epg;
    _epgChannelNamesIndexRef = epgChannelNames;
    _bumpEpgRevision();
    JavpLog.i(
      'epg',
      'load in ${watch.elapsedMilliseconds}ms feeds=${urls.length} '
          'programs=${merged.length} channels=${mergedNames.length} '
          'fetchMs=$fetchMs parseMs=$parseMs mergeMs=$mergeMs '
          'reused=$reused parsed=$parsedFeeds reason=$reason',
    );
  }

  Future<({List<int> bytes, String? contentEncoding, bool notModified})?>
  _loadEpgBytes(String epgUrl) async {
    final localPath = LocalSourcePath.tryLocalFilePath(epgUrl);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final bytes = await collectBytesYielding(
        file.openRead(),
        maxBytes: kMaxEpgDownloadBytes,
        tooLargeMessage: 'Guide file is too large',
      );
      if (bytes.isEmpty) return null;
      final cached = _epgHttpCache[epgUrl];
      if (cached != null &&
          _epgFeedIsWarm(epgUrl) &&
          _epgBytesLikelySame(cached.bytes, bytes)) {
        return (
          bytes: cached.bytes,
          contentEncoding: cached.contentEncoding,
          notModified: true,
        );
      }
      _epgHttpCache[epgUrl] = _EpgHttpCacheEntry(
        bytes: bytes,
        contentEncoding: null,
      );
      return (bytes: bytes, contentEncoding: null, notModified: false);
    }
    if (!LocalSourcePath.isRemoteUrl(epgUrl)) return null;

    final cached = _epgHttpCache[epgUrl];
    // Session reuse when the panel didn't send validators (avoids downloading
    // the same guide twice during probe + merge).
    if (cached != null &&
        cached.bytes.isNotEmpty &&
        cached.etag == null &&
        cached.lastModified == null) {
      return (
        bytes: cached.bytes,
        contentEncoding: cached.contentEncoding,
        notModified: true,
      );
    }
    final request = http.Request('GET', Uri.parse(epgUrl));
    request.headers.addAll({
      'Accept': 'application/xml, text/xml, */*',
      'Accept-Encoding': 'gzip',
      if (cached?.etag != null) 'If-None-Match': cached!.etag!,
      if (cached?.lastModified != null)
        'If-Modified-Since': cached!.lastModified!,
    });
    late final http.StreamedResponse streamed;
    try {
      streamed = await _http
          .send(request)
          .timeout(
            _m3uConnectTimeout,
            onTimeout: () => throw TimeoutException('Guide download timed out'),
          );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
    if (streamed.statusCode == 304 && cached != null) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      return (
        bytes: cached.bytes,
        contentEncoding: cached.contentEncoding,
        notModified: true,
      );
    }
    if (streamed.statusCode >= 400) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      return null;
    }
    late final Uint8List bytes;
    try {
      bytes = await collectBytesYielding(
        streamed.stream.timeout(
          _m3uIdleTimeout,
          onTimeout: (sink) {
            sink.addError(TimeoutException('Guide download stalled'));
          },
        ),
        maxBytes: kMaxEpgDownloadBytes,
        tooLargeMessage: 'Guide is too large',
      );
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
    if (bytes.isEmpty) return null;
    final encoding = streamed.headers['content-encoding'];
    // Server ignored validators but body matches session cache → reuse parse.
    if (cached != null &&
        _epgFeedIsWarm(epgUrl) &&
        _epgBytesLikelySame(cached.bytes, bytes)) {
      _epgHttpCache[epgUrl] = _EpgHttpCacheEntry(
        bytes: cached.bytes,
        contentEncoding: cached.contentEncoding ?? encoding,
        etag: streamed.headers['etag'] ?? cached.etag,
        lastModified: streamed.headers['last-modified'] ?? cached.lastModified,
      );
      return (
        bytes: cached.bytes,
        contentEncoding: cached.contentEncoding ?? encoding,
        notModified: true,
      );
    }
    _epgHttpCache[epgUrl] = _EpgHttpCacheEntry(
      bytes: bytes,
      contentEncoding: encoding,
      etag: streamed.headers['etag'],
      lastModified: streamed.headers['last-modified'],
    );
    return (bytes: bytes, contentEncoding: encoding, notModified: false);
  }

  /// Cheap same-body check for large EPG payloads (length + edges).
  bool _epgBytesLikelySame(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    const edge = 64;
    final n = a.length < edge ? a.length : edge;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return false;
    }
    if (a.length > edge) {
      for (var i = 0; i < n; i++) {
        if (a[a.length - 1 - i] != b[b.length - 1 - i]) return false;
      }
    }
    return true;
  }

  /// Probe Xtream auto-discovered guide URLs (epgZip first, then xmltv.php).
  ///
  /// Does **not** download the full guide on the Sync critical path — that
  /// froze Sources on "Synchronisation des catégories live…" while logs had
  /// already moved on. Prefer a known [IptvSource.epgUrl]; otherwise a cheap
  /// reachability probe.
  Future<String?> _resolveXtreamEpgUrl(
    IptvSource source, {
    String? fallback,
  }) async {
    if (source.epgSourceId != null) return source.epgUrl ?? fallback;
    final known = source.epgUrl?.trim();
    if (known != null && known.isNotEmpty) return known;
    final server = source.serverUrl;
    if (server == null || server.isEmpty) return fallback;
    final hwnd = HwndSyncTrace.of(source.id);
    for (final url in _xtream.epgCandidateUrls(source)) {
      hwnd?.mark('epg-probe-start', 'url=${url.length > 60 ? '${url.substring(0, 60)}…' : url}');
      try {
        if (await _epgUrlLooksReachable(url)) {
          hwnd?.mark('epg-probe-ok');
          return url;
        }
      } catch (_) {
        // try next candidate
      }
      await pumpUi(label: 'epg-probe');
    }
    hwnd?.mark('epg-probe-fallback');
    return fallback;
  }

  /// HEAD / tiny GET — Sync must not pull multi‑MB xmltv to pick a URL.
  Future<bool> _epgUrlLooksReachable(String epgUrl) async {
    final localPath = LocalSourcePath.tryLocalFilePath(epgUrl);
    if (localPath != null) {
      return File(localPath).exists();
    }
    if (!LocalSourcePath.isRemoteUrl(epgUrl)) return false;
    try {
      final head = await _http
          .head(Uri.parse(epgUrl))
          .timeout(const Duration(seconds: 4));
      if (head.statusCode > 0 && head.statusCode < 400) return true;
      if (head.statusCode != 405 && head.statusCode != 501) return false;
    } catch (_) {
      // Some panels reject HEAD — fall through to a tiny ranged GET.
    }
    try {
      final request = http.Request('GET', Uri.parse(epgUrl));
      request.headers['Range'] = 'bytes=0-1023';
      final streamed = await _http
          .send(request)
          .timeout(const Duration(seconds: 4));
      final ok = streamed.statusCode > 0 && streamed.statusCode < 400;
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  void _bumpEpgRevision() {
    epgRevision++;
    _cachedOnNow = null;
  }

  bool isGuideLoading(MediaItem channel) =>
      _epgLoading.contains(_guideCacheKey(channel));

  /// Next upcoming programme after [at].
  EpgProgram? nextProgramFor(MediaItem channel, {DateTime? at}) {
    final moment = at ?? DateTime.now();
    final programs = guideFor(channel);
    EpgProgram? next;
    for (final program in programs) {
      if (!program.start.isAfter(moment)) continue;
      if (next == null || program.start.isBefore(next.start)) {
        next = program;
      }
    }
    return next;
  }

  /// Programme that ended most recently before [at].
  EpgProgram? previousProgramFor(MediaItem channel, {DateTime? at}) {
    final moment = at ?? DateTime.now();
    final programs = guideFor(channel);
    EpgProgram? previous;
    for (final program in programs) {
      if (!program.end.isBefore(moment) && !program.isAiringAt(moment)) {
        continue;
      }
      if (program.isAiringAt(moment)) continue;
      if (program.end.isAfter(moment)) continue;
      if (previous == null || program.end.isAfter(previous.end)) {
        previous = program;
      }
    }
    return previous;
  }

  /// Suggested live rows for the player browse pane (same group first, then On now).
  List<({MediaItem channel, EpgProgram program})> playerSuggestionsFor(
    MediaItem channel, {
    int limit = 16,
  }) {
    if (limit <= 0) return const [];
    final currentId = resolveLiveChannel(channel).id;
    final group = channel.group?.trim();
    final onNow = onNowChannels(limit: limit * 3 < 24 ? 24 : limit * 3);
    final sameGroup = <({MediaItem channel, EpgProgram program})>[];
    final other = <({MediaItem channel, EpgProgram program})>[];
    final seen = <String>{currentId};

    for (final row in onNow) {
      if (!seen.add(row.channel.id)) continue;
      final rowGroup = row.channel.group?.trim();
      if (group != null &&
          group.isNotEmpty &&
          rowGroup != null &&
          rowGroup == group) {
        sameGroup.add(row);
      } else {
        other.add(row);
      }
    }

    // Backfill same-category live when On now is thin.
    if (sameGroup.length < limit && group != null && group.isNotEmpty) {
      for (final candidate in liveChannelsInGroup(group).take(40)) {
        if (!seen.add(candidate.id)) continue;
        final program = nowPlayingFor(candidate);
        if (program == null) continue;
        sameGroup.add((channel: candidate, program: program));
        if (sameGroup.length >= limit) break;
      }
    }

    return [
      for (final row in [...sameGroup, ...other].take(limit))
        (
          channel: row.channel.copyWith(title: officialLiveTitle(row.channel)),
          program: row.program,
        ),
    ];
  }

  /// Other live channels for the player browse pane — no EPG required.
  ///
  /// Prefer same-category peers; fall back to favorites, then recents / For you.
  ///
  /// Sync path only: live SQLite mode clears the in-memory catalog and skips
  /// [ensureLiveIndex], so same-category peers need
  /// [playerPeerChannelsForAsync] ([pageLiveChannels]).
  ({List<MediaItem> channels, PlayerPeerSource source, String? category})
  playerPeerChannelsFor(MediaItem channel, {int limit = 24}) {
    if (limit <= 0) {
      return (
        channels: const <MediaItem>[],
        source: PlayerPeerSource.forYou,
        category: null,
      );
    }
    final resolved = resolveLiveChannel(channel);
    final isCurrent = _playerPeerIsCurrent(resolved);

    final group = resolved.group?.trim() ?? channel.group?.trim();
    if (group != null && group.isNotEmpty) {
      final peers = <MediaItem>[];
      final seen = <String>{};
      final List<MediaItem> candidates;
      if (_useLiveDb) {
        // Catalog emptied for SQLite; use [playerPeerChannelsForAsync].
        // Skip [hasLiveIndex]: ensureLiveIndex is a no-op in DB mode and a
        // leftover index would resolve against an empty in-memory catalog.
        candidates = const [];
      } else if (hasLiveIndex) {
        candidates = indexedLivePage(groupName: group, limit: limit + 8);
      } else {
        candidates = collapseLiveQualities(liveChannelsInGroup(group));
      }
      for (final candidate in candidates) {
        if (isCurrent(candidate)) continue;
        if (!seen.add(candidate.id)) continue;
        peers.add(candidate);
        if (peers.length >= limit) break;
      }
      if (peers.isNotEmpty) {
        return (
          channels: peers,
          source: PlayerPeerSource.category,
          category: group,
        );
      }
    }

    final favs = <MediaItem>[];
    final seenFav = <String>{};
    for (final candidate in favoriteChannels) {
      if (isCurrent(candidate)) continue;
      if (!seenFav.add(candidate.id)) continue;
      favs.add(candidate);
      if (favs.length >= limit) break;
    }
    if (favs.isNotEmpty) {
      return (
        channels: favs,
        source: PlayerPeerSource.favorites,
        category: null,
      );
    }

    final recents = <MediaItem>[];
    final seenRecent = <String>{};
    for (final candidate in recentChannels) {
      if (isCurrent(candidate)) continue;
      if (!seenRecent.add(candidate.id)) continue;
      recents.add(candidate);
      if (recents.length >= limit) break;
    }
    return (channels: recents, source: PlayerPeerSource.forYou, category: null);
  }

  /// Like [playerPeerChannelsFor], but loads same-category peers from the live
  /// SQLite catalog when the in-memory index is unavailable.
  Future<
    ({List<MediaItem> channels, PlayerPeerSource source, String? category})
  >
  playerPeerChannelsForAsync(MediaItem channel, {int limit = 24}) async {
    if (limit <= 0) {
      return (
        channels: const <MediaItem>[],
        source: PlayerPeerSource.forYou,
        category: null,
      );
    }
    final resolved = resolveLiveChannel(channel);
    final group = resolved.group?.trim() ?? channel.group?.trim();
    if (_useLiveDb && group != null && group.isNotEmpty) {
      final isCurrent = _playerPeerIsCurrent(resolved);
      final page = await pageLiveChannels(
        groupName: group,
        sourceId: resolved.sourceId,
        limit: limit + 8,
      );
      final peers = <MediaItem>[];
      final seen = <String>{};
      for (final candidate in page) {
        if (isCurrent(candidate)) continue;
        if (!seen.add(candidate.id)) continue;
        peers.add(candidate);
        if (peers.length >= limit) break;
      }
      if (peers.isNotEmpty) {
        return (
          channels: peers,
          source: PlayerPeerSource.category,
          category: group,
        );
      }
    }
    return playerPeerChannelsFor(channel, limit: limit);
  }

  bool Function(MediaItem) _playerPeerIsCurrent(MediaItem resolved) {
    final currentId = resolved.id;
    final currentStream = resolved.streamId;
    final currentSource = resolved.sourceId;
    return (MediaItem c) {
      if (c.id == currentId) return true;
      return currentStream != null &&
          currentStream.isNotEmpty &&
          c.streamId == currentStream &&
          c.sourceId == currentSource;
    };
  }

  bool isProgramReminded(MediaItem channel, EpgProgram program) {
    final key = EpgProgram.reminderKey(
      mediaItemId: channel.id,
      program: program,
    );
    return epgReminders.any((r) => r.id == key);
  }

  String? _mediaServerTimeshiftServerItemId(MediaItem channel, DateTime start) {
    final raw = channel.serverItemId?.trim() ?? '';
    if (raw.isEmpty) return null;
    switch (channel.origin) {
      case MediaOrigin.plex:
        final live = PlexClient.parseLiveServerItemId(raw);
        if (live == null) return null;
        return PlexClient.liveServerItemId(
          dvrId: live.dvrId,
          channelId: live.channelId,
          startAt: start,
        );
      case MediaOrigin.jellyfin:
      case MediaOrigin.emby:
        final live = JellyfinClient.parseLiveServerItemId(raw);
        final channelId =
            live?.channelId ??
            channel.streamId?.trim() ??
            channel.epgChannelId?.trim() ??
            '';
        if (channelId.isEmpty) return null;
        return JellyfinClient.liveServerItemId(channelId, startAt: start);
      default:
        return null;
    }
  }

  /// Catchup clip for offline download with before/after padding.
  MediaItem? liveDvrItemForDownload({
    required MediaItem channel,
    required EpgProgram program,
    Duration padBefore = Duration.zero,
    Duration padAfter = Duration.zero,
  }) {
    return liveDvrItemForDownloadAt(
      channel: channel,
      start: program.start,
      duration: program.duration,
      title: program.title,
      thumbnailUrl: program.imageUrl,
      allowWithoutCatchup: program.hasArchive,
      padBefore: padBefore,
      padAfter: padAfter,
    );
  }

  /// Offline catchup download from a wall-clock window (no EPG required).
  MediaItem? liveDvrItemForDownloadAt({
    required MediaItem channel,
    required DateTime start,
    required Duration duration,
    String? title,
    String? thumbnailUrl,
    bool allowWithoutCatchup = false,
    Duration padBefore = Duration.zero,
    Duration padAfter = Duration.zero,
  }) {
    final archive =
        resolveCatchupChannel(channel) ??
        (allowWithoutCatchup ? channel : null);
    if (archive == null) return null;
    if (!archive.supportsCatchup && !allowWithoutCatchup) return null;
    final source = sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == archive.sourceId,
      orElse: () => null,
    );
    if (source == null ||
        source.type != IptvSourceType.xtream ||
        archive.streamId == null) {
      return null;
    }

    final now = DateTime.now();
    final maxWindow = Duration(days: archive.catchupDays.clamp(1, 14));
    final window = computeDvrDownloadWindow(
      programStart: start,
      programDuration: duration,
      padBefore: padBefore,
      padAfter: padAfter,
      now: now,
      archiveWindow: maxWindow,
    );

    final url = _xtream.catchupUrl(
      source: source,
      streamId: archive.streamId!,
      start: window.start,
      duration: window.duration,
    );

    final label = (title == null || title.trim().isEmpty)
        ? channel.title
        : title.trim();
    final airDate = formatCatchupAirDate(start);
    final padKey =
        '${padBefore.inSeconds}-${padAfter.inSeconds}-${window.start.millisecondsSinceEpoch}';
    return MediaItem(
      id: 'dvr-dl-${archive.streamId}-$padKey',
      title: '$label (Offline)',
      playUrl: url,
      kind: MediaKind.catchup,
      origin: MediaOrigin.iptvXtream,
      subtitle: '${channel.title} · $airDate',
      thumbnailUrl:
          thumbnailUrl ?? channel.thumbnailUrl ?? archive.thumbnailUrl,
      group: channel.group ?? archive.group,
      duration: window.duration,
      channelId: archive.channelId,
      streamId: archive.streamId,
      epgChannelId: channel.epgChannelId ?? archive.epgChannelId,
      catchupDays: archive.catchupDays,
      sourceId: archive.sourceId,
      releaseDate: airDate,
    );
  }

  /// Wall-clock start encoded in `dvr-{streamId}-{ms}` history ids.
  static DateTime? catchupStartOf(MediaItem item) =>
      catchup_air.catchupStartOf(item);

  /// Local wall-clock label for catchup air time (`yyyy-MM-dd HH:mm`).
  static String formatCatchupAirDate(DateTime dt) =>
      catchup_air.formatCatchupAirDate(dt);

  /// Air-date label from [releaseDate] or the timestamp encoded in a catchup id.
  static String? catchupAirDateLabelOf(MediaItem item) =>
      catchup_air.catchupAirDateLabelOf(item);

  /// Whether a catchup/DVR history row is still inside the channel archive window.
  bool isCatchupAvailable(MediaItem item, {DateTime? now}) {
    if (item.kind != MediaKind.catchup) return true;
    final start = catchupStartOf(item);
    if (start == null) return false;
    final days = item.catchupDays > 0 ? item.catchupDays.clamp(1, 14) : 0;
    if (days <= 0) return false;
    final earliest = (now ?? DateTime.now()).subtract(Duration(days: days));
    return !start.isBefore(earliest);
  }

  /// Prefer an EPG-backed catchup row (programme title + art) for Continue watching.
  ///
  /// Stores [EpgProgram.duration] (not the clamped timeshift clip length) so
  /// resume math `start + duration * progress` matches how progress is persisted
  /// as a fraction within the EPG programme.
  MediaItem? catchupHistoryItem({
    required MediaItem channel,
    required DateTime at,
    double progress = 0,
  }) {
    final program = programAt(channel, at: at);
    if (program != null) {
      final item = catchupItem(channel: channel, program: program);
      if (item != null) {
        final art = program.imageUrl;
        return item.copyWith(
          progress: progress.clamp(0.0, 1.0),
          // Keep programme duration even when liveDvrItem clamped the clip.
          duration: program.duration.inMilliseconds > 0
              ? program.duration
              : item.duration,
          thumbnailUrl: (art != null && art.isNotEmpty)
              ? art
              : item.thumbnailUrl,
        );
      }
    }
    return liveDvrItem(
      channel: channel,
      start: at,
      title: '${officialLiveTitle(channel)} (DVR)',
    )?.copyWith(progress: progress.clamp(0.0, 1.0));
  }

  Future<void> importLocalFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.video,
    );
    if (result == null) return;

    final added = result.files.where((f) => f.path != null).map((f) {
      final stripped = displayTitleFromFileName(f.name);
      return MediaItem(
        id: _uuid.v4(),
        title: stripped.isNotEmpty ? stripped : f.name,
        playUrl: f.path!,
        kind: MediaKind.local,
        origin: MediaOrigin.localFile,
        subtitle: 'Local file',
        group: 'Local',
      );
    }).toList();

    localMedia = [...added, ...localMedia];
    await _store.saveLocalMedia(localMedia);
    notifyListeners();
  }

  /// Adds an externally opened URI (Open with / VIEW intent) to local media,
  /// reusing an existing entry when the same [playUrl] is already stored.
  Future<MediaItem> upsertExternalMedia(MediaItem item) async {
    final existing = localMedia.cast<MediaItem?>().firstWhere(
      (m) => m?.playUrl == item.playUrl,
      orElse: () => null,
    );
    if (existing != null) return existing;

    await _clearHistoryTombstone(item.id, playUrl: item.playUrl);
    _localMediaEpoch++;
    _cancelPendingLocalMediaPersist();
    localMedia = [item, ...localMedia];
    await _persistLocalMediaNow(localMedia);
    notifyListeners();
    return item;
  }

  Future<void> addNetworkUrl({
    required String title,
    required String url,
  }) async {
    final trimmed = url.trim();
    if (looksLikeTorrentPlayUrl(trimmed)) {
      await addTorrent(title: title, magnetOrPath: trimmed);
      return;
    }
    // Channel-list M3Us must be imported as sources — opening the playlist URL
    // as a single stream fails in the player. If the path lied (JSON / HLS
    // behind a `.m3u` URL), fall through and sniff.
    if (M3uPlaylistIo.looksLikeChannelListUrl(trimmed)) {
      try {
        await addM3uSource(
          name: title.trim().isEmpty ? 'M3U Source' : title.trim(),
          playlistUrl: trimmed,
        );
        return;
      } on SourceKindMismatchException catch (e) {
        if (e.detected == SourceContentKind.jsonCatalog) {
          await addCustomCatalogSource(
            name: title.trim().isEmpty ? 'Custom catalog' : title.trim(),
            catalogUrl: trimmed,
          );
          return;
        }
        if (e.detected != SourceContentKind.hlsPlaylist) rethrow;
        // HLS behind a `.m3u` path — keep as a direct stream below.
      }
    }

    // Progressive audio / radio hosts — don't wait on a probe (and don't land
    // in Library as a video URL when the mount is unreachable).
    if (looksLikeAudioOnlyUrl(trimmed)) {
      await _addLocalRadioStation(title: title, url: trimmed);
      return;
    }

    // Path suffix missed — sniff the downloaded body for M3U / JSON catalogs,
    // or classify Icecast / progressive audio as a live radio channel.
    final routed = await _tryRouteNetworkUrlByContent(
      title: title,
      url: trimmed,
    );
    if (routed) return;

    final item = MediaItem(
      id: _uuid.v4(),
      title: title.trim().isEmpty ? url : title.trim(),
      playUrl: trimmed,
      kind: MediaKind.network,
      origin: MediaOrigin.url,
      subtitle: 'Direct URL',
      group: 'Network',
    );
    // Intentional re-add cancels a prior Retirer URL tombstone.
    await _clearHistoryTombstone(item.id, playUrl: trimmed);
    _localMediaEpoch++;
    _cancelPendingLocalMediaPersist();
    localMedia = [item, ...localMedia];
    await _persistLocalMediaNow(localMedia);
    notifyListeners();
  }

  /// Peek http(s) / local file content and add as M3U, JSON, or live radio.
  /// Returns true when the URL was handled (caller must not add a direct stream).
  Future<bool> _tryRouteNetworkUrlByContent({
    required String title,
    required String url,
  }) async {
    String? peek;
    Map<String, String>? headers;
    var statusCode = 200;
    Uint8List? bytes;
    final m3uLocal = M3uPlaylistIo.tryLocalFilePath(url);
    final catalogLocal = LocalSourcePath.tryLocalFilePath(url);
    final localPath = m3uLocal ?? catalogLocal;
    if (localPath != null) {
      try {
        final file = File(localPath);
        if (!await file.exists()) return false;
        final raf = await file.open();
        try {
          bytes = await raf.read(4096);
          if (bytes.isEmpty) return false;
          peek = utf8.decode(bytes, allowMalformed: true);
        } finally {
          await raf.close();
        }
      } catch (_) {
        return false;
      }
    } else if (M3uPlaylistIo.isRemotePlaylistUrl(url)) {
      try {
        final probe = await _probeRemoteUrl(url);
        if (probe.bytes.isEmpty) return false;
        bytes = probe.bytes;
        headers = probe.headers;
        statusCode = probe.statusCode;
        peek = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        // Reachability failures fall through to a normal direct-URL add;
        // playback will surface the real error.
        return false;
      }
    } else {
      return false;
    }

    final kind = sniffSourceContent(peek);
    final display = title.trim();
    switch (kind) {
      case SourceContentKind.iptvM3u:
        await addM3uSource(
          name: display.isEmpty ? 'M3U Source' : display,
          playlistUrl: url,
        );
        return true;
      case SourceContentKind.jsonCatalog:
        await addCustomCatalogSource(
          name: display.isEmpty ? 'Custom catalog' : display,
          catalogUrl: url,
        );
        return true;
      case SourceContentKind.hlsPlaylist:
      case SourceContentKind.xmlEpg:
      case SourceContentKind.html:
      case SourceContentKind.xtreamCodes:
        return false;
      case SourceContentKind.unknown:
        break;
    }

    // Icecast / shoutcast / progressive audio mount → Live channel.
    if (headers != null &&
        looksLikeInfiniteAudioStream(
          headers: headers,
          bytes: bytes,
          contentLength: fullContentLength(
            statusCode: statusCode,
            headers: headers,
          ),
        )) {
      final icy = icyNameFromHeaders(headers);
      await _addLocalRadioStation(
        title: display.isNotEmpty ? display : (icy ?? ''),
        url: url,
        subtitle: icy != null && display.isNotEmpty ? icy : 'Radio',
      );
      return true;
    }
    return false;
  }

  /// User-pasted radio mount (`.mp3` / Icecast) stored as a live audio item.
  Future<void> _addLocalRadioStation({
    required String title,
    required String url,
    String subtitle = 'Radio',
  }) async {
    final display = title.trim();
    final item = MediaItem(
      id: _uuid.v4(),
      title: display.isNotEmpty ? display : _titleFromAudioUrl(url),
      playUrl: url,
      kind: MediaKind.live,
      origin: MediaOrigin.url,
      subtitle: subtitle,
      group: 'Radio',
      tags: withAudioOnlyTag(const []),
    );
    await _clearHistoryTombstone(item.id, playUrl: url);
    _localMediaEpoch++;
    _cancelPendingLocalMediaPersist();
    localMedia = [item, ...localMedia];
    await _persistLocalMediaNow(localMedia);
    notifyListeners();
  }

  String _titleFromAudioUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri != null) {
      if (uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        if (last.isNotEmpty) {
          try {
            return Uri.decodeComponent(last);
          } catch (_) {
            return last;
          }
        }
      }
      if (uri.host.isNotEmpty) return uri.host;
    }
    return url.trim();
  }

  /// Bring-your-own magnet URI or local `.torrent` path.
  Future<MediaItem> addTorrent({
    required String magnetOrPath,
    String title = '',
  }) async {
    final raw = magnetOrPath.trim();
    if (raw.isEmpty) {
      throw ArgumentError('Magnet link or .torrent path is required');
    }
    final display = title.trim().isEmpty
        ? (isMagnetUri(raw)
              ? _magnetDisplayName(raw)
              : raw.split(RegExp(r'[\\/]')).last)
        : title.trim();
    final item = MediaItem(
      id: _uuid.v4(),
      title: display,
      playUrl: raw,
      kind: MediaKind.vod,
      origin: MediaOrigin.torrent,
      subtitle: isMagnetUri(raw) ? 'Magnet' : 'Torrent file',
      group: 'Torrents',
    );
    localMedia = [item, ...localMedia];
    await _store.saveLocalMedia(localMedia);
    notifyListeners();
    return item;
  }

  String _magnetDisplayName(String magnet) {
    final dn = RegExp(
      r'[?&]dn=([^&]+)',
      caseSensitive: false,
    ).firstMatch(magnet)?.group(1);
    if (dn != null && dn.isNotEmpty) {
      try {
        return Uri.decodeComponent(dn.replaceAll('+', ' '));
      } catch (_) {
        return dn;
      }
    }
    final hash = RegExp(
      r'btih:([a-zA-Z0-9]+)',
      caseSensitive: false,
    ).firstMatch(magnet)?.group(1);
    if (hash != null && hash.length >= 8) {
      return 'Torrent ${hash.substring(0, 8)}…';
    }
    return 'Torrent';
  }

  Future<void> saveTmdbCredentials(TmdbCredentials credentials) async {
    tmdb = credentials;
    await _store.saveTmdb(credentials);
    _tmdbDiscovery.clearCache();
    _tmdbDiscoveryFingerprint = null;
    _tmdbDiscoveryAttempted = false;
    _tmdbTrendingShelf = const [];
    _tmdbPopularShelf = const [];
    _tmdbDiscoveryRevision++;
    notifyListeners();
  }

  Future<bool> testTmdb() async {
    try {
      return await _tmdb.validate(tmdb);
    } catch (e, st) {
      JavpLog.e('tmdb', 'validate failed', error: e, stack: st);
      return false;
    }
  }

  Future<void> saveSkipSettings(SkipSegmentSettings settings) async {
    skipSettings = settings;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveSkipSettings(settings);
      _noteSyncableChange();
    });
  }

  Future<void> saveTrackLanguageSettings(TrackLanguageSettings settings) async {
    trackLanguageSettings = settings;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveTrackLanguageSettings(settings);
      _noteSyncableChange();
    });
  }

  Future<void> saveMediaServerStreamQuality(
    MediaServerStreamQuality quality,
  ) async {
    if (mediaServerStreamQuality == quality) return;
    mediaServerStreamQuality = quality;
    notifyListeners();
    await persistAfterFrame(() async {
      await _store.saveMediaServerStreamQuality(quality);
      _noteSyncableChange();
    });
  }

  Future<void> saveDownloadSettings(DownloadSettings settings) async {
    downloadSettings = settings;
    _downloads.wifiOnly = DesktopUi.enabled ? false : settings.wifiOnly;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveDownloadSettings(settings);
      _downloads.onNetworkChanged();
      _noteSyncableChange();
    });
  }

  Future<void> saveSoftwareVideoDecoder(bool enabled) async {
    if (softwareVideoDecoder == enabled) return;
    softwareVideoDecoder = enabled;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() => _store.saveSoftwareVideoDecoder(enabled));
  }

  Future<void> saveCastServerTranscodeFallback(bool enabled) async {
    if (castServerTranscodeFallback == enabled) return;
    castServerTranscodeFallback = enabled;
    _notifyListenersAfterIdle();
    await persistAfterFrame(
      () => _store.saveCastServerTranscodeFallback(enabled),
    );
  }

  LiveScrubMode get _defaultLiveScrubMode =>
      LiveScrubModeX.defaultFor(androidTv: TvPlatform.isAndroidTv);

  Future<void> setLiveScrubMode(LiveScrubMode mode) async {
    if (liveScrubMode == mode) return;
    liveScrubMode = mode;
    notifyListeners();
    await persistAfterFrame(() async {
      await _store.saveLiveScrubMode(mode);
      _noteSyncableChange();
    });
  }

  Future<void> setCyclePlaybackSpeeds(List<double> speeds) async {
    final next = normalizeCyclePlaybackSpeeds(speeds);
    if (listEquals(cyclePlaybackSpeeds, next)) return;
    cyclePlaybackSpeeds = next;
    _notifyListenersAfterIdle();
    await persistAfterFrame(() async {
      await _store.saveCyclePlaybackSpeeds(next);
      _noteSyncableChange();
    });
  }

  Future<void> setLiveQualityMode(LiveQualityMode mode) async {
    if (liveQualityMode == mode) return;
    liveQualityMode = mode;
    notifyListeners();
    await persistAfterFrame(() async {
      await _store.saveLiveQualityMode(mode);
      _noteSyncableChange();
    });
  }

  Future<MediaDetails?> loadMediaDetails(
    MediaItem item, {
    bool forceRefresh = false,
  }) {
    return _runUserFacing(
      () => _loadMediaDetailsBody(item, forceRefresh: forceRefresh),
    );
  }

  Future<MediaDetails?> _loadMediaDetailsBody(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    // Search → detail (e.g. a series) freezes: next E/ui-freeze shows these marks
    // plus platform=/sync= from [UiStallWatchdog.desktopContextSuffix].
    UiDebug.mark('loadMediaDetails:start');
    try {
      return await _loadMediaDetailsBodyInner(
        item,
        forceRefresh: forceRefresh,
      );
    } finally {
      UiDebug.mark('loadMediaDetails:end');
    }
  }

  Future<MediaDetails?> _loadMediaDetailsBodyInner(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    var working = item;
    if (item.origin == MediaOrigin.iptvXtream &&
        item.kind == MediaKind.vod &&
        (item.tmdbId == null || item.plot == null || forceRefresh)) {
      working = await enrichVodItem(item);
    }

    if (!forceRefresh) {
      final cached =
          detailsCache[working.detailsId ?? working.id] ??
          detailsCache['tmdb-movie-${working.tmdbId}'] ??
          detailsCache['tmdb-tv-${working.tmdbId}'] ??
          (working.simklId != null
              ? detailsCache['simkl-movie-${working.simklId}'] ??
                    detailsCache['simkl-tv-${working.simklId}'] ??
                    detailsCache['simkl-anime-${working.simklId}']
              : null) ??
          (working.traktId != null
              ? detailsCache['trakt-movie-${working.traktId}'] ??
                    detailsCache['trakt-show-${working.traktId}']
              : null);
      if (cached != null &&
          (working.origin != MediaOrigin.customCatalog ||
              cached.seasons.isNotEmpty ||
              !working.isSeries)) {
        // Episode stills for custom-catalog series go through
        // enrichSeriesEpisodeArtFromTmdb / _resolveSeriesTmdbId — do not
        // bypass this cache just because tmdbId is missing (that re-ran
        // Simkl/title enrich forever for IPTV/VOD with no id).
        return cached;
      }
    }

    MediaDetails? base;

    // JAVP query catalogs: /search shells need /items/{id} for seasons/cast.
    if (working.origin == MediaOrigin.customCatalog) {
      base = await _ensureCustomCatalogDetails(working);
    }

    // Prefer media-server details when available.
    if (base == null &&
        working.serverItemId != null &&
        working.sourceId != null) {
      final source = sources.cast<IptvSource?>().firstWhere(
        (s) => s?.id == working.sourceId,
        orElse: () => null,
      );
      if (source != null && source.type.isMediaServer) {
        try {
          final client = _clientFor(source.type);
          final session = await _sessionFor(source);
          base = await client.details(source, session, working.serverItemId!);
        } catch (_) {}
      }
    }

    // Panel / catalog already-rich row — synthesize details.
    if (base == null &&
        (working.plot != null ||
            working.posterUrl != null ||
            working.tmdbId != null ||
            working.genres.isNotEmpty ||
            working.trailerUrl != null ||
            working.tags.isNotEmpty ||
            working.contentRating != null)) {
      final cachedExtra = detailsCache[working.detailsId ?? working.id];
      base = MediaDetails(
        id:
            working.detailsId ??
            (working.tmdbId != null
                ? 'tmdb-movie-${working.tmdbId}'
                : working.id),
        title: VodGrouping.displayTitle(working),
        mediaItemId: working.id,
        tmdbId: working.tmdbId,
        anilistId: working.anilistId,
        imdbId: working.imdbId,
        tvdbId: working.tvdbId,
        plot: working.plot,
        posterUrl: working.posterUrl ?? working.thumbnailUrl,
        backdropUrl: working.backdropUrl,
        genres: working.genres,
        rating: working.rating,
        year: working.year,
        runtime: working.duration,
        cast: cachedExtra?.cast ?? const [],
        trailerUrl: working.trailerUrl ?? cachedExtra?.trailerUrl,
        trailerKey: cachedExtra?.trailerKey,
        seasons: cachedExtra?.seasons ?? const [],
        seasonNumber: working.seasonNumber,
        episodeNumber: working.episodeNumber,
        tags: working.tags.isNotEmpty
            ? working.tags
            : cachedExtra?.tags ?? const [],
        contentRating: working.contentRating ?? cachedExtra?.contentRating,
        studio: working.studio ?? cachedExtra?.studio,
        originalTitle: working.originalTitle ?? cachedExtra?.originalTitle,
        releaseDate: working.releaseDate ?? cachedExtra?.releaseDate,
        updatedAt: DateTime.now(),
      );
    }

    final enricher = activeEnricher;
    final canEnrich =
        enricher != null &&
        enricher.isAvailable &&
        MetadataMatch.shouldEnrich(
          origin: working.origin,
          enrichMediaServers: metadataSettings.enrichMediaServers,
        );

    if (canEnrich) {
      try {
        final enriched = await enricher.enrich(working);
        if (enriched != null) {
          var merged = base != null
              ? MetadataMatch.overlayPresentation(base, enriched)
              : enriched;
          merged = await _supplementWithTmdb(working, merged);
          await _cacheDetails(merged, notify: false);
          await _applyDetailsToCatalog(working, merged);
          return merged;
        }
      } catch (_) {}
    }

    if (base != null) {
      await _cacheDetails(base, notify: false);
      await _applyDetailsToCatalog(working, base);
      return base;
    }
    return null;
  }

  /// Fill cast / collection / trailer from TMDB when the active enricher left
  /// those holes (SIMKL has director + no collections; Trakt has people).
  Future<MediaDetails> _supplementWithTmdb(
    MediaItem item,
    MediaDetails details,
  ) async {
    if (!tmdb.isConfigured) return details;
    if (metadataSettings.provider == MetadataProviderId.tmdb) return details;
    final tmdbId = details.tmdbId ?? item.tmdbId;
    if (tmdbId == null || tmdbId <= 0) return details;
    final needsCast = MetadataMatch.isThinCast(details.cast);
    final needsCollection = details.collectionId == null;
    final needsTrailer =
        (details.trailerKey == null || details.trailerKey!.isEmpty) &&
        (details.trailerUrl == null || details.trailerUrl!.isEmpty);
    if (!needsCast && !needsCollection && !needsTrailer) return details;
    try {
      final language = TmdbEnricher.languageTag();
      final preferTv =
          item.isSeries ||
          item.seasonNumber != null ||
          details.seasons.isNotEmpty ||
          details.id.contains('-tv-') ||
          details.id.contains('-anime-') ||
          details.id.contains('-show-');
      MediaDetails? extra;
      if (preferTv) {
        extra = await _tmdb.fetchTv(
          tmdb,
          tmdbId,
          mediaItemId: item.id,
          language: language,
        );
        extra ??= await _tmdb.fetchMovie(
          tmdb,
          tmdbId,
          mediaItemId: item.id,
          language: language,
        );
      } else {
        extra = await _tmdb.fetchMovie(
          tmdb,
          tmdbId,
          mediaItemId: item.id,
          language: language,
        );
        extra ??= await _tmdb.fetchTv(
          tmdb,
          tmdbId,
          mediaItemId: item.id,
          language: language,
        );
      }
      if (extra == null) return details;
      return MetadataMatch.fillMissing(details, extra);
    } catch (_) {
      return details;
    }
  }

  Future<void> _cacheDetails(
    MediaDetails details, {
    bool notify = true,
  }) async {
    detailsCache = {...detailsCache, details.id: details};
    if (details.mediaItemId != null) {
      detailsCache = {...detailsCache, details.mediaItemId!: details};
    }
    final simkl = details.simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) {
      detailsCache = {
        ...detailsCache,
        'simkl-movie-$simkl': details,
        'simkl-tv-$simkl': details,
        'simkl-anime-$simkl': details,
      };
    }
    final trakt = details.traktId?.trim();
    if (trakt != null && trakt.isNotEmpty) {
      detailsCache = {
        ...detailsCache,
        'trakt-movie-$trakt': details,
        'trakt-show-$trakt': details,
      };
    }
    // Browsing a shelf enriches many titles in a row; encoding the whole cache
    // per title made opening details feel like a stutter.
    _schedulePersist(_PersistTarget.detailsCache);
    // Callers that immediately [_applyDetailsToCatalog] pass [notify]: false so
    // detail open does not double-rebuild (blink) before apply finishes.
    if (notify) notifyListeners();
  }

  Future<void> _applyDetailsToCatalog(
    MediaItem item,
    MediaDetails details,
  ) async {
    final merged = MetadataMatch.mergeOntoItem(item, details);
    var touched = false;
    var identityChanged = false;
    final catalogIndex = catalog.indexWhere((m) => m.id == item.id);
    if (catalogIndex >= 0) {
      final prev = catalog[catalogIndex];
      identityChanged =
          identityChanged ||
          merged.tmdbId != prev.tmdbId ||
          merged.imdbId != prev.imdbId;
      final next = List<MediaItem>.of(catalog);
      next[catalogIndex] = merged;
      catalog = next;
      _schedulePersist(_PersistTarget.catalog);
      touched = true;
    }
    final localIndex = localMedia.indexWhere((m) => m.id == item.id);
    if (localIndex >= 0) {
      final next = List<MediaItem>.of(localMedia);
      next[localIndex] = merged;
      localMedia = next;
      _schedulePersist(_PersistTarget.localMedia);
      touched = true;
    }
    final watchIndex = watchlist.indexWhere((m) => m.id == item.id);
    if (watchIndex >= 0) {
      final next = List<MediaItem>.of(watchlist);
      next[watchIndex] = merged;
      watchlist = next;
      await _store.saveWatchlist(watchlist);
      touched = true;
    }
    final prevVod = _vodStreamCache[item.id];
    if (prevVod != null) {
      identityChanged =
          identityChanged ||
          merged.tmdbId != prevVod.tmdbId ||
          merged.imdbId != prevVod.imdbId;
      UiDebug.mark('applyDetails:replaceVod');
      _replaceVodCacheItem(merged);
      if (_useVodDb) {
        unawaited(_vodDb.upsertItems([merged]));
      }
      touched = true;
    }
    if (identityChanged) _invalidateVodVariantIndex();
    // Always notify: paired [_cacheDetails](..., notify: false) relies on this
    // single rebuild so detail enrich does not blink twice.
    if (touched) notifyListeners();
  }

  /// Drop the live Versions family map so the next Catalog/Search pass regroups
  /// after a TMDB/IMDb id is attached to a cached row.
  ///
  /// Keeps [_vodVariantStaleIndex] so title/search/home do not collapse to a
  /// single edition while the isolate rebuild runs on large IPTV caches.
  void _invalidateVodVariantIndex() {
    if (_vodVariantIndex != null) {
      _vodVariantStaleIndex = _vodVariantIndex;
      _vodVariantStaleCanonical = _vodGroupCanonical;
    }
    _vodVariantIndex = null;
    _vodGroupCanonical = null;
    _vodVariantBuiltStamp = -1;
    _vodVariantEpoch++;
    _vodPoolCache = null;
    _catalogIdentityCache = null;
    _catalogIdentityStamp = -1;
    _invalidateHomeShelfCaches();
    // Idle: start a rebuild now. Busy: in-flight finally sees the new stamp
    // and reschedules (see [_finishVodVariantIndexBuild]).
    if (!_vodVariantIndexBuilding) {
      _scheduleVodVariantIndexBuild();
    }
  }

  Future<List<MetadataSearchHit>> searchMetadata(String query) {
    final enricher = activeEnricher;
    if (enricher == null || !enricher.isAvailable)
      return Future.value(const []);
    return enricher.search(query);
  }

  /// Backward-compatible TMDB search used by older call sites.
  Future<List<TmdbSearchHit>> searchTmdb(String query) {
    return _tmdb.search(
      tmdb,
      query: query,
      language: TmdbEnricher.languageTag(),
    );
  }

  Future<void> applyMetadataMatch(
    MediaItem item, {
    required String externalId,
    required String mediaType,
  }) async {
    final enricher = activeEnricher;
    if (enricher == null || !enricher.isAvailable) return;
    final details = await enricher.enrich(
      item,
      forceExternalId: externalId,
      forceType: mediaType,
    );
    if (details == null) return;
    final merged = await _supplementWithTmdb(item, details);
    await _cacheDetails(merged, notify: false);
    await _applyDetailsToCatalog(item, merged);
  }

  Future<void> applyTmdbMatch(
    MediaItem item, {
    required int tmdbId,
    required String mediaType,
  }) async {
    await applyMetadataMatch(item, externalId: '$tmdbId', mediaType: mediaType);
  }

  Future<void> ensureTmdbCollection(
    int collectionId,
    String name,
    String mediaItemId,
  ) async {
    final existing = collections.cast<LibraryCollection?>().firstWhere(
      (c) => c?.tmdbCollectionId == collectionId,
      orElse: () => null,
    );

    TmdbCollectionInfo? remote;
    if (tmdb.isConfigured) {
      try {
        remote = await _tmdb.fetchCollection(
          tmdb,
          collectionId,
          language: TmdbEnricher.languageTag(),
        );
      } catch (_) {}
    }

    final matchedIds = await _localIdsForTmdbCollectionParts(
      remote?.parts ?? const [],
    );
    final idSet = <String>{
      mediaItemId,
      if (existing != null) ...existing.mediaItemIds,
      ...matchedIds,
    };

    final displayName = (remote != null && remote.name.trim().isNotEmpty)
        ? remote.name
        : name;
    if (existing != null) {
      final updated = existing.copyWith(
        name: displayName,
        overview: remote?.overview ?? existing.overview,
        posterUrl: remote?.posterUrl ?? existing.posterUrl,
        backdropUrl: remote?.backdropUrl ?? existing.backdropUrl,
        mediaItemIds: idSet.toList(),
      );
      final unchanged =
          updated.name == existing.name &&
          updated.overview == existing.overview &&
          updated.posterUrl == existing.posterUrl &&
          updated.backdropUrl == existing.backdropUrl &&
          updated.mediaItemIds.length == existing.mediaItemIds.length &&
          updated.mediaItemIds.toSet().containsAll(existing.mediaItemIds);
      if (unchanged) return;
      collections = [
        for (final c in collections)
          if (c.id == existing.id) updated else c,
      ];
      await _store.saveCollections(collections);
      notifyListeners();
      return;
    }

    collections = [
      LibraryCollection(
        id: _uuid.v4(),
        name: displayName,
        overview: remote?.overview,
        posterUrl: remote?.posterUrl,
        backdropUrl: remote?.backdropUrl,
        tmdbCollectionId: collectionId,
        mediaItemIds: idSet.toList(),
        createdAt: DateTime.now(),
      ),
      ...collections,
    ];
    await _store.saveCollections(collections);
    notifyListeners();
  }

  /// Match TMDB collection parts to on-device VOD / catalog rows.
  Future<List<String>> _localIdsForTmdbCollectionParts(
    List<TmdbCollectionPart> parts,
  ) async {
    if (parts.isEmpty) return const [];
    final tmdbIds = [for (final p in parts) p.tmdbId];
    final byTmdb = <int, MediaItem>{};

    if (_useVodDb) {
      try {
        final rows = await _vodDb.itemsByTmdbIds(tmdbIds, series: false);
        for (final item in rows) {
          final id = item.tmdbId;
          if (id == null || id <= 0) continue;
          byTmdb.putIfAbsent(id, () => item);
        }
      } catch (_) {}
    }

    void consider(MediaItem item) {
      final id = item.tmdbId;
      if (id == null || id <= 0) return;
      if (item.isLive || item.isEpisode || item.isSeries) return;
      if (!isSourceVodContentVisible(item.sourceId)) return;
      byTmdb.putIfAbsent(id, () => item);
    }

    for (final item in catalog) {
      consider(item);
    }
    for (final item in localMedia) {
      consider(item);
    }
    for (final item in _vodStreamCache.values) {
      consider(item);
    }

    final missing = [
      for (final p in parts)
        if (!byTmdb.containsKey(p.tmdbId)) p,
    ];
    if (missing.isNotEmpty) {
      try {
        final pool = <MediaItem>[
          ...catalog.where(
            (m) =>
                !m.isLive &&
                !m.isEpisode &&
                isSourceVodContentVisible(m.sourceId),
          ),
          ...localMedia.where(
            (m) =>
                !m.isLive &&
                !m.isEpisode &&
                isSourceVodContentVisible(m.sourceId),
          ),
          ..._vodStreamCache.values.where(
            (m) =>
                !m.isLive &&
                !m.isEpisode &&
                isSourceVodContentVisible(m.sourceId),
          ),
        ];
        final index = await SimklMatchIndex.buildAsync(pool);
        for (final part in missing) {
          final hit = index.match(
            SimklIds(tmdb: part.tmdbId),
            title: part.title,
            year: part.year,
          );
          if (hit == null || hit.isLive || hit.isEpisode || hit.isSeries) {
            continue;
          }
          byTmdb.putIfAbsent(part.tmdbId, () => hit);
        }
      } catch (_) {}
    }

    final out = <String>[];
    final seen = <String>{};
    for (final part in parts) {
      final item = byTmdb[part.tmdbId];
      if (item == null) continue;
      if (!seen.add(item.id)) continue;
      out.add(item.id);
    }
    return out;
  }

  /// Search custom catalogs for [query]: remote `/search` when advertised,
  /// otherwise title-match against the on-device catalog / VOD cache for that
  /// source (simple dumps, v2 without `search`, catalog-bridge bridges).
  ///
  /// [persist]/[notify]/[touchVod] default on for interactive Search. Tracker
  /// shell linking passes them false and flushes once after the batch so each
  /// Custom catalog hit does not rewrite the whole catalog or rematerialize Home.
  ///
  /// When [touchVod] is true, hits are upserted via [_replaceVodCacheItem] —
  /// never [_touchVodCache], which would drop the SQLite group-index and force
  /// a multi-second rebuild (Search → detail blink/freeze).
  ///
  /// [invalidateVariants] defaults true for non-Search callers. Interactive
  /// Search turns it off — [_invalidateVodVariantIndex] also wipes Home shelf
  /// caches and schedules a full isolate rebuild (typing lag / notify storms).
  Future<List<MediaItem>> searchRemoteCatalogs(
    String query, {
    String? sourceId,
    int limit = 40,
    bool persist = true,
    bool notify = true,
    bool touchVod = true,
    bool invalidateVariants = true,
    bool Function()? isCurrent,
    void Function(List<MediaItem> soFar)? onPartial,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final targets = sources.where((s) {
      if (!s.enabled) return false;
      if (s.type != IptvSourceType.custom) return false;
      if (sourceId != null && s.id != sourceId) return false;
      final url = s.playlistUrl;
      if (url == null || url.isEmpty) return false;
      // Asset / local-file dumps are already covered by [searchLocalLibrary].
      if (isAssetCatalogUrl(url) ||
          LocalSourcePath.tryLocalFilePath(url) != null) {
        return false;
      }
      return true;
    }).toList();
    if (targets.isEmpty) return const [];

    final out = <MediaItem>[];
    final seen = <String>{};
    var catalogTouched = false;
    final stillCurrent = isCurrent ?? () => true;

    void addHits(Iterable<MediaItem> items) {
      for (final item in items) {
        if (!seen.add(item.id)) continue;
        out.add(item);
      }
    }

    void publishPartial() {
      if (!stillCurrent()) return;
      final cb = onPartial;
      if (cb == null || out.isEmpty) return;
      cb(List<MediaItem>.unmodifiable(out));
    }

    for (final source in targets) {
      if (!stillCurrent()) break;
      var usedRemote = false;
      if (source.supportsCatalogSearch) {
        try {
          await _applyCatalogClientProfile();
          if (!stillCurrent()) break;
          final page = await _customCatalog
              .search(
                baseUrl: source.playlistUrl!,
                sourceId: source.id,
                query: q,
                limit: limit,
                locale: _catalogLocaleParam,
                headers: _customCatalogHeaders(source),
              )
              .timeout(const Duration(seconds: 8));
          if (!stillCurrent()) break;
          usedRemote = true;
          if (page.details.isNotEmpty) {
            detailsCache = {...detailsCache, ...page.details};
            _schedulePersist(_PersistTarget.detailsCache);
          }
          addHits(page.items);
          if (page.items.isNotEmpty) {
            final ids = page.items.map((e) => e.id).toSet();
            catalog = [
              ...catalog.where(
                (m) => m.sourceId != source.id || !ids.contains(m.id),
              ),
              ...page.items,
            ];
            catalogTouched = true;
            var vodUpserted = false;
            for (final item in page.items) {
              if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
                continue;
              }
              if (touchVod) {
                // Grow/replace one bucket — do not wipe group-index / Home rails.
                _replaceVodCacheItem(item);
                vodUpserted = true;
              } else {
                _vodStreamCache[item.id] = item;
              }
            }
            // Versions chips: Search uses [mergeVodSearchFamilyOverlay]. Full
            // isolate rebuild + home shelf wipe freezes typing mid-keystroke.
            if (vodUpserted && invalidateVariants) {
              _invalidateVodVariantIndex();
            }
            publishPartial();
          }
        } on CatalogSearchUnsupportedException {
          _warnCatalogSearch404Once(source);
          // Fall through to local title match.
        } catch (e) {
          JavpLog.w(
            'catalog',
            'Custom catalog search failed (${source.name})',
            error: e,
          );
        }
      }

      if (!usedRemote) {
        final before = out.length;
        addHits(
          _searchCachedCustomCatalogTitles(
            sourceId: source.id,
            query: q,
            limit: limit,
          ),
        );
        if (out.length > before) publishPartial();
      }
    }
    if (!stillCurrent()) return out;
    if (catalogTouched && persist) {
      await _store.saveCatalog(catalog);
    } else if (catalogTouched && stillCurrent()) {
      // Only schedule encode for the winning keystroke — superseded searches
      // used to pile catalog: save lines mid-typing (40ms×N + FTS wait).
      _schedulePersist(_PersistTarget.catalog);
    }
    if (catalogTouched && notify) {
      notifyListeners();
    }
    return out;
  }

  void _warnCatalogSearch404Once(IptvSource source) {
    if (!_catalogSearch404Warned.add(source.id)) return;
    JavpLog.w(
      'catalog',
      'Custom catalog has no /search (${source.name}); using local titles',
    );
  }

  /// Title-token match against persisted custom-catalog rows for [sourceId].
  List<MediaItem> _searchCachedCustomCatalogTitles({
    required String sourceId,
    required String query,
    int limit = 40,
  }) {
    final tokens = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty || limit <= 0) return const [];

    final out = <MediaItem>[];
    final seen = <String>{};

    void consider(MediaItem m) {
      if (out.length >= limit) return;
      if (m.sourceId != sourceId) return;
      if (m.isLive) return;
      if (!seen.add(m.id)) return;
      final hay = VodSearchIndex.hayFor(m);
      if (!VodSearchIndex.matchesTokens(hay, tokens)) return;
      out.add(m);
    }

    for (final m in catalog) {
      consider(m);
      if (out.length >= limit) return out;
    }
    for (final m in _vodStreamCache.values) {
      consider(m);
      if (out.length >= limit) return out;
    }
    return out;
  }

  /// Remote search for JAVP query APIs + Jellyfin/Emby/Plex.
  ///
  /// Xtream has no server-side title search — if the VOD cache is empty we
  /// kick an idle warm so later queries can hit locally.
  Future<List<MediaItem>> searchRemoteSources(
    String query, {
    String? sourceId,
    int limit = 40,
    void Function(List<MediaItem> soFar)? onPartial,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final gen = ++_remoteSearchGen;
    bool stillCurrent() => gen == _remoteSearchGen;
    return _runUserFacing(
      () => _searchRemoteSourcesBody(
        q,
        sourceId: sourceId,
        limit: limit,
        onPartial: onPartial,
        isCurrent: stillCurrent,
      ),
    );
  }

  Future<List<MediaItem>> _searchRemoteSourcesBody(
    String q, {
    String? sourceId,
    int limit = 40,
    void Function(List<MediaItem> soFar)? onPartial,
    bool Function()? isCurrent,
  }) async {
    final watch = Stopwatch()..start();
    final out = <MediaItem>[];
    final seen = <String>{};
    var mediaServerHits = 0;
    var mediaServersQueried = 0;
    final stillCurrent = isCurrent ?? () => true;

    void addAll(Iterable<MediaItem> items) {
      for (final item in items) {
        if (!seen.add(item.id)) continue;
        out.add(item);
      }
    }

    void publishPartial() {
      if (!stillCurrent()) return;
      final cb = onPartial;
      if (cb == null || out.isEmpty) return;
      cb(List<MediaItem>.unmodifiable(out));
    }

    final beforeCatalog = out.length;
    addAll(
      await searchRemoteCatalogs(
        q,
        sourceId: sourceId,
        limit: limit,
        // Search already paints via [onPartial] setState — avoid notify storms
        // + await saveCatalog on every superseded keystroke (4× overlapping
        // remotes in logs). Family overlay covers Versions chips.
        persist: false,
        notify: false,
        invalidateVariants: false,
        isCurrent: stillCurrent,
        onPartial: onPartial,
      ),
    );
    if (!stillCurrent()) return out;
    final catalogHits = out.length - beforeCatalog;
    if (catalogHits > 0) publishPartial();

    for (final source in sources) {
      if (!stillCurrent()) break;
      if (!source.enabled) continue;
      if (sourceId != null && source.id != sourceId) continue;
      if (!source.type.isMediaServer) continue;
      mediaServersQueried++;
      try {
        final page = await browseMediaServer(
          sourceId: source.id,
          search: q,
          limit: limit,
        ).timeout(const Duration(seconds: 8));
        if (!stillCurrent()) break;
        final before = out.length;
        addAll(page.items);
        mediaServerHits += out.length - before;
        if (page.items.isNotEmpty) {
          final ids = page.items.map((e) => e.id).toSet();
          catalog = [
            ...catalog.where(
              (m) => m.sourceId != source.id || !ids.contains(m.id),
            ),
            ...page.items,
          ];
          publishPartial();
        }
      } catch (_) {}
    }

    // Xtream has no remote title search — do not kick a full VOD download
    // from Search (that freezes the UI). Cache fills via idle/manual sync.
    if (stillCurrent() && out.isNotEmpty) {
      _schedulePersist(_PersistTarget.catalog);
      // One coalesced notify — Search UI already updated via onPartial.
      _notifyListenersAfterIdle();
    }
    final ms = watch.elapsedMilliseconds;
    // No raw query text — length + counts only.
    final summary =
        'remote in ${ms}ms qLen=${q.length} n=${out.length} '
        'catalog=$catalogHits mediaServer=$mediaServerHits '
        'servers=$mediaServersQueried'
        '${sourceId == null ? '' : ' source=1'}'
        '${stillCurrent() ? '' : ' superseded=1'}';
    if (ms >= 1500) {
      JavpLog.w('search', summary);
    } else {
      JavpLog.slow('search', summary, ms);
    }
    return out;
  }

  /// True when Search should call the network (JAVP APIs / media servers).
  bool get hasRemoteSearchTargets {
    for (final s in sources) {
      if (!s.enabled) continue;
      if (s.type == IptvSourceType.custom &&
          s.playlistUrl != null &&
          s.playlistUrl!.isNotEmpty) {
        return true;
      }
      if (s.type.isMediaServer) return true;
    }
    return false;
  }

  bool isVodPrefetching({String? sourceId}) {
    if (sourceId != null) return _vodPrefetching.contains(sourceId);
    return _vodPrefetching.isNotEmpty;
  }

  Future<LibraryPlaylist> createPlaylist(String name) async {
    final playlist = LibraryPlaylist(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Playlist' : name.trim(),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    playlists = [playlist, ...playlists];
    await _store.savePlaylists(playlists);
    notifyListeners();
    return playlist;
  }

  Future<void> addToPlaylist(String playlistId, String mediaItemId) async {
    playlists = [
      for (final p in playlists)
        if (p.id == playlistId)
          p.copyWith(
            mediaItemIds: p.mediaItemIds.contains(mediaItemId)
                ? p.mediaItemIds
                : [...p.mediaItemIds, mediaItemId],
            updatedAt: DateTime.now(),
          )
        else
          p,
    ];
    await _store.savePlaylists(playlists);
    notifyListeners();
  }

  Future<void> removePlaylist(String playlistId) async {
    playlists = playlists.where((p) => p.id != playlistId).toList();
    await _store.savePlaylists(playlists);
    notifyListeners();
  }

  Future<MediaSegmentBundle> segmentsFor(MediaItem item) async {
    // Catalog-embedded segments win immediately.
    if (item.hasCatalogSegments) {
      return MediaSegmentBundle(
        key: 'catalog:${item.id}',
        segments: item.segments,
        fetchedAt: item.updatedAt ?? DateTime.now(),
      );
    }

    final catalogKey = 'catalog:${item.id}';
    if (segmentCache.containsKey(catalogKey)) {
      return segmentCache[catalogKey]!;
    }

    final key = SegmentResolver.keyForItem(item);
    if (key != null && segmentCache.containsKey(key)) {
      final cached = segmentCache[key]!;
      final age = DateTime.now().difference(cached.fetchedAt ?? DateTime(2000));
      if (age < const Duration(days: 7)) return cached;
    }

    // Prefer server chapters when available.
    if (item.serverItemId != null && item.sourceId != null) {
      final source = sources.cast<IptvSource?>().firstWhere(
        (s) => s?.id == item.sourceId,
        orElse: () => null,
      );
      if (source != null &&
          (source.type == IptvSourceType.jellyfin ||
              source.type == IptvSourceType.emby)) {
        // MediaSegments is Jellyfin/Emby-only (Plex uses a different API).
        try {
          final client = _clientFor(source.type);
          final session = await _sessionFor(source);
          final segs = await client.mediaSegments(
            source,
            session,
            item.serverItemId!,
          );
          if (segs.isNotEmpty) {
            final bundle = MediaSegmentBundle(
              key: key ?? 'server-${item.serverItemId}',
              segments: segs,
              fetchedAt: DateTime.now(),
            );
            segmentCache = {...segmentCache, bundle.key: bundle};
            _schedulePersist(_PersistTarget.segmentCache);
            return bundle;
          }
        } catch (_) {}
      }
    }

    final bundle = await _segments.resolve(item);
    if (bundle.key != 'unknown') {
      segmentCache = {...segmentCache, bundle.key: bundle};
      _schedulePersist(_PersistTarget.segmentCache);
    }
    return bundle;
  }

  DownloadTask? downloadTaskFor(MediaItem item) {
    final byId = _downloads.taskForItemId(item.id);
    if (byId != null) return byId;
    return _downloads.bestTaskFor(item);
  }

  /// Local file path when a completed offline download matches [item].
  String? offlinePlayPathFor(MediaItem item) =>
      _downloads.offlinePlayPathFor(item);

  DownloadStatus? downloadStatusFor(MediaItem item) =>
      downloadTaskFor(item)?.status;

  DownloadStatus? downloadStatusForId(String id) =>
      _downloads.taskForItemId(id)?.status;

  String seriesKeyFor(MediaItem series) =>
      series.streamId ?? series.seriesId ?? series.id;

  MediaItem? seriesForEpisode(MediaItem episode) {
    final sid = episode.seriesId?.trim();
    if (sid == null || sid.isEmpty) return null;
    MediaItem? match(Iterable<MediaItem> items) {
      return items.cast<MediaItem?>().firstWhere(
        (m) =>
            m != null &&
            m.isSeries &&
            (m.streamId == sid ||
                m.id == sid ||
                m.seriesId == sid ||
                seriesKeyFor(m) == sid),
        orElse: () => null,
      );
    }

    return match(catalog) ??
        match(_vodStreamCache.values) ??
        match(watchlist) ??
        match(history);
  }

  /// Locate [current] in [info] by id/streamId, then by S/E numbers.
  int _episodeIndexInSeries(SeriesInfo info, MediaItem current) {
    final flat = flattenedEpisodes(info);
    final streamId = current.streamId?.trim();
    final byId = flat.indexWhere(
      (e) =>
          e.id == current.id ||
          (streamId != null && streamId.isNotEmpty && e.id == streamId),
    );
    if (byId >= 0) return byId;
    final season = current.seasonNumber;
    final epNum = current.episodeNumber;
    if (season == null || epNum == null) return -1;
    return flat.indexWhere(
      (e) => e.seasonNumber == season && e.episodeNum == epNum,
    );
  }

  /// Ensure season rows exist for next/prev resolution (custom-catalog stubs).
  Future<SeriesInfo> _seriesInfoForAdjacentEpisodes(
    MediaItem series,
    MediaItem current,
  ) async {
    var info = await loadSeriesInfo(series);
    if (flattenedEpisodes(info).isNotEmpty) {
      // Hydrate the current season when the shell only has stubs / a partial list.
      final season = current.seasonNumber;
      if (season != null && series.origin == MediaOrigin.customCatalog) {
        info =
            await ensureSeasonEpisodes(series: series, seasonNumber: season) ??
            info;
      }
      return info;
    }
    final season = current.seasonNumber ?? 1;
    return await ensureSeasonEpisodes(series: series, seasonNumber: season) ??
        info;
  }

  Future<MediaItem?> _playableAdjacentEpisode({
    required MediaItem series,
    required SeriesEpisode episode,
  }) async {
    final live = resolvedEpisodeFor(series: series, episode: episode);
    final offline = offlineItemForEpisode(series: series, episode: live);
    if (offline != null) return offline;
    // Unresolved catalog stubs: enable next/prev immediately and resolve in
    // the background so a slow/failed fill cannot gray out the skip buttons.
    if (series.origin == MediaOrigin.customCatalog &&
        live.needsPlaybackResolve) {
      unawaited(ensureEpisodePlayable(series: series, episode: live));
      return episodeMediaItem(series: series, episode: live);
    }
    return await ensureEpisodePlayable(series: series, episode: episode) ??
        episodeMediaItem(series: series, episode: episode);
  }

  /// Next playable episode after [current] (same series), or null at the end.
  Future<MediaItem?> nextEpisodeItem(MediaItem current) async {
    if (!current.isEpisode) return null;
    final series = seriesForEpisode(current) ?? seriesShellForEpisode(current);
    if (series == null) return null;
    try {
      var info = await _seriesInfoForAdjacentEpisodes(series, current);
      var flat = flattenedEpisodes(info);
      if (flat.isEmpty) return null;
      var idx = _episodeIndexInSeries(info, current);
      if (idx < 0) {
        final season = current.seasonNumber;
        final epNum = current.episodeNumber;
        if (season == null || epNum == null) return null;
        var nextEps = episodesAfter(
          info: info,
          seasonNumber: season,
          episodeNum: epNum,
          count: 1,
        );
        if (nextEps.isEmpty) {
          info =
              await ensureSeasonEpisodes(
                series: series,
                seasonNumber: season + 1,
              ) ??
              info;
          nextEps = episodesAfter(
            info: info,
            seasonNumber: season,
            episodeNum: epNum,
            count: 1,
          );
        }
        if (nextEps.isEmpty) return null;
        return _playableAdjacentEpisode(series: series, episode: nextEps.first);
      }
      if (idx + 1 >= flat.length) {
        final season = current.seasonNumber ?? flat[idx].seasonNumber;
        info =
            await ensureSeasonEpisodes(
              series: series,
              seasonNumber: season + 1,
            ) ??
            info;
        flat = flattenedEpisodes(info);
        idx = _episodeIndexInSeries(info, current);
        if (idx < 0 || idx + 1 >= flat.length) return null;
      }
      return _playableAdjacentEpisode(series: series, episode: flat[idx + 1]);
    } catch (e) {
      JavpLog.w('play', 'next-episode failed item=${current.id}', error: e);
      return null;
    }
  }

  /// Previous playable episode before [current] (same series), or null at start.
  Future<MediaItem?> previousEpisodeItem(MediaItem current) async {
    if (!current.isEpisode) return null;
    final series = seriesForEpisode(current) ?? seriesShellForEpisode(current);
    if (series == null) return null;
    try {
      final info = await _seriesInfoForAdjacentEpisodes(series, current);
      final flat = flattenedEpisodes(info);
      if (flat.isEmpty) return null;
      var idx = _episodeIndexInSeries(info, current);
      if (idx < 0) {
        final season = current.seasonNumber;
        final epNum = current.episodeNumber;
        if (season == null || epNum == null) return null;
        final prevEps = episodesBefore(
          info: info,
          seasonNumber: season,
          episodeNum: epNum,
          count: 1,
        );
        if (prevEps.isEmpty) return null;
        return _playableAdjacentEpisode(series: series, episode: prevEps.first);
      }
      if (idx <= 0) return null;
      return _playableAdjacentEpisode(series: series, episode: flat[idx - 1]);
    } catch (_) {
      return null;
    }
  }

  /// Rebuild a history / Continue watching episode like series-detail play.
  ///
  /// No-ops when S/E + series + playable URL are already present (avoids an
  /// Xtream network round-trip on every resume). Preserves resume progress.
  Future<MediaItem> normalizeEpisodeForPlayback(MediaItem episode) async {
    if (!episode.isEpisode) return episode;
    final hasCoords =
        episode.seasonNumber != null && episode.episodeNumber != null;
    final sid = episode.seriesId?.trim();
    final hasSeries = sid != null && sid.isNotEmpty;
    final playable =
        episode.playUrl.trim().isNotEmpty ||
        (episode.serverItemId != null &&
            episode.serverItemId!.trim().isNotEmpty);
    if (hasCoords && hasSeries && playable) return episode;

    final series = seriesForEpisode(episode) ?? seriesShellForEpisode(episode);
    if (series == null) return episode;
    try {
      final info = await _seriesInfoForAdjacentEpisodes(series, episode);
      final flat = flattenedEpisodes(info);
      final idx = _episodeIndexInSeries(info, episode);
      if (idx < 0 || idx >= flat.length) return episode;
      final ready = await ensureEpisodePlayable(
        series: series,
        episode: flat[idx],
      );
      if (ready == null) return episode;
      return ready.copyWith(
        progress: episode.progress,
        lastWatchedAt: episode.lastWatchedAt,
        duration: episode.duration ?? ready.duration,
      );
    } catch (_) {
      return episode;
    }
  }

  Future<int> enqueueDownloadNext(
    MediaItem series, {
    required SeriesInfo info,
    required SeriesEpisode from,
    int? count,
  }) async {
    final n = count ?? downloadSettings.aheadCountClamped;
    final next = episodesAfter(
      info: info,
      seasonNumber: from.seasonNumber,
      episodeNum: from.episodeNum,
      count: n,
    );
    return enqueueEpisodeDownloads(series, next);
  }

  Future<int> enqueueDownloadRemainingInSeason(
    MediaItem series, {
    required SeriesInfo info,
    required int seasonNumber,
    int? fromEpisodeNum,
  }) async {
    final eps = remainingInSeason(
      info: info,
      seasonNumber: seasonNumber,
      fromEpisodeNum: fromEpisodeNum,
    );
    return enqueueEpisodeDownloads(series, eps);
  }

  /// Queue every episode in the series that isn't already downloaded/queued.
  Future<int> enqueueDownloadEntireSeries(
    MediaItem series, {
    required SeriesInfo info,
  }) {
    return enqueueEpisodeDownloads(series, allEpisodesInSeries(info));
  }

  /// Aniyomi-style download ahead while watching. Returns newly queued count.
  Future<int> enqueueDownloadAhead(MediaItem playingEpisode) async {
    if (!downloadSettings.downloadAheadWhileWatching) return 0;
    if (!playingEpisode.isEpisode) return 0;
    if (_downloadAheadTriggered.contains(playingEpisode.id)) return 0;
    _downloadAheadTriggered.add(playingEpisode.id);

    final series = seriesForEpisode(playingEpisode);
    if (series == null) return 0;
    try {
      final info = await loadSeriesInfo(series);
      final season = playingEpisode.seasonNumber;
      final epNum = playingEpisode.episodeNumber;
      if (season == null || epNum == null) return 0;
      return enqueueDownloadNext(
        series,
        info: info,
        from: SeriesEpisode(
          id: playingEpisode.streamId ?? playingEpisode.id,
          episodeNum: epNum,
          seasonNumber: season,
          title: playingEpisode.title,
          containerExtension: 'mp4',
        ),
        count: downloadSettings.aheadCountClamped,
      );
    } catch (_) {
      return 0;
    }
  }

  /// Queue an offline catchup clip for a wall-clock window (no EPG needed).
  Future<bool> enqueueCatchupDownloadAt({
    required MediaItem channel,
    required DateTime start,
    required Duration duration,
    String? title,
  }) async {
    final item = liveDvrItemForDownloadAt(
      channel: channel,
      start: start,
      duration: duration,
      title: title,
    );
    if (item == null) return false;
    return enqueueDownload(item);
  }

  /// Live channel backing a catchup/DVR [MediaItem], when resolvable.
  MediaItem? liveChannelForCatchup(MediaItem catchup) {
    if (catchup.kind != MediaKind.catchup) return null;
    if (catchup.streamId == null || catchup.sourceId == null) return null;
    final matched = liveChannels.cast<MediaItem?>().firstWhere(
      (c) => c?.streamId == catchup.streamId && c?.sourceId == catchup.sourceId,
      orElse: () => null,
    );
    if (matched != null) return matched;
    // Synthetic live row so download URL builders still have stream metadata.
    return MediaItem(
      id: 'live-${catchup.sourceId}-${catchup.streamId}',
      title: catchup.subtitle ?? catchup.title,
      playUrl: catchup.playUrl,
      kind: MediaKind.live,
      origin: catchup.origin,
      subtitle: catchup.group,
      thumbnailUrl: catchup.thumbnailUrl,
      group: catchup.group,
      channelId: catchup.channelId,
      streamId: catchup.streamId,
      epgChannelId: catchup.epgChannelId,
      catchupDays: catchup.catchupDays,
      sourceId: catchup.sourceId,
    );
  }

  /// EPG programme for a catchup clip, when the guide still has it.
  EpgProgram? programForCatchup(MediaItem catchup) {
    final channel = liveChannelForCatchup(catchup);
    final start = catchupStartOf(catchup);
    if (channel == null || start == null) return null;
    return programAt(channel, at: start.add(const Duration(seconds: 30)));
  }

  /// Queue an existing catchup/DVR clip for offline with before/after padding.
  ///
  /// Prefer this over [enqueueDownload] for [MediaKind.catchup] — the playable
  /// catchup URL is unpadded; downloads should use [computeDvrDownloadWindow].
  Future<bool> enqueueCatchupDownloadForClip(
    MediaItem catchup, {
    Duration? padBefore,
    Duration? padAfter,
  }) async {
    if (catchup.kind != MediaKind.catchup) return false;
    final channel = liveChannelForCatchup(catchup);
    if (channel == null) return false;

    final program = programForCatchup(catchup);
    if (program != null) {
      return enqueueCatchupDownload(
        channel: channel,
        program: program,
        padBefore: padBefore,
        padAfter: padAfter,
      );
    }

    final start = catchupStartOf(catchup);
    final duration = catchup.duration;
    if (start == null || duration == null || duration.inSeconds <= 0) {
      // Can't rebuild a padded window — fall back to the clip URL as-is.
      return enqueueDownload(catchup);
    }
    final before = padBefore ?? downloadSettings.dvrPadBefore;
    final after = padAfter ?? downloadSettings.dvrPadAfter;
    final item = liveDvrItemForDownloadAt(
      channel: channel,
      start: start,
      duration: duration,
      title: catchup.title,
      thumbnailUrl: catchup.thumbnailUrl,
      allowWithoutCatchup: true,
      padBefore: before,
      padAfter: after,
    );
    if (item == null) return false;
    return enqueueDownload(item);
  }

  Future<bool> _hasNetworkConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty) return false;
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // Prefer keeping the file if we can't tell.
      return false;
    }
  }

  DownloadTask? _completedDownloadTaskFor(MediaItem item) {
    DownloadTask? task = _downloads.bestTaskFor(item, completedOnly: true);
    if (task == null && item.id.startsWith('dl-')) {
      final tid = item.id.substring(3);
      task = _downloads.tasks.cast<DownloadTask?>().firstWhere(
        (t) => t?.id == tid,
        orElse: () => null,
      );
    }
    if (task == null || task.status != DownloadStatus.completed) return null;
    return task;
  }

  String _removeScheduleKey(DownloadTask task, MediaItem item) =>
      task.id.isNotEmpty ? task.id : item.id;

  /// Cancel a pending "remove after watching" for [item] (e.g. replay).
  void cancelScheduledRemoveDownload(MediaItem item) {
    final task = _completedDownloadTaskFor(item);
    final keys = <String>{
      item.id,
      if (task != null) _removeScheduleKey(task, item),
      if (task != null) task.item.id,
      if (item.id.startsWith('dl-')) item.id.substring(3),
    };
    var changed = false;
    for (final key in keys) {
      _scheduledRemoveAfterWatch.remove(key)?.cancel();
      if (_scheduledRemoveItems.remove(key) != null) changed = true;
      if (_pendingRemoveWhenOnline.remove(key) != null) changed = true;
      // Allow a later watch cycle to schedule again.
      _removeAfterWatchTriggered.remove(key);
    }
    if (changed) unawaited(_persistPendingRemoveAfterWatch());
  }

  Future<void> _persistPendingRemoveAfterWatch() async {
    await _store.savePendingRemoveAfterWatch(
      _pendingRemoveWhenOnline.values.toList(),
    );
  }

  void _queuePendingRemoveWhenOnline(String key, MediaItem item) {
    _pendingRemoveWhenOnline[key] = item;
    unawaited(_persistPendingRemoveAfterWatch());
  }

  Future<void> _runScheduledRemoveAfterWatch(String key) async {
    _scheduledRemoveAfterWatch.remove(key);
    final item = _scheduledRemoveItems.remove(key);
    if (item == null) return;
    if (!downloadSettings.removeAfterWatch) return;

    if (!await _hasNetworkConnectivity()) {
      _queuePendingRemoveWhenOnline(key, item);
      return;
    }

    await maybeRemoveDownloadAfterWatch(item);
  }

  /// When back online, finish any removals that were deferred while offline.
  Future<void> _flushPendingRemoveAfterWatch() async {
    if (_pendingRemoveWhenOnline.isEmpty) return;
    if (!downloadSettings.removeAfterWatch) {
      _pendingRemoveWhenOnline.clear();
      await _persistPendingRemoveAfterWatch();
      return;
    }
    if (!await _hasNetworkConnectivity()) return;

    final pending = Map<String, MediaItem>.from(_pendingRemoveWhenOnline);
    for (final entry in pending.entries) {
      if (!await _hasNetworkConnectivity()) break;
      final removed = await maybeRemoveDownloadAfterWatch(entry.value);
      if (removed || _completedDownloadTaskFor(entry.value) == null) {
        _pendingRemoveWhenOnline.remove(entry.key);
      }
    }
    await _persistPendingRemoveAfterWatch();
  }

  /// Delete offline file after the title was finished or left for the next episode.
  Future<bool> maybeRemoveDownloadAfterWatch(MediaItem item) async {
    if (!downloadSettings.removeAfterWatch) return false;
    if (_removeAfterWatchTriggered.contains(item.id)) return false;

    // Never wipe the only copy while offline — retry when connectivity returns.
    if (!await _hasNetworkConnectivity()) {
      final task = _completedDownloadTaskFor(item);
      if (task != null) {
        _queuePendingRemoveWhenOnline(_removeScheduleKey(task, item), item);
      } else {
        _queuePendingRemoveWhenOnline(item.id, item);
      }
      return false;
    }

    final task = _completedDownloadTaskFor(item);
    if (task == null) return false;

    final key = _removeScheduleKey(task, item);
    _scheduledRemoveAfterWatch.remove(key)?.cancel();
    _scheduledRemoveItems.remove(key);
    _pendingRemoveWhenOnline.remove(key);
    unawaited(_persistPendingRemoveAfterWatch());

    _removeAfterWatchTriggered.add(item.id);
    _removeAfterWatchTriggered.add(task.item.id);
    _removeAfterWatchTriggered.add(key);
    final localId = task.asLocalItem().id;
    await _downloads.remove(task.id, deleteFile: true);
    localMedia = localMedia.where((m) => m.id != localId).toList();
    await _persistDownloads();
    await _store.saveLocalMedia(localMedia);
    notifyListeners();
    return true;
  }

  Future<int> refreshWatchlistSeriesDownloads({String? sourceId}) async {
    var queued = 0;
    final seriesList = watchlist.where((m) {
      if (!m.isSeries) return false;
      if (sourceId != null && m.sourceId != sourceId) return false;
      return true;
    }).toList();

    for (final series in seriesList) {
      try {
        final info = await loadSeriesInfo(series);
        final key = seriesKeyFor(series);
        final currentIds = [for (final e in flattenedEpisodes(info)) e.id];
        final known = knownEpisodeIdsBySeries[key] ?? const <String>[];
        final fresh = newEpisodeIds(currentIds: currentIds, knownIds: known);
        knownEpisodeIdsBySeries = {...knownEpisodeIdsBySeries, key: currentIds};
        await _store.saveKnownEpisodeIds(knownEpisodeIdsBySeries);

        if (!downloadSettings.downloadNewOnUpdate || fresh.isEmpty) continue;
        final byId = {for (final e in flattenedEpisodes(info)) e.id: e};
        final toQueue = [
          for (final id in fresh)
            if (byId[id] != null) byId[id]!,
        ];
        queued += await enqueueEpisodeDownloads(series, toQueue);
      } catch (_) {
        // Per-series failures should not stop the batch.
      }
    }
    return queued;
  }

  Future<void> _persistDownloads() async {
    if (!_downloadsHydrated) return;
    await _store.saveDownloads(_downloads.completedItems);
  }

  /// Mirror finished downloads into Library offline copies immediately.
  Future<void> _syncCompletedDownloadsToLibrary() async {
    if (!_downloadsHydrated) return;
    final completed = _downloads.completedItems;
    if (completed.isEmpty) return;
    final existing = {for (final m in localMedia) m.id};
    final fresh = [
      for (final item in completed)
        if (!existing.contains(item.id)) item,
    ];
    if (fresh.isEmpty) return;
    localMedia = [...fresh, ...localMedia];
    await _store.saveLocalMedia(localMedia);
  }

  /// Pasted URL / local import / torrent / download — not IPTV catalog rows.
  static bool _isUserOwnedLibraryOrigin(MediaItem item) {
    switch (item.origin) {
      case MediaOrigin.url:
      case MediaOrigin.localFile:
      case MediaOrigin.torrent:
      case MediaOrigin.download:
        return true;
      case MediaOrigin.iptvM3u:
      case MediaOrigin.iptvXtream:
      case MediaOrigin.iptvStalker:
      case MediaOrigin.customCatalog:
      case MediaOrigin.jellyfin:
      case MediaOrigin.emby:
      case MediaOrigin.plex:
        return false;
    }
  }

  /// Films / For you may include history as cards; skip URL ghosts that were
  /// already removed from [localMedia] (Retirer used to leave history alone).
  bool _isLibraryBackedShelfItem(MediaItem item) {
    if (_isHistoryTombstoned(item)) return false;
    if (!_isUserOwnedLibraryOrigin(item)) return true;
    if (isTrackerListShell(item)) return true;
    if (localMedia.any((m) => m.id == item.id)) return true;
    if (_downloads.completedItems.any((m) => m.id == item.id)) return true;
    return false;
  }

  /// Whether [item] is a user-owned Library row (URL, import, torrent, download)
  /// that can be removed from this device — not catalog/IPTV source content.
  bool isRemovableLibraryItem(MediaItem item) {
    // Tracker shells reuse [MediaOrigin.url] with an empty playUrl — Retirer
    // would no-op on localMedia and leave the shell in Simkl/My List.
    if (isTrackerListShell(item)) return false;
    if (_isUserOwnedLibraryOrigin(item)) return true;
    return item.kind == MediaKind.local || item.kind == MediaKind.network;
  }

  String? _lastWatchNotifyKey;
  Timer? _watchProgressNotifyTimer;

  void _upsertHistory(MediaItem updated) {
    history = [
      updated,
      ...history.where((m) {
        if (m.id == updated.id) return false;
        if (m.kind == MediaKind.catchup && !isCatchupAvailable(m)) {
          return false;
        }
        // One history row per movie family so quality/language switches
        // share Continue watching instead of degrouping encodes.
        if (_sameMovieWatchFamily(m, updated)) return false;
        // Same for episode versions (catalog magnets / encodes of SxxExx).
        if (_sameEpisodeWatchFamily(m, updated)) return false;
        return true;
      }),
    ].take(200).toList();
  }

  /// Updates [localMedia] when this title (or matching episode) is a local
  /// row. Returns whether a row changed (and schedules write-behind).
  bool _patchLocalMediaProgress(MediaItem updated, {bool softPersist = false}) {
    if (localMedia.isEmpty) return false;
    var localChanged = false;
    final nextLocal = localMedia.map((m) {
      final sameItem = m.id == updated.id;
      final sameEpisode =
          updated.seriesId != null &&
          updated.seriesId == m.seriesId &&
          updated.seasonNumber != null &&
          updated.seasonNumber == m.seasonNumber &&
          updated.episodeNumber != null &&
          updated.episodeNumber == m.episodeNumber;
      if (!sameItem && !sameEpisode) return m;
      localChanged = true;
      return m.copyWith(
        progress: updated.progress,
        duration: updated.duration ?? m.duration,
        lastWatchedAt: updated.lastWatchedAt,
      );
    }).toList();
    if (!localChanged) return false;
    localMedia = nextLocal;
    if (softPersist) {
      _scheduleSoftPersist(_PersistTarget.localMedia);
    } else {
      _schedulePersist(_PersistTarget.localMedia);
    }
    return true;
  }

  void _notifyWatchProgress(MediaItem updated, {bool structural = false}) {
    _cachedContinueWatching = null;
    _continueWatchingStamp = -1;
    watchHistoryRevision++;
    final key =
        '${updated.id}:${(updated.progress * 20).floor()}'; // ~5% buckets
    final isStructural =
        structural ||
        _lastWatchNotifyKey == null ||
        !_lastWatchNotifyKey!.startsWith('${updated.id}:');
    if (isStructural) {
      _watchProgressNotifyTimer?.cancel();
      _watchProgressNotifyTimer = null;
      _lastWatchNotifyKey = key;
      notifyListeners();
      return;
    }
    if (key == _lastWatchNotifyKey) return;
    _lastWatchNotifyKey = key;
    if (_watchProgressNotifyTimer != null) return;
    _watchProgressNotifyTimer = Timer(const Duration(seconds: 2), () {
      _watchProgressNotifyTimer = null;
      if (_disposed) return;
      notifyListeners();
    });
  }

  // Tracker sync / scrobble → TrackerSyncCoordinator
  // (lib/providers/library/tracker_sync_coordinator.dart)

  void setAppForeground(bool foreground) {
    // Android can kill a backgrounded app at any point — land pending writes now.
    if (!foreground) unawaited(flushPendingWrites());
    _appForeground = foreground;
    if (!foreground) {
      _idleWorkGeneration++;
      _cancelShellThaw();
      // Hold the single-worker queue while AFK so a freeze/thaw cannot dump
      // every deferred idle job onto the UI isolate. (Desktop blur does not
      // pause — see [setDesktopShellActive].)
      _bgQueue.setPaused(true);
      _vodVariantIndexResumeTimer?.cancel();
      _vodVariantIndexResumeTimer = null;
      _idleJobsQuietResumeTimer?.cancel();
      _idleJobsQuietResumeTimer = null;
      if (_liveCategoryPrefetching.isNotEmpty) {
        _liveCategoryPrefetchPaused.addAll(_liveCategoryPrefetching);
        final n = _liveCategoryPrefetching.length;
        _liveCategoryPrefetching.clear();
        JavpLog.i('tv', 'prefetch live categories cancel on background n=$n');
      }
      // True AFK — treat like a long blur so wake does not immediately index.
      if (_vodVariantIndexBuilding || _vodVariantIndexDeferred) {
        _vodVariantIndexDeferred = true;
        _desktopShellBlurredAt ??= DateTime.now();
      }
      JavpLog.i(
        'lifecycle',
        'background queuePending=${_bgQueue.pendingCount} '
            'deferredIndex=$_vodVariantIndexDeferred '
            'idleGen=$_idleWorkGeneration',
      );
      return;
    }
    // Windows can resume (taskbar click) without window_manager onWindowFocus
    // when the HWND was unresponsive — Sources then parks on shell=false.
    if (!_desktopShellActive) {
      JavpLog.w(
        'desktop',
        'recover shell on foreground (missed onWindowFocus)',
      );
      setDesktopShellActive(true);
    }
    // Restore / resume: paint and take clicks before any catalog apply.
    _beginShellThaw(reason: 'foreground');
    // Drop stacked idle jobs BEFORE unpause so thaw does not drain depth=5.
    _coalesceIdleJobsAfterResume(reason: 'foreground');
    _bgQueue.setPaused(false);
    _resumeLiveCategoryPrefetchAfterFocus();
    JavpLog.i(
      'lifecycle',
      'foreground queuePending=${_bgQueue.pendingCount} '
          'deferredIndex=$_vodVariantIndexDeferred',
    );
    _scheduleDeferredVodVariantIndexResume(reason: 'foreground');
  }

  /// Desktop blur/focus — defer opportunistic Versions index; coalesce idle.
  ///
  /// Does not pause the bg queue (that stays on [setAppForeground] for true
  /// AFK / minimize lifecycle). Short alt-tab should not stop a movie; on
  /// Windows, [PlaybackProvider.onDesktopShellBlurred] pauses after a long
  /// blur so libmpv does not keep marking Flutter textures while minimized.
  ///
  /// Manual Synchroniser holds focus ([shouldHoldDesktopFocusForSync]): a
  /// spurious onWindowBlur mid-fetch must not latch shell=false or the HWND
  /// stops taking clicks while frames still tick.
  void setDesktopShellActive(bool active) {
    if (!active && _manualSyncFocusHold.isNotEmpty) {
      JavpLog.i(
        'desktop',
        'ignore shell blur during manual sync hold '
            'n=${_manualSyncFocusHold.length}',
      );
      return;
    }
    if (_desktopShellActive == active) return;
    _desktopShellActive = active;
    if (!active) {
      _idleWorkGeneration++;
      _cancelShellThaw();
      _desktopShellBlurredAt = DateTime.now();
      _vodVariantIndexResumeTimer?.cancel();
      _vodVariantIndexResumeTimer = null;
      _idleJobsQuietResumeTimer?.cancel();
      _idleJobsQuietResumeTimer = null;
      // Mark defer so a hydrate-driven schedule that races blur is skipped.
      if (_vodVariantIndexBuilding ||
          (_vodVariantIndex == null && _vodStreamCache.isNotEmpty)) {
        _vodVariantIndexDeferred = true;
      }
      // Stop in-flight Xtream live category fill (loop checks the set).
      if (_liveCategoryPrefetching.isNotEmpty) {
        _liveCategoryPrefetchPaused.addAll(_liveCategoryPrefetching);
        final n = _liveCategoryPrefetching.length;
        _liveCategoryPrefetching.clear();
        JavpLog.i('tv', 'prefetch live categories cancel on blur n=$n');
      }
      // Drop pending idle warm/sync so alt-tab does not keep warming.
      final dropped = _bgQueue.cancelPending(ids: _coalescableIdleJobIds);
      if (dropped > 0) {
        _vodWarmScheduled = false;
        _idleSourceSyncScheduled = false;
      }
      JavpLog.i(
        'desktop',
        'shell blur deferredIndex=$_vodVariantIndexDeferred '
            'droppedIdle=$dropped queuePending=${_bgQueue.pendingCount} '
            'idleGen=$_idleWorkGeneration',
      );
      return;
    }
    _beginShellThaw(reason: 'focus');
    final blurredFor = _desktopShellBlurredAt == null
        ? Duration.zero
        : DateTime.now().difference(_desktopShellBlurredAt!);
    _coalesceIdleJobsAfterResume(reason: 'focus');
    _resumePostHydrateIndexesIfNeeded();
    _resumeLiveCategoryPrefetchAfterFocus();
    JavpLog.i(
      'desktop',
      'shell focus blurFor=${blurredFor.inSeconds}s '
          'deferredIndex=$_vodVariantIndexDeferred '
          'queuePending=${_bgQueue.pendingCount}',
    );
    _scheduleDeferredVodVariantIndexResume(
      reason: 'focus',
      blurredFor: blurredFor,
    );
  }

  /// Drop stacked low idle jobs and reschedule once after a quiet delay.
  ///
  /// Same-id enqueue already dedupes; wake lag is from *distinct* ids
  /// (idle-vod-warm → relinks → for-you-remote → deep-sync → idle-source-sync).
  /// Only re-queue jobs that still have work; do not reset For-you fingerprint
  /// on alt-tab (that forced unnecessary remote enrich).
  void _coalesceIdleJobsAfterResume({required String reason}) {
    final dropped = _bgQueue.cancelPending(ids: _coalescableIdleJobIds);
    _vodWarmScheduled = false;
    _idleSourceSyncScheduled = false;
    _deepSyncSoftDeferTimer?.cancel();
    _deepSyncSoftDeferTimer = null;
    _idleJobsQuietResumeTimer?.cancel();
    JavpLog.i(
      'bg',
      'coalesce idle after $reason dropped=$dropped '
          'quiet=${_idleJobsQuietResumeDelay.inSeconds}s',
    );
    _idleJobsQuietResumeTimer = Timer(_idleJobsQuietResumeDelay, () {
      _idleJobsQuietResumeTimer = null;
      if (!_allowIdleBackgroundWork) {
        JavpLog.i(
          'bg',
          'coalesce idle quiet skip allowIdle=false '
              'fg=$_appForeground shell=$_desktopShellActive '
              'playback=$_playbackActive — wait for focus',
        );
        return;
      }
      final needWarm = _needsIdleVodWarm();
      final needSource = _idleSourceSyncCandidates().isNotEmpty;
      final needDeep = _hasPendingDeepSync();
      JavpLog.i(
        'bg',
        'coalesce idle quiet fire reason=$reason '
            'needWarm=$needWarm needSource=$needSource needDeep=$needDeep',
      );
      if (needWarm) {
        unawaited(scheduleIdleVodWarm(reason: 'coalesce:$reason'));
      }
      if (needSource) {
        unawaited(_scheduleIdleSourceSync(reason: 'coalesce:$reason'));
      }
      if (needDeep) {
        unawaited(_deepSyncPendingSources());
      }
    });
  }

  void _scheduleDeferredVodVariantIndexResume({
    required String reason,
    Duration? blurredFor,
  }) {
    if (_vodVariantIndexBuilding) return;
    // Already current — clear stale defer flag and skip.
    if (_vodVariantIndex != null && _vodVariantBuiltStamp == _vodPoolStamp) {
      _vodVariantIndexDeferred = false;
      return;
    }
    if (!_vodVariantIndexDeferred) return;
    if (!_allowOpportunisticVodIndex) return;

    // Fresh enough for this stamp — Catalog/detail can still force a rebuild.
    final last = _vodVariantIndexLastBuiltAt;
    if (last != null &&
        _vodVariantIndex != null &&
        _vodVariantBuiltStamp == _vodPoolStamp &&
        DateTime.now().difference(last) < _vodVariantIndexResumeTtl) {
      _vodVariantIndexDeferred = false;
      JavpLog.i('vod', 'variant index resume skipped (fresh) after $reason');
      return;
    }

    final away =
        blurredFor ??
        (_desktopShellBlurredAt == null
            ? _vodVariantIndexLongBlur
            : DateTime.now().difference(_desktopShellBlurredAt!));
    final delay = away >= _vodVariantIndexLongBlur
        ? _vodVariantIndexResumeDelay
        : _vodVariantIndexShortResumeDelay;

    _vodVariantIndexResumeTimer?.cancel();
    JavpLog.i(
      'vod',
      'variant index resume delayed ${delay.inSeconds}s '
          'after $reason (away=${away.inSeconds}s)',
    );
    _vodVariantIndexResumeTimer = Timer(delay, () {
      _vodVariantIndexResumeTimer = null;
      _resumeDeferredVodVariantIndex();
    });
  }

  void _resumeDeferredVodVariantIndex() {
    if (!_vodVariantIndexDeferred || !_allowOpportunisticVodIndex) return;
    if (_vodVariantIndexBuilding) return;
    if (_vodVariantIndex != null && _vodVariantBuiltStamp == _vodPoolStamp) {
      _vodVariantIndexDeferred = false;
      return;
    }
    _vodVariantIndexDeferred = false;
    _desktopShellBlurredAt = null;
    _scheduleVodVariantIndexBuild();
  }

  /// After a UI stall the isolate is runnable again — drop queued idle work
  /// so the hitch does not immediately start another catalog job.
  ///
  /// Cannot abort the tight loop that caused the gap (Dart is single-threaded).
  /// Opportunistic in-flight syncs abort at the next [_yieldSoftSyncToShell].
  void _onUiStallDetected(int gapMs, String phase) {
    if (_disposed) return;
    final dropped = _dropOpportunisticIdle(reason: 'ui-stall');
    JavpLog.w(
      'ui-stall',
      'abort idle gap=${gapMs}ms phase=$phase dropped=$dropped '
          'idleGen=$_idleWorkGeneration '
          'marks=${UiStallWatchdog.recentMarks} '
          '${UiStallWatchdog.desktopContextSuffix()} '
          '${debugWorkSnapshot().toLogLine()}',
    );
  }

  int _dropOpportunisticIdle({required String reason}) {
    _idleWorkGeneration++;
    final dropped = _bgQueue.cancelPending(ids: _coalescableIdleJobIds);
    if (dropped > 0) {
      _vodWarmScheduled = false;
      _idleSourceSyncScheduled = false;
    }
    if (reason != 'ui-stall') {
      JavpLog.i(
        'bg',
        'coalesce overlay reason=$reason dropped=$dropped '
            'idleGen=$_idleWorkGeneration',
      );
    }
    return dropped;
  }

  @override
  void dispose() {
    _disposed = true;
    _agentSyncTrigger?.stop();
    _agentSyncTrigger = null;
    UiStallWatchdog.removeStallListener(_onUiStallDetected);
    if (identical(UiStallWatchdog.desktopHintsProvider, _stallDesktopHints)) {
      UiStallWatchdog.desktopHintsProvider = null;
    }
    _writeBehindTimer?.cancel();
    _writeBehindTimer = null;
    _softPersistTimer?.cancel();
    _softPersistTimer = null;
    _watchProgressNotifyTimer?.cancel();
    _watchProgressNotifyTimer = null;
    _vodVariantIndexResumeTimer?.cancel();
    _vodVariantIndexResumeTimer = null;
    _idleJobsQuietResumeTimer?.cancel();
    _idleJobsQuietResumeTimer = null;
    _deepSyncSoftDeferTimer?.cancel();
    _deepSyncSoftDeferTimer = null;
    _trackerRelinkAfterVodTimer?.cancel();
    _trackerRelinkAfterVodTimer = null;
    _cancelShellThaw();
    _homeRevealSettleTimeoutTimer?.cancel();
    _homeRevealSettleTimeoutTimer = null;
    _deferredAddSyncIds.clear();
    _deferredAddSyncFlush = null;
    if (_homeRevealSettledCompleter != null &&
        !_homeRevealSettledCompleter!.isCompleted) {
      _homeRevealSettledCompleter!.complete();
    }
    _homeRevealSettledCompleter = null;
    _postHydrateFollowupsTimer?.cancel();
    _postHydrateFollowupsTimer = null;
    JavpImageCache.instance.setStartupThrottle(false);
    _bgQueue.setColdStartMode(false);
    // Fire-and-forget: the store owns its own file handles and outlives us.
    unawaited(flushPendingWrites());
    for (final timer in _scheduledRemoveAfterWatch.values) {
      timer.cancel();
    }
    _scheduledRemoveAfterWatch.clear();
    _scheduledRemoveItems.clear();
    _pendingRemoveWhenOnline.clear();
    unawaited(_connectivitySub?.cancel());
    _downloads.removeListener(_onDownloadsChanged);
    unawaited(AndroidDownloadKeepAlive.instance.stop());
    _cast.removeListener(notifyListeners);
    _cast.dispose();
    syncStatusListenable.dispose();
    // Owned HTTP clients — injected clients are owned by the caller.
    if (_injectedHttp == null) {
      _closeOwnedHttpClients();
    }
    unawaited(_torrent.stopActive(deleteFiles: false));
    unawaited(_liveDb.close());
    unawaited(_vodDb.close());
    unawaited(_epgDb.close());
    super.dispose();
  }
}

/// Narrow listenable for the Sources row + Live TV status strip.
///
/// [ChangeNotifier.notifyListeners] is protected — this tick is the only
/// way soft-sync status may wake those widgets without a catalog rebuild.
class LibrarySyncStatusTick extends ChangeNotifier with DeferNotifyIfBuilding {
  bool _tickDisposed = false;

  @override
  bool get notifyListenersDisposed => _tickDisposed;

  @override
  void dispose() {
    _tickDisposed = true;
    super.dispose();
  }

  void tick() {
    if (!hasListeners) return;
    notifyListeners();
  }
}

/// Where [LibraryProvider.playerPeerChannelsFor] pulled its list from.
enum PlayerPeerSource { category, favorites, forYou }

/// Stores that [LibraryProvider] persists lazily via write-behind.
enum _PersistTarget {
  catalog,
  localMedia,
  history,
  detailsCache,
  segmentCache,
  vodCache,
}

class _EpgHttpCacheEntry {
  const _EpgHttpCacheEntry({
    required this.bytes,
    this.contentEncoding,
    this.etag,
    this.lastModified,
  });

  final List<int> bytes;
  final String? contentEncoding;
  final String? etag;
  final String? lastModified;
}
