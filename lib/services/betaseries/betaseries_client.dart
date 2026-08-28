import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/betaseries_models.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';

/// Thin BetaSeries API client (device OAuth + member show lists).
///
/// Docs: https://developers.betaseries.com/
class BetaseriesClient {
  BetaseriesClient({http.Client? httpClient})
      : _http = httpClient ?? createDnsFallbackHttpClient(),
        _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;
  static const _api = 'https://api.betaseries.com';
  static const _version = '3.0';
  static const _appName = 'javp';
  static const _appVersion = '0.1.0';

  void close() {
    if (_ownsClient) _http.close();
  }

  Map<String, String> _headers(BetaseriesCredentials creds, {bool json = true}) =>
      {
        'User-Agent': '$_appName/$_appVersion',
        'Accept': 'application/json',
        'X-BetaSeries-Version': _version,
        'X-BetaSeries-Key': creds.effectiveApiKey,
        if (json) 'Content-Type': 'application/x-www-form-urlencoded',
        if (creds.accessToken != null && creds.accessToken!.isNotEmpty)
          'Authorization': 'Bearer ${creds.accessToken}',
      };

  Future<bool> validate(BetaseriesCredentials creds) async {
    if (!creds.isAuthenticated) return false;
    try {
      final response = await _http.get(
        Uri.parse('$_api/members/infos'),
        headers: _headers(creds),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Starts device OAuth. Show [BetaseriesDeviceSession.userCode] and open
  /// [BetaseriesDeviceSession.verificationUri].
  Future<BetaseriesDeviceSession> requestDeviceCode(
    BetaseriesCredentials creds,
  ) async {
    if (!creds.isConfigured) {
      throw Exception('BetaSeries API key not configured');
    }
    final response = await _http.post(
      Uri.parse('$_api/oauth/device'),
      headers: _headers(creds),
      body: {
        'client_id': creds.effectiveApiKey,
      },
    );
    if (response.statusCode >= 400) {
      throw Exception('BetaSeries device code failed (${response.statusCode})');
    }
    final decoded = _decodeBody(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('BetaSeries device code returned unexpected body');
    }
    final session = BetaseriesDeviceSession.fromJson(decoded);
    if (session.userCode.isEmpty || session.deviceCode.isEmpty) {
      throw Exception('BetaSeries device code returned empty codes');
    }
    return session;
  }

  /// Polls until the user authorizes, then returns the member token.
  Future<BetaseriesTokenResult> waitForDeviceToken({
    required BetaseriesCredentials creds,
    required BetaseriesDeviceSession session,
    required bool Function() isCancelled,
  }) async {
    if (!creds.isConfigured) {
      throw Exception('BetaSeries API key not configured');
    }
    final secret = creds.effectiveApiSecret;
    if (secret.isEmpty) {
      throw Exception(
        'BetaSeries API secret required for device login — set it under Developer',
      );
    }
    final deadline = DateTime.now().add(Duration(seconds: session.expiresIn));
    var interval = Duration(seconds: session.interval.clamp(3, 30));

    while (true) {
      if (isCancelled()) throw Exception('BetaSeries device login cancelled');
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('BetaSeries device code expired — request a new one');
      }

      final response = await _http.post(
        Uri.parse('$_api/oauth/access_token'),
        headers: _headers(creds),
        body: {
          'client_id': creds.effectiveApiKey,
          'client_secret': secret,
          'code': session.deviceCode,
        },
      );

      if (response.statusCode == 200) {
        final decoded = _decodeBody(response.body);
        if (decoded is Map<String, dynamic>) {
          final token = BetaseriesTokenResult.fromJson(decoded);
          if (token.accessToken.isNotEmpty) return token;
        }
        // Form body: access_token=…
        final form = Uri.splitQueryString(response.body);
        final access = (form['access_token'] ?? form['token'] ?? '').trim();
        if (access.isNotEmpty) {
          return BetaseriesTokenResult(
            accessToken: access,
            login: form['login'],
          );
        }
        throw Exception('BetaSeries token response missing access_token');
      }

      // Pending / slow_down — keep polling (BetaSeries often returns 400 + errors).
      if (response.statusCode == 400 || response.statusCode == 401) {
        final decoded = _decodeBody(response.body);
        final err = _firstErrorCode(decoded);
        if (err == 'slow_down') {
          interval = Duration(seconds: (interval.inSeconds * 2).clamp(5, 30));
          await Future<void>.delayed(interval);
          continue;
        }
        if (err == 'authorization_pending' ||
            err == 'pending' ||
            err == 'waiting' ||
            err.isEmpty) {
          await Future<void>.delayed(interval);
          continue;
        }
        if (err == 'expired_token' || err == 'expired') {
          throw Exception('BetaSeries device code expired — request a new one');
        }
        if (err == 'access_denied' || err == 'denied') {
          throw Exception('BetaSeries authorization denied');
        }
        await Future<void>.delayed(interval);
        continue;
      }

      throw Exception('BetaSeries device token failed (${response.statusCode})');
    }
  }

  /// Pull member lists for My List + status store. Fail soft per bucket.
  Future<BetaseriesUserLists> getUserLists(BetaseriesCredentials creds) async {
    if (!creds.isAuthenticated) return const BetaseriesUserLists();
    final watching = await _memberShows(creds, status: 'current');
    final plan = await _memberShows(creds, status: 'not_started');
    final dropped = await _memberShows(creds, status: 'stopped');
    final completed = await _memberShows(creds, status: 'completed');
    return BetaseriesUserLists(
      watching: watching,
      planToWatch: plan,
      dropped: dropped,
      completed: completed,
    );
  }

  Future<List<BetaseriesShowHit>> _memberShows(
    BetaseriesCredentials creds, {
    required String status,
  }) async {
    final statusKind = BetaseriesShowHit.statusFromApiFilter(status);
    final out = <BetaseriesShowHit>[];
    var offset = 0;
    const limit = 100;
    // Cap pages so a huge account cannot stall sync forever.
    for (var page = 0; page < 8; page++) {
      try {
        final uri = Uri.parse('$_api/shows/member').replace(
          queryParameters: {
            'status': status,
            'limit': '$limit',
            'offset': '$offset',
            'order': 'last_seen',
            'summary': 'true',
            'includes': 'user',
          },
        );
        final response = await _http.get(uri, headers: _headers(creds));
        if (response.statusCode >= 400) break;
        final decoded = _decodeBody(response.body);
        if (decoded is! Map<String, dynamic>) break;
        final shows = decoded['shows'];
        if (shows is! List || shows.isEmpty) break;
        var added = 0;
        for (final raw in shows) {
          if (raw is! Map) continue;
          final hit = BetaseriesShowHit.fromApiShow(
            raw.cast<String, dynamic>(),
            status: statusKind,
          );
          if (hit == null) continue;
          out.add(hit);
          added += 1;
        }
        if (added < limit) break;
        offset += limit;
      } catch (_) {
        break;
      }
    }
    return out;
  }

  /// Mark episode watched (scrobble). Optional for v1 callers; fail soft.
  Future<bool> markEpisodeWatched(
    BetaseriesCredentials creds, {
    int? episodeId,
    int? tvdbEpisodeId,
    bool bulk = true,
  }) async {
    if (!creds.isAuthenticated) return false;
    if ((episodeId == null || episodeId <= 0) &&
        (tvdbEpisodeId == null || tvdbEpisodeId <= 0)) {
      return false;
    }
    try {
      final body = <String, String>{
        if (episodeId != null && episodeId > 0) 'id': '$episodeId',
        if (tvdbEpisodeId != null && tvdbEpisodeId > 0)
          'thetvdb_id': '$tvdbEpisodeId',
        'bulk': bulk ? 'true' : 'false',
      };
      final response = await _http.post(
        Uri.parse('$_api/episodes/watched'),
        headers: _headers(creds),
        body: body,
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Object? _decodeBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      // access_token=… form response
      if (trimmed.contains('=')) {
        return Map<String, dynamic>.from(Uri.splitQueryString(trimmed));
      }
      return null;
    }
  }

  String _firstErrorCode(Object? decoded) {
    if (decoded is! Map) return '';
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      if (first is Map) {
        return '${first['code'] ?? first['type'] ?? first['text'] ?? ''}'
            .trim()
            .toLowerCase();
      }
      return '$first'.trim().toLowerCase();
    }
    return '${decoded['error'] ?? ''}'.trim().toLowerCase();
  }
}
