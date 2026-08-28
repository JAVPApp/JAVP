import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/catalog/custom_catalog_client.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/desktop/anchored_menu_surface.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/season_chip_slider.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/vod_source_groups.dart';
import 'package:provider/provider.dart';

class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({super.key, required this.series});

  final MediaItem series;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late Future<SeriesInfo> _future;
  int? _seasonNumber;
  bool _loadingSeason = false;

  /// When true, the episode list only shows downloaded episodes.
  bool _onlyDownloaded = false;

  /// True while we fetch the episode list after an empty first paint.
  bool _hydratingEpisodes = false;
  bool _episodeHydrationStarted = false;
  final Set<String> _resolvingEpisodeIds = {};

  /// Episode ids already handed to warm viewport prefetch (attempted once).
  ///
  /// Stays set after failure so unaired / empty catalog stubs are not re-enqueued
  /// from [buildCard] every frame (that loop froze sample series detail: perpetual
  /// setState + I/jank with hitch notifies=0).
  final Set<String> _prefetchQueuedIds = {};

  /// Ids currently in a prefetch batch — drives the Resolving… spinner only.
  final Set<String> _prefetchInflightIds = {};
  final List<SeriesEpisode> _prefetchPending = [];
  Timer? _prefetchDebounce;
  bool _prefetchUiScheduled = false;

  /// Delay after stub list before cold/bulk fill (skipped when Play fires).
  Timer? _progressiveDelay;

  /// Season we already scheduled progressive fill for.
  int? _progressiveSeason;

  /// Focused row shown as "Resolving…" during cold delay / bulk fill.
  String? _coldFocusEpisodeId;
  bool _coldFillInProgress = false;

  /// User hit Play/Versions — cancel cold delay; resolve is priority.
  bool _priorityPlayStarted = false;

  late MediaItem _activeShell;

  @override
  void initState() {
    super.initState();
    final library = context.read<LibraryProvider>();
    _activeShell = library.resolveVodVariant(widget.series);
    unawaited(library.hydrateVodFamilyFromDb(widget.series));
    _future = library.loadSeriesInfo(_activeShell);
    final resume = library.resumeEpisodeForSeries(_activeShell);
    _seasonNumber = resume?.seasonNumber ?? _activeShell.seasonNumber;
    // After the first paint/load: hydrate empty episode lists, or soft-refresh
    // stale custom-catalog shells. Avoid racing a second fetch while
    // [loadSeriesInfo] is still in flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_afterInitialSeriesLoad(library));
    });
  }

  bool _infoHasEpisodes(SeriesInfo info) =>
      info.seasons.any((s) => s.episodes.isNotEmpty);

  Future<void> _afterInitialSeriesLoad(LibraryProvider library) async {
    try {
      final info = await _future;
      if (!mounted) return;
      if (!_infoHasEpisodes(info)) {
        await _hydrateEpisodes(library, force: true);
        return;
      }
      unawaited(_enrichEpisodeArt(library, info));
      if (_activeShell.origin != MediaOrigin.customCatalog) return;
      final details = library.detailsFor(_activeShell);
      final updated = details?.updatedAt;
      final stale =
          updated == null ||
          DateTime.now().difference(updated) >=
              LibraryProvider.customCatalogShellTtl;
      if (stale) unawaited(_softRefreshSeries(library));
    } catch (_) {}
  }

  /// Optional episode stills from SIMKL / Trakt / TMDB when the catalog omitted art.
  Future<void> _enrichEpisodeArt(
    LibraryProvider library,
    SeriesInfo info, {
    int? seasonNumber,
  }) async {
    try {
      final next = await library.enrichSeriesEpisodeArt(
        _activeShell,
        info,
        seasonNumber: seasonNumber ?? _seasonNumber,
      );
      if (!mounted) return;
      if (identical(next, info)) return;
      // Same episode ids — only art/plot filled; keep the painted future.
      setState(() => _future = Future.value(next));
    } catch (_) {}
  }

  Future<void> _hydrateEpisodes(
    LibraryProvider library, {
    bool force = false,
  }) async {
    if (_episodeHydrationStarted && !force) return;
    if (_hydratingEpisodes) return;
    _episodeHydrationStarted = true;
    if (mounted) setState(() => _hydratingEpisodes = true);
    try {
      SeriesInfo next;
      if (_activeShell.origin == MediaOrigin.customCatalog) {
        next = await library.refreshSeriesInfo(_activeShell, force: force);
        final seasonNum =
            _seasonNumber ??
            (next.seasons.isEmpty ? null : next.seasons.first.seasonNumber);
        if (seasonNum != null &&
            !next.seasons.any(
              (s) => s.seasonNumber == seasonNum && s.episodes.isNotEmpty,
            )) {
          next =
              await library.ensureSeasonEpisodes(
                series: _activeShell,
                seasonNumber: seasonNum,
              ) ??
              next;
        }
      } else {
        await library.loadMediaDetails(_activeShell, forceRefresh: true);
        next = await library.loadSeriesInfo(_activeShell);
      }
      if (!mounted) return;
      setState(() => _future = Future.value(next));
      unawaited(_enrichEpisodeArt(library, next));
    } catch (_) {
      // Keep whatever we already painted.
    } finally {
      if (mounted) setState(() => _hydratingEpisodes = false);
    }
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
    _progressiveDelay?.cancel();
    super.dispose();
  }

  /// Progressive custom-catalog stub awaiting `GET /items/{id}`.
  ///
  /// Plex / Jellyfin / Emby leave playUrl empty by design (stream URL built at
  /// play time) — that must not look like catalog lazy-resolve loading.
  bool _needsCatalogResolve(SeriesEpisode episode) =>
      _activeShell.origin == MediaOrigin.customCatalog &&
      episode.needsPlaybackResolve;

  /// Catalog stub with no on-device file — prefetch / Loading, not Versions.
  bool _shouldAutoResolve(LibraryProvider library, SeriesEpisode episode) {
    if (!_needsCatalogResolve(episode)) return false;
    return !library.hasOfflineCopyForEpisode(
      series: _activeShell,
      episode: episode,
    );
  }

  SeriesEpisode _pickFocusEpisode(
    List<SeriesEpisode> episodes, {
    SeriesEpisode? prioritize,
  }) {
    if (prioritize != null) {
      for (final ep in episodes) {
        if (ep.id == prioritize.id) return ep;
      }
    }
    return episodes.first;
  }

  /// After stub `/episodes`: wait ~1s (bridge pool warm), then bulk-fill short
  /// cours or cold-resolve the focused episode. Play cancels the delay.
  void _scheduleProgressiveFill(
    LibraryProvider library,
    List<SeriesEpisode> episodes, {
    required int seasonNumber,
    SeriesEpisode? prioritize,
  }) {
    if (_activeShell.origin != MediaOrigin.customCatalog) return;
    if (episodes.isEmpty) return;
    if (_progressiveSeason == seasonNumber) return;
    _progressiveSeason = seasonNumber;
    _progressiveDelay?.cancel();

    final focus = _pickFocusEpisode(episodes, prioritize: prioritize);
    var liveFocus = library.resolvedEpisodeFor(
      series: _activeShell,
      episode: focus,
    );

    if (library.isCustomCatalogSeriesWarm(_activeShell)) {
      if (mounted) {
        setState(() {
          _coldFillInProgress = false;
          _coldFocusEpisodeId = null;
        });
      }
      _enqueueWarmVisible(library, episodes);
      return;
    }

    if (!_shouldAutoResolve(library, liveFocus) &&
        episodes.every((e) {
          final live = library.resolvedEpisodeFor(
            series: _activeShell,
            episode: e,
          );
          return !_shouldAutoResolve(library, live);
        })) {
      return;
    }

    if (!_shouldAutoResolve(library, liveFocus)) {
      for (final e in episodes) {
        final live = library.resolvedEpisodeFor(
          series: _activeShell,
          episode: e,
        );
        if (_shouldAutoResolve(library, live)) {
          liveFocus = live;
          break;
        }
      }
    }

    if (mounted) {
      setState(() {
        _coldFocusEpisodeId = liveFocus.id;
        _coldFillInProgress = true;
      });
    }

    _progressiveDelay = Timer(
      LibraryProvider.customCatalogColdPrefetchDelay,
      () {
        if (!mounted || _priorityPlayStarted) {
          if (mounted) {
            setState(() {
              _coldFillInProgress = false;
              _coldFocusEpisodeId = null;
            });
          }
          return;
        }
        unawaited(
          _runProgressiveFill(
            library,
            episodes,
            seasonNumber: seasonNumber,
            focus: liveFocus,
          ),
        );
      },
    );
  }

  Future<void> _runProgressiveFill(
    LibraryProvider library,
    List<SeriesEpisode> episodes, {
    required int seasonNumber,
    required SeriesEpisode focus,
  }) async {
    try {
      final courSize = episodes.length;
      if (courSize <= CustomCatalogClient.maxResolveLimit) {
        await library.bulkResolveSeasonEpisodes(
          series: _activeShell,
          seasonNumber: seasonNumber,
          limit: courSize,
        );
      } else {
        // Long shows: tight window from the focused episode, not the whole cour.
        var focusIndex = 0;
        for (var i = 0; i < episodes.length; i++) {
          if (episodes[i].id == focus.id) {
            focusIndex = i;
            break;
          }
        }
        await library.bulkResolveSeasonEpisodes(
          series: _activeShell,
          seasonNumber: seasonNumber,
          limit: 12,
          offset: focusIndex,
        );
      }

      if (!mounted || _priorityPlayStarted) return;

      final stillFocus = library.resolvedEpisodeFor(
        series: _activeShell,
        episode: focus,
      );
      if (_shouldAutoResolve(library, stillFocus) &&
          !library.isCustomCatalogSeriesWarm(_activeShell)) {
        // Bulk unsupported / empty — cold-gate a single per-episode resolve.
        await library.prefetchEpisodePlayback(
          series: _activeShell,
          episodes: [stillFocus],
        );
      } else if (_shouldAutoResolve(library, stillFocus)) {
        await library.resolveEpisodePlayback(
          series: _activeShell,
          episode: stillFocus,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _coldFillInProgress = false;
          _coldFocusEpisodeId = null;
        });
        if (library.isCustomCatalogSeriesWarm(_activeShell)) {
          _enqueueWarmVisible(library, episodes);
        }
      }
    }
  }

  void _enqueueWarmVisible(
    LibraryProvider library,
    List<SeriesEpisode> episodes,
  ) {
    // Only a short look-ahead once warm — not the old first-10 stampede.
    for (final episode in episodes.take(6)) {
      _enqueueEpisodePrefetch(library, episode);
    }
  }

  /// Queue progressive stubs for warm prefetch as rows paint.
  ///
  /// Cold series: skipped (bulk / focused resolve owns the first fill).
  /// Each episode id is attempted at most once per screen visit — failed stubs
  /// (unaired / no magnet) must not clear the queue mark or [buildCard] will
  /// re-enqueue forever.
  void _enqueueEpisodePrefetch(LibraryProvider library, SeriesEpisode episode) {
    if (_activeShell.origin != MediaOrigin.customCatalog) return;
    if (!library.isCustomCatalogSeriesWarm(_activeShell)) return;
    final live = library.resolvedEpisodeFor(
      series: _activeShell,
      episode: episode,
    );
    if (!_shouldAutoResolve(library, live)) return;
    if (!_prefetchQueuedIds.add(live.id)) return;
    _prefetchInflightIds.add(live.id);
    _prefetchPending.add(live);
    UiDebug.mark('series-prefetch:enqueue');
    // Coalesce Resolving… paints — never one post-frame setState per row.
    if (!_prefetchUiScheduled) {
      _prefetchUiScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prefetchUiScheduled = false;
        if (mounted) setState(() {});
      });
    }
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 100), () {
      if (!mounted || _prefetchPending.isEmpty) return;
      final batch = List<SeriesEpisode>.from(_prefetchPending);
      _prefetchPending.clear();
      UiDebug.mark('series-prefetch:batch');
      unawaited(
        library
            .prefetchEpisodePlayback(
              series: _activeShell,
              episodes: batch,
              concurrency: LibraryProvider.customCatalogWarmPrefetchConcurrency,
            )
            .whenComplete(() {
              if (!mounted) return;
              setState(() {
                for (final ep in batch) {
                  _prefetchInflightIds.remove(ep.id);
                  // Keep [_prefetchQueuedIds] — do not retry failed stubs.
                }
              });
            }),
      );
    });
  }

  void _cancelColdDelayForPlay() {
    _priorityPlayStarted = true;
    _progressiveDelay?.cancel();
    _progressiveDelay = null;
    if (_coldFillInProgress && mounted) {
      setState(() {
        _coldFillInProgress = false;
        _coldFocusEpisodeId = null;
      });
    }
  }

  Future<void> _softRefreshSeries(LibraryProvider library) async {
    try {
      final current = await _future;
      // If we have nothing to show yet, use the hydrating spinner path.
      if (!_infoHasEpisodes(current)) {
        await _hydrateEpisodes(library, force: true);
        return;
      }
      final next = await library.refreshSeriesInfo(_activeShell);
      if (!mounted) return;
      setState(() => _future = Future.value(next));
    } catch (_) {
      // Keep the cached first paint.
    }
  }

  Future<void> _pullRefresh(LibraryProvider library) async {
    try {
      final next = await library.refreshSeriesInfo(_activeShell, force: true);
      if (!mounted) return;
      setState(() => _future = Future.value(next));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.couldNotRefreshEpisodes('$e'))),
      );
    }
  }

  SeriesEpisode? _episodeMatchingResume(SeriesInfo info, MediaItem resume) {
    final streamId = resume.streamId?.trim();
    for (final season in info.seasons) {
      for (final episode in season.episodes) {
        if (episode.id == resume.id) return episode;
        if (streamId != null && streamId.isNotEmpty && episode.id == streamId) {
          return episode;
        }
        if (resume.seasonNumber == episode.seasonNumber &&
            resume.episodeNumber == episode.episodeNum) {
          return episode;
        }
      }
    }
    return null;
  }

  String _resumeLabel(BuildContext context, MediaItem resume) {
    final l10n = context.l10n;
    final sn = resume.seasonNumber;
    final en = resume.episodeNumber;
    if (sn != null || en != null) {
      final code =
          'S${(sn ?? 1).toString().padLeft(2, '0')}'
          'E${(en ?? 0).toString().padLeft(2, '0')}';
      final pct = (resume.progress * 100).round();
      return l10n.resumeEpisodeProgress(code, pct);
    }
    return l10n.resume;
  }

  Future<void> _selectSeason(LibraryProvider library, int seasonNumber) async {
    setState(() => _seasonNumber = seasonNumber);
    final info = await _future;
    SeriesSeason? season;
    for (final s in info.seasons) {
      if (s.seasonNumber == seasonNumber) {
        season = s;
        break;
      }
    }
    if (season != null && season.episodes.isNotEmpty) {
      unawaited(_enrichEpisodeArt(library, info, seasonNumber: seasonNumber));
      return;
    }
    if (_activeShell.origin != MediaOrigin.customCatalog) return;
    if (_loadingSeason) return;
    setState(() => _loadingSeason = true);
    try {
      final next = await library.ensureSeasonEpisodes(
        series: _activeShell,
        seasonNumber: seasonNumber,
      );
      if (!mounted || next == null) return;
      setState(() => _future = Future.value(next));
      unawaited(_enrichEpisodeArt(library, next, seasonNumber: seasonNumber));
    } finally {
      if (mounted) setState(() => _loadingSeason = false);
    }
  }

  Future<EpisodePlayVariant?> _pickEpisodeVariant({
    required LibraryProvider library,
    required SeriesEpisode episode,
  }) async {
    // Progressive catalogs: resolve magnets/versions on demand first.
    _cancelColdDelayForPlay();
    var live = library.resolvedEpisodeFor(
      series: _activeShell,
      episode: episode,
    );
    if (_needsCatalogResolve(live)) {
      setState(() => _resolvingEpisodeIds.add(episode.id));
      try {
        live =
            await library.resolveEpisodePlayback(
              series: _activeShell,
              episode: episode,
            ) ??
            live;
      } finally {
        if (mounted) {
          setState(() => _resolvingEpisodeIds.remove(episode.id));
        }
      }
    }
    final variants = library.episodePlayVariants(
      series: _activeShell,
      episode: live,
    );
    if (variants.length <= 1) {
      return variants.isEmpty ? null : variants.first;
    }
    final isQuality = variants.first.id.startsWith('msq-');
    if (!mounted) return null;
    return showAppModal<EpisodePlayVariant>(
      context: context,
      builder: (context) {
        final preferred = library.preferredEpisodeVariant(
          series: _activeShell,
          episode: live,
        );
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  isQuality
                      ? context.l10n.qualityForEpisode(live.shortLabel)
                      : context.l10n.versionsForEpisode(live.shortLabel),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final v in variants)
                ListTile(
                  title: Text(v.displayLabel),
                  subtitle:
                      v.subtitle != null &&
                          v.subtitle!.trim().isNotEmpty &&
                          !v.displayLabel.contains(v.subtitle!.trim())
                      ? Text(v.subtitle!)
                      : null,
                  trailing: preferred?.id == v.id
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.pop(context, v),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _playEpisode({
    required LibraryProvider library,
    required SeriesEpisode episode,
    bool pickVersion = false,
  }) async {
    _cancelColdDelayForPlay();
    EpisodePlayVariant? variant;
    if (pickVersion) {
      variant = await _pickEpisodeVariant(library: library, episode: episode);
      if (variant == null || !mounted) return;
      await library.setPreferredEpisodeVariant(
        series: _activeShell,
        episode: episode,
        variant: variant,
      );
      if (variant.id.startsWith('msq-')) {
        final q = MediaServerStreamQuality.values
            .asNameMap()[variant.id.substring(4)];
        if (q != null) {
          await library.saveMediaServerStreamQuality(q);
        }
      }
    } else {
      final offline = library.offlineItemForEpisode(
        series: _activeShell,
        episode: episode,
      );
      if (offline != null) {
        context.push('/player', extra: offline);
        return;
      }
    }
    setState(() => _resolvingEpisodeIds.add(episode.id));
    MediaItem? item;
    try {
      item = await library.ensureEpisodePlayable(
        series: _activeShell,
        episode: episode,
        variant: variant,
      );
    } finally {
      if (mounted) {
        setState(() => _resolvingEpisodeIds.remove(episode.id));
      }
    }
    if (!mounted) return;
    if (item == null ||
        (item.playUrl.trim().isEmpty && item.serverItemId == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.couldNotBuildEpisodeStreamUrl)),
      );
      return;
    }
    context.push('/player', extra: item);
  }

  Future<void> _showSeriesDownloadOptions({
    required LibraryProvider library,
    required SeriesInfo info,
    required SeriesSeason? selectedSeason,
  }) async {
    await showAppModal<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selectedSeason != null)
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: Text(
                    context.l10n.downloadSeasonNamed(selectedSeason.name),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    enqueueDownloadsWithFeedback(
                      context,
                      library,
                      () => library.enqueueDownloadRemainingInSeason(
                        _activeShell,
                        info: info,
                        seasonNumber: selectedSeason.seasonNumber,
                      ),
                      singular: 'episode',
                      plural: 'episodes',
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.library_add_rounded),
                title: Text(context.l10n.downloadEntireSeries),
                subtitle: Text(context.l10n.queueEveryEpisodeOffline),
                onTap: () {
                  Navigator.pop(ctx);
                  enqueueDownloadsWithFeedback(
                    context,
                    library,
                    () => library.enqueueDownloadEntireSeries(
                      _activeShell,
                      info: info,
                    ),
                    singular: 'episode',
                    plural: 'episodes',
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEpisodeDownloadSheet({
    required LibraryProvider library,
    required SeriesInfo info,
    required SeriesEpisode episode,
    required MediaItem? playable,
    Offset? anchor,
  }) async {
    final ahead = library.downloadSettings.aheadCountClamped;
    final historyItem = library.historyForSeriesEpisode(
      series: _activeShell,
      episode: episode,
    );
    final progressTarget =
        historyItem ??
        playable ??
        library.episodeMediaItem(series: _activeShell, episode: episode) ??
        MediaItem(
          id: episode.id,
          title: episode.title,
          playUrl: episode.playUrl ?? '',
          kind: MediaKind.vod,
          origin: _activeShell.origin,
          subtitle: '${_activeShell.title} · ${episode.shortLabel}',
          thumbnailUrl: episode.thumbnailUrl ?? _activeShell.thumbnailUrl,
          posterUrl: _activeShell.posterUrl,
          duration: episode.duration,
          sourceId: _activeShell.sourceId,
          serverItemId: _activeShell.origin.isMediaServer ? episode.id : null,
          seriesId:
              _activeShell.streamId ??
              _activeShell.serverItemId ??
              _activeShell.id,
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNum,
          tmdbId: _activeShell.tmdbId,
          anilistId: _activeShell.anilistId,
          imdbId: _activeShell.imdbId,
        );

    Widget content(BuildContext ctx) {
      final compact = anchor != null && DesktopUi.enabled;
      return SafeArea(
        top: false,
        bottom: !compact,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact)
              const AppModalDragHandle(top: 10, bottom: 8)
            else
              const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.check_circle_outline_rounded),
              title: Text(context.l10n.markAsWatched),
              onTap: () async {
                Navigator.pop(ctx);
                await library.markAsWatched(progressTarget);
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove_done_rounded),
              title: Text(context.l10n.markAsUnwatched),
              onTap: () async {
                Navigator.pop(ctx);
                await library.markAsUnwatched(progressTarget);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: Text(context.l10n.downloadThisEpisode),
              onTap: () async {
                Navigator.pop(ctx);
                if (playable == null) return;
                await enqueueDownloadWithFeedback(context, library, playable);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: Text(context.l10n.downloadNextCount(ahead)),
              onTap: () async {
                Navigator.pop(ctx);
                await enqueueDownloadsWithFeedback(
                  context,
                  library,
                  () => library.enqueueDownloadNext(
                    _activeShell,
                    info: info,
                    from: episode,
                  ),
                  singular: 'episode',
                  plural: 'episodes',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.library_add_rounded),
              title: Text(context.l10n.downloadRemainingInSeason),
              onTap: () async {
                Navigator.pop(ctx);
                await enqueueDownloadsWithFeedback(
                  context,
                  library,
                  () => library.enqueueDownloadRemainingInSeason(
                    _activeShell,
                    info: info,
                    seasonNumber: episode.seasonNumber,
                    fromEpisodeNum: episode.episodeNum,
                  ),
                  singular: 'episode',
                  plural: 'episodes',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_rounded),
              title: Text(context.l10n.downloadEntireSeries),
              onTap: () async {
                Navigator.pop(ctx);
                await enqueueDownloadsWithFeedback(
                  context,
                  library,
                  () => library.enqueueDownloadEntireSeries(
                    _activeShell,
                    info: info,
                  ),
                  singular: 'episode',
                  plural: 'episodes',
                );
              },
            ),
          ],
        ),
      );
    }

    if (anchor != null && DesktopUi.enabled) {
      await showAnchoredMenuSurface<void>(
        context: context,
        globalPosition: anchor,
        builder: content,
      );
      return;
    }

    await showAppModal<void>(context: context, builder: content);
  }

  int _historyWatchStamp(LibraryProvider l) => Object.hash(
    identityHashCode(l.history),
    l.history.length,
    l.history.isEmpty ? null : l.history.first.id,
    l.history.isEmpty ? null : l.history.first.progress,
    l.history.isEmpty ? null : l.history.first.lastWatchedAt,
  );

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final saved = context.select<LibraryProvider, bool>(
      (l) => l.isInWatchlist(_activeShell),
    );
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.downloads.tasks.length,
        l.downloads.activeCount,
        Object.hashAll(
          l.downloads.tasks.map((t) => Object.hash(t.id, t.status)),
        ),
        l.mediaServerStreamQuality,
        l.customCatalogResolveRevision,
        l.vodGroupingRevision,
        l.vodFamilyOverlayRevision,
        Object.hashAll(
          l.preferredVodVariants.entries.map(
            (e) => Object.hash(e.key, e.value),
          ),
        ),
        l.watchHistoryRevision,
        l.history.length,
      ),
    );
    final resumeItem = library.resumeEpisodeForSeries(_activeShell);
    final details = library.detailsFor(_activeShell);
    final cast = details?.cast ?? const <CastMember>[];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: FutureBuilder<SeriesInfo>(
        future: _future,
        builder: (context, snap) {
          // Keep last successful paint when [_future] is swapped (enrich /
          // soft-refresh) — avoid a full-screen spinner blink.
          if (snap.connectionState != ConnectionState.done &&
              snap.data == null) {
            return Center(child: CircularProgressIndicator());
          }
          if ((snap.hasError || snap.data == null) &&
              snap.connectionState == ConnectionState.done) {
            return _ErrorBody(
              message:
                  snap.error?.toString() ?? context.l10n.couldNotLoadSeries,
              onRetry: () {
                setState(() {
                  _future = library.loadSeriesInfo(_activeShell);
                });
              },
              onBack: () => context.pop(),
            );
          }

          final info = snap.data!;
          final seasons = info.seasons;
          final selectedSeason = seasons.isEmpty
              ? null
              : seasons.firstWhere(
                  (s) =>
                      s.seasonNumber ==
                      (_seasonNumber ??
                          resumeItem?.seasonNumber ??
                          seasons.first.seasonNumber),
                  orElse: () => seasons.first,
                );
          final resumeEpisode = resumeItem == null
              ? null
              : _episodeMatchingResume(info, resumeItem);

          final seasonEpisodes = selectedSeason?.episodes ?? const [];
          final seasonNum = selectedSeason?.seasonNumber;
          if (_activeShell.origin == MediaOrigin.customCatalog &&
              seasonEpisodes.isNotEmpty &&
              !_loadingSeason &&
              seasonNum != null &&
              _progressiveSeason != seasonNum) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _progressiveSeason == seasonNum) return;
              _scheduleProgressiveFill(
                library,
                seasonEpisodes,
                seasonNumber: seasonNum,
                prioritize: resumeEpisode,
              );
            });
          }

          // "Only downloaded" filter: constrain the season list to seasons with
          // at least one downloaded episode, and the episode list below to the
          // downloaded rows of the selected season.
          final downloadedEps = library.downloadedEpisodesForSeries(
            _activeShell,
          );
          final hasAnyDownloaded = downloadedEps.isNotEmpty;
          final downloadedKeys = {
            for (final ep in downloadedEps)
              '${ep.seasonNumber ?? 0}:${ep.episodeNumber ?? 0}',
          };
          final filteredSeasons = _onlyDownloaded && hasAnyDownloaded
              ? seasons
                    .where(
                      (s) => downloadedEps.any(
                        (ep) => (ep.seasonNumber ?? 0) == s.seasonNumber,
                      ),
                    )
                    .toList()
              : seasons;
          final filteredSelectedSeason = filteredSeasons.isEmpty
              ? null
              : filteredSeasons.firstWhere(
                  (s) =>
                      s.seasonNumber ==
                      (_seasonNumber ??
                          resumeItem?.seasonNumber ??
                          filteredSeasons.first.seasonNumber),
                  orElse: () => filteredSeasons.first,
                );
          final filteredSeasonEpisodes =
              filteredSelectedSeason?.episodes ?? const [];
          final displaySeasonEpisodes = _onlyDownloaded && hasAnyDownloaded
              ? filteredSeasonEpisodes
                    .where(
                      (ep) => downloadedKeys.contains(
                        '${ep.seasonNumber}:${ep.episodeNum}',
                      ),
                    )
                    .toList()
              : filteredSeasonEpisodes;
          final seasonUpcomingCount =
              displaySeasonEpisodes.where((e) => e.isUpcoming).length;
          final seasonFooterLabel = seasonUpcomingCount > 0
              ? context.l10n.episodesAiredAndUpcoming(
                  displaySeasonEpisodes.length - seasonUpcomingCount,
                  seasonUpcomingCount,
                )
              : '${displaySeasonEpisodes.length} ${context.l10n.episodes}';

          final poster =
              details?.posterUrl ?? info.coverUrl ?? _activeShell.artUrl;
          final backdrop =
              info.backdropUrl ??
              details?.backdropUrl ??
              info.coverUrl ??
              _activeShell.backdropUrl ??
              _activeShell.posterUrl;
          final plot = (details?.plot ?? info.plot)?.trim();
          final rating = details?.rating ?? info.rating;
          final year =
              details?.year ??
              _yearFromRelease(info.releaseDate ?? details?.releaseDate);
          final contentRating =
              details?.contentRating ?? _activeShell.contentRating;
          final studio = details?.studio ?? _activeShell.studio;
          final genres = details?.genres.isNotEmpty == true
              ? details!.genres
              : _genresFromInfo(info.genre);
          final title = details?.title.isNotEmpty == true
              ? details!.title
              : info.title;
          final preferredLangs = context
              .read<LocaleController>()
              .preferredContentLanguageCodes;
          final familyLayout = library.vodFamilyLayoutFor(_activeShell);
          final playTarget =
              resumeEpisode ??
              (seasonEpisodes.isNotEmpty ? seasonEpisodes.first : null);
          final playLabel = resumeItem != null
              ? _resumeLabel(context, resumeItem)
              : context.l10n.play;

          return RefreshIndicator(
            color: AppColors.accent,
            onRefresh: () => _pullRefresh(library),
            child: CustomScrollView(
              key: PageStorageKey<String>('series-scroll-${_activeShell.id}'),
              physics: const AlwaysScrollableScrollPhysics(),
              // Build a few off-screen episode rows so resolve can warm ahead.
              cacheExtent: 900,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 240,
                  backgroundColor: AppColors.bg,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (backdrop != null && backdrop.isNotEmpty)
                          JavpArt(url: backdrop, decodeWidth: 1080)
                        else
                          Container(color: AppColors.surfaceHigh),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xFF0B0C0F)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (poster != null && poster.isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 110,
                                  height: 165,
                                  child: JavpArt(url: poster, decodeWidth: 330),
                                ),
                              )
                            else
                              Container(
                                width: 110,
                                height: 165,
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceHigh,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.tv_outlined),
                              ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    [
                                      if (year != null) '$year',
                                      if (contentRating != null &&
                                          contentRating.isNotEmpty)
                                        contentRating,
                                      if (rating != null && rating > 0)
                                        '\u2605 ${rating.toStringAsFixed(1)}',
                                      if (seasons.isNotEmpty)
                                        '${seasons.length} ${context.l10n.seasons}',
                                      if (info.upcomingEpisodeCount > 0)
                                        context.l10n.episodesAiredAndUpcoming(
                                          info.airedEpisodeCount,
                                          info.upcomingEpisodeCount,
                                        )
                                      else if (info.episodeCount > 0)
                                        '${info.episodeCount} ${context.l10n.episodes}',
                                      if (studio != null && studio.isNotEmpty)
                                        studio,
                                      if (!familyLayout.hasMultipleSources)
                                        library.sourceLabelFor(_activeShell),
                                    ].join(' · '),
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                  if (genres.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (final g in genres.take(6))
                                          Chip(
                                            label: Text(g),
                                            visualDensity:
                                                VisualDensity.compact,
                                            backgroundColor:
                                                AppColors.surfaceHigh,
                                            side: BorderSide.none,
                                            labelStyle: const TextStyle(
                                              fontSize: 12,
                                              color: AppColors.text,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                  VodAvailabilityLine(
                                    layout: familyLayout,
                                    preferredLangs: preferredLangs,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            AppButton(
                              onPressed:
                                  playTarget == null && resumeItem == null
                                  ? null
                                  : () async {
                                      if (resumeEpisode != null) {
                                        await _playEpisode(
                                          library: library,
                                          episode: resumeEpisode,
                                        );
                                        return;
                                      }
                                      if (playTarget != null) {
                                        await _playEpisode(
                                          library: library,
                                          episode: playTarget,
                                        );
                                        return;
                                      }
                                      if (!mounted) return;
                                      context.push(
                                        '/player',
                                        extra: resumeItem,
                                      );
                                    },
                              icon: Icons.play_arrow_rounded,
                              label: playLabel,
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  library.toggleWatchlist(_activeShell),
                              icon: Icon(
                                saved
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_border_rounded,
                              ),
                              label: Text(
                                saved
                                    ? context.l10n.inMyList
                                    : context.l10n.myList,
                              ),
                            ),
                            if (seasons.isNotEmpty)
                              OutlinedButton.icon(
                                onPressed: () => _showSeriesDownloadOptions(
                                  library: library,
                                  info: info,
                                  selectedSeason: selectedSeason,
                                ),
                                icon: const Icon(Icons.download_rounded),
                                label: Text(context.l10n.download),
                              ),
                          ],
                        ),
                        if (plot != null && plot.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          Text(
                            context.l10n.overview,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          _ExpandableDescription(
                            text: plot,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              height: 1.45,
                            ),
                          ),
                        ],
                        if (cast.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          Text(
                            context.l10n.cast,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 120,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: cast.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, i) {
                                final c = cast[i];
                                return SizedBox(
                                  width: 88,
                                  child: Column(
                                    children: [
                                      CircleAvatar(
                                        radius: 32,
                                        backgroundColor: AppColors.surfaceHigh,
                                        backgroundImage: c.profileUrl != null
                                            ? NetworkImage(c.profileUrl!)
                                            : null,
                                        child: c.profileUrl == null
                                            ? Text(
                                                c.name.isEmpty
                                                    ? '?'
                                                    : c.name.characters.first,
                                              )
                                            : null,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        c.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (c.character != null)
                                        Text(
                                          c.character!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                        if (seasons.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  context.l10n.episodes,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              if (hasAnyDownloaded)
                                FilterChip(
                                  label: Text(context.l10n.onlyDownloaded),
                                  selected: _onlyDownloaded,
                                  onSelected: (v) =>
                                      setState(() => _onlyDownloaded = v),
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selectedColor: AppColors.accent,
                                  backgroundColor: AppColors.surfaceHigh,
                                  labelStyle: TextStyle(
                                    color: _onlyDownloaded
                                        ? Colors.white
                                        : AppColors.text,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                  side: BorderSide(
                                    color: _onlyDownloaded
                                        ? AppColors.accent
                                        : AppColors.border,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (filteredSeasons.isNotEmpty)
                  SliverToBoxAdapter(
                    child: SeasonChipSlider(
                      seasons: filteredSeasons,
                      selectedSeasonNumber:
                          filteredSelectedSeason?.seasonNumber,
                      onSelected: (seasonNumber) =>
                          _selectSeason(library, seasonNumber),
                    ),
                  ),
                if (_loadingSeason ||
                    _hydratingEpisodes ||
                    (!_infoHasEpisodes(info) && !_episodeHydrationStarted))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const LinearProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.loadingEllipsis,
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (filteredSelectedSeason == null ||
                    filteredSelectedSeason.episodes.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        context.l10n.noEpisodesFound,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else if (_onlyDownloaded && displaySeasonEpisodes.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        context.l10n.noEpisodesFound,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else ...[
                  ..._episodePreviewSlivers(
                    context: context,
                    library: library,
                    info: info,
                    episodes: displaySeasonEpisodes,
                    resumeEpisode: resumeEpisode,
                    resumeItem: resumeItem,
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                      child: Text(
                        seasonFooterLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _episodePreviewSlivers({
    required BuildContext context,
    required LibraryProvider library,
    required SeriesInfo info,
    required List<SeriesEpisode> episodes,
    required SeriesEpisode? resumeEpisode,
    required MediaItem? resumeItem,
  }) {
    final contentW = AdaptiveLayout.contentWidth(context);
    final columns = _episodeCardColumns(contentW);
    const pad = AppLayout.gutter;
    const gap = 12.0;

    final compact = columns <= 1;

    Widget buildCard(int index) {
      final episode = library.resolvedEpisodeFor(
        series: _activeShell,
        episode: episodes[index],
      );
      // Viewport (+ cacheExtent) builds enqueue background resolve.
      if (_shouldAutoResolve(library, episode)) {
        _enqueueEpisodePrefetch(library, episode);
      }
      return _buildEpisodePreviewCard(
        context: context,
        library: library,
        info: info,
        episode: episode,
        resumeEpisode: resumeEpisode,
        resumeItem: resumeItem,
        compact: compact,
      );
    }

    if (compact) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(pad, 4, pad, 0),
          sliver: SliverList.separated(
            itemCount: episodes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => buildCard(index),
          ),
        ),
      ];
    }

    // Row-based grid (not SliverGrid): fixed childAspectRatio always reserved
    // ~118px for plot even when empty. Top-aligned rows let each card shrink.
    final rowCount = (episodes.length + columns - 1) ~/ columns;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(pad, 4, pad, 0),
        sliver: SliverList.separated(
          itemCount: rowCount,
          separatorBuilder: (_, _) => const SizedBox(height: 16),
          itemBuilder: (context, rowIndex) {
            final start = rowIndex * columns;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) const SizedBox(width: gap),
                  Expanded(
                    child: start + col < episodes.length
                        ? buildCard(start + col)
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ];
  }

  static int _episodeCardColumns(double width) {
    if (width >= 1200) return 4;
    if (width >= 900) return 3;
    if (width >= 560) return 2;
    return 1;
  }

  Widget _buildEpisodePreviewCard({
    required BuildContext context,
    required LibraryProvider library,
    required SeriesInfo info,
    required SeriesEpisode episode,
    required SeriesEpisode? resumeEpisode,
    required MediaItem? resumeItem,
    bool compact = false,
  }) {
    final title = episode.title.trim().isEmpty
        ? context.l10n.episodeNumber(episode.episodeNum)
        : episode.title.trim();
    final variants = library.episodePlayVariants(
      series: _activeShell,
      episode: episode,
    );
    final preferred = library.preferredEpisodeVariant(
      series: _activeShell,
      episode: episode,
    );
    final playable = library.episodeMediaItem(
      series: _activeShell,
      episode: episode,
    );
    final unresolved = _needsCatalogResolve(episode);
    final autoResolve = _shouldAutoResolve(library, episode);
    // Play/Versions set [_resolvingEpisodeIds]; cold fill shows spinner on the
    // focused card only; warm prefetch uses [_prefetchInflightIds] (not the
    // permanent attempted set — that would spin forever on failed stubs).
    final resolving =
        _resolvingEpisodeIds.contains(episode.id) ||
        (_coldFillInProgress && _coldFocusEpisodeId == episode.id) ||
        (autoResolve &&
            library.isCustomCatalogSeriesWarm(_activeShell) &&
            _prefetchInflightIds.contains(episode.id));
    final watched = library.historyForSeriesEpisode(
      series: _activeShell,
      episode: episode,
    );
    final progress = watched?.progress ?? 0.0;
    final isWatched = progress >= 0.95;
    final isInProgress = progress > 0.02 && progress < 0.95;
    final isResumeTarget =
        resumeEpisode?.id == episode.id ||
        (resumeItem != null &&
            resumeItem.seasonNumber == episode.seasonNumber &&
            resumeItem.episodeNumber == episode.episodeNum);

    // Keep the primary meta line short: episode · duration · status/versions.
    // Full release labels belong in the Versions sheet, not jammed here.
    final metaParts = <String>[
      context.l10n.episodeNumber(episode.episodeNum),
      if (episode.isUpcoming)
        context.l10n.notAiredYet
      else if (episode.duration != null && episode.duration!.inSeconds > 0)
        context.l10n.minutesShort(
          episode.duration!.inMinutes.clamp(1, 24 * 60),
        ),
      if (!episode.isUpcoming && isWatched)
        context.l10n.watchedStatus
      else if (!episode.isUpcoming && isInProgress)
        context.l10n.percentWatched((progress * 100).round())
      else if (!episode.isUpcoming && resolving)
        context.l10n.resolvingEllipsis
      else if (!episode.isUpcoming && unresolved)
        context.l10n.loadingEllipsis
      else if (!episode.isUpcoming &&
          variants.length > 1 &&
          variants.first.id.startsWith('msq-'))
        preferred?.label ?? context.l10n.quality
      else if (!episode.isUpcoming && variants.length > 1)
        context.l10n.versionsCount(variants.length),
    ];

    final plot = episode.plot?.trim();
    // Prefer per-episode still when the catalog/source provides one.
    final thumb = episode.thumbnailUrl?.trim();
    final thumbUrl = (thumb != null && thumb.isNotEmpty)
        ? thumb
        : _activeShell.artUrl;
    final episodeLabel = context.l10n.episodeNumber(episode.episodeNum);
    final genericTitleMatch = RegExp(
      r'^(?:episode|épisode|ep\.?)\s*0*(\d+)$',
      caseSensitive: false,
    ).firstMatch(title);
    final titleLooksGeneric =
        title == episodeLabel ||
        (genericTitleMatch != null &&
            int.tryParse(genericTitleMatch.group(1)!) == episode.episodeNum);
    // Avoid "Épisode N" meta + "Episode N" title when the bridge has no real title.
    final displayTitle = titleLooksGeneric ? null : title;

    Future<void> openActions() async {
      final item =
          playable ??
          await library.ensureEpisodePlayable(
            series: _activeShell,
            episode: episode,
          );
      if (!mounted) return;
      await _showEpisodeDownloadSheet(
        library: library,
        info: info,
        episode: episode,
        playable: item,
      );
    }

    final card = _EpisodePreviewCard(
      title: displayTitle,
      meta: metaParts.join(' \u00b7 '),
      plot: (plot != null && plot.isNotEmpty) ? plot : null,
      thumbnailUrl: thumbUrl,
      compact: compact,
      isWatched: isWatched,
      isInProgress: isInProgress,
      progress: progress,
      metaAccent: isInProgress || isResumeTarget,
      versionsButton: (!resolving && (variants.length > 1 || unresolved))
          ? IconButton(
              tooltip: unresolved
                  ? context.l10n.resolveVersions
                  : variants.isNotEmpty && variants.first.id.startsWith('msq-')
                  ? context.l10n.chooseQuality
                  : context.l10n.chooseVersion,
              icon: Icon(
                unresolved
                    ? Icons.layers_outlined
                    : variants.isNotEmpty &&
                          variants.first.id.startsWith('msq-')
                    ? Icons.high_quality_rounded
                    : Icons.layers_rounded,
              ),
              color: AppColors.accent,
              visualDensity: VisualDensity.compact,
              onPressed: () => _playEpisode(
                library: library,
                episode: episode,
                pickVersion: true,
              ),
            )
          : null,
      downloadButton: resolving
          ? const SizedBox(
              width: 36,
              height: 36,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : playable == null
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                isInProgress
                    ? Icons.play_circle_fill_rounded
                    : Icons.play_circle_outline_rounded,
                color: AppColors.accent,
              ),
            )
          : DownloadStatusButton(
              item: playable,
              foregroundColor: compact ? AppColors.accent : Colors.white,
              onEnqueue: () async {
                final item = await library.ensureEpisodePlayable(
                  series: _activeShell,
                  episode: episode,
                );
                if (!context.mounted || item == null) return;
                await enqueueDownloadWithFeedback(context, library, item);
              },
            ),
      showResumeButton: compact && isResumeTarget,
      onPlay: () => _playEpisode(library: library, episode: episode),
      onLongPress: openActions,
    );

    if (!TvPlatform.isAndroidTv) return card;
    return TvFocusable(
      borderRadius: 10,
      onSelect: () => _playEpisode(library: library, episode: episode),
      child: card,
    );
  }

  static int? _yearFromRelease(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(r'(\d{4})').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static List<String> _genresFromInfo(String? genre) {
    if (genre == null || genre.trim().isEmpty) return const [];
    return genre
        .split(RegExp(r'[,/|]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

class _EpisodePreviewCard extends StatelessWidget {
  const _EpisodePreviewCard({
    required this.meta,
    required this.thumbnailUrl,
    required this.isWatched,
    required this.isInProgress,
    required this.progress,
    required this.metaAccent,
    required this.downloadButton,
    required this.onPlay,
    required this.onLongPress,
    this.compact = false,
    this.showResumeButton = false,
    this.title,
    this.plot,
    this.versionsButton,
  });

  final String? title;
  final String meta;
  final String? plot;
  final String? thumbnailUrl;
  final bool compact;
  final bool showResumeButton;
  final bool isWatched;
  final bool isInProgress;
  final double progress;
  final bool metaAccent;
  final Widget? versionsButton;
  final Widget downloadButton;
  final VoidCallback onPlay;
  final VoidCallback onLongPress;

  static const _compactThumbWidth = 128.0;
  static const _compactThumbHeight = _compactThumbWidth * 9 / 16;

  static ButtonStyle get _compactIconStyle => IconButton.styleFrom(
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.all(4),
    minimumSize: const Size(36, 36),
  );

  @override
  Widget build(BuildContext context) {
    final plotText = plot?.trim();
    final placeholder = ColoredBox(
      color: AppColors.surfaceHigh,
      child: Center(
        child: Icon(
          Icons.play_circle_outline_rounded,
          color: AppColors.textMuted.withValues(alpha: 0.7),
          size: compact ? 28 : 36,
        ),
      ),
    );

    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: isWatched ? 0.55 : 1,
            child: JavpArt(
              url: thumbnailUrl,
              decodeWidth: compact ? 320 : 640,
              fallback: placeholder,
            ),
          ),
          if (isWatched)
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.all(compact ? 6 : 8),
                child: Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.accent,
                  size: compact ? 18 : 22,
                ),
              ),
            ),
          if (isInProgress)
            Align(
              alignment: Alignment.bottomCenter,
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: Colors.black45,
                color: AppColors.accent,
              ),
            ),
          if (!compact)
            Positioned(
              top: 4,
              right: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [?versionsButton, downloadButton],
                ),
              ),
            ),
        ],
      ),
    );

    final metaStyle = TextStyle(
      fontSize: 12,
      color: metaAccent ? AppColors.accent : AppColors.textMuted,
    );
    final titleStyle = TextStyle(
      color: isWatched ? AppColors.textMuted : AppColors.text,
      fontWeight: FontWeight.w700,
      height: 1.25,
      fontSize: compact ? 14 : null,
    );
    final plotStyle = TextStyle(
      color: AppColors.textMuted,
      height: 1.35,
      fontSize: compact ? 12 : 13,
    );

    final titleAndPlot = <Widget>[
      if (title != null && title!.trim().isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(
          title!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      ],
      if (plotText != null && plotText.isNotEmpty) ...[
        SizedBox(height: compact ? 2 : 4),
        Text(
          plotText,
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: plotStyle,
        ),
      ],
    ];

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaStyle,
        ),
        ...titleAndPlot,
        if (compact && showResumeButton) ...[
          const SizedBox(height: 8),
          AppButton(
            size: AppButtonSize.sm,
            expand: true,
            icon: Icons.play_arrow_rounded,
            label: context.l10n.resume,
            onPressed: onPlay,
          ),
        ],
      ],
    );

    final compactActions = IconButtonTheme(
      data: IconButtonThemeData(style: _compactIconStyle),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [?versionsButton, downloadButton],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPlay,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: compact
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _compactThumbWidth,
                    height: _compactThumbHeight,
                    child: thumb,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: body),
                  SizedBox(
                    height: _compactThumbHeight,
                    child: Align(
                      alignment: Alignment.center,
                      child: compactActions,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(aspectRatio: 16 / 9, child: thumb),
                  const SizedBox(height: 8),
                  body,
                ],
              ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            const Spacer(),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(context.l10n.retry)),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _ExpandableDescription extends StatefulWidget {
  const _ExpandableDescription({
    required this.text,
    required this.style,
    this.collapsedLines = 3,
  });

  final String text;
  final TextStyle style;
  final int collapsedLines;

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : widget.collapsedLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                behavior: HitTestBehavior.opaque,
                child: Text(
                  _expanded ? context.l10n.showLess : context.l10n.showMore,
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
