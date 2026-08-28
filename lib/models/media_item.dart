import 'dart:convert';

import 'package:javp/models/media_segment.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/playback/audio_stream.dart';

enum MediaKind { local, network, live, vod, series, catchup }

enum MediaOrigin {
  localFile,
  url,
  iptvM3u,
  iptvXtream,
  iptvStalker,
  customCatalog,
  torrent,
  jellyfin,
  emby,
  plex,
  download,
}

extension MediaOriginX on MediaOrigin {
  bool get isMediaServer =>
      this == MediaOrigin.jellyfin ||
      this == MediaOrigin.emby ||
      this == MediaOrigin.plex;
}

/// External subtitle file advertised by a catalog / media server.
class ExternalSubtitle {
  const ExternalSubtitle({
    required this.url,
    this.language,
    this.label,
    this.isDefault = false,
    this.forced = false,
    this.hearingImpaired = false,
    this.format,
  });

  final String url;

  /// BCP-47 / ISO code when known (`en`, `ja`, `fr`).
  final String? language;

  /// Human label (`English`, `Forced`, …).
  final String? label;
  final bool isDefault;
  final bool forced;
  final bool hearingImpaired;

  /// Hint: `srt`, `vtt`, `ass`.
  final String? format;

  String get displayLabel {
    final parts = <String>[
      if ((label ?? '').trim().isNotEmpty) label!.trim(),
      if ((language ?? '').trim().isNotEmpty) language!.trim().toUpperCase(),
      if (forced) 'Forced',
      if (hearingImpaired) 'SDH',
    ];
    if (parts.isEmpty) return 'Subtitle';
    return parts.toSet().join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'language': language,
    'label': label,
    'default': isDefault,
    'forced': forced,
    'hearingImpaired': hearingImpaired,
    'format': format,
  };

  factory ExternalSubtitle.fromJson(Map<String, dynamic> json) {
    final url =
        (json['url'] as String?)?.trim() ??
        (json['uri'] as String?)?.trim() ??
        (json['src'] as String?)?.trim() ??
        '';
    return ExternalSubtitle(
      url: url,
      language:
          (json['language'] as String?)?.trim() ??
          (json['lang'] as String?)?.trim(),
      label:
          (json['label'] as String?)?.trim() ??
          (json['title'] as String?)?.trim() ??
          (json['name'] as String?)?.trim(),
      isDefault: json['default'] == true || json['isDefault'] == true,
      forced: json['forced'] == true || json['isForced'] == true,
      hearingImpaired:
          json['hearingImpaired'] == true ||
          json['sdh'] == true ||
          json['cc'] == true,
      format:
          (json['format'] as String?)?.trim() ??
          (json['type'] as String?)?.trim(),
    );
  }
}

/// External audio file / alternate audio stream from a catalog.
class ExternalAudio {
  const ExternalAudio({
    required this.url,
    this.language,
    this.label,
    this.isDefault = false,
  });

  final String url;
  final String? language;
  final String? label;
  final bool isDefault;

  String get displayLabel {
    final parts = <String>[
      if ((label ?? '').trim().isNotEmpty) label!.trim(),
      if ((language ?? '').trim().isNotEmpty) language!.trim().toUpperCase(),
    ];
    if (parts.isEmpty) return 'Audio';
    return parts.toSet().join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'language': language,
    'label': label,
    'default': isDefault,
  };

  factory ExternalAudio.fromJson(Map<String, dynamic> json) {
    final url =
        (json['url'] as String?)?.trim() ??
        (json['uri'] as String?)?.trim() ??
        (json['src'] as String?)?.trim() ??
        '';
    return ExternalAudio(
      url: url,
      language:
          (json['language'] as String?)?.trim() ??
          (json['lang'] as String?)?.trim(),
      label:
          (json['label'] as String?)?.trim() ??
          (json['title'] as String?)?.trim() ??
          (json['name'] as String?)?.trim(),
      isDefault: json['default'] == true || json['isDefault'] == true,
    );
  }
}

typedef ExternalAudioTrack = ExternalAudio;

class MediaItem {
  const MediaItem({
    required this.id,
    required this.title,
    required this.playUrl,
    required this.kind,
    required this.origin,
    this.subtitle,
    this.thumbnailUrl,
    this.posterUrl,
    this.backdropUrl,
    this.group,
    this.duration,
    this.channelId,
    this.channelName,
    this.streamId,
    this.epgChannelId,
    this.catchupDays = 0,
    this.progress = 0,
    this.lastWatchedAt,
    this.sourceId,
    this.simklId,
    this.traktId,
    this.detailsId,
    this.tmdbId,
    this.anilistId,
    this.imdbId,
    this.tvdbId,
    this.plot,
    this.genres = const [],
    this.rating,
    this.popularity,
    this.year,
    this.seasonNumber,
    this.episodeNumber,
    this.seriesId,
    this.serverItemId,
    this.torrentFile,
    this.audioLanguages = const [],
    this.subtitleLanguages = const [],
    this.subtitles = const [],
    this.audioTracks = const [],
    this.httpHeaders = const {},
    this.segments = const [],
    this.trailerUrl,
    this.contentRating,
    this.isAdult = false,
    this.studio,
    this.originalTitle,
    this.releaseDate,
    this.tags = const [],
    this.resolution,
    this.videoCodec,
    this.audioCodec,
    this.hdr,
    this.updatedAt,
    this.vastUrl,
  });

  final String id;
  final String title;
  final String playUrl;
  final MediaKind kind;
  final MediaOrigin origin;
  final String? subtitle;
  final String? thumbnailUrl;

  /// Portrait poster when available (preferred over [thumbnailUrl] for VOD).
  final String? posterUrl;
  final String? backdropUrl;
  final String? group;
  final Duration? duration;
  final String? channelId;

  /// Official channel label (M3U `tvg-name` / EPG display-name), when known.
  final String? channelName;
  final String? streamId;
  final String? epgChannelId;
  final int catchupDays;
  final double progress;
  final DateTime? lastWatchedAt;
  final String? sourceId;
  final String? simklId;
  final String? traktId;
  final String? detailsId;
  final int? tmdbId;

  /// AniList media id when known (anime bridges).
  final int? anilistId;
  final String? imdbId;
  final int? tvdbId;
  final String? plot;
  final List<String> genres;
  final double? rating;

  /// Catalog-local heat (higher = hotter). Scale is per source; Catalog
  /// Popular percentile-normalizes before mixing catalogs.
  final double? popularity;
  final int? year;
  final int? seasonNumber;
  final int? episodeNumber;

  /// Parent series id for episode rows (custom catalog / media servers).
  final String? seriesId;

  /// Remote media-server item id (Jellyfin/Emby/Plex).
  final String? serverItemId;

  /// Preferred file inside a multi-file magnet (`torrentFile` / `fileHint`).
  final String? torrentFile;

  /// Available audio language codes/labels from the catalog.
  final List<String> audioLanguages;

  /// Available subtitle language codes/labels (embedded or known).
  final List<String> subtitleLanguages;

  /// External subtitle files (SRT/VTT/ASS) loadable during playback.
  final List<ExternalSubtitle> subtitles;

  /// External / alternate audio files from a catalog.
  final List<ExternalAudio> audioTracks;

  /// Optional HTTP headers required to play [playUrl].
  final Map<String, String> httpHeaders;

  /// Intro/credits skip windows attached to this title.
  final List<MediaSegment> segments;
  final String? trailerUrl;
  final String? contentRating;

  /// Source-marked adult content (Xtream `is_adult`, catalog `adult`, etc.).
  /// Missing / false never hides titles; parental lock filters when true.
  final bool isAdult;
  final String? studio;
  final String? originalTitle;
  final String? releaseDate;
  final List<String> tags;
  final String? resolution;
  final String? videoCodec;
  final String? audioCodec;
  final String? hdr;
  final DateTime? updatedAt;

  /// Per-title VAST tag. `null` inherits the source tag; `''` disables ads.
  final String? vastUrl;

  bool get isLive => kind == MediaKind.live;

  /// Icecast / radio / progressive audio with no video plane.
  bool get isAudioOnly => mediaTagsIndicateAudioOnly(tags);

  /// Live radio / music: tagged audio-only, Radio/Music groups, or audio URLs.
  bool get isRadioStation =>
      isAudioOnly ||
      looksLikeRadioGroup(group) ||
      (kind == MediaKind.live && looksLikeAudioOnlyUrl(playUrl));
  bool get supportsCatchup => catchupDays > 0;
  bool get isSeries => kind == MediaKind.series;

  /// Playable episode row (Xtream/Jellyfin/etc. store these as [MediaKind.vod]).
  bool get isEpisode =>
      kind != MediaKind.series &&
      (seasonNumber != null ||
          episodeNumber != null ||
          (seriesId != null && seriesId!.trim().isNotEmpty));
  bool get isPlayable => kind != MediaKind.series;
  bool get hasExternalSubtitles => subtitles.any((s) => s.url.isNotEmpty);
  bool get hasExternalAudio => audioTracks.any((a) => a.url.isNotEmpty);
  bool get hasCatalogSegments => segments.isNotEmpty;

  bool get _hasPosterArt => posterUrl != null && posterUrl!.trim().isNotEmpty;
  bool get _hasBackdropArt =>
      backdropUrl != null && backdropUrl!.trim().isNotEmpty;
  bool get _hasThumbnailArt =>
      thumbnailUrl != null && thumbnailUrl!.trim().isNotEmpty;

  /// Best artwork for shelves: poster for non-live, else thumbnail.
  String? get artUrl {
    if (!isLive && _hasPosterArt) return posterUrl;
    if (_hasThumbnailArt) return thumbnailUrl;
    return posterUrl;
  }

  /// Artwork matched to a portrait (2:3) or landscape (16:9) tile.
  ///
  /// Portrait prefers poster → thumbnail → backdrop.
  /// Landscape prefers backdrop → thumbnail → poster.
  String? artUrlFor({required bool portrait}) {
    if (isLive) return artUrl;
    if (portrait) {
      if (_hasPosterArt) return posterUrl;
      if (_hasThumbnailArt) return thumbnailUrl;
      if (_hasBackdropArt) return backdropUrl;
      return null;
    }
    if (_hasBackdropArt) return backdropUrl;
    if (_hasThumbnailArt) return thumbnailUrl;
    if (_hasPosterArt) return posterUrl;
    return null;
  }

  /// Whether shelf/grid auto layout should use a portrait tile.
  ///
  /// True when a poster URL is available; false when only backdrop-style
  /// art exists (or none) so auto can fall back to landscape.
  bool get prefersPortraitArt => !isLive && _hasPosterArt;

  MediaItem copyWith({
    String? title,
    String? playUrl,
    String? subtitle,
    String? thumbnailUrl,
    String? posterUrl,
    String? backdropUrl,
    String? group,
    Duration? duration,
    String? channelName,
    double? progress,
    DateTime? lastWatchedAt,
    String? sourceId,
    String? simklId,
    String? traktId,
    String? detailsId,
    int? tmdbId,
    int? anilistId,
    String? imdbId,
    int? tvdbId,
    String? plot,
    List<String>? genres,
    double? rating,
    double? popularity,
    int? year,
    int? seasonNumber,
    int? episodeNumber,
    String? seriesId,
    String? serverItemId,
    String? torrentFile,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    List<ExternalSubtitle>? subtitles,
    List<ExternalAudio>? audioTracks,
    Map<String, String>? httpHeaders,
    List<MediaSegment>? segments,
    String? trailerUrl,
    String? contentRating,
    bool? isAdult,
    String? studio,
    String? originalTitle,
    String? releaseDate,
    List<String>? tags,
    String? resolution,
    String? videoCodec,
    String? audioCodec,
    String? hdr,
    DateTime? updatedAt,
    String? vastUrl,
    MediaOrigin? origin,
  }) {
    return MediaItem(
      id: id,
      title: title ?? this.title,
      playUrl: playUrl ?? this.playUrl,
      kind: kind,
      origin: origin ?? this.origin,
      subtitle: subtitle ?? this.subtitle,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      group: group ?? this.group,
      duration: duration ?? this.duration,
      channelId: channelId,
      channelName: channelName ?? this.channelName,
      streamId: streamId,
      epgChannelId: epgChannelId,
      catchupDays: catchupDays,
      progress: progress ?? this.progress,
      lastWatchedAt: lastWatchedAt ?? this.lastWatchedAt,
      sourceId: sourceId ?? this.sourceId,
      simklId: simklId ?? this.simklId,
      traktId: traktId ?? this.traktId,
      detailsId: detailsId ?? this.detailsId,
      tmdbId: tmdbId ?? this.tmdbId,
      anilistId: anilistId ?? this.anilistId,
      imdbId: imdbId ?? this.imdbId,
      tvdbId: tvdbId ?? this.tvdbId,
      plot: plot ?? this.plot,
      genres: genres ?? this.genres,
      rating: rating ?? this.rating,
      popularity: popularity ?? this.popularity,
      year: year ?? this.year,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      seriesId: seriesId ?? this.seriesId,
      serverItemId: serverItemId ?? this.serverItemId,
      torrentFile: torrentFile ?? this.torrentFile,
      audioLanguages: audioLanguages ?? this.audioLanguages,
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      subtitles: subtitles ?? this.subtitles,
      audioTracks: audioTracks ?? this.audioTracks,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      segments: segments ?? this.segments,
      trailerUrl: trailerUrl ?? this.trailerUrl,
      contentRating: contentRating ?? this.contentRating,
      isAdult: isAdult ?? this.isAdult,
      studio: studio ?? this.studio,
      originalTitle: originalTitle ?? this.originalTitle,
      releaseDate: releaseDate ?? this.releaseDate,
      tags: tags ?? this.tags,
      resolution: resolution ?? this.resolution,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      hdr: hdr ?? this.hdr,
      updatedAt: updatedAt ?? this.updatedAt,
      vastUrl: vastUrl ?? this.vastUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'playUrl': origin == MediaOrigin.iptvXtream
        ? stripXtreamCredentials(playUrl)
        : playUrl,
    'kind': kind.name,
    'origin': origin.name,
    'subtitle': subtitle,
    'thumbnailUrl': thumbnailUrl,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'group': group,
    'durationMs': duration?.inMilliseconds,
    'channelId': channelId,
    'channelName': channelName,
    'streamId': streamId,
    'epgChannelId': epgChannelId,
    'catchupDays': catchupDays,
    'progress': progress,
    'lastWatchedAt': lastWatchedAt?.toIso8601String(),
    'sourceId': sourceId,
    'simklId': simklId,
    'traktId': traktId,
    'detailsId': detailsId,
    'tmdbId': tmdbId,
    'anilistId': anilistId,
    'imdbId': imdbId,
    'tvdbId': tvdbId,
    'plot': plot,
    'genres': genres,
    'rating': rating,
    'popularity': popularity,
    'year': year,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'seriesId': seriesId,
    'serverItemId': serverItemId,
    'torrentFile': torrentFile,
    'audioLanguages': audioLanguages,
    'subtitleLanguages': subtitleLanguages,
    'subtitles': subtitles.map((s) => s.toJson()).toList(),
    'audioTracks': audioTracks.map((a) => a.toJson()).toList(),
    'httpHeaders': httpHeaders,
    'segments': segments.map((s) => s.toJson()).toList(),
    'trailerUrl': trailerUrl,
    'contentRating': contentRating,
    'isAdult': isAdult,
    'studio': studio,
    'originalTitle': originalTitle,
    'releaseDate': releaseDate,
    'tags': tags,
    'resolution': resolution,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'hdr': hdr,
    'updatedAt': updatedAt?.toIso8601String(),
    'vastUrl': vastUrl,
  };

  /// Lean history row for profile sync: playhead + CW identity, not catalog fat.
  ///
  /// Drops plot/genres/tracks/tags/headers/segments and keeps a single poster.
  /// [fromJson] still accepts older full snapshots.
  Map<String, dynamic> toSyncJson() {
    final poster = () {
      final p = posterUrl?.trim();
      if (p != null && p.isNotEmpty) return p;
      final t = thumbnailUrl?.trim();
      if (t != null && t.isNotEmpty) return t;
      return null;
    }();
    final map = <String, dynamic>{
      'id': id,
      'title': title,
      'playUrl': origin == MediaOrigin.iptvXtream
          ? stripXtreamCredentials(playUrl)
          : playUrl,
      'kind': kind.name,
      'origin': origin.name,
      'progress': progress,
    };
    void put(String key, Object? value) {
      if (value == null) return;
      if (value is String && value.isEmpty) return;
      map[key] = value;
    }

    put('subtitle', subtitle);
    put('posterUrl', poster);
    put('durationMs', duration?.inMilliseconds);
    put('channelId', channelId);
    put('channelName', channelName);
    put('streamId', streamId);
    if (catchupDays > 0) map['catchupDays'] = catchupDays;
    put('lastWatchedAt', lastWatchedAt?.toIso8601String());
    put('sourceId', sourceId);
    put('simklId', simklId);
    put('traktId', traktId);
    put('detailsId', detailsId);
    put('tmdbId', tmdbId);
    put('anilistId', anilistId);
    put('imdbId', imdbId);
    put('tvdbId', tvdbId);
    put('year', year);
    put('seasonNumber', seasonNumber);
    put('episodeNumber', episodeNumber);
    put('seriesId', seriesId);
    put('serverItemId', serverItemId);
    put('torrentFile', torrentFile);
    if (isAdult) map['isAdult'] = true;
    return map;
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final originName = json['origin'] as String?;
    final origin =
        MediaOrigin.values.asNameMap()[originName] ?? MediaOrigin.url;
    final rawPlayUrl = json['playUrl'] as String;

    return MediaItem(
      id: json['id'] as String,
      title: json['title'] as String,
      playUrl: origin == MediaOrigin.iptvXtream
          ? stripXtreamCredentials(rawPlayUrl)
          : rawPlayUrl,
      kind: MediaKind.values.byName(json['kind'] as String),
      origin: origin,
      subtitle: json['subtitle'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      group: json['group'] as String?,
      duration: json['durationMs'] == null
          ? null
          : Duration(milliseconds: (json['durationMs'] as num).toInt()),
      channelId: json['channelId'] as String?,
      channelName: json['channelName'] as String?,
      streamId: json['streamId'] as String?,
      epgChannelId: json['epgChannelId'] as String?,
      catchupDays: (json['catchupDays'] as num?)?.toInt() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      lastWatchedAt: json['lastWatchedAt'] == null
          ? null
          : DateTime.tryParse(json['lastWatchedAt'] as String),
      sourceId: json['sourceId'] as String?,
      simklId: json['simklId'] as String?,
      traktId: json['traktId'] as String?,
      detailsId: json['detailsId'] as String?,
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      anilistId: (json['anilistId'] as num?)?.toInt(),
      imdbId: json['imdbId'] as String?,
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      plot: json['plot'] as String?,
      genres: (json['genres'] as List?)?.map((e) => '$e').toList() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      popularity: (json['popularity'] as num?)?.toDouble(),
      year: (json['year'] as num?)?.toInt(),
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      seriesId: json['seriesId'] as String?,
      serverItemId: json['serverItemId'] as String?,
      torrentFile:
          (json['torrentFile'] as String?)?.trim() ??
          (json['fileHint'] as String?)?.trim(),
      audioLanguages: _stringListFromJson(json['audioLanguages']),
      subtitleLanguages: _stringListFromJson(json['subtitleLanguages']),
      subtitles: _subtitlesFromJson(json['subtitles']),
      audioTracks: _audioTracksFromJson(json['audioTracks']),
      httpHeaders: _stringMapFromJson(json['httpHeaders'] ?? json['headers']),
      segments: _segmentsFromJson(json['segments']),
      trailerUrl: json['trailerUrl'] as String?,
      contentRating: json['contentRating'] as String?,
      isAdult:
          json['isAdult'] == true ||
          json['isAdult'] == 1 ||
          json['isAdult'] == '1' ||
          json['adult'] == true ||
          json['adult'] == 1 ||
          json['adult'] == '1' ||
          json['is_adult'] == true ||
          json['is_adult'] == 1 ||
          json['is_adult'] == '1',
      studio: json['studio'] as String?,
      originalTitle: json['originalTitle'] as String?,
      releaseDate: json['releaseDate'] as String?,
      tags: _stringListFromJson(json['tags']),
      resolution: json['resolution'] as String?,
      videoCodec: json['videoCodec'] as String?,
      audioCodec: json['audioCodec'] as String?,
      hdr: json['hdr'] as String?,
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.tryParse('${json['updatedAt']}'),
      vastUrl: json.containsKey('vastUrl')
          ? '${json['vastUrl'] ?? ''}'.trim()
          : json.containsKey('vast')
          ? '${json['vast'] ?? ''}'.trim()
          : null,
    );
  }
}

List<String> _stringListFromJson(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw
        .split(RegExp(r'[,|/]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}

Map<String, String> _stringMapFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, String>{};
  raw.forEach((key, value) {
    final k = '$key'.trim();
    final v = '$value'.trim();
    if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
  });
  return out;
}

List<ExternalSubtitle> _subtitlesFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <ExternalSubtitle>[];
  for (final entry in raw) {
    if (entry is String && entry.trim().isNotEmpty) {
      out.add(ExternalSubtitle(url: entry.trim()));
      continue;
    }
    if (entry is Map) {
      final track = ExternalSubtitle.fromJson(Map<String, dynamic>.from(entry));
      if (track.url.isNotEmpty) out.add(track);
    }
  }
  return out;
}

List<ExternalAudio> _audioTracksFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <ExternalAudio>[];
  for (final entry in raw) {
    if (entry is String && entry.trim().isNotEmpty) {
      out.add(ExternalAudio(url: entry.trim()));
      continue;
    }
    if (entry is Map) {
      final track = ExternalAudio.fromJson(Map<String, dynamic>.from(entry));
      if (track.url.isNotEmpty) out.add(track);
    }
  }
  return out;
}

List<MediaSegment> _segmentsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <MediaSegment>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    try {
      out.add(MediaSegment.fromJson(map));
    } catch (_) {
      final typeName = '${map['type'] ?? 'intro'}';
      final type =
          MediaSegmentType.values.asNameMap()[typeName] ??
          MediaSegmentType.intro;
      out.add(
        MediaSegment(
          type: type,
          start: Duration(milliseconds: (map['startMs'] as num?)?.toInt() ?? 0),
          end: map['endMs'] == null
              ? null
              : Duration(milliseconds: (map['endMs'] as num).toInt()),
          source: '${map['source'] ?? 'catalog'}',
        ),
      );
    }
  }
  return out;
}

/// Coerce go_router `extra` into a [MediaItem] (typed object or JSON map).
///
/// Linux/desktop route restoration can round-trip extras through a codec that
/// turns ints into doubles and drops null [playUrl]. Catalog search hits must
/// still open `/title` after that hop.
MediaItem? mediaItemFromRouteExtra(Object? extra) {
  if (extra == null) return null;
  if (extra is MediaItem) return extra;
  if (extra is Map) {
    try {
      final map = <String, dynamic>{};
      extra.forEach((key, value) {
        final k = '$key';
        if (k.isEmpty) return;
        map[k] = value;
      });
      final id = '${map['id'] ?? ''}'.trim();
      final title = '${map['title'] ?? ''}'.trim();
      if (id.isEmpty || title.isEmpty) return null;
      map['id'] = id;
      map['title'] = title;
      map['playUrl'] = '${map['playUrl'] ?? ''}';
      final kind = map['kind'];
      if (kind is! String || kind.trim().isEmpty) {
        map['kind'] = 'vod';
      } else {
        map['kind'] = kind.trim();
      }
      return MediaItem.fromJson(map);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Serializes [MediaItem] route extras so router refreshes keep a playable object.
class MediaItemRouteExtraCodec extends Codec<Object?, Object?> {
  const MediaItemRouteExtraCodec();

  @override
  Converter<Object?, Object?> get decoder =>
      const _MediaItemRouteExtraDecoder();

  @override
  Converter<Object?, Object?> get encoder =>
      const _MediaItemRouteExtraEncoder();
}

class _MediaItemRouteExtraEncoder extends Converter<Object?, Object?> {
  const _MediaItemRouteExtraEncoder();

  @override
  Object? convert(Object? input) {
    if (input is MediaItem) return input.toJson();
    return input;
  }
}

class _MediaItemRouteExtraDecoder extends Converter<Object?, Object?> {
  const _MediaItemRouteExtraDecoder();

  @override
  Object? convert(Object? input) {
    return mediaItemFromRouteExtra(input) ?? input;
  }
}
