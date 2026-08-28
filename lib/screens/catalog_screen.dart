import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/screens/catalog_category_screen.dart';
import 'package:javp/services/catalog_source_picker.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/iptv/live_category_pins.dart';
import 'package:javp/services/source_filter_selection.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/catalog_browse_controls.dart';
import 'package:javp/widgets/desktop/hover_scroll_row.dart';
import 'package:javp/widgets/horizontal_scroll_text.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:javp/widgets/section_header.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/source_filter_app_bar_chip.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/tv/tv_segment_bar.dart';
import 'package:javp/widgets/tv_source_picker_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Streaming browse: Movies | Series with poster shelves by category.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _scroll = ScrollController();
  final _categorySearch = TextEditingController();
  Widget? _frozenTree;
  Object? _frozenStamp;
  IptvCategoryKind _kind = IptvCategoryKind.vod;

  /// Shelf browse vs searchable category grid (with favorites).
  bool _categoriesView = false;

  /// Empty = all VOD sources (Catalog-local; Search keeps its own chips).
  Set<String> _sourceKeys = {};
  static const _prefsSourceKey = 'catalog.sourceFilterIds';

  /// Network demand warms ([ensureVodCategoryAvailable]).
  final Set<String> _fetching = {};

  /// In-flight SQLite shelf page probes from [_sampleFor] (not network).
  final Set<String> _probing = {};
  final Set<String> _attempted = {};
  int _attemptedRevision = -1;
  bool _warmQueued = false;
  bool _diskHydrateQueued = false;

  /// True from first Catalog paint until demand disk hydrate completes.
  bool _initialHydratePending = true;
  String? _lastUiStateLog;
  bool _deferredShelfRebuildScheduled = false;
  bool _forceShelfRebuild = false;

  /// Bounded sample cache (LinkedHashMap). Prune so scrolling hundreds of
  /// categories does not retain every visited shelf's poster sample.
  ///
  /// Kept across [vodCacheRevision] / group / Home-shelf bumps (stale-while-
  /// revalidate) so SyncEngine progress does not blank shelves into "Loading…".
  final Map<String, List<MediaItem>> _shelfCache = {};
  /// [vodCacheRevision] at which each [_shelfCache] entry was written.
  final Map<String, int> _shelfCacheAtRevision = {};
  int _shelfCacheRevision = -1;
  static const _shelfCacheMax = 48;

  /// Category ids with an in-flight background sample refresh (dedupe).
  final Set<String> _revalidating = {};

  /// Debounce category-grid filter so each keystroke does not rematerialize
  /// every shelf (list-search lag when filtering hundreds of categories).
  Timer? _categorySearchDebounce;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(_onTabChanged);
    _scroll.addListener(_onScroll);
    _categorySearch.addListener(_onCategorySearchChanged);
    unawaited(_restoreSourceFilter());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreBrowsePrefs());
    });
  }

  Future<void> _restoreBrowsePrefs() async {
    await context.read<LibraryProvider>().loadCatalogBrowsePrefs();
    if (!mounted) return;
    setState(() {
      _frozenTree = null;
      _forceShelfRebuild = true;
      _shelfCache.clear();
      _shelfCacheAtRevision.clear();
    });
  }

  Future<void> _setBrowse(CatalogBrowsePrefs next) async {
    setState(() {
      _frozenTree = null;
      _forceShelfRebuild = true;
      _shelfCache.clear();
      _shelfCacheAtRevision.clear();
    });
    await context.read<LibraryProvider>().setCatalogBrowsePrefs(next);
  }

  Future<void> _openBrowseFilters(LibraryProvider library) async {
    final genres = library.catalogBrowseGenreOptions(
      series: _kind == IptvCategoryKind.series,
    );
    await showCatalogBrowseSheet(
      context: context,
      prefs: library.catalogBrowsePrefs,
      genres: genres,
      onChanged: (next) => unawaited(_setBrowse(next)),
    );
  }

  Future<void> _restoreSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = decodeSourceSelection(prefs.getString(_prefsSourceKey));
    if (!mounted || decoded.isEmpty) return;
    setState(() {
      _sourceKeys = decoded;
      _frozenTree = null;
      _forceShelfRebuild = true;
    });
  }

  Future<void> _persistSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSourceKey, encodeSourceSelection(_sourceKeys));
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _categorySearch.removeListener(_onCategorySearchChanged);
    _categorySearchDebounce?.cancel();
    _categorySearch.dispose();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onCategorySearchChanged() {
    if (!_categoriesView) return;
    _categorySearchDebounce?.cancel();
    _categorySearchDebounce = Timer(const Duration(milliseconds: 160), () {
      if (!mounted || !_categoriesView) return;
      setState(() {
        _frozenTree = null;
        _forceShelfRebuild = true;
      });
    });
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    final next = _tabs.index == 1
        ? IptvCategoryKind.series
        : IptvCategoryKind.vod;
    if (next == _kind) return;
    setState(() {
      _kind = next;
      _fetching.clear();
      _probing.clear();
      _attempted.clear();
      _revalidating.clear();
      _shelfCache.clear();
      _shelfCacheAtRevision.clear();
      _shelfCacheRevision = -1;
      _frozenTree = null;
      _forceShelfRebuild = true;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients || _categoriesView) return;
    // Warm empty shelves near the viewport — no rematerialize.
    if (_warmQueued) return;
    _warmQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmQueued = false;
      if (!mounted || _categoriesView) return;
      final library = context.read<LibraryProvider>();
      _warmEmptyShelves(library, _categories(library));
    });
  }

  void _scheduleDeferredShelfRebuild() {
    if (_deferredShelfRebuildScheduled) return;
    _deferredShelfRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deferredShelfRebuildScheduled = false;
      if (!mounted) return;
      if (!ShellVisibility.isActiveOf(context)) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      // Don't rematerialize every shelf mid-fling — wait until scroll settles.
      if (_scroll.hasClients && _scroll.position.isScrollingNotifier.value) {
        void onScrollIdle() {
          _scroll.position.isScrollingNotifier.removeListener(onScrollIdle);
          if (!mounted) return;
          _scheduleDeferredShelfRebuild();
        }

        _scroll.position.isScrollingNotifier.addListener(onScrollIdle);
        return;
      }
      setState(() => _forceShelfRebuild = true);
    });
  }

  List<IptvCategory> _categories(LibraryProvider library) {
    final raw = _kind == IptvCategoryKind.series
        ? library.seriesCategories
        : library.vodCategories;
    final selected = _effectiveSourceKeys(library);
    final series = _kind == IptvCategoryKind.series;
    final scoped = selected.isEmpty
        ? raw
        : [
            for (final c in raw)
              if (selected.any(
                (id) => library.onDemandCategoryMatchesSource(
                  category: c,
                  sourceId: id,
                  series: series,
                ),
              ))
                c,
          ];
    return iptvCategoriesWithFavoritesFirst(
      scoped,
      library.favoriteCategoryIds,
    );
  }

  Set<String> _effectiveSourceKeys(LibraryProvider library) {
    final available = [
      for (final source in library.parentalVisibleSources)
        if (iptvSourceContributesCatalog(source)) source.id,
    ];
    return normalizeSourceSelection(_sourceKeys, availableIds: available);
  }

  String _sourceLabel(LibraryProvider library) {
    final selected = _effectiveSourceKeys(library);
    final byId = {for (final s in library.parentalVisibleSources) s.id: s.name};
    return sourceFilterChipLabel(
      selected: selected,
      nameForId: (id) => byId[id] ?? id,
      allLabel: context.l10n.allSources,
      nSourcesLabel: context.l10n.nSources,
    );
  }

  Color? _sourceFilterAccent(LibraryProvider library) {
    final selected = _effectiveSourceKeys(library);
    if (selected.length != 1) return null;
    return library.colorForSourceId(selected.single);
  }

  Future<void> _pickSource(LibraryProvider library) async {
    final selected = _effectiveSourceKeys(library);
    final chosen = await showTvSourcePickerSheet(
      context: context,
      sources: catalogPickerSources(
        sources: library.parentalVisibleSources,
        selectedIds: selected,
      ),
      selectedIds: selected,
      allowLiveFilter: false,
    );
    if (chosen == null || !mounted) return;
    final next = normalizeSourceSelection(
      chosen,
      availableIds: [
        for (final source in library.parentalVisibleSources)
          if (iptvSourceContributesCatalog(source)) source.id,
      ],
    );
    if (sourceSelectionStamp(next) == sourceSelectionStamp(_sourceKeys)) {
      return;
    }
    setState(() {
      _sourceKeys = next;
      _fetching.clear();
      _probing.clear();
      _attempted.clear();
      _revalidating.clear();
      _shelfCache.clear();
      _shelfCacheAtRevision.clear();
      _shelfCacheRevision = -1;
      _frozenTree = null;
      _forceShelfRebuild = true;
    });
    unawaited(_persistSourceFilter());
  }

  void _openCategory(IptvCategory category) {
    final keys = _effectiveSourceKeys(context.read<LibraryProvider>());
    context.push(
      '/catalog/category',
      extra: CatalogCategoryArgs(
        category: category,
        sourceKeys: keys.isEmpty ? null : keys,
      ),
    );
  }

  List<IptvCategory> _filteredCategories(LibraryProvider library) {
    final cats = _categories(library);
    final q = _categorySearch.text.trim().toLowerCase();
    if (q.isEmpty) return cats;
    return [
      for (final cat in cats)
        if (cat.displayName.toLowerCase().contains(q) ||
            cat.name.toLowerCase().contains(q))
          cat,
    ];
  }

  void _warmEmptyShelves(LibraryProvider library, List<IptvCategory> cats) {
    if (cats.isEmpty) return;
    // Estimate which shelves sit near the viewport (header + poster row).
    final shelfH =
        AdaptiveLayout.compactShelfHeight(
          context,
          portrait: library.displaySettings.moviesCoverGridPortrait,
        ) +
        56;
    final pixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final start = (pixels / shelfH).floor().clamp(0, cats.length - 1);
    var launched = 0;
    for (final cat in cats.skip(start).take(5)) {
      if (_fetching.contains(cat.id)) continue;
      if (_attempted.contains(cat.id)) continue;
      final sample = _sampleFor(library, cat);
      if (sample.isNotEmpty) {
        _attempted.add(cat.id);
        continue;
      }
      // Empty sync/cache sample: demand-warm. [_sampleFor] may have started a
      // SQLite probe in [_probing]; [ensureVodCategoryAvailable] re-checks disk
      // before networking, so do not bail on probes or empty shelves never warm.
      _fetching.add(cat.id);
      _attempted.add(cat.id);
      launched++;
      // Paint spinner immediately — do not wait for the async finally.
      if (mounted) {
        setState(() {
          _frozenTree = null;
          _forceShelfRebuild = true;
        });
      }
      unawaited(() async {
        try {
          await library.ensureVodCategoryAvailable(cat);
          if (!mounted) return;
          final sourceKeys = _effectiveSourceKeys(library);
          final key =
              '${_kind.name}:${cat.id}:${encodeSourceSelection(sourceKeys)}:${library.catalogBrowsePrefs.stamp}';
          if (library.hasVodDb) {
            final filled = await library.vodShelfSampleAsync(
              categoryName: cat.name,
              series: _kind == IptvCategoryKind.series,
              sourceKeys: sourceKeys.isEmpty ? null : sourceKeys,
              limit: 14,
              browse: library.catalogBrowsePrefs,
            );
            if (!mounted) return;
            // Write through — do not clear then re-probe (that flashed Loading).
            if (filled.isNotEmpty) {
              _shelfCache[key] = filled;
              _shelfCacheAtRevision[key] = library.vodCacheRevision;
            }
          }
        } finally {
          _fetching.remove(cat.id);
          if (mounted) {
            setState(() {
              _frozenTree = null;
              _forceShelfRebuild = true;
            });
          }
        }
      }());
      if (launched >= 3) break;
    }
  }

  bool _shelfLoading(LibraryProvider library, IptvCategory category) {
    // Background revalidate must not spin — [_CatalogShelf] only shows the
    // indicator when [items] is empty; keep that contract for cold empties.
    if (_revalidating.contains(category.id)) return false;
    if (_fetching.contains(category.id) || _probing.contains(category.id)) {
      return true;
    }
    // JSON-only demand wait. An existing SQLite catalog is queryable even
    // while Home's idle hydrate is still scheduled — do not spin every shelf.
    if (_initialHydratePending &&
        !library.isVodDiskHydrated &&
        !library.hasVodDb &&
        !library.isVodDiskHydrateIdleWaiting) {
      return true;
    }
    return false;
  }

  void _logCatalogUiState({
    required LibraryProvider library,
    required int categoryCount,
    required bool showSpinner,
    required Set<String> selectedSources,
  }) {
    final reason = library.vodCatalogLoadingReason(sourceIds: selectedSources);
    final state = showSpinner
        ? 'spinner'
        : categoryCount == 0
        ? 'empty'
        : 'content';
    final line =
        '$state cats=$categoryCount reason=$reason '
        'hydratePending=$_initialHydratePending '
        'hydrated=${library.isVodDiskHydrated} '
        'hydrating=${library.isVodDiskHydrating} '
        'idleWait=${library.isVodDiskHydrateIdleWaiting} '
        'loading=${library.loading}';
    if (line == _lastUiStateLog) return;
    _lastUiStateLog = line;
    JavpLog.i('vod', 'catalog ui $line');
  }

  @override
  Widget build(BuildContext context) {
    final active = ShellVisibility.isActive(context);
    // Freeze when Search/detail is pushed on top — otherwise shelves keep
    // scanning under the overlay and ANR the app.
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);
    final currentVodRevision = context.read<LibraryProvider>().vodCacheRevision;
    final currentShelfRevision =
        context.read<LibraryProvider>().homeVodShelfRevision;
    final currentGroupCacheRevision =
        context.read<LibraryProvider>().vodDbGroupCacheRevision;
    final attemptStamp = Object.hash(
      currentVodRevision,
      currentShelfRevision,
      currentGroupCacheRevision,
    );
    if (_attemptedRevision != attemptStamp) {
      _attemptedRevision = attemptStamp;
      // Allow empty shelves to warm again; keep non-empty [_shelfCache] so
      // posters stay visible while samples revalidate against the new revision.
      // Do not clear [_revalidating] — in-flight refreshes stamp
      // [_shelfCacheAtRevision] on completion.
      _attempted.clear();
      _shelfCacheRevision = currentVodRevision;
      _frozenTree = null;
      _forceShelfRebuild = true;
    }

    final stamp = Object.hash(
      context.select<LibraryProvider, int>(
        (l) => Object.hash(
          l.sources.length,
          l.sourcesEnabledRevision,
          l.sourcesAppearanceRevision,
          l.catalog.length,
          l.vodCacheRevision,
          l.vodBusyRevision,
          l.homeVodShelfRevision,
          l.vodDbGroupCacheRevision,
          l.vodCategories.length,
          l.seriesCategories.length,
          l.favoriteCategoryIds.length,
          Object.hashAll(l.favoriteCategoryIds),
          // Match Accueil: do not rematerialize every shelf when bootstrap
          // [loading] flips — empty-state spinner still reads [loading] live.
          l.displaySettings.moviesCoverOrientation,
          l.tmdbDiscoveryRevision,
          l.catalogBrowseStamp,
        ),
      ),
      _kind,
      _categoriesView,
      _categorySearch.text,
      sourceSelectionStamp(_sourceKeys),
      _initialHydratePending,
      Object.hashAll(_fetching),
      Object.hashAll(_probing),
    );

    // Shell tab hidden: keep Element tree; SkipLayout skips layout/paint.
    Widget keep(Widget child) =>
        keepShellTabTree(skip: active && covered, child: child);

    if (!active) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }
    // Player / search covering this branch: skip layout/paint but keep the
    // Element tree so collapsing the mini player does not remount shelves.
    if (covered) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }

    if (_frozenTree != null && _frozenStamp == stamp) {
      _forceShelfRebuild = false;
      return keep(_frozenTree!);
    }

    // Data changed (e.g. VOD hydrate) — keep the live Element tree this frame
    // so mid-scroll does not rebuild every shelf; rematerialize when idle.
    // Exception: empty-shelf loading (hydrate / prefetch / warm) must paint a
    // spinner now, not after scroll settles.
    if (_frozenTree != null && !_forceShelfRebuild) {
      final peek = context.read<LibraryProvider>();
      final busy =
          (_initialHydratePending &&
              !peek.isVodDiskHydrated &&
              !peek.hasVodDb &&
              !peek.isVodDiskHydrateIdleWaiting) ||
          _fetching.isNotEmpty ||
          _probing.isNotEmpty;
      if (!busy) {
        _scheduleDeferredShelfRebuild();
        return keep(_frozenTree!);
      }
    }
    _forceShelfRebuild = false;

    final library = context.read<LibraryProvider>();
    // Demand-load huge Xtream disk cache as soon as Catalog is visible —
    // Home bootstrap no longer hydrates it. Always force delay=0 so we open
    // any idle gate instead of sitting behind Home's 45s warm.
    if (!_diskHydrateQueued) {
      _diskHydrateQueued = true;
      _initialHydratePending = !library.isVodDiskHydrated;
      JavpLog.i(
        'vod',
        'catalog demand hydrate queued pending=$_initialHydratePending '
            'hydrated=${library.isVodDiskHydrated} '
            'idleWait=${library.isVodDiskHydrateIdleWaiting}',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await library.ensureVodDiskHydrated();
          // Do not block shelf paint on full group-index — shelves page SQLite
          // via vodShelfSampleAsync. Awaiting the index starved cold start when
          // sqflite was busy with sort-title rewrite / GROUP BY.
          unawaited(library.ensureVodGroupIndex());
        } finally {
          if (mounted) {
            setState(() {
              _initialHydratePending = false;
              _frozenTree = null;
              _forceShelfRebuild = true;
            });
          }
        }
      });
    }
    final vodSources = catalogPickerSources(
      sources: library.parentalVisibleSources,
      selectedIds: _sourceKeys,
    );
    final multiSource = vodSources.length > 1;
    final cats = _categories(library);
    final favSet = library.favoriteCategoryIds.toSet();
    final sourceLabel = _sourceLabel(library);
    final sourceFilterActive = _effectiveSourceKeys(library).isNotEmpty;
    final selectedSources = _effectiveSourceKeys(library);
    final shelfIndexById = <String, int>{
      for (var i = 0; i < cats.length; i++) cats[i].id: i,
    };

    if (!_categoriesView && !_warmQueued) {
      _warmQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _warmQueued = false;
        if (mounted) _warmEmptyShelves(library, cats);
      });
    }

    if (cats.isNotEmpty) {
      _logCatalogUiState(
        library: library,
        categoryCount: cats.length,
        showSpinner: false,
        selectedSources: selectedSources,
      );
    }

    final tree = Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        key: const PageStorageKey<String>('catalog-scroll'),
        controller: _scroll,
        // Viewport + ~1–2 shelves. Larger values pin more MediaTiles/GPU.
        scrollCacheExtent: const ScrollCacheExtent.pixels(600),
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            // Theme appBar is transparent (Home hero); floating chrome must
            // cover shelves while it hides/snaps back over scrolling content.
            backgroundColor: AppColors.bg,
            surfaceTintColor: Colors.transparent,
            title: Text(
              context.l10n.navCatalog,
              style: Theme.of(
                context,
              ).appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
            ),
            actions: [
              if (multiSource)
                SourceFilterAppBarChip(
                  label: sourceLabel,
                  active: sourceFilterActive,
                  accentColor: _sourceFilterAccent(library),
                  onTap: () => unawaited(_pickSource(library)),
                ),
              if (TvPlatform.isAndroidTv) ...[
                TvFocusable(
                  borderRadius: 24,
                  onSelect: () => setState(() {
                    _categoriesView = !_categoriesView;
                    _frozenTree = null;
                    _forceShelfRebuild = true;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      _categoriesView
                          ? Icons.view_agenda_outlined
                          : Icons.grid_view_rounded,
                    ),
                  ),
                ),
                TvFocusable(
                  borderRadius: 24,
                  onSelect: () => context.push('/search'),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.search_rounded),
                  ),
                ),
                TvFocusable(
                  borderRadius: 24,
                  onSelect: () => context.push('/mylist'),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.bookmarks_outlined),
                  ),
                ),
              ] else ...[
                IconButton(
                  tooltip: _categoriesView
                      ? context.l10n.navCatalog
                      : context.l10n.categories,
                  onPressed: () => setState(() {
                    _categoriesView = !_categoriesView;
                    _frozenTree = null;
                    _forceShelfRebuild = true;
                  }),
                  icon: Icon(
                    _categoriesView
                        ? Icons.view_agenda_outlined
                        : Icons.grid_view_rounded,
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.search,
                  onPressed: () => context.push('/search'),
                  icon: const Icon(Icons.search_rounded),
                ),
                IconButton(
                  tooltip: context.l10n.myList,
                  onPressed: () => context.push('/mylist'),
                  icon: const Icon(Icons.bookmarks_outlined),
                ),
              ],
            ],
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(
                (TvPlatform.isAndroidTv ? 56 : 36) + 48,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TvPlatform.isAndroidTv
                      ? AnimatedBuilder(
                          animation: _tabs,
                          builder: (context, _) => TvSegmentBar(
                            labels: [context.l10n.movies, context.l10n.series],
                            index: _tabs.index,
                            onChanged: (i) => _tabs.animateTo(i),
                          ),
                        )
                      : TabBar(
                          controller: _tabs,
                          indicatorColor: AppColors.accent,
                          labelColor: AppColors.text,
                          unselectedLabelColor: AppColors.textMuted,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          tabs: [
                            Tab(height: 32, text: context.l10n.movies),
                            Tab(height: 32, text: context.l10n.series),
                          ],
                        ),
                  CatalogBrowseBar(
                    prefs: library.catalogBrowsePrefs,
                    onChanged: (next) => unawaited(_setBrowse(next)),
                    onOpenFilters: () => unawaited(_openBrowseFilters(library)),
                  ),
                ],
              ),
            ),
          ),
          if (cats.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: () {
                    final showSpinner =
                        library.loading ||
                        (_initialHydratePending &&
                            !library.isVodDiskHydrated &&
                            !library.hasVodDb &&
                            !library.isVodDiskHydrateIdleWaiting) ||
                        library.isVodCatalogLoading(sourceIds: selectedSources);
                    _logCatalogUiState(
                      library: library,
                      categoryCount: 0,
                      showSpinner: showSpinner,
                      selectedSources: selectedSources,
                    );
                    return showSpinner
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                context.l10n.loadingCategories,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            context.l10n.noCategoriesYet,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.textMuted),
                          );
                  }(),
                ),
              ),
            )
          else if (_categoriesView)
            ..._categoryListSlivers(context, library, favSet)
          else ...[
            ..._discoveryShelfSlivers(context, library),
            // Virtualized vertical shelves: off-screen rows dispose (unlike the
            // old eager `for … SliverToBoxAdapter` path that pinned every
            // visited category + nested HoverScrollRow / images).
            // Empty shelves still use [_shelfLoading] → spinner + Loading…
            // while hydrate / prefetch / warm is busy (idle+empty only then).
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final cat = cats[index];
                  return _CatalogShelf(
                    key: ValueKey<String>('shelf-${_kind.name}-${cat.id}'),
                    category: cat,
                    kind: _kind,
                    items: _sampleFor(library, cat),
                    loading: _shelfLoading(library, cat),
                    starred: favSet.contains(cat.id),
                    library: library,
                    onOpenCategory: () => _openCategory(cat),
                    onToggleFavorite: () => library.toggleFavoriteCategory(cat),
                    onOpenItem: (item) => _openItem(context, item),
                  );
                },
                childCount: cats.length,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: true,
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<String>) return null;
                  final id = key.value;
                  final prefix = 'shelf-${_kind.name}-';
                  if (!id.startsWith(prefix)) return null;
                  return shelfIndexById[id.substring(prefix.length)];
                },
              ),
            ),
            SliverToBoxAdapter(child: MiniPlayerScrollClearance()),
          ],
        ],
      ),
    );
    _frozenTree = tree;
    _frozenStamp = stamp;
    return keep(tree);
  }

  List<Widget> _categoryListSlivers(
    BuildContext context,
    LibraryProvider library,
    Set<String> favSet,
  ) {
    final filtered = _filteredCategories(library);
    final favCount = filtered.where((c) => favSet.contains(c.id)).length;
    final isTv = TvPlatform.isAndroidTv;
    final width = AdaptiveLayout.contentWidth(context);
    final crossAxisCount = isTv
        ? (width >= 1600
              ? 5
              : width >= 1200
              ? 4
              : 3)
        : AdaptiveLayout.liveCategoryColumns(context);
    final childAspectRatio = AdaptiveLayout.liveCategoryAspectRatio(context);
    final compact = isTv || AdaptiveLayout.useRail(context);
    final gap = isTv ? 6.0 : (compact ? 6.0 : 8.0);

    final header = filtered.isEmpty
        ? context.l10n.categories
        : favCount > 0
        ? '$favCount ${context.l10n.favorites.toLowerCase()} · ${filtered.length}'
        : '${filtered.length} ${context.l10n.categories.toLowerCase()}';

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppLayout.gutter,
            12,
            AppLayout.gutter,
            0,
          ),
          child: Text(
            header,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      if (!isTv)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.gutter,
              8,
              AppLayout.gutter,
              4,
            ),
            child: SizedBox(
              height: 36,
              child: JavpTextField(
                controller: _categorySearch,
                style: const TextStyle(color: AppColors.text, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: context.l10n.filterCategoriesHint,
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  suffixIcon: _categorySearch.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: context.l10n.clear,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: _categorySearch.clear,
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                  filled: true,
                  fillColor: AppColors.surfaceHigh,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 0,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ),
        ),
      if (filtered.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              context.l10n.noCategoriesMatch,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            isTv ? 10 : AppLayout.gutter,
            8,
            isTv ? 10 : AppLayout.gutter,
            8,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              childAspectRatio: childAspectRatio,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final cat = filtered[index];
                final starred = favSet.contains(cat.id);
                return _CatalogCategoryTile(
                  category: cat,
                  starred: starred,
                  onOpen: () => _openCategory(cat),
                  onToggleFavorite: () => library.toggleFavoriteCategory(cat),
                );
              },
              childCount: filtered.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        ),
      const SliverToBoxAdapter(child: MiniPlayerScrollClearance()),
    ];
  }

  List<MediaItem> _sampleFor(LibraryProvider library, IptvCategory category) {
    final rev = library.vodCacheRevision;
    // Advance revision stamp without wiping samples — stale posters stay up
    // until the async revalidate (or a sync hit) replaces them.
    if (rev != _shelfCacheRevision) {
      _shelfCacheRevision = rev;
    }
    final sourceKeys = _effectiveSourceKeys(library);
    final key =
        '${_kind.name}:${category.id}:${encodeSourceSelection(sourceKeys)}:${library.catalogBrowsePrefs.stamp}';
    final cached = _shelfCache.remove(key);
    if (cached != null) {
      // LRU bump — reinsert at end.
      _shelfCache[key] = cached;
      final atRev = _shelfCacheAtRevision[key];
      if (cached.isNotEmpty && atRev != rev) {
        _scheduleShelfRevalidate(
          library: library,
          category: category,
          key: key,
          sourceKeys: sourceKeys,
        );
      }
      return cached;
    }
    final items = library.vodShelfSample(
      categoryName: category.name,
      series: _kind == IptvCategoryKind.series,
      sourceKeys: sourceKeys.isEmpty ? null : sourceKeys,
      limit: 14,
      browse: library.catalogBrowsePrefs,
    );
    if (items.isEmpty &&
        library.hasVodDb &&
        !_probing.contains(category.id) &&
        !_fetching.contains(category.id) &&
        !_revalidating.contains(category.id)) {
      _probing.add(category.id);
      unawaited(() async {
        try {
          final filled = await library.vodShelfSampleAsync(
            categoryName: category.name,
            series: _kind == IptvCategoryKind.series,
            sourceKeys: sourceKeys.isEmpty ? null : sourceKeys,
            limit: 14,
            browse: library.catalogBrowsePrefs,
          );
          if (!mounted) return;
          if (filled.isNotEmpty) {
            _shelfCache[key] = filled;
            _shelfCacheAtRevision[key] = library.vodCacheRevision;
          }
          setState(() {
            _frozenTree = null;
            _forceShelfRebuild = true;
          });
        } finally {
          _probing.remove(category.id);
        }
      }());
    }
    if (items.isNotEmpty) {
      _shelfCache[key] = items;
      _shelfCacheAtRevision[key] = rev;
    }
    if (_shelfCache.length > _shelfCacheMax) {
      final drop = _shelfCache.length - (_shelfCacheMax ~/ 2);
      final stale = _shelfCache.keys.take(drop).toList(growable: false);
      for (final k in stale) {
        _shelfCache.remove(k);
        _shelfCacheAtRevision.remove(k);
      }
    }
    return items;
  }

  /// Refresh a painted shelf after VOD revision bumps without blanking tiles.
  void _scheduleShelfRevalidate({
    required LibraryProvider library,
    required IptvCategory category,
    required String key,
    required Set<String> sourceKeys,
  }) {
    if (!library.hasVodDb) return;
    if (_revalidating.contains(category.id) ||
        _probing.contains(category.id) ||
        _fetching.contains(category.id)) {
      return;
    }
    _revalidating.add(category.id);
    unawaited(() async {
      try {
        final filled = await library.vodShelfSampleAsync(
          categoryName: category.name,
          series: _kind == IptvCategoryKind.series,
          sourceKeys: sourceKeys.isEmpty ? null : sourceKeys,
          limit: 14,
          browse: library.catalogBrowsePrefs,
        );
        if (!mounted) return;
        // Stamp even when empty so we do not re-probe every frame on a
        // genuinely empty filtered shelf.
        _shelfCacheAtRevision[key] = library.vodCacheRevision;
        if (filled.isNotEmpty) {
          final prev = _shelfCache[key];
          _shelfCache[key] = filled;
          if (prev != null &&
              prev.length == filled.length &&
              _sameShelfIds(prev, filled)) {
            return;
          }
          setState(() {
            _frozenTree = null;
            _forceShelfRebuild = true;
          });
        }
      } finally {
        _revalidating.remove(category.id);
      }
    }());
  }

  static bool _sameShelfIds(List<MediaItem> a, List<MediaItem> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  static void _openItem(BuildContext context, MediaItem item) {
    if (item.isSeries) {
      context.push('/series', extra: item);
    } else {
      context.push('/title', extra: item);
    }
  }

  List<Widget> _discoveryShelfSlivers(
    BuildContext context,
    LibraryProvider library,
  ) {
    final wantSeries = _kind == IptvCategoryKind.series;
    bool matchesTab(MediaItem m) =>
        wantSeries ? m.isSeries : (!m.isSeries && !m.isEpisode);

    final selected = _effectiveSourceKeys(library);
    bool inSourceFilter(MediaItem m) {
      if (selected.isEmpty) return true;
      final sid = m.sourceId;
      if (sid == null || sid.isEmpty) return true;
      return selected.contains(sid);
    }

    final trending = library.applyCatalogBrowseItems(
      library.collapseHomeShelfItems(
        library.tmdbTrendingShelf.where(matchesTab).where(inSourceFilter),
        limit: 18,
      ),
      prefs: library.catalogBrowsePrefs,
      limit: 18,
    );
    final popularKeys = {for (final m in trending) library.shelfIdentityKey(m)};
    final popular = library.applyCatalogBrowseItems(
      library.collapseHomeShelfItems(
        library.tmdbPopularShelf
            .where(matchesTab)
            .where(inSourceFilter)
            .where((m) => !popularKeys.contains(library.shelfIdentityKey(m))),
        limit: 18,
      ),
      prefs: library.catalogBrowsePrefs,
      limit: 18,
    );
    final l10n = context.l10n;
    final portrait = library.displaySettings.moviesCoverPortrait;
    final out = <Widget>[];

    void addShelf(String title, String subtitle, List<MediaItem> items) {
      if (items.isEmpty) return;
      final usePortrait =
          portrait ?? items.any((i) => i.prefersPortraitArt && !i.isLive);
      out.add(
        SliverToBoxAdapter(
          child: SectionHeader(title: title, subtitle: subtitle),
        ),
      );
      out.add(
        SliverToBoxAdapter(
          child: SizedBox(
            height: AdaptiveLayout.compactShelfHeight(
              context,
              portrait: usePortrait,
            ),
            child: HoverScrollRow(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: AppLayout.shelfPadding,
                scrollCacheExtent: const ScrollCacheExtent.pixels(720),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return MediaTile(
                    item: item,
                    compact: true,
                    portrait: usePortrait,
                    sourceLabel: library.shelfSourceLabelFor(item),
                    onTap: () => _openItem(context, item),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    addShelf(l10n.trending, l10n.trendingInYourCatalog, trending);
    addShelf(l10n.popular, l10n.popularInYourCatalog, popular);

    if (out.isEmpty &&
        library.tmdb.isConfigured &&
        library.tmdbDiscoveryAttempted) {
      out.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: AppLayout.shelfPadding.copyWith(top: 8, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.trendingAndPopular,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.tmdbDiscoveryEmpty,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return out;
  }
}

/// One Catalog category shelf (header + horizontal poster row).
///
/// Built only while in the vertical viewport (+ [cacheExtent]); disposed when
/// scrolled away so nested [HoverScrollRow] controllers / tiles unload.
class _CatalogShelf extends StatelessWidget {
  const _CatalogShelf({
    super.key,
    required this.category,
    required this.kind,
    required this.items,
    required this.loading,
    required this.starred,
    required this.library,
    required this.onOpenCategory,
    required this.onToggleFavorite,
    required this.onOpenItem,
  });

  final IptvCategory category;
  final IptvCategoryKind kind;
  final List<MediaItem> items;
  final bool loading;
  final bool starred;
  final LibraryProvider library;
  final VoidCallback onOpenCategory;
  final VoidCallback onToggleFavorite;
  final void Function(MediaItem item) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final usePortrait = library.displaySettings.resolveMoviesCoverPortrait(
      items,
    );
    final shelfBodyHeight = AdaptiveLayout.compactShelfHeight(
      context,
      portrait: usePortrait,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeader(
          title: category.displayName,
          subtitle: kind == IptvCategoryKind.series
              ? context.l10n.series
              : context.l10n.movies,
          actionLabel: context.l10n.seeAll,
          onAction: onOpenCategory,
          favorited: starred,
          onFavorite: onToggleFavorite,
        ),
        SizedBox(
          height: shelfBodyHeight,
          child: items.isEmpty
              ? Padding(
                  padding: AppLayout.shelfPadding,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: loading
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                context.l10n.loadingEllipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: AppColors.textMuted),
                              ),
                            ],
                          )
                        : Text(
                            library.catalogBrowsePrefs.hideWatched ||
                                    library.catalogBrowsePrefs.hasGenreFilters
                                ? context.l10n.noTitlesMatchFilters
                                : context.l10n.noTitlesCachedYet,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: AppColors.textMuted),
                          ),
                  ),
                )
              : HoverScrollRow(
                  builder: (context, controller) => ListView.separated(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    padding: AppLayout.shelfPadding,
                    // Modest horizontal prefetch; vertical unload is the bound.
                    scrollCacheExtent: const ScrollCacheExtent.pixels(360),
                    addAutomaticKeepAlives: false,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final variants = library.vodVariantCountFor(item);
                      return MediaTile(
                        item: item,
                        compact: true,
                        portrait: item.isLive ? false : usePortrait,
                        sourceLabel: library.shelfSourceLabelFor(item),
                        variantCount: variants > 1 ? variants : null,
                        onTap: () => onOpenItem(item),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _CatalogCategoryTile extends StatelessWidget {
  const _CatalogCategoryTile({
    required this.category,
    required this.starred,
    required this.onOpen,
    required this.onToggleFavorite,
  });

  final IptvCategory category;
  final bool starred;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final isTv = TvPlatform.isAndroidTv;
    final compact = isTv || AdaptiveLayout.useRail(context);
    final tile = Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(compact ? 8 : 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(compact ? 8 : 12),
        onTap: onOpen,
        onLongPress: onToggleFavorite,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 10 : 12,
            compact ? 6 : 8,
            compact ? 6 : 4,
            compact ? 6 : 8,
          ),
          child: Row(
            children: [
              Expanded(
                child: HorizontalScrollText(
                  text: category.displayName,
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 13 : 13,
                    height: 1.15,
                  ),
                ),
              ),
              IconButton(
                tooltip: starred
                    ? context.l10n.favorited
                    : context.l10n.favorite,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: compact ? 28 : 32,
                  minHeight: compact ? 28 : 32,
                ),
                onPressed: onToggleFavorite,
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: compact ? 16 : 20,
                  color: starred ? AppColors.accent : AppColors.textMuted,
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );

    if (!isTv) return tile;
    return TvFocusable(borderRadius: 8, onSelect: onOpen, child: tile);
  }
}
