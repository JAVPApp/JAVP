import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/recommendations/local_recommender.dart';
import 'package:javp/services/simkl/simkl_match.dart';

/// Compact per-title apply stats for diagnostics ([TrackerLog]).
class TrackerProgressApplySummary {
  const TrackerProgressApplySummary({
    required this.title,
    required this.idKey,
    this.marked = 0,
    this.watched,
    this.total,
    this.next,
    this.moviePlayhead = false,
    this.progress,
  });

  final String title;
  final String idKey;
  final int marked;
  final int? watched;
  final int? total;
  final String? next;
  final bool moviePlayhead;
  final double? progress;

  String toLogLine() {
    final parts = <String>['id=$idKey', 'title=${_compactTitle(title)}'];
    if (moviePlayhead) {
      final pct = progress == null ? null : (progress! * 100).round();
      parts.add(pct == null ? 'movie' : 'movie progress=$pct%');
    } else {
      if (watched != null) {
        parts.add(
          total != null && total! > 0
              ? 'watched=$watched/$total'
              : 'watched=$watched',
        );
      }
      if (next != null && next!.isNotEmpty) parts.add('next=$next');
      parts.add('marked=$marked');
    }
    return parts.join(' ');
  }

  static String _compactTitle(String title, {int max = 40}) {
    final t = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }
}

/// Result of applying remote tracker playheads onto local history.
class TrackerProgressMergeResult {
  const TrackerProgressMergeResult({
    required this.history,
    required this.catalog,
    required this.changed,
    this.applied = const [],
    this.episodesMarked = 0,
    this.moviesUpdated = 0,
  });

  final List<MediaItem> history;
  final List<MediaItem> catalog;
  final bool changed;

  /// Titles that actually mutated local history/catalog (summarized, not per-ep).
  final List<TrackerProgressApplySummary> applied;
  final int episodesMarked;
  final int moviesUpdated;
}

/// One local catalog / details episode used when marking watched from trackers.
class TrackerEpisodeRef {
  const TrackerEpisodeRef({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.playUrl = '',
  });

  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String playUrl;
}

/// Merge policy: apply remote playhead only when it is ahead of local by >0.5%.
///
/// For series, episode-count / next-to-watch / completed rows also mark local
/// episode history as watched (idempotent — never regresses higher local
/// progress). Match uses [SimklMatchIndex] so episode VOD rows are never chosen
/// as the series hit.
class TrackerProgressMerger {
  TrackerProgressMerger._();

  static const aheadEpsilon = 0.005;
  static const watchedThreshold = 0.95;

  /// Cap invented S/E stubs when the local episode list is unknown (sync path).
  /// Series open rematerializes from the real catalog list.
  static const maxInventedWatched = 40;

  static TrackerProgressMergeResult applyEntries({
    required List<TrackerStatusEntry> entries,
    required List<MediaItem> history,
    required List<MediaItem> catalog,
    required List<MediaItem> watchlist,
    Iterable<MediaItem> extra = const [],
    SimklMatchIndex? index,
  }) {
    final idx =
        index ??
        SimklMatchIndex([...catalog, ...history, ...watchlist, ...extra]);
    final historyById = {for (final h in history) h.id: h};
    final catalogUpdates = <String, MediaItem>{};
    final applied = <TrackerProgressApplySummary>[];
    var episodesMarked = 0;
    var moviesUpdated = 0;
    var changed = false;

    for (final entry in entries) {
      if (!_entryCarriesProgress(entry)) continue;

      final ids = SimklIds(
        simkl: entry.simklId,
        tmdb: entry.tmdbId,
        imdb: entry.imdbId,
        tvdb: entry.tvdbId,
        anilist: entry.anilistId,
      );
      final matched = idx.match(ids, title: entry.title, year: entry.year);
      if (matched == null || matched.isEpisode) continue;

      final completed = entry.status == TrackerStatusKind.completed;

      // Series: mark / seed episodes from counts / next / completed; avoid
      // treating episode-ratio % as a series playhead (that made CW open at
      // episode 1 with a fake "continue" bar).
      if (matched.isSeries && !entry.moviesOnly) {
        final seriesOutcome = _applySeriesProgress(
          series: matched,
          entry: entry,
          historyById: historyById,
          catalogUpdates: catalogUpdates,
          knownEpisodes: const [],
        );
        var marked = seriesOutcome.marked;
        if (seriesOutcome.changed) changed = true;

        // Playback mid-episode still updates that episode's playhead.
        if (!completed &&
            entry.seasonNumber != null &&
            entry.episodeNumber != null &&
            entry.progress != null &&
            entry.progress! > 0.02 &&
            entry.progress! < watchedThreshold) {
          final epTouched = _upsertEpisodeProgress(
            series: matched,
            seasonNumber: entry.seasonNumber!,
            episodeNumber: entry.episodeNumber!,
            progress: entry.progress!,
            entry: entry,
            historyById: historyById,
            catalogUpdates: catalogUpdates,
            episodeId: null,
            episodeTitle: null,
            playUrl: '',
            seedUpNext: false,
          );
          if (epTouched) {
            changed = true;
            marked++;
          }
        }
        if (seriesOutcome.changed || marked > seriesOutcome.marked) {
          episodesMarked += marked;
          applied.add(
            _summaryForEntry(
              entry,
              marked: marked,
              next: seriesOutcome.nextLabel,
            ),
          );
        }
        continue;
      }

      // Movies / non-series: classic playhead merge.
      final remote = entry.progress;
      if (!completed && (remote == null || remote <= 0.02 || remote >= 0.95)) {
        continue;
      }
      final want = completed ? 1.0 : remote!;
      if (!completed && want <= matched.progress + aheadEpsilon) continue;
      if (completed && matched.progress >= watchedThreshold) continue;

      final updated = matched.copyWith(
        progress: want,
        lastWatchedAt: entry.updatedAt ?? DateTime.now(),
        simklId: matched.simklId ?? entry.simklId,
        tmdbId: matched.tmdbId ?? entry.tmdbId,
        imdbId: matched.imdbId ?? entry.imdbId,
        tvdbId: matched.tvdbId ?? entry.tvdbId,
        anilistId: matched.anilistId ?? entry.anilistId,
      );
      historyById[updated.id] = updated;
      catalogUpdates[updated.id] = updated;
      changed = true;
      moviesUpdated++;
      applied.add(
        TrackerProgressApplySummary(
          title: entry.title,
          idKey: entry.identityKey,
          moviePlayhead: true,
          progress: want,
        ),
      );
    }

    return _finish(
      history,
      catalog,
      historyById,
      catalogUpdates,
      changed,
      applied: applied,
      episodesMarked: episodesMarked,
      moviesUpdated: moviesUpdated,
    );
  }

  /// Apply tracker watched flags onto a series' local episode list (open path).
  ///
  /// Prefer exact next-to-watch / watched-count over crude % when [episodes]
  /// are known. Idempotent vs higher local progress.
  static TrackerProgressMergeResult applySeriesEpisodes({
    required MediaItem series,
    required TrackerStatusEntry entry,
    required List<TrackerEpisodeRef> episodes,
    required List<MediaItem> history,
    List<MediaItem> catalog = const [],
  }) {
    if (series.isEpisode || episodes.isEmpty) {
      return TrackerProgressMergeResult(
        history: history,
        catalog: catalog,
        changed: false,
      );
    }
    if (!_entryCarriesProgress(entry) &&
        entry.status != TrackerStatusKind.completed) {
      return TrackerProgressMergeResult(
        history: history,
        catalog: catalog,
        changed: false,
      );
    }

    final historyById = {for (final h in history) h.id: h};
    final catalogUpdates = <String, MediaItem>{};
    final outcome = _applySeriesProgress(
      series: series,
      entry: entry,
      historyById: historyById,
      catalogUpdates: catalogUpdates,
      knownEpisodes: episodes,
    );
    final applied = outcome.changed
        ? [
            _summaryForEntry(
              entry,
              marked: outcome.marked,
              next: outcome.nextLabel,
            ),
          ]
        : const <TrackerProgressApplySummary>[];
    return _finish(
      history,
      catalog,
      historyById,
      catalogUpdates,
      outcome.changed,
      applied: applied,
      episodesMarked: outcome.marked,
    );
  }

  /// Same as [applyEntries] but builds the match index with frame yields when
  /// none is supplied — use from tracker Sync Now / import paths.
  static Future<TrackerProgressMergeResult> applyEntriesAsync({
    required List<TrackerStatusEntry> entries,
    required List<MediaItem> history,
    required List<MediaItem> catalog,
    required List<MediaItem> watchlist,
    Iterable<MediaItem> extra = const [],
    SimklMatchIndex? index,
  }) async {
    final idx =
        index ??
        await SimklMatchIndex.buildAsync([
          ...catalog,
          ...history,
          ...watchlist,
          ...extra,
        ]);
    await yieldAfterIsolateChunk();
    // Large status/playback merges still run on the UI isolate — yield once
    // more before the sync walk so Simkl Sync Now can paint the phase banner.
    if (entries.length > 24 || catalog.length > 4000) {
      await yieldAfterIsolateChunk();
    }
    return applyEntries(
      entries: entries,
      history: history,
      catalog: catalog,
      watchlist: watchlist,
      extra: extra,
      index: idx,
    );
  }

  static bool _entryCarriesProgress(TrackerStatusEntry entry) {
    if (entry.status == TrackerStatusKind.completed) return true;
    if (entry.status == TrackerStatusKind.dropped ||
        entry.status == TrackerStatusKind.hold ||
        entry.status == TrackerStatusKind.planToWatch ||
        entry.status == TrackerStatusKind.watchlist) {
      return false;
    }
    if (entry.watchedEpisodes != null && entry.watchedEpisodes! > 0) {
      return true;
    }
    if (entry.seasonNumber != null && entry.episodeNumber != null) {
      return true;
    }
    final p = entry.progress;
    return p != null && p > 0.02;
  }

  static ({bool changed, int marked, String? nextLabel}) _applySeriesProgress({
    required MediaItem series,
    required TrackerStatusEntry entry,
    required Map<String, MediaItem> historyById,
    required Map<String, MediaItem> catalogUpdates,
    required List<TrackerEpisodeRef> knownEpisodes,
  }) {
    var changed = false;
    var marked = 0;
    String? nextLabel;
    final completed = entry.status == TrackerStatusKind.completed;
    final watchedPairs = _resolveWatchedPairs(entry, knownEpisodes);
    final at = entry.updatedAt ?? DateTime.now();

    for (final pair in watchedPairs) {
      final sn = pair.$1;
      final en = pair.$2;
      final ref = _findRef(knownEpisodes, sn, en);
      final touched = _upsertEpisodeProgress(
        series: series,
        seasonNumber: sn,
        episodeNumber: en,
        progress: 1.0,
        entry: entry,
        historyById: historyById,
        catalogUpdates: catalogUpdates,
        episodeId: ref?.id,
        episodeTitle: ref?.title,
        playUrl: ref?.playUrl ?? '',
        seedUpNext: false,
        watchedAt: at,
      );
      if (touched) {
        changed = true;
        marked++;
      }
    }

    // Seed next-to-watch (or first unwatched after count) for Continue Watching.
    if (!completed) {
      final next = _resolveNextEpisode(entry, knownEpisodes, watchedPairs);
      if (next != null) {
        nextLabel = _formatSe(next.$1, next.$2);
        final ref = _findRef(knownEpisodes, next.$1, next.$2);
        final playhead =
            (entry.seasonNumber == next.$1 &&
                entry.episodeNumber == next.$2 &&
                entry.progress != null &&
                entry.progress! > 0.02 &&
                entry.progress! < watchedThreshold)
            ? entry.progress!
            : 0.0;
        final touched = _upsertEpisodeProgress(
          series: series,
          seasonNumber: next.$1,
          episodeNumber: next.$2,
          progress: playhead,
          entry: entry,
          historyById: historyById,
          catalogUpdates: catalogUpdates,
          episodeId: ref?.id,
          episodeTitle: ref?.title,
          playUrl: ref?.playUrl ?? '',
          seedUpNext: playhead <= 0.02,
          watchedAt: at,
        );
        if (touched) changed = true;
      }
    }

    // Keep series tile meta (N/M) without inventing a fake series playhead CW.
    final seriesProgress = completed
        ? 1.0
        : (entry.progress ??
              (entry.watchedEpisodes != null &&
                      entry.totalEpisodes != null &&
                      entry.totalEpisodes! > 0
                  ? (entry.watchedEpisodes! / entry.totalEpisodes!).clamp(
                      0.0,
                      1.0,
                    )
                  : null));
    if (seriesProgress != null &&
        seriesProgress > series.progress + aheadEpsilon) {
      final updated = series.copyWith(
        progress: seriesProgress,
        lastWatchedAt: at,
        simklId: series.simklId ?? entry.simklId,
        tmdbId: series.tmdbId ?? entry.tmdbId,
        imdbId: series.imdbId ?? entry.imdbId,
        tvdbId: series.tvdbId ?? entry.tvdbId,
        anilistId: series.anilistId ?? entry.anilistId,
      );
      catalogUpdates[updated.id] = updated;
      // Do not push series shells into history — CW uses episode rows.
      changed = true;
    }

    return (changed: changed, marked: marked, nextLabel: nextLabel);
  }

  static TrackerProgressApplySummary _summaryForEntry(
    TrackerStatusEntry entry, {
    required int marked,
    String? next,
  }) {
    final resolvedNext =
        next ??
        (entry.seasonNumber != null && entry.episodeNumber != null
            ? _formatSe(entry.seasonNumber!, entry.episodeNumber!)
            : null);
    return TrackerProgressApplySummary(
      title: entry.title,
      idKey: entry.identityKey,
      marked: marked,
      watched: entry.watchedEpisodes,
      total: entry.totalEpisodes,
      next: resolvedNext,
    );
  }

  static String _formatSe(int season, int episode) {
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  /// Watched (season, episode) pairs. Prefers watched counts, then next-up.
  ///
  /// [TrackerStatusEntry.seasonNumber]/[TrackerStatusEntry.episodeNumber] is
  /// either next-to-watch (library) or a mid-episode playhead (playback). When
  /// both a watched count and next-up exist and disagree (e.g. watched=5 +
  /// next S01E05), next-up wins so that episode is not marked watched. A
  /// mid-episode playhead never truncates the watched count.
  static List<(int, int)> _resolveWatchedPairs(
    TrackerStatusEntry entry,
    List<TrackerEpisodeRef> episodes,
  ) {
    final completed = entry.status == TrackerStatusKind.completed;
    if (episodes.isNotEmpty) {
      if (completed) {
        return [for (final e in episodes) (e.seasonNumber, e.episodeNumber)];
      }
      final nextS = entry.seasonNumber;
      final nextE = entry.episodeNumber;
      final watched = entry.watchedEpisodes;
      final nextIsUp = _seasonEpisodeIsNextUp(entry);

      if (watched != null && watched > 0) {
        final n = watched.clamp(0, episodes.length);
        final byCount = [
          for (final e in episodes.take(n)) (e.seasonNumber, e.episodeNumber),
        ];
        // Next-to-watch inside the watched prefix → don't mark that episode
        // (Simkl "watching ep 5" / next-up, not "5 fully watched").
        if (nextIsUp &&
            nextS != null &&
            nextE != null &&
            nextS > 0 &&
            nextE > 0) {
          final beforeNext = [
            for (final e in episodes)
              if (_epBefore(e.seasonNumber, e.episodeNumber, nextS, nextE))
                (e.seasonNumber, e.episodeNumber),
          ];
          if (beforeNext.length < byCount.length) return beforeNext;
        }
        return byCount;
      }

      if (nextS != null && nextE != null && nextS > 0 && nextE > 0) {
        return [
          for (final e in episodes)
            if (_epBefore(e.seasonNumber, e.episodeNumber, nextS, nextE))
              (e.seasonNumber, e.episodeNumber),
        ];
      }
      final pct = entry.progress;
      if (pct != null && pct > 0.02) {
        final total = entry.totalEpisodes ?? episodes.length;
        final n = (total * pct).floor().clamp(0, episodes.length);
        return [
          for (final e in episodes.take(n)) (e.seasonNumber, e.episodeNumber),
        ];
      }
      return const [];
    }

    // No local episode list yet (sync path) — invent S/E from next + counts.
    List<(int, int)> take(int n) {
      final capped = n.clamp(0, maxInventedWatched);
      return [for (var i = 1; i <= capped; i++) (1, i)];
    }

    if (completed) {
      final total = entry.totalEpisodes ?? entry.watchedEpisodes;
      if (total == null || total <= 0) return const [];
      return take(total);
    }

    final nextS = entry.seasonNumber;
    final nextE = entry.episodeNumber;
    final watched = entry.watchedEpisodes;
    final nextIsUp = _seasonEpisodeIsNextUp(entry);

    if (watched != null && watched > 0) {
      if (nextIsUp &&
          nextS != null &&
          nextE != null &&
          nextS == 1 &&
          nextE > 0) {
        final beforeNext = (nextE - 1).clamp(0, maxInventedWatched);
        if (beforeNext < watched) return take(beforeNext);
      }
      return take(watched);
    }

    if (nextS != null && nextE != null && nextS > 0 && nextE > 0) {
      if (nextS == 1) {
        final n = (nextE - 1).clamp(0, maxInventedWatched);
        return [for (var i = 1; i <= n; i++) (1, i)];
      }
      // Multi-season without a count: only mark same-season predecessors.
      final n = (nextE - 1).clamp(0, maxInventedWatched);
      return [for (var i = 1; i <= n; i++) (nextS, i)];
    }
    final pct = entry.progress;
    final total = entry.totalEpisodes;
    if (pct != null && total != null && total > 0 && pct > 0.02) {
      return take((total * pct).floor());
    }
    return const [];
  }

  /// True when [entry]'s season/episode is next-to-watch, not a mid-playhead.
  ///
  /// Playback rows carry progress on the paused episode; library rows often
  /// carry series ratio `watched/total` plus `next_to_watch`. Only the latter
  /// should truncate the watched-count prefix.
  static bool _seasonEpisodeIsNextUp(TrackerStatusEntry entry) {
    final nextS = entry.seasonNumber;
    final nextE = entry.episodeNumber;
    if (nextS == null || nextE == null || nextS <= 0 || nextE <= 0) {
      return false;
    }
    final p = entry.progress;
    if (p == null || p <= 0.02 || p >= watchedThreshold) return true;
    // Series-ratio progress (≈ watched/total) still means next-up.
    final w = entry.watchedEpisodes;
    final t = entry.totalEpisodes;
    if (w != null && t != null && t > 0) {
      final ratio = (w / t).clamp(0.0, 1.0);
      if ((p - ratio).abs() < 0.02) return true;
    }
    // Mid-episode playhead on this S/E (inbound playback) — not next-up.
    return false;
  }

  static (int, int)? _resolveNextEpisode(
    TrackerStatusEntry entry,
    List<TrackerEpisodeRef> episodes,
    List<(int, int)> watchedPairs,
  ) {
    final nextS = entry.seasonNumber;
    final nextE = entry.episodeNumber;
    if (nextS != null && nextE != null && nextS > 0 && nextE > 0) {
      return (nextS, nextE);
    }
    if (episodes.isNotEmpty) {
      final watched = {for (final p in watchedPairs) '${p.$1}:${p.$2}'};
      for (final e in episodes) {
        if (!watched.contains('${e.seasonNumber}:${e.episodeNumber}')) {
          return (e.seasonNumber, e.episodeNumber);
        }
      }
      return null;
    }
    final watchedCount = entry.watchedEpisodes;
    if (watchedCount != null && watchedCount >= 0) {
      return (1, watchedCount + 1);
    }
    return null;
  }

  static bool _epBefore(int s, int e, int nextS, int nextE) {
    if (s < nextS) return true;
    if (s > nextS) return false;
    return e < nextE;
  }

  static TrackerEpisodeRef? _findRef(
    List<TrackerEpisodeRef> episodes,
    int sn,
    int en,
  ) {
    for (final e in episodes) {
      if (e.seasonNumber == sn && e.episodeNumber == en) return e;
    }
    return null;
  }

  static bool _upsertEpisodeProgress({
    required MediaItem series,
    required int seasonNumber,
    required int episodeNumber,
    required double progress,
    required TrackerStatusEntry entry,
    required Map<String, MediaItem> historyById,
    required Map<String, MediaItem> catalogUpdates,
    required String? episodeId,
    required String? episodeTitle,
    required String playUrl,
    required bool seedUpNext,
    DateTime? watchedAt,
  }) {
    final seriesKey = (series.streamId?.trim().isNotEmpty == true)
        ? series.streamId!.trim()
        : series.id;
    final existing = _findHistoryEpisode(
      historyById,
      series: series,
      seriesKey: seriesKey,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );

    final want = progress.clamp(0.0, 1.0);
    if (existing != null) {
      // Never regress local playhead / watched state.
      if (want >= watchedThreshold && existing.progress >= watchedThreshold) {
        return false;
      }
      if (want < watchedThreshold && want <= existing.progress + aheadEpsilon) {
        // Still allow tagging an unwatched stub as continue-up-next.
        if (!(seedUpNext &&
            !LocalRecommender.isContinueUpNext(existing) &&
            existing.progress <= 0.02)) {
          return false;
        }
      }
    }

    final id = episodeId?.trim().isNotEmpty == true
        ? episodeId!.trim()
        : (existing?.id ??
              'tracker-ep:$seriesKey:s${seasonNumber}e$episodeNumber');
    final epCode =
        'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';
    final showTitle = series.title.trim();
    final title =
        (episodeTitle != null &&
            episodeTitle.trim().isNotEmpty &&
            !RegExp(
              r'^(episode|épisode|ep)\s*\d+$',
              caseSensitive: false,
            ).hasMatch(episodeTitle.trim()))
        ? episodeTitle.trim()
        : (showTitle.isNotEmpty ? '$showTitle · $epCode' : epCode);

    final tags = <String>[
      if (existing != null)
        ...existing.tags.where((t) => t != LocalRecommender.continueUpNextTag),
      if (seedUpNext && want < watchedThreshold)
        LocalRecommender.continueUpNextTag,
    ];

    final base =
        existing ??
        MediaItem(
          id: id,
          title: title,
          playUrl: playUrl,
          kind: MediaKind.vod,
          origin: series.origin,
          posterUrl: series.posterUrl,
          thumbnailUrl: series.thumbnailUrl,
          backdropUrl: series.backdropUrl,
          group: series.group,
          sourceId: series.sourceId,
          seriesId: seriesKey,
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
          tmdbId: series.tmdbId,
          imdbId: series.imdbId,
          tvdbId: series.tvdbId,
          anilistId: series.anilistId,
          simklId: series.simklId,
          subtitle: showTitle.isNotEmpty ? '$showTitle · $epCode' : epCode,
        );

    final mergedProgress = existing == null
        ? want
        : (want >= existing.progress ? want : existing.progress);
    final at = watchedAt ?? entry.updatedAt ?? DateTime.now();
    final resolvedPlayUrl = playUrl.trim().isNotEmpty ? playUrl : base.playUrl;
    final subtitle = showTitle.isNotEmpty ? '$showTitle · $epCode' : epCode;

    // Remap synthetic → real episode id when details load (copyWith has no id).
    if (existing != null && existing.id != id) {
      historyById.remove(existing.id);
    }

    final updated = existing != null && existing.id == id
        ? base.copyWith(
            title: title,
            playUrl: resolvedPlayUrl,
            progress: mergedProgress,
            lastWatchedAt: at,
            seriesId: seriesKey,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            simklId: base.simklId ?? entry.simklId ?? series.simklId,
            tmdbId: base.tmdbId ?? entry.tmdbId ?? series.tmdbId,
            imdbId: base.imdbId ?? entry.imdbId ?? series.imdbId,
            tvdbId: base.tvdbId ?? entry.tvdbId ?? series.tvdbId,
            anilistId: base.anilistId ?? entry.anilistId ?? series.anilistId,
            tags: tags,
            subtitle: subtitle,
          )
        : MediaItem(
            id: id,
            title: title,
            playUrl: resolvedPlayUrl,
            kind: MediaKind.vod,
            origin: series.origin,
            posterUrl: base.posterUrl ?? series.posterUrl,
            thumbnailUrl: base.thumbnailUrl ?? series.thumbnailUrl,
            backdropUrl: base.backdropUrl ?? series.backdropUrl,
            group: base.group ?? series.group,
            sourceId: base.sourceId ?? series.sourceId,
            seriesId: seriesKey,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            progress: mergedProgress,
            lastWatchedAt: at,
            tmdbId: base.tmdbId ?? entry.tmdbId ?? series.tmdbId,
            imdbId: base.imdbId ?? entry.imdbId ?? series.imdbId,
            tvdbId: base.tvdbId ?? entry.tvdbId ?? series.tvdbId,
            anilistId: base.anilistId ?? entry.anilistId ?? series.anilistId,
            simklId: base.simklId ?? entry.simklId ?? series.simklId,
            subtitle: subtitle,
            tags: tags,
          );
    historyById[updated.id] = updated;
    if (catalogUpdates.containsKey(updated.id) ||
        (episodeId != null && episodeId.isNotEmpty)) {
      catalogUpdates[updated.id] = updated;
    }
    return true;
  }

  static MediaItem? _findHistoryEpisode(
    Map<String, MediaItem> historyById, {
    required MediaItem series,
    required String seriesKey,
    required int seasonNumber,
    required int episodeNumber,
  }) {
    MediaItem? best;
    for (final h in historyById.values) {
      if (!h.isEpisode) continue;
      if (h.seasonNumber != seasonNumber || h.episodeNumber != episodeNumber) {
        continue;
      }
      final sid = h.seriesId?.trim();
      final belongs =
          sid == seriesKey ||
          sid == series.id ||
          (series.streamId != null && sid == series.streamId) ||
          h.id == series.id;
      if (!belongs && !_looseSeriesIdMatch(h, series)) {
        continue;
      }
      if (best == null ||
          (h.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).isAfter(
            best.lastWatchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          )) {
        best = h;
      }
    }
    return best;
  }

  static bool _looseSeriesIdMatch(MediaItem episode, MediaItem series) {
    if (series.tmdbId != null && episode.tmdbId == series.tmdbId) return true;
    if (series.anilistId != null && episode.anilistId == series.anilistId) {
      return true;
    }
    if (series.simklId != null && episode.simklId == series.simklId) {
      return true;
    }
    if (series.imdbId != null &&
        episode.imdbId != null &&
        series.imdbId!.toLowerCase() == episode.imdbId!.toLowerCase()) {
      return true;
    }
    return false;
  }

  static TrackerProgressMergeResult _finish(
    List<MediaItem> history,
    List<MediaItem> catalog,
    Map<String, MediaItem> historyById,
    Map<String, MediaItem> catalogUpdates,
    bool changed, {
    List<TrackerProgressApplySummary> applied = const [],
    int episodesMarked = 0,
    int moviesUpdated = 0,
  }) {
    if (!changed) {
      return TrackerProgressMergeResult(
        history: history,
        catalog: catalog,
        changed: false,
      );
    }

    final nextHistory = historyById.values.toList()
      ..sort((a, b) {
        final aAt = a.lastWatchedAt;
        final bAt = b.lastWatchedAt;
        if (aAt == null && bAt == null) return 0;
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        return bAt.compareTo(aAt);
      });
    // Prefer keeping episode progress rows; trim oldest beyond cap.
    final trimmed = nextHistory.length > 400
        ? nextHistory.take(400).toList()
        : nextHistory;
    final nextCatalog = catalogUpdates.isEmpty
        ? catalog
        : [for (final m in catalog) catalogUpdates[m.id] ?? m];

    return TrackerProgressMergeResult(
      history: trimmed,
      catalog: nextCatalog,
      changed: true,
      applied: applied,
      episodesMarked: episodesMarked,
      moviesUpdated: moviesUpdated,
    );
  }
}
