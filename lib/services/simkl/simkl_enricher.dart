import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/metadata/episode_art_overlay.dart';
import 'package:javp/services/metadata/metadata_match.dart';
import 'package:javp/services/metadata/metadata_provider.dart';
import 'package:javp/services/simkl/simkl_client.dart';

/// SIMKL-backed enricher — works with the bundled client id (no login).
class SimklEnricher implements MetadataEnricher {
  SimklEnricher(
    this._client, {
    required SimklCredentials Function() credentials,
  }) : _credentials = credentials;

  final SimklClient _client;
  final SimklCredentials Function() _credentials;

  @override
  MetadataProviderId get id => MetadataProviderId.simkl;

  @override
  bool get isAvailable => _credentials().isConfigured;

  @override
  Future<List<MetadataSearchHit>> search(String query, {String? type}) async {
    final creds = _credentials();
    if (!creds.isConfigured || query.trim().isEmpty) return const [];
    final prefer = type ?? 'movie';
    final raw = await _client.search(creds, query: query, type: prefer);
    return [
      for (final map in raw)
        if (_hitFromSearch(map, prefer) != null) _hitFromSearch(map, prefer)!,
    ];
  }

  @override
  Future<MediaDetails?> enrich(
    MediaItem item, {
    String? forceType,
    String? forceExternalId,
  }) async {
    final creds = _credentials();
    if (!creds.isConfigured) return null;
    final language = MetadataMatch.languageCode();

    final preferAnime =
        forceType == 'anime' || MetadataMatch.looksLikeAnime(item);
    final preferTv =
        forceType == 'tv' || item.isSeries || item.seasonNumber != null;

    if (forceExternalId != null && forceExternalId.isNotEmpty) {
      return _fetchBySimklId(
        creds,
        forceExternalId,
        anime: preferAnime,
        tv: preferTv || preferAnime,
        mediaItemId: item.id,
        language: language,
      );
    }

    if (item.simklId != null && item.simklId!.isNotEmpty) {
      final hit = await _fetchBySimklId(
        creds,
        item.simklId!,
        anime: preferAnime,
        tv: preferTv || preferAnime,
        mediaItemId: item.id,
        language: language,
      );
      if (hit != null) return hit;
    }

    if (item.tmdbId != null ||
        (item.imdbId != null && item.imdbId!.isNotEmpty) ||
        item.tvdbId != null) {
      final byId = await _client.searchById(
        creds,
        tmdb: item.tmdbId,
        imdb: item.imdbId,
        tvdb: item.tvdbId,
        type: preferAnime
            ? 'anime'
            : preferTv
            ? 'tv'
            : 'movie',
      );
      final simklId = _simklIdFrom(byId);
      if (simklId != null) {
        final details = await _fetchBySimklId(
          creds,
          simklId,
          anime: preferAnime,
          tv: preferTv || preferAnime,
          mediaItemId: item.id,
          language: language,
        );
        if (details != null) return details;
      }
    }

    final query = MetadataMatch.cleanTitle(item.title);
    if (query.isEmpty) return null;

    final types = preferAnime
        ? <String>['anime', 'tv', 'movie']
        : preferTv
        ? <String>['tv', 'movie', 'anime']
        : <String>['movie', 'tv', 'anime'];

    for (final type in types) {
      final hits = await _client.search(creds, query: query, type: type);
      if (hits.isEmpty) continue;
      final year = MetadataMatch.guessYear(item);
      Map<String, dynamic> best = hits.first;
      if (year != null) {
        for (final h in hits) {
          final y = (h['year'] as num?)?.toInt();
          if (y == year) {
            best = h;
            break;
          }
        }
      }
      final simklId = _simklIdFrom(best);
      if (simklId == null) continue;
      final details = await _fetchBySimklId(
        creds,
        simklId,
        anime: type == 'anime',
        tv: type == 'tv' || type == 'anime',
        mediaItemId: item.id,
        language: language,
      );
      if (details != null) return details;
    }
    return null;
  }

  Future<MediaDetails?> _fetchBySimklId(
    SimklCredentials creds,
    String simklId, {
    required bool anime,
    required bool tv,
    String? mediaItemId,
    String? language,
  }) async {
    Map<String, dynamic>? raw;
    var kind = 'movie';
    if (anime) {
      raw = await _client.fetchAnime(creds, simklId, language: language);
      kind = 'anime';
    }
    if (raw == null && tv) {
      raw = await _client.fetchTv(creds, simklId, language: language);
      kind = 'tv';
    }
    if (raw == null) {
      raw = await _client.fetchMovie(creds, simklId, language: language);
      kind = 'movie';
    }
    if (raw == null && !tv) {
      raw = await _client.fetchTv(creds, simklId, language: language);
      kind = 'tv';
    }
    if (raw == null) {
      raw = await _client.fetchAnime(creds, simklId, language: language);
      kind = 'anime';
    }
    if (raw == null) return null;
    return mapDetails(raw, kind: kind, mediaItemId: mediaItemId);
  }

  /// Episode stills / titles / plots for overlay onto catalog rows.
  Future<List<SeasonEpisodeArt>> fetchEpisodeArt(
    String simklId, {
    required bool anime,
  }) async {
    final creds = _credentials();
    if (!creds.isConfigured || simklId.trim().isEmpty) return const [];
    final raw = await _client.fetchEpisodes(
      creds,
      simklId,
      anime: anime,
      language: MetadataMatch.languageCode(),
    );
    return mapEpisodes(raw);
  }

  static MediaDetails mapDetails(
    Map<String, dynamic> map, {
    required String kind,
    String? mediaItemId,
  }) {
    final ids = map['ids'] is Map
        ? Map<String, dynamic>.from(map['ids'] as Map)
        : const <String, dynamic>{};
    final simklId = _idString(
      ids['simkl'] ?? ids['simkl_id'] ?? map['simkl_id'],
    );
    final genres =
        (map['genres'] as List?)
            ?.map((g) => '$g'.trim())
            .where((g) => g.isNotEmpty)
            .toList() ??
        const <String>[];
    final ratings = map['ratings'];
    double? rating;
    if (ratings is Map) {
      final simkl = ratings['simkl'];
      if (simkl is Map && simkl['rating'] != null) {
        rating = (simkl['rating'] as num?)?.toDouble();
      }
      rating ??= (ratings['imdb'] is Map)
          ? ((ratings['imdb'] as Map)['rating'] as num?)?.toDouble()
          : null;
    }
    final trailer = map['trailer'];
    String? trailerUrl;
    String? trailerKey;
    if (trailer is String && trailer.isNotEmpty) {
      trailerUrl = trailer;
      trailerKey = _youtubeKey(trailer);
    } else if (trailer is Map) {
      trailerUrl = (trailer['url'] as String?)?.trim();
      trailerKey =
          _idString(trailer['youtube']) ??
          _idString(trailer['yt']) ??
          _youtubeKey(trailerUrl);
    }
    final trailers = map['trailers'];
    if (trailers is List) {
      for (final raw in trailers) {
        if (raw is! Map) continue;
        final yt = _idString(raw['youtube']) ?? _idString(raw['yt']);
        if (yt == null || yt.isEmpty) continue;
        trailerKey ??= yt;
        trailerUrl ??= 'https://www.youtube.com/watch?v=$yt';
        break;
      }
    }

    final released =
        (map['released'] as String?) ?? (map['first_aired'] as String?) ?? '';
    final runtimeMin = (map['runtime'] as num?)?.toInt();
    final year =
        (map['year'] as num?)?.toInt() ??
        (released.length >= 4 ? int.tryParse(released.substring(0, 4)) : null);

    return MediaDetails(
      id: 'simkl-$kind-${simklId ?? ids['slug'] ?? mediaItemId ?? 'unknown'}',
      title: (map['title'] as String?)?.trim() ?? '',
      mediaItemId: mediaItemId,
      simklId: simklId,
      tmdbId: _idInt(ids['tmdb']),
      imdbId: _idString(ids['imdb']),
      tvdbId: _idInt(ids['tvdb']),
      anilistId: _idInt(ids['anilist']),
      plot: (map['overview'] as String?)?.trim(),
      posterUrl: SimklClient.posterUrl(map['poster'] as String?),
      backdropUrl: SimklClient.fanartUrl(map['fanart'] as String?),
      genres: genres,
      rating: rating,
      year: year,
      runtime: runtimeMin == null ? null : Duration(minutes: runtimeMin),
      cast: _mapCast(map),
      trailerUrl: trailerUrl,
      trailerKey: trailerKey,
      contentRating: (map['certification'] as String?)?.trim(),
      studio:
          (map['network'] as String?)?.trim() ??
          (map['studio'] as String?)?.trim(),
      originalTitle:
          (map['title_en'] as String?)?.trim() ??
          (map['title_romaji'] as String?)?.trim(),
      releaseDate: released.isEmpty ? null : released,
      updatedAt: DateTime.now(),
    );
  }

  /// Map `GET /tv|anime/episodes/{id}` rows to overlay stills.
  static List<SeasonEpisodeArt> mapEpisodes(List<Map<String, dynamic>> raw) {
    final out = <SeasonEpisodeArt>[];
    for (final map in raw) {
      final type = '${map['type'] ?? ''}'.toLowerCase();
      if (type == 'special') continue;
      final epNum =
          (map['episode'] as num?)?.toInt() ??
          (map['episode_number'] as num?)?.toInt();
      if (epNum == null || epNum <= 0) continue;
      final seasonNum =
          (map['season'] as num?)?.toInt() ??
          (map['season_number'] as num?)?.toInt() ??
          1;
      if (seasonNum <= 0) continue;
      final runtimeMin = (map['runtime'] as num?)?.toInt();
      out.add(
        SeasonEpisodeArt(
          episodeNumber: epNum,
          seasonNumber: seasonNum,
          title: (map['title'] as String?)?.trim(),
          plot:
              (map['description'] as String?)?.trim() ??
              (map['overview'] as String?)?.trim(),
          thumbnailUrl: SimklClient.episodeStillUrl(map['img'] as String?),
          duration: runtimeMin == null || runtimeMin <= 0
              ? null
              : Duration(minutes: runtimeMin),
        ),
      );
    }
    return out;
  }

  MetadataSearchHit? _hitFromSearch(Map<String, dynamic> map, String type) {
    final title = (map['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return null;
    final ids = map['ids'] is Map
        ? Map<String, dynamic>.from(map['ids'] as Map)
        : const <String, dynamic>{};
    final simklId = _simklIdFrom(map) ?? _idString(ids['simkl']);
    if (simklId == null) return null;
    final endpoint = (map['endpoint_type'] as String?) ?? type;
    final mediaType = endpoint.contains('anime')
        ? 'anime'
        : endpoint.contains('tv') || endpoint.contains('show')
        ? 'tv'
        : 'movie';
    return MetadataSearchHit(
      id: simklId,
      title: title,
      mediaType: mediaType,
      year: (map['year'] as num?)?.toInt(),
      posterUrl: SimklClient.posterUrl(map['poster'] as String?),
      overview: (map['overview'] as String?)?.trim(),
    );
  }

  static String? _simklIdFrom(Map<String, dynamic>? map) {
    if (map == null) return null;
    final ids = map['ids'] is Map
        ? Map<String, dynamic>.from(map['ids'] as Map)
        : null;
    return _idString(
      ids?['simkl'] ?? ids?['simkl_id'] ?? map['simkl_id'] ?? map['simkl'],
    );
  }

  static String? _idString(dynamic v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static int? _idInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String? _youtubeKey(String? url) {
    final raw = url?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (!raw.contains('/') && !raw.contains('?') && raw.length <= 20) {
      return raw;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final v = uri.queryParameters['v']?.trim();
    if (v != null && v.isNotEmpty) return v;
    if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last.trim();
    }
    final embed = uri.pathSegments.indexOf('embed');
    if (embed >= 0 && embed + 1 < uri.pathSegments.length) {
      return uri.pathSegments[embed + 1].trim();
    }
    return null;
  }

  static List<CastMember> _mapCast(Map<String, dynamic> map) {
    final out = <CastMember>[];
    final seen = <String>{};

    void add({
      required String name,
      String? role,
      String? profileUrl,
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
          profileUrl: profileUrl,
          order: order,
        ),
      );
    }

    final director = (map['director'] as String?)?.trim();
    if (director != null && director.isNotEmpty) {
      add(name: director, role: 'Director', order: -20);
    }

    void addPeople(dynamic raw, {String? defaultRole, int startOrder = 0}) {
      if (raw is! List) return;
      var order = startOrder;
      for (final entry in raw.take(20)) {
        if (entry is String) {
          add(name: entry, role: defaultRole, order: order++);
          continue;
        }
        if (entry is! Map) continue;
        final person = entry['person'] is Map
            ? Map<String, dynamic>.from(entry['person'] as Map)
            : Map<String, dynamic>.from(entry);
        final name =
            (person['name'] as String?) ?? (entry['name'] as String?) ?? '';
        final role =
            (entry['character'] as String?) ??
            (entry['job'] as String?) ??
            defaultRole;
        final photo =
            person['poster'] as String? ??
            person['img'] as String? ??
            entry['poster'] as String?;
        add(
          name: name,
          role: role,
          profileUrl: SimklClient.posterUrl(photo, size: '_c'),
          order: (entry['order'] as num?)?.toInt() ?? order++,
        );
      }
    }

    addPeople(map['people'] ?? map['cast'], startOrder: 0);
    addPeople(map['crew'], defaultRole: 'Crew', startOrder: -10);
    return out;
  }
}
