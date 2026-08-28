import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';

/// Thin SIMKL API client. Uses the bundled client id when none is set.
///
/// Docs: https://api.simkl.org/
class SimklClient {
  SimklClient({http.Client? httpClient})
    : _http = httpClient ?? createDnsFallbackHttpClient(),
      _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;
  static const _base = 'https://api.simkl.com';
  static const _appName = 'javp';
  static const _appVersion = '0.1.0';

  Map<String, String> _query(String clientId) => {
    'client_id': clientId,
    'app-name': _appName,
    'app-version': _appVersion,
  };

  Map<String, String> _headers(SimklCredentials creds) => {
    'Content-Type': 'application/json',
    'User-Agent': '$_appName/$_appVersion',
    'simkl-api-key': creds.effectiveClientId,
    if (creds.accessToken != null)
      'Authorization': 'Bearer ${creds.accessToken}',
  };

  Uri _uri(String path, String clientId, [String? extraPath]) {
    final full = extraPath == null ? '$_base$path' : '$_base$path/$extraPath';
    return Uri.parse(full).replace(queryParameters: _query(clientId));
  }

  String _clientId(SimklCredentials creds) => creds.effectiveClientId;

  Future<bool> validate(SimklCredentials creds) async {
    if (!creds.isAuthenticated) return false;
    final response = await _http.get(
      _uri('/users/settings', _clientId(creds)),
      headers: _headers(creds),
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  /// Starts the device PIN flow. Open [SimklPinSession.verificationUri] and
  /// have the user enter [SimklPinSession.userCode].
  Future<SimklPinSession> requestPin(String clientId) async {
    final id = clientId.trim().isEmpty
        ? SimklCredentials.bundledClientId
        : clientId.trim();
    final response = await _http.get(
      _uri('/oauth/pin', id),
      headers: {'User-Agent': '$_appName/$_appVersion'},
    );
    if (response.statusCode >= 400) {
      throw Exception('SIMKL PIN request failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('SIMKL PIN request returned unexpected body');
    }
    final session = SimklPinSession.fromJson(decoded);
    if (session.userCode.isEmpty) {
      throw Exception('SIMKL PIN request returned no user_code');
    }
    return session;
  }

  /// Polls until the user approves the PIN, then returns the access token.
  ///
  /// Throws if [isCancelled] becomes true, the PIN expires, or SIMKL errors.
  Future<String> waitForPinToken({
    required String clientId,
    required SimklPinSession session,
    required bool Function() isCancelled,
  }) async {
    final id = clientId.trim().isEmpty
        ? SimklCredentials.bundledClientId
        : clientId.trim();
    final deadline = DateTime.now().add(Duration(seconds: session.expiresIn));
    final interval = Duration(seconds: session.interval.clamp(3, 30));

    while (true) {
      if (isCancelled()) {
        throw Exception('SIMKL PIN cancelled');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('SIMKL PIN expired — request a new one');
      }

      final response = await _http.get(
        _uri('/oauth/pin', id, session.userCode),
        headers: {'User-Agent': '$_appName/$_appVersion'},
      );
      if (response.statusCode >= 400) {
        throw Exception('SIMKL PIN poll failed (${response.statusCode})');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('SIMKL PIN poll returned unexpected body');
      }

      // Fresh PIN payload means the previous code is gone.
      if (decoded.containsKey('device_code') &&
          decoded['access_token'] == null) {
        throw Exception('SIMKL PIN expired — request a new one');
      }

      final token = (decoded['access_token'] as String?)?.trim();
      if (token != null && token.isNotEmpty) {
        return token;
      }

      await Future<void>.delayed(interval);
    }
  }

  Future<void> scrobble(
    SimklCredentials creds,
    SimklScrobbleEvent event,
  ) async {
    if (!creds.isAuthenticated) return;

    final response = await _http.post(
      _uri('/sync/history', _clientId(creds)),
      headers: _headers(creds),
      body: jsonEncode(event.toHistoryPayload()),
    );

    if (response.statusCode >= 400) {
      throw Exception('SIMKL scrobble failed (${response.statusCode})');
    }
  }

  Future<List<Map<String, dynamic>>> search(
    SimklCredentials creds, {
    required String query,
    String type = 'movie',
  }) async {
    if (!creds.isConfigured) return const [];
    final id = _clientId(creds);
    final uri = _uri(
      '/search/$type',
      id,
    ).replace(queryParameters: {..._query(id), 'q': query, 'extended': 'full'});
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  /// Resolve by external id (`tmdb`, `imdb`, `tvdb`, …).
  Future<Map<String, dynamic>?> searchById(
    SimklCredentials creds, {
    int? tmdb,
    String? imdb,
    int? tvdb,
    String? type,
  }) async {
    if (!creds.isConfigured) return null;
    final id = _clientId(creds);
    final params = <String, String>{..._query(id)};
    if (tmdb != null && tmdb > 0) params['tmdb'] = '$tmdb';
    if (imdb != null && imdb.trim().isNotEmpty) params['imdb'] = imdb.trim();
    if (tvdb != null && tvdb > 0) params['tvdb'] = '$tvdb';
    if (type != null && type.isNotEmpty) params['type'] = type;
    if (params.length <= _query(id).length) return null;
    final uri = Uri.parse('$_base/search/id').replace(queryParameters: params);
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      return Map<String, dynamic>.from(decoded.first as Map);
    }
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  Future<Map<String, dynamic>?> fetchMovie(
    SimklCredentials creds,
    String simklId, {
    String? language,
  }) => _fetchDetail(creds, '/movies/$simklId', language: language);

  Future<Map<String, dynamic>?> fetchTv(
    SimklCredentials creds,
    String simklId, {
    String? language,
  }) => _fetchDetail(creds, '/tv/$simklId', language: language);

  Future<Map<String, dynamic>?> fetchAnime(
    SimklCredentials creds,
    String simklId, {
    String? language,
  }) => _fetchDetail(creds, '/anime/$simklId', language: language);

  /// Every season + episode for a TV show or anime (`GET /tv|anime/episodes/{id}`).
  Future<List<Map<String, dynamic>>> fetchEpisodes(
    SimklCredentials creds,
    String simklId, {
    required bool anime,
    String? language,
  }) async {
    if (!creds.isConfigured || simklId.trim().isEmpty) return const [];
    final path = anime ? '/anime/episodes/$simklId' : '/tv/episodes/$simklId';
    final id = _clientId(creds);
    final params = <String, String>{
      ..._query(id),
      if (language != null && language.isNotEmpty) 'language': language,
    };
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);
    try {
      final response = await _http.get(uri, headers: _headers(creds));
      if (response.statusCode >= 400) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Similar / social recommendations embedded on a detail record.
  ///
  /// SIMKL has no standalone recommend endpoint — `users_recommendations`
  /// comes back on `GET /movies|tv|anime/{id}` (client id enough).
  Future<List<SimklRecHit>> fetchRelatedRecommendations(
    SimklCredentials creds, {
    required String simklId,
    String? kind,
  }) async {
    final id = simklId.trim();
    if (!creds.isConfigured || id.isEmpty) return const [];
    final order = switch (kind) {
      'movie' => const ['movie'],
      'tv' => const ['tv', 'anime'],
      'anime' => const ['anime', 'tv'],
      _ => const ['tv', 'movie', 'anime'],
    };
    for (final k in order) {
      final raw = switch (k) {
        'movie' => await fetchMovie(creds, id),
        'anime' => await fetchAnime(creds, id),
        _ => await fetchTv(creds, id),
      };
      if (raw == null) continue;
      final hits = SimklRecHit.listFromDetail(raw);
      if (hits.isNotEmpty) return hits;
    }
    return const [];
  }

  /// Plan-to-watch lists (movies + shows + anime). Requires a linked session.
  ///
  /// Sequential pulls per Simkl sync guidance. Fail soft per type.
  /// Shared with For You remote enricher — keep signature stable.
  Future<List<SimklLibraryItem>> getPlanToWatch(SimklCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final out = <SimklLibraryItem>[];
    for (final entry in const [
      ('movies', 'movie'),
      ('shows', 'show'),
      ('anime', 'anime'),
    ]) {
      try {
        out.addAll(
          await _allItemsByStatus(
            creds,
            type: entry.$1,
            mediaKey: entry.$2,
            status: 'plantowatch',
          ),
        );
      } catch (_) {}
    }
    return out;
  }

  Future<Map<String, dynamic>?> _fetchDetail(
    SimklCredentials creds,
    String path, {
    String? language,
  }) async {
    if (!creds.isConfigured) return null;
    final id = _clientId(creds);
    final params = <String, String>{
      ..._query(id),
      if (language != null && language.isNotEmpty) 'language': language,
    };
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    // Unknown id returns `[]` (Type 3 null) — treat as miss.
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  /// Full poster URL from a SIMKL poster path fragment.
  static String? posterUrl(String? path, {String size = '_m'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return 'https://wsrv.nl/?url=https://simkl.in/posters/$clean$size.webp&q=90';
  }

  /// Full episode still URL from a SIMKL `img` path fragment.
  static String? episodeStillUrl(String? path, {String size = '_w'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return 'https://wsrv.nl/?url=https://simkl.in/episodes/$clean$size.webp&q=90';
  }

  /// Full fanart URL from a SIMKL fanart path fragment.
  static String? fanartUrl(String? path, {String size = '_medium'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return 'https://wsrv.nl/?url=https://simkl.in/fanart/$clean$size.webp&q=90';
  }

  /// Last-modified stamps for watchlists / playback — gate for re-sync.
  Future<SimklActivities> getActivities(SimklCredentials creds) async {
    if (!creds.isAuthenticated) return const SimklActivities();
    final response = await _http.get(
      _uri('/sync/activities', _clientId(creds)),
      headers: _headers(creds),
    );
    if (response.statusCode >= 400) {
      throw Exception('SIMKL activities failed (${response.statusCode})');
    }
    final body = response.body;
    return Isolate.run(() {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const SimklActivities();
      return SimklActivities.fromApi(Map<String, dynamic>.from(decoded));
    });
  }

  /// Shows + anime on Watching.
  ///
  /// Fetches sequentially (Simkl guidance: avoid parallel full library pulls).
  Future<List<SimklLibraryItem>> getWatching(SimklCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final out = <SimklLibraryItem>[];
    // Keep going if one type fails — don't drop TV when anime errors (or vice versa).
    try {
      out.addAll(
        await _allItemsByStatus(
          creds,
          type: 'shows',
          mediaKey: 'show',
          status: 'watching',
        ),
      );
    } catch (_) {}
    try {
      out.addAll(
        await _allItemsByStatus(
          creds,
          type: 'anime',
          mediaKey: 'anime',
          status: 'watching',
        ),
      );
    } catch (_) {}
    return out;
  }

  /// Dropped / completed / hold buckets for inbound status sync.
  ///
  /// Movies skip `hold` (Simkl convention). Fail soft per type.
  Future<List<SimklLibraryItem>> getStatusItems(
    SimklCredentials creds, {
    required String status,
  }) async {
    if (!creds.isAuthenticated) return const [];
    final want = status.trim().toLowerCase();
    if (want.isEmpty) return const [];
    final out = <SimklLibraryItem>[];
    final types = <(String, String)>[
      ('shows', 'show'),
      ('anime', 'anime'),
      if (want != 'hold' && want != 'watching') ('movies', 'movie'),
    ];
    for (final entry in types) {
      try {
        out.addAll(
          await _allItemsByStatus(
            creds,
            type: entry.$1,
            mediaKey: entry.$2,
            status: want,
          ),
        );
      } catch (_) {}
    }
    return out;
  }

  Future<List<SimklLibraryItem>> getDropped(SimklCredentials creds) =>
      getStatusItems(creds, status: 'dropped');

  Future<List<SimklLibraryItem>> getCompleted(SimklCredentials creds) =>
      getStatusItems(creds, status: 'completed');

  Future<List<SimklLibraryItem>> getHold(SimklCredentials creds) =>
      getStatusItems(creds, status: 'hold');

  /// Delta of all library changes since [dateFrom] (ISO stamp from activities).
  Future<List<SimklLibraryItem>> getAllItemsSince(
    SimklCredentials creds, {
    required String dateFrom,
  }) async {
    if (!creds.isAuthenticated) return const [];
    final id = _clientId(creds);
    final uri = _uri(
      '/sync/all-items',
      id,
    ).replace(queryParameters: {..._query(id), 'date_from': dateFrom});
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) {
      throw Exception('SIMKL all-items delta failed (${response.statusCode})');
    }
    final body = response.body;
    return Isolate.run(() => _parseAllItemsDelta(body));
  }

  Future<List<SimklLibraryItem>> _allItemsByStatus(
    SimklCredentials creds, {
    required String type,
    required String mediaKey,
    required String status,
  }) async {
    final id = _clientId(creds);
    // Path status bucket is authoritative: …/{type}/{watching|plantowatch}
    final uri = _uri('/sync/all-items/$type/$status', id).replace(
      queryParameters: {
        ..._query(id),
        if (status == 'watching') 'next_watch_info': 'yes',
      },
    );
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) {
      throw Exception('SIMKL $status ($type) failed (${response.statusCode})');
    }
    final body = response.body;
    return Isolate.run(() => _parseStatusList(body, type, mediaKey, status));
  }

  /// Paused playback sessions (progress as 0–1).
  Future<List<SimklPlayback>> getPlaybacks(SimklCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final response = await _http.get(
      _uri('/sync/playback', _clientId(creds)),
      headers: _headers(creds),
    );
    if (response.statusCode >= 400) {
      throw Exception('SIMKL playback failed (${response.statusCode})');
    }
    final body = response.body;
    return Isolate.run(() {
      final decoded = jsonDecode(body);
      if (decoded is! List) return const <SimklPlayback>[];
      return [
        for (final entry in decoded)
          if (entry is Map)
            SimklPlayback.fromApiEntry(Map<String, dynamic>.from(entry)),
      ];
    });
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}

List<SimklLibraryItem> _parseStatusList(
  String body,
  String type,
  String mediaKey,
  String expectedStatus,
) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final map = Map<String, dynamic>.from(decoded);
  // Only the typed list key (shows / anime / movies) — never fall back to
  // nested media object keys (`show` / `movie`).
  final list = map[type];
  if (list is! List) return const [];
  final want = expectedStatus.trim().toLowerCase();
  final out = <SimklLibraryItem>[];
  for (final entry in list) {
    if (entry is! Map) continue;
    final item = SimklLibraryItem.fromSyncEntry(
      Map<String, dynamic>.from(entry),
      mediaKey: mediaKey,
    );
    final status = item.status?.trim().toLowerCase();
    if (want == 'watching') {
      if (!item.isWatchingStatus) continue;
    } else if (status != null && status.isNotEmpty && status != want) {
      continue;
    }
    if (item.title.isEmpty &&
        item.ids.simkl == null &&
        item.ids.tmdb == null &&
        item.ids.imdb == null) {
      continue;
    }
    out.add(item);
  }
  return out;
}

List<SimklLibraryItem> _parseAllItemsDelta(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final map = Map<String, dynamic>.from(decoded);
  final out = <SimklLibraryItem>[];
  void take(String listKey, String mediaKey) {
    final list = map[listKey];
    if (list is! List) return;
    for (final entry in list) {
      if (entry is! Map) continue;
      final raw = Map<String, dynamic>.from(entry);
      final status = (raw['status'] as String?)?.trim().toLowerCase();
      // Delta can include any status — Watching shelf only wants watching.
      if (status != 'watching') continue;
      final item = SimklLibraryItem.fromSyncEntry(raw, mediaKey: mediaKey);
      if (item.title.isEmpty &&
          item.ids.simkl == null &&
          item.ids.tmdb == null) {
        continue;
      }
      out.add(item);
    }
  }

  take('shows', 'show');
  take('anime', 'anime');
  return out;
}
