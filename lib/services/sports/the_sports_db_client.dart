import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/sports_models.dart';
import 'package:javp/services/network/app_http_client.dart';

/// TheSportsDB football schedule client (free tier / optional BYO key).
///
/// Docs: https://www.thesportsdb.com/api.php
/// Free/demo key `123` is rate-limited; users can paste their own key in Settings.
class TheSportsDbClient {
  TheSportsDbClient({http.Client? client, this.apiKey = defaultFreeApiKey})
    : _client = client;

  /// Public free/demo key documented by TheSportsDB.
  static const defaultFreeApiKey = '123';

  final http.Client? _client;
  final String apiKey;

  String get _effectiveKey {
    final k = apiKey.trim();
    return k.isEmpty ? defaultFreeApiKey : k;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.https(
      'www.thesportsdb.com',
      '/api/v1/json/$_effectiveKey/$path',
      query,
    );
  }

  Future<http.Client> _http() async => _client ?? await createAppHttpClient();

  /// Soccer fixtures for a calendar day (UTC date string `YYYY-MM-DD`).
  Future<List<SportsFixture>> eventsForDay(DateTime day) async {
    final date =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final client = await _http();
    final owns = _client == null;
    try {
      final res = await client
          .get(_uri('eventsday.php', {'d': date, 's': 'Soccer'}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('TheSportsDB HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body);
      if (body is! Map) return const [];
      final events = body['events'];
      if (events is! List) return const [];
      final out = <SportsFixture>[];
      for (final row in events) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        final fixture = _parseEvent(map);
        if (fixture != null) out.add(fixture);
      }
      out.sort((a, b) => a.kickoff.compareTo(b.kickoff));
      return out;
    } finally {
      if (owns) client.close();
    }
  }

  Future<List<SportsTeamRef>> searchTeams(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final client = await _http();
    final owns = _client == null;
    try {
      final res = await client
          .get(_uri('searchteams.php', {'t': q}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('TheSportsDB HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body);
      if (body is! Map) return const [];
      final teams = body['teams'];
      if (teams is! List) return const [];
      final out = <SportsTeamRef>[];
      for (final row in teams) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        if ((map['strSport'] as String?)?.toLowerCase() != 'soccer') continue;
        final id = '${map['idTeam'] ?? ''}'.trim();
        final name = (map['strTeam'] as String?)?.trim() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        out.add(
          SportsTeamRef(
            id: id,
            name: name,
            badgeUrl: (map['strBadge'] as String?)?.trim(),
          ),
        );
      }
      return out;
    } finally {
      if (owns) client.close();
    }
  }

  SportsFixture? _parseEvent(Map<String, dynamic> map) {
    final id = '${map['idEvent'] ?? ''}'.trim();
    final home = (map['strHomeTeam'] as String?)?.trim() ?? '';
    final away = (map['strAwayTeam'] as String?)?.trim() ?? '';
    if (id.isEmpty || home.isEmpty || away.isEmpty) return null;
    final leagueId = '${map['idLeague'] ?? ''}'.trim();
    final leagueName = (map['strLeague'] as String?)?.trim() ?? '';
    final ts = (map['strTimestamp'] as String?)?.trim();
    DateTime kickoff;
    if (ts != null && ts.isNotEmpty) {
      kickoff =
          DateTime.tryParse(ts)?.toLocal() ??
          DateTime.tryParse(
            '${map['dateEvent']}T${map['strTime']}',
          )?.toLocal() ??
          DateTime.now();
    } else {
      final date = (map['dateEvent'] as String?)?.trim() ?? '';
      final time = (map['strTime'] as String?)?.trim() ?? '00:00:00';
      kickoff = DateTime.tryParse('${date}T$time')?.toLocal() ?? DateTime.now();
    }
    return SportsFixture(
      id: id,
      leagueId: leagueId,
      leagueName: leagueName,
      homeTeam: home,
      awayTeam: away,
      kickoff: kickoff,
      homeScore: (map['intHomeScore'] as String?)?.trim(),
      awayScore: (map['intAwayScore'] as String?)?.trim(),
      status: (map['strStatus'] as String?)?.trim(),
      homeBadgeUrl: (map['strHomeTeamBadge'] as String?)?.trim(),
      awayBadgeUrl: (map['strAwayTeamBadge'] as String?)?.trim(),
    );
  }
}
