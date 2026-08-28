import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/my_list_ui_prefs.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/simkl/simkl_match.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';
import 'package:javp/widgets/desktop/hover_marquee_text.dart';
import 'package:javp/widgets/filter_chips.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/poster_lift.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/tv/tv_segment_bar.dart';
import 'package:provider/provider.dart';

/// Watchlist + favorite channels — Catalog-style posters with search/filters.
///
/// Tracker merge: linked **SIMKL Watching**, **SIMKL Plan to Watch**,
/// **Trakt watchlist**, **Plex watchlist**, and **Letterboxd** (export import,
/// movies) appear beside the local shelf (source chips + badges).
class MyListScreen extends StatefulWidget {
  const MyListScreen({super.key, this.initialSource});

  /// Home Watching → See all (and similar) select this source chip.
  final MyListSourceFilter? initialSource;

  @override
  State<MyListScreen> createState() => _MyListScreenState();
}

class _MyListScreenState extends State<MyListScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Identity + length so add/remove rebuilds; EPG so “now playing” stays fresh.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        Object.hash(
          identityHashCode(l.watchlist),
          l.watchlist.length,
          identityHashCode(l.simklWatching),
          l.simklWatching.length,
          identityHashCode(l.simklPlanToWatch),
          l.simklPlanToWatch.length,
          identityHashCode(l.traktWatchlist),
          l.traktWatchlist.length,
          identityHashCode(l.plexWatchlist),
          l.plexWatchlist.length,
          identityHashCode(l.letterboxdWatchlist),
          l.letterboxdWatchlist.length,
        ),
        Object.hash(
          identityHashCode(l.serializdWatching),
          l.serializdWatching.length,
          identityHashCode(l.serializdWatchlist),
          l.serializdWatchlist.length,
          identityHashCode(l.betaseriesWatching),
          l.betaseriesWatching.length,
          identityHashCode(l.betaseriesPlan),
          l.betaseriesPlan.length,
        ),
        l.favoriteChannelIds.length,
        Object.hashAll(l.favoriteChannelIds),
        l.displaySettings.moviesCoverOrientation,
        l.epgRevision,
        l.simkl.isAuthenticated,
        l.trakt.isAuthenticated,
        l.hasPlexWatchlistSource,
        l.serializd.isAuthenticated,
        l.betaseries.isAuthenticated,
        l.hasLetterboxdImport,
      ),
    );
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final tabLabels = [l10n.myList, l10n.favorites];
    final moviePortrait = library.displaySettings.moviesCoverGridPortrait;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(
          l10n.myList,
          style: Theme.of(
            context,
          ).appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
        ),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(TvPlatform.isAndroidTv ? 56 : 36),
          child: TvPlatform.isAndroidTv
              ? AnimatedBuilder(
                  animation: _tabs,
                  builder: (context, _) => TvSegmentBar(
                    labels: tabLabels,
                    index: _tabs.index,
                    onChanged: (i) => _tabs.animateTo(i),
                  ),
                )
              : TabBar(
                  controller: _tabs,
                  indicatorColor: AppColors.accent,
                  labelColor: AppColors.text,
                  unselectedLabelColor: AppColors.textMuted,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  tabs: [
                    for (final label in tabLabels) Tab(height: 32, text: label),
                  ],
                ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _WatchlistTab(
            portrait: moviePortrait,
            initialSource: widget.initialSource,
          ),
          const _FavoritesTab(),
        ],
      ),
    );
  }
}

class _WatchlistTab extends StatefulWidget {
  const _WatchlistTab({required this.portrait, this.initialSource});

  final bool portrait;
  final MyListSourceFilter? initialSource;

  @override
  State<_WatchlistTab> createState() => _WatchlistTabState();
}

class _WatchlistTabState extends State<_WatchlistTab> {
  final _query = TextEditingController();
  late MyListUiPrefs _prefs;
  bool _prefsReady = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _prefs = applyMyListInitialSource(
      MyListUiPrefs.defaults,
      widget.initialSource,
    );
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final prefs = await context.read<LibraryProvider>().loadMyListUiPrefs();
    if (!mounted) return;
    setState(() {
      _prefs = applyMyListInitialSource(prefs, widget.initialSource);
      _prefsReady = true;
    });
  }

  Future<void> _setPrefs(MyListUiPrefs next) async {
    setState(() => _prefs = next);
    await context.read<LibraryProvider>().saveMyListUiPrefs(next);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matchesKind(MediaItem item) {
    switch (_prefs.kind) {
      case MyListKindFilter.all:
        return true;
      case MyListKindFilter.movies:
        return !item.isSeries &&
            !item.isEpisode &&
            !item.isLive &&
            item.kind != MediaKind.catchup;
      case MyListKindFilter.series:
        return item.isSeries;
    }
  }

  String _displayTitle(LibraryProvider library, MediaItem item) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      return library.liveOrCatchupDisplayTitle(item);
    }
    if (item.kind == MediaKind.vod || item.kind == MediaKind.series) {
      return VodGrouping.displayTitle(item);
    }
    return item.title;
  }

  List<MediaItem> _filtered(
    LibraryProvider library, {
    required MyListSourceFilter source,
  }) {
    var items = library.myListBrowseItems(source: source);
    items = items.where(_matchesKind).toList();
    final q = _query.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items
          .where((i) => _displayTitle(library, i).toLowerCase().contains(q))
          .toList();
    }
    switch (_prefs.sort) {
      case MyListSort.recentlyAdded:
        // myListBrowseItems keeps watchlist prepend order, then SIMKL.
        break;
      case MyListSort.titleAsc:
        items = List<MediaItem>.of(items)
          ..sort(
            (a, b) => _displayTitle(
              library,
              a,
            ).toLowerCase().compareTo(_displayTitle(library, b).toLowerCase()),
          );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final showWatchingChip =
        library.simkl.isAuthenticated || library.simklWatching.isNotEmpty;
    final showPlanChip =
        library.simkl.isAuthenticated || library.simklPlanToWatch.isNotEmpty;
    final showTraktChip =
        library.trakt.isAuthenticated || library.traktWatchlist.isNotEmpty;
    final showPlexChip =
        library.hasPlexWatchlistSource || library.plexWatchlist.isNotEmpty;
    final showLetterboxdChip = library.hasLetterboxdImport;
    final showSerializdWatchingChip =
        library.serializd.isAuthenticated ||
        library.serializdWatching.isNotEmpty;
    final showSerializdWatchlistChip =
        library.serializd.isAuthenticated ||
        library.serializdWatchlist.isNotEmpty;
    final showBetaseriesWatchingChip =
        library.betaseries.isAuthenticated ||
        library.betaseriesWatching.isNotEmpty;
    final showBetaseriesPlanChip =
        library.betaseries.isAuthenticated || library.betaseriesPlan.isNotEmpty;

    final kindOptions = <FilterChipOption<MyListKindFilter>>[
      FilterChipOption(value: MyListKindFilter.all, label: l10n.all),
      FilterChipOption(value: MyListKindFilter.movies, label: l10n.movies),
      FilterChipOption(value: MyListKindFilter.series, label: l10n.series),
    ];
    final sourceOptions = <FilterChipOption<MyListSourceFilter>>[
      FilterChipOption(value: MyListSourceFilter.all, label: l10n.allSources),
      FilterChipOption(value: MyListSourceFilter.local, label: l10n.local),
      if (showWatchingChip)
        FilterChipOption(
          value: MyListSourceFilter.simklWatching,
          label: l10n.myListSourceWatching,
        ),
      if (showPlanChip)
        FilterChipOption(
          value: MyListSourceFilter.simklPlan,
          label: l10n.myListSourcePlanToWatch,
        ),
      if (showTraktChip)
        FilterChipOption(
          value: MyListSourceFilter.trakt,
          label: l10n.myListSourceTrakt,
        ),
      if (showPlexChip)
        FilterChipOption(
          value: MyListSourceFilter.plex,
          label: l10n.myListSourcePlex,
        ),
      if (showLetterboxdChip)
        FilterChipOption(
          value: MyListSourceFilter.letterboxd,
          label: l10n.myListSourceLetterboxd,
        ),
      if (showSerializdWatchingChip)
        FilterChipOption(
          value: MyListSourceFilter.serializdWatching,
          label: l10n.myListSourceSerializdWatching,
        ),
      if (showSerializdWatchlistChip)
        FilterChipOption(
          value: MyListSourceFilter.serializdWatchlist,
          label: l10n.myListSourceSerializdWatchlist,
        ),
      if (showBetaseriesWatchingChip)
        FilterChipOption(
          value: MyListSourceFilter.betaseriesWatching,
          label: l10n.myListSourceBetaseriesWatching,
        ),
      if (showBetaseriesPlanChip)
        FilterChipOption(
          value: MyListSourceFilter.betaseriesPlan,
          label: l10n.myListSourceBetaseriesPlan,
        ),
    ];
    final sortOptions = <FilterChipOption<MyListSort>>[
      FilterChipOption(
        value: MyListSort.recentlyAdded,
        label: l10n.sortRecentlyAdded,
      ),
      FilterChipOption(value: MyListSort.titleAsc, label: l10n.sortTitleAz),
    ];

    // Clamp source if a tracker chip disappeared after unlink.
    final sourceSelected =
        sourceOptions.any((o) => o.value == _prefs.effectiveSource)
        ? _prefs.effectiveSource
        : MyListSourceFilter.all;
    final items = _filtered(library, source: sourceSelected);
    final localKeys = {
      for (final w in library.watchlist) library.shelfIdentityKey(w),
    };

    Widget emptyPane() {
      if (sourceSelected == MyListSourceFilter.simklWatching &&
          library.simklWatching.isEmpty) {
        return _EmptyPane(
          icon: Icons.cloud_outlined,
          title: l10n.watching,
          body: l10n.myListSimklEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.simklPlan &&
          library.simklPlanToWatch.isEmpty) {
        return _EmptyPane(
          icon: Icons.playlist_add_check_outlined,
          title: l10n.myListSourcePlanToWatch,
          body: l10n.myListPlanEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.trakt &&
          library.traktWatchlist.isEmpty) {
        return _EmptyPane(
          icon: Icons.bookmark_border_outlined,
          title: l10n.myListSourceTrakt,
          body: l10n.myListTraktEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.plex &&
          library.plexWatchlist.isEmpty) {
        return _EmptyPane(
          icon: Icons.grid_view_rounded,
          title: l10n.myListSourcePlex,
          body: l10n.myListPlexEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.letterboxd &&
          library.letterboxdWatchlist.isEmpty) {
        return _EmptyPane(
          icon: Icons.movie_filter_outlined,
          title: l10n.myListSourceLetterboxd,
          body: l10n.myListLetterboxdEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.serializdWatching &&
          library.serializdWatching.isEmpty) {
        return _EmptyPane(
          icon: Icons.live_tv_outlined,
          title: l10n.myListSourceSerializdWatching,
          body: l10n.myListSerializdEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.serializdWatchlist &&
          library.serializdWatchlist.isEmpty) {
        return _EmptyPane(
          icon: Icons.bookmark_add_outlined,
          title: l10n.myListSourceSerializdWatchlist,
          body: l10n.myListSerializdEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.betaseriesWatching &&
          library.betaseriesWatching.isEmpty) {
        return _EmptyPane(
          icon: Icons.cloud_outlined,
          title: l10n.myListSourceBetaseriesWatching,
          body: l10n.myListBetaseriesEmptyHelp,
        );
      }
      if (sourceSelected == MyListSourceFilter.betaseriesPlan &&
          library.betaseriesPlan.isEmpty) {
        return _EmptyPane(
          icon: Icons.playlist_add_check_outlined,
          title: l10n.myListSourceBetaseriesPlan,
          body: l10n.myListBetaseriesEmptyHelp,
        );
      }
      if (library.watchlist.isEmpty &&
          (sourceSelected == MyListSourceFilter.local ||
              (library.simklWatching.isEmpty &&
                  library.simklPlanToWatch.isEmpty &&
                  library.traktWatchlist.isEmpty &&
                  library.plexWatchlist.isEmpty &&
                  library.letterboxdWatchlist.isEmpty &&
                  library.serializdWatching.isEmpty &&
                  library.serializdWatchlist.isEmpty &&
                  library.betaseriesWatching.isEmpty &&
                  library.betaseriesPlan.isEmpty))) {
        return _EmptyPane(
          icon: Icons.bookmarks_outlined,
          title: l10n.yourShelfIsEmpty,
          body: l10n.myListEmptyHelp,
        );
      }
      return _EmptyPane(
        icon: Icons.filter_alt_off_outlined,
        title: l10n.noMatches,
        body: l10n.myListNoFilterMatches,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IptvSearchBar(controller: _query, hintText: l10n.myListSearchHint),
        const SizedBox(height: 8),
        FilterChips<MyListKindFilter>(
          options: kindOptions,
          selected: _prefs.kind,
          onSelected: (v) => _setPrefs(_prefs.copyWith(kind: v)),
        ),
        const SizedBox(height: 6),
        FilterChips<MyListSourceFilter>(
          options: sourceOptions,
          selected: sourceSelected,
          onSelected: (v) => _setPrefs(_prefs.copyWith(source: v)),
        ),
        const SizedBox(height: 6),
        FilterChips<MyListSort>(
          options: sortOptions,
          selected: _prefs.sort,
          onSelected: (v) => _setPrefs(_prefs.copyWith(sort: v)),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: !_prefsReady && items.isEmpty
              ? const SizedBox.shrink()
              : items.isEmpty
              ? emptyPane()
              : GridView.builder(
                  padding: AppLayout.pagePadding(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: AdaptiveLayout.posterGridColumns(
                      AdaptiveLayout.contentWidth(context),
                    ),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: AdaptiveLayout.posterGridChildAspectRatio(
                      portrait: widget.portrait,
                    ),
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final shell = isTrackerListShell(item);
                    final fromLocal = localKeys.contains(
                      library.shelfIdentityKey(item),
                    );
                    final sourceLabel = _sourceBadgeLabel(
                      l10n: l10n,
                      library: library,
                      item: item,
                      sourceSelected: sourceSelected,
                      fromLocal: fromLocal,
                      shell: shell,
                    );
                    final subtitle = shell
                        ? l10n.notInLibrary
                        : item.isSeries
                        ? l10n.series
                        : (item.tags.contains('simkl-watching') &&
                                  item.subtitle != null &&
                                  item.subtitle!.isNotEmpty
                              ? item.subtitle
                              : null);
                    return _PosterCell(
                      item: item,
                      sourceLabel: sourceLabel,
                      portrait: widget.portrait,
                      subtitle: subtitle,
                      onTap: () => unawaited(_openItem(context, item)),
                      onLongPress: shell
                          ? null
                          : (anchor) => showMediaItemActions(
                              context: context,
                              item: item,
                              anchor: anchor,
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _sourceBadgeLabel({
    required AppLocalizations l10n,
    required LibraryProvider library,
    required MediaItem item,
    required MyListSourceFilter sourceSelected,
    required bool fromLocal,
    required bool shell,
  }) {
    // Unmatched tracker shells: show which tracker list they came from.
    if (shell) {
      if (sourceSelected == MyListSourceFilter.simklWatching ||
          item.tags.contains('simkl-watching') ||
          (item.id.startsWith('simkl:') &&
              !item.id.startsWith('simkl-plan:'))) {
        return l10n.myListSourceWatching;
      }
      if (sourceSelected == MyListSourceFilter.simklPlan ||
          item.tags.contains('simkl-plantowatch') ||
          item.id.startsWith('simkl-plan:')) {
        return l10n.myListSourcePlanToWatch;
      }
      if (sourceSelected == MyListSourceFilter.trakt ||
          item.tags.contains('trakt-watchlist') ||
          item.id.startsWith('trakt:')) {
        return l10n.myListSourceTrakt;
      }
      if (sourceSelected == MyListSourceFilter.plex ||
          item.tags.contains('plex-watchlist') ||
          item.id.startsWith('plex-watchlist:')) {
        return l10n.myListSourcePlex;
      }
      if (sourceSelected == MyListSourceFilter.letterboxd ||
          item.tags.contains('letterboxd-watchlist') ||
          item.id.startsWith('letterboxd:')) {
        return l10n.myListSourceLetterboxd;
      }
      if (sourceSelected == MyListSourceFilter.serializdWatching ||
          item.tags.contains('serializd-watching') ||
          item.id.startsWith('serializd:watching:')) {
        return l10n.myListSourceSerializdWatching;
      }
      if (sourceSelected == MyListSourceFilter.serializdWatchlist ||
          item.tags.contains('serializd-watchlist') ||
          item.id.startsWith('serializd:watchlist:')) {
        return l10n.myListSourceSerializdWatchlist;
      }
      if (sourceSelected == MyListSourceFilter.betaseriesWatching ||
          item.tags.contains('betaseries-watching') ||
          (item.id.startsWith('betaseries:') &&
              !item.id.startsWith('betaseries-plan:'))) {
        return l10n.myListSourceBetaseriesWatching;
      }
      if (sourceSelected == MyListSourceFilter.betaseriesPlan ||
          item.tags.contains('betaseries-plan') ||
          item.id.startsWith('betaseries-plan:')) {
        return l10n.myListSourceBetaseriesPlan;
      }
      if (!fromLocal) return l10n.myListSourceWatching;
    }
    // Linked / local titles: show which Catalog source(s) can play them
    // ("Xtream", "3 sources") — not the tracker list name.
    return library.shelfSourceLabelFor(item);
  }

  Future<void> _openItem(BuildContext context, MediaItem item) async {
    final library = context.read<LibraryProvider>();
    var target = item;
    if (isTrackerListShell(item)) {
      final linked = library.resolveSimklWatchingTap(item);
      if (linked != null && !isTrackerListShell(linked)) {
        target = linked;
      } else {
        final remote = await showDialog<MediaItem?>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (dialogContext) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              MediaItem? matched;
              try {
                matched = await library.resolveSimklWatchingTapAsync(item);
              } finally {
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(matched);
                }
              }
            });
            return PopScope(
              canPop: false,
              child: AlertDialog(
                backgroundColor: AppColors.surface,
                content: Row(
                  children: [
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        dialogContext.l10n.resolvingEllipsis,
                        style: const TextStyle(color: AppColors.text),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
        if (remote != null) target = remote;
      }
      if (!context.mounted) return;
      if (isTrackerListShell(target)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.noLocalStreamYet)));
        return;
      }
    }

    if (target.isSeries) {
      context.push('/series', extra: target);
    } else if (target.isLive) {
      context.push('/player', extra: target);
    } else {
      context.push('/player', extra: target);
    }
  }
}

class _FavoritesTab extends StatefulWidget {
  const _FavoritesTab();

  @override
  State<_FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<_FavoritesTab> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final channels = library.favoriteChannels;
    final q = _query.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? channels
        : channels.where((c) => c.title.toLowerCase().contains(q)).toList();

    if (channels.isEmpty) {
      return _EmptyPane(
        icon: Icons.star_outline_rounded,
        title: context.l10n.noChannelsInThisList,
        body: context.l10n.starLiveChannelsHelp,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IptvSearchBar(
          controller: _query,
          hintText: context.l10n.favoritesSearchHint,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: filtered.isEmpty
              ? _EmptyPane(
                  icon: Icons.filter_alt_off_outlined,
                  title: context.l10n.noMatches,
                  body: context.l10n.myListNoFilterMatches,
                )
              : GridView.builder(
                  padding: AppLayout.pagePadding(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: AdaptiveLayout.posterGridColumns(
                      AdaptiveLayout.contentWidth(context),
                    ),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: AdaptiveLayout.posterGridChildAspectRatio(
                      portrait: false,
                    ),
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final channel = filtered[index];
                    final now = library.nowPlayingFor(channel);
                    final subtitle = [
                      if (now != null) now.title,
                      if (channel.group != null && channel.group!.isNotEmpty)
                        channel.group,
                    ].join(' · ');
                    return _PosterCell(
                      item: channel,
                      sourceLabel: library.sourceLabelFor(channel),
                      portrait: false,
                      live: true,
                      subtitle: subtitle.isEmpty ? null : subtitle,
                      onTap: () => context.push('/player', extra: channel),
                      onLongPress: (anchor) => showMediaItemActions(
                        context: context,
                        item: channel,
                        anchor: anchor,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Poster tile matching Search / Catalog category browse.
class _PosterCell extends StatelessWidget {
  const _PosterCell({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.sourceLabel,
    this.subtitle,
    this.portrait = true,
    this.live = false,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final void Function(Offset? anchor)? onLongPress;
  final String? sourceLabel;
  final String? subtitle;
  final bool portrait;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final title = item.isLive || item.kind == MediaKind.catchup
        ? library.liveOrCatchupDisplayTitle(item)
        : item.kind == MediaKind.vod || item.kind == MediaKind.series
        ? VodGrouping.displayTitle(item)
        : item.title;
    final art = item.artUrlFor(portrait: portrait) ?? item.thumbnailUrl;
    final metaLines = subtitle == null || subtitle!.isEmpty ? 2 : 1;

    final posterArt = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surfaceHigh,
                  Color.lerp(AppColors.accent, AppColors.bg, 0.72)!,
                ],
              ),
            ),
          ),
          if (art != null && art.isNotEmpty)
            JavpArt(url: art, decodeWidth: portrait ? 320 : 420),
          if (live)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  context.l10n.liveBadge,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 9,
                  ),
                ),
              ),
            )
          else if (item.isSeries)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  context.l10n.series.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
          if (sourceLabel != null && sourceLabel!.isNotEmpty)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 96),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  sourceLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    Widget card = PosterCardShell(
      radius: 10,
      expandPoster: true,
      poster: posterArt,
      meta: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HoverMarqueeText(
            text: title,
            maxLines: metaLines,
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              height: 1.15,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        onSelect: onTap,
        borderRadius: 10,
        expandOnFocus: true,
        child: card,
      );
    }
    if (DesktopUi.enabled) {
      return DesktopHoverTile(
        radius: 10,
        onTap: onTap,
        onSecondaryTapAt: onLongPress != null
            ? (pos) => onLongPress!(pos)
            : null,
        showPlayBadge: true,
        child: card,
      );
    }
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress != null ? () => onLongPress!(null) : null,
      borderRadius: BorderRadius.circular(10),
      child: card,
    );
  }
}
