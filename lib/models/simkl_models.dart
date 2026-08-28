import 'package:javp/services/trackers/device_pin_uri.dart';

class SimklCredentials {
  const SimklCredentials({
    required this.clientId,
    this.accessToken,
  });

  /// JAVP-bundled client id — used when the user has not set their own.
  static const bundledClientId =
      '3b1766f995a653063883bbad334e540502700c1c98efb83ca0b39c29acba1d73';

  final String clientId;
  final String? accessToken;

  /// Client id sent to SIMKL (custom override, else bundled).
  String get effectiveClientId {
    final custom = clientId.trim();
    if (custom.isNotEmpty) return custom;
    return bundledClientId;
  }

  bool get usesBundledClientId => clientId.trim().isEmpty;

  bool get isConfigured => effectiveClientId.isNotEmpty;
  bool get isAuthenticated =>
      isConfigured && accessToken != null && accessToken!.isNotEmpty;

  SimklCredentials copyWith({String? clientId, String? accessToken}) {
    return SimklCredentials(
      clientId: clientId ?? this.clientId,
      accessToken: accessToken ?? this.accessToken,
    );
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'accessToken': accessToken,
      };

  factory SimklCredentials.fromJson(Map<String, dynamic> json) {
    return SimklCredentials(
      clientId: json['clientId'] as String? ?? '',
      accessToken: json['accessToken'] as String?,
    );
  }
}

/// Result of `GET /oauth/pin` — show [userCode] and open [verificationUri].
class SimklPinSession {
  const SimklPinSession({
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    this.verificationUriComplete,
  });

  final String userCode;
  final Uri verificationUri;
  /// RFC 8628 complete URI when SIMKL includes the code in the link.
  final Uri? verificationUriComplete;
  final int expiresIn;
  final int interval;

  /// URL encoded in a TV/desktop QR (complete URI when present).
  Uri get scanUri =>
      devicePinScanUri(verificationUri, verificationUriComplete);

  factory SimklPinSession.fromJson(Map<String, dynamic> json) {
    final uriCandidate = (json['verification_uri'] as String?)?.trim();
    final uriFallback = (json['verification_url'] as String?)?.trim();
    final uriRaw = (uriCandidate != null && uriCandidate.isNotEmpty)
        ? uriCandidate
        : (uriFallback != null && uriFallback.isNotEmpty)
            ? uriFallback
            : 'https://simkl.com/pin';
    return SimklPinSession(
      userCode: (json['user_code'] as String? ?? '').trim(),
      verificationUri: Uri.parse(uriRaw),
      verificationUriComplete: parseOptionalUri(
        json['verification_uri_complete'] as String?,
      ),
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }
}

enum SimklWatchStatus { watching, completed, plantowatch, hold, dropped }

class SimklScrobbleEvent {
  const SimklScrobbleEvent({
    required this.title,
    required this.progress,
    required this.status,
    this.year,
    this.simklId,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.seasonNumber,
    this.episodeNumber,
    this.isShow = false,
  });

  final String title;
  final double progress;
  final SimklWatchStatus status;
  final int? year;
  final String? simklId;
  final int? tmdbId;
  final String? imdbId;
  final int? tvdbId;
  final int? seasonNumber;
  final int? episodeNumber;

  /// When true, payload goes under `shows` (TMDB tv namespace); else `movies`.
  final bool isShow;

  Map<String, dynamic> toJson() => {
        'title': title,
        'progress': progress,
        'status': status.name,
        'year': year,
        'simklId': simklId,
        'tmdbId': tmdbId,
        'imdbId': imdbId,
        'tvdbId': tvdbId,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'isShow': isShow,
      };

  factory SimklScrobbleEvent.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String? ?? 'watching';
    return SimklScrobbleEvent(
      title: json['title'] as String? ?? '',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      status: SimklWatchStatus.values.asNameMap()[statusName] ??
          SimklWatchStatus.watching,
      year: (json['year'] as num?)?.toInt(),
      simklId: json['simklId'] as String?,
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      imdbId: json['imdbId'] as String?,
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      isShow: json['isShow'] as bool? ?? false,
    );
  }

  /// Builds the `/sync/history` body Simkl expects.
  ///
  /// Important: for shows, `status: completed` with no `seasons`/`episodes`
  /// marks the **entire series** watched. Episode scrobbles must nest the
  /// episode and must not send show-level `completed`.
  ///
  /// Mid-watch "put on Watching" must send **status only** — nesting an
  /// episode in `/sync/history` marks that episode watched on Simkl.
  Map<String, dynamic> toHistoryPayload() {
    final ids = <String, dynamic>{};
    final simkl = simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) {
      ids['simkl'] = int.tryParse(simkl) ?? simkl;
    }
    if (tmdbId != null && tmdbId! > 0) {
      ids['tmdb'] = tmdbId;
    }
    final imdb = imdbId?.trim();
    if (imdb != null && imdb.isNotEmpty) {
      ids['imdb'] = imdb;
    }
    if (tvdbId != null && tvdbId! > 0) {
      ids['tvdb'] = tvdbId;
    }

    final item = <String, dynamic>{
      if (ids.isNotEmpty) 'ids': ids,
      'title': title,
      if (year != null) 'year': year,
    };

    if (isShow) {
      final season = seasonNumber;
      final episode = episodeNumber;
      final hasEpisode = episode != null && episode > 0;
      final hasSeason = season != null && season > 0;
      final markEpisodeWatched =
          status == SimklWatchStatus.completed && hasEpisode;

      // Never escalate to series-complete from playback.
      item['status'] = SimklWatchStatus.watching.name;

      if (markEpisodeWatched) {
        if (hasSeason) {
          item['seasons'] = [
            {
              'number': season,
              'episodes': [
                {'number': episode},
              ],
            },
          ];
        } else {
          // Anime sequential / single-season: Simkl wraps to season 1.
          item['episodes'] = [
            {'number': episode},
          ];
        }
      }
      return {
        'shows': [item],
      };
    }

    item['status'] = status.name;
    return {
      'movies': [item],
    };
  }
}

/// Shared external IDs from a Simkl media object (`show` / `movie` / `anime`).
class SimklIds {
  const SimklIds({
    this.simkl,
    this.tmdb,
    this.imdb,
    this.tvdb,
    this.anilist,
    this.slug,
  });

  final String? simkl;
  final int? tmdb;
  final String? imdb;
  final int? tvdb;
  /// AniList media id — used by anime / custom catalogs.
  final int? anilist;
  final String? slug;

  factory SimklIds.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SimklIds();
    return SimklIds(
      simkl: _idString(json['simkl']),
      tmdb: _idInt(json['tmdb']),
      imdb: (json['imdb'] as String?)?.trim(),
      tvdb: _idInt(json['tvdb']),
      anilist: _idInt(json['anilist'] ?? json['anilist_id']),
      slug: (json['slug'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (simkl != null) 'simkl': simkl,
        if (tmdb != null) 'tmdb': tmdb,
        if (imdb != null) 'imdb': imdb,
        if (tvdb != null) 'tvdb': tvdb,
        if (anilist != null) 'anilist': anilist,
        if (slug != null) 'slug': slug,
      };

  static String? _idString(Object? raw) {
    if (raw == null) return null;
    final s = '$raw'.trim();
    return s.isEmpty ? null : s;
  }

  static int? _idInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}

/// Builds a full poster URL from a Simkl poster path fragment.
String? simklPosterUrl(String? poster) {
  final p = poster?.trim();
  if (p == null || p.isEmpty) return null;
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  return 'https://simkl.in/posters/${p}_m.jpg';
}

/// One row from `GET /sync/all-items/{type}/watching`.
class SimklLibraryItem {
  const SimklLibraryItem({
    required this.title,
    required this.isShow,
    required this.ids,
    this.year,
    this.posterUrl,
    this.watchedEpisodes,
    this.totalEpisodes,
    this.nextToWatch,
    this.lastWatchedAt,
    this.status,
  });

  final String title;
  final bool isShow;
  final SimklIds ids;
  final int? year;
  final String? posterUrl;
  final int? watchedEpisodes;
  final int? totalEpisodes;
  final String? nextToWatch;
  final DateTime? lastWatchedAt;
  /// Simkl watchlist bucket (`watching`, `completed`, …).
  final String? status;

  bool get isWatchingStatus {
    final s = status?.trim().toLowerCase();
    // Watching endpoint rows sometimes omit status; treat missing as watching.
    return s == null || s.isEmpty || s == 'watching';
  }

  bool get isPlanToWatchStatus {
    final s = status?.trim().toLowerCase();
    return s == 'plantowatch' || s == 'plan to watch' || s == 'plan_to_watch';
  }

  /// Watched count for shelf labels / series %, aligned with inbound merge:
  /// when `next_to_watch` falls inside the watched prefix (e.g. count=5 +
  /// next S01E05), use episodes-before-next so `N/M eps` matches local badges
  /// (next-up is not marked watched).
  int? get displayWatchedEpisodes {
    final watched = watchedEpisodes;
    if (watched == null) return null;
    final next = _parseNextToWatch(nextToWatch);
    if (next == null) return watched;
    final ns = next.$1;
    final ne = next.$2;
    // Single-season (and anime absolute) next labels are safe to reconcile.
    if (ns == 1 && ne > 0) {
      final beforeNext = ne - 1;
      if (beforeNext >= 0 && watched > beforeNext) return beforeNext;
    }
    return watched;
  }

  /// 0–1 series progress from watched/total episode counts.
  double? get episodeProgress {
    final watched = displayWatchedEpisodes;
    final total = totalEpisodes;
    if (watched == null || total == null || total <= 0) return null;
    return (watched / total).clamp(0.0, 1.0);
  }

  String? get progressSubtitle {
    final parts = <String>[];
    final watched = displayWatchedEpisodes;
    final total = totalEpisodes;
    if (watched != null && total != null && total > 0) {
      parts.add('$watched/$total eps');
    }
    final next = nextToWatch?.trim();
    if (next != null && next.isNotEmpty) {
      parts.add('Next $next');
    }
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  static (int, int)? _parseNextToWatch(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final se = RegExp(r'[Ss](\d{1,2})\s*[Ee](\d{1,3})').firstMatch(text);
    if (se != null) {
      return (int.parse(se.group(1)!), int.parse(se.group(2)!));
    }
    final x = RegExp(r'(\d{1,2})\s*[xX]\s*(\d{1,3})').firstMatch(text);
    if (x != null) {
      return (int.parse(x.group(1)!), int.parse(x.group(2)!));
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'isShow': isShow,
        'ids': ids.toJson(),
        'year': year,
        'posterUrl': posterUrl,
        'watchedEpisodes': watchedEpisodes,
        'totalEpisodes': totalEpisodes,
        'nextToWatch': nextToWatch,
        'lastWatchedAt': lastWatchedAt?.toIso8601String(),
        'status': status,
      };

  factory SimklLibraryItem.fromJson(Map<String, dynamic> json) {
    return SimklLibraryItem(
      title: json['title'] as String? ?? '',
      isShow: json['isShow'] as bool? ?? true,
      ids: SimklIds.fromJson(
        (json['ids'] as Map?)?.cast<String, dynamic>(),
      ),
      year: (json['year'] as num?)?.toInt(),
      posterUrl: json['posterUrl'] as String?,
      watchedEpisodes: (json['watchedEpisodes'] as num?)?.toInt(),
      totalEpisodes: (json['totalEpisodes'] as num?)?.toInt(),
      nextToWatch: json['nextToWatch'] as String?,
      lastWatchedAt: DateTime.tryParse(json['lastWatchedAt'] as String? ?? ''),
      status: json['status'] as String?,
    );
  }

  /// Parses one entry from `/sync/all-items` (show / anime / movie wrapper).
  factory SimklLibraryItem.fromSyncEntry(
    Map<String, dynamic> entry, {
    required String mediaKey,
  }) {
    // Anime payloads nest under `show` (same as TV); fall back across keys.
    final media = (entry[mediaKey] as Map?)?.cast<String, dynamic>() ??
        (entry['show'] as Map?)?.cast<String, dynamic>() ??
        (entry['anime'] as Map?)?.cast<String, dynamic>() ??
        (entry['movie'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final ids = SimklIds.fromJson(
      (media['ids'] as Map?)?.cast<String, dynamic>(),
    );
    final status = (entry['status'] as String?)?.trim().toLowerCase();
    return SimklLibraryItem(
      title: (media['title'] as String?)?.trim() ?? '',
      isShow: mediaKey != 'movie',
      ids: ids,
      year: (media['year'] as num?)?.toInt(),
      posterUrl: simklPosterUrl(media['poster'] as String?),
      watchedEpisodes: (entry['watched_episodes_count'] as num?)?.toInt(),
      totalEpisodes: (entry['total_episodes_count'] as num?)?.toInt(),
      nextToWatch: (entry['next_to_watch'] as String?)?.trim(),
      lastWatchedAt: DateTime.tryParse(
        entry['last_watched_at'] as String? ?? '',
      ),
      status: status,
    );
  }
}

/// Paused playback from `GET /sync/playback` (`progress` is 0–100 from API).
class SimklPlayback {
  const SimklPlayback({
    required this.progress,
    required this.isShow,
    required this.ids,
    required this.title,
    this.year,
    this.posterUrl,
    this.seasonNumber,
    this.episodeNumber,
    this.pausedAt,
  });

  /// Normalized 0–1 playhead.
  final double progress;
  final bool isShow;
  final SimklIds ids;
  final String title;
  final int? year;
  final String? posterUrl;
  final int? seasonNumber;
  final int? episodeNumber;
  final DateTime? pausedAt;

  Map<String, dynamic> toJson() => {
        'progress': progress,
        'isShow': isShow,
        'ids': ids.toJson(),
        'title': title,
        'year': year,
        'posterUrl': posterUrl,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'pausedAt': pausedAt?.toIso8601String(),
      };

  factory SimklPlayback.fromJson(Map<String, dynamic> json) {
    return SimklPlayback(
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      isShow: json['isShow'] as bool? ?? false,
      ids: SimklIds.fromJson(
        (json['ids'] as Map?)?.cast<String, dynamic>(),
      ),
      title: json['title'] as String? ?? '',
      year: (json['year'] as num?)?.toInt(),
      posterUrl: json['posterUrl'] as String?,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      pausedAt: DateTime.tryParse(json['pausedAt'] as String? ?? ''),
    );
  }

  factory SimklPlayback.fromApiEntry(Map<String, dynamic> entry) {
    final movie = (entry['movie'] as Map?)?.cast<String, dynamic>();
    final show = (entry['show'] as Map?)?.cast<String, dynamic>();
    final episode = (entry['episode'] as Map?)?.cast<String, dynamic>();
    final media = movie ?? show ?? const <String, dynamic>{};
    final isShow = movie == null;
    final pct = (entry['progress'] as num?)?.toDouble() ?? 0;
    return SimklPlayback(
      progress: (pct / 100).clamp(0.0, 1.0),
      isShow: isShow,
      ids: SimklIds.fromJson(
        (media['ids'] as Map?)?.cast<String, dynamic>(),
      ),
      title: (media['title'] as String?)?.trim() ?? '',
      year: (media['year'] as num?)?.toInt(),
      posterUrl: simklPosterUrl(media['poster'] as String?),
      seasonNumber: (episode?['season'] as num?)?.toInt(),
      episodeNumber: (episode?['number'] as num?)?.toInt() ??
          (episode?['episode'] as num?)?.toInt(),
      pausedAt: DateTime.tryParse(entry['paused_at'] as String? ?? ''),
    );
  }
}

/// Timestamps from `GET /sync/activities` used to gate re-fetch.
class SimklActivities {
  const SimklActivities({
    this.tvWatching,
    this.animeWatching,
    this.moviesWatching,
    this.tvPlanToWatch,
    this.animePlanToWatch,
    this.moviesPlanToWatch,
    this.tvDropped,
    this.animeDropped,
    this.moviesDropped,
    this.tvCompleted,
    this.animeCompleted,
    this.moviesCompleted,
    this.tvHold,
    this.animeHold,
    this.playback,
    this.raw = const {},
  });

  final String? tvWatching;
  final String? animeWatching;
  final String? moviesWatching;
  final String? tvPlanToWatch;
  final String? animePlanToWatch;
  final String? moviesPlanToWatch;
  final String? tvDropped;
  final String? animeDropped;
  final String? moviesDropped;
  final String? tvCompleted;
  final String? animeCompleted;
  final String? moviesCompleted;
  final String? tvHold;
  final String? animeHold;
  final String? playback;
  final Map<String, dynamic> raw;

  bool watchingUnchanged(SimklActivities? previous) {
    if (previous == null) return false;
    return tvWatching == previous.tvWatching &&
        animeWatching == previous.animeWatching &&
        moviesWatching == previous.moviesWatching;
  }

  bool planToWatchUnchanged(SimklActivities? previous) {
    if (previous == null) return false;
    return tvPlanToWatch == previous.tvPlanToWatch &&
        animePlanToWatch == previous.animePlanToWatch &&
        moviesPlanToWatch == previous.moviesPlanToWatch;
  }

  bool playbackUnchanged(SimklActivities? previous) {
    if (previous == null) return false;
    return playback == previous.playback;
  }

  bool statusBucketsUnchanged(SimklActivities? previous) {
    if (previous == null) return false;
    return tvDropped == previous.tvDropped &&
        animeDropped == previous.animeDropped &&
        moviesDropped == previous.moviesDropped &&
        tvCompleted == previous.tvCompleted &&
        animeCompleted == previous.animeCompleted &&
        moviesCompleted == previous.moviesCompleted &&
        tvHold == previous.tvHold &&
        animeHold == previous.animeHold;
  }

  /// Best ISO stamp to pass as `date_from` on continuous `/sync/all-items`.
  String? get dateFromStamp {
    final candidates = <String>[
      if (tvWatching != null && tvWatching!.isNotEmpty) tvWatching!,
      if (animeWatching != null && animeWatching!.isNotEmpty) animeWatching!,
      if (moviesWatching != null && moviesWatching!.isNotEmpty) moviesWatching!,
      if (tvPlanToWatch != null && tvPlanToWatch!.isNotEmpty) tvPlanToWatch!,
      if (animePlanToWatch != null && animePlanToWatch!.isNotEmpty)
        animePlanToWatch!,
      if (moviesPlanToWatch != null && moviesPlanToWatch!.isNotEmpty)
        moviesPlanToWatch!,
      if (tvDropped != null && tvDropped!.isNotEmpty) tvDropped!,
      if (animeDropped != null && animeDropped!.isNotEmpty) animeDropped!,
      if (moviesDropped != null && moviesDropped!.isNotEmpty) moviesDropped!,
      if (tvCompleted != null && tvCompleted!.isNotEmpty) tvCompleted!,
      if (animeCompleted != null && animeCompleted!.isNotEmpty) animeCompleted!,
      if (moviesCompleted != null && moviesCompleted!.isNotEmpty)
        moviesCompleted!,
      if (tvHold != null && tvHold!.isNotEmpty) tvHold!,
      if (animeHold != null && animeHold!.isNotEmpty) animeHold!,
      if (playback != null && playback!.isNotEmpty) playback!,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort();
    return candidates.last;
  }

  Map<String, dynamic> toJson() => {
        'tvWatching': tvWatching,
        'animeWatching': animeWatching,
        'moviesWatching': moviesWatching,
        'tvPlanToWatch': tvPlanToWatch,
        'animePlanToWatch': animePlanToWatch,
        'moviesPlanToWatch': moviesPlanToWatch,
        'tvDropped': tvDropped,
        'animeDropped': animeDropped,
        'moviesDropped': moviesDropped,
        'tvCompleted': tvCompleted,
        'animeCompleted': animeCompleted,
        'moviesCompleted': moviesCompleted,
        'tvHold': tvHold,
        'animeHold': animeHold,
        'playback': playback,
        'raw': raw,
      };

  factory SimklActivities.fromJson(Map<String, dynamic> json) {
    return SimklActivities(
      tvWatching: json['tvWatching'] as String?,
      animeWatching: json['animeWatching'] as String?,
      moviesWatching: json['moviesWatching'] as String?,
      tvPlanToWatch: json['tvPlanToWatch'] as String?,
      animePlanToWatch: json['animePlanToWatch'] as String?,
      moviesPlanToWatch: json['moviesPlanToWatch'] as String?,
      tvDropped: json['tvDropped'] as String?,
      animeDropped: json['animeDropped'] as String?,
      moviesDropped: json['moviesDropped'] as String?,
      tvCompleted: json['tvCompleted'] as String?,
      animeCompleted: json['animeCompleted'] as String?,
      moviesCompleted: json['moviesCompleted'] as String?,
      tvHold: json['tvHold'] as String?,
      animeHold: json['animeHold'] as String?,
      playback: json['playback'] as String?,
      raw: (json['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  factory SimklActivities.fromApi(Map<String, dynamic> json) {
    Map<String, dynamic>? nest(String key) =>
        (json[key] as Map?)?.cast<String, dynamic>();
    final tv = nest('tv') ?? nest('shows');
    final anime = nest('anime') ?? nest('anime_lists');
    final movies = nest('movies') ?? nest('movie');
    final pb = nest('playback') ?? nest('playbacks');
    String? stampOf(Map<String, dynamic>? m, String key) {
      if (m == null) return null;
      final lists = (m['lists'] as Map?)?.cast<String, dynamic>() ?? m;
      return (lists[key] ?? m[key])?.toString();
    }

    String? watchingOf(Map<String, dynamic>? m) {
      if (m == null) return null;
      final lists = (m['lists'] as Map?)?.cast<String, dynamic>() ?? m;
      return (lists['watching'] ?? m['watching'] ?? m['all'])?.toString();
    }

    return SimklActivities(
      tvWatching: watchingOf(tv),
      animeWatching: watchingOf(anime),
      moviesWatching: watchingOf(movies),
      tvPlanToWatch: stampOf(tv, 'plantowatch'),
      animePlanToWatch: stampOf(anime, 'plantowatch'),
      moviesPlanToWatch: stampOf(movies, 'plantowatch'),
      tvDropped: stampOf(tv, 'dropped'),
      animeDropped: stampOf(anime, 'dropped'),
      moviesDropped: stampOf(movies, 'dropped'),
      tvCompleted: stampOf(tv, 'completed'),
      animeCompleted: stampOf(anime, 'completed'),
      moviesCompleted: stampOf(movies, 'completed'),
      tvHold: stampOf(tv, 'hold'),
      animeHold: stampOf(anime, 'hold'),
      playback: (pb?['all'] ?? pb?['episodes'] ?? pb?['movies'])?.toString(),
      raw: json,
    );
  }
}

/// Offline / failed Simkl scrobble waiting to sync when connectivity returns.
class PendingSimklScrobble {
  const PendingSimklScrobble({
    required this.mediaId,
    required this.event,
    required this.queuedAt,
  });

  final String mediaId;
  final SimklScrobbleEvent event;
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        'event': event.toJson(),
        'queuedAt': queuedAt.toIso8601String(),
      };

  factory PendingSimklScrobble.fromJson(Map<String, dynamic> json) {
    return PendingSimklScrobble(
      mediaId: json['mediaId'] as String? ?? '',
      event: SimklScrobbleEvent.fromJson(
        (json['event'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// One entry from detail `users_recommendations` (similar titles).
class SimklRecHit {
  const SimklRecHit({
    required this.title,
    required this.ids,
    this.year,
    this.type,
  });

  final String title;
  final SimklIds ids;
  final int? year;
  /// `movie` / `tv` / `anime` when present.
  final String? type;

  static List<SimklRecHit> listFromDetail(Map<String, dynamic> detail) {
    final raw = detail['users_recommendations'] as List? ?? const [];
    final out = <SimklRecHit>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final title = (map['title'] as String?)?.trim() ?? '';
      final ids = SimklIds.fromJson(
        (map['ids'] as Map?)?.cast<String, dynamic>(),
      );
      if (title.isEmpty &&
          ids.simkl == null &&
          ids.tmdb == null &&
          ids.imdb == null) {
        continue;
      }
      out.add(
        SimklRecHit(
          title: title,
          ids: ids,
          year: (map['year'] as num?)?.toInt(),
          type: (map['type'] as String?)?.trim(),
        ),
      );
    }
    return out;
  }
}
