import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:javp/compat/javp_compute.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/catalog/catalog_client_gate.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/services/ads/vast_parser.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/metadata/external_ids.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:uuid/uuid.dart';

export 'catalog_client_gate.dart';

/// Bring-your-own catalog schema (v1 bulk dump + v2 query helpers).
class CustomCatalogClient {
  CustomCatalogClient({http.Client? httpClient, this.profile})
    : _injectedHttp = httpClient;

  static const _uuid = Uuid();
  final http.Client? _injectedHttp;
  http.Client? _ownedHttp;

  /// Running JAVP client (version / platform / capabilities). Isolates copy it.
  CatalogClientProfile? profile;

  /// Named `sources[]` gates from the last root fetch, keyed by catalog URL.
  final Map<String, Map<String, CatalogClientGate>> _namedSourcesByCatalogUrl =
      {};

  CatalogClientProfile? _parseProfile;
  Map<String, CatalogClientGate> _parseNamedSources = const {};
  Map<String, String> _inheritPlayHeaders = const {};

  /// Catalog-root playback headers (User-Agent / Referer / …) from the last
  /// root fetch, keyed by catalog URL. Applied to later `/search` / `/items`
  /// rows that omit their own `httpHeaders`.
  final Map<String, Map<String, String>> _playHeadersByCatalogUrl = {};

  /// Parsing runs on throwaway instances inside worker isolates, so the socket
  /// pool is only created if someone actually makes a request.
  http.Client get _http => _injectedHttp ?? (_ownedHttp ??= http.Client());

  /// Optional source token → `Authorization: Bearer …` for premium catalogs.
  ///
  /// If [token] already starts with `Bearer ` (any case), it is sent as-is.
  static Map<String, String>? authHeaders(String? token) {
    final raw = token?.trim() ?? '';
    if (raw.isEmpty) return null;
    final value = raw.toLowerCase().startsWith('bearer ') ? raw : 'Bearer $raw';
    return {'Authorization': value};
  }

  Map<String, CatalogClientGate> namedSourcesFor(String? catalogUrl) {
    final key = catalogUrl?.trim() ?? '';
    if (key.isEmpty) return _parseNamedSources;
    return _namedSourcesByCatalogUrl[key] ?? const {};
  }

  void rememberNamedSources(
    String catalogUrl,
    List<CatalogNamedSource> sources,
  ) {
    final key = catalogUrl.trim();
    if (key.isEmpty) return;
    if (sources.isEmpty) {
      _namedSourcesByCatalogUrl.remove(key);
      return;
    }
    _namedSourcesByCatalogUrl[key] = catalogNamedSourceGates(sources);
  }

  void rememberPlayHeaders(String catalogUrl, Map<String, String> headers) {
    final key = catalogUrl.trim();
    if (key.isEmpty) return;
    if (headers.isEmpty) {
      _playHeadersByCatalogUrl.remove(key);
      return;
    }
    _playHeadersByCatalogUrl[key] = Map<String, String>.from(headers);
  }

  Map<String, String> playHeadersFor(String? catalogUrl) {
    final key = catalogUrl?.trim() ?? '';
    if (key.isEmpty) return const {};
    return _playHeadersByCatalogUrl[key] ?? const {};
  }

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    final hinted = _withClientQuery(uri);
    final merged = <String, String>{...?profile?.httpHeaders, ...?headers};
    if (merged.isEmpty) return _http.get(hinted);
    return _http.get(hinted, headers: merged);
  }

  Uri _withClientQuery(Uri uri) {
    final extra = profile?.queryParameters;
    if (extra == null || extra.isEmpty) return uri;
    // Append only missing keys onto the original query string so we do not
    // decode/re-encode an existing signed or tokenized query. Insert before
    // any #fragment so keys are not lost when clients strip the fragment.
    final existing = uri.queryParameters;
    final toAdd = <MapEntry<String, String>>[
      for (final e in extra.entries)
        if (!existing.containsKey(e.key)) e,
    ];
    if (toAdd.isEmpty) return uri;
    final encoded = toAdd
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final full = uri.toString();
    final hash = full.indexOf('#');
    final before = hash < 0 ? full : full.substring(0, hash);
    final after = hash < 0 ? '' : full.substring(hash);
    final sep = uri.hasQuery || before.contains('?') ? '&' : '?';
    return Uri.parse('$before$sep$encoded$after');
  }

  void _beginParse({
    CatalogClientProfile? profile,
    Map<String, CatalogClientGate>? namedSources,
    Map<String, String>? inheritPlayHeaders,
  }) {
    _parseProfile = profile ?? this.profile;
    _parseNamedSources = namedSources ?? const {};
    _inheritPlayHeaders = inheritPlayHeaders ?? const {};
  }

  /// True when this item / variant / episode may appear for [_parseProfile].
  bool _entryAllowed(
    Map<String, dynamic> map, {
    String? playUrl,
    String? inheritSourceKey,
  }) {
    final sourceKey = catalogSourceKeyFromJson(map) ?? inheritSourceKey;
    if (sourceKey != null) {
      final named = _parseNamedSources[sourceKey];
      if (named != null && !catalogClientAllows(named, _parseProfile)) {
        return false;
      }
    }
    if (!catalogClientAllows(CatalogClientGate.fromJson(map), _parseProfile)) {
      return false;
    }
    if (playUrl != null &&
        playUrl.isNotEmpty &&
        _parseProfile != null &&
        playUrlRequiresTorrents(playUrl) &&
        !_parseProfile!.hasCapability('torrents')) {
      return false;
    }
    return true;
  }

  CustomCatalogParseResult parse(
    String body, {
    required String sourceId,
    String? appVersion,
    CatalogClientProfile? profile,
    Map<String, CatalogClientGate>? namedSources,
  }) {
    final client = profile ?? this.profile;
    final effectiveVersion = appVersion ?? client?.appVersion;
    final decoded = jsonDecode(body);
    String? catalogName;
    var version = 1;
    var capabilities = const <String>[];
    int? itemCount;
    String? vastUrl;
    String? minVersion;
    String? epgUrl;
    var catalogSources = const <CatalogNamedSource>[];
    late final List<dynamic> rawItems;

    if (decoded is List) {
      _beginParse(profile: client, namedSources: namedSources);
      rawItems = decoded;
    } else if (decoded is Map<String, dynamic>) {
      catalogName = decoded['name'] as String?;
      version = (decoded['version'] as num?)?.toInt() ?? 1;
      capabilities = stringListFromJson(decoded['capabilities']);
      itemCount = (decoded['itemCount'] as num?)?.toInt();
      vastUrl = vastUrlFromJson(decoded);
      minVersion = catalogMinVersionFromJson(decoded);
      epgUrl = catalogEpgUrlFromJson(decoded);
      ensureCatalogMinVersion(
        minVersion: minVersion,
        appVersion: effectiveVersion,
      );
      ensureCatalogClientSupported(
        gate: CatalogClientGate.fromJson(decoded),
        profile: client,
      );
      catalogSources = catalogNamedSourcesFromJson(
        decoded['sources'] ?? decoded['catalogSources'],
      );
      final playHeaders = catalogPlaybackHeadersFromJson(decoded);
      _beginParse(
        profile: client,
        namedSources: namedSources ?? catalogNamedSourceGates(catalogSources),
        inheritPlayHeaders: playHeaders,
      );
      final items = decoded['items'] ?? decoded['entries'] ?? decoded['media'];
      if (items == null) {
        // v2 descriptor-only response (no items yet).
        return CustomCatalogParseResult(
          name: catalogName,
          version: version,
          minVersion: minVersion,
          capabilities: capabilities,
          itemCount: itemCount,
          vastUrl: vastUrl,
          epgUrl: epgUrl,
          namedSources: catalogSources,
          playHeaders: playHeaders,
          items: const [],
          details: const {},
        );
      }
      if (items is! List) {
        throw const FormatException(
          'Custom catalog JSON must include an "items" array '
          '(or be a top-level array).',
        );
      }
      rawItems = items;
    } else {
      throw const FormatException(
        'Custom catalog must be a JSON object or array.',
      );
    }

    final items = <MediaItem>[];
    final details = <String, MediaDetails>{};

    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final parsed = _parseItem(map, sourceId: sourceId);
      if (parsed == null) continue;
      items.addAll(parsed.items);
      details.addAll(parsed.details);
    }

    // Link flat episode rows into series details when seasons were not nested.
    _attachSiblingEpisodes(items, details);

    return CustomCatalogParseResult(
      name: catalogName,
      version: version,
      minVersion: minVersion,
      capabilities: capabilities,
      itemCount: itemCount ?? items.length,
      vastUrl: vastUrl,
      epgUrl: epgUrl,
      namedSources: catalogSources,
      playHeaders: _inheritPlayHeaders,
      items: items,
      details: details,
    );
  }

  /// Probe a catalog root URL for v1/v2 metadata.
  Future<CustomCatalogParseResult> fetchRoot(
    String catalogUrl, {
    required String sourceId,
    Map<String, String>? headers,
    String? appVersion,
    CatalogClientProfile? profile,
  }) async {
    final client = profile ?? this.profile;
    final uri = _withClientQuery(Uri.parse(catalogUrl));
    final request = http.Request('GET', uri);
    final merged = <String, String>{...?client?.httpHeaders, ...?headers};
    if (merged.isNotEmpty) request.headers.addAll(merged);
    final streamed = await _http.send(request);
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      throw Exception(
        'Catalog auth failed (${streamed.statusCode}) — check the access token',
      );
    }
    if (streamed.statusCode >= 400) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      throw Exception('Failed to fetch catalog (${streamed.statusCode})');
    }
    final bytes = await collectBytesYielding(
      streamed.stream,
      maxBytes: 64 * 1024 * 1024,
      tooLargeMessage: 'Catalog is too large',
    );
    JavpLog.i(
      'catalog',
      'fetchRoot status=${streamed.statusCode} bytes=${bytes.length} '
          'source=$sourceId',
    );
    final sid = sourceId;
    final ver = appVersion ?? client?.appVersion;
    final captured = client;
    // Bulk dumps can be multi‑MB — parse off the UI isolate and stream items
    // back in chunks (Isolate.run of the full result freezes Windows).
    final parsed = await parseCatalogBodyInIsolate(
      bytes,
      sourceId: sid,
      appVersion: ver,
      profile: captured,
    );
    rememberNamedSources(catalogUrl, parsed.namedSources);
    rememberPlayHeaders(catalogUrl, parsed.playHeaders);
    return parsed;
  }

  Future<CustomCatalogPage> search({
    required String baseUrl,
    required String sourceId,
    required String query,
    int page = 1,
    int limit = 50,
    String? locale,
    Map<String, String>? headers,
  }) async {
    final uri = _join(baseUrl, '/search').replace(
      queryParameters: {
        'q': query,
        'page': '$page',
        'limit': '$limit',
        ..._localeQuery(locale),
      },
    );
    final response = await _get(uri, headers: headers);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'Catalog auth failed (${response.statusCode}) — check the access token',
      );
    }
    if (response.statusCode == 404) {
      // Simple / misconfigured catalogs often lack `/search`. Callers should
      // prefer [CustomCatalogParseResult.supportsSearch] and fall back to the
      // on-device cache; this typed miss avoids stack spam when still attempted.
      throw const CatalogSearchUnsupportedException();
    }
    if (response.statusCode >= 400) {
      throw Exception('Catalog search failed (${response.statusCode})');
    }
    return _parsePageAsync(
      response.body,
      sourceId: sourceId,
      query: query,
      catalogUrl: baseUrl,
    );
  }

  Future<CustomCatalogPage> browse({
    required String baseUrl,
    required String sourceId,
    String? group,
    int page = 1,
    int limit = 50,
    String? locale,
    Map<String, String>? headers,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'limit': '$limit',
      if (group != null && group.isNotEmpty) 'group': group,
      ..._localeQuery(locale),
    };
    final uri = _join(baseUrl, '/browse').replace(queryParameters: params);
    final response = await _get(uri, headers: headers);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'Catalog auth failed (${response.statusCode}) — check the access token',
      );
    }
    if (response.statusCode >= 400) {
      throw Exception('Catalog browse failed (${response.statusCode})');
    }
    return _parsePageAsync(
      response.body,
      sourceId: sourceId,
      catalogUrl: baseUrl,
    );
  }

  /// Single title / progressive episode resolve: `GET /items/{id}?locale=`.
  ///
  /// [locale] is the app or device language code (e.g. `fr`) so bridges can
  /// prefer matching audio / release groups when filling `playUrl`.
  Future<CustomCatalogItemResult?> fetchItem({
    required String baseUrl,
    required String sourceId,
    required String id,
    String? locale,
    Map<String, String>? headers,
  }) async {
    var uri = _join(baseUrl, '/items/${Uri.encodeComponent(id)}');
    final localeParams = _localeQuery(locale);
    if (localeParams.isNotEmpty) {
      uri = uri.replace(queryParameters: localeParams);
    }
    final response = await _get(uri, headers: headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'Catalog auth failed (${response.statusCode}) — check the access token',
      );
    }
    if (response.statusCode >= 400) {
      throw Exception(catalogHttpError('item', response));
    }
    final decoded = jsonDecode(response.body);
    final map = decoded is Map<String, dynamic>
        ? decoded
        : decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : null;
    if (map == null) return null;
    final itemMap = map['item'] is Map
        ? Map<String, dynamic>.from(map['item'] as Map)
        : map;
    final catalogError =
        catalogErrorMessage(map) ?? catalogErrorMessage(itemMap);
    _beginParse(
      profile: profile,
      namedSources: namedSourcesFor(baseUrl),
      inheritPlayHeaders: mergePlaybackHeaders(
        playHeadersFor(baseUrl),
        catalogPlaybackHeadersFromJson(map),
      ),
    );
    final parsed = _parseItem(itemMap, sourceId: sourceId);
    if (parsed == null || parsed.items.isEmpty) {
      if (catalogError != null) throw Exception(catalogError);
      return null;
    }
    return CustomCatalogItemResult(
      item: parsed.items.first,
      details: parsed.details[parsed.items.first.id],
      allItems: parsed.items,
      detailsById: parsed.details,
    );
  }

  /// Lazy episode list: `GET /items/{id}/episodes?season=&locale=&resolve=&limit=&offset=`.
  ///
  /// Returns an empty list when the bridge does not implement the endpoint
  /// (404). Flexible response shapes: `{episodes}`, `{seasons}`, or a bare
  /// episode array.
  ///
  /// When [resolve] is true, bridges may fill `playUrl` / `playVariants` in one
  /// RTT (hard-capped at [maxResolveLimit] episodes). Prefer stubs first, then
  /// an opt-in resolve for short cours — never unbounded long-running series–scale fills.
  static const maxResolveLimit = 24;

  Future<List<SeriesSeasonDetails>> fetchEpisodes({
    required String baseUrl,
    required String id,
    int? season,
    String? locale,
    bool resolve = false,
    int? limit,
    int offset = 0,
    Map<String, String>? headers,
  }) async {
    var uri = _join(baseUrl, '/items/${Uri.encodeComponent(id)}/episodes');
    final params = <String, String>{
      if (season != null) 'season': '$season',
      ..._localeQuery(locale),
      if (resolve) 'resolve': '1',
      if (resolve || limit != null)
        'limit': '${(limit ?? maxResolveLimit).clamp(1, maxResolveLimit)}',
      if (offset > 0) 'offset': '$offset',
    };
    if (params.isNotEmpty) {
      uri = uri.replace(queryParameters: params);
    }
    final response = await _get(uri, headers: headers);
    if (response.statusCode == 404) return const [];
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'Catalog auth failed (${response.statusCode}) — check the access token',
      );
    }
    if (response.statusCode >= 400) {
      throw Exception(catalogHttpError('episodes', response));
    }
    final decoded = jsonDecode(response.body);
    _beginParse(
      profile: profile,
      namedSources: namedSourcesFor(baseUrl),
      inheritPlayHeaders: playHeadersFor(baseUrl),
    );
    if (decoded is List) {
      final episodes = _parseEpisodeList(
        decoded,
        seriesId: id,
        seasonNumber: season ?? 1,
      );
      if (episodes.isEmpty) return const [];
      return [
        SeriesSeasonDetails(
          seasonNumber: season ?? 1,
          name: 'Season ${season ?? 1}',
          episodes: episodes,
        ),
      ];
    }
    if (decoded is! Map) return const [];
    final map = Map<String, dynamic>.from(decoded);
    _inheritPlayHeaders = mergePlaybackHeaders(
      playHeadersFor(baseUrl),
      catalogPlaybackHeadersFromJson(map),
    );
    if (map['seasons'] != null) {
      return _parseSeasons(map['seasons'], seriesId: id);
    }
    final seasonNumber =
        (map['season'] as num?)?.toInt() ??
        (map['seasonNumber'] as num?)?.toInt() ??
        season ??
        1;
    final raw = map['episodes'] ?? map['items'] ?? map['entries'];
    if (raw is! List) return const [];
    final episodes = _parseEpisodeList(
      raw,
      seriesId: id,
      seasonNumber: seasonNumber,
    );
    if (episodes.isEmpty) return const [];
    return [
      SeriesSeasonDetails(
        seasonNumber: seasonNumber,
        name: (map['name'] as String?)?.trim() ?? 'Season $seasonNumber',
        episodes: episodes,
      ),
    ];
  }

  Future<List<CustomCatalogGroup>> fetchGroups({
    required String baseUrl,
    Map<String, String>? headers,
  }) async {
    final uri = _join(baseUrl, '/groups');
    final response = await _get(uri, headers: headers);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'Catalog auth failed (${response.statusCode}) — check the access token',
      );
    }
    if (response.statusCode >= 400) {
      throw Exception('Catalog groups failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    final list = decoded is Map
        ? (decoded['groups'] as List? ?? const [])
        : decoded is List
        ? decoded
        : const [];
    return list
        .whereType<Map>()
        .map((e) {
          final map = Map<String, dynamic>.from(e);
          return CustomCatalogGroup(
            id: '${map['id'] ?? map['name'] ?? ''}',
            name: '${map['name'] ?? map['id'] ?? ''}',
            count: (map['count'] as num?)?.toInt(),
          );
        })
        .where((g) => g.id.isNotEmpty)
        .toList();
  }

  /// Bridges are free to return large pages; anything sizeable is decoded and
  /// built on a worker so browse/search never stalls a frame.
  Future<CustomCatalogPage> _parsePageAsync(
    String body, {
    required String sourceId,
    String? query,
    String? catalogUrl,
  }) {
    final capturedProfile = profile;
    final named = namedSourcesFor(catalogUrl);
    final inherit = playHeadersFor(catalogUrl);
    if (body.length < 64 * 1024) {
      return Future.value(
        CustomCatalogClient(profile: capturedProfile)._parsePage(
          body,
          sourceId: sourceId,
          query: query,
          namedSources: named,
          inheritPlayHeaders: inherit,
        ),
      );
    }
    return javpCompute(
      () => CustomCatalogClient(profile: capturedProfile)._parsePage(
        body,
        sourceId: sourceId,
        query: query,
        namedSources: named,
        inheritPlayHeaders: inherit,
      ),
    );
  }

  CustomCatalogPage _parsePage(
    String body, {
    required String sourceId,
    String? query,
    Map<String, CatalogClientGate>? namedSources,
    Map<String, String>? inheritPlayHeaders,
  }) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Catalog page must be a JSON object');
    }
    final map = Map<String, dynamic>.from(decoded);
    _beginParse(
      profile: profile,
      namedSources: namedSources,
      inheritPlayHeaders: mergePlaybackHeaders(
        inheritPlayHeaders ?? const {},
        catalogPlaybackHeadersFromJson(map),
      ),
    );
    final rawItems = map['items'] ?? map['entries'] ?? map['media'] ?? const [];
    if (rawItems is! List) {
      throw const FormatException('Catalog page missing items array');
    }
    final items = <MediaItem>[];
    final details = <String, MediaDetails>{};
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final parsed = _parseItem(
        Map<String, dynamic>.from(entry),
        sourceId: sourceId,
      );
      if (parsed == null) continue;
      items.addAll(parsed.items);
      details.addAll(parsed.details);
    }
    return CustomCatalogPage(
      query: query ?? map['query'] as String?,
      page: (map['page'] as num?)?.toInt() ?? 1,
      limit: (map['limit'] as num?)?.toInt() ?? items.length,
      total: (map['total'] as num?)?.toInt() ?? items.length,
      items: items,
      details: details,
    );
  }

  _ParsedEntry? _parseItem(
    Map<String, dynamic> map, {
    required String sourceId,
  }) {
    final title = (map['title'] as String?)?.trim();
    if (title == null || title.isEmpty) return null;

    final kindName = (map['kind'] as String?)?.trim().toLowerCase() ?? 'vod';
    final kind = MediaKind.values.asNameMap()[kindName] ?? MediaKind.vod;
    final playUrl =
        (map['playUrl'] as String?)?.trim() ??
        (map['url'] as String?)?.trim() ??
        (map['streamUrl'] as String?)?.trim() ??
        '';

    // Series shells may omit playUrl; everything else needs one (or variants).
    final variantsRaw = map['playVariants'] ?? map['variants'];
    final hasVariants = variantsRaw is List && variantsRaw.isNotEmpty;
    if (kind != MediaKind.series && playUrl.isEmpty && !hasVariants) {
      return null;
    }

    final itemSourceKey = catalogSourceKeyFromJson(map);
    if (kind == MediaKind.series) {
      if (!_entryAllowed(map, inheritSourceKey: itemSourceKey)) return null;
    } else if (!hasVariants) {
      if (!_entryAllowed(
        map,
        playUrl: playUrl,
        inheritSourceKey: itemSourceKey,
      )) {
        return null;
      }
    } else if (!_entryAllowed(map, inheritSourceKey: itemSourceKey)) {
      return null;
    }

    final id = (map['id'] as String?)?.trim().isNotEmpty == true
        ? map['id'] as String
        : _uuid.v4();
    final durationMs = (map['durationMs'] as num?)?.toInt();
    final poster =
        map['posterUrl'] as String? ??
        map['poster'] as String? ??
        map['thumbnailUrl'] as String?;
    final genres = stringListFromJson(map['genres']);
    final audioLanguages = stringListFromJson(
      map['audioLanguages'] ?? map['audio'] ?? map['audioLangs'],
    );
    final subtitleLanguages = stringListFromJson(
      map['subtitleLanguages'] ??
          map['subLanguages'] ??
          map['subtitleLangs'] ??
          map['subs'],
    );
    final subtitles = subtitlesFromJson(
      map['subtitles'] ?? map['externalSubtitles'],
    );
    final audioTracks = audioTracksFromJson(
      map['audioTracks'] ?? map['externalAudio'] ?? map['audioFiles'],
    );
    final headers = Map<String, String>.from(
      catalogPlaybackHeadersFromJson(map, inherit: _inheritPlayHeaders),
    );
    final drmKind = drmKindFromCatalogJson(map);
    if (drmKind != null) {
      headers.addAll(drmHintHeadersFor(drmKind));
    }
    final segments = segmentsFromJson(map['segments']);
    final tags = stringListFromJson(map['tags']);
    final vastUrl = vastUrlFromJson(map, allowEmpty: true);
    final cast = _parseCast(map['cast']);
    final seasons = _parseSeasons(
      map['seasons'],
      seriesId: id,
      inheritPlayHeaders: headers,
    );
    final trailerUrl =
        (map['trailerUrl'] as String?)?.trim() ??
        (map['trailer'] as String?)?.trim();
    final trailerKey =
        (map['trailerKey'] as String?)?.trim() ??
        (map['youtubeTrailer'] as String?)?.trim();
    final seriesId =
        (map['seriesId'] as String?)?.trim() ??
        (map['parentId'] as String?)?.trim();
    final year = (map['year'] as num?)?.toInt();
    final releaseDate = (map['releaseDate'] as String?)?.trim();
    final anilistId = _anilistIdFrom(map, id);
    final torrentFile =
        (map['torrentFile'] as String?)?.trim() ??
        (map['fileHint'] as String?)?.trim();
    final tmdbId = _tmdbIdFrom(
      map,
      id: id,
      tags: tags,
      title: title,
      playUrl: playUrl,
      posterUrl: poster,
    );
    final imdbId = ExternalIds.imdbFromMap(
      map,
      id: id,
      tags: tags,
      title: title,
    );
    final tvdbId = (map['tvdbId'] as num?)?.toInt();
    final plot = map['plot'] as String? ?? map['description'] as String?;
    final contentRating =
        (map['contentRating'] as String?)?.trim() ??
        (map['certification'] as String?)?.trim();
    final isAdult = resolveIsAdult(
      flag: map['adult'] ?? map['isAdult'] ?? map['is_adult'],
      contentRating: contentRating,
      genres: genres,
      tags: tags,
    );
    final studio =
        (map['studio'] as String?)?.trim() ??
        (map['network'] as String?)?.trim();
    final originalTitle = (map['originalTitle'] as String?)?.trim();
    final thumbnail =
        map['thumbnailUrl'] as String? ??
        map['poster'] as String? ??
        map['still'] as String? ??
        map['stillUrl'] as String? ??
        map['image'] as String? ??
        map['imageUrl'] as String? ??
        map['logo'] as String?;
    final backdrop =
        map['backdropUrl'] as String? ?? map['backdrop'] as String?;
    final group = map['group'] as String? ?? map['category'] as String?;
    final rating = (map['rating'] as num?)?.toDouble();
    final popularity = parseCatalogItemPopularity(map);

    // Series contract: episode UI comes only from seasons[] / seriesId rows.
    // Shell playUrl / playVariants must not replace the shell or act as episodes.
    if (kind == MediaKind.series) {
      final shell = MediaItem(
        id: id,
        title: title,
        playUrl: '',
        kind: MediaKind.series,
        origin: MediaOrigin.customCatalog,
        subtitle: map['subtitle'] as String?,
        thumbnailUrl: thumbnail,
        posterUrl: poster,
        backdropUrl: backdrop,
        group: group,
        streamId: map['streamId'] as String? ?? id,
        sourceId: sourceId,
        tmdbId: tmdbId,
        anilistId: anilistId,
        imdbId: imdbId,
        tvdbId: tvdbId,
        plot: plot,
        genres: genres,
        rating: rating,
        popularity: popularity,
        year: year,
        audioLanguages: audioLanguages,
        subtitleLanguages: subtitleLanguages,
        trailerUrl: trailerUrl,
        contentRating: contentRating,
        isAdult: isAdult,
        studio: studio,
        originalTitle: originalTitle,
        releaseDate: releaseDate,
        tags: tags,
        updatedAt: map['updatedAt'] == null
            ? null
            : DateTime.tryParse('${map['updatedAt']}'),
        vastUrl: vastUrl,
        httpHeaders: headers,
      );
      final details = <String, MediaDetails>{
        id: MediaDetails(
          id: id,
          title: title,
          mediaItemId: id,
          tmdbId: tmdbId,
          anilistId: anilistId,
          imdbId: imdbId,
          tvdbId: tvdbId,
          plot: plot,
          posterUrl: poster ?? thumbnail,
          backdropUrl: backdrop,
          genres: genres,
          rating: rating,
          year: year,
          cast: cast,
          trailerUrl: trailerUrl,
          trailerKey: trailerKey,
          seasons: seasons,
          tags: tags,
          contentRating: contentRating,
          studio: studio,
          originalTitle: originalTitle,
          releaseDate: releaseDate,
          updatedAt: shell.updatedAt ?? DateTime.now(),
        ),
      };
      return _ParsedEntry(items: [shell], details: details);
    }

    MediaItem buildRow({
      required String rowId,
      required String rowTitle,
      required String rowPlayUrl,
      String? label,
      String? resolution,
      String? videoCodec,
      String? audioCodec,
      String? hdr,
      Map<String, String>? extraHeaders,
      String? rowTorrentFile,
      List<String>? rowAudioLanguages,
      List<String>? rowSubtitleLanguages,
      List<ExternalSubtitle>? rowSubtitles,
      List<ExternalAudio>? rowAudioTracks,
    }) {
      return MediaItem(
        id: rowId,
        title: rowTitle,
        playUrl: rowPlayUrl,
        kind: kind,
        origin: MediaOrigin.customCatalog,
        subtitle: label ?? map['subtitle'] as String?,
        thumbnailUrl: thumbnail,
        posterUrl: poster,
        backdropUrl: backdrop,
        group: group,
        duration: durationMs == null
            ? null
            : Duration(milliseconds: durationMs),
        channelId: map['channelId'] as String?,
        streamId: map['streamId'] as String?,
        epgChannelId: map['epgChannelId'] as String?,
        catchupDays: (map['catchupDays'] as num?)?.toInt() ?? 0,
        sourceId: sourceId,
        tmdbId: tmdbId,
        anilistId: anilistId,
        imdbId: imdbId,
        tvdbId: tvdbId,
        plot: plot,
        genres: genres,
        rating: rating,
        popularity: popularity,
        year: year,
        seasonNumber:
            (map['seasonNumber'] as num?)?.toInt() ??
            (map['season'] as num?)?.toInt(),
        episodeNumber:
            (map['episodeNumber'] as num?)?.toInt() ??
            (map['episode'] as num?)?.toInt(),
        seriesId: seriesId,
        torrentFile: rowTorrentFile ?? torrentFile,
        audioLanguages: rowAudioLanguages ?? audioLanguages,
        subtitleLanguages: rowSubtitleLanguages ?? subtitleLanguages,
        subtitles: rowSubtitles ?? subtitles,
        audioTracks: rowAudioTracks ?? audioTracks,
        httpHeaders: {...headers, ...?extraHeaders},
        segments: segments,
        trailerUrl: trailerUrl,
        contentRating: contentRating,
        isAdult: isAdult,
        studio: studio,
        originalTitle: originalTitle,
        releaseDate: releaseDate,
        tags: tags,
        resolution: resolution ?? (map['resolution'] as String?)?.trim(),
        videoCodec: videoCodec ?? (map['videoCodec'] as String?)?.trim(),
        audioCodec: audioCodec ?? (map['audioCodec'] as String?)?.trim(),
        hdr: hdr ?? (map['hdr'] as String?)?.trim(),
        updatedAt: map['updatedAt'] == null
            ? null
            : DateTime.tryParse('${map['updatedAt']}'),
        vastUrl: vastUrl,
      );
    }

    final items = <MediaItem>[];
    final details = <String, MediaDetails>{};

    if (variantsRaw is List && variantsRaw.isNotEmpty) {
      for (var i = 0; i < variantsRaw.length; i++) {
        final v = variantsRaw[i];
        if (v is String && v.trim().isNotEmpty) {
          if (!_entryAllowed(
            map,
            playUrl: v.trim(),
            inheritSourceKey: itemSourceKey,
          )) {
            continue;
          }
          _addOrMergeCatalogRow(
            items,
            buildRow(
              rowId: '$id-v$i',
              rowTitle: title,
              rowPlayUrl: v.trim(),
              label: map['subtitle'] as String?,
            ),
          );
          continue;
        }
        if (v is! Map) continue;
        final vm = Map<String, dynamic>.from(v);
        final vUrl =
            (vm['playUrl'] as String?)?.trim() ??
            (vm['url'] as String?)?.trim() ??
            '';
        if (vUrl.isEmpty) continue;
        if (!_entryAllowed(
          vm,
          playUrl: vUrl,
          inheritSourceKey: itemSourceKey,
        )) {
          continue;
        }
        final vId = (vm['id'] as String?)?.trim().isNotEmpty == true
            ? vm['id'] as String
            : '$id-v$i';
        final vLabel =
            (vm['label'] as String?)?.trim() ??
            (vm['title'] as String?)?.trim() ??
            (vm['name'] as String?)?.trim() ??
            (vm['resolution'] as String?)?.trim();
        final vAudio = stringListFromJson(
          vm['audioLanguages'] ?? vm['audio'] ?? vm['audioLangs'],
        );
        final vSubs = stringListFromJson(
          vm['subtitleLanguages'] ??
              vm['subLanguages'] ??
              vm['subtitleLangs'] ??
              vm['subs'],
        );
        final vExtSubs = subtitlesFromJson(
          vm['subtitles'] ?? vm['externalSubtitles'],
        );
        final vExtAudio = audioTracksFromJson(
          vm['audioTracks'] ?? vm['externalAudio'] ?? vm['audioFiles'],
        );
        _addOrMergeCatalogRow(
          items,
          buildRow(
            rowId: vId,
            rowTitle: title,
            rowPlayUrl: vUrl,
            label: vLabel ?? map['subtitle'] as String?,
            resolution: (vm['resolution'] as String?)?.trim(),
            videoCodec: (vm['videoCodec'] as String?)?.trim(),
            audioCodec: (vm['audioCodec'] as String?)?.trim(),
            hdr: (vm['hdr'] as String?)?.trim(),
            extraHeaders: () {
              final extra = catalogPlaybackHeadersFromJson(vm);
              final variantDrm = drmKindFromCatalogJson(vm);
              if (variantDrm != null) {
                extra.addAll(drmHintHeadersFor(variantDrm));
              }
              return extra;
            }(),
            rowTorrentFile:
                (vm['torrentFile'] as String?)?.trim() ??
                (vm['fileHint'] as String?)?.trim(),
            rowAudioLanguages: vAudio.isNotEmpty ? vAudio : null,
            rowSubtitleLanguages: vSubs.isNotEmpty ? vSubs : null,
            rowSubtitles: vExtSubs.isNotEmpty ? vExtSubs : null,
            rowAudioTracks: vExtAudio.isNotEmpty ? vExtAudio : null,
          ),
        );
      }
      if (items.isEmpty &&
          playUrl.isNotEmpty &&
          _entryAllowed(
            map,
            playUrl: playUrl,
            inheritSourceKey: itemSourceKey,
          )) {
        items.add(buildRow(rowId: id, rowTitle: title, rowPlayUrl: playUrl));
      }
    } else {
      items.add(buildRow(rowId: id, rowTitle: title, rowPlayUrl: playUrl));
    }

    if (items.isEmpty) return null;

    final primary = items.first;
    final needsDetails =
        cast.isNotEmpty ||
        seasons.isNotEmpty ||
        anilistId != null ||
        (trailerUrl != null && trailerUrl.isNotEmpty) ||
        (trailerKey != null && trailerKey.isNotEmpty) ||
        tags.isNotEmpty ||
        primary.plot != null ||
        primary.posterUrl != null ||
        primary.contentRating != null ||
        primary.studio != null ||
        primary.originalTitle != null;

    if (needsDetails) {
      details[primary.id] = MediaDetails(
        id: primary.id,
        title: primary.originalTitle?.isNotEmpty == true
            ? primary.title
            : primary.title,
        mediaItemId: primary.id,
        tmdbId: primary.tmdbId,
        anilistId: primary.anilistId,
        imdbId: primary.imdbId,
        tvdbId: primary.tvdbId,
        plot: primary.plot,
        posterUrl: primary.posterUrl ?? primary.thumbnailUrl,
        backdropUrl: primary.backdropUrl,
        genres: primary.genres,
        rating: primary.rating,
        year: primary.year,
        runtime: primary.duration,
        cast: cast,
        trailerUrl: trailerUrl,
        trailerKey: trailerKey,
        seasons: seasons,
        seasonNumber: primary.seasonNumber,
        episodeNumber: primary.episodeNumber,
        tags: tags,
        contentRating: primary.contentRating,
        studio: primary.studio,
        originalTitle: primary.originalTitle,
        releaseDate: releaseDate,
        updatedAt: primary.updatedAt ?? DateTime.now(),
      );
      // Mirror details onto variant siblings.
      for (final item in items.skip(1)) {
        details[item.id] = details[primary.id]!.copyWith(mediaItemId: item.id);
      }
    }

    return _ParsedEntry(items: items, details: details);
  }

  void _attachSiblingEpisodes(
    List<MediaItem> items,
    Map<String, MediaDetails> details,
  ) {
    final bySeries = <String, List<MediaItem>>{};
    for (final item in items) {
      final sid = item.seriesId;
      if (sid == null || sid.isEmpty) continue;
      if (item.kind == MediaKind.series) continue;
      bySeries.putIfAbsent(sid, () => []).add(item);
    }
    if (bySeries.isEmpty) return;

    for (final entry in bySeries.entries) {
      final seriesId = entry.key;
      final episodes = entry.value;
      final existing = details[seriesId];
      if (existing != null && existing.seasons.isNotEmpty) continue;

      final seasonMap = <int, List<SeriesEpisodeDetails>>{};
      for (final ep in episodes) {
        final sn = ep.seasonNumber ?? 1;
        seasonMap
            .putIfAbsent(sn, () => [])
            .add(
              SeriesEpisodeDetails(
                id: ep.id,
                episodeNumber: ep.episodeNumber ?? 0,
                seasonNumber: sn,
                title: ep.title,
                plot: ep.plot,
                thumbnailUrl: ep.artUrl,
                duration: ep.duration,
                playUrl: ep.playUrl,
                tmdbId: ep.tmdbId,
                torrentFile: ep.torrentFile,
                httpHeaders: ep.httpHeaders,
              ),
            );
      }
      final seasons =
          seasonMap.entries
              .map(
                (e) => SeriesSeasonDetails(
                  seasonNumber: e.key,
                  name: 'Season ${e.key}',
                  episodes: e.value
                    ..sort(
                      (a, b) => a.episodeNumber.compareTo(b.episodeNumber),
                    ),
                ),
              )
              .toList()
            ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

      final shell = items.cast<MediaItem?>().firstWhere(
        (m) => m?.id == seriesId || m?.streamId == seriesId,
        orElse: () => null,
      );
      details[seriesId] = MediaDetails(
        id: seriesId,
        title: shell?.title ?? existing?.title ?? seriesId,
        mediaItemId: shell?.id ?? seriesId,
        tmdbId: shell?.tmdbId ?? existing?.tmdbId,
        imdbId: shell?.imdbId ?? existing?.imdbId,
        plot: shell?.plot ?? existing?.plot,
        posterUrl: shell?.posterUrl ?? existing?.posterUrl,
        backdropUrl: shell?.backdropUrl ?? existing?.backdropUrl,
        genres: shell?.genres ?? existing?.genres ?? const [],
        rating: shell?.rating ?? existing?.rating,
        year: shell?.year ?? existing?.year,
        cast: existing?.cast ?? const [],
        trailerUrl: shell?.trailerUrl ?? existing?.trailerUrl,
        seasons: seasons,
        tags: shell?.tags ?? existing?.tags ?? const [],
        contentRating: shell?.contentRating ?? existing?.contentRating,
        studio: shell?.studio ?? existing?.studio,
        originalTitle: shell?.originalTitle ?? existing?.originalTitle,
        releaseDate: shell?.releaseDate ?? existing?.releaseDate,
        updatedAt: DateTime.now(),
      );
    }
  }

  static List<CastMember> _parseCast(Object? raw) {
    if (raw is! List) return const [];
    final out = <CastMember>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is String && entry.trim().isNotEmpty) {
        out.add(CastMember(name: entry.trim(), order: i));
        continue;
      }
      if (entry is Map) {
        final map = Map<String, dynamic>.from(entry);
        final name = (map['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) continue;
        out.add(
          CastMember(
            name: name,
            character:
                (map['character'] as String?)?.trim() ??
                (map['role'] as String?)?.trim(),
            profileUrl:
                (map['profileUrl'] as String?)?.trim() ??
                (map['image'] as String?)?.trim(),
            order: (map['order'] as num?)?.toInt() ?? i,
          ),
        );
      }
    }
    return out;
  }

  List<SeriesSeasonDetails> _parseSeasons(
    Object? raw, {
    required String seriesId,
    Map<String, String>? inheritPlayHeaders,
  }) {
    if (raw is! List) return const [];
    final out = <SeriesSeasonDetails>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final seasonNumber =
          (map['seasonNumber'] as num?)?.toInt() ??
          (map['season'] as num?)?.toInt() ??
          0;
      final episodesRaw = map['episodes'] ?? map['items'] ?? const [];
      final episodes = episodesRaw is List
          ? _parseEpisodeList(
              episodesRaw,
              seriesId: seriesId,
              seasonNumber: seasonNumber,
              inheritPlayHeaders: inheritPlayHeaders,
            )
          : const <SeriesEpisodeDetails>[];
      out.add(
        SeriesSeasonDetails(
          seasonNumber: seasonNumber,
          name: (map['name'] as String?)?.trim() ?? 'Season $seasonNumber',
          posterUrl: map['posterUrl'] as String? ?? map['poster'] as String?,
          episodes: episodes,
        ),
      );
    }
    return out;
  }

  List<SeriesEpisodeDetails> _parseEpisodeList(
    List<dynamic> raw, {
    required String seriesId,
    required int seasonNumber,
    Map<String, String>? inheritPlayHeaders,
  }) {
    final parentHeaders = inheritPlayHeaders ?? _inheritPlayHeaders;
    final episodes = <SeriesEpisodeDetails>[];
    for (final ep in raw) {
      if (ep is! Map) continue;
      final em = Map<String, dynamic>.from(ep);
      if (!_entryAllowed(em)) continue;
      final epSourceKey = catalogSourceKeyFromJson(em);
      final epHeaders = catalogPlaybackHeadersFromJson(
        em,
        inherit: parentHeaders,
      );
      final epNum =
          (em['episodeNumber'] as num?)?.toInt() ??
          (em['episode'] as num?)?.toInt() ??
          0;
      final sn =
          (em['seasonNumber'] as num?)?.toInt() ??
          (em['season'] as num?)?.toInt() ??
          seasonNumber;
      final epId = (em['id'] as String?)?.trim().isNotEmpty == true
          ? em['id'] as String
          : '$seriesId-s${sn}e$epNum';
      final epTitle = (em['title'] as String?)?.trim() ?? 'Episode $epNum';
      final durationMs = (em['durationMs'] as num?)?.toInt();
      final variantsRaw = em['playVariants'] ?? em['variants'];
      final variants = <EpisodePlayVariant>[];
      if (variantsRaw is List) {
        for (var i = 0; i < variantsRaw.length; i++) {
          final entry = variantsRaw[i];
          if (entry is String && entry.trim().isNotEmpty) {
            if (!_entryAllowed(
              em,
              playUrl: entry.trim(),
              inheritSourceKey: epSourceKey,
            )) {
              continue;
            }
            variants.add(
              EpisodePlayVariant(
                id: '$epId-v$i',
                label: 'Version ${i + 1}',
                playUrl: entry.trim(),
                httpHeaders: epHeaders,
              ),
            );
            continue;
          }
          if (entry is! Map) continue;
          final vm = Map<String, dynamic>.from(entry);
          final v = EpisodePlayVariant.fromJson(vm);
          if (v.playUrl.isEmpty) continue;
          if (!_entryAllowed(
            vm,
            playUrl: v.playUrl,
            inheritSourceKey: epSourceKey,
          )) {
            continue;
          }
          final variantHeaders = catalogPlaybackHeadersFromJson(
            vm,
            inherit: epHeaders,
          );
          variants.add(
            EpisodePlayVariant(
              id: v.id.isNotEmpty ? v.id : '$epId-v$i',
              label: v.label,
              playUrl: v.playUrl,
              subtitle: v.subtitle,
              resolution: v.resolution,
              videoCodec: v.videoCodec,
              audioCodec: v.audioCodec,
              hdr: v.hdr,
              torrentFile: v.torrentFile,
              audioLanguages: v.audioLanguages,
              subtitleLanguages: v.subtitleLanguages,
              httpHeaders: variantHeaders,
            ),
          );
        }
      }
      final playVariants = VodGrouping.collapseEpisodeVariantsByStream(
        variants,
      );
      var primaryUrl =
          (em['playUrl'] as String?)?.trim() ?? (em['url'] as String?)?.trim();
      final hadPlayable =
          (primaryUrl != null && primaryUrl.isNotEmpty) || variantsRaw is List;
      if (primaryUrl != null &&
          primaryUrl.isNotEmpty &&
          !_entryAllowed(
            em,
            playUrl: primaryUrl,
            inheritSourceKey: epSourceKey,
          )) {
        primaryUrl = null;
      }
      primaryUrl ??= playVariants.isNotEmpty
          ? playVariants.first.playUrl
          : null;
      if (hadPlayable &&
          (primaryUrl == null || primaryUrl.isEmpty) &&
          playVariants.isEmpty) {
        continue;
      }
      episodes.add(
        SeriesEpisodeDetails(
          id: epId,
          episodeNumber: epNum,
          seasonNumber: sn,
          title: epTitle,
          plot: em['plot'] as String? ?? em['description'] as String?,
          thumbnailUrl: _episodeThumbnailUrl(em),
          duration: durationMs == null
              ? null
              : Duration(milliseconds: durationMs),
          airDate: SeriesEpisode.parseAirDate(
            em['airDate'] ?? em['releaseDate'] ?? em['air_date'],
          ),
          playUrl: primaryUrl,
          tmdbId: ExternalIds.tmdbFromMap(em),
          torrentFile:
              (em['torrentFile'] as String?)?.trim() ??
              (em['fileHint'] as String?)?.trim() ??
              (playVariants.isNotEmpty ? playVariants.first.torrentFile : null),
          resolution:
              (em['resolution'] as String?)?.trim() ??
              (playVariants.isNotEmpty ? playVariants.first.resolution : null),
          playVariants: playVariants,
          httpHeaders: epHeaders,
        ),
      );
    }
    return episodes;
  }

  /// Same HLS / file URL listed twice in `playVariants` is one encode.
  static void _addOrMergeCatalogRow(List<MediaItem> items, MediaItem row) {
    final key = VodGrouping.streamIdentity(row);
    if (key != null) {
      for (var i = 0; i < items.length; i++) {
        if (VodGrouping.streamIdentity(items[i]) == key) {
          items[i] = VodGrouping.mergeSameStreamEditions(items[i], row);
          return;
        }
      }
    }
    items.add(row);
  }

  /// Per-episode still / poster from a nested or `/items` row.
  static String? _episodeThumbnailUrl(Map<String, dynamic> em) {
    for (final key in const [
      'thumbnailUrl',
      'poster',
      'posterUrl',
      'still',
      'stillUrl',
      'image',
      'imageUrl',
      'logo',
    ]) {
      final v = (em[key] as String?)?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Builds `/search`, `/browse`, `/items/…` under a catalog descriptor URL.
  ///
  /// Exposed for unit tests (URL joining is easy to get wrong with [Uri.resolve]).
  Uri resolveEndpoint(String catalogUrl, String path) =>
      _join(catalogUrl, path);

  /// Optional `locale` query (BCP-47 language tag / language code, e.g. `fr`).
  static Map<String, String> _localeQuery(String? locale) {
    final tag = locale?.trim() ?? '';
    if (tag.isEmpty) return const {};
    return {'locale': tag};
  }

  Uri _join(String baseUrl, String path) {
    final base = Uri.parse(baseUrl.trim());
    final rel = path.startsWith('/') ? path.substring(1) : path;

    var rootPath = base.path;
    // Descriptor URL ends with /catalog → API routes live on the parent.
    if (rootPath.endsWith('/catalog') || rootPath.endsWith('/catalog/')) {
      rootPath = rootPath.replaceFirst(RegExp(r'/catalog/?$'), '');
    } else if (RegExp(
      r'\.(json|js)$',
      caseSensitive: false,
    ).hasMatch(rootPath)) {
      // …/library.json → parent directory for /search, /browse, …
      rootPath = rootPath.replaceAll(RegExp(r'/[^/]+$'), '');
    }

    // Directory form so Uri.resolve *appends* instead of replacing the last
    // segment (`…/catalog` + `search` → `…/search` without the trailing slash).
    if (rootPath.isEmpty) rootPath = '/';
    if (!rootPath.endsWith('/')) rootPath = '$rootPath/';

    return base.replace(path: rootPath, query: '', fragment: '').resolve(rel);
  }
}

/// Catalog-local heat from an item map. Higher = hotter. Any non-negative
/// scale. Optional 1-based [popularityRank] is inverted (`1/rank`).
///
/// Aliases: `popularity`, `popular`, `pop`, `heat`. Rank: `popularityRank`,
/// `popularity_rank`, `popularRank`. Generic `rank` is ignored.
double? parseCatalogItemPopularity(Map<String, dynamic> map) {
  for (final key in const ['popularity', 'popular', 'pop', 'heat']) {
    if (!map.containsKey(key)) continue;
    final n = _finiteNumber(map[key]);
    if (n != null && n >= 0) return n;
  }
  for (final key in const [
    'popularityRank',
    'popularity_rank',
    'popularRank',
  ]) {
    if (!map.containsKey(key)) continue;
    final r = _finiteNumber(map[key]);
    if (r != null && r >= 1) return 1.0 / r;
  }
  return null;
}

double? _finiteNumber(Object? raw) {
  if (raw is num) {
    final d = raw.toDouble();
    return d.isFinite ? d : null;
  }
  if (raw is String) {
    final d = double.tryParse(raw.trim());
    if (d != null && d.isFinite) return d;
  }
  return null;
}

int? _positiveInt(Object? raw) {
  if (raw is num) {
    final n = raw.toInt();
    return n > 0 ? n : null;
  }
  if (raw is String) {
    final n = int.tryParse(raw.trim());
    if (n != null && n > 0) return n;
  }
  return null;
}

int? _anilistIdFrom(Map<String, dynamic> map, String id) {
  final fromField = _positiveInt(
    map['anilistId'] ?? map['anilist_id'] ?? map['anilist'],
  );
  if (fromField != null) return fromField;
  final match = RegExp(
    r'^(?:anilist[-:])(\d+)$',
    caseSensitive: false,
  ).firstMatch(id.trim());
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  return null;
}

int? _tmdbIdFrom(
  Map<String, dynamic> map, {
  String? id,
  List<String> tags = const [],
  String? title,
  String? playUrl,
  String? posterUrl,
}) {
  return ExternalIds.tmdbFromMap(
    map,
    id: id,
    tags: tags,
    title: title,
    playUrl: playUrl,
    posterUrl: posterUrl,
  );
}

class _ParsedEntry {
  const _ParsedEntry({required this.items, required this.details});
  final List<MediaItem> items;
  final Map<String, MediaDetails> details;
}

class CustomCatalogParseResult {
  const CustomCatalogParseResult({
    required this.items,
    this.vod,
    this.name,
    this.version = 1,
    this.minVersion,
    this.capabilities = const [],
    this.itemCount,
    this.vastUrl,
    this.epgUrl,
    this.namedSources = const [],
    this.playHeaders = const {},
    this.details = const {},
  });

  final String? name;
  final int version;

  /// Optional minimum JAVP app version (`min_version` / `minVersion`).
  final String? minVersion;
  final List<String> capabilities;
  final int? itemCount;

  /// Catalog-level VAST/VMAP tag (root `vastUrl` / `ads.vastUrl`).
  final String? vastUrl;

  /// Catalog-level XMLTV URL (root `epgUrl` / aliases). Loaded into the
  /// merged live guide for this source's channels.
  final String? epgUrl;
  final List<CatalogNamedSource> namedSources;

  /// Root `playHeaders` / `userAgent` inherited by item `playUrl`s.
  final Map<String, String> playHeaders;

  /// Leftovers that are not VOD/series. When [vod] is set, those rows were
  /// packed off the UI isolate and are not in [items].
  final List<MediaItem> items;

  /// Packed VOD/series for `vod_catalog.db`. Null on web / in-process parse.
  final VodIngestPlan? vod;
  final Map<String, MediaDetails> details;

  int get vodCount =>
      vod?.vodCount ??
      items
          .where((m) => m.kind == MediaKind.vod || m.kind == MediaKind.series)
          .length;

  bool get isQueryApi => version >= 2 || capabilities.isNotEmpty;

  /// True when the descriptor advertises remote `GET /search`.
  bool get supportsSearch =>
      capabilities.any((c) => c.trim().toLowerCase() == 'search');
}

class CustomCatalogPage {
  const CustomCatalogPage({
    required this.items,
    this.query,
    this.page = 1,
    this.limit = 50,
    this.total = 0,
    this.details = const {},
  });

  final String? query;
  final int page;
  final int limit;
  final int total;
  final List<MediaItem> items;
  final Map<String, MediaDetails> details;
}

class CustomCatalogItemResult {
  const CustomCatalogItemResult({
    required this.item,
    this.details,
    this.allItems = const [],
    this.detailsById = const {},
  });

  final MediaItem item;
  final MediaDetails? details;
  final List<MediaItem> allItems;
  final Map<String, MediaDetails> detailsById;
}

class CustomCatalogGroup {
  const CustomCatalogGroup({required this.id, required this.name, this.count});

  final String id;
  final String name;
  final int? count;
}

/// Remote `/search` is missing (HTTP 404). Prefer local catalog title match.
class CatalogSearchUnsupportedException implements Exception {
  const CatalogSearchUnsupportedException();

  @override
  String toString() => 'Catalog search unsupported (404)';
}

/// Pack VOD/series from an in-process parse so the UI never copies those graphs.
CustomCatalogParseResult packCustomCatalogVod(
  CustomCatalogParseResult parsed, {
  required String sourceId,
}) {
  final split = splitAndPackVodItems(parsed.items, fallbackSourceId: sourceId);
  return CustomCatalogParseResult(
    items: split.leftovers,
    vod: split.vod,
    name: parsed.name,
    version: parsed.version,
    minVersion: parsed.minVersion,
    capabilities: parsed.capabilities,
    itemCount: parsed.itemCount,
    vastUrl: parsed.vastUrl,
    epgUrl: parsed.epgUrl,
    namedSources: parsed.namedSources,
    playHeaders: parsed.playHeaders,
    details: parsed.details,
  );
}

List<String> stringListFromJson(Object? raw) => catalogStringListFromJson(raw);

Map<String, String> stringMapFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, String>{};
  raw.forEach((key, value) {
    final k = '$key'.trim();
    final v = '$value'.trim();
    if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
  });
  return out;
}

List<ExternalSubtitle> subtitlesFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <ExternalSubtitle>[];
  for (final entry in raw) {
    if (entry is String && entry.trim().isNotEmpty) {
      out.add(ExternalSubtitle(url: entry.trim()));
      continue;
    }
    if (entry is Map) {
      final track = ExternalSubtitle.fromJson(Map<String, dynamic>.from(entry));
      if (track.url.isNotEmpty) out.add(track);
    }
  }
  return out;
}

List<ExternalAudio> audioTracksFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <ExternalAudio>[];
  for (final entry in raw) {
    if (entry is String && entry.trim().isNotEmpty) {
      out.add(ExternalAudio(url: entry.trim()));
      continue;
    }
    if (entry is Map) {
      final track = ExternalAudio.fromJson(Map<String, dynamic>.from(entry));
      if (track.url.isNotEmpty) out.add(track);
    }
  }
  return out;
}

List<MediaSegment> segmentsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <MediaSegment>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    final typeName = (map['type'] as String?)?.trim().toLowerCase() ?? '';
    final type = switch (typeName) {
      'intro' || 'opening' => MediaSegmentType.intro,
      'recap' => MediaSegmentType.recap,
      'credits' || 'outro' || 'endcredits' => MediaSegmentType.credits,
      'preview' => MediaSegmentType.preview,
      _ => MediaSegmentType.values.asNameMap()[typeName],
    };
    if (type == null) continue;
    final startMs =
        (map['startMs'] as num?)?.toInt() ??
        (((map['start'] as num?)?.toDouble() ?? 0) * 1000).round();
    final endRaw = map['endMs'] ?? map['end'];
    out.add(
      MediaSegment(
        type: type,
        start: Duration(milliseconds: startMs),
        end: endRaw == null
            ? null
            : Duration(
                milliseconds: (endRaw is num)
                    ? (map['endMs'] != null
                          ? endRaw.toInt()
                          : (endRaw.toDouble() * 1000).round())
                    : 0,
              ),
        source: (map['source'] as String?)?.trim() ?? 'catalog',
        confidence: (map['confidence'] as num?)?.toDouble(),
      ),
    );
  }
  return out;
}

/// Root XMLTV URL advertised by a custom catalog (`epgUrl` / aliases).
String? catalogEpgUrlFromJson(Map<String, dynamic> map) {
  for (final key in const [
    'epgUrl',
    'epg_url',
    'xmltvUrl',
    'xmltv_url',
    'tvgUrl',
    'url-tvg',
    'x-tvg-url',
    'epg',
  ]) {
    final v = map[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// Absolute HTTP(S) / file URL, or [catalogUrl]-relative.
String? resolveCatalogEpgUrl(String? epgUrl, {String? catalogUrl}) {
  final raw = epgUrl?.trim();
  if (raw == null || raw.isEmpty) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed != null && parsed.hasScheme) return raw;
  final base = catalogUrl?.trim();
  if (base == null || base.isEmpty) return raw;
  try {
    return Uri.parse(base).resolve(raw).toString();
  } catch (_) {
    return raw;
  }
}

/// Bridge `{error}` / `{message}` body, when present.
String? catalogErrorMessage(Map<String, dynamic> map) {
  for (final key in ['error', 'message', 'detail', 'errorMessage']) {
    final v = map[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is Map) {
      final nested = catalogErrorMessage(Map<String, dynamic>.from(v));
      if (nested != null) return nested;
    }
  }
  return null;
}

String catalogHttpError(String kind, http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final msg = catalogErrorMessage(Map<String, dynamic>.from(decoded));
      if (msg != null) return msg;
    }
  } catch (_) {}
  return 'Catalog $kind failed (${response.statusCode})';
}

const _catalogParseChunkSize = 400;

/// Parse a bulk catalog dump off the UI isolate and stream items back in
/// chunks. A single [Isolate.run] of the full [CustomCatalogParseResult]
/// freezes Windows ("Not Responding") the same way M3U handoff did.
///
/// Dumps ≥ 64 KiB pack VOD in the worker ([CustomCatalogParseResult.vod]).
/// Smaller / in-process parses still return items; the library packs those
/// with `_takeImportedVodToSqlite`. Query-API descriptors upsert; dumps
/// replace. Empty dump + query API must not wipe a warm cache.
///
/// Playlist bytes are streamed to the worker in 256 KiB slices — spawning
/// with the full dump copies it on the UI isolate and locks focus.
Future<CustomCatalogParseResult> parseCatalogBodyInIsolate(
  List<int> bytes, {
  required String sourceId,
  String? appVersion,
  CatalogClientProfile? profile,
}) async {
  if (kIsWeb || bytes.length < 64 * 1024) {
    return javpCompute(
      () => CustomCatalogClient().parse(
        utf8.decode(bytes),
        sourceId: sourceId,
        appVersion: appVersion,
        profile: profile,
      ),
    );
  }
  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _catalogParseIsolateMain,
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
      throw StateError('catalog parse isolate exited before handshake');
    }
    if (isolateError != null) throw isolateError!;
    final workerPort = iter.current as SendPort;
    workerPort.send({
      'sourceId': sourceId,
      'appVersion': appVersion,
      'profile': profile == null
          ? null
          : {
              'appVersion': profile.appVersion,
              'platform': profile.platform,
              'device': profile.device,
              'capabilities': profile.capabilities,
            },
    });
    await yieldAfterIsolateChunk();
    const byteChunk = 256 * 1024;
    for (var i = 0; i < bytes.length; i += byteChunk) {
      if (isolateError != null) throw isolateError!;
      final end = i + byteChunk > bytes.length ? bytes.length : i + byteChunk;
      workerPort.send(bytes.sublist(i, end));
      await yieldAfterIsolateChunk();
    }
    workerPort.send(null);

    String? name;
    var version = 1;
    String? minVersion;
    var capabilities = const <String>[];
    int? itemCount;
    String? vastUrl;
    String? epgUrl;
    var namedSources = const <CatalogNamedSource>[];
    var playHeaders = const <String, String>{};
    final items = <MediaItem>[];
    final vodRows = <Map<String, Object?>>[];
    final vodFamilies = <String, List<String>>{};
    final vodCanonical = <String, String>{};
    var packedVod = false;
    var details = const <String, MediaDetails>{};
    var header = false;
    while (await iter.moveNext()) {
      if (isolateError != null) throw isolateError!;
      final message = iter.current;
      if (message == null) break;
      if (!header) {
        header = true;
        if (message is Map) {
          name = message['name'] as String?;
          version = (message['version'] as num?)?.toInt() ?? 1;
          minVersion = message['minVersion'] as String?;
          final caps = message['capabilities'];
          if (caps is List) {
            capabilities = [for (final c in caps) '$c'];
          }
          itemCount = (message['itemCount'] as num?)?.toInt();
          vastUrl = message['vastUrl'] as String?;
          final epg = message['epgUrl'];
          if (epg is String && epg.trim().isNotEmpty) epgUrl = epg.trim();
          final named = message['namedSources'];
          if (named is List<CatalogNamedSource>) {
            namedSources = named;
          } else if (named is List) {
            namedSources = [
              for (final e in named)
                if (e is CatalogNamedSource) e,
            ];
          }
          final headers = message['playHeaders'];
          if (headers is Map) {
            playHeaders = {
              for (final e in headers.entries) '${e.key}': '${e.value}',
            };
          }
        }
        await yieldAfterIsolateChunk();
        continue;
      }
      if (message is List) {
        for (final e in message) {
          if (e is MediaItem) items.add(e);
        }
        await yieldAfterIsolateChunk();
        continue;
      }
      if (message is Map) {
        final type = '${message['t'] ?? ''}';
        final raw = message['v'];
        if (raw is List) {
          switch (type) {
            case 'vod':
              packedVod = true;
              for (final e in raw) {
                if (e is Map<String, Object?>) {
                  vodRows.add(e);
                } else if (e is Map) {
                  vodRows.add(Map<String, Object?>.from(e));
                }
              }
            case 'vodFamilies':
              packedVod = true;
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                vodFamilies['${e[0]}'] = [
                  for (final id in (e[1] is List ? e[1] as List : const []))
                    '$id',
                ];
              }
            case 'vodCanonical':
              packedVod = true;
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                vodCanonical['${e[0]}'] = '${e[1]}';
              }
          }
        }
        if (type.isNotEmpty) {
          await yieldAfterIsolateChunk();
          continue;
        }
      }
      if (message is Map && message.containsKey('details')) {
        final raw = message['details'];
        if (raw is Map<String, MediaDetails>) {
          details = raw;
        } else if (raw is Map) {
          details = {
            for (final e in raw.entries)
              if (e.value is MediaDetails) '${e.key}': e.value as MediaDetails,
          };
        }
        await yieldAfterIsolateChunk();
      }
    }
    if (isolateError != null) throw isolateError!;
    return CustomCatalogParseResult(
      items: items,
      vod: packedVod
          ? VodIngestPlan(
              rows: vodRows,
              families: vodFamilies,
              canonical: vodCanonical,
            )
          : null,
      name: name,
      version: version,
      minVersion: minVersion,
      capabilities: capabilities,
      itemCount: itemCount,
      vastUrl: vastUrl,
      epgUrl: epgUrl,
      namedSources: namedSources,
      playHeaders: playHeaders,
      details: details,
    );
  } finally {
    await errorSub.cancel();
    await iter.cancel();
    receive.close();
    errors.close();
    worker.kill(priority: Isolate.immediate);
  }
}

CatalogClientProfile? _catalogProfileFromIsolate(Object? raw) {
  if (raw is! Map) return null;
  return CatalogClientProfile(
    appVersion: raw['appVersion'] as String?,
    platform: raw['platform'] as String?,
    device: raw['device'] as String?,
    capabilities: [
      for (final c in (raw['capabilities'] as List? ?? const [])) '$c',
    ],
  );
}

@pragma('vm:entry-point')
void _catalogParseIsolateMain(SendPort reply) {
  unawaited(_catalogParseIsolateBody(reply));
}

Future<void> _catalogParseIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  var sourceId = '';
  String? appVersion;
  CatalogClientProfile? profile;
  final buffer = BytesBuilder(copy: false);
  try {
    await for (final message in inbound) {
      if (message == null) break;
      if (message is Map && message.containsKey('sourceId')) {
        sourceId = '${message['sourceId'] ?? ''}';
        final ver = message['appVersion'];
        appVersion = ver is String && ver.isNotEmpty ? ver : null;
        profile = _catalogProfileFromIsolate(message['profile']);
        continue;
      }
      if (message is List<int>) buffer.add(message);
    }
    final parsed = packCustomCatalogVod(
      CustomCatalogClient().parse(
        utf8.decode(buffer.takeBytes()),
        sourceId: sourceId,
        appVersion: appVersion,
        profile: profile,
      ),
      sourceId: sourceId,
    );
    reply.send({
      'name': parsed.name,
      'version': parsed.version,
      'minVersion': parsed.minVersion,
      'capabilities': parsed.capabilities,
      'itemCount': parsed.itemCount,
      'vastUrl': parsed.vastUrl,
      'epgUrl': parsed.epgUrl,
      'namedSources': parsed.namedSources,
      'playHeaders': parsed.playHeaders,
    });
    const chunk = _catalogParseChunkSize;
    void sendMaps(String type, List<Map<String, Object?>> rows) {
      for (var i = 0; i < rows.length; i += chunk) {
        final end = i + chunk > rows.length ? rows.length : i + chunk;
        reply.send({
          't': type,
          'v': List<Map<String, Object?>>.from(rows.getRange(i, end)),
        });
      }
    }

    void sendPairs(String type, List<List<Object>> pairs) {
      for (var i = 0; i < pairs.length; i += chunk) {
        final end = i + chunk > pairs.length ? pairs.length : i + chunk;
        reply.send({'t': type, 'v': pairs.sublist(i, end)});
      }
    }

    final vod = parsed.vod;
    if (vod != null) {
      sendMaps('vod', vod.rows);
      sendPairs('vodFamilies', [
        for (final e in vod.families.entries) [e.key, e.value],
      ]);
      sendPairs('vodCanonical', [
        for (final e in vod.canonical.entries) [e.key, e.value],
      ]);
    }
    final leftovers = parsed.items;
    for (var i = 0; i < leftovers.length; i += chunk) {
      final end = i + chunk > leftovers.length ? leftovers.length : i + chunk;
      reply.send(List<MediaItem>.from(leftovers.getRange(i, end)));
    }
    if (parsed.details.isNotEmpty) {
      reply.send({'details': parsed.details});
    }
  } finally {
    inbound.close();
    reply.send(null);
  }
}
