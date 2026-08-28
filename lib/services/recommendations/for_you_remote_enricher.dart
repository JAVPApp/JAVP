import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/recommendations/local_recommender.dart';
import 'package:javp/services/simkl/simkl_client.dart';
import 'package:javp/services/simkl/simkl_match.dart';
import 'package:javp/services/tmdb/tmdb_client.dart';
import 'package:javp/services/trakt/trakt_client.dart';

/// Cloud enrichment for Home "For you" — TMDB / SIMKL / Trakt → catalog boosts.
///
/// Local ranking stays authoritative; this only returns
/// [LocalRecommender.tasteIdentityKey] → score boosts for titles that already
/// exist in the catalog pool. Fail soft when keys/sessions are missing.
class ForYouRemoteEnricher {
  ForYouRemoteEnricher({
    TmdbClient? tmdbClient,
    SimklClient? simklClient,
    TraktClient? traktClient,
    this.cacheTtl = const Duration(hours: 6),
    this.maxSeeds = 5,
  })  : _tmdb = tmdbClient ?? TmdbClient(),
        _simkl = simklClient ?? SimklClient(),
        _trakt = traktClient ?? TraktClient();

  final TmdbClient _tmdb;
  final SimklClient _simkl;
  final TraktClient _trakt;
  final Duration cacheTtl;
  final int maxSeeds;

  static const tmdbBoost = 28.0;
  static const simklSimilarBoost = 26.0;
  static const simklPlanBoost = 20.0;
  static const traktRecBoost = 30.0;
  static const traktWatchlistBoost = 18.0;
  static const traktRelatedBoost = 24.0;

  final Map<String, _CachedBoosts> _cache = {};

  /// Collect boosts keyed by [LocalRecommender.tasteIdentityKey].
  Future<Map<String, double>> collectBoosts({
    required List<MediaItem> catalogPool,
    required List<MediaItem> history,
    required List<MediaItem> watchlist,
    List<MediaItem> simklWatching = const [],
    List<MediaItem> serializdWatching = const [],
    TmdbCredentials tmdb = const TmdbCredentials(),
    SimklCredentials simkl = const SimklCredentials(clientId: ''),
    TraktCredentials trakt = const TraktCredentials(),
  }) async {
    final seeds = _pickSeeds(
      history: history,
      watchlist: watchlist,
      simklWatching: simklWatching,
      serializdWatching: serializdWatching,
    );
    final fingerprint = _fingerprint(
      seeds: seeds,
      tmdb: tmdb,
      simkl: simkl,
      trakt: trakt,
    );
    final cached = _cache[fingerprint];
    if (cached != null &&
        DateTime.now().difference(cached.at) < cacheTtl) {
      return Map<String, double>.from(cached.boosts);
    }

    final index = SimklMatchIndex(catalogPool);
    final boosts = <String, double>{};

    void addHit(MediaItem? hit, double weight) {
      if (hit == null) return;
      if (hit.isLive || hit.kind == MediaKind.catchup || hit.isEpisode) return;
      final key = LocalRecommender.tasteIdentityKey(hit);
      final prev = boosts[key] ?? 0;
      if (weight > prev) boosts[key] = weight;
    }

    MediaItem? mapIds({
      int? tmdbId,
      String? simklId,
      String? imdb,
      int? tvdb,
      int? anilist,
      String? title,
      int? year,
      bool? preferSeries,
    }) {
      final hit = index.match(
        SimklIds(
          simkl: simklId,
          tmdb: tmdbId,
          imdb: imdb,
          tvdb: tvdb,
          anilist: anilist,
        ),
        title: title,
        year: year,
      );
      if (hit == null || preferSeries == null) return hit;
      // Soft preference when TMDB namespaces collide.
      if (preferSeries && !hit.isSeries && hit.tmdbId == tmdbId) {
        // Keep hit — catalog may only have the movie row.
      }
      return hit;
    }

    // --- TMDB similar + recommendations ---
    if (tmdb.isConfigured) {
      final tmdbSeeds = seeds
          .where((s) => s.tmdbId != null && s.tmdbId! > 0)
          .take(maxSeeds)
          .toList();
      for (final seed in tmdbSeeds) {
        final mediaType = seed.isSeries ? 'tv' : 'movie';
        final id = seed.tmdbId!;
        try {
          final similar = await _tmdb.similar(
            tmdb,
            tmdbId: id,
            mediaType: mediaType,
          );
          for (final h in similar.take(12)) {
            addHit(
              mapIds(
                tmdbId: h.id,
                title: h.title,
                year: h.year,
                preferSeries: h.mediaType == 'tv',
              ),
              tmdbBoost,
            );
          }
        } catch (_) {}
        try {
          final recs = await _tmdb.recommendations(
            tmdb,
            tmdbId: id,
            mediaType: mediaType,
          );
          for (final h in recs.take(12)) {
            addHit(
              mapIds(
                tmdbId: h.id,
                title: h.title,
                year: h.year,
                preferSeries: h.mediaType == 'tv',
              ),
              tmdbBoost * 0.95,
            );
          }
        } catch (_) {}
      }
    }

    // --- SIMKL similar (detail users_recommendations) + plan-to-watch ---
    if (simkl.isConfigured) {
      final simklSeeds = seeds
          .where((s) => (s.simklId ?? '').trim().isNotEmpty)
          .take(maxSeeds)
          .toList();
      for (final seed in simklSeeds) {
        final kind = seed.isSeries
            ? (seed.anilistId != null ? 'anime' : 'tv')
            : 'movie';
        try {
          final hits = await _simkl.fetchRelatedRecommendations(
            simkl,
            simklId: seed.simklId!.trim(),
            kind: kind,
          );
          for (final h in hits.take(12)) {
            addHit(
              mapIds(
                tmdbId: h.ids.tmdb,
                simklId: h.ids.simkl,
                imdb: h.ids.imdb,
                tvdb: h.ids.tvdb,
                anilist: h.ids.anilist,
                title: h.title,
                year: h.year,
                preferSeries: h.type != 'movie',
              ),
              simklSimilarBoost,
            );
          }
        } catch (_) {}
      }

      if (simkl.isAuthenticated) {
        try {
          final planned = await _simkl.getPlanToWatch(simkl);
          for (final row in planned.take(40)) {
            addHit(
              mapIds(
                tmdbId: row.ids.tmdb,
                simklId: row.ids.simkl,
                imdb: row.ids.imdb,
                tvdb: row.ids.tvdb,
                anilist: row.ids.anilist,
                title: row.title,
                year: row.year,
                preferSeries: row.isShow,
              ),
              simklPlanBoost,
            );
          }
        } catch (_) {}
      }
    }

    // --- Trakt recommendations / watchlist / related ---
    if (trakt.isAuthenticated) {
      try {
        final movieRecs =
            await _trakt.getMovieRecommendations(trakt, limit: 20);
        for (final h in movieRecs) {
          addHit(
            mapIds(
              tmdbId: h.tmdb,
              imdb: h.imdb,
              tvdb: h.tvdb,
              title: h.title,
              year: h.year,
              preferSeries: false,
            ),
            traktRecBoost,
          );
        }
      } catch (_) {}
      try {
        final showRecs = await _trakt.getShowRecommendations(trakt, limit: 20);
        for (final h in showRecs) {
          addHit(
            mapIds(
              tmdbId: h.tmdb,
              imdb: h.imdb,
              tvdb: h.tvdb,
              title: h.title,
              year: h.year,
              preferSeries: true,
            ),
            traktRecBoost,
          );
        }
      } catch (_) {}
      try {
        final wlMovies = await _trakt.getWatchlistMovies(trakt);
        for (final h in wlMovies.take(30)) {
          addHit(
            mapIds(
              tmdbId: h.tmdb,
              imdb: h.imdb,
              title: h.title,
              year: h.year,
              preferSeries: false,
            ),
            traktWatchlistBoost,
          );
        }
      } catch (_) {}
      try {
        final wlShows = await _trakt.getWatchlistShows(trakt);
        for (final h in wlShows.take(30)) {
          addHit(
            mapIds(
              tmdbId: h.tmdb,
              imdb: h.imdb,
              tvdb: h.tvdb,
              title: h.title,
              year: h.year,
              preferSeries: true,
            ),
            traktWatchlistBoost,
          );
        }
      } catch (_) {}
    } else if (trakt.isConfigured) {
      // Related works with client id only — still map via TMDB/IMDb ids.
      final relatedSeeds = seeds
          .where((s) => s.tmdbId != null && s.tmdbId! > 0)
          .take(maxSeeds)
          .toList();
      for (final seed in relatedSeeds) {
        final id = 'tmdb:${seed.tmdbId}';
        try {
          final related = seed.isSeries
              ? await _trakt.getRelatedShows(trakt, id, limit: 8)
              : await _trakt.getRelatedMovies(trakt, id, limit: 8);
          for (final h in related) {
            addHit(
              mapIds(
                tmdbId: h.tmdb,
                imdb: h.imdb,
                tvdb: h.tvdb,
                title: h.title,
                year: h.year,
                preferSeries: seed.isSeries,
              ),
              traktRelatedBoost,
            );
          }
        } catch (_) {}
      }
    }

    _cache[fingerprint] = _CachedBoosts(boosts: boosts, at: DateTime.now());
    // Cap cache entries so long-lived processes don't grow forever.
    if (_cache.length > 8) {
      final oldest = _cache.entries.toList()
        ..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in oldest.take(_cache.length - 6)) {
        _cache.remove(e.key);
      }
    }
    return Map<String, double>.from(boosts);
  }

  void clearCache() => _cache.clear();

  List<MediaItem> _pickSeeds({
    required List<MediaItem> history,
    required List<MediaItem> watchlist,
    required List<MediaItem> simklWatching,
    List<MediaItem> serializdWatching = const [],
  }) {
    final out = <MediaItem>[];
    final seen = <String>{};

    void take(Iterable<MediaItem> source, {int limit = 8}) {
      var n = 0;
      for (final item in source) {
        if (n >= limit) break;
        if (item.isLive || item.kind == MediaKind.catchup) continue;
        final hasId = (item.tmdbId != null && item.tmdbId! > 0) ||
            (item.simklId != null && item.simklId!.trim().isNotEmpty) ||
            (item.imdbId != null && item.imdbId!.trim().isNotEmpty);
        if (!hasId) continue;
        final key = LocalRecommender.tasteIdentityKey(item);
        if (!seen.add(key)) continue;
        out.add(item);
        n++;
      }
    }

    take(history, limit: maxSeeds + 2);
    take(watchlist, limit: 3);
    take(simklWatching, limit: 3);
    take(serializdWatching, limit: 3);
    return out.take(maxSeeds + 4).toList();
  }

  String _fingerprint({
    required List<MediaItem> seeds,
    required TmdbCredentials tmdb,
    required SimklCredentials simkl,
    required TraktCredentials trakt,
  }) {
    final seedPart = seeds
        .map(
          (s) =>
              '${s.tmdbId ?? ''}:${s.simklId ?? ''}:${s.isSeries ? 's' : 'm'}',
        )
        .join('|');
    return Object.hash(
      seedPart,
      tmdb.isConfigured,
      simkl.isAuthenticated,
      simkl.isConfigured,
      trakt.isAuthenticated,
      trakt.isConfigured,
    ).toString();
  }
}

class _CachedBoosts {
  _CachedBoosts({required this.boosts, required this.at});
  final Map<String, double> boosts;
  final DateTime at;
}
