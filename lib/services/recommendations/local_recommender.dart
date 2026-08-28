import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_grouping.dart';

/// Fully local "for you" ranking, optionally boosted by remote id hits.
///
/// Score uses recent watches, My List, shared groups/genres, optional
/// [remoteBoosts] from TMDB / SIMKL / Trakt (see [ForYouRemoteEnricher]), and
/// a light diversity pass so the shelf is not one category repeated.
///
/// Remote enrichers must map cloud ids back to catalog rows only; missing
/// keys / unlinked sessions fail soft and leave this path fully local.
class LocalRecommender {
  /// History tag: episode queued as Continue watching after the prior one
  /// finished (progress still 0 until the user actually starts it).
  static const continueUpNextTag = 'continue-up-next';

  /// Soft genres that only belong on For you when the user already watches
  /// them — otherwise a locale-ranked Xtream preview surfaces random bios.
  static const nicheTasteGenres = {
    'biography',
    'biographical',
    'biopic',
    'autobiography',
    'documentary',
    'docudrama',
  };

  /// Cap so same-origin IPTV history cannot swamp genre / group signals
  /// (66 same-origin watches ≈ 770 origin points vs genre clamp of 40).
  static const maxOriginScore = 12.0;

  /// Below this, a candidate with known taste data is not relevant enough.
  static const minTasteScore = 8.0;

  static bool isContinueUpNext(MediaItem item) =>
      item.tags.contains(continueUpNextTag);

  /// Whether [item] should appear on the Continue watching shelf.
  static bool isContinueWatchingCandidate(MediaItem item) {
    if (item.progress > 0.02 && item.progress < 0.95) return true;
    // Seeded next episode after finishing the previous one.
    return item.isEpisode && isContinueUpNext(item) && item.progress < 0.95;
  }

  /// Stable title identity for taste / finished exclusion (no library index).
  ///
  /// Prefer TMDB / AniList when known so EN| / FR| / multi-source siblings
  /// share one slot even before [LibraryProvider] variant collapse.
  static String tasteIdentityKey(MediaItem item) {
    if (item.isSeries) {
      if (item.anilistId != null && item.anilistId! > 0) {
        return 'al:${item.anilistId}';
      }
      if (item.tmdbId != null && item.tmdbId! > 0) {
        return 'tmdb-tv:${item.tmdbId}';
      }
      return 'series:${VodGrouping.normalizeTitle(item.title)}|${item.year ?? ''}';
    }
    final sid = item.seriesId?.trim();
    if (sid != null && sid.isNotEmpty) {
      return 'series-id:$sid';
    }
    if (!item.isEpisode) {
      final g = VodGrouping.groupKey(item);
      if (g != null) return 'vod:$g';
    }
    return 'id:${item.id}';
  }

  static String _normGenre(String raw) => raw.trim().toLowerCase();

  static bool _isNicheGenre(String genre) => nicheTasteGenres.contains(genre);

  List<MediaItem> recommend({
    required List<MediaItem> catalog,
    required List<MediaItem> history,
    List<MediaItem> watchlist = const [],
    Map<String, double> remoteBoosts = const {},
    int limit = 20,
  }) {
    if (catalog.isEmpty || limit <= 0) return const [];

    final recentGroups = <String, int>{};
    final recentOrigins = <MediaOrigin, int>{};
    final genreAffinity = <String, double>{};
    final watchedIds = <String>{};
    final finishedKeys = <String>{};
    final continueKeys = <String>{};
    final watchlistKeys = <String>{};

    void absorbGenres(MediaItem item, double weight) {
      for (final raw in item.genres) {
        final g = _normGenre(raw);
        if (g.isEmpty) continue;
        genreAffinity[g] = (genreAffinity[g] ?? 0) + weight;
      }
    }

    for (var i = 0; i < history.length; i++) {
      final item = history[i];
      watchedIds.add(item.id);
      final weight = (history.length - i).toDouble();
      final key = tasteIdentityKey(item);
      if (item.group != null) {
        recentGroups[item.group!] =
            (recentGroups[item.group!] ?? 0) + weight.round();
      }
      recentOrigins[item.origin] =
          (recentOrigins[item.origin] ?? 0) + weight.round();
      absorbGenres(item, weight);
      if (item.progress >= 0.95) {
        finishedKeys.add(key);
      } else if (isContinueWatchingCandidate(item)) {
        continueKeys.add(key);
      }
    }

    for (var i = 0; i < watchlist.length; i++) {
      final item = watchlist[i];
      final weight = (watchlist.length - i) * 0.55;
      watchlistKeys.add(tasteIdentityKey(item));
      if (item.group != null) {
        recentGroups[item.group!] =
            (recentGroups[item.group!] ?? 0) + weight.round();
      }
      absorbGenres(item, weight);
    }

    final hasTaste =
        genreAffinity.isNotEmpty ||
        recentGroups.isNotEmpty ||
        remoteBoosts.isNotEmpty ||
        watchlistKeys.isNotEmpty;

    final scored = <MapEntry<MediaItem, double>>[];
    for (final item in catalog) {
      final key = tasteIdentityKey(item);
      // Skip finished titles (by family), and soft-skip in-progress — those
      // already surface on Continue watching.
      if (finishedKeys.contains(key)) continue;
      if (continueKeys.contains(key) && !watchlistKeys.contains(key)) continue;

      var score = 0.0;
      var tasteHits = 0.0;
      if (item.progress > 0 && item.progress < 0.95) {
        score += 50 + (item.progress * 20);
        tasteHits += 50;
      }
      if (item.group != null && recentGroups.containsKey(item.group)) {
        final groupScore = recentGroups[item.group!]!.toDouble();
        score += groupScore;
        tasteHits += groupScore;
      }
      final originRaw = (recentOrigins[item.origin] ?? 0) * 0.35;
      score += originRaw.clamp(0, maxOriginScore);

      var genreHits = 0.0;
      var hasGenres = false;
      var nicheWithoutAffinity = false;
      for (final raw in item.genres) {
        final g = _normGenre(raw);
        if (g.isEmpty) continue;
        hasGenres = true;
        final affinity = genreAffinity[g];
        if (affinity != null) {
          genreHits += affinity;
        } else if (_isNicheGenre(g)) {
          nicheWithoutAffinity = true;
        }
      }
      if (genreHits > 0) {
        final clamped = genreHits.clamp(0, 40);
        score += clamped;
        tasteHits += clamped;
      } else if (genreAffinity.isNotEmpty && !hasGenres) {
        // Unenriched rows stay eligible but rank below genre matches.
        score -= 2;
      } else if (genreAffinity.isNotEmpty && hasGenres) {
        // Known genres with zero overlap are not "for you".
        score -= 18;
      }
      if (nicheWithoutAffinity && genreHits <= 0) {
        // Autobiography / documentary noise from locale-ranked VOD previews.
        score -= 35;
      }

      if (watchlistKeys.contains(key)) {
        score += 18;
        tasteHits += 18;
      }
      final remote = remoteBoosts[key];
      if (remote != null && remote > 0) {
        score += remote;
        tasteHits += remote;
      }
      if (item.tmdbId != null || item.anilistId != null) {
        score += 3;
      }
      if (item.posterUrl != null || item.thumbnailUrl != null) {
        score += 1.5;
      }

      if (item.lastWatchedAt != null) {
        final ageHours =
            DateTime.now().difference(item.lastWatchedAt!).inHours;
        score += (72 - ageHours).clamp(0, 72) * 0.4;
      }
      if (watchedIds.contains(item.id) && item.progress >= 0.95) {
        score -= 30;
      }
      // Mild boost for live content during typical evening hours.
      final hour = DateTime.now().hour;
      if (item.isLive && hour >= 18 && hour <= 23) score += 8;

      // When we know the user's taste, require a real signal — not locale /
      // same-origin fluff or an unrelated Biography/Documentary.
      if (hasTaste && tasteHits < 1) {
        if (nicheWithoutAffinity || hasGenres || score < minTasteScore) {
          continue;
        }
      }
      scored.add(MapEntry(item, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return _diversify(scored, limit: limit);
  }

  /// Prefer score order, but cap how many rows share a group / top genre.
  static List<MediaItem> _diversify(
    List<MapEntry<MediaItem, double>> scored, {
    required int limit,
  }) {
    final out = <MediaItem>[];
    final seenKeys = <String>{};
    final groupCounts = <String, int>{};
    final genreCounts = <String, int>{};
    final deferred = <MediaItem>[];

    bool underCaps(MediaItem item) {
      final group = item.group?.trim();
      if (group != null &&
          group.isNotEmpty &&
          (groupCounts[group] ?? 0) >= 3) {
        return false;
      }
      final top = _primaryGenre(item);
      if (top != null && (genreCounts[top] ?? 0) >= 4) {
        return false;
      }
      return true;
    }

    void take(MediaItem item) {
      final key = tasteIdentityKey(item);
      if (!seenKeys.add(key)) return;
      out.add(item);
      final group = item.group?.trim();
      if (group != null && group.isNotEmpty) {
        groupCounts[group] = (groupCounts[group] ?? 0) + 1;
      }
      final top = _primaryGenre(item);
      if (top != null) {
        genreCounts[top] = (genreCounts[top] ?? 0) + 1;
      }
    }

    for (final entry in scored) {
      if (out.length >= limit) break;
      final item = entry.key;
      if (seenKeys.contains(tasteIdentityKey(item))) continue;
      if (underCaps(item)) {
        take(item);
      } else {
        deferred.add(item);
      }
    }
    for (final item in deferred) {
      if (out.length >= limit) break;
      take(item);
    }
    return out;
  }

  static String? _primaryGenre(MediaItem item) {
    for (final raw in item.genres) {
      final g = _normGenre(raw);
      if (g.isNotEmpty) return g;
    }
    return null;
  }

  List<MediaItem> continueWatching(List<MediaItem> history, {int limit = 12}) {
    final items = history.where(isContinueWatchingCandidate).toList()
      ..sort((a, b) {
        final aTime = a.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

    // One row per series (most recently watched episode wins).
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final item in items) {
      if (!seen.add(continueWatchingKey(item))) continue;
      out.add(item);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Collapse key so multiple in-progress episodes of one show share a slot,
  /// and movie encodes (quality / language versions) share one slot too.
  ///
  /// Prefer seriesId / external ids so a history series shell without
  /// seriesId still collapses with its episode sibling when ids align.
  /// Movies without TMDB still collapse via [VodGrouping.groupKey]
  /// (title+year or same-source name) so switching versions does not
  /// degroup Continue watching.
  static String continueWatchingKey(MediaItem item) {
    if (item.anilistId != null && item.anilistId! > 0) {
      return 'al:${item.anilistId}';
    }
    if (item.simklId != null && item.simklId!.trim().isNotEmpty) {
      return 'simkl:${item.simklId!.trim()}';
    }
    if (item.isSeries || item.isEpisode) {
      if (item.tmdbId != null && item.tmdbId! > 0) {
        return 'tmdb:${item.tmdbId}';
      }
      final sid = item.seriesId?.trim();
      if (sid != null && sid.isNotEmpty) return 'series:$sid';
      final stream = item.streamId?.trim();
      if (stream != null && stream.isNotEmpty) {
        return 'stream:$stream';
      }
    } else if (!item.isLive && item.kind != MediaKind.catchup) {
      if (item.tmdbId != null && item.tmdbId! > 0) {
        return 'tmdb:${item.tmdbId}';
      }
      final g = VodGrouping.groupKey(item);
      if (g != null) return 'vod:$g';
    }
    return 'id:${item.id}';
  }
}
