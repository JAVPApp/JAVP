import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/services/metadata/metadata_match.dart';
import 'package:javp/services/metadata/metadata_provider.dart';
import 'package:javp/services/tmdb/tmdb_client.dart';

/// TMDB-backed enricher — requires a BYO API key.
class TmdbEnricher implements MetadataEnricher {
  TmdbEnricher(this._client, {required TmdbCredentials Function() credentials})
    : _credentials = credentials;

  final TmdbClient _client;
  final TmdbCredentials Function() _credentials;

  @override
  MetadataProviderId get id => MetadataProviderId.tmdb;

  @override
  bool get isAvailable => _credentials().isConfigured;

  static String languageTag() => MetadataMatch.languageTag();

  @override
  Future<List<MetadataSearchHit>> search(String query, {String? type}) async {
    final creds = _credentials();
    if (!creds.isConfigured || query.trim().isEmpty) return const [];
    final hits = await _client.search(
      creds,
      query: query,
      type: type,
      language: languageTag(),
    );
    return [
      for (final h in hits)
        MetadataSearchHit(
          id: '${h.id}',
          title: h.title,
          mediaType: h.mediaType,
          year: h.year,
          posterUrl: h.posterUrl,
          overview: h.overview,
        ),
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
    final language = languageTag();

    final forceTmdbId = forceExternalId == null
        ? null
        : int.tryParse(forceExternalId);
    if (forceTmdbId != null) {
      if (forceType == 'tv' || item.isSeries) {
        return _client.fetchTv(
          creds,
          forceTmdbId,
          mediaItemId: item.id,
          language: language,
        );
      }
      return _client.fetchMovie(
        creds,
        forceTmdbId,
        mediaItemId: item.id,
        language: language,
      );
    }

    if (item.tmdbId != null) {
      if (item.isSeries || item.seasonNumber != null) {
        return _client.fetchTv(
          creds,
          item.tmdbId!,
          mediaItemId: item.id,
          language: language,
        );
      }
      final movie = await _client.fetchMovie(
        creds,
        item.tmdbId!,
        mediaItemId: item.id,
        language: language,
      );
      if (movie != null) return movie;
      return _client.fetchTv(
        creds,
        item.tmdbId!,
        mediaItemId: item.id,
        language: language,
      );
    }

    // Prefer exact IMDb / TVDB → TMDB id before fuzzy title search.
    final externalHit = await _client.findByExternalId(
      creds,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
      language: language,
    );
    if (externalHit != null) {
      return _fetchHit(creds, item, externalHit, language: language);
    }

    final query = MetadataMatch.cleanTitle(item.title);
    if (query.isEmpty) return null;
    final year = MetadataMatch.guessYear(item);
    final preferTv =
        forceType == 'tv' ||
        item.isSeries ||
        MetadataMatch.looksLikeAnime(item);

    var hits = await _searchWithFallback(
      creds,
      query: query,
      type: preferTv ? 'tv' : (forceType ?? 'movie'),
      year: year,
      language: language,
    );
    if (hits.isEmpty) {
      hits = await _searchWithFallback(
        creds,
        query: query,
        type: preferTv ? 'movie' : 'tv',
        year: year,
        language: language,
      );
    }
    final original = item.originalTitle?.trim();
    if (hits.isEmpty &&
        original != null &&
        original.isNotEmpty &&
        original.toLowerCase() != query.toLowerCase()) {
      hits = await _searchWithFallback(
        creds,
        query: original,
        type: preferTv ? 'tv' : (forceType ?? 'movie'),
        year: year,
        language: language,
      );
      if (hits.isEmpty) {
        hits = await _searchWithFallback(
          creds,
          query: original,
          type: preferTv ? 'movie' : 'tv',
          year: year,
          language: language,
        );
      }
    }
    if (hits.isEmpty) return null;

    final hit = _bestHit(hits, query, originalTitle: original);
    return _fetchHit(creds, item, hit, language: language);
  }

  Future<MediaDetails?> _fetchHit(
    TmdbCredentials creds,
    MediaItem item,
    TmdbSearchHit hit, {
    required String language,
  }) {
    return hit.mediaType == 'tv'
        ? _client.fetchTv(
            creds,
            hit.id,
            mediaItemId: item.id,
            language: language,
          )
        : _client.fetchMovie(
            creds,
            hit.id,
            mediaItemId: item.id,
            language: language,
          );
  }

  Future<List<TmdbSearchHit>> _searchWithFallback(
    TmdbCredentials creds, {
    required String query,
    required String type,
    int? year,
    String? language,
  }) async {
    var hits = await _client.search(
      creds,
      query: query,
      type: type,
      year: year,
      language: language,
    );
    if (hits.isEmpty && year != null) {
      hits = await _client.search(
        creds,
        query: query,
        type: type,
        language: language,
      );
    }
    return hits;
  }

  static TmdbSearchHit _bestHit(
    List<TmdbSearchHit> hits,
    String query, {
    String? originalTitle,
  }) {
    if (hits.length == 1) return hits.first;
    final needles = <String>{
      _foldTitle(query),
      if (originalTitle != null) _foldTitle(originalTitle),
    }..removeWhere((s) => s.isEmpty);
    for (final needle in needles) {
      for (final hit in hits) {
        if (_foldTitle(hit.title) == needle) return hit;
      }
    }
    return hits.first;
  }

  static String _foldTitle(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u3040-\u30ff\u4e00-\u9fff]+'), '')
      .trim();

  /// Backward-compatible alias used by older call sites.
  static MediaItem mergeOntoItem(MediaItem item, MediaDetails details) =>
      MetadataMatch.mergeOntoItem(item, details);
}
