import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/services/simkl/simkl_match.dart';
import 'package:javp/services/tmdb/tmdb_client.dart';
import 'package:javp/services/tmdb/tmdb_enricher.dart';

/// TMDB Popular / Trending lists intersected with on-device VOD.
///
/// Optional enrichment only — fails soft when the key is missing. Matching
/// prefers [SimklIds.tmdb], then the same title/year fuzzy path already used
/// by tracker / For You remote enrich.
class TmdbLocalDiscovery {
  TmdbLocalDiscovery({
    TmdbClient? tmdbClient,
    this.cacheTtl = const Duration(hours: 6),
    this.maxHitsPerList = 40,
  }) : _tmdb = tmdbClient ?? TmdbClient();

  final TmdbClient _tmdb;
  final Duration cacheTtl;
  final int maxHitsPerList;

  final Map<String, _CachedLists> _cache = {};

  /// Fetch trending + popular TMDB hits (cached).
  Future<({List<TmdbSearchHit> trending, List<TmdbSearchHit> popular})>
      fetchLists(TmdbCredentials creds) async {
    if (!creds.isConfigured) {
      return (trending: const <TmdbSearchHit>[], popular: const <TmdbSearchHit>[]);
    }
    final language = TmdbEnricher.languageTag();
    final key = Object.hash(creds.apiKey.trim(), language).toString();
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < cacheTtl) {
      return (trending: cached.trending, popular: cached.popular);
    }

    List<TmdbSearchHit> trending = const [];
    List<TmdbSearchHit> popularMovies = const [];
    List<TmdbSearchHit> popularTv = const [];
    try {
      trending = await _tmdb.trending(
        creds,
        mediaType: 'all',
        timeWindow: 'week',
        language: language,
      );
    } catch (_) {}
    try {
      popularMovies = await _tmdb.popularMovies(creds, language: language);
    } catch (_) {}
    try {
      popularTv = await _tmdb.popularTv(creds, language: language);
    } catch (_) {}

    final popular = _dedupeHits([
      ...popularMovies.take(maxHitsPerList),
      ...popularTv.take(maxHitsPerList),
    ]).take(maxHitsPerList).toList(growable: false);
    final trendingDeduped =
        _dedupeHits(trending).take(maxHitsPerList).toList(growable: false);

    _cache[key] = _CachedLists(
      trending: trendingDeduped,
      popular: popular,
      at: DateTime.now(),
    );
    if (_cache.length > 6) {
      final oldest = _cache.entries.toList()
        ..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in oldest.take(_cache.length - 4)) {
        _cache.remove(e.key);
      }
    }
    return (trending: trendingDeduped, popular: popular);
  }

  void clearCache() => _cache.clear();

  /// Map TMDB hits → local catalog rows, preserving remote rank order.
  static List<MediaItem> matchHits({
    required List<TmdbSearchHit> hits,
    required SimklMatchIndex index,
    int limit = 18,
    bool Function(MediaItem item)? accept,
  }) {
    if (hits.isEmpty || limit < 1) return const [];
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final hit in hits) {
      if (out.length >= limit) break;
      final matched = index.match(
        SimklIds(tmdb: hit.id),
        title: hit.title,
        year: hit.year,
      );
      if (matched == null) continue;
      if (matched.isLive ||
          matched.kind == MediaKind.catchup ||
          matched.isEpisode) {
        continue;
      }
      if (accept != null && !accept(matched)) continue;
      // Soft prefer series shells when TMDB says TV.
      if (hit.mediaType == 'tv' && !matched.isSeries && matched.tmdbId == hit.id) {
        // Keep — catalog may only have a movie row under the same id.
      }
      final key = matched.tmdbId != null && matched.tmdbId! > 0
          ? 'tmdb:${matched.tmdbId}'
          : '${matched.id}:${matched.title.toLowerCase()}';
      if (!seen.add(key)) continue;
      out.add(matched);
    }
    return out;
  }

  static List<TmdbSearchHit> _dedupeHits(Iterable<TmdbSearchHit> hits) {
    final seen = <int>{};
    final out = <TmdbSearchHit>[];
    for (final h in hits) {
      if (!seen.add(h.id)) continue;
      out.add(h);
    }
    return out;
  }
}

class _CachedLists {
  _CachedLists({
    required this.trending,
    required this.popular,
    required this.at,
  });

  final List<TmdbSearchHit> trending;
  final List<TmdbSearchHit> popular;
  final DateTime at;
}
