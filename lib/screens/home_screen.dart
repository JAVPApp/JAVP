import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/my_list_ui_prefs.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/platform/web_app_limitation.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/recommendations/home_continue_watching.dart';
import 'package:javp/services/recommendations/home_type_affinity.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/home_first_sync_notice.dart';
import 'package:javp/widgets/cast/cast_device_sheet.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/widgets/app_button.dart';
import 'package:javp/widgets/app_logo.dart';
import 'package:javp/widgets/desktop/hover_scroll_row.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:javp/widgets/now_on_card.dart';
import 'package:javp/widgets/section_header.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/screens/tv/tv_pairing_screen.dart';
import 'package:javp/services/live_watch_nav.dart';
import 'package:javp/services/simkl/simkl_match.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Widget? _frozenTree;
  Object? _frozenStamp;
  final _scroll = ScrollController();
  final _homeTopCtaFocus = FocusNode(debugLabel: 'homeTopCta');
  bool _epgWarmScheduled = false;
  bool _vodWarmRequested = false;
  String? _lastHomeUiStateLog;
  Object? _lastEpgWarmStamp;
  bool _deferredShelfRebuildScheduled = false;
  bool _forceShelfRebuild = false;
  bool _pausedWhileHidden = false;

  /// Cold / post-bootstrap live upgrade — Plex-like progressive fill.
  ///
  /// Incomplete shelves are fine; later phases append below CW (never above).
  /// 0 = Continue Watching + Watching (+ Watch live when live is ranked first)
  /// 1 = Offline + highest-ranked VOD type (Movies or Series)
  /// 2 = Other VOD type + On now (+ Watch live when it ranks below a VOD type)
  /// 3 = For you / My list / TMDB
  /// 4 = catalog group rails
  ///
  /// Each phase paints only [_eagerTileCap] posters; idle expands the rest.
  static const _revealMax = 4;

  /// Gap between shelf groups (not every animation frame — kills ~700ms piles).
  static const _revealGap = Duration(milliseconds: 220);

  /// After phase 4, quiet beat before [LibraryProvider.markHomeRevealSettled].
  static const _revealSettleGrace = Duration(milliseconds: 600);

  /// First paint posters per rail (viewport-ish); expand on idle / scroll.
  static const _initialTileCap = 5;
  static const _tileCapMax = 18;
  static const _tileExpandStep = 4;
  static const _tileExpandGap = Duration(milliseconds: 180);

  int _revealPhase = 0;
  bool _revealComplete = false;
  bool _revealBumpScheduled = false;
  bool _revealSettleReported = false;
  int _eagerTileCap = _initialTileCap;
  bool _tileExpandScheduled = false;
  Timer? _revealBumpTimer;
  Timer? _revealSettleTimer;
  Timer? _tileExpandTimer;

  /// Top CTA (Watch live when live ranks first, or empty-home Add) pins the
  /// app bar — jump-to-0 on focus only then.
  bool _homeTopCtaPinsHeader = true;

  @override
  void dispose() {
    _revealBumpTimer?.cancel();
    _revealSettleTimer?.cancel();
    _tileExpandTimer?.cancel();
    _scroll.dispose();
    _homeTopCtaFocus.dispose();
    super.dispose();
  }

  void _warmOnNowEpg(LibraryProvider library) {
    if (_epgWarmScheduled) return;
    _epgWarmScheduled = true;
    final seed = <MediaItem>[
      ...library.favoriteChannels,
      ...library.recentChannels,
    ];
    final need = <MediaItem>[];
    final seen = <String>{};
    for (final channel in seed) {
      final id = channel.streamId;
      if (id == null || !seen.add(id)) continue;
      if (library.isGuideFetched(channel)) continue;
      need.add(channel);
      if (need.length >= 16) break;
    }
    if (need.isEmpty) return;
    unawaited(library.fetchChannelGuides(need, concurrency: 4));
  }

  void _scheduleDeferredShelfRebuild() {
    if (_deferredShelfRebuildScheduled) return;
    _deferredShelfRebuildScheduled = true;
    // Idle — not post-frame: let the Accueil paint/settle first so Simkl /
    // for-you notifies don't rematerialize shelves on the nav hitch frame.
    SchedulerBinding.instance.scheduleTask(() {
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
    }, Priority.idle);
  }

  /// Watch live (or empty-shelf CTA) is below the Home app bar / blurb when
  /// live is the user's top type. Default focus ensureVisible pins that button
  /// to the top of the viewport and Up has nowhere to go — jump to offset 0
  /// so the header stays readable.
  void _revealHomeTop() {
    if (!TvPlatform.isAndroidTv) return;
    if (!_homeTopCtaPinsHeader) return;
    void jump() {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    }

    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
  }

  KeyEventResult _onHomeKey(FocusNode node, KeyEvent event) {
    if (!TvPlatform.isAndroidTv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (!_homeTopCtaFocus.hasFocus) return KeyEventResult.ignored;
    // Mid-page Watch live (Movies/Series ranked above) still uses this focus
    // node — do not swallow Up; let normal traversal reach rails above.
    if (!_homeTopCtaPinsHeader) return KeyEventResult.ignored;
    if (!_scroll.hasClients || _scroll.offset <= 0) {
      return KeyEventResult.ignored;
    }
    _revealHomeTop();
    return KeyEventResult.handled;
  }

  void _scheduleRevealBump() {
    if (_revealComplete || _revealBumpScheduled) return;
    if (_revealPhase >= _revealMax) {
      _revealComplete = true;
      _scheduleRevealSettle();
      return;
    }
    _revealBumpScheduled = true;
    _revealBumpTimer?.cancel();
    // Timed gap + idle apply — not Priority.animation (stacked with bootstrap).
    _revealBumpTimer = Timer(_revealGap, () {
      _revealBumpTimer = null;
      if (!mounted || _revealComplete) {
        _revealBumpScheduled = false;
        return;
      }
      SchedulerBinding.instance.scheduleTask(() {
        _revealBumpScheduled = false;
        if (!mounted || _revealComplete) return;
        if (!ShellVisibility.isActiveOf(context)) return;
        setState(() {
          _revealPhase = (_revealPhase + 1).clamp(0, _revealMax);
          if (_revealPhase >= _revealMax) {
            _revealComplete = true;
            _forceShelfRebuild = true;
            _scheduleRevealSettle();
            _scheduleTileExpand();
          } else {
            _forceShelfRebuild = true;
          }
        });
      }, Priority.idle);
    });
  }

  void _scheduleRevealSettle() {
    if (_revealSettleReported) return;
    _revealSettleTimer?.cancel();
    _revealSettleTimer = Timer(_revealSettleGrace, () {
      _revealSettleTimer = null;
      if (!mounted || _revealSettleReported) return;
      _revealSettleReported = true;
      context.read<LibraryProvider>().markHomeRevealSettled(reason: 'reveal');
      _scheduleTileExpand();
    });
  }

  void _scheduleTileExpand() {
    if (_tileExpandScheduled || _eagerTileCap >= _tileCapMax) return;
    if (!_revealComplete) return;
    _tileExpandScheduled = true;
    _tileExpandTimer?.cancel();
    _tileExpandTimer = Timer(_tileExpandGap, () {
      _tileExpandTimer = null;
      _tileExpandScheduled = false;
      if (!mounted) return;
      SchedulerBinding.instance.scheduleTask(() {
        if (!mounted) return;
        if (!ShellVisibility.isActiveOf(context)) return;
        if (_eagerTileCap >= _tileCapMax) return;
        setState(() {
          _eagerTileCap = (_eagerTileCap + _tileExpandStep).clamp(
            _initialTileCap,
            _tileCapMax,
          );
          _forceShelfRebuild = true;
        });
        if (_eagerTileCap < _tileCapMax) _scheduleTileExpand();
      }, Priority.idle);
    });
  }

  void _noteRevealEmptyOrDone(
    LibraryProvider library, {
    required bool hasShelves,
  }) {
    if (_revealSettleReported) return;
    if (!hasShelves && !library.loading) {
      _revealComplete = true;
      _revealSettleReported = true;
      library.markHomeRevealSettled(reason: 'empty');
    }
  }

  List<MediaItem> _capTiles(List<MediaItem> items) {
    if (items.length <= _eagerTileCap) return items;
    return items.take(_eagerTileCap).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final active = ShellVisibility.isActive(context);
    // Freeze under Player/Search — watch history updates must not rebuild Home
    // underneath and reset scroll when minimizing back.
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);

    // Keep epgRevision out of this select — On now uses Selector below.
    // Hash history identity (not only length) so continue-watching removes
    // always rebuild even if another write keeps the list the same size.
    // Do NOT include liveDbRevision or syncStatus — idle source sync / EPG
    // replace 27k channels and would force a full Home rebuild under quiet sync.
    final localeStamp = context.select<LocaleController, int>(
      (c) => Object.hash(
        c.effectiveLanguageCode,
        Object.hashAll(c.preferredContentLocalesOverride),
      ),
    );
    final stamp = context.select<LibraryProvider, int>(
      (l) => Object.hash(
        // Content fingerprint — not history list identity (reloadAfterSync /
        // simkl / for-you used to rematerialize every shelf on alt-tab).
        l.homeShelfContentStamp,
        l.sourcesAppearanceRevision,
        localeStamp,
      ),
    );

    // Shell tab hidden: keep the last Element tree mounted. [SkipLayout] in
    // ShellBranchHost skips layout/paint — unlike the old SizedBox path, which
    // forced a full remount hitch on every return to Home.
    Widget keep(Widget child) =>
        keepShellTabTree(skip: active && covered, child: child);

    if (!active) {
      _pausedWhileHidden = true;
      return keep(_frozenTree ?? const SizedBox.expand());
    }
    // Reveal / tile-expand timers bail out while hidden. Coming back with the
    // same stamp used to keep the capped frozen rail forever. Also rematerialize
    // when content arrived while we were away (e.g. demo sync after empty settle)
    // — otherwise Accueil keeps the frozen "shelf is empty" tree forever.
    if (_pausedWhileHidden) {
      _pausedWhileHidden = false;
      if (!_revealComplete ||
          _eagerTileCap < _tileCapMax ||
          _frozenStamp != stamp) {
        _forceShelfRebuild = true;
      }
    }

    // Player / search covering this branch: skip layout/paint but keep the
    // Element tree. Returning SizedBox.expand remounted every shelf on pop.
    if (covered) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }

    // Warm return: same data stamp → identical widget instance (no Element work).
    // Honor [_forceShelfRebuild] so staggered reveal can rematerialize one
    // shelf group per frame without waiting for a stamp change.
    if (_frozenTree != null && _frozenStamp == stamp && !_forceShelfRebuild) {
      return keep(_frozenTree!);
    }

    // Data changed while we were away — serve the stale tree on this frame so
    // the nav selection paints immediately, then recompute shelves next frame.
    if (_frozenTree != null && !_forceShelfRebuild) {
      _scheduleDeferredShelfRebuild();
      return keep(_frozenTree!);
    }
    _forceShelfRebuild = false;

    final library = context.read<LibraryProvider>();
    final moviePortrait = library.displaySettings.moviesCoverPortrait;
    final l10n = context.l10n;
    // Idle only — network when missing/stale; disk hydrate is late (demand
    // or ~45s idle) so first paint is not blocked by ~200k Xtream rows.
    // If blur cancels the queued warm, re-ask on a later paint.
    if (!library.isVodDiskHydrated && !_vodWarmRequested) {
      _vodWarmRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await library.scheduleIdleVodWarm(reason: 'home-idle');
        } finally {
          if (mounted && !library.isVodDiskHydrated) {
            _vodWarmRequested = false;
          }
        }
      });
    }
    if (!library.hasLiveDb &&
        !library.hasLiveIndex &&
        library.sources.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        library.ensureLiveIndex(delay: const Duration(seconds: 1));
      });
    }
    final favRecentStamp = Object.hash(
      library.favoriteChannelIds.length,
      library.recentChannelIds.length,
    );
    if (_lastEpgWarmStamp != favRecentStamp) {
      _lastEpgWarmStamp = favRecentStamp;
      _epgWarmScheduled = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _warmOnNowEpg(library);
      });
    }

    // Last-close cache. After sources restore, gone catalogs are already
    // omitted so empty live Movies cannot resurrect deleted posters.
    final snap = library.homeShelfSnapshot;
    final watchingLive = library.simklWatching;
    // Prefer live Simkl rows; last-close Watching is the cold-start stand-in.
    final watchingItems = watchingLive.isNotEmpty
        ? watchingLive
        : (snap?.watching ?? const <MediaItem>[]);
    // History + Simkl must not paint the same show twice (CW series shell +
    // Watching row, or CW episode-attached sibling of a Watching shell).
    // Filter against the shelf that will actually paint, and keep last-close
    // series cards while live CW is still a leftover subset (catalog/shells
    // not ready). Empty live after bootstrap stays empty when history is gone.
    final continueItems = HomeContinueWatching.resolve(
      live: library.continueWatching,
      snapshot: snap?.continueWatching ?? const <MediaItem>[],
      watching: watchingItems,
      loading: library.loading,
      historyKeys: HomeContinueWatching.keySet(
        library.continueWatchingHistorySupport,
      ),
    );

    // Incomplete shelves are fine — stagger expensive VOD rails so Accueil
    // never rematerializes movies+series+for-you in one frame.
    // Phase 0: CW + Watching (+ Watch live when live ranks first).
    // Phase 1: Offline + highest-ranked VOD type (Movies or Series)
    // Phase 2: Other VOD type + On now
    // Phase 3: For you / My list / TMDB
    // Phase 4: catalog group rails
    final phase = _revealComplete ? _revealMax : _revealPhase;
    final usedSnapCw =
        continueItems.isNotEmpty &&
        library.continueWatching.length < continueItems.length;
    final typeOrder = HomeTypeAffinity.rank(
      history: library.history,
      snapshotOrder: (snap?.typeOrder.isNotEmpty ?? false)
          ? snap!.typeOrder
          : null,
    );
    final firstVod = HomeTypeAffinity.firstVodType(typeOrder);

    var movies = const <MediaItem>[];
    var series = const <MediaItem>[];
    var forYou = const <MediaItem>[];
    var trending = const <MediaItem>[];
    var popular = const <MediaItem>[];
    var myList = const <MediaItem>[];
    var offlineItems = const <MediaItem>[];
    var offlineSeries = const <MediaItem>[];
    var groupShelves = const <({String title, List<MediaItem> items})>[];
    var showTmdbDiscoveryEmpty = false;

    if (phase >= 1) {
      offlineSeries = library.downloadedSeriesItems.take(18).toList();
      // Standalone downloads (movies / catchup / imports) keep their own shelf;
      // episodes that map to a series shell live on [offlineSeries], but
      // unmatched orphans still fall back to this flat list.
      offlineItems = library.offlineLibraryItems
          .where(
            (m) => !m.isEpisode || library.seriesShellForEpisode(m) == null,
          )
          .take(18)
          .toList();
      if (phase >= 2 || firstVod == HomeContentType.movies) {
        final moviesLive = _movieShelf(library);
        movies = moviesLive.isNotEmpty
            ? moviesLive
            : (snap?.movies ?? const <MediaItem>[]);
      }
      if (phase >= 2 || firstVod == HomeContentType.series) {
        final seriesLive = _seriesShelf(library);
        series = seriesLive.isNotEmpty
            ? seriesLive
            : (snap?.series ?? const <MediaItem>[]);
      }
    }

    final shownIds = {...movies.map((m) => m.id), ...series.map((m) => m.id)};
    final shownKeys = {
      for (final m in movies) library.shelfIdentityKey(m),
      for (final m in series) library.shelfIdentityKey(m),
    };

    if (phase >= 3) {
      final forYouLive = library.collapseHomeShelfItems(
        library.recommendations.where(
          (m) =>
              !m.isEpisode && !shownKeys.contains(library.shelfIdentityKey(m)),
        ),
        limit: 18,
      );
      forYou = forYouLive.isNotEmpty
          ? forYouLive
          : (snap?.forYou ?? const <MediaItem>[]);
      final trendingLive = library.collapseHomeShelfItems(
        library.tmdbTrendingShelf.where(
          (m) => !shownKeys.contains(library.shelfIdentityKey(m)),
        ),
        limit: 18,
      );
      trending = trendingLive.isNotEmpty
          ? trendingLive
          : (snap?.trending ?? const <MediaItem>[]);
      final popularLive = library.collapseHomeShelfItems(
        library.tmdbPopularShelf.where(
          (m) =>
              !shownKeys.contains(library.shelfIdentityKey(m)) &&
              !trending.any(
                (t) =>
                    library.shelfIdentityKey(t) == library.shelfIdentityKey(m),
              ),
        ),
        limit: 18,
      );
      popular = popularLive.isNotEmpty
          ? popularLive
          : (snap?.popular ?? const <MediaItem>[]);
      for (final m in [...trending, ...popular]) {
        shownIds.add(m.id);
        shownKeys.add(library.shelfIdentityKey(m));
      }
      showTmdbDiscoveryEmpty =
          library.tmdb.isConfigured &&
          library.tmdbDiscoveryAttempted &&
          trending.isEmpty &&
          popular.isEmpty;
      final myListLive = library.collapseHomeShelfItems(
        library.watchlist,
        limit: 12,
      );
      myList = myListLive.isNotEmpty
          ? myListLive
          : (snap?.myList ?? const <MediaItem>[]);
    }
    if (phase >= 4) {
      groupShelves = library.catalogGroupPreviews(excludeIds: shownIds);
    }

    var recentLive = TvPlatform.isAndroidTv
        ? library.recentLiveHomeRow(limit: 12)
        : const <MediaItem>[];
    if (recentLive.isEmpty && (snap?.recentLive.isNotEmpty ?? false)) {
      recentLive = snap!.recentLive;
    }
    var watchLiveTarget = TvPlatform.isAndroidTv
        ? library.preferredWatchLiveChannel
        : null;
    watchLiveTarget ??= recentLive.isNotEmpty ? recentLive.first : null;
    final showWatchLive =
        TvPlatform.isAndroidTv &&
        (watchLiveTarget != null ||
            recentLive.isNotEmpty ||
            (snap?.watchLive ?? false) ||
            library.recentChannelIds.isNotEmpty ||
            library.favoriteChannelIds.isNotEmpty ||
            library.hasLiveDb ||
            library.hasLiveIndex ||
            library.liveChannels.isNotEmpty);
    final watchLiveIsHomeTop =
        showWatchLive && typeOrder.first == HomeContentType.live;

    // Count last-close rails even before phase catches up — otherwise empty CW
    // + snap movies flashes the bootstrap spinner until loading clears.
    final snapHasRails = snap?.hasContent ?? false;
    final hasShelves =
        continueItems.isNotEmpty ||
        watchingItems.isNotEmpty ||
        offlineItems.isNotEmpty ||
        offlineSeries.isNotEmpty ||
        movies.isNotEmpty ||
        series.isNotEmpty ||
        groupShelves.isNotEmpty ||
        forYou.isNotEmpty ||
        trending.isNotEmpty ||
        popular.isNotEmpty ||
        showTmdbDiscoveryEmpty ||
        myList.isNotEmpty ||
        snapHasRails ||
        library.favoriteChannelIds.isNotEmpty ||
        library.recentChannelIds.isNotEmpty ||
        showWatchLive;
    _homeTopCtaPinsHeader = watchLiveIsHomeTop || !hasShelves;

    // CW first when present; if CW is empty (live + snap) or we already have a
    // last-close snapshot, stagger the rest immediately — don't wait on bootstrap.
    final cwSettled =
        continueItems.isNotEmpty || snapHasRails || !library.loading;
    if (hasShelves && cwSettled && !_revealComplete) {
      _scheduleRevealBump();
    } else if (hasShelves && _revealPhase >= _revealMax) {
      _revealComplete = true;
      _scheduleRevealSettle();
      _scheduleTileExpand();
    }
    _noteRevealEmptyOrDone(library, hasShelves: hasShelves);

    final showHomeSpinner = library.loading && !hasShelves;
    final homeLine =
        '${showHomeSpinner
            ? 'spinner'
            : !hasShelves
            ? 'empty'
            : 'content'} '
        'loading=${library.loading} '
        'snap=$snapHasRails snapCw=$usedSnapCw '
        'reveal=$phase/$_revealMax${_revealComplete ? '+done' : ''} '
        'tiles=$_eagerTileCap '
        'cw=${continueItems.length} watch=${watchingItems.length} '
        'movies=${movies.length} series=${series.length} '
        'forYou=${forYou.length} groups=${groupShelves.length} '
        'watchLive=${showWatchLive ? 1 : 0} liveRow=${recentLive.length} '
        'types=${HomeTypeAffinity.encodeOrder(typeOrder).join(",")} '
        'hydrated=${library.isVodDiskHydrated} '
        'hydrating=${library.isVodDiskHydrating} '
        'idleWait=${library.isVodDiskHydrateIdleWaiting} '
        'vodBusy=${library.vodCatalogLoadingReason()} '
        'sync=${library.syncStatus != null}';
    if (homeLine != _lastHomeUiStateLog) {
      _lastHomeUiStateLog = homeLine;
      JavpLog.i('vod', 'home ui $homeLine');
    }

    // Persist after stagger — but don't shrink a richer last-close paint while
    // VOD is still warming (journals showed snap 18/18 overwritten by 3/1).
    if (_revealComplete && hasShelves && !library.loading) {
      final prev = snap;
      final liveRails = movies.length + series.length + forYou.length;
      final prevRails = prev == null
          ? 0
          : prev.movies.length + prev.series.length + prev.forYou.length;
      final shrinkingWarm =
          prev != null && liveRails < prevRails && !library.isVodDiskHydrated;
      if (!shrinkingWarm) {
        library.noteHomeShelfPaint(
          continueWatching: continueItems,
          watching: watchingItems,
          movies: movies,
          series: series,
          forYou: forYou,
          myList: myList,
          trending: trending,
          popular: popular,
          recentLive: recentLive,
          watchLive: showWatchLive,
          typeOrder: typeOrder,
        );
      }
    }

    final settled = library.isHomeRevealSettled;
    // Tight vertical prefetch while trickling — wide cache rebuilt every
    // off-screen rail's posters and caused ~700–900ms shelf hitches.
    final scrollView = CustomScrollView(
      key: const PageStorageKey<String>('home-scroll'),
      controller: _scroll,
      scrollCacheExtent: ScrollCacheExtent.pixels(settled ? 360 : 100),
      slivers: [
        SliverAppBar(
          floating: true,
          title: Row(
            children: [
              const AppLogo(size: 28),
              const SizedBox(width: 10),
              Text(
                'JAVP',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          actions: [
            if (!TvPlatform.isAndroidTv) ...[
              IconButton(
                tooltip: library.downloads.waitingForWifi
                    ? l10n.downloadsWaitingWifi
                    : library.downloads.activeCount > 0
                    ? l10n.downloadsActiveCount(library.downloads.activeCount)
                    : l10n.downloads,
                onPressed: () => context.push('/downloads'),
                icon: Badge(
                  isLabelVisible:
                      library.downloads.activeCount > 0 ||
                      library.downloads.waitingForWifi,
                  label: library.downloads.waitingForWifi
                      ? null
                      : Text('${library.downloads.activeCount}'),
                  child: Icon(
                    library.downloads.activeCount > 0 ||
                            library.downloads.waitingForWifi
                        ? Icons.download_rounded
                        : Icons.download_outlined,
                  ),
                ),
              ),
              if (AppCapabilities.castToDevice)
                Builder(
                  builder: (context) {
                    final casting = context.select<PlaybackProvider, bool>(
                      (p) => p.isCasting,
                    );
                    final device = context.select<LibraryProvider, String?>(
                      (l) => l.cast.deviceName,
                    );
                    return IconButton(
                      tooltip: casting
                          ? l10n.castingTo(device ?? '')
                          : l10n.castToDevice,
                      onPressed: () => unawaited(showCastDeviceSheet(context)),
                      icon: Icon(
                        casting
                            ? Icons.cast_connected_rounded
                            : Icons.cast_rounded,
                      ),
                    );
                  },
                ),
              IconButton(
                tooltip: l10n.search,
                onPressed: () => context.push('/search'),
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                tooltip: l10n.history,
                onPressed: () => context.push('/history'),
                icon: const Icon(Icons.history_rounded),
              ),
              IconButton(
                tooltip: l10n.addSource,
                onPressed: () => context.push('/sources'),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ],
        ),
        if (WebAppLimitation.httpSourcesBanner(
              context: context,
              sources: library.sources,
              onDismissed: () => setState(() {}),
            )
            case final banner?)
          SliverToBoxAdapter(child: banner),
        if (!hasShelves)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ListenableBuilder(
              listenable: library.syncStatusListenable,
              builder: (context, _) {
                if (library.isFirstCatalogSyncRunning) {
                  return HomeFirstSyncNotice(status: library.syncStatus);
                }
                if (library.loading) {
                  return const Center(
                    // Keep the default arrow — wait cursor over the whole
                    // shell felt like sync had locked the UI even though
                    // nothing absorbs hits.
                    child: MouseRegion(
                      cursor: SystemMouseCursors.basic,
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                return _EmptyHome(
                  onAdd: () {
                    if (TvPlatform.isAndroidTv) {
                      Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TvPairingScreen(),
                        ),
                      );
                    } else {
                      context.push('/sources');
                    }
                  },
                  topCtaFocus: _homeTopCtaFocus,
                  onTopCtaFocus: _revealHomeTop,
                );
              },
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: ListenableBuilder(
              listenable: library.syncStatusListenable,
              builder: (context, _) {
                if (!library.isFirstCatalogSyncRunning) {
                  return const SizedBox.shrink();
                }
                return HomeFirstSyncNotice(
                  compact: true,
                  status: library.syncStatus,
                );
              },
            ),
          ),
          // Session rails stay first (CW / Watching / Downloaded). Watch live
          // only sits above them when live is the user's top type. Later
          // reveal phases append below, never above.
          if (watchLiveIsHomeTop)
            ..._watchLiveSection(
              context,
              library: library,
              primary: watchLiveTarget,
              recent: recentLive,
            ),
          if (continueItems.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.continueWatching,
              subtitle: l10n.continueWatchingSubtitle,
              items: continueItems,
              portrait: moviePortrait,
              resumeOnTap: true,
              allowRemoveFromContinueWatching: true,
            ),
          if (watchingItems.isNotEmpty ||
              (library.simkl.isAuthenticated && library.isSimklSyncing))
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.watching,
              subtitle: library.isSimklSyncing
                  ? l10n.refreshingFromSimkl
                  : l10n.watchingSimklSubtitle,
              items: watchingItems,
              portrait: moviePortrait,
              actionLabel: l10n.seeAll,
              onAction: () => context.push(
                '/mylist',
                extra: MyListSourceFilter.simklWatching,
              ),
            ),
          if (offlineSeries.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.downloadedSeries,
              subtitle: l10n.downloadedSeriesSubtitle,
              items: offlineSeries,
              portrait: moviePortrait,
              resumeOnTap: false,
              actionLabel: l10n.seeAll,
              onAction: () => context.push('/downloaded-series'),
            ),
          if (offlineItems.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.downloaded,
              subtitle: l10n.availableOffline,
              items: offlineItems,
              portrait: moviePortrait,
              resumeOnTap: true,
              actionLabel: l10n.seeAll,
              onAction: () => context.push('/downloads'),
            ),
          ..._rankedTypeSlivers(
            context,
            library: library,
            typeOrder: typeOrder,
            phase: phase,
            showWatchLive: showWatchLive,
            skipLive: watchLiveIsHomeTop,
            watchLiveTarget: watchLiveTarget,
            recentLive: recentLive,
            movies: movies,
            series: series,
            moviePortrait: moviePortrait,
          ),
          if (phase >= 2)
            SliverToBoxAdapter(
              child: Selector<LibraryProvider, int>(
                selector: (_, l) => l.epgRevision,
                builder: (context, _, _) {
                  final onNow = library.onNowChannels(limit: 24);
                  if (onNow.isEmpty) return const SizedBox.shrink();
                  final onNowVisible = onNow.length <= _eagerTileCap
                      ? onNow
                      : onNow.take(_eagerTileCap).toList(growable: false);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader(
                        title: l10n.onNow,
                        subtitle: l10n.onNowSubtitle,
                        actionLabel: 'TV',
                        onAction: () => context.go('/tv'),
                      ),
                      SizedBox(
                        height: 210,
                        child: HoverScrollRow(
                          builder: (context, controller) => ListView.separated(
                            controller: controller,
                            scrollDirection: Axis.horizontal,
                            padding: AppLayout.shelfPadding,
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              160,
                            ),
                            itemCount: onNowVisible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              final entry = onNowVisible[index];
                              return _OnNowShelfCard(
                                seed: entry.channel,
                                program: entry.program,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (forYou.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.forYou,
              subtitle: l10n.forYouSubtitle,
              items: forYou,
              portrait: moviePortrait,
            ),
          if (trending.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.trending,
              subtitle: l10n.trendingInYourCatalog,
              items: trending,
              portrait: moviePortrait,
            ),
          if (popular.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.popular,
              subtitle: l10n.popularInYourCatalog,
              items: popular,
              portrait: moviePortrait,
            ),
          if (showTmdbDiscoveryEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: AppLayout.shelfPadding.copyWith(top: 12, bottom: 8),
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
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (myList.isNotEmpty)
            ..._mediaShelf(
              context,
              library: library,
              title: l10n.myList,
              subtitle: l10n.savedForLater,
              items: myList,
              portrait: moviePortrait,
              actionLabel: l10n.seeAll,
              onAction: () => context.push('/mylist'),
            ),
          for (final shelf in groupShelves)
            ..._mediaShelf(
              context,
              library: library,
              title: shelf.title,
              subtitle: l10n.fromYourCatalog,
              items: shelf.items,
              portrait: moviePortrait,
              actionLabel: l10n.seeAll,
              onAction: () => context.go('/catalog'),
            ),
          const SliverToBoxAdapter(child: MiniPlayerScrollClearance()),
        ],
      ],
    );

    final tree = TvPlatform.isAndroidTv
        ? Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onHomeKey,
            child: scrollView,
          )
        : scrollView;

    // Never freeze the bootstrap Loading spinner — with VOD hydrate deferred,
    // first paint often has empty shelves + loading=true; freezing that tree
    // and only rematerializing on idle left Accueil spinning forever.
    if (!(library.loading && !hasShelves)) {
      _frozenTree = tree;
      _frozenStamp = stamp;
    } else {
      _frozenTree = null;
      _frozenStamp = null;
    }
    return keep(tree);
  }

  List<Widget> _rankedTypeSlivers(
    BuildContext context, {
    required LibraryProvider library,
    required List<HomeContentType> typeOrder,
    required int phase,
    required bool showWatchLive,
    required bool skipLive,
    required MediaItem? watchLiveTarget,
    required List<MediaItem> recentLive,
    required List<MediaItem> movies,
    required List<MediaItem> series,
    required bool? moviePortrait,
  }) {
    final l10n = context.l10n;
    final out = <Widget>[];
    for (final type in typeOrder) {
      if (phase < HomeTypeAffinity.minRevealPhase(type, typeOrder)) continue;
      switch (type) {
        case HomeContentType.live:
          if (!skipLive && showWatchLive) {
            out.addAll(
              _watchLiveSection(
                context,
                library: library,
                primary: watchLiveTarget,
                recent: recentLive,
              ),
            );
          }
        case HomeContentType.movies:
          if (movies.isNotEmpty) {
            out.addAll(
              _mediaShelf(
                context,
                library: library,
                title: l10n.movies,
                subtitle: l10n.onDemandTitles,
                items: movies,
                portrait: moviePortrait,
                actionLabel: l10n.seeAll,
                onAction: () => context.go('/catalog'),
              ),
            );
          }
        case HomeContentType.series:
          if (series.isNotEmpty) {
            out.addAll(
              _mediaShelf(
                context,
                library: library,
                title: l10n.series,
                subtitle: l10n.showsAndSeasons,
                items: series,
                portrait: moviePortrait,
                actionLabel: l10n.seeAll,
                onAction: () => context.go('/catalog'),
              ),
            );
          }
      }
    }
    return out;
  }

  static List<MediaItem> _movieShelf(LibraryProvider library) {
    // Over-fetch preview before collapse — EN|/FR| / multi-source siblings
    // used to survive as separate cards when we only deduped by item id.
    return library.collapseHomeShelfItems([
      ...library.recommendations.where(
        (m) =>
            library.isListedVodSourceVisible(m.sourceId) && _isOnDemandMovie(m),
      ),
      ...library.watchlist.where(
        (m) =>
            library.isListedVodSourceVisible(m.sourceId) && _isOnDemandMovie(m),
      ),
      ...library.vodPreview(series: false, limit: 36),
    ], limit: 18);
  }

  /// Android TV Home hero: one-press Watch live + recent/favorite channel row.
  List<Widget> _watchLiveSection(
    BuildContext context, {
    required LibraryProvider library,
    required MediaItem? primary,
    required List<MediaItem> recent,
  }) {
    final l10n = context.l10n;
    final channelLabel = primary == null
        ? null
        : library.officialLiveTitle(primary);

    Future<void> playPreferred() async {
      final target =
          primary ?? await library.resolvePreferredWatchLiveChannel();
      if (target == null) {
        if (context.mounted) context.go('/tv');
        return;
      }
      if (!context.mounted) return;
      await openLivePlayback(context, target);
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: AppLayout.shelfPadding.copyWith(top: 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.watchLive,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                channelLabel == null
                    ? l10n.watchLiveSubtitle
                    : l10n.watchLiveChannelSubtitle(channelLabel),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 14),
              // No autofocus: shell rail pin after Accueil select would steal it
              // back a frame later ("focus then debind"). Right from the rail
              // enters content via [ShellScreen._enterContentFromRail].
              AppActionButton(
                focusNode: _homeTopCtaFocus,
                icon: Icons.live_tv_rounded,
                onPressed: () => unawaited(playPreferred()),
                onFocusChange: (focused) {
                  if (focused) _revealHomeTop();
                },
                label: l10n.watchLive,
              ),
            ],
          ),
        ),
      ),
      if (recent.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: SectionHeader(
            title: l10n.recentLive,
            subtitle: l10n.recentLiveSubtitle,
            actionLabel: 'TV',
            onAction: () => context.go('/tv'),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: AdaptiveLayout.compactShelfHeight(context, portrait: false),
            child: HoverScrollRow(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: AppLayout.shelfPadding,
                scrollCacheExtent: const ScrollCacheExtent.pixels(160),
                itemCount: recent.length > 6 ? 6 : recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final channel = recent[index];
                  final variants = library.liveVariantCount(channel);
                  return MediaTile(
                    item: channel,
                    compact: true,
                    portrait: false,
                    sourceLabel: library.sourceLabelFor(channel),
                    variantCount: variants > 1 ? variants : null,
                    onTap: () => unawaited(openLivePlayback(context, channel)),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    ];
  }

  static List<MediaItem> _seriesShelf(LibraryProvider library) {
    return library.collapseHomeShelfItems([
      ...library.recommendations.where(
        (m) => library.isListedVodSourceVisible(m.sourceId) && m.isSeries,
      ),
      ...library.watchlist.where(
        (m) => library.isListedVodSourceVisible(m.sourceId) && m.isSeries,
      ),
      ...library.vodPreview(series: true, limit: 36),
    ], limit: 18);
  }

  static bool _isOnDemandMovie(MediaItem m) =>
      !m.isEpisode &&
      !m.isSeries &&
      !m.isLive &&
      m.kind != MediaKind.catchup &&
      (m.kind == MediaKind.vod ||
          m.kind == MediaKind.local ||
          m.kind == MediaKind.network);

  List<Widget> _mediaShelf(
    BuildContext context, {
    required LibraryProvider library,
    required String title,
    required String subtitle,
    required List<MediaItem> items,
    bool? portrait,
    bool resumeOnTap = false,
    bool allowRemoveFromContinueWatching = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    // Cap eager posters — idle [_scheduleTileExpand] grows the rail. Full
    // item lists still persist via [noteHomeShelfPaint] from uncapped sources.
    final visible = _capTiles(items);
    final settled = library.isHomeRevealSettled;
    // Auto (portrait == null): one format for the whole shelf so tiles match.
    final uniformPortrait =
        portrait ?? visible.any((i) => i.prefersPortraitArt && !i.isLive);
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: title,
          subtitle: subtitle,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: AdaptiveLayout.compactShelfHeight(
            context,
            portrait: uniformPortrait,
            withProgress: resumeOnTap,
          ),
          child: HoverScrollRow(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: AppLayout.shelfPadding,
              // Trickle decode: small prefetch until Accueil settled.
              scrollCacheExtent: ScrollCacheExtent.pixels(settled ? 320 : 120),
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final item = visible[index];
                final isOnDemand =
                    !item.isLive &&
                    !item.isEpisode &&
                    (item.kind == MediaKind.vod || item.isSeries);
                // Tracker shells reuse MediaOrigin.url with an empty playUrl —
                // never paint a fake "URL" / catalog chip (tap has nothing local).
                final trackerShell = isTrackerListShell(item);
                return MediaTile(
                  item: item,
                  compact: true,
                  portrait: item.isLive ? false : uniformPortrait,
                  sourceLabel: trackerShell
                      ? null
                      : (isOnDemand
                            ? library.shelfSourceLabelFor(item)
                            : library.sourceLabelFor(item)),
                  variantCount: isOnDemand && !item.isSeries
                      ? library.vodVariantCountFor(item)
                      : null,
                  onLongPress: allowRemoveFromContinueWatching
                      ? (anchor) => showMediaItemActions(
                          context: context,
                          item: item,
                          anchor: anchor,
                          onPlay: () {
                            if (resumeOnTap && item.isPlayable) {
                              playMediaItem(context, item);
                              return;
                            }
                            if (resumeOnTap && item.isSeries) {
                              final episode = library.resumeEpisodeForSeries(
                                item,
                              );
                              if (episode != null) {
                                playMediaItem(context, episode);
                                return;
                              }
                            }
                            _openItem(context, item);
                          },
                          onRemoveFromContinueWatching: () {
                            unawaited(library.removeFromContinueWatching(item));
                          },
                        )
                      : null,
                  onTap: () async {
                    var target = item;
                    if (isTrackerListShell(item)) {
                      final linked = library.resolveSimklWatchingTap(item);
                      if (linked != null && !isTrackerListShell(linked)) {
                        target = linked;
                      } else {
                        // Remote catalog match can take a while — don't hang silent.
                        final remote = await showDialog<MediaItem?>(
                          context: context,
                          useRootNavigator: true,
                          barrierDismissible: false,
                          builder: (dialogContext) {
                            // Start lookup once the dialog route is installed so
                            // a fast result can't pop the page underneath.
                            WidgetsBinding.instance.addPostFrameCallback((
                              _,
                            ) async {
                              MediaItem? matched;
                              try {
                                matched = await library
                                    .resolveSimklWatchingTapAsync(item);
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
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Text(
                                        dialogContext.l10n.resolvingEllipsis,
                                        style: const TextStyle(
                                          color: AppColors.text,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                        if (remote != null && !isTrackerListShell(remote)) {
                          target = remote;
                        }
                      }
                    }
                    if (!context.mounted) return;
                    // Still a tracker placeholder — nothing local to open.
                    if (isTrackerListShell(target)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.l10n.noLocalStreamYet)),
                      );
                      return;
                    }
                    if (allowRemoveFromContinueWatching) {
                      openContinueWatchingItem(context, target);
                      return;
                    }
                    if (resumeOnTap && target.isPlayable) {
                      playMediaItem(context, target);
                      return;
                    }
                    if (resumeOnTap && target.isSeries) {
                      final episode = library.resumeEpisodeForSeries(target);
                      if (episode != null) {
                        playMediaItem(context, episode);
                        return;
                      }
                    }
                    _openItem(context, target);
                  },
                );
              },
            ),
          ),
        ),
      ),
    ];
  }

  static void _openItem(BuildContext context, MediaItem item) {
    if (item.origin == MediaOrigin.download ||
        item.kind == MediaKind.local ||
        item.origin == MediaOrigin.localFile) {
      context.push('/player', extra: item);
      return;
    }
    if (item.isLive) {
      openLivePlayback(context, item);
      return;
    }
    if (item.kind == MediaKind.catchup) {
      context.push('/player', extra: item);
      return;
    }
    if (item.isSeries) {
      context.push('/series', extra: item);
      return;
    }
    if (item.isEpisode) {
      playMediaItem(context, item);
      return;
    }
    context.push('/title', extra: item);
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onAdd, this.topCtaFocus, this.onTopCtaFocus});

  final VoidCallback onAdd;
  final FocusNode? topCtaFocus;
  final VoidCallback? onTopCtaFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.playlist_add_rounded,
            size: 56,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.yourShelfIsEmpty,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.emptyShelfHint,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (TvPlatform.isAndroidTv)
            AppActionButton(
              focusNode: topCtaFocus,
              icon: Icons.qr_code_2_rounded,
              onPressed: onAdd,
              onFocusChange: (focused) {
                if (focused) onTopCtaFocus?.call();
              },
              label: l10n.devicePairTitle,
            )
          else
            AppButton(
              onPressed: onAdd,
              icon: Icons.add_rounded,
              label: l10n.addMediaSource,
            ),
        ],
      ),
    );
  }
}

/// Home “On now” tile: clickable poster + start-over after catchup sibling loads.
class _OnNowShelfCard extends StatefulWidget {
  const _OnNowShelfCard({required this.seed, required this.program});

  final MediaItem seed;
  final EpgProgram program;

  @override
  State<_OnNowShelfCard> createState() => _OnNowShelfCardState();
}

class _OnNowShelfCardState extends State<_OnNowShelfCard> {
  MediaItem? _fromStart;

  @override
  void initState() {
    super.initState();
    final library = context.read<LibraryProvider>();
    final channel = library.resolveLiveChannel(widget.seed);
    _fromStart = library.catchupItem(channel: channel, program: widget.program);
    unawaited(_hydrateCatchup());
  }

  @override
  void didUpdateWidget(covariant _OnNowShelfCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seed.id != widget.seed.id ||
        oldWidget.program.start != widget.program.start) {
      unawaited(_hydrateCatchup());
    }
  }

  Future<void> _hydrateCatchup() async {
    final library = context.read<LibraryProvider>();
    final channel = library.resolveLiveChannel(widget.seed);
    final item = await library.catchupItemAsync(
      channel: channel,
      program: widget.program,
    );
    if (!mounted) return;
    if (item?.id == _fromStart?.id && item?.playUrl == _fromStart?.playUrl) {
      return;
    }
    setState(() => _fromStart = item);
  }

  void _playLive() {
    final library = context.read<LibraryProvider>();
    unawaited(
      openLivePlayback(context, library.resolveLiveChannel(widget.seed)),
    );
  }

  void _playFromStart() {
    final item = _fromStart;
    if (item == null) return;
    context.push('/player', extra: item);
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final channel = library.resolveLiveChannel(widget.seed);
    final titled = channel.copyWith(title: library.officialLiveTitle(channel));
    return NowOnCard(
      channel: titled,
      program: widget.program,
      channelLabel: titled.title,
      onTap: _playLive,
      onLongPress: (anchor) => showMediaItemActions(
        context: context,
        item: titled,
        anchor: anchor,
        onPlay: _playLive,
        onStartOver: _fromStart == null ? null : _playFromStart,
        showDetails: false,
        showWatchlist: false,
        showDownload: false,
        showPlaylists: false,
      ),
      onPlayFromStart: _fromStart == null ? null : _playFromStart,
    );
  }
}
