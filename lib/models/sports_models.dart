/// Football (soccer) schedule models for BYO sports → channel matching.
library;

class SportsLeagueRef {
  const SportsLeagueRef({required this.id, required this.name, this.country});

  final String id;
  final String name;
  final String? country;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (country != null) 'country': country,
  };

  factory SportsLeagueRef.fromJson(Map<String, dynamic> json) {
    return SportsLeagueRef(
      id: '${json['id']}',
      name: (json['name'] as String?)?.trim() ?? '',
      country: (json['country'] as String?)?.trim(),
    );
  }
}

class SportsTeamRef {
  const SportsTeamRef({required this.id, required this.name, this.badgeUrl});

  final String id;
  final String name;
  final String? badgeUrl;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (badgeUrl != null) 'badgeUrl': badgeUrl,
  };

  factory SportsTeamRef.fromJson(Map<String, dynamic> json) {
    return SportsTeamRef(
      id: '${json['id']}',
      name: (json['name'] as String?)?.trim() ?? '',
      badgeUrl: (json['badgeUrl'] as String?)?.trim(),
    );
  }
}

class SportsFixture {
  const SportsFixture({
    required this.id,
    required this.leagueId,
    required this.leagueName,
    required this.homeTeam,
    required this.awayTeam,
    required this.kickoff,
    this.homeScore,
    this.awayScore,
    this.status,
    this.homeBadgeUrl,
    this.awayBadgeUrl,
  });

  final String id;
  final String leagueId;
  final String leagueName;
  final String homeTeam;
  final String awayTeam;
  final DateTime kickoff;
  final String? homeScore;
  final String? awayScore;
  final String? status;
  final String? homeBadgeUrl;
  final String? awayBadgeUrl;

  String get title => '$homeTeam vs $awayTeam';

  bool get isLiveLike {
    final s = (status ?? '').toUpperCase();
    return s == 'LIVE' ||
        s == '1H' ||
        s == '2H' ||
        s == 'HT' ||
        s == 'ET' ||
        s == 'BT' ||
        s == 'P';
  }
}

/// Curated soccer leagues (TheSportsDB ids) shown in follow pickers.
const kCuratedSoccerLeagues = <SportsLeagueRef>[
  SportsLeagueRef(
    id: '4328',
    name: 'English Premier League',
    country: 'England',
  ),
  SportsLeagueRef(id: '4335', name: 'Spanish La Liga', country: 'Spain'),
  SportsLeagueRef(id: '4332', name: 'Italian Serie A', country: 'Italy'),
  SportsLeagueRef(id: '4331', name: 'German Bundesliga', country: 'Germany'),
  SportsLeagueRef(id: '4334', name: 'French Ligue 1', country: 'France'),
  SportsLeagueRef(id: '4480', name: 'UEFA Champions League'),
  SportsLeagueRef(id: '4481', name: 'UEFA Europa League'),
  SportsLeagueRef(
    id: '4346',
    name: 'American Major League Soccer',
    country: 'USA',
  ),
  SportsLeagueRef(
    id: '4330',
    name: 'Scottish Premiership',
    country: 'Scotland',
  ),
  SportsLeagueRef(id: '4396', name: 'FIFA World Cup'),
];

class SportsPrefs {
  const SportsPrefs({
    this.apiKey = '',
    this.followedLeagueIds = const {},
    this.followedTeams = const [],
  });

  /// Empty → use TheSportsDB free/demo key.
  final String apiKey;
  final Set<String> followedLeagueIds;
  final List<SportsTeamRef> followedTeams;

  static const empty = SportsPrefs();

  SportsPrefs copyWith({
    String? apiKey,
    Set<String>? followedLeagueIds,
    List<SportsTeamRef>? followedTeams,
  }) {
    return SportsPrefs(
      apiKey: apiKey ?? this.apiKey,
      followedLeagueIds: followedLeagueIds ?? this.followedLeagueIds,
      followedTeams: followedTeams ?? this.followedTeams,
    );
  }

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey,
    'followedLeagueIds': followedLeagueIds.toList()..sort(),
    'followedTeams': [for (final t in followedTeams) t.toJson()],
  };

  /// Follow lists only — empty map when nothing is followed so profile-sync
  /// empty-section seeding can adopt a remote copy.
  Map<String, dynamic> toFollowsJson() {
    if (followedLeagueIds.isEmpty && followedTeams.isEmpty) {
      return const <String, dynamic>{};
    }
    return {
      'followedLeagueIds': followedLeagueIds.toList()..sort(),
      'followedTeams': [for (final t in followedTeams) t.toJson()],
    };
  }

  factory SportsPrefs.fromJson(Map<String, dynamic> json) {
    final leagues = <String>{};
    final rawLeagues = json['followedLeagueIds'];
    if (rawLeagues is List) {
      for (final id in rawLeagues) {
        final s = '$id'.trim();
        if (s.isNotEmpty) leagues.add(s);
      }
    }
    final teams = <SportsTeamRef>[];
    final rawTeams = json['followedTeams'];
    if (rawTeams is List) {
      for (final row in rawTeams) {
        if (row is Map<String, dynamic>) {
          final t = SportsTeamRef.fromJson(row);
          if (t.id.isNotEmpty && t.name.isNotEmpty) teams.add(t);
        } else if (row is Map) {
          final t = SportsTeamRef.fromJson(Map<String, dynamic>.from(row));
          if (t.id.isNotEmpty && t.name.isNotEmpty) teams.add(t);
        }
      }
    }
    return SportsPrefs(
      apiKey: (json['apiKey'] as String?)?.trim() ?? '',
      followedLeagueIds: leagues,
      followedTeams: teams,
    );
  }
}
