import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/trackers/device_pin_uri.dart';

/// Device-local BetaSeries credentials (token never goes in Drive snapshots).
///
/// Auth: OAuth2 device code (`POST /oauth/device` → poll `/oauth/access_token`).
/// Docs: https://developers.betaseries.com/docs/getting-started/authentication/
class BetaseriesCredentials {
  const BetaseriesCredentials({
    this.apiKey = '',
    this.apiSecret = '',
    this.accessToken,
    this.login,
  });

  /// Inject at build time: `--dart-define=BETASERIES_API_KEY=…`
  static const bundledApiKey = String.fromEnvironment(
    'BETASERIES_API_KEY',
    defaultValue: '',
  );

  /// Inject at build time: `--dart-define=BETASERIES_API_SECRET=…`
  static const bundledApiSecret = String.fromEnvironment(
    'BETASERIES_API_SECRET',
    defaultValue: '',
  );

  final String apiKey;
  final String apiSecret;
  final String? accessToken;
  final String? login;

  String get effectiveApiKey {
    final custom = apiKey.trim();
    if (custom.isNotEmpty) return custom;
    return bundledApiKey;
  }

  String get effectiveApiSecret {
    final custom = apiSecret.trim();
    if (custom.isNotEmpty) return custom;
    return bundledApiSecret;
  }

  bool get usesBundledApiKey => apiKey.trim().isEmpty;

  bool get isConfigured => effectiveApiKey.isNotEmpty;

  bool get isAuthenticated =>
      isConfigured && accessToken != null && accessToken!.isNotEmpty;

  BetaseriesCredentials copyWith({
    String? apiKey,
    String? apiSecret,
    String? accessToken,
    String? login,
    bool clearToken = false,
  }) {
    return BetaseriesCredentials(
      apiKey: apiKey ?? this.apiKey,
      apiSecret: apiSecret ?? this.apiSecret,
      accessToken: clearToken ? null : (accessToken ?? this.accessToken),
      login: clearToken ? null : (login ?? this.login),
    );
  }

  Map<String, dynamic> toJson() => {
        'apiKey': apiKey,
        'apiSecret': apiSecret,
        'accessToken': accessToken,
        'login': login,
      };

  factory BetaseriesCredentials.fromJson(Map<String, dynamic> json) {
    return BetaseriesCredentials(
      apiKey: json['apiKey'] as String? ?? '',
      apiSecret: json['apiSecret'] as String? ?? '',
      accessToken: json['accessToken'] as String?,
      login: json['login'] as String?,
    );
  }
}

/// Result of `POST /oauth/device`.
class BetaseriesDeviceSession {
  const BetaseriesDeviceSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    this.verificationUriComplete,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  /// RFC 8628 complete URI when BetaSeries includes the code in the link.
  final Uri? verificationUriComplete;
  final int expiresIn;
  final int interval;

  /// URL encoded in a TV/desktop QR (complete URI when present).
  Uri get scanUri =>
      devicePinScanUri(verificationUri, verificationUriComplete);

  factory BetaseriesDeviceSession.fromJson(Map<String, dynamic> json) {
    final uriRaw = (json['verification_url'] as String?)?.trim() ??
        (json['verification_uri'] as String?)?.trim();
    return BetaseriesDeviceSession(
      deviceCode: (json['device_code'] as String? ?? '').trim(),
      userCode: (json['user_code'] as String? ?? '').trim(),
      verificationUri: Uri.parse(
        (uriRaw != null && uriRaw.isNotEmpty)
            ? uriRaw
            : 'https://www.betaseries.com/device',
      ),
      verificationUriComplete: parseOptionalUri(
        json['verification_uri_complete'] as String?,
      ),
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 1800,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }
}

class BetaseriesTokenResult {
  const BetaseriesTokenResult({
    required this.accessToken,
    this.login,
  });

  final String accessToken;
  final String? login;

  factory BetaseriesTokenResult.fromJson(Map<String, dynamic> json) {
    // Device flow may return form-urlencoded or JSON depending on Accept.
    final token = (json['access_token'] as String? ??
            json['token'] as String? ??
            '')
        .trim();
    final user = (json['user'] as Map?)?.cast<String, dynamic>();
    return BetaseriesTokenResult(
      accessToken: token,
      login: (json['login'] as String?)?.trim() ??
          (user?['login'] as String?)?.trim(),
    );
  }
}

/// Compact show row from `GET /shows/member`.
class BetaseriesShowHit {
  const BetaseriesShowHit({
    required this.id,
    required this.title,
    required this.status,
    this.year,
    this.imdbId,
    this.tvdbId,
    this.tmdbId,
    this.posterUrl,
    this.progress,
    this.watchedEpisodes,
    this.totalEpisodes,
    this.lastSeenAt,
  });

  final int id;
  final String title;
  final TrackerStatusKind status;
  final int? year;
  final String? imdbId;
  final int? tvdbId;
  final int? tmdbId;
  final String? posterUrl;
  final double? progress;
  final int? watchedEpisodes;
  final int? totalEpisodes;
  final DateTime? lastSeenAt;

  TrackerStatusEntry toStatusEntry() => TrackerStatusEntry(
        source: TrackerSources.betaseries,
        key: id > 0 ? 'bs:$id' : null,
        status: status,
        title: title,
        year: year,
        tmdbId: tmdbId,
        imdbId: imdbId,
        tvdbId: tvdbId,
        progress: progress,
        watchedEpisodes: watchedEpisodes,
        totalEpisodes: totalEpisodes,
        updatedAt: lastSeenAt,
      );

  static TrackerStatusKind statusFromApiFilter(String filter) {
    switch (filter.trim().toLowerCase()) {
      case 'current':
      case 'active':
        return TrackerStatusKind.watching;
      case 'not_started':
        return TrackerStatusKind.planToWatch;
      case 'stopped':
        return TrackerStatusKind.dropped;
      case 'completed':
      case 'archived_and_completed':
        return TrackerStatusKind.completed;
      case 'archived':
        return TrackerStatusKind.hold;
      default:
        return TrackerStatusKind.watching;
    }
  }

  static BetaseriesShowHit? fromApiShow(
    Map<String, dynamic> show, {
    required TrackerStatusKind status,
  }) {
    final id = (show['id'] as num?)?.toInt() ?? 0;
    final title = (show['title'] as String?)?.trim() ?? '';
    if (id <= 0 && title.isEmpty) return null;

    final images = (show['images'] as Map?)?.cast<String, dynamic>();
    final poster = (images?['poster'] as String?)?.trim() ??
        (show['poster'] as String?)?.trim();

    final imdb = (show['imdb_id'] as String?)?.trim();
    final tvdb = _idInt(show['thetvdb_id'] ?? show['tvdb_id']);
    final tmdb = _idInt(show['tmdb_id']);

    final user = (show['user'] as Map?)?.cast<String, dynamic>();
    final seen = (user?['seen'] as num?)?.toInt() ??
        (user?['episodes'] as num?)?.toInt();
    final total = (show['episodes'] as num?)?.toInt() ??
        (user?['total'] as num?)?.toInt();
    double? progress;
    if (seen != null && total != null && total > 0) {
      progress = (seen / total).clamp(0.0, 1.0);
    } else {
      final remaining = (user?['remaining'] as num?)?.toInt();
      if (remaining != null && total != null && total > 0) {
        final watched = total - remaining;
        progress = (watched / total).clamp(0.0, 1.0);
      }
    }

    final year = _idInt(show['creation'] ?? show['year']);
    final lastRaw = user?['last'] ?? user?['status'] ?? show['last_seen'];
    DateTime? lastSeen;
    if (lastRaw is String) {
      lastSeen = DateTime.tryParse(lastRaw);
    } else if (lastRaw is num) {
      // Unix seconds when large enough.
      final n = lastRaw.toInt();
      if (n > 1e9) {
        lastSeen = DateTime.fromMillisecondsSinceEpoch(n * 1000);
      }
    }

    return BetaseriesShowHit(
      id: id,
      title: title,
      status: status,
      year: year,
      imdbId: imdb,
      tvdbId: tvdb,
      tmdbId: tmdb,
      posterUrl: poster,
      progress: progress,
      watchedEpisodes: seen,
      totalEpisodes: total,
      lastSeenAt: lastSeen,
    );
  }

  static int? _idInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final t = raw.trim();
      if (t.isEmpty) return null;
      return int.tryParse(t);
    }
    return null;
  }
}

/// Bundled list pull used by sync (watching + plan + dropped/completed).
class BetaseriesUserLists {
  const BetaseriesUserLists({
    this.watching = const [],
    this.planToWatch = const [],
    this.dropped = const [],
    this.completed = const [],
  });

  final List<BetaseriesShowHit> watching;
  final List<BetaseriesShowHit> planToWatch;
  final List<BetaseriesShowHit> dropped;
  final List<BetaseriesShowHit> completed;

  bool get isEmpty =>
      watching.isEmpty &&
      planToWatch.isEmpty &&
      dropped.isEmpty &&
      completed.isEmpty;

  List<TrackerStatusEntry> toStatusEntries() {
    final out = <TrackerStatusEntry>[];
    void addAll(Iterable<BetaseriesShowHit> rows) {
      for (final row in rows) {
        out.add(row.toStatusEntry());
      }
    }

    addAll(watching);
    addAll(planToWatch);
    addAll(dropped);
    addAll(completed);
    return out;
  }
}
