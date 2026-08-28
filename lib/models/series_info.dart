import 'package:javp/services/catalog/catalog_play_headers.dart';

class SeriesInfo {
  const SeriesInfo({
    required this.seriesId,
    required this.title,
    required this.seasons,
    this.plot,
    this.coverUrl,
    this.genre,
    this.releaseDate,
    this.rating,
    this.backdropUrl,
  });

  final String seriesId;
  final String title;
  final String? plot;
  final String? coverUrl;
  final String? genre;
  final String? releaseDate;
  final double? rating;
  final String? backdropUrl;
  final List<SeriesSeason> seasons;

  int get episodeCount =>
      seasons.fold(0, (sum, season) => sum + season.episodes.length);

  /// Episodes whose [SeriesEpisode.airDate] is today or earlier (or unknown).
  int get airedEpisodeCount => seasons.fold(
    0,
    (sum, season) =>
        sum + season.episodes.where((e) => !e.isUpcoming).length,
  );

  /// Episodes with a future [SeriesEpisode.airDate].
  int get upcomingEpisodeCount => seasons.fold(
    0,
    (sum, season) =>
        sum + season.episodes.where((e) => e.isUpcoming).length,
  );

  /// Same SxxExx row across catalogs (episode ids are not shared).
  SeriesEpisode? episodeAt({
    required int seasonNumber,
    required int episodeNum,
  }) {
    for (final season in seasons) {
      if (season.seasonNumber != seasonNumber) continue;
      for (final episode in season.episodes) {
        if (episode.episodeNum == episodeNum) return episode;
      }
    }
    return null;
  }
}

class SeriesSeason {
  const SeriesSeason({
    required this.seasonNumber,
    required this.name,
    required this.episodes,
    this.coverUrl,
  });

  final int seasonNumber;
  final String name;
  final String? coverUrl;
  final List<SeriesEpisode> episodes;
}

class SeriesEpisode {
  const SeriesEpisode({
    required this.id,
    required this.episodeNum,
    required this.seasonNumber,
    required this.title,
    required this.containerExtension,
    this.plot,
    this.thumbnailUrl,
    this.duration,
    this.airDate,
    this.playUrl,
    this.torrentFile,
    this.resolution,
    this.playVariants = const [],
    this.httpHeaders = const {},
  });

  final String id;
  final int episodeNum;
  final int seasonNumber;
  final String title;
  final String containerExtension;
  final String? plot;
  final String? thumbnailUrl;
  final Duration? duration;
  /// First air date when known (panel / TMDB). Date-only; time ignored.
  final DateTime? airDate;
  /// Direct play URL when known (custom catalog / details cache).
  final String? playUrl;
  /// Preferred file inside a multi-file magnet.
  final String? torrentFile;
  final String? resolution;
  /// Alternate magnets / qualities for this episode.
  final List<EpisodePlayVariant> playVariants;
  /// Playback headers for [playUrl] (catalog `httpHeaders` / `userAgent`).
  final Map<String, String> httpHeaders;

  String get shortLabel => 'S${seasonNumber.toString().padLeft(2, '0')}'
      'E${episodeNum.toString().padLeft(2, '0')}';

  /// True when [airDate] is after today (local calendar day).
  bool get isUpcoming {
    final d = airDate;
    if (d == null) return false;
    final now = DateTime.now();
    final airDay = DateTime(d.year, d.month, d.day);
    final today = DateTime(now.year, now.month, now.day);
    return airDay.isAfter(today);
  }

  /// True when [playUrl] / variants have no direct URL yet.
  ///
  /// For progressive custom catalogs this means a stub awaiting
  /// `GET /items/{id}`. Media-server (Plex / Jellyfin / Emby) episodes
  /// intentionally omit playUrl (resolved at play via serverItemId) — callers
  /// must also check `origin == MediaOrigin.customCatalog` before showing
  /// catalog-resolve loading UI or calling bridge resolve.
  bool get needsPlaybackResolve {
    final url = playUrl?.trim();
    if (url != null && url.isNotEmpty) return false;
    return !playVariants.any((v) => v.playUrl.trim().isNotEmpty);
  }

  SeriesEpisode copyWith({
    String? title,
    String? plot,
    String? thumbnailUrl,
    Duration? duration,
    DateTime? airDate,
    String? playUrl,
    String? torrentFile,
    String? resolution,
    List<EpisodePlayVariant>? playVariants,
    Map<String, String>? httpHeaders,
  }) {
    return SeriesEpisode(
      id: id,
      episodeNum: episodeNum,
      seasonNumber: seasonNumber,
      title: title ?? this.title,
      containerExtension: containerExtension,
      plot: plot ?? this.plot,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      airDate: airDate ?? this.airDate,
      playUrl: playUrl ?? this.playUrl,
      torrentFile: torrentFile ?? this.torrentFile,
      resolution: resolution ?? this.resolution,
      playVariants: playVariants ?? this.playVariants,
      httpHeaders: httpHeaders ?? this.httpHeaders,
    );
  }

  /// Parse panel / TMDB air dates (`YYYY-MM-DD`, ISO, or epoch seconds).
  static DateTime? parseAirDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) {
      return DateTime(raw.year, raw.month, raw.day);
    }
    if (raw is num) {
      final value = raw.toInt();
      if (value <= 0) return null;
      final dt = value > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
      return DateTime(dt.year, dt.month, dt.day);
    }
    final text = '$raw'.trim();
    if (text.isEmpty) return null;
    final asInt = int.tryParse(text);
    if (asInt != null) return parseAirDate(asInt);
    final normalized = text.length >= 10 ? text.substring(0, 10) : text;
    final dt = DateTime.tryParse(normalized) ?? DateTime.tryParse(text);
    if (dt == null) return null;
    return DateTime(dt.year, dt.month, dt.day);
  }

  /// Variants list, or a single synthetic row from [playUrl].
  List<EpisodePlayVariant> get effectiveVariants {
    if (playVariants.isNotEmpty) return playVariants;
    final url = playUrl?.trim();
    if (url == null || url.isEmpty) return const [];
    return [
      EpisodePlayVariant(
        id: id,
        label: resolution?.trim().isNotEmpty == true
            ? resolution!.trim()
            : 'Default',
        playUrl: url,
        resolution: resolution,
        torrentFile: torrentFile,
        httpHeaders: httpHeaders,
      ),
    ];
  }
}

/// One stream / torrent option for an episode (catalog `playVariants`).
class EpisodePlayVariant {
  const EpisodePlayVariant({
    required this.id,
    required this.label,
    required this.playUrl,
    this.subtitle,
    this.resolution,
    this.videoCodec,
    this.audioCodec,
    this.hdr,
    this.torrentFile,
    this.audioLanguages = const [],
    this.subtitleLanguages = const [],
    this.httpHeaders = const {},
  });

  final String id;
  final String label;
  final String playUrl;
  final String? subtitle;
  final String? resolution;
  final String? videoCodec;
  final String? audioCodec;
  final String? hdr;
  final String? torrentFile;
  final List<String> audioLanguages;
  final List<String> subtitleLanguages;
  /// Playback headers for this variant's [playUrl].
  final Map<String, String> httpHeaders;

  String get displayLabel {
    final parts = <String>[
      if (label.trim().isNotEmpty) label.trim(),
      if (subtitle != null &&
          subtitle!.trim().isNotEmpty &&
          !label.contains(subtitle!.trim()))
        subtitle!.trim(),
    ];
    if (audioLanguages.length > 1) {
      parts.add(
        'Audio ${audioLanguages.take(4).map((e) => e.toUpperCase()).join('/')}',
      );
    } else if (audioLanguages.length == 1 &&
        !parts.any((p) => p.toUpperCase().contains(audioLanguages.first.toUpperCase()))) {
      parts.add('Audio ${audioLanguages.first.toUpperCase()}');
    }
    if (subtitleLanguages.isNotEmpty) {
      final subs = subtitleLanguages.take(4).map((e) => e.toUpperCase()).join('/');
      final already = parts.any(
        (p) =>
            p.toUpperCase().contains('SUB') ||
            p.toUpperCase().contains(subs),
      );
      if (!already) parts.add('Subs $subs');
    }
    if (resolution != null &&
        resolution!.trim().isNotEmpty &&
        !parts.any((p) => p.contains(resolution!.trim()))) {
      parts.add(resolution!.trim());
    }
    if (parts.isNotEmpty) return parts.join(' · ');
    return 'Version';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'playUrl': playUrl,
        'subtitle': subtitle,
        'resolution': resolution,
        'videoCodec': videoCodec,
        'audioCodec': audioCodec,
        'hdr': hdr,
        'torrentFile': torrentFile,
        'audioLanguages': audioLanguages,
        'subtitleLanguages': subtitleLanguages,
        if (httpHeaders.isNotEmpty) 'httpHeaders': httpHeaders,
      };

  factory EpisodePlayVariant.fromJson(Map<String, dynamic> json) {
    return EpisodePlayVariant(
      id: (json['id'] as String?)?.trim() ?? '',
      label: (json['label'] as String?)?.trim() ??
          (json['title'] as String?)?.trim() ??
          (json['name'] as String?)?.trim() ??
          (json['resolution'] as String?)?.trim() ??
          'Version',
      playUrl: (json['playUrl'] as String?)?.trim() ??
          (json['url'] as String?)?.trim() ??
          '',
      subtitle: (json['subtitle'] as String?)?.trim(),
      resolution: (json['resolution'] as String?)?.trim(),
      videoCodec: (json['videoCodec'] as String?)?.trim(),
      audioCodec: (json['audioCodec'] as String?)?.trim(),
      hdr: (json['hdr'] as String?)?.trim(),
      torrentFile: (json['torrentFile'] as String?)?.trim() ??
          (json['fileHint'] as String?)?.trim(),
      audioLanguages: _stringList(
        json['audioLanguages'] ?? json['audio'] ?? json['audioLangs'],
      ),
      subtitleLanguages: _stringList(
        json['subtitleLanguages'] ??
            json['subLanguages'] ??
            json['subtitleLangs'] ??
            json['subs'],
      ),
      httpHeaders: catalogPlaybackHeadersFromJson(json),
    );
  }
}

List<String> _stringList(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return const [];
}
