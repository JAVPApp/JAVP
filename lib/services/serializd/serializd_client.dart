import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/serializd_models.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';

/// Unofficial Serializd web/app API client.
///
/// Serializd has **no public OAuth / device PIN**. Auth is email+password →
/// bearer token (same as the Android/web apps). Host and shapes can change;
/// callers must fail soft.
///
/// API host: `https://serializd.onrender.com/api/` (not www — Vercel blocks
/// non-browser clients on the marketing domain).
class SerializdClient {
  SerializdClient({http.Client? httpClient})
      : _http = httpClient ?? createDnsFallbackHttpClient(),
        _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;

  static const _base = 'https://serializd.onrender.com/api';
  static const _origin = 'https://www.serializd.com';
  static const _appId = 'serializd_vercel';
  static const _userAgent = 'javp/0.3.3';

  void close() {
    if (_ownsClient) _http.close();
  }

  Map<String, String> _headers({String? token, bool jsonBody = false}) => {
        'Accept': 'application/json, text/plain, */*',
        'Origin': _origin,
        'Referer': '$_origin/',
        'X-Requested-With': _appId,
        'User-Agent': _userAgent,
        if (jsonBody) 'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty)
          'Authorization': 'Bearer $token',
      };

  Future<SerializdCredentials> login({
    required String email,
    required String password,
  }) async {
    final response = await _http.post(
      Uri.parse('$_base/login'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
      }),
    );
    final map = _decodeMap(response, action: 'login');
    if (response.statusCode >= 400) {
      final message = (map['message'] as String?)?.trim();
      throw Exception(
        message?.isNotEmpty == true
            ? message
            : 'Serializd login failed (${response.statusCode})',
      );
    }
    final token = (map['token'] as String?)?.trim() ?? '';
    if (token.isEmpty) {
      throw Exception('Serializd login returned no token');
    }
    return SerializdCredentials(
      accessToken: token,
      username: (map['username'] as String?)?.trim(),
    );
  }

  Future<bool> validate(SerializdCredentials creds) async {
    if (!creds.isAuthenticated) return false;
    try {
      final response = await _http.post(
        Uri.parse('$_base/validateauthtoken'),
        headers: _headers(jsonBody: true),
        body: jsonEncode({'token': creds.accessToken}),
      );
      if (response.statusCode >= 400) return false;
      final map = _decodeMap(response, action: 'validate', allowHtml: true);
      return map['isValid'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Pulls watching / watchlist / dropped / paused (+ watched when possible).
  Future<SerializdUserLists> getUserLists(SerializdCredentials creds) async {
    if (!creds.isAuthenticated) {
      return const SerializdUserLists();
    }
    final token = creds.accessToken!.trim();
    var username = creds.username?.trim();

    // Prefer username pages (richer titles/posters). Fall back to context.
    if (username == null || username.isEmpty) {
      final validated = await _validateForUsername(token);
      username = validated;
    }

    if (username != null && username.isNotEmpty) {
      try {
        final lists = await _fetchUsernameLists(username);
        if (!lists.isEmpty) {
          return SerializdUserLists(
            watching: lists.watching,
            watchlist: lists.watchlist,
            dropped: lists.dropped,
            paused: lists.paused,
            completed: lists.completed,
            username: username,
          );
        }
      } catch (_) {
        // Fall through to authenticated context.
      }
    }

    return _fetchUserContext(token, username: username);
  }

  Future<String?> _validateForUsername(String token) async {
    try {
      final response = await _http.post(
        Uri.parse('$_base/validateauthtoken'),
        headers: _headers(jsonBody: true),
        body: jsonEncode({'token': token}),
      );
      if (response.statusCode >= 400) return null;
      final map = _decodeMap(response, action: 'validate');
      if (map['isValid'] != true) return null;
      final name = (map['username'] as String?)?.trim();
      return (name != null && name.isNotEmpty) ? name : null;
    } catch (_) {
      return null;
    }
  }

  Future<SerializdUserLists> _fetchUsernameLists(String username) async {
    final enc = Uri.encodeComponent(username);
    Future<List<SerializdShowHit>> page(
      String pathSuffix,
      TrackerStatusKind status, {
      String itemsKey = 'items',
    }) async {
      final out = <SerializdShowHit>[];
      var pageNum = 1;
      var totalPages = 1;
      while (pageNum <= totalPages && pageNum <= 20) {
        final uri = Uri.parse(
          '$_base/user/$enc/$pathSuffix/$pageNum?sort_by=date_added_desc',
        );
        final response = await _http.get(uri, headers: _headers());
        if (response.statusCode >= 400) break;
        final map = _decodeMap(response, action: pathSuffix);
        totalPages = (map['totalPages'] as num?)?.toInt() ?? 1;
        final raw = map[itemsKey] ?? map['items'];
        if (raw is List) {
          for (final entry in raw) {
            if (entry is! Map) continue;
            final hit = _hitFromMap(
              entry.cast<String, dynamic>(),
              status: status,
            );
            if (hit != null) out.add(hit);
          }
        }
        pageNum++;
      }
      return out;
    }

    final watching =
        await page('currently_watching_page', TrackerStatusKind.watching);
    final watchlist = await page(
      'watchlistpage_v2',
      TrackerStatusKind.watchlist,
    );
    final dropped =
        await page('dropped_shows_page', TrackerStatusKind.dropped);
    final paused = await page('paused_shows_page', TrackerStatusKind.hold);
    final completed = await page(
      'watchedpage_v2',
      TrackerStatusKind.completed,
    );

    return SerializdUserLists(
      watching: watching,
      watchlist: watchlist,
      dropped: dropped,
      paused: paused,
      completed: completed,
      username: username,
    );
  }

  Future<SerializdUserLists> _fetchUserContext(
    String token, {
    String? username,
  }) async {
    final uri = Uri.parse('$_base/user_information').replace(
      queryParameters: {'shouldGetUserContext': 'true'},
    );
    final response = await _http.get(
      uri,
      headers: _headers(token: token),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'Serializd user lists failed (${response.statusCode})',
      );
    }
    final map = _decodeMap(response, action: 'user_information');
    final context =
        (map['context'] as Map?)?.cast<String, dynamic>() ?? const {};

    List<SerializdShowHit> parse(
      String key,
      TrackerStatusKind status,
    ) {
      final raw = context[key];
      if (raw is! List) return const [];
      final out = <SerializdShowHit>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final hit = _hitFromMap(
          entry.cast<String, dynamic>(),
          status: status,
        );
        if (hit != null) out.add(hit);
      }
      return out;
    }

    return SerializdUserLists(
      watching: parse('currentlyWatching', TrackerStatusKind.watching),
      watchlist: parse('watchlist', TrackerStatusKind.watchlist),
      dropped: parse('droppedShows', TrackerStatusKind.dropped),
      paused: parse('pausedShows', TrackerStatusKind.hold),
      completed: parse('watched', TrackerStatusKind.completed),
      username: username ?? (map['username'] as String?)?.trim(),
    );
  }

  /// Resolves TMDB season id for [seasonNumber] (needed to log episodes).
  Future<int?> resolveSeasonId({
    required int showId,
    required int seasonNumber,
  }) async {
    if (showId <= 0 || seasonNumber <= 0) return null;
    try {
      final response = await _http.get(
        Uri.parse('$_base/show/$showId/season/$seasonNumber'),
        headers: _headers(),
      );
      if (response.statusCode >= 400) return null;
      final map = _decodeMap(response, action: 'season');
      return (map['seasonId'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<bool> logEpisodes({
    required SerializdCredentials creds,
    required int showId,
    required int seasonId,
    required List<int> episodeNumbers,
  }) async {
    if (!creds.isAuthenticated ||
        showId <= 0 ||
        seasonId <= 0 ||
        episodeNumbers.isEmpty) {
      return false;
    }
    final response = await _http.post(
      Uri.parse('$_base/episode_log/add'),
      headers: _headers(token: creds.accessToken, jsonBody: true),
      body: jsonEncode({
        'showId': showId,
        'seasonId': seasonId,
        'episodeNumbers': episodeNumbers,
      }),
    );
    if (response.statusCode >= 400) {
      _decodeMap(response, action: 'log_episodes'); // surface message
      return false;
    }
    return true;
  }

  SerializdShowHit? _hitFromMap(
    Map<String, dynamic> json, {
    required TrackerStatusKind status,
  }) {
    final showId = (json['showId'] as num?)?.toInt() ??
        (json['show_id'] as num?)?.toInt() ??
        0;
    final title = (json['showName'] as String?)?.trim() ??
        (json['name'] as String?)?.trim() ??
        (json['title'] as String?)?.trim() ??
        '';
    if (showId <= 0 && title.isEmpty) return null;

    final seasonIdsRaw = json['seasonIds'] ?? json['season_ids'];
    final seasonIds = seasonIdsRaw is List
        ? seasonIdsRaw.whereType<num>().map((n) => n.toInt()).toList()
        : const <int>[];

    return SerializdShowHit(
      showId: showId,
      title: title.isNotEmpty ? title : 'TMDB $showId',
      status: status,
      posterUrl: _normalizeImage(
        (json['bannerImage'] as String?) ??
            (json['posterPath'] as String?) ??
            (json['posterUrl'] as String?),
      ),
      dateAdded: DateTime.tryParse(
        (json['dateAdded'] as String?) ??
            (json['date_added'] as String?) ??
            '',
      ),
      seasonIds: seasonIds,
    );
  }

  String? _normalizeImage(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('/')) {
      return 'https://image.tmdb.org/t/p/w500$value';
    }
    return value;
  }

  Map<String, dynamic> _decodeMap(
    http.Response response, {
    required String action,
    bool allowHtml = false,
  }) {
    final body = response.body.trim();
    if (body.isEmpty) return {};
    if (!allowHtml &&
        (body.startsWith('<!') ||
            body.toLowerCase().contains('vercel security'))) {
      throw Exception(
        'Serializd $action blocked (wrong host or bot check). '
        'Try again later.',
      );
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      throw Exception(
        'Serializd $action returned non-JSON (${response.statusCode})',
      );
    }
    return {};
  }
}
