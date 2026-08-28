import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';

/// Thin Trakt API client. Enrichment works with client id only.
///
/// Docs: https://trakt.docs.apiary.io / https://docs.trakt.tv
class TraktClient {
  TraktClient({http.Client? httpClient})
    : _http = httpClient ?? createDnsFallbackHttpClient(),
      _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;
  static const _api = 'https://api.trakt.tv';
  static const _auth = 'https://api.trakt.tv';
  static const _appName = 'javp';
  static const _appVersion = '0.1.0';

  Map<String, String> _headers(TraktCredentials creds, {bool json = true}) => {
    'User-Agent': '$_appName/$_appVersion',
    'trakt-api-version': '2',
    'trakt-api-key': creds.effectiveClientId,
    if (json) 'Content-Type': 'application/json',
    if (creds.accessToken != null && creds.accessToken!.isNotEmpty)
      'Authorization': 'Bearer ${creds.accessToken}',
  };

  Future<bool> validate(TraktCredentials creds) async {
    if (!creds.isAuthenticated) return false;
    final response = await _http.get(
      Uri.parse('$_api/users/settings'),
      headers: _headers(creds),
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  /// Starts device OAuth. Show [TraktDeviceSession.userCode] and open
  /// [TraktDeviceSession.verificationUri].
  Future<TraktDeviceSession> requestDeviceCode(TraktCredentials creds) async {
    if (!creds.isConfigured) {
      throw Exception('Trakt client id not configured');
    }
    final response = await _http.post(
      Uri.parse('$_auth/oauth/device/code'),
      headers: _headers(creds),
      body: jsonEncode({'client_id': creds.effectiveClientId}),
    );
    if (response.statusCode >= 400) {
      throw Exception('Trakt device code failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Trakt device code returned unexpected body');
    }
    final session = TraktDeviceSession.fromJson(decoded);
    if (session.userCode.isEmpty || session.deviceCode.isEmpty) {
      throw Exception('Trakt device code returned empty codes');
    }
    return session;
  }

  /// Polls until the user authorizes, then returns tokens.
  Future<TraktTokenResult> waitForDeviceToken({
    required TraktCredentials creds,
    required TraktDeviceSession session,
    required bool Function() isCancelled,
  }) async {
    if (!creds.isConfigured) {
      throw Exception('Trakt client id not configured');
    }
    final secret = creds.effectiveClientSecret;
    if (secret.isEmpty) {
      throw Exception(
        'Trakt client secret required for device login — set it under Developer',
      );
    }
    final deadline = DateTime.now().add(Duration(seconds: session.expiresIn));
    final interval = Duration(seconds: session.interval.clamp(3, 30));

    while (true) {
      if (isCancelled()) throw Exception('Trakt device login cancelled');
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('Trakt device code expired — request a new one');
      }

      final response = await _http.post(
        Uri.parse('$_auth/oauth/device/token'),
        headers: _headers(creds),
        body: jsonEncode({
          'code': session.deviceCode,
          'client_id': creds.effectiveClientId,
          'client_secret': secret,
        }),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw Exception('Trakt token returned unexpected body');
        }
        final token = TraktTokenResult.fromJson(decoded);
        if (token.accessToken.isEmpty) {
          throw Exception('Trakt token response missing access_token');
        }
        return token;
      }

      // 400 pending / slow_down — keep polling
      if (response.statusCode == 400) {
        try {
          final decoded = jsonDecode(response.body);
          final err = decoded is Map ? '${decoded['error'] ?? ''}' : '';
          if (err == 'slow_down') {
            await Future<void>.delayed(interval * 2);
            continue;
          }
          if (err == 'authorization_pending') {
            await Future<void>.delayed(interval);
            continue;
          }
          if (err == 'expired_token' || err == 'slow_down') {
            throw Exception('Trakt device code expired — request a new one');
          }
          if (err == 'access_denied') {
            throw Exception('Trakt authorization denied');
          }
        } catch (e) {
          if (e is Exception && e.toString().contains('Trakt')) rethrow;
        }
        await Future<void>.delayed(interval);
        continue;
      }

      throw Exception('Trakt device token failed (${response.statusCode})');
    }
  }

  Future<List<Map<String, dynamic>>> search(
    TraktCredentials creds, {
    required String query,
    String type = 'movie',
  }) async {
    if (!creds.isConfigured || query.trim().isEmpty) return const [];
    final uri = Uri.parse(
      '$_api/search/$type',
    ).replace(queryParameters: {'query': query.trim(), 'extended': 'full'});
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  /// Lookup by external id type: `tmdb`, `imdb`, `tvdb`, `trakt`.
  Future<List<Map<String, dynamic>>> searchById(
    TraktCredentials creds, {
    required String idType,
    required String id,
    String? type,
  }) async {
    if (!creds.isConfigured || id.trim().isEmpty) return const [];
    final path = type == null || type.isEmpty
        ? '$_api/search/$idType/${Uri.encodeComponent(id.trim())}'
        : '$_api/search/$idType/${Uri.encodeComponent(id.trim())}/$type';
    final uri = Uri.parse(path).replace(queryParameters: {'extended': 'full'});
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>?> fetchMovie(TraktCredentials creds, String id) =>
      _fetch(creds, '/movies/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>?> fetchShow(TraktCredentials creds, String id) =>
      _fetch(creds, '/shows/${Uri.encodeComponent(id)}');

  /// Cast + crew (`GET /movies|shows/{id}/people`). Client id enough.
  Future<Map<String, dynamic>?> fetchPeople(
    TraktCredentials creds,
    String id, {
    required bool show,
  }) {
    final path = show
        ? '/shows/${Uri.encodeComponent(id)}/people'
        : '/movies/${Uri.encodeComponent(id)}/people';
    return _fetch(creds, path);
  }

  /// One season's episodes with titles / overviews / images.
  Future<List<Map<String, dynamic>>> fetchSeasonEpisodes(
    TraktCredentials creds,
    String id, {
    required int seasonNumber,
  }) async {
    if (!creds.isConfigured || id.trim().isEmpty || seasonNumber < 0) {
      return const [];
    }
    final uri = Uri.parse(
      '$_api/shows/${Uri.encodeComponent(id)}/seasons/$seasonNumber/episodes',
    ).replace(queryParameters: {'extended': 'full'});
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

  /// Personalized movie recommendations. Requires a linked OAuth session.
  Future<List<TraktIdHit>> getMovieRecommendations(
    TraktCredentials creds, {
    int limit = 20,
  }) => _authList(
    creds,
    '/recommendations/movies',
    mediaKey: 'movie',
    limit: limit,
    query: {'ignore_collected': 'true', 'ignore_watchlisted': 'true'},
  );

  /// Personalized show recommendations. Requires a linked OAuth session.
  Future<List<TraktIdHit>> getShowRecommendations(
    TraktCredentials creds, {
    int limit = 20,
  }) => _authList(
    creds,
    '/recommendations/shows',
    mediaKey: 'show',
    limit: limit,
    query: {'ignore_collected': 'true', 'ignore_watchlisted': 'true'},
  );

  /// User movie watchlist. Requires a linked OAuth session.
  Future<List<TraktIdHit>> getWatchlistMovies(TraktCredentials creds) =>
      _authList(creds, '/sync/watchlist/movies', mediaKey: 'movie');

  /// User show watchlist. Requires a linked OAuth session.
  Future<List<TraktIdHit>> getWatchlistShows(TraktCredentials creds) =>
      _authList(creds, '/sync/watchlist/shows', mediaKey: 'show');

  /// Movies + shows watchlist. Fail soft per type when unlinked / errored.
  Future<List<TraktIdHit>> getWatchlist(TraktCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final out = <TraktIdHit>[];
    try {
      out.addAll(await getWatchlistMovies(creds));
    } catch (_) {}
    try {
      out.addAll(await getWatchlistShows(creds));
    } catch (_) {}
    return out;
  }

  /// Paused playback sessions (progress as 0–1). Fail soft when unlinked.
  Future<List<TraktPlayback>> getPlaybacks(TraktCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final response = await _http.get(
      Uri.parse('$_api/sync/playback'),
      headers: _headers(creds),
    );
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map)
          TraktPlayback.fromApiEntry(Map<String, dynamic>.from(entry)),
    ];
  }

  /// Dropped shows (`GET /users/hidden/dropped`). Paginates; fail soft.
  Future<List<TraktIdHit>> getDroppedShows(TraktCredentials creds) async {
    if (!creds.isAuthenticated) return const [];
    final out = <TraktIdHit>[];
    var page = 1;
    const limit = 100;
    while (page <= 20) {
      final uri = Uri.parse(
        '$_api/users/hidden/dropped',
      ).replace(queryParameters: {'page': '$page', 'limit': '$limit'});
      final response = await _http.get(uri, headers: _headers(creds));
      if (response.statusCode >= 400) break;
      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) break;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        // Hidden-dropped wraps under `show`; listed_at may be `hidden_at`.
        if (map['listed_at'] == null && map['hidden_at'] != null) {
          map['listed_at'] = map['hidden_at'];
        }
        final hit = TraktIdHit.fromApiEntry(map, mediaKey: 'show');
        if (hit != null) out.add(hit);
      }
      if (decoded.length < limit) break;
      page++;
    }
    return out;
  }

  /// Last-activity stamps for gating watchlist re-pulls.
  Future<TraktLastActivities?> getLastActivities(TraktCredentials creds) async {
    if (!creds.isAuthenticated) return null;
    final response = await _http.get(
      Uri.parse('$_api/sync/last_activities'),
      headers: _headers(creds),
    );
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    return TraktLastActivities.fromApi(Map<String, dynamic>.from(decoded));
  }

  /// Related movies for a title (client id enough; no user token required).
  Future<List<TraktIdHit>> getRelatedMovies(
    TraktCredentials creds,
    String id, {
    int limit = 10,
  }) => _publicList(
    creds,
    '/movies/${Uri.encodeComponent(id)}/related',
    mediaKey: 'movie',
    limit: limit,
  );

  /// Related shows for a title (client id enough; no user token required).
  Future<List<TraktIdHit>> getRelatedShows(
    TraktCredentials creds,
    String id, {
    int limit = 10,
  }) => _publicList(
    creds,
    '/shows/${Uri.encodeComponent(id)}/related',
    mediaKey: 'show',
    limit: limit,
  );

  Future<Map<String, dynamic>?> _fetch(
    TraktCredentials creds,
    String path,
  ) async {
    if (!creds.isConfigured) return null;
    final uri = Uri.parse(
      '$_api$path',
    ).replace(queryParameters: {'extended': 'full'});
    final response = await _http.get(uri, headers: _headers(creds));
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<TraktIdHit>> _authList(
    TraktCredentials creds,
    String path, {
    required String mediaKey,
    int? limit,
    Map<String, String> query = const {},
  }) async {
    if (!creds.isAuthenticated) return const [];
    return _list(creds, path, mediaKey: mediaKey, limit: limit, query: query);
  }

  Future<List<TraktIdHit>> _publicList(
    TraktCredentials creds,
    String path, {
    required String mediaKey,
    int? limit,
  }) async {
    if (!creds.isConfigured) return const [];
    return _list(creds, path, mediaKey: mediaKey, limit: limit);
  }

  Future<List<TraktIdHit>> _list(
    TraktCredentials creds,
    String path, {
    required String mediaKey,
    int? limit,
    Map<String, String> query = const {},
  }) async {
    final params = <String, String>{
      ...query,
      if (limit != null && limit > 0) 'limit': '$limit',
    };
    final uri = Uri.parse(
      '$_api$path',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final response = await _http.get(uri, headers: _headers(creds));
    // 401/403 = missing scope or expired token — fail soft.
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    final out = <TraktIdHit>[];
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final hit = TraktIdHit.fromApiEntry(map, mediaKey: mediaKey);
      if (hit != null) out.add(hit);
    }
    return out;
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
