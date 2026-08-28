import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/screens/tv/tv_remote_screen.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/filter_chips.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/source_color_picker.dart';
import 'package:provider/provider.dart';

enum _SearchKind { all, live, vod, series, epg }

/// App-wide search across local media, VOD/series cache, and query catalogs.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  String? _sourceKey;
  _SearchKind _kind = _SearchKind.all;
  List<MediaItem> _localHits = const [];
  List<MediaItem> _remoteHits = const [];
  List<MediaItem> _mergedHits = const [];
  Map<String, List<MediaItem>> _searchFamilies = const {};
  bool _searching = false;

  /// True after local hits paint while remote catalog/media-server search runs.
  bool _remotePending = false;
  Timer? _debounce;
  int _searchGen = 0;
  int _lastGroupingRevision = -1;
  int _lastEpgRevision = -1;
  int _lastVodRevision = -1;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    final q = _query.text.trim();
    if (q.isEmpty) {
      _searchGen++;
      setState(() {
        _localHits = const [];
        _remoteHits = const [];
        _mergedHits = const [];
        _searchFamilies = const {};
        _searching = false;
        _remotePending = false;
      });
      return;
    }
    // Do not setState here — rebuilding the hit list on every keystroke is what
    // made Search typing feel frozen (logs: FTS wait + live-page + chronic jank
    // while route stayed /home). Spinner starts when the debounced search runs.
    _debounce = Timer(const Duration(milliseconds: 280), _runSearch);
  }

  void _recomputeMerged(LibraryProvider library) {
    final raw = [..._localHits, ..._remoteHits];
    _mergedHits = library.collapseSearchHits(
      raw,
      limit: 80,
      query: _query.text,
    );
    _searchFamilies = library.vodSearchFamilyIndex(raw);
    library.mergeVodSearchFamilyOverlay(_searchFamilies);
  }

  /// When background Xtream TMDB enrich finishes, re-collapse without retyping.
  void _maybeRemergeAfterGrouping(LibraryProvider library, int groupingRev) {
    if (groupingRev == _lastGroupingRevision) return;
    final hadRevision = _lastGroupingRevision >= 0;
    _lastGroupingRevision = groupingRev;
    if (!hadRevision) return;
    if (_query.text.trim().isEmpty) return;
    if (_localHits.isEmpty && _remoteHits.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (library.vodGroupingRevision != groupingRev) return;
      setState(() => _recomputeMerged(library));
    });
  }

  Future<void> _runSearch() async {
    if (!mounted) return;
    final library = context.read<LibraryProvider>();
    final q = _query.text.trim();
    final sourceId = _sourceKey;
    final gen = ++_searchGen;
    if (q.isEmpty) {
      setState(() {
        _localHits = const [];
        _remoteHits = const [];
        _mergedHits = const [];
        _searchFamilies = const {};
        _searching = false;
        _remotePending = false;
      });
      return;
    }

    final remoteKey = sourceId == LibraryProvider.localSourceKey
        ? null
        : sourceId;
    final Future<List<MediaItem>> remoteFuture;
    final bool expectRemote;
    // Short queries: local FTS only. Custom catalog/media-server for qLen≤2 flooded
    // the UI isolate (logs: remote 3s + catalog saves while typing lagged).
    if (sourceId == LibraryProvider.localSourceKey || q.length < 3) {
      remoteFuture = Future.value(const <MediaItem>[]);
      expectRemote = false;
    } else {
      expectRemote = _expectsRemoteSearch(library, sourceId);
      remoteFuture = library.searchRemoteSources(
        q,
        sourceId: remoteKey,
        limit: 40,
        onPartial: (hits) {
          if (!mounted || gen != _searchGen) return;
          setState(() {
            _remoteHits = hits;
            _recomputeMerged(library);
          });
        },
      );
    }
    // One rebuild to show the spinner — after debounce, not per keystroke.
    if (mounted && gen == _searchGen) {
      setState(() {
        _searching = true;
        _remotePending = expectRemote;
      });
    }

    List<MediaItem> local = const [];
    try {
      local = await library.searchLocalLibrary(
        q,
        sourceKey: sourceId,
        limit: 60,
        collapse: false,
      );
    } catch (e) {
      debugPrint('Local search failed: $e');
    }
    if (!mounted || gen != _searchGen) return;
    setState(() {
      _localHits = local;
      _recomputeMerged(library);
      // Keep "searching" until remote finishes when we expect network hits.
      if (!expectRemote) {
        _searching = false;
        _remotePending = false;
      }
    });

    try {
      final hits = await remoteFuture;
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _remoteHits = hits;
        _recomputeMerged(library);
        _searching = false;
        _remotePending = false;
      });
    } catch (e) {
      debugPrint('Remote search failed: $e');
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _searching = false;
        _remotePending = false;
      });
    }
  }

  /// Progressive VOD ingest only — refresh FTS hits without cancelling remotes
  /// or flipping the spinner on every pack commit.
  Future<void> _refreshLocalSearchOnly() async {
    if (!mounted) return;
    final library = context.read<LibraryProvider>();
    final q = _query.text.trim();
    final sourceId = _sourceKey;
    if (q.isEmpty) return;
    final gen = _searchGen;
    List<MediaItem> local = const [];
    try {
      local = await library.searchLocalLibrary(
        q,
        sourceKey: sourceId,
        limit: 60,
        collapse: false,
      );
    } catch (e) {
      debugPrint('Local search refresh failed: $e');
      return;
    }
    if (!mounted || gen != _searchGen) return;
    if (_query.text.trim() != q) return;
    setState(() {
      _localHits = local;
      _recomputeMerged(library);
    });
  }

  List<MediaItem> get _results => _hitsOf(_kind, _mergedHits);

  static bool _isEpg(MediaItem item) =>
      item.tags.contains(LibraryProvider.epgSearchTag);

  static List<MediaItem> _hitsOf(_SearchKind kind, List<MediaItem> all) {
    switch (kind) {
      case _SearchKind.all:
        return all;
      case _SearchKind.live:
        return [
          for (final m in all)
            if (m.isLive && !_isEpg(m)) m,
        ];
      case _SearchKind.vod:
        return [
          for (final m in all)
            if (m.kind == MediaKind.vod && !m.isSeries && !m.isEpisode) m,
        ];
      case _SearchKind.series:
        return [
          for (final m in all)
            if (m.isSeries) m,
        ];
      case _SearchKind.epg:
        return [
          for (final m in all)
            if (_isEpg(m)) m,
        ];
    }
  }

  ({int all, int live, int vod, int series, int epg}) _kindCounts() {
    var live = 0, vod = 0, series = 0, epg = 0;
    for (final m in _mergedHits) {
      if (_isEpg(m)) {
        epg++;
      } else if (m.isSeries) {
        series++;
      } else if (m.isLive) {
        live++;
      } else if (m.kind == MediaKind.vod && !m.isEpisode) {
        vod++;
      }
    }
    return (
      all: _mergedHits.length,
      live: live,
      vod: vod,
      series: series,
      epg: epg,
    );
  }

  String _statusLine(LibraryProvider library, int count) {
    final syncing = library.syncingSourceLabels(
      onlySourceId: _sourceKey,
      limit: 3,
    );
    final pendingRemoteNames = _pendingRemoteSourceLabels(library);
    // Prefer "still syncing" once we have something to show — progressive
    // ingest is the usual reason Search feels stuck, not a blank spinner.
    if (count > 0 && syncing.isNotEmpty) {
      return context.l10n.resultsSourcesSyncing(count, syncing.join(', '));
    }
    if (_remotePending && pendingRemoteNames.isNotEmpty) {
      return context.l10n.resultsStillCheckingSources(
        count,
        pendingRemoteNames.join(', '),
      );
    }
    if (_searching || _remotePending) {
      return context.l10n.resultsSearching(count);
    }
    if (syncing.isNotEmpty) {
      return context.l10n.resultsSourcesSyncing(count, syncing.join(', '));
    }
    if (library.isVodPrefetching()) {
      return context.l10n.resultsCachingCatalog(count);
    }
    return context.l10n.resultsCount(count);
  }

  String _emptyMessage(LibraryProvider library) {
    final pendingRemoteNames = _pendingRemoteSourceLabels(library);
    if (_remotePending && pendingRemoteNames.isNotEmpty) {
      return context.l10n.searchingSources(pendingRemoteNames.join(', '));
    }
    if (_searching || _remotePending) return context.l10n.searching;
    final syncing = library.syncingSourceLabels(
      onlySourceId: _sourceKey,
      limit: 3,
    );
    if (syncing.isNotEmpty) {
      return context.l10n.resultsSourcesSyncing(0, syncing.join(', '));
    }
    if (library.isVodPrefetching()) {
      return context.l10n.resultsCachingCatalog(0);
    }
    if (_kind != _SearchKind.all && _mergedHits.isNotEmpty) {
      return context.l10n.noMatches;
    }
    if (library.vodCacheCount == 0 && library.sources.isNotEmpty) {
      return context.l10n.noMatchesYetOpenCatalog;
    }
    return context.l10n.noMatches;
  }

  /// Names of enabled remote catalogs / media servers still being queried.
  List<String> _pendingRemoteSourceLabels(LibraryProvider library) {
    if (!_remotePending) return const [];
    final out = <String>[];
    for (final source in library.sources) {
      if (!source.enabled) continue;
      if (_sourceKey != null && source.id != _sourceKey) continue;
      if (!_sourceSupportsRemoteSearch(source)) continue;
      final name = source.name.trim();
      if (name.isEmpty) continue;
      out.add(name);
      if (out.length >= 3) break;
    }
    return out;
  }

  static bool _sourceSupportsRemoteSearch(IptvSource source) {
    if (source.type.isMediaServer) return true;
    return source.type == IptvSourceType.custom &&
        (source.playlistUrl ?? '').trim().isNotEmpty;
  }

  bool _expectsRemoteSearch(LibraryProvider library, String? sourceId) {
    if (sourceId == LibraryProvider.localSourceKey) return false;
    if (sourceId != null) {
      for (final source in library.sources) {
        if (source.id != sourceId || !source.enabled) continue;
        return _sourceSupportsRemoteSearch(source);
      }
      return false;
    }
    return library.hasRemoteSearchTargets;
  }

  void _maybeResearchAfterEpg(int epgRev) {
    if (epgRev == _lastEpgRevision) return;
    final hadRevision = _lastEpgRevision >= 0;
    _lastEpgRevision = epgRev;
    if (!hadRevision) return;
    if (_query.text.trim().isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onQueryChanged(_query.text);
    });
  }

  /// Progressive ingest publishes FTS rows between commits. Keep the current
  /// query live without forcing the user to retype — local only, so in-flight
  /// remote searches are not cancelled on every pack.
  void _maybeResearchAfterVod(int vodRev) {
    if (vodRev == _lastVodRevision) return;
    final hadRevision = _lastVodRevision >= 0;
    _lastVodRevision = vodRev;
    if (!hadRevision) return;
    if (_query.text.trim().isEmpty) return;
    _debounce?.cancel();
    final delay = context.read<LibraryProvider>().isVodPrefetching()
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 450);
    _debounce = Timer(delay, () {
      unawaited(_refreshLocalSearchOnly());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Cheap listen — rebuild on progressive VOD commits so an open query
    // can pick up newly published FTS rows without rematerializing posters
    // on every 400-row transaction (re-search is debounced).
    final moviePortrait = context.select<LibraryProvider, bool>(
      (l) => l.displaySettings.moviesCoverGridPortrait,
    );
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.sources.length,
        l.sourcesEnabledRevision,
        l.sourcesAppearanceRevision,
        l.localMedia.isNotEmpty,
        l.isVodPrefetching(),
        l.vodCacheCount == 0,
        l.vodCacheRevision,
        l.vodGroupingRevision,
        l.epgRevision,
        l.syncStatusRevision,
        Object.hashAll(l.preferredVodVariants.values),
      ),
    );
    final library = context.read<LibraryProvider>();
    _maybeRemergeAfterGrouping(library, library.vodGroupingRevision);
    _maybeResearchAfterEpg(library.epgRevision);
    _maybeResearchAfterVod(library.vodCacheRevision);
    final results = _results;
    final counts = _kindCounts();
    final qActive = _query.text.trim().isNotEmpty;
    final sourceOptions = <FilterChipOption<String?>>[
      FilterChipOption(value: null, label: context.l10n.allSources),
      if (library.localMedia.isNotEmpty)
        FilterChipOption(
          value: LibraryProvider.localSourceKey,
          label: context.l10n.local,
        ),
      for (final source in library.sources)
        if (source.enabled)
          FilterChipOption(
            value: source.id,
            label: library.isSourceSyncActivity(source.id)
                ? '${source.name}…'
                : source.name,
          ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.search),
        actions: [
          if (phoneRemoteEntryAvailable)
            IconButton(
              tooltip: context.l10n.typeOnPhone,
              onPressed: () {
                unawaited(
                  openPhoneRemote(
                    context,
                    onSearch: (text) {
                      _query.text = text;
                      _query.selection = TextSelection.collapsed(
                        offset: text.length,
                      );
                      _onQueryChanged(text);
                    },
                  ),
                );
              },
              icon: const Icon(Icons.smartphone_rounded),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IptvSearchBar(
            controller: _query,
            hintText: context.l10n.searchHint,
            onChanged: _onQueryChanged,
            onClear: () {
              _searchGen++;
              setState(() {
                _localHits = const [];
                _remoteHits = const [];
                _mergedHits = const [];
                _searchFamilies = const {};
                _searching = false;
                _remotePending = false;
              });
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.gutter,
              8,
              AppLayout.gutter,
              8,
            ),
            child: Text(
              _query.text.trim().isEmpty
                  ? context.l10n.searchIdleHelp
                  : _statusLine(library, results.length),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
          FilterChips<_SearchKind>(
            options: [
              FilterChipOption(
                value: _SearchKind.all,
                label: qActive
                    ? '${context.l10n.all} ${counts.all}'
                    : context.l10n.all,
              ),
              FilterChipOption(
                value: _SearchKind.live,
                label: qActive
                    ? '${context.l10n.live} ${counts.live}'
                    : context.l10n.live,
              ),
              FilterChipOption(
                value: _SearchKind.vod,
                label: qActive
                    ? '${context.l10n.movies} ${counts.vod}'
                    : context.l10n.movies,
              ),
              FilterChipOption(
                value: _SearchKind.series,
                label: qActive
                    ? '${context.l10n.series} ${counts.series}'
                    : context.l10n.series,
              ),
              FilterChipOption(
                value: _SearchKind.epg,
                label: qActive
                    ? '${context.l10n.guide} ${counts.epg}'
                    : context.l10n.guide,
              ),
            ],
            selected: _kind,
            onSelected: (v) => setState(() => _kind = v),
          ),
          const SizedBox(height: 6),
          FilterChips<String?>(
            options: sourceOptions,
            selected: _sourceKey,
            onSelected: (v) {
              setState(() => _sourceKey = v);
              _onQueryChanged(_query.text);
            },
          ),
          Expanded(
            child: _query.text.trim().isEmpty
                ? Center(
                    child: Text(
                      context.l10n.searchHintAll,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : results.isEmpty
                ? Center(
                    child: Text(
                      _emptyMessage(library),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: AppLayout.pagePadding(),
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final item = results[index];
                      return _searchResultRow(
                        context,
                        library,
                        item,
                        moviePortrait: moviePortrait,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _searchResultRow(
    BuildContext context,
    LibraryProvider library,
    MediaItem item, {
    required bool moviePortrait,
  }) {
    final isEpg = _isEpg(item);
    final isMovie =
        item.kind == MediaKind.vod && !item.isSeries && !item.isEpisode;
    final variants = isMovie
        ? library.vodVariantsForSearch(item, familyIndex: _searchFamilies)
        : const <MediaItem>[];
    final playable = isMovie ? library.resolveVodVariant(item) : item;
    final title = isEpg
        ? item.title
        : (item.isLive || item.kind == MediaKind.catchup
              ? library.liveOrCatchupDisplayTitle(item)
              : (isMovie || item.isSeries
                    ? VodGrouping.displayTitle(playable)
                    : item.title));
    final art =
        playable.artUrlFor(portrait: moviePortrait) ?? playable.thumbnailUrl;
    final sourceIds = isMovie
        ? VodGrouping.uniqueSourceIds(variants)
        : const <String>[];
    final source = isMovie
        ? library.sourceLabelFor(playable)
        : library.sourceLabelFor(item);
    final nowProgram = !isEpg && item.isLive
        ? library.nowPlayingFor(item)
        : null;
    final liveCatchup =
        !isEpg && item.isLive && library.liveSupportsCatchup(item);
    final subtitle = isMovie
        ? (VodGrouping.searchHitSubtitle(
                variantCount: variants.length,
                sourceCount: sourceIds.length,
                versionsLabel: context.l10n.versionsCount(variants.length),
                sourceLabel: source,
              ) ??
              '')
        : isEpg
        ? (item.subtitle ?? '')
        : [
            if (nowProgram != null) ...[
              nowProgram.title,
              nowProgram.timeWindow,
            ] else if ((playable.subtitle?.trim().isNotEmpty == true))
              playable.subtitle!.trim()
            else if (source.isNotEmpty)
              source,
            if (liveCatchup) context.l10n.catchup,
          ].join(' · ');
    final sourceDots = isMovie && sourceIds.length > 1
        ? [
            for (final id in sourceIds)
              (
                label: _searchSourceLabel(library, id, variants),
                color: _searchSourceColor(library, id),
              ),
          ]
        : const <({String label, Color color})>[];
    final kindLabel = isEpg
        ? (item.tags.contains(LibraryProvider.epgSearchCatchupTag)
              ? context.l10n.catchup
              : context.l10n.guide)
        : item.isSeries
        ? context.l10n.series
        : liveCatchup
        ? context.l10n.catchup
        : item.isLive
        ? context.l10n.live
        : item.kind == MediaKind.vod
        ? context.l10n.movies
        : context.l10n.local;

    return GestureDetector(
      onSecondaryTapUp: (details) => showMediaItemActions(
        context: context,
        item: playable,
        anchor: details.globalPosition,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InkWell(
          onTap: () {
            if (playable.isSeries) {
              context.push('/series', extra: playable);
            } else if (isEpg) {
              unawaited(_openEpgSearchHit(library, item));
            } else if (playable.isLive ||
                playable.origin == MediaOrigin.localFile ||
                playable.kind == MediaKind.local) {
              context.push('/player', extra: playable);
            } else {
              context.push('/title', extra: playable);
            }
          },
          onLongPress: () =>
              showMediaItemActions(context: context, item: playable),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: art != null && art.isNotEmpty
                      ? JavpArt(url: art, decodeWidth: 96)
                      : ColoredBox(
                          color: AppColors.surfaceHigh,
                          child: Center(
                            child: Text(
                              kindLabel.isNotEmpty
                                  ? kindLabel[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    if (subtitle.isNotEmpty || sourceDots.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (subtitle.isNotEmpty)
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          if (sourceDots.isNotEmpty) ...[
                            if (subtitle.isNotEmpty) const SizedBox(width: 8),
                            _SearchSourceDots(sources: sourceDots),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  kindLabel.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEpgSearchHit(
    LibraryProvider library,
    MediaItem item,
  ) async {
    final program = library.epgProgramFromSearchItem(item);
    if (program == null) {
      if (!mounted) return;
      context.push('/player', extra: item);
      return;
    }
    final now = DateTime.now();
    final canCatchup =
        item.tags.contains(LibraryProvider.epgSearchCatchupTag) &&
        (program.end.isBefore(now) || program.isAiringAt(now));
    if (canCatchup) {
      final clip = await library.catchupItemAsync(
        channel: item,
        program: program,
      );
      if (!mounted) return;
      if (clip != null) {
        context.push('/player', extra: clip);
        return;
      }
    }
    if (!mounted) return;
    context.push('/player', extra: item);
  }
}

String _searchSourceLabel(
  LibraryProvider library,
  String sourceId,
  List<MediaItem> variants,
) {
  for (final v in variants) {
    if (v.sourceId?.trim() == sourceId) return library.sourceLabelFor(v);
  }
  return sourceId;
}

Color _searchSourceColor(LibraryProvider library, String sourceId) {
  return library.colorForSourceId(sourceId) ??
      kSourceColorPresets[sourceId.hashCode.abs() % kSourceColorPresets.length];
}

/// Compact source-color dots so Search can hint at catalogs without chips.
class _SearchSourceDots extends StatelessWidget {
  const _SearchSourceDots({required this.sources});

  final List<({String label, Color color})> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    const maxDots = 4;
    final shown = sources.take(maxDots).toList(growable: false);
    final extra = sources.length - shown.length;
    final names = sources.map((s) => s.label).join(', ');
    return Tooltip(
      message: names,
      child: Semantics(
        label: names,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              SourceColorDot(color: shown[i].color, size: 9),
            ],
            if (extra > 0) ...[
              const SizedBox(width: 4),
              Text(
                '+$extra',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
