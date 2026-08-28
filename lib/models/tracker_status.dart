/// Tracker-agnostic watch status for inbound sync (SIMKL / Trakt / Serializd /
/// Letterboxd / …).
///
/// Used to exclude Dropped / Hold / Completed from Continue Watching / For You
/// and to merge remote playhead when a tracker is ahead of local history.
enum TrackerStatusKind {
  watching,
  completed,
  watchlist,
  planToWatch,
  hold,
  dropped,
}

/// One remote status / progress row, keyed for catalog match (prefer TMDB / IMDB).
///
/// [source] is a stable string id (`simkl`, `trakt`, `serializd`, `letterboxd`).
class TrackerStatusEntry {
  const TrackerStatusEntry({
    required this.source,
    required this.status,
    required this.title,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.anilistId,
    this.simklId,
    this.year,
    this.progress,
    this.seasonNumber,
    this.episodeNumber,
    this.watchedEpisodes,
    this.totalEpisodes,
    this.updatedAt,
    this.rating,
    this.moviesOnly = false,
    this.key,
  });

  final String source;
  final TrackerStatusKind status;
  final String title;
  final int? tmdbId;
  final String? imdbId;
  final int? tvdbId;
  final int? anilistId;
  final String? simklId;
  final int? year;

  /// 0–1 playhead or series progress when the tracker exposes it.
  final double? progress;
  final int? seasonNumber;
  final int? episodeNumber;

  /// Exact watched / total episode counts when the tracker exposes them
  /// (Simkl `watched_episodes_count`, BetaSeries `user.seen`, …).
  final int? watchedEpisodes;
  final int? totalEpisodes;
  final DateTime? updatedAt;
  final double? rating;

  /// Letterboxd (and similar) movie-only imports.
  final bool moviesOnly;

  /// Optional provider-native stable key (e.g. Letterboxd URI slug).
  final String? key;

  /// Stable identity for merge / CW exclusion maps.
  String get identityKey {
    if (anilistId != null && anilistId! > 0) return 'al:$anilistId';
    if (tmdbId != null && tmdbId! > 0) return 'tmdb:$tmdbId';
    final imdb = imdbId?.trim().toLowerCase();
    if (imdb != null && imdb.isNotEmpty) return 'imdb:$imdb';
    if (tvdbId != null && tvdbId! > 0) return 'tvdb:$tvdbId';
    final simkl = simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) return 'simkl:$simkl';
    final native = key?.trim();
    if (native != null && native.isNotEmpty) return 'key:$native';
    final norm = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final y = year;
    if (y != null && y > 0) return 'title:$norm|$y';
    return 'title:$norm';
  }

  /// Alias used by Letterboxd / merge helpers.
  String get compositeKey => identityKey;

  bool get excludesFromContinueWatching =>
      status == TrackerStatusKind.dropped ||
      status == TrackerStatusKind.hold ||
      status == TrackerStatusKind.completed;

  bool get excludesFromForYou =>
      status == TrackerStatusKind.dropped ||
      status == TrackerStatusKind.hold ||
      status == TrackerStatusKind.completed;

  /// Rows worth carrying in a cloud profile before the next tracker pull.
  ///
  /// Keeps dropped / hold (CW exclusion) and watching (inbound playheads).
  /// Omits bulk **completed** (and watchlist / plan-to-watch) — Simkl / Trakt /
  /// etc. re-import those on sync. Until that pull, finished titles may briefly
  /// appear in Continue Watching if local history still has progress.
  bool get worthSyncingForContinueWatching =>
      status == TrackerStatusKind.dropped ||
      status == TrackerStatusKind.hold ||
      status == TrackerStatusKind.watching;

  TrackerStatusEntry copyWith({
    String? source,
    TrackerStatusKind? status,
    String? title,
    int? tmdbId,
    String? imdbId,
    int? tvdbId,
    int? anilistId,
    String? simklId,
    int? year,
    double? progress,
    int? seasonNumber,
    int? episodeNumber,
    int? watchedEpisodes,
    int? totalEpisodes,
    DateTime? updatedAt,
    double? rating,
    bool? moviesOnly,
    String? key,
  }) {
    return TrackerStatusEntry(
      source: source ?? this.source,
      status: status ?? this.status,
      title: title ?? this.title,
      tmdbId: tmdbId ?? this.tmdbId,
      imdbId: imdbId ?? this.imdbId,
      tvdbId: tvdbId ?? this.tvdbId,
      anilistId: anilistId ?? this.anilistId,
      simklId: simklId ?? this.simklId,
      year: year ?? this.year,
      progress: progress ?? this.progress,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      watchedEpisodes: watchedEpisodes ?? this.watchedEpisodes,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      updatedAt: updatedAt ?? this.updatedAt,
      rating: rating ?? this.rating,
      moviesOnly: moviesOnly ?? this.moviesOnly,
      key: key ?? this.key,
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'status': status.name,
        'title': title,
        'tmdbId': tmdbId,
        'imdbId': imdbId,
        'tvdbId': tvdbId,
        'anilistId': anilistId,
        'simklId': simklId,
        'year': year,
        'progress': progress,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'watchedEpisodes': watchedEpisodes,
        'totalEpisodes': totalEpisodes,
        'updatedAt': updatedAt?.toIso8601String(),
        'rating': rating,
        'moviesOnly': moviesOnly,
        'key': key,
      };

  factory TrackerStatusEntry.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String? ?? 'watching';
    return TrackerStatusEntry(
      source: (json['source'] as String?)?.trim() ?? 'simkl',
      status: TrackerStatusKind.values.asNameMap()[statusName] ??
          TrackerStatusKind.watching,
      title: json['title'] as String? ?? '',
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      imdbId: json['imdbId'] as String?,
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      anilistId: (json['anilistId'] as num?)?.toInt(),
      simklId: json['simklId'] as String?,
      year: (json['year'] as num?)?.toInt(),
      progress: (json['progress'] as num?)?.toDouble(),
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      watchedEpisodes: (json['watchedEpisodes'] as num?)?.toInt(),
      totalEpisodes: (json['totalEpisodes'] as num?)?.toInt(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      rating: (json['rating'] as num?)?.toDouble(),
      moviesOnly: json['moviesOnly'] as bool? ?? false,
      key: json['key'] as String?,
    );
  }
}

/// Merge [incoming] into [existing], optionally replacing one [replaceSource].
List<TrackerStatusEntry> mergeTrackerStatuses(
  List<TrackerStatusEntry> existing,
  Iterable<TrackerStatusEntry> incoming, {
  String? replaceSource,
}) {
  final store = TrackerStatusStore(
    replaceSource == null
        ? existing
        : existing.where((e) => e.source != replaceSource),
  );
  store.upsertAll(incoming);
  return store.toList();
}

/// Device-local map of remote statuses (not Drive tokens; safe in prefs / sync).
class TrackerStatusStore {
  TrackerStatusStore([Iterable<TrackerStatusEntry> entries = const []]) {
    for (final e in entries) {
      upsert(e);
    }
  }

  final Map<String, TrackerStatusEntry> _byKey = {};

  Iterable<TrackerStatusEntry> get entries => _byKey.values;

  TrackerStatusEntry? operator [](String identityKey) => _byKey[identityKey];

  void upsert(TrackerStatusEntry entry) {
    final key = entry.identityKey;
    final prev = _byKey[key];
    if (prev == null) {
      _byKey[key] = entry;
      return;
    }
    final prevAt = prev.updatedAt;
    final nextAt = entry.updatedAt;
    if (prevAt != null && nextAt != null && nextAt.isBefore(prevAt)) {
      return;
    }
    if (prevAt != null &&
        nextAt != null &&
        nextAt.isAtSameMomentAs(prevAt) &&
        prev.excludesFromContinueWatching &&
        !entry.excludesFromContinueWatching) {
      return;
    }
    final progress = _maxProgress(prev.progress, entry.progress);
    final ahead = (entry.progress ?? 0) >= (prev.progress ?? 0) ||
        (entry.watchedEpisodes ?? 0) >= (prev.watchedEpisodes ?? 0);
    _byKey[key] = entry.copyWith(
      progress: progress,
      seasonNumber: ahead
          ? (entry.seasonNumber ?? prev.seasonNumber)
          : (prev.seasonNumber ?? entry.seasonNumber),
      episodeNumber: ahead
          ? (entry.episodeNumber ?? prev.episodeNumber)
          : (prev.episodeNumber ?? entry.episodeNumber),
      watchedEpisodes: _maxInt(prev.watchedEpisodes, entry.watchedEpisodes),
      totalEpisodes: _maxInt(prev.totalEpisodes, entry.totalEpisodes),
      tmdbId: entry.tmdbId ?? prev.tmdbId,
      imdbId: entry.imdbId ?? prev.imdbId,
      tvdbId: entry.tvdbId ?? prev.tvdbId,
      anilistId: entry.anilistId ?? prev.anilistId,
      simklId: entry.simklId ?? prev.simklId,
    );
  }

  void upsertAll(Iterable<TrackerStatusEntry> list) {
    for (final e in list) {
      upsert(e);
    }
  }

  void replaceSource(String source, Iterable<TrackerStatusEntry> list) {
    _byKey.removeWhere((_, e) => e.source == source);
    upsertAll(list);
  }

  bool excludesContinueWatching({
    int? tmdbId,
    String? imdbId,
    int? tvdbId,
    int? anilistId,
    String? simklId,
    String? title,
    int? year,
  }) {
    final hit = lookup(
      tmdbId: tmdbId,
      imdbId: imdbId,
      tvdbId: tvdbId,
      anilistId: anilistId,
      simklId: simklId,
      title: title,
      year: year,
    );
    return hit?.excludesFromContinueWatching ?? false;
  }

  bool excludesForYou({
    int? tmdbId,
    String? imdbId,
    int? tvdbId,
    int? anilistId,
    String? simklId,
    String? title,
    int? year,
  }) {
    final hit = lookup(
      tmdbId: tmdbId,
      imdbId: imdbId,
      tvdbId: tvdbId,
      anilistId: anilistId,
      simklId: simklId,
      title: title,
      year: year,
    );
    return hit?.excludesFromForYou ?? false;
  }

  TrackerStatusEntry? lookup({
    int? tmdbId,
    String? imdbId,
    int? tvdbId,
    int? anilistId,
    String? simklId,
    String? title,
    int? year,
  }) {
    if (anilistId != null && anilistId > 0) {
      final hit = _byKey['al:$anilistId'];
      if (hit != null) return hit;
    }
    if (tmdbId != null && tmdbId > 0) {
      final hit = _byKey['tmdb:$tmdbId'];
      if (hit != null) return hit;
    }
    final imdb = imdbId?.trim().toLowerCase();
    if (imdb != null && imdb.isNotEmpty) {
      final hit = _byKey['imdb:$imdb'];
      if (hit != null) return hit;
    }
    if (tvdbId != null && tvdbId > 0) {
      final hit = _byKey['tvdb:$tvdbId'];
      if (hit != null) return hit;
    }
    final simkl = simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) {
      final hit = _byKey['simkl:$simkl'];
      if (hit != null) return hit;
    }
    if (title != null && title.trim().isNotEmpty) {
      final norm = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      if (year != null && year > 0) {
        final hit = _byKey['title:$norm|$year'];
        if (hit != null) return hit;
      }
      return _byKey['title:$norm'];
    }
    return null;
  }

  List<TrackerStatusEntry> toList() => _byKey.values.toList(growable: false);

  Map<String, dynamic> toJson() => {
        'entries': toList().map((e) => e.toJson()).toList(),
      };

  factory TrackerStatusStore.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    if (raw is! List) return TrackerStatusStore();
    return TrackerStatusStore(
      raw
          .whereType<Map>()
          .map((e) => TrackerStatusEntry.fromJson(e.cast<String, dynamic>())),
    );
  }

  static double? _maxProgress(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a >= b ? a : b;
  }

  static int? _maxInt(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a >= b ? a : b;
  }
}

/// Well-known [TrackerStatusEntry.source] values.
abstract final class TrackerSources {
  static const simkl = 'simkl';
  static const trakt = 'trakt';
  static const serializd = 'serializd';
  static const betaseries = 'betaseries';
  static const letterboxd = 'letterboxd';
}

/// Legacy alias — prefer [TrackerStatusKind].
typedef TrackerWatchStatus = TrackerStatusKind;
