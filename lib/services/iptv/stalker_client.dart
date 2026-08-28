import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';

/// Result of a Stalker/Ministra catalog sync (live first; VOD/series optional).
class StalkerSyncResult {
  const StalkerSyncResult({
    required this.live,
    required this.vod,
    required this.series,
    required this.liveCategories,
    required this.vodCategories,
    required this.seriesCategories,
    this.portalBase,
  });

  final List<MediaItem> live;
  final List<MediaItem> vod;
  final List<MediaItem> series;
  final List<IptvCategory> liveCategories;
  final List<IptvCategory> vodCategories;
  final List<IptvCategory> seriesCategories;
  final String? portalBase;
}

class _StalkerSession {
  _StalkerSession({
    required this.token,
    required this.base,
    required this.apiPath,
    required this.portal,
    required this.mac,
    this.serial,
  });

  final String token;
  final String base;
  final String apiPath;
  final String portal;
  final String mac;
  final String? serial;
}

class _CachedStalkerSession {
  _CachedStalkerSession(this.session, this.expiresAt);
  final _StalkerSession session;
  final DateTime expiresAt;
  bool get isValid => expiresAt.isAfter(DateTime.now());
}

/// Stalker / Ministra portal client (MAG-style handshake + load.php API).
///
/// Talks to the portal directly from the device — no CORS proxy required.
/// Stream tokens from [createLink] are often IP-bound and short-lived; resolve
/// a fresh URL at play time rather than caching playable URLs.
class StalkerClient {
  StalkerClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Discovered API path cache (portal|mac → base + apiPath).
  final Map<String, ({String base, String apiPath})> _pathCache = {};

  /// Handshake token cache. Invalidated on auth failure.
  final Map<String, _CachedStalkerSession> _sessionCache = {};

  static const sessionTtl = Duration(minutes: 5);

  static const _apiPaths = <String>[
    'server/load.php',
    'portal.php',
    'stalker_portal/server/load.php',
  ];

  static const _magUserAgent =
      'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 '
      '(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';

  /// Normalize a MAC to `AA:BB:CC:DD:EE:FF` (uppercase).
  static String normalizeMac(String raw) {
    final hex = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    if (hex.length != 12) {
      throw Exception(
        'Enter a valid MAC address (12 hex digits, e.g. 00:1A:79:12:34:56)',
      );
    }
    final parts = <String>[];
    for (var i = 0; i < 12; i += 2) {
      parts.add(hex.substring(i, i + 2));
    }
    return parts.join(':');
  }

  String _normalizePortal(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  String _cacheKey(String portal, String mac) =>
      '${_normalizePortal(portal)}|$mac';

  Map<String, String> _headers({
    required String mac,
    required String portalUrl,
    String token = '',
    String? serial,
  }) {
    final stripped = _normalizePortal(portalUrl).replaceAll(RegExp(r'/c$'), '');
    final referer = '$stripped/c/';
    var cookie =
        'mac=${Uri.encodeComponent(mac)}; stb_lang=en; '
        'timezone=Europe%2FParis';
    if (serial != null && serial.trim().isNotEmpty) {
      cookie += '; sn=${serial.trim()}';
    }
    return {
      'User-Agent': _magUserAgent,
      'Accept': '*/*',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-User-Agent': 'Model: MAG250; Link: WiFi',
      'Authorization': token.isEmpty ? 'Bearer ' : 'Bearer $token',
      'Cookie': cookie,
      'Referer': referer,
    };
  }

  /// Handshake only — validates portal + MAC before saving a source.
  Future<void> authenticate(IptvSource source) async {
    await _getSession(source);
  }

  Future<_StalkerSession> _getSession(IptvSource source) async {
    final portal = source.serverUrl?.trim();
    if (portal == null || portal.isEmpty) {
      throw Exception('Portal URL is missing');
    }
    final mac = normalizeMac(source.username ?? '');
    final serial = source.password?.trim();
    final serialOpt = (serial == null || serial.isEmpty) ? null : serial;
    final key = _cacheKey(portal, mac);
    final cachedSession = _sessionCache[key];
    if (cachedSession != null && cachedSession.isValid) {
      return cachedSession.session;
    }

    final cached = _pathCache[key];

    if (cached != null) {
      final token = await _tryHandshake(
        base: cached.base,
        apiPath: cached.apiPath,
        mac: mac,
        portalUrl: portal,
        serial: serialOpt,
      );
      if (token != null) {
        final session = _StalkerSession(
          token: token,
          base: cached.base,
          apiPath: cached.apiPath,
          portal: portal,
          mac: mac,
          serial: serialOpt,
        );
        await _ensureProfile(session);
        _sessionCache[key] = _CachedStalkerSession(
          session,
          DateTime.now().add(sessionTtl),
        );
        return session;
      }
      _pathCache.remove(key);
      _sessionCache.remove(key);
    }

    final stripped = _normalizePortal(portal);
    final bases = <String>[('$stripped/')];
    if (stripped.endsWith('/c')) {
      bases.add('${stripped.replaceAll(RegExp(r'/c$'), '')}/');
    } else {
      bases.add('$stripped/c/');
    }

    Object? lastError;
    for (final base in bases) {
      for (final path in _apiPaths) {
        try {
          final token = await _tryHandshake(
            base: base,
            apiPath: path,
            mac: mac,
            portalUrl: portal,
            serial: serialOpt,
          );
          if (token != null) {
            _pathCache[key] = (base: base, apiPath: path);
            final session = _StalkerSession(
              token: token,
              base: base,
              apiPath: path,
              portal: portal,
              mac: mac,
              serial: serialOpt,
            );
            await _ensureProfile(session);
            _sessionCache[key] = _CachedStalkerSession(
              session,
              DateTime.now().add(sessionTtl),
            );
            return session;
          }
        } catch (e) {
          lastError = e;
          if ('$e'.contains('rate limited')) rethrow;
        }
      }
    }
    throw Exception(
      'Stalker handshake failed'
      '${lastError == null ? '' : ': $lastError'}',
    );
  }

  Future<String?> _tryHandshake({
    required String base,
    required String apiPath,
    required String mac,
    required String portalUrl,
    String? serial,
  }) async {
    final uri = Uri.parse('$base$apiPath').replace(
      queryParameters: {
        'type': 'stb',
        'action': 'handshake',
        'prehash': '0',
        'token': '',
        'JsHttpRequest': '1-xml',
      },
    );
    final headers = _headers(mac: mac, portalUrl: portalUrl, serial: serial);
    final response = await _http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 429) {
      throw Exception('Portal rate limited (429). Try again in a minute.');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) return null;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final js = decoded['js'];
      if (js is! Map) return null;
      final token = '${js['token'] ?? ''}'.trim();
      return token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// Many portals require get_profile before channel/VOD APIs accept the token.
  Future<void> _ensureProfile(_StalkerSession session) async {
    try {
      await _portalFetch(session, {
        'type': 'stb',
        'action': 'get_profile',
        'hd': '1',
        'ver':
            'ImageDescription: 0.2.18-r14-pub-250; ImageDate: Fri Jan 15 15:20:44 EET 2016; '
            'PORTAL version: 5.6.0; API Version: JS API version: 328; '
            'STB API version: 134; Player Engine version: 0x566',
        'num_banks': '2',
        'sn': session.serial ?? '',
        'stb_type': 'MAG250',
        'image_version': '218',
        'auth_second_step': '1',
        'hw_version': '1.7-BD-00',
        'hw_version_2': '1.7-BD-00',
        'device_id': '',
        'device_id2': '',
        'signature': '',
        'api_signature': '262',
      });
    } catch (_) {
      // Non-fatal — some portals skip profile.
    }
  }

  Future<Map<String, dynamic>?> _portalFetch(
    _StalkerSession session,
    Map<String, String> params, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final query = {...params, 'JsHttpRequest': '1-xml'};
    final uri = Uri.parse(
      '${session.base}${session.apiPath}',
    ).replace(queryParameters: query);
    final headers = _headers(
      mac: session.mac,
      portalUrl: session.portal,
      token: session.token,
      serial: session.serial,
    );

    Future<Map<String, dynamic>?> once(http.Response response) async {
      if (response.statusCode >= 400) return null;
      final text = response.body;
      if (text.contains('Authorization failed')) return null;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return null;
    }

    try {
      final get = await _http.get(uri, headers: headers).timeout(timeout);
      final parsed = await once(get);
      if (parsed != null) return parsed;
    } catch (_) {}

    try {
      final body = query.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');
      final post = await _http
          .post(uri, headers: headers, body: body)
          .timeout(timeout);
      return once(post);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _portalFetchRetry(
    _StalkerSession session,
    Map<String, String> params, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var active = session;
    var result = await _portalFetch(active, params, timeout: timeout);
    if (result == null) {
      // Token expired — drop the cache, handshake once, then retry.
      _sessionCache.remove(_cacheKey(session.portal, session.mac));
      active = await _getSession(
        IptvSource(
          id: 'tmp',
          name: 'tmp',
          type: IptvSourceType.stalker,
          createdAt: DateTime.now(),
          serverUrl: session.portal,
          username: session.mac,
          password: session.serial,
        ),
      );
      result = await _portalFetch(active, params, timeout: timeout);
    }
    if (result == null) {
      throw Exception(
        'Stalker authorization failed for ${params['action'] ?? 'request'}',
      );
    }
    return result;
  }

  Future<StalkerSyncResult> syncCatalog(
    IptvSource source, {
    bool includeVod = false,
    bool includeSeries = false,
  }) async {
    final session = await _getSession(source);

    final genreData = await _portalFetchRetry(session, {
      'type': 'itv',
      'action': 'get_genres',
    });
    final chData = await _portalFetchRetry(session, {
      'type': 'itv',
      'action': 'get_all_channels',
    }, timeout: const Duration(seconds: 30));

    final genresRaw = genreData['js'];
    final genreList = genresRaw is List ? genresRaw : const [];
    final genreMap = <String, String>{};
    final adultGenreIds = <String>{};
    final liveCategories = <IptvCategory>[];
    for (final raw in genreList.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty || id == '*') continue;
      final title = '${row['title'] ?? 'Other'}'.trim();
      genreMap[id] = title.isEmpty ? 'Other' : title;
      final censored =
          truthyAdultFlag(row['censored']) ||
          truthyAdultFlag(row['adult']) ||
          truthyAdultFlag(row['is_adult']);
      if (censored) adultGenreIds.add(id);
      liveCategories.add(
        IptvCategory(
          id: id,
          name: genreMap[id]!,
          kind: IptvCategoryKind.live,
          sourceId: source.id,
          isAdult: censored,
        ),
      );
    }

    final channelsRoot = chData['js'];
    final channelRows = channelsRoot is Map
        ? (channelsRoot['data'] is List
              ? channelsRoot['data'] as List
              : const [])
        : (channelsRoot is List ? channelsRoot : const []);

    final live = <MediaItem>[];
    final liveSlice = Stopwatch()..start();
    for (final raw in channelRows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      final cmd = '${row['cmd'] ?? ''}'.trim();
      final genreId = '${row['tv_genre_id'] ?? ''}'.trim();
      final group = genreMap[genreId] ?? 'Other';
      final logo = _firstNonEmpty([row['logo'], row['logo_url'], row['icon']]);
      final epgId = _firstNonEmpty([row['xmltv_id'], row['epg_id']]);
      final name = '${row['name'] ?? 'Channel'}'.trim();
      final isAdult =
          truthyAdultFlag(row['censored']) ||
          truthyAdultFlag(row['adult']) ||
          truthyAdultFlag(row['is_adult']) ||
          adultGenreIds.contains(genreId);
      live.add(
        MediaItem(
          id: 'stalker-live-${source.id}-$id',
          title: name.isEmpty ? 'Channel' : name,
          playUrl: cmd,
          kind: MediaKind.live,
          origin: MediaOrigin.iptvStalker,
          subtitle: group,
          thumbnailUrl: logo,
          group: group,
          channelId: id,
          streamId: id,
          epgChannelId: epgId,
          sourceId: source.id,
          isAdult: isAdult,
        ),
      );
      await yieldUiIfDue(liveSlice, label: 'stalker-live-map');
    }

    // Always load VOD/series category shelves (Xtream parity) so Catalog can
    // show groups before background prefetch fills item caches.
    final vodCategories = await _fetchCategories(session, source, 'vod');
    final seriesCategories = await _fetchCategories(session, source, 'series');
    var vod = <MediaItem>[];
    var series = <MediaItem>[];

    if (includeVod) {
      final slice = Stopwatch()..start();
      for (final cat in vodCategories) {
        final rows = await _fetchOrderedList(
          session,
          type: 'vod',
          category: cat.id,
        );
        for (final row in rows) {
          final item = _mapVod(
            source,
            row,
            cat.name,
            categoryAdult: cat.isAdult,
          );
          if (item != null) vod.add(item);
          await yieldUiIfDue(slice, label: 'stalker-vod-map');
        }
      }
    }

    if (includeSeries) {
      final slice = Stopwatch()..start();
      for (final cat in seriesCategories) {
        final rows = await _fetchOrderedList(
          session,
          type: 'series',
          category: cat.id,
        );
        for (final row in rows) {
          final item = _mapSeries(
            source,
            row,
            cat.name,
            categoryAdult: cat.isAdult,
          );
          if (item != null) series.add(item);
          await yieldUiIfDue(slice, label: 'stalker-series-map');
        }
      }
    }

    return StalkerSyncResult(
      live: live,
      vod: vod,
      series: series,
      liveCategories: liveCategories,
      vodCategories: vodCategories,
      seriesCategories: seriesCategories,
      portalBase: session.base,
    );
  }

  /// Full movies + series packed for SQLite — no `List<MediaItem>` kept.
  ///
  /// Library prefetch **replaces** this source. An empty plan must not wipe
  /// a warm cache — that skip lives in [LibraryProvider], not here.
  /// Per-category [loadCategoryStreams] still returns a page of items.
  Future<VodIngestPlan> fetchOnDemandCatalogPlan(IptvSource source) async {
    final session = await _getSession(source);
    final vodCategories = await _fetchCategories(session, source, 'vod');
    final seriesCategories = await _fetchCategories(session, source, 'series');

    final sql = <Map<String, Object?>>[];
    final variants = <Map<String, Object?>>[];
    final slice = Stopwatch()..start();

    Future<void> pack(MediaItem? item) async {
      if (item == null) return;
      sql.add(VodCatalogDb.packItem(item));
      if (!item.isEpisode && !item.isLive) {
        variants.add(VodVariantIndex.packRow(item));
      }
      await yieldUiIfDue(slice, label: 'stalker-pack');
    }

    for (final cat in vodCategories) {
      final rows = await _fetchOrderedList(
        session,
        type: 'vod',
        category: cat.id,
      );
      for (final row in rows) {
        await pack(_mapVod(source, row, cat.name, categoryAdult: cat.isAdult));
      }
    }

    for (final cat in seriesCategories) {
      final rows = await _fetchOrderedList(
        session,
        type: 'series',
        category: cat.id,
      );
      for (final row in rows) {
        await pack(
          _mapSeries(source, row, cat.name, categoryAdult: cat.isAdult),
        );
      }
    }
    return vodIngestPlanFromVariantRowChunksInIsolate(
      rows: sql,
      variantRowChunks: [variants],
    );
  }

  /// On-demand category contents (Xtream [loadCategoryStreams] parity).
  Future<List<MediaItem>> loadCategoryStreams(
    IptvSource source, {
    required IptvCategory category,
  }) async {
    if (category.kind == IptvCategoryKind.live) {
      return const [];
    }
    final session = await _getSession(source);
    final type = category.kind == IptvCategoryKind.series ? 'series' : 'vod';
    final rows = await _fetchOrderedList(
      session,
      type: type,
      category: category.id,
    );
    final out = <MediaItem>[];
    final slice = Stopwatch()..start();
    for (final row in rows) {
      final item = category.kind == IptvCategoryKind.series
          ? _mapSeries(
              source,
              row,
              category.name,
              categoryAdult: category.isAdult,
            )
          : _mapVod(
              source,
              row,
              category.name,
              categoryAdult: category.isAdult,
            );
      if (item != null) out.add(item);
      await yieldUiIfDue(slice, label: 'stalker-category-map');
    }
    return out;
  }

  Future<List<IptvCategory>> _fetchCategories(
    _StalkerSession session,
    IptvSource source,
    String type,
  ) async {
    final kind = type == 'vod' ? IptvCategoryKind.vod : IptvCategoryKind.series;
    final data = await _portalFetchRetry(session, {
      'type': type,
      'action': 'get_categories',
    });
    final raw = data['js'];
    final list = raw is List ? raw : const [];
    final out = <IptvCategory>[];
    for (final entry in list.whereType<Map>()) {
      final row = Map<String, dynamic>.from(entry);
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty || id == '*') continue;
      final title = '${row['title'] ?? 'Category'}'.trim();
      out.add(
        IptvCategory(
          id: id,
          name: title.isEmpty ? 'Category' : title,
          kind: kind,
          sourceId: source.id,
          isAdult:
              truthyAdultFlag(row['censored']) ||
              truthyAdultFlag(row['adult']) ||
              truthyAdultFlag(row['is_adult']),
        ),
      );
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _fetchOrderedList(
    _StalkerSession session, {
    required String type,
    required String category,
    int maxItems = 2000,
  }) async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; all.length < maxItems; page++) {
      Map<String, dynamic> data;
      try {
        data = await _portalFetchRetry(session, {
          'type': type,
          'action': 'get_ordered_list',
          'category': category,
          'page': '$page',
          'p': '$page',
        }, timeout: const Duration(seconds: 25));
      } catch (_) {
        break;
      }
      final js = data['js'];
      if (js is! Map) break;
      final items = js['data'];
      if (items is! List || items.isEmpty) break;
      for (final raw in items.whereType<Map>()) {
        all.add(Map<String, dynamic>.from(raw));
      }
      final declaredTotal =
          int.tryParse('${js['total_items'] ?? js['results_num'] ?? 0}') ?? 0;
      if (declaredTotal > 0 && all.length >= declaredTotal) break;
      final declaredPages =
          int.tryParse('${js['total_pages'] ?? js['pages_count'] ?? 0}') ?? 0;
      if (declaredPages > 0 && page >= declaredPages) break;
    }
    return all;
  }

  MediaItem? _mapVod(
    IptvSource source,
    Map<String, dynamic> row,
    String group, {
    bool categoryAdult = false,
  }) {
    final id = '${row['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final name = '${row['name'] ?? 'Movie'}'.trim();
    final cmd = '${row['cmd'] ?? ''}'.trim();
    final logo = _firstNonEmpty([
      row['screenshot_uri'],
      row['cover'],
      row['logo'],
    ]);
    return MediaItem(
      id: 'stalker-vod-${source.id}-$id',
      title: name.isEmpty ? 'Movie' : name,
      playUrl: cmd,
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvStalker,
      subtitle: group,
      thumbnailUrl: logo,
      posterUrl: logo,
      group: group,
      streamId: id,
      sourceId: source.id,
      rating: double.tryParse('${row['rating_imdb'] ?? row['rating'] ?? ''}'),
      year: int.tryParse('${row['year'] ?? ''}'),
      isAdult:
          categoryAdult ||
          truthyAdultFlag(row['censored']) ||
          truthyAdultFlag(row['adult']) ||
          truthyAdultFlag(row['is_adult']),
    );
  }

  MediaItem? _mapSeries(
    IptvSource source,
    Map<String, dynamic> row,
    String group, {
    bool categoryAdult = false,
  }) {
    final id = '${row['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final name = '${row['name'] ?? 'Series'}'.trim();
    final logo = _firstNonEmpty([
      row['screenshot_uri'],
      row['cover'],
      row['logo'],
    ]);
    return MediaItem(
      id: 'stalker-series-${source.id}-$id',
      title: name.isEmpty ? 'Series' : name,
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.iptvStalker,
      subtitle: ['Series', group].join(' · '),
      thumbnailUrl: logo,
      posterUrl: logo,
      group: group,
      streamId: id,
      sourceId: source.id,
      rating: double.tryParse('${row['rating_imdb'] ?? row['rating'] ?? ''}'),
      year: int.tryParse('${row['year'] ?? ''}'),
      isAdult:
          categoryAdult ||
          truthyAdultFlag(row['censored']) ||
          truthyAdultFlag(row['adult']) ||
          truthyAdultFlag(row['is_adult']),
    );
  }

  /// Seasons + episodes for a series (episode [SeriesEpisode.playUrl] holds cmd).
  Future<SeriesInfo> fetchSeriesInfo(
    IptvSource source, {
    required String seriesId,
  }) async {
    final session = await _getSession(source);
    final movieId = seriesId.split(':').first;
    final data = await _portalFetchRetry(session, {
      'type': 'series',
      'action': 'get_ordered_list',
      'movie_id': movieId,
      'page': '1',
      'p': '1',
    });
    final js = data['js'];
    final rawSeasons = js is Map && js['data'] is List
        ? js['data'] as List
        : const [];

    final seasons = <SeriesSeason>[];
    var seasonNumber = 0;
    for (final raw in rawSeasons.whereType<Map>()) {
      seasonNumber += 1;
      final row = Map<String, dynamic>.from(raw);
      final seasonId = '${row['id'] ?? seasonNumber}'.trim();
      final name = '${row['name'] ?? 'Season $seasonNumber'}'.trim();
      final cmd = '${row['cmd'] ?? ''}'.trim();
      final logo = _firstNonEmpty([
        row['screenshot_uri'],
        row['cover'],
        row['logo'],
      ]);
      final episodeNums = row['series'];
      final episodes = <SeriesEpisode>[];
      if (episodeNums is List) {
        for (final n in episodeNums) {
          final ep = int.tryParse('$n') ?? 0;
          if (ep <= 0) continue;
          episodes.add(
            SeriesEpisode(
              id: '$seasonId:$ep',
              episodeNum: ep,
              seasonNumber: seasonNumber,
              title: 'Episode $ep',
              containerExtension: 'ts',
              // Season cmd — resolved via create_link with series=episodeNum.
              playUrl: cmd,
              thumbnailUrl: logo,
            ),
          );
        }
      }
      seasons.add(
        SeriesSeason(
          seasonNumber: seasonNumber,
          name: name.isEmpty ? 'Season $seasonNumber' : name,
          coverUrl: logo,
          episodes: episodes,
        ),
      );
    }

    return SeriesInfo(seriesId: seriesId, title: source.name, seasons: seasons);
  }

  /// Resolve a Stalker cmd to a playable HTTP(S) URL via `create_link`.
  ///
  /// [episode] is the Stalker series episode index (1-based) when playing a
  /// series episode; omit for live / VOD movies.
  Future<String> createLink(
    IptvSource source, {
    required String cmd,
    required bool isLive,
    int? episode,
  }) async {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) {
      throw Exception('Stalker stream command is empty — re-sync the source');
    }
    final session = await _getSession(source);
    final stalkerType = isLive ? 'itv' : 'vod';
    final params = <String, String>{
      'type': stalkerType,
      'action': 'create_link',
      'cmd': trimmed,
      'series': '${episode ?? 0}',
      'forced_storage': '0',
      'disable_ad': '0',
      'download': '0',
      'force_ch_link_check': '0',
    };
    final data = await _portalFetchRetry(session, params);
    final js = data['js'];
    if (js is! Map) throw Exception('No stream URL returned from portal');
    var streamUrl = '${js['cmd'] ?? ''}'.trim();
    if (streamUrl.isEmpty) {
      throw Exception('No stream URL returned from portal');
    }
    streamUrl = streamUrl
        .replaceFirst(RegExp(r'^ffmpeg\s+', caseSensitive: false), '')
        .trim();
    // Some portals return localhost — rewrite to the portal host.
    if (streamUrl.contains('localhost') || streamUrl.contains('127.0.0.1')) {
      try {
        final portalHost = Uri.parse(session.portal).host;
        if (portalHost.isNotEmpty) {
          streamUrl = streamUrl
              .replaceAll(RegExp(r'localhost(:\d+)?'), portalHost)
              .replaceAll(RegExp(r'127\.0\.0\.1(:\d+)?'), portalHost);
        }
      } catch (_) {}
    }
    if (!(streamUrl.startsWith('http://') ||
        streamUrl.startsWith('https://'))) {
      throw Exception('Portal returned a non-HTTP stream: $streamUrl');
    }
    return streamUrl;
  }

  static String? _firstNonEmpty(List<Object?> values) {
    for (final v in values) {
      final s = '$v'.trim();
      if (s.isNotEmpty && s != 'null') return s;
    }
    return null;
  }
}
