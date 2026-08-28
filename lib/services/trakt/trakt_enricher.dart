import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/metadata/episode_art_overlay.dart';
import 'package:javp/services/metadata/metadata_match.dart';
import 'package:javp/services/metadata/metadata_provider.dart';
import 'package:javp/services/trakt/trakt_client.dart';

/// Trakt-backed enricher — needs a client id (bundled via dart-define or custom).
class TraktEnricher implements MetadataEnricher {
  TraktEnricher(
    this._client, {
    required TraktCredentials Function() credentials,
  }) : _credentials = credentials;

  final TraktClient _client;
  final TraktCredentials Function() _credentials;

  @override
  MetadataProviderId get id => MetadataProviderId.trakt;

  @override
  bool get isAvailable => _credentials().isConfigured;

  @override
  Future<List<MetadataSearchHit>> search(String query, {String? type}) async {
    final creds = _credentials();
    if (!creds.isConfigured || query.trim().isEmpty) return const [];
    final prefer = type == 'tv' || type == 'show' ? 'show' : 'movie';
    final raw = await _client.search(creds, query: query, type: prefer);
    return [
      for (final entry in raw)
        if (_hitFromSearch(entry) != null) _hitFromSearch(entry)!,
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

    final preferTv = forceType == 'tv' || forceType == 'show' || item.isSeries;

    if (forceExternalId != null && forceExternalId.isNotEmpty) {
      return _fetchByTraktId(
        creds,
        forceExternalId,
        tv: preferTv,
        mediaItemId: item.id,
      );
    }

    if (item.tmdbId != null) {
      final hits = await _client.searchById(
        creds,
        idType: 'tmdb',
        id: '${item.tmdbId}',
        type: preferTv ? 'show' : 'movie',
      );
      final details = await _detailsFromSearchHits(
        creds,
        hits,
        preferTv: preferTv,
        mediaItemId: item.id,
      );
      if (details != null) return details;
    }

    if (item.imdbId != null && item.imdbId!.isNotEmpty) {
      final hits = await _client.searchById(
        creds,
        idType: 'imdb',
        id: item.imdbId!,
      );
      final details = await _detailsFromSearchHits(
        creds,
        hits,
        preferTv: preferTv,
        mediaItemId: item.id,
      );
      if (details != null) return details;
    }

    final query = MetadataMatch.cleanTitle(item.title);
    if (query.isEmpty) return null;
    final year = MetadataMatch.guessYear(item);
    final types = preferTv
        ? <String>['show', 'movie']
        : <String>['movie', 'show'];

    for (final type in types) {
      final hits = await _client.search(creds, query: query, type: type);
      if (hits.isEmpty) continue;
      Map<String, dynamic>? best;
      for (final entry in hits) {
        final media = _mediaObject(entry);
        if (media == null) continue;
        final y = (media['year'] as num?)?.toInt();
        if (year != null && y != null && y != year) continue;
        best = entry;
        break;
      }
      best ??= hits.first;
      final details = await _detailsFromSearchHits(
        creds,
        [best],
        preferTv: type == 'show',
        mediaItemId: item.id,
      );
      if (details != null) return details;
    }
    return null;
  }

  Future<MediaDetails?> _detailsFromSearchHits(
    TraktCredentials creds,
    List<Map<String, dynamic>> hits, {
    required bool preferTv,
    String? mediaItemId,
  }) async {
    for (final entry in hits) {
      final type = (entry['type'] as String?) ?? (preferTv ? 'show' : 'movie');
      final media = _mediaObject(entry);
      if (media == null) continue;
      final ids = media['ids'] is Map
          ? Map<String, dynamic>.from(media['ids'] as Map)
          : const <String, dynamic>{};
      final traktId = _idString(ids['trakt'] ?? ids['slug']);
      if (traktId == null) continue;
      // Prefer summary endpoint for freshest extended=full payload.
      final isShow = type == 'show' || type == 'episode';
      final summary = isShow
          ? await _client.fetchShow(creds, traktId)
          : await _client.fetchMovie(creds, traktId);
      Map<String, dynamic>? people;
      if (summary != null) {
        try {
          people = await _client.fetchPeople(creds, traktId, show: isShow);
        } catch (_) {}
        return mapDetails(
          summary,
          kind: isShow ? 'show' : 'movie',
          mediaItemId: mediaItemId,
          people: people,
        );
      }
      // Fall back to embedded search object.
      return mapDetails(
        media,
        kind: isShow ? 'show' : 'movie',
        mediaItemId: mediaItemId,
      );
    }
    return null;
  }

  Future<MediaDetails?> _fetchByTraktId(
    TraktCredentials creds,
    String id, {
    required bool tv,
    String? mediaItemId,
  }) async {
    if (tv) {
      final show = await _client.fetchShow(creds, id);
      if (show != null) {
        Map<String, dynamic>? people;
        try {
          people = await _client.fetchPeople(creds, id, show: true);
        } catch (_) {}
        return mapDetails(
          show,
          kind: 'show',
          mediaItemId: mediaItemId,
          people: people,
        );
      }
    }
    final movie = await _client.fetchMovie(creds, id);
    if (movie != null) {
      Map<String, dynamic>? people;
      try {
        people = await _client.fetchPeople(creds, id, show: false);
      } catch (_) {}
      return mapDetails(
        movie,
        kind: 'movie',
        mediaItemId: mediaItemId,
        people: people,
      );
    }
    if (!tv) {
      final show = await _client.fetchShow(creds, id);
      if (show != null) {
        Map<String, dynamic>? people;
        try {
          people = await _client.fetchPeople(creds, id, show: true);
        } catch (_) {}
        return mapDetails(
          show,
          kind: 'show',
          mediaItemId: mediaItemId,
          people: people,
        );
      }
    }
    return null;
  }

  /// Episode stills / titles / plots for overlay onto catalog rows.
  Future<List<SeasonEpisodeArt>> fetchEpisodeArt(
    String traktId, {
    required int seasonNumber,
  }) async {
    final creds = _credentials();
    if (!creds.isConfigured || traktId.trim().isEmpty) return const [];
    final raw = await _client.fetchSeasonEpisodes(
      creds,
      traktId,
      seasonNumber: seasonNumber,
    );
    return mapEpisodes(raw, seasonNumber: seasonNumber);
  }

  static MediaDetails mapDetails(
    Map<String, dynamic> map, {
    required String kind,
    String? mediaItemId,
    Map<String, dynamic>? people,
  }) {
    final ids = map['ids'] is Map
        ? Map<String, dynamic>.from(map['ids'] as Map)
        : const <String, dynamic>{};
    final traktId = _idString(ids['trakt'] ?? ids['slug']);
    final genres =
        (map['genres'] as List?)
            ?.map((g) => '$g'.trim())
            .where((g) => g.isNotEmpty)
            .toList() ??
        const <String>[];
    final images = map['images'] is Map
        ? Map<String, dynamic>.from(map['images'] as Map)
        : null;
    final runtimeMin = (map['runtime'] as num?)?.toInt();
    final released =
        (map['released'] as String?) ?? (map['first_aired'] as String?) ?? '';
    final trailer = (map['trailer'] as String?)?.trim();

    return MediaDetails(
      id: 'trakt-$kind-${traktId ?? mediaItemId ?? 'unknown'}',
      title: (map['title'] as String?)?.trim() ?? '',
      mediaItemId: mediaItemId,
      traktId: traktId,
      tmdbId: _idInt(ids['tmdb']),
      imdbId: _idString(ids['imdb']),
      tvdbId: _idInt(ids['tvdb']),
      plot: (map['overview'] as String?)?.trim(),
      posterUrl: _imageUrl(images, 'poster'),
      backdropUrl: _imageUrl(images, 'fanart') ?? _imageUrl(images, 'thumb'),
      genres: genres,
      rating: (map['rating'] as num?)?.toDouble(),
      year: (map['year'] as num?)?.toInt(),
      runtime: runtimeMin == null ? null : Duration(minutes: runtimeMin),
      cast: _mapPeople(people),
      trailerUrl: trailer,
      trailerKey: _youtubeKey(trailer),
      contentRating: (map['certification'] as String?)?.trim(),
      studio: (map['network'] as String?)?.trim(),
      originalTitle: (map['original_title'] as String?)?.trim(),
      releaseDate: released.isEmpty ? null : released,
      updatedAt: DateTime.now(),
    );
  }

  static List<SeasonEpisodeArt> mapEpisodes(
    List<Map<String, dynamic>> raw, {
    required int seasonNumber,
  }) {
    final out = <SeasonEpisodeArt>[];
    for (final map in raw) {
      final epNum =
          (map['number'] as num?)?.toInt() ?? (map['episode'] as num?)?.toInt();
      if (epNum == null || epNum <= 0) continue;
      final season = (map['season'] as num?)?.toInt() ?? seasonNumber;
      if (season <= 0) continue;
      final images = map['images'] is Map
          ? Map<String, dynamic>.from(map['images'] as Map)
          : null;
      final runtimeMin = (map['runtime'] as num?)?.toInt();
      out.add(
        SeasonEpisodeArt(
          episodeNumber: epNum,
          seasonNumber: season,
          title: (map['title'] as String?)?.trim(),
          plot: (map['overview'] as String?)?.trim(),
          thumbnailUrl:
              _imageUrl(images, 'screenshot') ?? _imageUrl(images, 'thumb'),
          duration: runtimeMin == null || runtimeMin <= 0
              ? null
              : Duration(minutes: runtimeMin),
        ),
      );
    }
    return out;
  }

  MetadataSearchHit? _hitFromSearch(Map<String, dynamic> entry) {
    final type = (entry['type'] as String?) ?? 'movie';
    final media = _mediaObject(entry);
    if (media == null) return null;
    final title = (media['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return null;
    final ids = media['ids'] is Map
        ? Map<String, dynamic>.from(media['ids'] as Map)
        : const <String, dynamic>{};
    final id = _idString(ids['trakt'] ?? ids['slug']);
    if (id == null) return null;
    final images = media['images'] is Map
        ? Map<String, dynamic>.from(media['images'] as Map)
        : null;
    return MetadataSearchHit(
      id: id,
      title: title,
      mediaType: type == 'show' ? 'tv' : 'movie',
      year: (media['year'] as num?)?.toInt(),
      posterUrl: _imageUrl(images, 'poster'),
      overview: (media['overview'] as String?)?.trim(),
    );
  }

  static Map<String, dynamic>? _mediaObject(Map<String, dynamic> entry) {
    for (final key in ['movie', 'show', 'episode']) {
      final v = entry[key];
      if (v is Map) return Map<String, dynamic>.from(v);
    }
    if (entry.containsKey('title') && entry.containsKey('ids')) return entry;
    return null;
  }

  static String? _imageUrl(Map<String, dynamic>? images, String key) {
    if (images == null) return null;
    final list = images[key];
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    if (first is String && first.isNotEmpty) {
      return first.startsWith('http') ? first : 'https://$first';
    }
    if (first is Map) {
      final url = first['url'] ?? first['full'] ?? first['thumb'];
      if (url is String && url.isNotEmpty) {
        return url.startsWith('http') ? url : 'https://$url';
      }
    }
    return null;
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
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final v = uri.queryParameters['v']?.trim();
    if (v != null && v.isNotEmpty) return v;
    if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last.trim();
    }
    return null;
  }

  static List<CastMember> _mapPeople(Map<String, dynamic>? people) {
    if (people == null) return const [];
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

    String? personName(Map<String, dynamic> entry) {
      final person = entry['person'] is Map
          ? Map<String, dynamic>.from(entry['person'] as Map)
          : entry;
      return (person['name'] as String?)?.trim();
    }

    String? personPhoto(Map<String, dynamic> entry) {
      final person = entry['person'] is Map
          ? Map<String, dynamic>.from(entry['person'] as Map)
          : entry;
      final images = person['images'] is Map
          ? Map<String, dynamic>.from(person['images'] as Map)
          : null;
      return _imageUrl(images, 'headshot') ?? _imageUrl(images, 'avatar');
    }

    var order = -20;
    final crew = people['crew'] is Map
        ? Map<String, dynamic>.from(people['crew'] as Map)
        : const <String, dynamic>{};
    for (final dept in ['created by', 'directing']) {
      final list = crew[dept];
      if (list is! List) continue;
      for (final raw in list.take(4)) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final name = personName(entry);
        if (name == null) continue;
        final jobs = entry['jobs'];
        final job = jobs is List && jobs.isNotEmpty
            ? '${jobs.first}'
            : (dept == 'created by' ? 'Creator' : 'Director');
        add(
          name: name,
          role: job,
          profileUrl: personPhoto(entry),
          order: order++,
        );
      }
    }

    final cast = people['cast'];
    if (cast is List) {
      var i = 0;
      for (final raw in cast.take(20)) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);
        final name = personName(entry);
        if (name == null) continue;
        final chars = entry['characters'];
        final role = chars is List && chars.isNotEmpty
            ? '${chars.first}'
            : entry['character'] as String?;
        add(name: name, role: role, profileUrl: personPhoto(entry), order: i++);
      }
    }
    return out;
  }
}
