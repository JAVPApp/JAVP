import 'package:javp/models/tracker_status.dart';

/// Device-local Serializd session (token never goes in Drive snapshots).
class SerializdCredentials {
  const SerializdCredentials({
    this.accessToken,
    this.username,
  });

  final String? accessToken;
  final String? username;

  bool get isAuthenticated =>
      accessToken != null && accessToken!.trim().isNotEmpty;

  SerializdCredentials copyWith({
    String? accessToken,
    String? username,
    bool clearToken = false,
  }) {
    return SerializdCredentials(
      accessToken: clearToken ? null : (accessToken ?? this.accessToken),
      username: username ?? this.username,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'username': username,
      };

  factory SerializdCredentials.fromJson(Map<String, dynamic> json) {
    return SerializdCredentials(
      accessToken: json['accessToken'] as String?,
      username: json['username'] as String?,
    );
  }
}

/// Compact show row from Serializd user lists (TMDB show id = [showId]).
class SerializdShowHit {
  const SerializdShowHit({
    required this.showId,
    required this.title,
    required this.status,
    this.posterUrl,
    this.dateAdded,
    this.seasonIds = const [],
  });

  /// TMDB TV show id (Serializd’s primary key).
  final int showId;
  final String title;
  final TrackerStatusKind status;
  final String? posterUrl;
  final DateTime? dateAdded;
  final List<int> seasonIds;

  Map<String, dynamic> toJson() => {
        'showId': showId,
        'title': title,
        'status': status.name,
        'posterUrl': posterUrl,
        'dateAdded': dateAdded?.toIso8601String(),
        'seasonIds': seasonIds,
      };

  factory SerializdShowHit.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String? ?? 'watching';
    return SerializdShowHit(
      showId: (json['showId'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      status: TrackerStatusKind.values.asNameMap()[statusName] ??
          TrackerStatusKind.watching,
      posterUrl: json['posterUrl'] as String?,
      dateAdded: DateTime.tryParse(json['dateAdded'] as String? ?? ''),
      seasonIds: (json['seasonIds'] as List?)
              ?.whereType<num>()
              .map((n) => n.toInt())
              .toList() ??
          const [],
    );
  }

  TrackerStatusEntry toStatusEntry() => TrackerStatusEntry(
        source: TrackerSources.serializd,
        key: showId > 0 ? 'tmdb:$showId' : null,
        status: status,
        title: title,
        tmdbId: showId > 0 ? showId : null,
        // Serializd lists rarely expose mid-show counts; completed still
        // forces local episode watched flags when the series is opened.
        progress: status == TrackerStatusKind.completed ? 1.0 : null,
        updatedAt: dateAdded,
      );
}

/// Bundled list pull from Serializd (watching + watchlist + dropped/paused).
class SerializdUserLists {
  const SerializdUserLists({
    this.watching = const [],
    this.watchlist = const [],
    this.dropped = const [],
    this.paused = const [],
    this.completed = const [],
    this.username,
  });

  final List<SerializdShowHit> watching;
  final List<SerializdShowHit> watchlist;
  final List<SerializdShowHit> dropped;
  final List<SerializdShowHit> paused;

  /// Fully watched seasons/shows (from watched list when available).
  final List<SerializdShowHit> completed;
  final String? username;

  bool get isEmpty =>
      watching.isEmpty &&
      watchlist.isEmpty &&
      dropped.isEmpty &&
      paused.isEmpty &&
      completed.isEmpty;

  /// Status rows for the shared [TrackerStatusStore] pipeline.
  List<TrackerStatusEntry> toStatusEntries() {
    final out = <TrackerStatusEntry>[];
    void addAll(Iterable<SerializdShowHit> rows) {
      for (final row in rows) {
        if (row.showId <= 0 && row.title.trim().isEmpty) continue;
        out.add(row.toStatusEntry());
      }
    }

    addAll(watching);
    addAll(watchlist);
    addAll(dropped);
    addAll(paused);
    addAll(completed);
    return out;
  }
}

/// Queued outbound episode log when Serializd is briefly unreachable.
class PendingSerializdScrobble {
  const PendingSerializdScrobble({
    required this.showId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.seasonId,
    this.queuedAt,
  });

  final int showId;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final int? seasonId;
  final DateTime? queuedAt;

  Map<String, dynamic> toJson() => {
        'showId': showId,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'title': title,
        'seasonId': seasonId,
        'queuedAt': queuedAt?.toIso8601String(),
      };

  factory PendingSerializdScrobble.fromJson(Map<String, dynamic> json) {
    return PendingSerializdScrobble(
      showId: (json['showId'] as num?)?.toInt() ?? 0,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 0,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      seasonId: (json['seasonId'] as num?)?.toInt(),
      queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? ''),
    );
  }
}
