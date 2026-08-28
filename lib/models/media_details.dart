import 'package:javp/models/series_info.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';

/// Rich metadata for a title (movie, episode, or series shell).
///
/// [MediaItem] stays the lightweight shelf/playback row; this holds plot,
/// artwork, cast, external ids, and optional season trees.
class MediaDetails {
  const MediaDetails({
    required this.id,
    required this.title,
    this.mediaItemId,
    this.tmdbId,
    this.simklId,
    this.traktId,
    this.anilistId,
    this.imdbId,
    this.tvdbId,
    this.plot,
    this.posterUrl,
    this.backdropUrl,
    this.genres = const [],
    this.rating,
    this.year,
    this.runtime,
    this.cast = const [],
    this.trailerUrl,
    this.trailerKey,
    this.collectionId,
    this.collectionName,
    this.seasons = const [],
    this.seasonNumber,
    this.episodeNumber,
    this.tags = const [],
    this.contentRating,
    this.studio,
    this.originalTitle,
    this.releaseDate,
    this.updatedAt,
  });

  /// Stable details cache key (often equals [mediaItemId] or `tmdb-movie-123`).
  final String id;
  final String title;
  final String? mediaItemId;
  final int? tmdbId;
  final String? simklId;
  final String? traktId;
  final int? anilistId;
  final String? imdbId;
  final int? tvdbId;
  final String? plot;
  final String? posterUrl;
  final String? backdropUrl;
  final List<String> genres;
  final double? rating;
  final int? year;
  final Duration? runtime;
  final List<CastMember> cast;
  final String? trailerUrl;
  final String? trailerKey;
  final int? collectionId;
  final String? collectionName;
  final List<SeriesSeasonDetails> seasons;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<String> tags;
  final String? contentRating;
  final String? studio;
  final String? originalTitle;
  final String? releaseDate;
  final DateTime? updatedAt;

  bool get isSeries => seasons.isNotEmpty;
  bool get hasTrailer =>
      (trailerUrl != null && trailerUrl!.isNotEmpty) ||
      (trailerKey != null && trailerKey!.isNotEmpty);

  String? get youtubeTrailerUrl {
    if (trailerUrl != null && trailerUrl!.isNotEmpty) return trailerUrl;
    if (trailerKey == null || trailerKey!.isEmpty) return null;
    return 'https://www.youtube.com/watch?v=$trailerKey';
  }

  MediaDetails copyWith({
    String? title,
    String? mediaItemId,
    int? tmdbId,
    String? simklId,
    String? traktId,
    int? anilistId,
    String? imdbId,
    int? tvdbId,
    String? plot,
    String? posterUrl,
    String? backdropUrl,
    List<String>? genres,
    double? rating,
    int? year,
    Duration? runtime,
    List<CastMember>? cast,
    String? trailerUrl,
    String? trailerKey,
    int? collectionId,
    String? collectionName,
    List<SeriesSeasonDetails>? seasons,
    int? seasonNumber,
    int? episodeNumber,
    List<String>? tags,
    String? contentRating,
    String? studio,
    String? originalTitle,
    String? releaseDate,
    DateTime? updatedAt,
  }) {
    return MediaDetails(
      id: id,
      title: title ?? this.title,
      mediaItemId: mediaItemId ?? this.mediaItemId,
      tmdbId: tmdbId ?? this.tmdbId,
      simklId: simklId ?? this.simklId,
      traktId: traktId ?? this.traktId,
      anilistId: anilistId ?? this.anilistId,
      imdbId: imdbId ?? this.imdbId,
      tvdbId: tvdbId ?? this.tvdbId,
      plot: plot ?? this.plot,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      genres: genres ?? this.genres,
      rating: rating ?? this.rating,
      year: year ?? this.year,
      runtime: runtime ?? this.runtime,
      cast: cast ?? this.cast,
      trailerUrl: trailerUrl ?? this.trailerUrl,
      trailerKey: trailerKey ?? this.trailerKey,
      collectionId: collectionId ?? this.collectionId,
      collectionName: collectionName ?? this.collectionName,
      seasons: seasons ?? this.seasons,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      tags: tags ?? this.tags,
      contentRating: contentRating ?? this.contentRating,
      studio: studio ?? this.studio,
      originalTitle: originalTitle ?? this.originalTitle,
      releaseDate: releaseDate ?? this.releaseDate,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'mediaItemId': mediaItemId,
    'tmdbId': tmdbId,
    'simklId': simklId,
    'traktId': traktId,
    'anilistId': anilistId,
    'imdbId': imdbId,
    'tvdbId': tvdbId,
    'plot': plot,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'genres': genres,
    'rating': rating,
    'year': year,
    'runtimeMs': runtime?.inMilliseconds,
    'cast': cast.map((c) => c.toJson()).toList(),
    'trailerUrl': trailerUrl,
    'trailerKey': trailerKey,
    'collectionId': collectionId,
    'collectionName': collectionName,
    'seasons': seasons.map((s) => s.toJson()).toList(),
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'tags': tags,
    'contentRating': contentRating,
    'studio': studio,
    'originalTitle': originalTitle,
    'releaseDate': releaseDate,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory MediaDetails.fromJson(Map<String, dynamic> json) {
    return MediaDetails(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      mediaItemId: json['mediaItemId'] as String?,
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      simklId: json['simklId'] as String?,
      traktId: json['traktId'] as String?,
      anilistId: (json['anilistId'] as num?)?.toInt(),
      imdbId: json['imdbId'] as String?,
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      plot: json['plot'] as String?,
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      genres: (json['genres'] as List?)?.cast<String>() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      year: (json['year'] as num?)?.toInt(),
      runtime: json['runtimeMs'] == null
          ? null
          : Duration(milliseconds: json['runtimeMs'] as int),
      cast:
          (json['cast'] as List?)
              ?.whereType<Map>()
              .map((e) => CastMember.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      trailerUrl: json['trailerUrl'] as String?,
      trailerKey: json['trailerKey'] as String?,
      collectionId: (json['collectionId'] as num?)?.toInt(),
      collectionName: json['collectionName'] as String?,
      seasons:
          (json['seasons'] as List?)
              ?.whereType<Map>()
              .map(
                (e) =>
                    SeriesSeasonDetails.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList() ??
          const [],
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      tags: (json['tags'] as List?)?.cast<String>() ?? const [],
      contentRating: json['contentRating'] as String?,
      studio: json['studio'] as String?,
      originalTitle: json['originalTitle'] as String?,
      releaseDate: json['releaseDate'] as String?,
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.tryParse(json['updatedAt'] as String),
    );
  }
}

class CastMember {
  const CastMember({
    required this.name,
    this.character,
    this.profileUrl,
    this.order = 0,
  });

  final String name;
  final String? character;
  final String? profileUrl;
  final int order;

  Map<String, dynamic> toJson() => {
    'name': name,
    'character': character,
    'profileUrl': profileUrl,
    'order': order,
  };

  factory CastMember.fromJson(Map<String, dynamic> json) {
    return CastMember(
      name: json['name'] as String? ?? '',
      character: json['character'] as String?,
      profileUrl: json['profileUrl'] as String?,
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }
}

class SeriesSeasonDetails {
  const SeriesSeasonDetails({
    required this.seasonNumber,
    required this.name,
    required this.episodes,
    this.posterUrl,
  });

  final int seasonNumber;
  final String name;
  final String? posterUrl;
  final List<SeriesEpisodeDetails> episodes;

  Map<String, dynamic> toJson() => {
    'seasonNumber': seasonNumber,
    'name': name,
    'posterUrl': posterUrl,
    'episodes': episodes.map((e) => e.toJson()).toList(),
  };

  factory SeriesSeasonDetails.fromJson(Map<String, dynamic> json) {
    return SeriesSeasonDetails(
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      posterUrl: json['posterUrl'] as String?,
      episodes:
          (json['episodes'] as List?)
              ?.whereType<Map>()
              .map(
                (e) =>
                    SeriesEpisodeDetails.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList() ??
          const [],
    );
  }
}

class SeriesEpisodeDetails {
  const SeriesEpisodeDetails({
    required this.id,
    required this.episodeNumber,
    required this.seasonNumber,
    required this.title,
    this.plot,
    this.thumbnailUrl,
    this.duration,
    this.airDate,
    this.playUrl,
    this.tmdbId,
    this.torrentFile,
    this.resolution,
    this.playVariants = const [],
    this.httpHeaders = const {},
  });

  final String id;
  final int episodeNumber;
  final int seasonNumber;
  final String title;
  final String? plot;
  final String? thumbnailUrl;
  final Duration? duration;
  final DateTime? airDate;
  final String? playUrl;
  final int? tmdbId;
  final String? torrentFile;
  final String? resolution;
  final List<EpisodePlayVariant> playVariants;
  /// Playback headers for [playUrl] (catalog `httpHeaders` / `userAgent`).
  final Map<String, String> httpHeaders;

  String get shortLabel =>
      'S${seasonNumber.toString().padLeft(2, '0')}'
      'E${episodeNumber.toString().padLeft(2, '0')}';

  SeriesEpisodeDetails copyWith({
    String? title,
    String? plot,
    String? thumbnailUrl,
    Duration? duration,
    DateTime? airDate,
    String? playUrl,
    int? tmdbId,
    String? torrentFile,
    String? resolution,
    List<EpisodePlayVariant>? playVariants,
    Map<String, String>? httpHeaders,
  }) {
    return SeriesEpisodeDetails(
      id: id,
      episodeNumber: episodeNumber,
      seasonNumber: seasonNumber,
      title: title ?? this.title,
      plot: plot ?? this.plot,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      airDate: airDate ?? this.airDate,
      playUrl: playUrl ?? this.playUrl,
      tmdbId: tmdbId ?? this.tmdbId,
      torrentFile: torrentFile ?? this.torrentFile,
      resolution: resolution ?? this.resolution,
      playVariants: playVariants ?? this.playVariants,
      httpHeaders: httpHeaders ?? this.httpHeaders,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'episodeNumber': episodeNumber,
    'seasonNumber': seasonNumber,
    'title': title,
    'plot': plot,
    'thumbnailUrl': thumbnailUrl,
    'durationMs': duration?.inMilliseconds,
    if (airDate != null)
      'airDate':
          '${airDate!.year.toString().padLeft(4, '0')}-'
          '${airDate!.month.toString().padLeft(2, '0')}-'
          '${airDate!.day.toString().padLeft(2, '0')}',
    'playUrl': playUrl,
    'tmdbId': tmdbId,
    'torrentFile': torrentFile,
    'resolution': resolution,
    'playVariants': playVariants.map((e) => e.toJson()).toList(),
    if (httpHeaders.isNotEmpty) 'httpHeaders': httpHeaders,
  };

  factory SeriesEpisodeDetails.fromJson(Map<String, dynamic> json) {
    final variantsRaw = json['playVariants'] ?? json['variants'];
    final variants = <EpisodePlayVariant>[];
    if (variantsRaw is List) {
      for (final entry in variantsRaw) {
        if (entry is Map) {
          final v = EpisodePlayVariant.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (v.playUrl.isNotEmpty) variants.add(v);
        } else if (entry is String && entry.trim().isNotEmpty) {
          variants.add(
            EpisodePlayVariant(
              id: '${json['id']}-v${variants.length}',
              label: 'Version ${variants.length + 1}',
              playUrl: entry.trim(),
            ),
          );
        }
      }
    }
    return SeriesEpisodeDetails(
      id: json['id'] as String? ?? '',
      episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      plot: json['plot'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      duration: json['durationMs'] == null
          ? null
          : Duration(milliseconds: json['durationMs'] as int),
      airDate: SeriesEpisode.parseAirDate(
        json['airDate'] ?? json['releaseDate'] ?? json['air_date'],
      ),
      playUrl: json['playUrl'] as String?,
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      torrentFile:
          (json['torrentFile'] as String?)?.trim() ??
          (json['fileHint'] as String?)?.trim(),
      resolution: (json['resolution'] as String?)?.trim(),
      playVariants: variants,
      httpHeaders: catalogPlaybackHeadersFromJson(json),
    );
  }
}
