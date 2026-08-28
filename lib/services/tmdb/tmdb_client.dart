import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/media_details.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/models/tmdb_credentials.dart';

/// BYO TMDB v3 API client.
class TmdbClient {
  TmdbClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  static const _base = 'https://api.themoviedb.org/3';
  static const imageBase = 'https://image.tmdb.org/t/p';

  static String? posterUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return '$imageBase/$size$path';
  }

  static String? backdropUrl(String? path, {String size = 'w780'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return '$imageBase/$size$path';
  }

  Future<bool> validate(TmdbCredentials creds) async {
    if (!creds.isConfigured) return false;
    final uri = Uri.parse(
      '$_base/configuration',
    ).replace(queryParameters: {'api_key': creds.apiKey.trim()});
    try {
      final response = await _http.get(uri);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<List<TmdbSearchHit>> search(
    TmdbCredentials creds, {
    required String query,
    String? type,
    int? year,
    String? language,
  }) async {
    if (!creds.isConfigured || query.trim().isEmpty) return const [];
    final endpoint = switch (type) {
      'tv' => 'search/tv',
      'movie' => 'search/movie',
      _ => 'search/multi',
    };
    final params = <String, String>{
      'api_key': creds.apiKey.trim(),
      'query': query.trim(),
      'include_adult': 'false',
      if (language != null && language.isNotEmpty) 'language': language,
    };
    if (year != null) {
      if (type == 'tv') {
        params['first_air_date_year'] = '$year';
      } else {
        params['year'] = '$year';
      }
    }
    final uri = Uri.parse('$_base/$endpoint').replace(queryParameters: params);
    final http.Response response;
    try {
      response = await _http.get(uri);
    } catch (_) {
      return const [];
    }
    if (response.statusCode >= 400) return const [];
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final results = decoded['results'] as List? ?? const [];
    final hits = <TmdbSearchHit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final mediaType = (map['media_type'] as String?) ?? type ?? 'movie';
      if (mediaType == 'person') continue;
      final title = (map['title'] as String?) ?? (map['name'] as String?) ?? '';
      if (title.isEmpty) continue;
      final date =
          (map['release_date'] as String?) ??
          (map['first_air_date'] as String?) ??
          '';
      hits.add(
        TmdbSearchHit(
          id: (map['id'] as num).toInt(),
          title: title,
          mediaType: mediaType == 'tv' ? 'tv' : 'movie',
          year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
          posterUrl: posterUrl(map['poster_path'] as String?),
          overview: map['overview'] as String?,
        ),
      );
    }
    return hits;
  }

  /// Titles similar to [tmdbId] (`/movie|tv/{id}/similar`).
  Future<List<TmdbSearchHit>> similar(
    TmdbCredentials creds, {
    required int tmdbId,
    required String mediaType,
    int page = 1,
    String? language,
  }) {
    if (tmdbId <= 0) return Future.value(const []);
    return _relatedList(
      creds,
      path: '/${_mediaPath(mediaType)}/$tmdbId/similar',
      mediaType: mediaType == 'tv' ? 'tv' : 'movie',
      page: page,
      language: language,
    );
  }

  /// Editorial recommendations for [tmdbId] (`/movie|tv/{id}/recommendations`).
  Future<List<TmdbSearchHit>> recommendations(
    TmdbCredentials creds, {
    required int tmdbId,
    required String mediaType,
    int page = 1,
    String? language,
  }) {
    if (tmdbId <= 0) return Future.value(const []);
    return _relatedList(
      creds,
      path: '/${_mediaPath(mediaType)}/$tmdbId/recommendations',
      mediaType: mediaType == 'tv' ? 'tv' : 'movie',
      page: page,
      language: language,
    );
  }

  /// Global trending (`/trending/{media_type}/{time_window}`).
  ///
  /// [mediaType] is `all`, `movie`, or `tv`. [timeWindow] is `day` or `week`.
  Future<List<TmdbSearchHit>> trending(
    TmdbCredentials creds, {
    String mediaType = 'all',
    String timeWindow = 'week',
    int page = 1,
    String? language,
  }) async {
    if (!creds.isConfigured) return const [];
    final type = switch (mediaType) {
      'movie' => 'movie',
      'tv' => 'tv',
      _ => 'all',
    };
    final window = timeWindow == 'day' ? 'day' : 'week';
    final detail = await _get(creds, '/trending/$type/$window', {
      'page': '$page',
      if (language != null && language.isNotEmpty) 'language': language,
    });
    return _parseResultHits(
      detail,
      defaultMediaType: type == 'all' ? null : type,
    );
  }

  /// Popular movies (`/movie/popular`).
  Future<List<TmdbSearchHit>> popularMovies(
    TmdbCredentials creds, {
    int page = 1,
    String? language,
  }) {
    return _relatedList(
      creds,
      path: '/movie/popular',
      mediaType: 'movie',
      page: page,
      language: language,
    );
  }

  /// Popular TV (`/tv/popular`).
  Future<List<TmdbSearchHit>> popularTv(
    TmdbCredentials creds, {
    int page = 1,
    String? language,
  }) {
    return _relatedList(
      creds,
      path: '/tv/popular',
      mediaType: 'tv',
      page: page,
      language: language,
    );
  }

  static String _mediaPath(String mediaType) =>
      mediaType == 'tv' ? 'tv' : 'movie';

  Future<List<TmdbSearchHit>> _relatedList(
    TmdbCredentials creds, {
    required String path,
    required String mediaType,
    int page = 1,
    String? language,
  }) async {
    if (!creds.isConfigured) return const [];
    final detail = await _get(creds, path, {
      'page': '$page',
      if (language != null && language.isNotEmpty) 'language': language,
    });
    return _parseResultHits(detail, defaultMediaType: mediaType);
  }

  List<TmdbSearchHit> _parseResultHits(
    Map<String, dynamic>? detail, {
    String? defaultMediaType,
  }) {
    if (detail == null) return const [];
    final results = detail['results'] as List? ?? const [];
    final hits = <TmdbSearchHit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final mediaTypeRaw =
          (map['media_type'] as String?) ?? defaultMediaType ?? 'movie';
      if (mediaTypeRaw == 'person') continue;
      final mediaType = mediaTypeRaw == 'tv' ? 'tv' : 'movie';
      final title = (map['title'] as String?) ?? (map['name'] as String?) ?? '';
      if (title.isEmpty) continue;
      final id = (map['id'] as num?)?.toInt();
      if (id == null || id <= 0) continue;
      final date =
          (map['release_date'] as String?) ??
          (map['first_air_date'] as String?) ??
          '';
      hits.add(
        TmdbSearchHit(
          id: id,
          title: title,
          mediaType: mediaType,
          year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
          posterUrl: posterUrl(map['poster_path'] as String?),
          overview: map['overview'] as String?,
        ),
      );
    }
    return hits;
  }

  Future<MediaDetails?> fetchMovie(
    TmdbCredentials creds,
    int tmdbId, {
    String? mediaItemId,
    String? language,
  }) async {
    if (!creds.isConfigured) return null;
    final detail = await _get(creds, '/movie/$tmdbId', {
      'append_to_response': 'credits,videos,external_ids,release_dates',
      if (language != null && language.isNotEmpty) 'language': language,
    });
    if (detail == null) return null;
    return _mapMovie(detail, mediaItemId: mediaItemId, language: language);
  }

  Future<MediaDetails?> fetchTv(
    TmdbCredentials creds,
    int tmdbId, {
    String? mediaItemId,
    String? language,
  }) async {
    if (!creds.isConfigured) return null;
    final detail = await _get(creds, '/tv/$tmdbId', {
      'append_to_response': 'credits,videos,external_ids,content_ratings',
      if (language != null && language.isNotEmpty) 'language': language,
    });
    if (detail == null) return null;
    return _mapTv(detail, mediaItemId: mediaItemId, language: language);
  }

  /// Resolve a TMDB title from IMDb / TVDB (`/find/{id}`).
  Future<TmdbSearchHit?> findByExternalId(
    TmdbCredentials creds, {
    String? imdbId,
    int? tvdbId,
    String? language,
  }) async {
    if (!creds.isConfigured) return null;
    final imdb = imdbId?.trim();
    if (imdb != null && imdb.isNotEmpty) {
      final hit = await _findExternal(
        creds,
        externalId: imdb,
        externalSource: 'imdb_id',
        language: language,
      );
      if (hit != null) return hit;
    }
    if (tvdbId != null && tvdbId > 0) {
      return _findExternal(
        creds,
        externalId: '$tvdbId',
        externalSource: 'tvdb_id',
        language: language,
      );
    }
    return null;
  }

  Future<TmdbSearchHit?> _findExternal(
    TmdbCredentials creds, {
    required String externalId,
    required String externalSource,
    String? language,
  }) async {
    final detail = await _get(creds, '/find/$externalId', {
      'external_source': externalSource,
      if (language != null && language.isNotEmpty) 'language': language,
    });
    if (detail == null) return null;
    for (final key in const [
      'movie_results',
      'tv_results',
      'tv_episode_results',
      'tv_season_results',
    ]) {
      final list = detail[key] as List? ?? const [];
      for (final raw in list) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final id = (map['id'] as num?)?.toInt();
        if (id == null || id <= 0) continue;
        final title =
            (map['title'] as String?) ?? (map['name'] as String?) ?? '';
        if (title.isEmpty) continue;
        final mediaType = key.startsWith('tv') ? 'tv' : 'movie';
        // Episode/season hits still carry the show id in some payloads; prefer
        // movie/tv_results. Skip pure episode rows without a useful title date.
        if (key == 'tv_episode_results' || key == 'tv_season_results') {
          continue;
        }
        final date =
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?) ??
            '';
        return TmdbSearchHit(
          id: id,
          title: title,
          mediaType: mediaType,
          year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
          posterUrl: posterUrl(map['poster_path'] as String?),
          overview: map['overview'] as String?,
        );
      }
    }
    return null;
  }

  /// Franchise / collection members (`/collection/{id}`).
  Future<TmdbCollectionInfo?> fetchCollection(
    TmdbCredentials creds,
    int collectionId, {
    String? language,
  }) async {
    if (!creds.isConfigured || collectionId <= 0) return null;
    final detail = await _get(creds, '/collection/$collectionId', {
      if (language != null && language.isNotEmpty) 'language': language,
    });
    if (detail == null) return null;
    final partsRaw = detail['parts'] as List? ?? const [];
    final parts = <TmdbCollectionPart>[];
    for (final raw in partsRaw) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = (map['id'] as num?)?.toInt();
      if (id == null || id <= 0) continue;
      final title = (map['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;
      final date = map['release_date'] as String? ?? '';
      parts.add(
        TmdbCollectionPart(
          tmdbId: id,
          title: title,
          year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
          posterUrl: posterUrl(map['poster_path'] as String?),
          overview: (map['overview'] as String?)?.trim(),
        ),
      );
    }
    return TmdbCollectionInfo(
      id: collectionId,
      name: (detail['name'] as String?)?.trim() ?? '',
      overview: (detail['overview'] as String?)?.trim(),
      posterUrl: posterUrl(detail['poster_path'] as String?),
      backdropUrl: backdropUrl(detail['backdrop_path'] as String?),
      parts: parts,
    );
  }

  /// Season episode rows with stills (`/tv/{id}/season/{n}`).
  ///
  /// Used to fill series-page episode tiles when the catalog omits art —
  /// does not replace playback URLs.
  Future<List<TmdbSeasonEpisode>> fetchTvSeason(
    TmdbCredentials creds,
    int tmdbId, {
    required int seasonNumber,
    String? language,
  }) async {
    if (!creds.isConfigured || tmdbId <= 0 || seasonNumber < 0) {
      return const [];
    }
    final detail = await _get(creds, '/tv/$tmdbId/season/$seasonNumber', {
      if (language != null && language.isNotEmpty) 'language': language,
    });
    if (detail == null) return const [];
    final raw = detail['episodes'] as List? ?? const [];
    final out = <TmdbSeasonEpisode>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final epNum = (map['episode_number'] as num?)?.toInt();
      if (epNum == null || epNum < 0) continue;
      final runtimeMin = (map['runtime'] as num?)?.toInt();
      out.add(
        TmdbSeasonEpisode(
          episodeNumber: epNum,
          seasonNumber: seasonNumber,
          title: (map['name'] as String?)?.trim(),
          plot: _nonEmpty(map['overview'] as String?),
          thumbnailUrl: posterUrl(map['still_path'] as String?, size: 'w300'),
          duration: runtimeMin == null || runtimeMin <= 0
              ? null
              : Duration(minutes: runtimeMin),
          airDate: SeriesEpisode.parseAirDate(map['air_date']),
          tmdbId: (map['id'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  Future<Map<String, dynamic>?> _get(
    TmdbCredentials creds,
    String path,
    Map<String, String> extra,
  ) async {
    final params = {'api_key': creds.apiKey.trim(), ...extra};
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);
    try {
      final response = await _http.get(uri);
      if (response.statusCode >= 400) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  MediaDetails _mapMovie(
    Map<String, dynamic> map, {
    String? mediaItemId,
    String? language,
  }) {
    final genres =
        (map['genres'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['name'] ?? ''}')
            .where((n) => n.isNotEmpty)
            .toList() ??
        const <String>[];
    final credits = map['credits'] as Map<String, dynamic>? ?? const {};
    final cast = _mapCastAndCrew(
      cast: credits['cast'] as List?,
      crew: credits['crew'] as List?,
    );
    final videos = map['videos'] as Map<String, dynamic>? ?? const {};
    final trailerKey = _pickTrailerKey(videos['results'] as List?);
    final external = map['external_ids'] as Map<String, dynamic>? ?? const {};
    final collection = map['belongs_to_collection'] as Map<String, dynamic>?;
    final date = map['release_date'] as String? ?? '';
    final runtimeMin = (map['runtime'] as num?)?.toInt();
    final companies = map['production_companies'] as List? ?? const [];
    final studio = _firstNamed(companies);

    return MediaDetails(
      id: 'tmdb-movie-${map['id']}',
      title: map['title'] as String? ?? '',
      mediaItemId: mediaItemId,
      tmdbId: (map['id'] as num?)?.toInt(),
      imdbId: external['imdb_id'] as String? ?? map['imdb_id'] as String?,
      plot: _nonEmpty(map['overview'] as String?),
      posterUrl: posterUrl(map['poster_path'] as String?),
      backdropUrl: backdropUrl(map['backdrop_path'] as String?),
      genres: genres,
      rating: (map['vote_average'] as num?)?.toDouble(),
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      runtime: runtimeMin == null ? null : Duration(minutes: runtimeMin),
      cast: cast,
      trailerKey: trailerKey,
      collectionId: (collection?['id'] as num?)?.toInt(),
      collectionName: collection?['name'] as String?,
      contentRating: _movieCertification(map, language),
      studio: studio,
      originalTitle: (map['original_title'] as String?)?.trim(),
      releaseDate: date.isNotEmpty ? date : null,
      updatedAt: DateTime.now(),
    );
  }

  MediaDetails _mapTv(
    Map<String, dynamic> map, {
    String? mediaItemId,
    String? language,
  }) {
    final genres =
        (map['genres'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['name'] ?? ''}')
            .where((n) => n.isNotEmpty)
            .toList() ??
        const <String>[];
    final credits = map['credits'] as Map<String, dynamic>? ?? const {};
    final cast = _mapCastAndCrew(
      cast: credits['cast'] as List?,
      crew: credits['crew'] as List?,
      creators: map['created_by'] as List?,
    );
    final videos = map['videos'] as Map<String, dynamic>? ?? const {};
    final trailerKey = _pickTrailerKey(videos['results'] as List?);
    final external = map['external_ids'] as Map<String, dynamic>? ?? const {};
    final date = map['first_air_date'] as String? ?? '';
    final seasonsRaw = map['seasons'] as List? ?? const [];
    final seasons = <SeriesSeasonDetails>[];
    for (final raw in seasonsRaw) {
      if (raw is! Map) continue;
      final s = Map<String, dynamic>.from(raw);
      final seasonNum = (s['season_number'] as num?)?.toInt() ?? 0;
      if (seasonNum <= 0) continue;
      seasons.add(
        SeriesSeasonDetails(
          seasonNumber: seasonNum,
          name: s['name'] as String? ?? 'Season $seasonNum',
          posterUrl: posterUrl(s['poster_path'] as String?),
          episodes: const [],
        ),
      );
    }
    final networks = map['networks'] as List? ?? const [];
    final companies = map['production_companies'] as List? ?? const [];
    final studio = _firstNamed(networks) ?? _firstNamed(companies);

    return MediaDetails(
      id: 'tmdb-tv-${map['id']}',
      title: map['name'] as String? ?? '',
      mediaItemId: mediaItemId,
      tmdbId: (map['id'] as num?)?.toInt(),
      imdbId: external['imdb_id'] as String?,
      tvdbId: (external['tvdb_id'] as num?)?.toInt(),
      plot: _nonEmpty(map['overview'] as String?),
      posterUrl: posterUrl(map['poster_path'] as String?),
      backdropUrl: backdropUrl(map['backdrop_path'] as String?),
      genres: genres,
      rating: (map['vote_average'] as num?)?.toDouble(),
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      cast: cast,
      trailerKey: trailerKey,
      seasons: seasons,
      contentRating: _tvContentRating(map, language),
      studio: studio,
      originalTitle: (map['original_name'] as String?)?.trim(),
      releaseDate: date.isNotEmpty ? date : null,
      updatedAt: DateTime.now(),
    );
  }

  List<CastMember> _mapCastAndCrew({List? cast, List? crew, List? creators}) {
    final out = <CastMember>[];
    final seen = <String>{};

    void addPerson({
      required String name,
      required String? role,
      String? profilePath,
      required int order,
    }) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) return;
      final key = trimmed.toLowerCase();
      if (!seen.add(key)) return;
      out.add(
        CastMember(
          name: trimmed,
          character: role,
          profileUrl: posterUrl(profilePath, size: 'w185'),
          order: order,
        ),
      );
    }

    var order = -20;
    if (creators != null) {
      for (final raw in creators.take(3)) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        addPerson(
          name: map['name'] as String? ?? '',
          role: 'Creator',
          profilePath: map['profile_path'] as String?,
          order: order++,
        );
      }
    }
    if (crew != null) {
      for (final raw in crew) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final job = (map['job'] as String?)?.trim() ?? '';
        if (job != 'Director') continue;
        addPerson(
          name: map['name'] as String? ?? '',
          role: 'Director',
          profilePath: map['profile_path'] as String?,
          order: order++,
        );
        if (order >= -14) break; // at most a few directors
      }
    }

    if (cast != null) {
      for (final entry in cast.take(20)) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        addPerson(
          name: map['name'] as String? ?? '',
          role: map['character'] as String?,
          profilePath: map['profile_path'] as String?,
          order: (map['order'] as num?)?.toInt() ?? out.length,
        );
      }
    }
    return out;
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  String? _firstNamed(List raw) {
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = (entry['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  String? _preferCountry(String? language) {
    if (language == null || language.isEmpty) return 'US';
    final parts = language.split(RegExp(r'[-_]'));
    if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
      return parts[1].trim().toUpperCase();
    }
    return 'US';
  }

  String? _movieCertification(Map<String, dynamic> map, String? language) {
    final releaseDates = map['release_dates'] as Map? ?? const {};
    final results = releaseDates['results'] as List? ?? const [];
    final prefer = _preferCountry(language);
    String? fallback;
    for (final pass in [prefer, 'US', null]) {
      for (final raw in results) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final country = (entry['iso_3166_1'] as String?)?.toUpperCase();
        if (pass != null && country != pass) continue;
        final dates = entry['release_dates'] as List? ?? const [];
        for (final d in dates) {
          if (d is! Map) continue;
          final cert = (d['certification'] as String?)?.trim();
          if (cert == null || cert.isEmpty) continue;
          if (pass != null) return cert;
          fallback ??= cert;
        }
      }
      if (pass == null) return fallback;
    }
    return fallback;
  }

  String? _tvContentRating(Map<String, dynamic> map, String? language) {
    final ratings = map['content_ratings'] as Map? ?? const {};
    final results = ratings['results'] as List? ?? const [];
    final prefer = _preferCountry(language);
    String? fallback;
    for (final pass in [prefer, 'US', null]) {
      for (final raw in results) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final country = (entry['iso_3166_1'] as String?)?.toUpperCase();
        if (pass != null && country != pass) continue;
        final rating = (entry['rating'] as String?)?.trim();
        if (rating == null || rating.isEmpty) continue;
        if (pass != null) return rating;
        fallback ??= rating;
      }
      if (pass == null) return fallback;
    }
    return fallback;
  }

  String? _pickTrailerKey(List? results) {
    if (results == null) return null;
    Map<String, dynamic>? best;
    for (final raw in results) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      if (map['site'] != 'YouTube') continue;
      final type = map['type'] as String? ?? '';
      if (type != 'Trailer' && type != 'Teaser') continue;
      best ??= map;
      if (type == 'Trailer' && map['official'] == true)
        return map['key'] as String?;
      if (type == 'Trailer') best = map;
    }
    return best?['key'] as String?;
  }

  void close() => _http.close();
}

class TmdbSearchHit {
  const TmdbSearchHit({
    required this.id,
    required this.title,
    required this.mediaType,
    this.year,
    this.posterUrl,
    this.overview,
  });

  final int id;
  final String title;
  final String mediaType;
  final int? year;
  final String? posterUrl;
  final String? overview;
}

/// One episode from [TmdbClient.fetchTvSeason] (stills / plot only).
class TmdbSeasonEpisode {
  const TmdbSeasonEpisode({
    required this.episodeNumber,
    required this.seasonNumber,
    this.title,
    this.plot,
    this.thumbnailUrl,
    this.duration,
    this.airDate,
    this.tmdbId,
  });

  final int episodeNumber;
  final int seasonNumber;
  final String? title;
  final String? plot;
  final String? thumbnailUrl;
  final Duration? duration;
  final DateTime? airDate;
  final int? tmdbId;
}

/// Franchise collection from [TmdbClient.fetchCollection].
class TmdbCollectionInfo {
  const TmdbCollectionInfo({
    required this.id,
    required this.name,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.parts = const [],
  });

  final int id;
  final String name;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final List<TmdbCollectionPart> parts;
}

class TmdbCollectionPart {
  const TmdbCollectionPart({
    required this.tmdbId,
    required this.title,
    this.year,
    this.posterUrl,
    this.overview,
  });

  final int tmdbId;
  final String title;
  final int? year;
  final String? posterUrl;
  final String? overview;
}
