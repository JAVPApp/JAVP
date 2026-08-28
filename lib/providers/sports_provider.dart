import 'package:flutter/foundation.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/sports/sports_channel_matcher.dart';
import 'package:javp/services/sports/the_sports_db_client.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/storage/sports_prefs_store.dart';

class MatchedSportsFixture {
  const MatchedSportsFixture({required this.fixture, this.match});

  final SportsFixture fixture;
  final SportsChannelMatch? match;
}

class SportsProvider extends ChangeNotifier {
  SportsProvider({
    SportsPrefsStore? keyStore,
    LibraryStore? libraryStore,
    TheSportsDbClient? client,
    this.onSyncableChanged,
  }) : _keyStore = keyStore ?? SportsPrefsStore(),
       _libraryStore = libraryStore ?? LibraryStore(),
       _injectedClient = client;

  final SportsPrefsStore _keyStore;
  LibraryStore _libraryStore;
  final TheSportsDbClient? _injectedClient;

  /// Fired after follow lists are written so profile sync can push them.
  void Function()? onSyncableChanged;

  SportsPrefs _prefs = SportsPrefs.empty;
  List<MatchedSportsFixture> _today = const [];
  bool _loading = false;
  String? _error;
  Future<void>? _bootstrapFuture;

  /// Day + prefs + library fingerprint for the last successful refresh.
  String? _refreshCacheKey;

  /// Bumped on profile switch so in-flight refreshes cannot publish stale matches.
  int _profileEpoch = 0;

  /// Bumped at the start of each refresh so overlapping refreshes drop losers.
  int _refreshSeq = 0;

  SportsPrefs get prefs => _prefs;
  List<MatchedSportsFixture> get todayFixtures => _today;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasFollows =>
      _prefs.followedLeagueIds.isNotEmpty || _prefs.followedTeams.isNotEmpty;

  Future<void> bootstrap() {
    final inflight = _bootstrapFuture;
    if (inflight != null) return inflight;
    final future = _reloadPrefs();
    _bootstrapFuture = future;
    return future;
  }

  /// Load follows for [profileId] (API key stays device-global).
  Future<void> bindProfile(String profileId) async {
    _profileEpoch++;
    _refreshSeq++;
    _today = const [];
    _refreshCacheKey = null;
    _error = null;
    _loading = false;
    if (_libraryStore.profileId != profileId) {
      _libraryStore = LibraryStore(profileId: profileId);
    }
    _bootstrapFuture = null;
    _prefs = SportsPrefs.empty;
    notifyListeners();
    await bootstrap();
  }

  /// Re-read follows after Drive/WebDAV applied a remote sportsFollows section.
  Future<void> reloadFromStore() async {
    _bootstrapFuture = null;
    _refreshCacheKey = null;
    await bootstrap();
  }

  TheSportsDbClient _client() {
    return _injectedClient ?? TheSportsDbClient(apiKey: _prefs.apiKey);
  }

  Future<void> _reloadPrefs() async {
    final follows = await _libraryStore.loadSportsFollows();
    final apiKey = await _keyStore.loadApiKey();
    _prefs = follows.copyWith(apiKey: apiKey);
    notifyListeners();
  }

  Future<void> savePrefs(SportsPrefs next) async {
    await bootstrap();
    _prefs = next;
    await _libraryStore.saveSportsFollows(next);
    await _keyStore.saveApiKey(next.apiKey);
    onSyncableChanged?.call();
    // Follow/API changes must not reuse a stale filtered fixture list.
    _refreshCacheKey = null;
    notifyListeners();
  }

  String _prefsFingerprint() {
    final leagues = _prefs.followedLeagueIds.toList()..sort();
    final teams = [for (final t in _prefs.followedTeams) t.id]..sort();
    return '${_prefs.apiKey}|${leagues.join(',')}|${teams.join(',')}';
  }

  String _libraryFingerprint(LibraryProvider library) {
    final sourceIds = [for (final s in library.sources) s.id]..sort();
    return '${library.liveChannels.length}|${sourceIds.join(',')}';
  }

  Future<void> toggleLeague(SportsLeagueRef league, bool follow) async {
    await bootstrap();
    final ids = {..._prefs.followedLeagueIds};
    if (follow) {
      ids.add(league.id);
    } else {
      ids.remove(league.id);
    }
    await savePrefs(_prefs.copyWith(followedLeagueIds: ids));
  }

  Future<void> followTeam(SportsTeamRef team) async {
    await bootstrap();
    final teams = [
      for (final t in _prefs.followedTeams)
        if (t.id != team.id) t,
      team,
    ];
    await savePrefs(_prefs.copyWith(followedTeams: teams));
  }

  Future<void> unfollowTeam(String teamId) async {
    await bootstrap();
    final teams = [
      for (final t in _prefs.followedTeams)
        if (t.id != teamId) t,
    ];
    await savePrefs(_prefs.copyWith(followedTeams: teams));
  }

  Future<List<SportsTeamRef>> searchTeams(String query) {
    return _client().searchTeams(query);
  }

  Future<void> refreshToday(
    LibraryProvider library, {
    bool force = false,
  }) async {
    // Capture before any await so a mid-flight profile switch invalidates us.
    final epoch = _profileEpoch;
    await bootstrap();
    if (epoch != _profileEpoch) return;
    final day = DateTime.now();
    final dayKey = DateTime(day.year, day.month, day.day);
    final cacheKey =
        '${dayKey.toIso8601String()}|${_prefsFingerprint()}|${_libraryFingerprint(library)}';
    if (!force &&
        _refreshCacheKey == cacheKey &&
        _today.isNotEmpty &&
        _error == null) {
      return;
    }
    final seq = ++_refreshSeq;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final events = await _client().eventsForDay(dayKey);
      if (epoch != _profileEpoch || seq != _refreshSeq) return;
      final filtered = _filterFollowed(events);
      final channels = await _candidateChannels(library);
      if (epoch != _profileEpoch || seq != _refreshSeq) return;
      final matched = <MatchedSportsFixture>[
        for (final fixture in filtered)
          MatchedSportsFixture(
            fixture: fixture,
            match: SportsChannelMatcher.bestMatch(
              fixture: fixture,
              channels: channels,
              nowPlaying: library.nowPlayingFor,
            ),
          ),
      ];
      if (epoch != _profileEpoch || seq != _refreshSeq) return;
      _today = matched;
      _refreshCacheKey = cacheKey;
    } catch (e, st) {
      debugPrint('SportsProvider refresh failed: $e\n$st');
      if (epoch != _profileEpoch || seq != _refreshSeq) return;
      _error = e.toString();
      _today = const [];
      _refreshCacheKey = null;
    } finally {
      if (epoch == _profileEpoch && seq == _refreshSeq) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  List<SportsFixture> _filterFollowed(List<SportsFixture> events) {
    if (!hasFollows) {
      // No follows yet — show a short preview of today's slate so the screen
      // is not empty before the user picks leagues/teams.
      return events.take(40).toList(growable: false);
    }
    final leagueIds = _prefs.followedLeagueIds;
    final teamNames = {
      for (final t in _prefs.followedTeams) t.name.trim().toLowerCase(),
    };
    return events
        .where((e) {
          if (leagueIds.contains(e.leagueId)) return true;
          final home = e.homeTeam.trim().toLowerCase();
          final away = e.awayTeam.trim().toLowerCase();
          for (final name in teamNames) {
            if (name.isEmpty) continue;
            if (home == name ||
                away == name ||
                home.contains(name) ||
                away.contains(name) ||
                name.contains(home) ||
                name.contains(away)) {
              return true;
            }
          }
          return false;
        })
        .toList(growable: false);
  }

  Future<List<MediaItem>> _candidateChannels(LibraryProvider library) async {
    final out = <MediaItem>[];
    var offset = 0;
    const pageSize = 500;
    const maxChannels = 5000;
    while (out.length < maxChannels) {
      final page = await library.pageLiveChannels(
        offset: offset,
        limit: pageSize,
      );
      if (page.isEmpty) break;
      out.addAll(page);
      offset += page.length;
      if (page.length < pageSize) break;
    }
    final collapsed = library.collapseLiveQualities(out);
    if (collapsed.isNotEmpty) return collapsed;
    final legacy = [
      for (final c in library.liveChannels)
        if (library.parentalLock?.isLiveChannelHidden(c) != true) c,
    ];
    return library.collapseLiveQualities(legacy);
  }
}
