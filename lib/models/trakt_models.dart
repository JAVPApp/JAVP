import 'package:javp/services/trackers/device_pin_uri.dart';

class TraktCredentials {
  const TraktCredentials({
    this.clientId = '',
    this.clientSecret = '',
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  /// Inject at build time: `--dart-define=TRAKT_CLIENT_ID=…`
  static const bundledClientId = String.fromEnvironment(
    'TRAKT_CLIENT_ID',
    defaultValue: '',
  );

  /// Inject at build time: `--dart-define=TRAKT_CLIENT_SECRET=…`
  static const bundledClientSecret = String.fromEnvironment(
    'TRAKT_CLIENT_SECRET',
    defaultValue: '',
  );

  final String clientId;
  final String clientSecret;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  String get effectiveClientId {
    final custom = clientId.trim();
    if (custom.isNotEmpty) return custom;
    return bundledClientId;
  }

  String get effectiveClientSecret {
    final custom = clientSecret.trim();
    if (custom.isNotEmpty) return custom;
    return bundledClientSecret;
  }

  bool get usesBundledClientId => clientId.trim().isEmpty;

  bool get isConfigured => effectiveClientId.isNotEmpty;

  bool get isAuthenticated =>
      isConfigured && accessToken != null && accessToken!.isNotEmpty;

  TraktCredentials copyWith({
    String? clientId,
    String? clientSecret,
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    bool clearTokens = false,
  }) {
    return TraktCredentials(
      clientId: clientId ?? this.clientId,
      clientSecret: clientSecret ?? this.clientSecret,
      accessToken: clearTokens ? null : (accessToken ?? this.accessToken),
      refreshToken: clearTokens ? null : (refreshToken ?? this.refreshToken),
      expiresAt: clearTokens ? null : (expiresAt ?? this.expiresAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'clientSecret': clientSecret,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  factory TraktCredentials.fromJson(Map<String, dynamic> json) {
    return TraktCredentials(
      clientId: json['clientId'] as String? ?? '',
      clientSecret: json['clientSecret'] as String? ?? '',
      accessToken: json['accessToken'] as String?,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    );
  }
}

/// Result of `POST /oauth/device/code`.
class TraktDeviceSession {
  const TraktDeviceSession({
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
  /// RFC 8628 complete URI when Trakt includes the code in the link.
  final Uri? verificationUriComplete;
  final int expiresIn;
  final int interval;

  /// URL encoded in a TV/desktop QR (complete URI when present).
  Uri get scanUri =>
      devicePinScanUri(verificationUri, verificationUriComplete);

  factory TraktDeviceSession.fromJson(Map<String, dynamic> json) {
    final uriRaw = (json['verification_url'] as String?)?.trim() ??
        (json['verification_uri'] as String?)?.trim();
    return TraktDeviceSession(
      deviceCode: (json['device_code'] as String? ?? '').trim(),
      userCode: (json['user_code'] as String? ?? '').trim(),
      verificationUri: Uri.parse(
        (uriRaw != null && uriRaw.isNotEmpty)
            ? uriRaw
            : 'https://trakt.tv/activate',
      ),
      verificationUriComplete: parseOptionalUri(
        json['verification_uri_complete'] as String?,
      ),
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 600,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }
}

class TraktTokenResult {
  const TraktTokenResult({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
  });

  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;

  factory TraktTokenResult.fromJson(Map<String, dynamic> json) {
    return TraktTokenResult(
      accessToken: (json['access_token'] as String? ?? '').trim(),
      refreshToken: (json['refresh_token'] as String?)?.trim(),
      expiresIn: (json['expires_in'] as num?)?.toInt(),
    );
  }
}

/// Stamps from `GET /sync/last_activities` used to gate watchlist re-fetch.
class TraktLastActivities {
  const TraktLastActivities({
    this.moviesWatchlistedAt,
    this.showsWatchlistedAt,
    this.episodesWatchlistedAt,
    this.moviesPausedAt,
    this.episodesPausedAt,
    this.hiddenAt,
  });

  final String? moviesWatchlistedAt;
  final String? showsWatchlistedAt;
  final String? episodesWatchlistedAt;
  final String? moviesPausedAt;
  final String? episodesPausedAt;
  /// Bumped when dropped / hidden lists change.
  final String? hiddenAt;

  bool watchlistUnchanged(TraktLastActivities? previous) {
    if (previous == null) return false;
    return moviesWatchlistedAt == previous.moviesWatchlistedAt &&
        showsWatchlistedAt == previous.showsWatchlistedAt &&
        episodesWatchlistedAt == previous.episodesWatchlistedAt;
  }

  bool playbackUnchanged(TraktLastActivities? previous) {
    if (previous == null) return false;
    return moviesPausedAt == previous.moviesPausedAt &&
        episodesPausedAt == previous.episodesPausedAt;
  }

  bool droppedUnchanged(TraktLastActivities? previous) {
    if (previous == null) return false;
    return hiddenAt == previous.hiddenAt;
  }

  Map<String, dynamic> toJson() => {
        'moviesWatchlistedAt': moviesWatchlistedAt,
        'showsWatchlistedAt': showsWatchlistedAt,
        'episodesWatchlistedAt': episodesWatchlistedAt,
        'moviesPausedAt': moviesPausedAt,
        'episodesPausedAt': episodesPausedAt,
        'hiddenAt': hiddenAt,
      };

  factory TraktLastActivities.fromJson(Map<String, dynamic> json) {
    return TraktLastActivities(
      moviesWatchlistedAt: json['moviesWatchlistedAt'] as String?,
      showsWatchlistedAt: json['showsWatchlistedAt'] as String?,
      episodesWatchlistedAt: json['episodesWatchlistedAt'] as String?,
      moviesPausedAt: json['moviesPausedAt'] as String?,
      episodesPausedAt: json['episodesPausedAt'] as String?,
      hiddenAt: json['hiddenAt'] as String?,
    );
  }

  factory TraktLastActivities.fromApi(Map<String, dynamic> json) {
    String? stamp(String section, String key) {
      final nest = (json[section] as Map?)?.cast<String, dynamic>();
      return nest?[key]?.toString();
    }

    return TraktLastActivities(
      moviesWatchlistedAt: stamp('movies', 'watchlisted_at'),
      showsWatchlistedAt: stamp('shows', 'watchlisted_at'),
      episodesWatchlistedAt: stamp('episodes', 'watchlisted_at'),
      moviesPausedAt: stamp('movies', 'paused_at'),
      episodesPausedAt: stamp('episodes', 'paused_at'),
      hiddenAt: stamp('movies', 'hidden_at') ??
          stamp('shows', 'hidden_at') ??
          stamp('episodes', 'hidden_at'),
    );
  }
}

/// Paused playback from `GET /sync/playback` (progress is 0–100 from API).
class TraktPlayback {
  const TraktPlayback({
    required this.progress,
    required this.isShow,
    required this.title,
    this.year,
    this.trakt,
    this.tmdb,
    this.imdb,
    this.tvdb,
    this.seasonNumber,
    this.episodeNumber,
    this.pausedAt,
  });

  /// Normalized 0–1 playhead.
  final double progress;
  final bool isShow;
  final String title;
  final int? year;
  final int? trakt;
  final int? tmdb;
  final String? imdb;
  final int? tvdb;
  final int? seasonNumber;
  final int? episodeNumber;
  final DateTime? pausedAt;

  factory TraktPlayback.fromApiEntry(Map<String, dynamic> entry) {
    final type = (entry['type'] as String?)?.trim().toLowerCase();
    final episode = (entry['episode'] as Map?)?.cast<String, dynamic>();
    final show = (entry['show'] as Map?)?.cast<String, dynamic>();
    final movie = (entry['movie'] as Map?)?.cast<String, dynamic>();
    final isShow = type == 'episode' || episode != null || show != null;
    final media = isShow ? (show ?? const <String, dynamic>{}) : (movie ?? {});
    final ids = (media['ids'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rawProgress = (entry['progress'] as num?)?.toDouble() ?? 0;
    final progress = rawProgress > 1.0 ? rawProgress / 100.0 : rawProgress;
    return TraktPlayback(
      progress: progress.clamp(0.0, 1.0),
      isShow: isShow,
      title: (media['title'] as String?)?.trim() ?? '',
      year: (media['year'] as num?)?.toInt(),
      trakt: _playbackIdInt(ids['trakt']),
      tmdb: _playbackIdInt(ids['tmdb']),
      imdb: (ids['imdb'] as String?)?.trim(),
      tvdb: _playbackIdInt(ids['tvdb']),
      seasonNumber: (episode?['season'] as num?)?.toInt(),
      episodeNumber: (episode?['number'] as num?)?.toInt(),
      pausedAt: DateTime.tryParse(entry['paused_at'] as String? ?? ''),
    );
  }

  static int? _playbackIdInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}

/// Compact id hit from recommendations / watchlist / related endpoints.
class TraktIdHit {
  const TraktIdHit({
    required this.title,
    required this.isShow,
    this.year,
    this.trakt,
    this.tmdb,
    this.imdb,
    this.tvdb,
    this.slug,
    this.listedAt,
  });

  final String title;
  final bool isShow;
  final int? year;
  final int? trakt;
  final int? tmdb;
  final String? imdb;
  final int? tvdb;
  final String? slug;
  final DateTime? listedAt;

  /// Prefer TMDB when mapping into the local catalog.
  int? get preferredTmdb => tmdb;

  static TraktIdHit? fromApiEntry(
    Map<String, dynamic> entry, {
    required String mediaKey,
  }) {
    // Watchlist wraps under movie/show; recommendations/related are flat.
    final media = (entry[mediaKey] as Map?)?.cast<String, dynamic>() ??
        (entry['movie'] as Map?)?.cast<String, dynamic>() ??
        (entry['show'] as Map?)?.cast<String, dynamic>() ??
        entry;
    final title = (media['title'] as String?)?.trim() ?? '';
    final ids = (media['ids'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tmdb = _idInt(ids['tmdb']);
    final imdb = (ids['imdb'] as String?)?.trim();
    final tvdb = _idInt(ids['tvdb']);
    final trakt = _idInt(ids['trakt']);
    final slug = (ids['slug'] as String?)?.trim();
    if (title.isEmpty && tmdb == null && imdb == null && trakt == null) {
      return null;
    }
    final isShow = mediaKey == 'show' || entry.containsKey('show');
    return TraktIdHit(
      title: title,
      isShow: isShow,
      year: (media['year'] as num?)?.toInt(),
      trakt: trakt,
      tmdb: tmdb,
      imdb: imdb,
      tvdb: tvdb,
      slug: slug,
      listedAt: DateTime.tryParse(entry['listed_at'] as String? ?? ''),
    );
  }

  static int? _idInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}
