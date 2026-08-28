import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/for_you_shelf.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/live_category_page.dart';
import 'package:javp/services/iptv/live_category_pins.dart';
import 'package:javp/l10n/for_you_shelf_l10n.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/live_watch_nav.dart';
import 'package:javp/services/source_filter_selection.dart';
import 'package:javp/services/tv_source_picker.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/filter_chips.dart';
import 'package:javp/widgets/epg_guide_grid.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/widgets/epg_program_sheet.dart';
import 'package:javp/widgets/horizontal_scroll_text.dart';
import 'package:javp/widgets/iptv_category_picker.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/iptv_toolbar.dart';
import 'package:javp/widgets/live_channel_list.dart';
import 'package:javp/widgets/live_quality_picker.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/source_filter_app_bar_chip.dart';
import 'package:javp/widgets/tv/live_category_actions.dart';
import 'package:javp/widgets/tv_source_picker_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live TV: channels + EPG / catchup (no movies/series).
class TvScreen extends StatefulWidget {
  const TvScreen({super.key});

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _liveSearch = TextEditingController();
  final _categorySearch = TextEditingController();
  final _nestedScrollKey = GlobalKey<NestedScrollViewState>();
  ScrollController? _innerScroll;
  Timer? _searchDebounce;
  Timer? _epgPrefetchDebounce;
  List<MediaItem> _cachedLive = const [];
  List<ForYouShelf> _forYouShelves = const [];
  Object? _liveListStamp;
  Widget? _frozenTree;
  Object? _frozenListStamp;
  bool _filterScheduled = false;
  bool _filterRunning = false;
  final Set<String> _epgPrefetchQueued = {};

  bool _scanExhausted = true;
  bool _appendingLive = false;
  Stopwatch? _categorySwitchWatch;
  String? _categorySwitchLabel;

  /// Last category-page source for `I/tv:` logs: sqlite | memory | ensure.
  String _lastLiveFetchFrom = 'sqlite';
  Object? _lastCategoriesLogSig;
  static const _livePageSize = 80;
  static const _chipHome = kLiveChipForYou;
  static const _chipAll = kLiveChipAll;
  static const _chipLocale = kLiveChipLocale;
  static const _tabCategories = 0;
  static const _tabChannels = 1;

  IptvLiveFilter _liveFilter = IptvLiveFilter.all;
  IptvSort _liveSort = IptvSort.playlist;

  /// `null` = For you (favorites+recents+locale). [kIptvCategoryAllId] = All. Else category id.
  String? _liveCategoryId;

  /// Full list of locale-matched channels (opened from For you shelf header).
  bool _localeBrowse = false;

  /// Empty = all live sources. Non-empty = include only these source ids.
  Set<String> _sourceKeys = {};
  static const _prefsSourceKey = 'tv.sourceFilterIds';

  List<IptvCategory> _scopedCategories = const [];
  Map<String, int> _scopedCategoryCounts = const {};
  Object? _scopedCategoriesStamp;
  bool _scopedCategoriesLoading = false;
  int _scopedCategoriesGen = 0;

  bool get _isHomeBrowse =>
      _liveCategoryId == null &&
      !_localeBrowse &&
      _liveFilter == IptvLiveFilter.all &&
      _liveSearch.text.trim().isEmpty;

  bool get _isAllBrowse => _liveCategoryId == kIptvCategoryAllId;

  bool get _isLocaleBrowse => _localeBrowse;

  /// Pin lists only affect For you / Favorites / Recents — not All or a category.
  bool get _listDependsOnPins =>
      _isHomeBrowse ||
      _liveFilter == IptvLiveFilter.favorites ||
      _liveFilter == IptvLiveFilter.recents;

  Object _listStampFor(LibraryProvider library) {
    final lockStamp = library.parentalLock?.lockFilterStamp ?? 'none';
    if (_listDependsOnPins) {
      return Object.hash(
        library.liveDbRevision,
        library.hasLiveDb,
        library.sourcesEnabledRevision,
        library.sourcesAppearanceRevision,
        _liveFilter,
        _liveSort,
        _liveCategoryId,
        _localeBrowse,
        sourceSelectionStamp(_sourceKeys),
        _liveSearch.text,
        library.favoriteChannelIds.length,
        library.favoriteCategoryIds.length,
        library.recentChannelIds.length,
        lockStamp,
      );
    }
    return Object.hash(
      library.liveDbRevision,
      library.hasLiveDb,
      library.sourcesEnabledRevision,
      library.sourcesAppearanceRevision,
      _liveFilter,
      _liveSort,
      _liveCategoryId,
      _localeBrowse,
      sourceSelectionStamp(_sourceKeys),
      _liveSearch.text,
      lockStamp,
    );
  }

  String? _groupNameFor(LibraryProvider library) {
    if (_liveCategoryId == null || _isAllBrowse) return null;
    final cat = _categoriesFor(library).cast<IptvCategory?>().firstWhere(
      (c) => c?.id == _liveCategoryId,
      orElse: () => null,
    );
    return cat?.name;
  }

  List<IptvCategory> _categoriesFor(LibraryProvider library) {
    final fromProvider = _sourceKeys.isEmpty
        ? library.liveCategories
        : [
            for (final c in library.liveCategories)
              if (c.sourceId == null || _sourceKeys.contains(c.sourceId)) c,
          ];
    return tvLiveCategoriesForBrowse(
      scoped: _scopedCategories,
      fromProvider: fromProvider,
    );
  }

  /// Categories for chips / Categories tab — favorites (bookmarked) first.
  List<IptvCategory> _categoriesSortedFor(LibraryProvider library) =>
      iptvCategoriesWithFavoritesFirst(
        _categoriesFor(library),
        library.favoriteCategoryIds,
      );

  Object _scopedStampFor(LibraryProvider library) => Object.hash(
    library.liveDbRevision,
    library.hasLiveDb,
    sourceSelectionStamp(_sourceKeys),
    library.parentalLock?.lockFilterStamp ?? 'none',
    Object.hashAll([for (final c in library.liveCategories) c.id]),
  );

  Future<void> _reloadScopedCategories(
    LibraryProvider library, {
    bool loadCounts = false,
  }) async {
    final gen = ++_scopedCategoriesGen;
    final sourceKeys = Set<String>.from(_sourceKeys);
    final sourceIds = sourceKeys.isEmpty ? null : sourceKeys;
    final stamp = _scopedStampFor(library);
    // Keep the prior list visible while refreshing — clearing it made chips /
    // Categories flash empty (and looked like a sync failure).
    if (mounted) {
      setState(() {
        _scopedCategoriesLoading = true;
        if (loadCounts) _scopedCategoryCounts = const {};
      });
    } else {
      _scopedCategoriesLoading = true;
      if (loadCounts) _scopedCategoryCounts = const {};
    }

    try {
      // Names first (cheap DISTINCT) so chips/Categories stay responsive.
      final names = await library.liveGroupNames(sourceIds: sourceIds);
      if (!mounted || gen != _scopedCategoriesGen) return;
      final byName = {for (final c in library.liveCategories) c.name: c};
      var cats = <IptvCategory>[
        for (final name in names)
          byName[name] ??
              IptvCategory(id: name, name: name, kind: IptvCategoryKind.live),
      ];
      // Xtream lazy sync: categories exist in the API list before any live DB
      // rows — fall back so chips appear immediately after sync.
      // Also covers M3U/custom: when DISTINCT is empty, still show provider rows.
      bool matchesSource(IptvCategory c) =>
          sourceKeys.isEmpty ||
          c.sourceId == null ||
          sourceKeys.contains(c.sourceId);
      if (cats.isEmpty) {
        cats = [
          for (final c in library.liveCategories)
            if (matchesSource(c)) c,
        ];
      }
      // Prefer union when DB groups are a subset of Xtream API categories
      // (category-first sync fills groups lazily — API list is authoritative).
      if (sourceKeys.isEmpty || cats.isEmpty) {
        final fromProvider = [
          for (final c in library.liveCategories)
            if (matchesSource(c)) c,
        ];
        if (fromProvider.length > cats.length) {
          final seen = {for (final c in cats) c.name};
          cats = [
            ...cats,
            for (final c in fromProvider)
              if (seen.add(c.name)) c,
          ];
        }
      } else {
        // Source-scoped: merge any Xtream rows missing from the live DB yet.
        final seen = {for (final c in cats) c.name};
        for (final c in library.liveCategories) {
          if (!matchesSource(c) || c.sourceId == null) continue;
          if (seen.add(c.name)) cats.add(c);
        }
      }
      final resolved = cats;
      if (!mounted || gen != _scopedCategoriesGen) return;
      setState(() {
        _scopedCategories = resolved;
        _scopedCategoriesStamp = stamp;
        _scopedCategoriesLoading = false;
        if (sourceKeys.isNotEmpty && resolved.isEmpty) {
          _liveCategoryId = kIptvCategoryAllId;
          _liveListStamp = null;
          _frozenTree = null;
        } else if (_liveCategoryId != null &&
            !_isAllBrowse &&
            !resolved.any((c) => c.id == _liveCategoryId)) {
          _liveCategoryId = null;
          _liveListStamp = null;
          _frozenTree = null;
        }
      });

      // GROUP BY counts are expensive — only when Categories is open.
      if (!loadCounts) return;
      final rows = await library.liveGroupCounts(sourceIds: sourceIds);
      if (!mounted || gen != _scopedCategoriesGen) return;
      setState(() {
        _scopedCategoryCounts = {for (final row in rows) row.name: row.count};
      });
    } catch (_) {
      if (!mounted || gen != _scopedCategoriesGen) return;
      setState(() {
        _scopedCategories = [
          for (final c in library.liveCategories)
            if (sourceKeys.isEmpty ||
                c.sourceId == null ||
                sourceKeys.contains(c.sourceId))
              c,
        ];
        if (loadCounts) _scopedCategoryCounts = const {};
        _scopedCategoriesStamp = stamp;
        _scopedCategoriesLoading = false;
      });
    } finally {
      // Stale generations must not clear the newer refresh's loading flag —
      // but if we are still the latest and never painted, drop the spinner.
      if (mounted &&
          gen == _scopedCategoriesGen &&
          _scopedCategoriesLoading) {
        setState(() => _scopedCategoriesLoading = false);
      }
    }
  }

  void _ensureScopedCategories(LibraryProvider library) {
    // Warm group names on Channels too — chips used to depend only on
    // iptv_categories, so M3U/demo (groups in live DB only) looked empty.
    // Expensive GROUP BY counts stay Categories-tab-only.
    final onCategories = _tabs.index == _tabCategories;
    final stamp = _scopedStampFor(library);
    final wantCounts = onCategories;
    if (library.liveCategories.isEmpty) {
      unawaited(
        library.ensureXtreamLiveCategoryRows(
          sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        ),
      );
    }
    if (_scopedCategoriesStamp == stamp) {
      if (wantCounts &&
          _scopedCategoryCounts.isEmpty &&
          _scopedCategories.isNotEmpty &&
          !_scopedCategoriesLoading) {
        unawaited(_reloadScopedCategories(library, loadCounts: true));
      }
      return;
    }
    // Stamp changed while a reload is in-flight: start a new gen instead of
    // keeping the empty first snapshot. The older flight discards on gen.
    unawaited(_reloadScopedCategories(library, loadCounts: wantCounts));
  }

  String _chipSelectedLabel(LibraryProvider library) {
    if (_isLocaleBrowse) return _chipLocale;
    if (_isHomeBrowse) return _chipHome;
    if (_isAllBrowse) return _chipAll;
    return _categoriesFor(library)
            .cast<IptvCategory?>()
            .firstWhere((c) => c?.id == _liveCategoryId, orElse: () => null)
            ?.displayName ??
        _chipHome;
  }

  List<String> _chipLabels(LibraryProvider library) {
    final cats = _categoriesSortedFor(library);
    // Until Categories are loaded, only offer For you / All (no DISTINCT).
    if (cats.isEmpty) {
      final base = <String>[_chipHome, _chipAll];
      if (_isLocaleBrowse && !base.contains(_chipLocale)) {
        base.insert(1, _chipLocale);
      }
      return base;
    }
    final selected = _chipSelectedLabel(library);
    final names = cats.take(14).map((c) => c.displayName).toList();
    final labels = <String>[_chipHome, ...names, _chipAll];
    if (!labels.contains(selected)) {
      labels.insert(1, selected);
    }
    return labels;
  }

  /// Invalidate the browse stamp for a category/source change.
  ///
  /// When [clearStaleChannels] is true (Xtream live DB), drop the previous
  /// category’s rows so we never paint the wrong list while SQLite pages.
  /// Clears For you shelves so category browse cannot paint shelf UI.
  /// (Filter-sheet keep-visible still only nulls the stamp under the scrim.)
  void _beginLiveListReload({bool clearStaleChannels = false}) {
    _frozenTree = null;
    _liveListStamp = null;
    _forYouShelves = const [];
    _scanExhausted = true;
    if (clearStaleChannels) {
      _cachedLive = const [];
    }
  }

  void _markCategorySwitch(String label) {
    _categorySwitchWatch = Stopwatch()..start();
    _categorySwitchLabel = label;
  }

  void _logCategoryListReady({required String from}) {
    final watch = _categorySwitchWatch;
    if (watch == null) return;
    final label = _categorySwitchLabel ?? '?';
    final catId = _liveCategoryId ?? 'home';
    JavpLog.i(
      'tv',
      'category select → list ready in ${watch.elapsedMilliseconds}ms '
          'from=$from category=$catId target=$label count=${_cachedLive.length}',
    );
    _categorySwitchWatch = null;
    _categorySwitchLabel = null;
  }

  /// Instant fill from the in-memory catalog when there is no live DB.
  /// Returns true when [_liveListStamp] was set (async filter can be skipped).
  bool _primeMemoryLiveList(LibraryProvider library) {
    if (library.hasLiveDb) return false;
    if (_isHomeBrowse || _isLocaleBrowse) return false;
    if (_liveFilter != IptvLiveFilter.all) return false;
    if (_liveSearch.text.trim().isNotEmpty) return false;

    _cachedLive = _filterLive(library);
    _liveListStamp = _listStampFor(library);
    _scanExhausted = true;
    _lastLiveFetchFrom = 'memory';
    _logCategoryListReady(from: 'memory');
    return true;
  }

  /// Apply a category/chip target, then page from SQLite (Xtream) or memory.
  void _applyLiveBrowseTarget(
    LibraryProvider library, {
    required void Function() applyTarget,
    bool kickSqlite = true,
  }) {
    setState(() {
      _beginLiveListReload(clearStaleChannels: library.hasLiveDb);
      applyTarget();
      if (!library.hasLiveDb) {
        _primeMemoryLiveList(library);
      }
    });
    if (kickSqlite && library.hasLiveDb && _liveListStamp == null) {
      _scheduleFilter(library, immediate: true);
    }
  }

  void _onChipSelected(LibraryProvider library, String label) {
    if (label == _chipHome) {
      _markCategorySwitch(_chipHome);
      _applyLiveBrowseTarget(
        library,
        applyTarget: () {
          _liveCategoryId = null;
          _localeBrowse = false;
          _liveFilter = IptvLiveFilter.all;
        },
      );
      return;
    }
    if (label == _chipLocale) {
      _markCategorySwitch(_chipLocale);
      _applyLiveBrowseTarget(
        library,
        applyTarget: () {
          _liveCategoryId = null;
          _localeBrowse = true;
          _liveFilter = IptvLiveFilter.all;
        },
      );
      return;
    }
    if (label == _chipAll) {
      _markCategorySwitch(_chipAll);
      _applyLiveBrowseTarget(
        library,
        applyTarget: () {
          _liveCategoryId = kIptvCategoryAllId;
          _localeBrowse = false;
          _liveFilter = IptvLiveFilter.all;
        },
      );
      return;
    }
    final cat = _categoriesFor(library).cast<IptvCategory?>().firstWhere(
      (c) => c?.name == label || c?.displayName == label,
      orElse: () => null,
    );
    if (cat == null) return;
    _markCategorySwitch(cat.name);
    _applyLiveBrowseTarget(
      library,
      applyTarget: () {
        _liveCategoryId = cat.id;
        _localeBrowse = false;
        _liveFilter = IptvLiveFilter.all;
      },
    );
  }

  void _openCategory(IptvCategory category) {
    final library = context.read<LibraryProvider>();
    _markCategorySwitch(category.name);
    _applyLiveBrowseTarget(
      library,
      applyTarget: () {
        _liveCategoryId = category.id;
        _localeBrowse = false;
        _liveFilter = IptvLiveFilter.all;
        _tabs.index = _tabChannels;
      },
    );
  }

  void _openLocaleBrowse() {
    final library = context.read<LibraryProvider>();
    _markCategorySwitch(_chipLocale);
    _applyLiveBrowseTarget(
      library,
      applyTarget: () {
        _localeBrowse = true;
        _liveCategoryId = null;
        _liveFilter = IptvLiveFilter.all;
        _tabs.index = _tabChannels;
      },
    );
  }

  List<MediaItem> _sourceFilter(Iterable<MediaItem> channels) {
    if (_sourceKeys.isEmpty) return channels.toList();
    return [
      for (final channel in channels)
        if (sourceMatchesFilter(channel.sourceId, _sourceKeys)) channel,
    ];
  }

  void _scheduleFilter(LibraryProvider library, {bool immediate = false}) {
    if (_filterRunning) return;
    if (immediate) {
      // Prefer an immediate SQLite page over a pending post-frame pass.
      _filterScheduled = false;
      unawaited(_runLiveFilter(library));
      return;
    }
    if (_filterScheduled) return;
    _filterScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _filterScheduled = false;
      if (!mounted) return;
      await _runLiveFilter(library);
    });
  }

  Future<void> _runLiveFilter(LibraryProvider library) async {
    if (!mounted || _filterRunning) return;
    _filterRunning = true;
    // Keep scroll across pin-driven For you refreshes (open/minimize watch).
    final liveScroll = _innerScroll;
    final savedOffset = liveScroll != null && liveScroll.hasClients
        ? liveScroll.offset
        : null;
    _scanExhausted = false;
    _appendingLive = false;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) {
      _filterRunning = false;
      return;
    }
    // Capture after yield so a category chip tap mid-flight is not stamped
    // with the previous For you / All selection.
    final stamp = _listStampFor(library);

    if (_liveFilter == IptvLiveFilter.favorites) {
      _forYouShelves = const [];
      _cachedLive = [
        for (final c in _sourceFilter(library.favoriteChannels))
          c.copyWith(title: library.officialLiveTitle(c)),
      ];
      _scanExhausted = true;
      _lastLiveFetchFrom = 'memory';
    } else if (_liveFilter == IptvLiveFilter.recents) {
      _forYouShelves = const [];
      _cachedLive = [
        for (final c in _sourceFilter(library.recentChannels))
          c.copyWith(title: library.officialLiveTitle(c)),
      ];
      _scanExhausted = true;
      _lastLiveFetchFrom = 'memory';
    } else if (_isHomeBrowse) {
      // Device locale (not MaterialApp's resolved UI locale — that falls
      // back to en_US when French/etc. aren't in supportedLocales).
      // IptvLocaleHints.normalize remaps Fire OS fr_CA → fr_FR in Europe;
      // Americas offsets keep CA for Québec.
      final locale = WidgetsBinding.instance.platformDispatcher.locale;
      // Instant shelves from in-memory favs/recents — no SQLite DISTINCT.
      var quick = await library.buildForYouLiveShelves(
        sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        locale: locale,
        includeLocaleSamples: false,
      );
      if (!mounted || _listStampFor(library) != stamp) {
        _filterRunning = false;
        if (mounted) _scheduleFilter(library, immediate: true);
        return;
      }
      // Xtream category-first: Home can be empty while groups exist but
      // streams are not in SQLite yet. Demand-fill instead of waiting on idle.
      if (quick.isEmpty) {
        await library.ensureLiveListingsWarm(
          sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        );
        if (!mounted || _listStampFor(library) != stamp) {
          _filterRunning = false;
          if (mounted) _scheduleFilter(library, immediate: true);
          return;
        }
        quick = await library.buildForYouLiveShelves(
          sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
          locale: locale,
          includeLocaleSamples: true,
        );
        if (!mounted || _listStampFor(library) != stamp) {
          _filterRunning = false;
          if (mounted) _scheduleFilter(library, immediate: true);
          return;
        }
      }
      if (quick.isEmpty) {
        // For you is recents / favs / locale-named groups. If none of those
        // match, still show the live list so Direct is not a blank page.
        _forYouShelves = const [];
        if (!library.hasLiveDb) {
          _cachedLive = _filterLive(library);
          _scanExhausted = true;
          _lastLiveFetchFrom = 'memory';
        } else {
          final page = await _fetchLivePage(
            library,
            stamp,
            offset: 0,
            limit: _livePageSize,
          );
          if (!mounted || _listStampFor(library) != stamp) {
            _filterRunning = false;
            if (mounted) _scheduleFilter(library, immediate: true);
            return;
          }
          _cachedLive = page;
          _scanExhausted = page.length < _livePageSize;
          _lastLiveFetchFrom = 'all-fallback';
        }
        JavpLog.i(
          'tv',
          'Direct For you empty → listing from=$_lastLiveFetchFrom '
              'count=${_cachedLive.length}',
        );
      } else {
        _forYouShelves = quick;
        final flat = <MediaItem>[];
        final seen = <String>{};
        for (final shelf in quick) {
          for (final channel in shelf.channels) {
            if (!seen.add(channel.id)) continue;
            flat.add(channel);
          }
        }
        _cachedLive = flat;
        _scanExhausted = true;
        _lastLiveFetchFrom = 'memory';
        unawaited(_enrichForYouLocale(library, stamp, locale));
      }
    } else if (_isLocaleBrowse || library.hasLiveDb) {
      _forYouShelves = const [];
      // SQLite-first page into a local buffer — swap atomically in setState.
      final page = await _fetchLivePage(
        library,
        stamp,
        offset: 0,
        limit: _livePageSize,
      );
      if (!mounted || _listStampFor(library) != stamp) {
        _filterRunning = false;
        if (mounted) _scheduleFilter(library, immediate: true);
        return;
      }
      _cachedLive = page;
      _scanExhausted = page.length < _livePageSize;
    } else {
      _forYouShelves = const [];
      final items = _filterLive(library);
      if (!mounted) {
        _filterRunning = false;
        return;
      }
      _cachedLive = items;
      _scanExhausted = true;
      _lastLiveFetchFrom = 'memory';
    }

    if (!mounted) {
      _filterRunning = false;
      return;
    }
    // Category/source changed while we were loading — discard and retry.
    if (_listStampFor(library) != stamp) {
      _filterRunning = false;
      _scheduleFilter(library, immediate: true);
      return;
    }
    setState(() {
      _liveListStamp = stamp;
      _frozenTree = null;
      _filterRunning = false;
    });
    _logCategoryListReady(from: _lastLiveFetchFrom);
    if (savedOffset != null && savedOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scroll = _innerScroll;
        if (!mounted || scroll == null || !scroll.hasClients) return;
        final max = scroll.position.maxScrollExtent;
        scroll.jumpTo(savedOffset.clamp(0.0, max));
      });
    }
    _prefetchVisibleEpg(library);
    if (!_scanExhausted &&
        !_isHomeBrowse &&
        (_isLocaleBrowse || library.hasLiveDb)) {
      unawaited(_warmLivePages(library, stamp));
    }
  }

  Future<void> _enrichForYouLocale(
    LibraryProvider library,
    Object stamp,
    Locale locale,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted || _liveListStamp != stamp || !_isHomeBrowse) return;
    final shelves = await library.buildForYouLiveShelves(
      sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
      locale: locale,
      includeLocaleSamples: true,
    );
    if (!mounted || _liveListStamp != stamp || !_isHomeBrowse) return;
    final flat = <MediaItem>[];
    final seen = <String>{};
    for (final shelf in shelves) {
      for (final channel in shelf.channels) {
        if (!seen.add(channel.id)) continue;
        flat.add(channel);
      }
    }
    setState(() {
      _forYouShelves = shelves;
      _cachedLive = flat;
      _frozenTree = null;
    });
    _prefetchVisibleEpg(library);
  }

  Future<void> _warmLivePages(LibraryProvider library, Object stamp) async {
    if (!mounted || _liveListStamp != stamp || _scanExhausted) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted || _liveListStamp != stamp || _scanExhausted) return;
    final before = _cachedLive.length;
    await _appendLivePage(library, stamp, targetCount: before + _livePageSize);
    if (!mounted || _liveListStamp != stamp) return;
    if (_cachedLive.length > before) {
      setState(() => _frozenTree = null);
    }
  }

  Future<void> _loadMoreLive() async {
    if (!mounted ||
        _filterRunning ||
        _appendingLive ||
        _scanExhausted ||
        (_isHomeBrowse && _forYouShelves.isNotEmpty)) {
      return;
    }
    final stamp = _liveListStamp;
    if (stamp == null) return;
    final library = context.read<LibraryProvider>();
    if (!_isLocaleBrowse &&
        !library.hasLiveDb &&
        (_isAllBrowse || _isHomeBrowse || _liveCategoryId == null)) {
      return;
    }
    _appendingLive = true;
    try {
      final before = _cachedLive.length;
      await _appendLivePage(
        library,
        stamp,
        targetCount: before + _livePageSize,
      );
      if (mounted && _liveListStamp == stamp && _cachedLive.length > before) {
        setState(() => _frozenTree = null);
      }
    } finally {
      _appendingLive = false;
    }
  }

  Future<void> _appendLivePage(
    LibraryProvider library,
    Object stamp, {
    required int targetCount,
  }) async {
    final need = targetCount - _cachedLive.length;
    if (need <= 0) {
      _scanExhausted = true;
      return;
    }
    final page = await _fetchLivePage(
      library,
      stamp,
      offset: _cachedLive.length,
      limit: need,
    );
    if (!mounted || (_liveListStamp != null && _liveListStamp != stamp)) {
      return;
    }
    _cachedLive = [..._cachedLive, ...page];
    _scanExhausted = page.length < need;
  }

  /// One live page for the current browse target.
  ///
  /// Xtream: page SQLite first via [LibraryProvider.pageLiveChannels]. Only
  /// calls [LibraryProvider.ensureLiveCategoryAvailable] when the group is
  /// empty (already-synced categories skip the network round-trip).
  Future<List<MediaItem>> _fetchLivePage(
    LibraryProvider library,
    Object stamp, {
    required int offset,
    required int limit,
  }) async {
    final q = _liveSearch.text.trim();
    if (_isLocaleBrowse) {
      _lastLiveFetchFrom = 'sqlite';
      final page = await library.pageLocaleLiveChannels(
        locale: WidgetsBinding.instance.platformDispatcher.locale,
        sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        query: q.isEmpty ? null : q,
        offset: offset,
        limit: limit,
      );
      if (page.isNotEmpty) {
        library.scheduleCatalogRevalidate(
          sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        );
      }
      return page;
    }

    Future<List<MediaItem>> pageOnce() {
      if (!library.hasLiveDb) return Future.value(const []);
      return library.pageLiveChannels(
        groupName: _groupNameFor(library),
        sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
        query: q.isEmpty ? null : q,
        offset: offset,
        limit: limit,
        catchupFirst: _liveFilter == IptvLiveFilter.catchup,
        catchupOnly: _liveFilter == IptvLiveFilter.catchup,
        sort: _liveSort.listingSort,
      );
    }

    IptvCategory? cat;
    if (!_isAllBrowse && !_isHomeBrowse) {
      cat = _categoriesFor(library).cast<IptvCategory?>().firstWhere(
        (c) => c?.id == _liveCategoryId,
        orElse: () => null,
      );
    }

    // Prefer an immediate SQLite page; ensure/fetch only when the group is cold.
    var page = await pageOnce();
    if (page.isNotEmpty) {
      _lastLiveFetchFrom = 'sqlite';
      library.scheduleCatalogRevalidate(
        sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
      );
      return page;
    }
    if (offset > 0) {
      _lastLiveFetchFrom = 'sqlite';
      return page;
    }
    if (cat != null) {
      await library.ensureLiveCategoryAvailable(cat);
    } else {
      await library.ensureLiveListingsWarm(
        sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
      );
    }
    if (!mounted || (_liveListStamp != null && _liveListStamp != stamp)) {
      return const [];
    }
    _lastLiveFetchFrom = 'ensure';
    return pageOnce();
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 3,
      vsync: this,
      // Channels first — Categories GROUP BY waits until that tab is opened.
      initialIndex: _tabChannels,
    );
    _tabs.addListener(_onTabChanged);
    _categorySearch.addListener(() {
      if (mounted && _tabs.index == _tabCategories) setState(() {});
    });
    unawaited(_restoreSourceFilter());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _epgPrefetchDebounce?.cancel();
    _innerScroll?.removeListener(_onInnerScroll);
    _innerScroll = null;
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _liveSearch.dispose();
    _categorySearch.dispose();
    super.dispose();
  }

  /// NestedScrollView's body primary controller (Channels / Categories / Guide).
  void _ensureInnerScrollListener() {
    final inner = _nestedScrollKey.currentState?.innerController;
    if (inner == null || identical(inner, _innerScroll)) return;
    _innerScroll?.removeListener(_onInnerScroll);
    _innerScroll = inner;
    _innerScroll!.addListener(_onInnerScroll);
  }

  void _onInnerScroll() {
    if (_tabs.index != _tabChannels) return;
    _onLiveScroll();
  }

  String _liveCountLabel(
    LibraryProvider library,
    int shown, {
    required bool exhausted,
  }) {
    final n = exhausted ? '$shown' : '$shown+';
    final at = library.newestCatalogSyncAt(
      sourceIds: _sourceKeys.isEmpty ? null : _sourceKeys,
    );
    if (at == null) return n;
    return '$n · ${LibraryProvider.formatCacheAge(at)}';
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging && mounted) {
      _frozenTree = null;
      setState(() {});
      if (_tabs.index == _tabCategories) {
        _ensureScopedCategories(context.read<LibraryProvider>());
      }
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (mounted) {
        _frozenTree = null;
        _liveListStamp = null;
        setState(() {});
      }
    });
  }

  void _onLiveScroll() {
    _scheduleVisibleEpgPrefetch();
    final scroll = _innerScroll;
    if (scroll == null || !scroll.hasClients || _scanExhausted) return;
    final pos = scroll.position;
    if (pos.pixels > pos.maxScrollExtent - 900) {
      unawaited(_loadMoreLive());
    }
  }

  void _scheduleVisibleEpgPrefetch() {
    _epgPrefetchDebounce?.cancel();
    _epgPrefetchDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!mounted || _tabs.index != _tabChannels) return;
      _prefetchVisibleEpg(context.read<LibraryProvider>());
    });
  }

  void _prefetchVisibleEpg(LibraryProvider library) {
    if (_cachedLive.isEmpty) return;
    const extent = 72.0;
    final scroll = _innerScroll;
    final offset = scroll != null && scroll.hasClients ? scroll.offset : 0.0;
    final viewport = scroll != null && scroll.hasClients
        ? scroll.position.viewportDimension
        : 800.0;
    final first = (offset / extent).floor().clamp(0, _cachedLive.length);
    final last = ((offset + viewport) / extent).ceil().clamp(
      0,
      _cachedLive.length,
    );
    final slice = _cachedLive.sublist(first, last);
    final need = <MediaItem>[];
    for (final channel in slice) {
      final streamId = channel.streamId;
      if (streamId == null) continue;
      if (library.isGuideFetched(channel) || library.isGuideLoading(channel)) {
        continue;
      }
      if (!_epgPrefetchQueued.add(streamId)) continue;
      need.add(channel);
      if (need.length >= 12) break;
    }
    if (need.isEmpty) return;
    unawaited(
      library.fetchChannelGuides(need, concurrency: 6).whenComplete(() {
        for (final channel in need) {
          final id = channel.streamId;
          if (id == null) continue;
          if (!library.isGuideFetched(channel)) {
            _epgPrefetchQueued.remove(id);
          }
        }
      }),
    );
  }

  List<MediaItem> _filterLive(LibraryProvider library) {
    // Prefer group index — avoids walking 28k channels for a category page.
    final groupName = _groupNameFor(library);

    var items = library.filterBySource(
      library.liveChannelsInGroup(groupName),
      sourceKeys: _sourceKeys.isEmpty ? null : _sourceKeys,
    );

    items = switch (_liveFilter) {
      IptvLiveFilter.all => items,
      IptvLiveFilter.favorites =>
        items.where((c) => library.isFavoriteChannel(c)).toList(),
      IptvLiveFilter.recents => () {
        final recentIds = library.recentChannelIds.toSet();
        final matched = items.where((c) => recentIds.contains(c.id)).toList();
        matched.sort(
          (a, b) => library.recentChannelIds
              .indexOf(a.id)
              .compareTo(library.recentChannelIds.indexOf(b.id)),
        );
        return matched;
      }(),
      IptvLiveFilter.catchup => items
          .where((c) => library.liveSupportsCatchup(c))
          .toList(),
      IptvLiveFilter.hasEpg =>
        items
            .where(
              (c) =>
                  c.epgChannelId != null && c.epgChannelId!.trim().isNotEmpty,
            )
            .toList(),
    };

    final q = _liveSearch.text;
    if (q.trim().isNotEmpty) {
      items = items
          .where(
            (c) => iptvMatchesQuery(q, [
              c.title,
              c.channelName,
              c.group,
              c.epgChannelId,
              c.streamId,
              c.channelId,
            ]),
          )
          .toList();
    }

    items = [...items];
    switch (_liveSort) {
      case IptvSort.playlist:
        // Keep provider/playlist order from the catalog / sync.
        break;
      case IptvSort.nameAsc:
        items.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case IptvSort.categoryAsc:
        items.sort((a, b) {
          final g = (a.group ?? '').compareTo(b.group ?? '');
          if (g != 0) return g;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      case IptvSort.catchupFirst:
        items.sort((a, b) {
          final c =
              (library.liveSupportsCatchup(b) ? 1 : 0) -
              (library.liveSupportsCatchup(a) ? 1 : 0);
          if (c != 0) return c;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
    }
    return library.collapseLiveQualities(items);
  }

  Future<void> _pickLiveQuality(
    LibraryProvider library,
    MediaItem channel,
  ) async {
    final chosen = await showLiveQualityPicker(
      context: context,
      channel: channel,
    );
    if (chosen == null) {
      final variants = await library.qualityVariantsForAsync(channel);
      if (variants.length <= 1 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.noOtherQualitiesForEpgId)),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _pickLiveCategory(LibraryProvider library) async {
    final selected = await showIptvCategoryPicker(
      context: context,
      title: context.l10n.liveCategories,
      categories: _categoriesSortedFor(library),
      selectedId: _liveCategoryId,
      includeAll: true,
      allKind: IptvCategoryKind.live,
    );
    if (selected == null) return;
    _markCategorySwitch(selected.name);
    _applyLiveBrowseTarget(
      library,
      applyTarget: () {
        // Keep All as kIptvCategoryAllId; null stays reserved for For you.
        _liveCategoryId = selected.id;
        _localeBrowse = false;
        _liveFilter = IptvLiveFilter.all;
      },
    );
  }

  Future<void> _showLiveSortPicker() async {
    final chosen = await showAppModal<IptvSort>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Text(
                context.l10n.sortLiveChannels,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final sort in IptvSort.values)
                ListTile(
                  title: Text(sort.label(context.l10n)),
                  trailing: sort == _liveSort
                      ? const Icon(Icons.check, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.pop(context, sort),
                ),
            ],
          ),
        );
      },
    );
    if (chosen != null) setState(() => _liveSort = chosen);
  }

  Future<void> _pickSource(LibraryProvider library) async {
    final pickerSources = library.parentalVisibleSources;
    final available = tvPickerSources(
      sources: pickerSources,
      liveOnly: false,
      selectedIds: _sourceKeys,
    );
    final selected = normalizeSourceSelection(
      _sourceKeys,
      availableIds: [for (final s in available) s.id],
    );
    final chosen = await showTvSourcePickerSheet(
      context: context,
      sources: pickerSources,
      selectedIds: selected,
    );
    if (chosen == null || !mounted) return;
    final next = normalizeSourceSelection(
      chosen,
      availableIds: [for (final s in available) s.id],
    );
    if (sourceSelectionStamp(next) == sourceSelectionStamp(_sourceKeys)) {
      return;
    }
    setState(() {
      _beginLiveListReload(clearStaleChannels: library.hasLiveDb);
      _sourceKeys = next;
      // For you is for the combined catalog; a concrete subset opens All.
      _liveCategoryId = next.isEmpty ? null : kIptvCategoryAllId;
      _localeBrowse = false;
      _liveFilter = IptvLiveFilter.all;
      if (!library.hasLiveDb) {
        _primeMemoryLiveList(library);
      }
    });
    if (library.hasLiveDb && _liveListStamp == null) {
      _scheduleFilter(library, immediate: true);
    }
    unawaited(_persistSourceFilter());
    await _reloadScopedCategories(
      library,
      loadCounts: _tabs.index == _tabCategories,
    );
  }

  Future<void> _restoreSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = decodeSourceSelection(prefs.getString(_prefsSourceKey));
    if (!mounted || decoded.isEmpty) return;
    setState(() {
      _sourceKeys = decoded;
      _liveListStamp = null;
      _frozenTree = null;
    });
  }

  Future<void> _persistSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSourceKey, encodeSourceSelection(_sourceKeys));
  }

  String _sourceLabel(LibraryProvider library) {
    final byId = {for (final s in library.parentalVisibleSources) s.id: s.name};
    return sourceFilterChipLabel(
      selected: _sourceKeys,
      nameForId: (id) => byId[id] ?? id,
      allLabel: context.l10n.allSources,
      nSourcesLabel: context.l10n.nSources,
    );
  }

  Color? _sourceFilterAccent(LibraryProvider library) {
    if (_sourceKeys.length != 1) return null;
    return library.colorForSourceId(_sourceKeys.single);
  }

  Future<void> _showLiveFilters(LibraryProvider library) async {
    await showAppModal<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModal) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.l10n.liveFilters,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final filter in IptvLiveFilter.values)
                          ChoiceChip(
                            label: Text(filter.label(context.l10n)),
                            selected: _liveFilter == filter,
                            onSelected: (_) {
                              setState(() {
                                _liveFilter = filter;
                                if (filter != IptvLiveFilter.all) {
                                  _localeBrowse = false;
                                }
                                // Invalidate stamp only — keep _frozenTree so
                                // the list stays visible under this sheet.
                                _liveListStamp = null;
                              });
                              setModal(() {});
                            },
                            selectedColor: AppColors.accent,
                            showCheckmark: false,
                          ),
                      ],
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.sort_rounded),
                      title: Text(_liveSort.label(context.l10n)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        Navigator.pop(context);
                        await _showLiveSortPicker();
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_open_outlined),
                      title: Text(
                        _isLocaleBrowse
                            ? context.l10n.inYourLanguage
                            : _isHomeBrowse
                            ? context.l10n.forYou
                            : _isAllBrowse
                            ? context.l10n.allCategories
                            : (_categoriesFor(library)
                                      .cast<IptvCategory?>()
                                      .firstWhere(
                                        (c) => c?.id == _liveCategoryId,
                                        orElse: () => null,
                                      )
                                      ?.displayName ??
                                  context.l10n.category),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        Navigator.pop(context);
                        await _pickLiveCategory(library);
                      },
                    ),
                    if (_liveFilter != IptvLiveFilter.all ||
                        _liveCategoryId != null ||
                        _localeBrowse)
                      AppActionButton(
                        variant: AppActionButtonVariant.text,
                        onPressed: () {
                          setState(() {
                            _beginLiveListReload();
                            _liveFilter = IptvLiveFilter.all;
                            _liveCategoryId = null;
                            _localeBrowse = false;
                          });
                          Navigator.pop(context);
                        },
                        label: context.l10n.backToForYou,
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLiveBody({
    required LibraryProvider library,
    required List<MediaItem> filteredLive,
  }) {
    final useShelves = _isHomeBrowse && _forYouShelves.isNotEmpty;
    return Selector<LibraryProvider, int>(
      selector: (_, l) =>
          Object.hash(l.epgRevision, l.favoriteChannelIds.length),
      builder: (context, _, _) {
        if (useShelves) {
          return CustomScrollView(
            slivers: [
              for (final shelf in _forYouShelves) ...[
                SliverToBoxAdapter(child: _forYouShelfHeader(context, shelf)),
                LiveChannelSliverList(
                  itemCount: shelf.channels.length,
                  itemBuilder: (context, index) =>
                      _liveChannelTile(context, library, shelf.channels[index]),
                ),
              ],
              SliverToBoxAdapter(child: MiniPlayerScrollClearance()),
            ],
          );
        }
        return LiveChannelList(
          itemCount: filteredLive.length,
          itemBuilder: (context, index) =>
              _liveChannelTile(context, library, filteredLive[index]),
        );
      },
    );
  }

  Widget _forYouShelfHeader(BuildContext context, ForYouShelf shelf) {
    final localized = localizeForYouShelf(context.l10n, shelf);
    final openAll = shelf.id == 'locale';
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800);
    final subtitleStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted);

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localized.title, style: titleStyle),
        if (localized.subtitle != null && localized.subtitle!.isNotEmpty)
          Text(localized.subtitle!, style: subtitleStyle),
      ],
    );

    if (!openAll) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: text,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openLocaleBrowse,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
          child: Row(
            children: [
              Expanded(child: text),
              Text(
                context.l10n.seeAll,
                style: subtitleStyle?.copyWith(fontWeight: FontWeight.w600),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _liveChannelTile(
    BuildContext context,
    LibraryProvider library,
    MediaItem item,
  ) {
    final fav = library.isFavoriteChannel(item);
    final now = library.nowPlayingFor(item);
    final moment = DateTime.now();
    final canStartOver =
        now != null && (library.liveSupportsCatchup(item) || now.hasArchive);
    final String? subtitle;
    final double? programProgress;
    if (now != null) {
      subtitle = '${now.title} · ${_liveProgramWindow(now.start, now.end)}';
      programProgress = now.progressAt(moment);
    } else {
      subtitle = item.subtitle;
      programProgress = null;
    }
    final tileItem = item.copyWith(subtitle: subtitle);
    final variants = library.liveVariantCount(item);
    return MediaTile(
      item: tileItem,
      sourceLabel: library.sourceLabelFor(item),
      variantCount: variants > 1 ? variants : null,
      programImageUrl: now?.imageUrl,
      programProgress: programProgress,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canStartOver)
            IconButton(
              tooltip: context.l10n.startOver,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => _startOverChannel(library, item, now),
              icon: const Icon(
                Icons.restart_alt_rounded,
                color: AppColors.accent,
                size: 20,
              ),
            ),
          IconButton(
            tooltip: fav
                ? context.l10n.removeFavorite
                : context.l10n.favoriteChannel,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => library.toggleFavoriteChannel(item),
            icon: Icon(
              fav ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 20,
              color: fav ? AppColors.accent : AppColors.textMuted,
            ),
          ),
        ],
      ),
      onTap: () => openLivePlayback(context, item),
      onLongPress: (anchor) => showMediaItemActions(
        context: context,
        item: item,
        anchor: anchor,
        onPlay: () => openLivePlayback(context, item),
        onPickQuality: () => _pickLiveQuality(library, item),
        onStartOver: canStartOver
            ? () => _startOverChannel(library, item, now)
            : null,
        showDetails: false,
        showWatchlist: false,
        showDownload: false,
        showPlaylists: false,
      ),
    );
  }

  Future<void> _startOverChannel(
    LibraryProvider library,
    MediaItem channel,
    EpgProgram program,
  ) async {
    final item = await library.catchupItemAsync(
      channel: channel,
      program: program,
    );
    if (!mounted) return;
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.startOverUnavailable)),
      );
      return;
    }
    context.push('/player', extra: item);
  }

  String _liveProgramClock(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _liveProgramWindow(DateTime start, DateTime end) {
    return '${_liveProgramClock(start)}–${_liveProgramClock(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final active = ShellVisibility.isActive(context);
    // Freeze under Player/Search/etc. — otherwise recordWatch on open/minimize
    // reloads the channel list and jumps scroll to the top when you return.
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);

    final library = context.read<LibraryProvider>();
    // Cheap listen only — do not walk the live catalog.
    // EPG/favorite row updates use Selector on the list, not this scaffold.
    context.select<LibraryProvider, int>((l) {
      // Soft sync / idle live fill must not rematerialize the TV tree every
      // tick — ignore syncStatus/loading; liveDbRevision is coalesced during
      // prefetch so category chips/lists refresh once when fill settles.
      final base = Object.hash(
        l.liveDbRevision,
        l.hasLiveDb,
        l.sources.length,
        l.sourcesEnabledRevision,
        l.sourcesAppearanceRevision,
        l.liveCategories.length,
        l.parentalLock?.lockFilterStamp ?? 'none',
      );
      // Categories tab always needs favorite pins for sort + star state.
      final needPins = _listDependsOnPins || _tabs.index == _tabCategories;
      if (!needPins) return base;
      return Object.hash(
        base,
        l.favoriteChannelIds.length,
        l.favoriteCategoryIds.length,
        Object.hashAll(l.favoriteCategoryIds),
        l.recentChannelIds.length,
      );
    });

    // Shell tab hidden: keep Element tree; SkipLayout skips layout/paint.
    if (!active) {
      if (_frozenTree != null) return _frozenTree!;
      return const SizedBox.expand();
    }
    // Route on top (player / search / filter sheets): keep the last painted
    // tree so translucent sheets still show channels under the scrim. Skip
    // rebuild + filter work until the covering route pops.
    if (covered) {
      if (_frozenTree != null) return _frozenTree!;
      return const SizedBox.expand();
    }

    final listStamp = _listStampFor(library);
    // Stamp match means the painted list matches the browse target. Do not gate
    // on [_filterRunning] — an in-flight SQLite page can ready the list while
    // an older filter flight is still draining (it discards on stamp mismatch).
    final listReady = _liveListStamp == listStamp;
    _ensureScopedCategories(library);

    if (!listReady) {
      _scheduleFilter(library);
    }

    final cats = _categoriesSortedFor(library);
    // Re-entering TV with a warm tree (EPG arrives without invalidating this).
    // Live category ids belong here: disk hydrate does not bump liveDbRevision,
    // so an empty Categories first frame used to freeze and stay blank.
    final freezeStamp = tvLiveScaffoldFreezeStamp(
      listStamp: listStamp,
      tabIndex: _tabs.index,
      categorySearch: _categorySearch.text,
      favoriteCategoryIds: library.favoriteCategoryIds,
      liveCategoryIds: [for (final c in cats) c.id],
      scopedCount: _scopedCategories.length,
      scopedLoading: _scopedCategoriesLoading,
    );
    if (_frozenTree != null &&
        _frozenListStamp == freezeStamp &&
        (_tabs.index != _tabChannels || listReady)) {
      _logCategoriesTab(library, cats, frozen: true);
      return _frozenTree!;
    }
    _logCategoriesTab(library, cats, frozen: false);

    final filteredLive = listReady ? _cachedLive : _cachedLive;
    final multiSource =
        tvPickerSources(
          sources: library.parentalVisibleSources,
          liveOnly: false,
        ).length >
        1;
    final liveFiltersActive =
        _liveFilter != IptvLiveFilter.all ||
        _liveCategoryId != null ||
        _localeBrowse ||
        _liveSort != IptvSort.playlist ||
        _sourceKeys.isNotEmpty;
    final hasLiveCapableSource = library.parentalVisibleSources.any(
      (s) => s.enabled,
    );
    final showLoading =
        (!listReady && filteredLive.isEmpty) ||
        (filteredLive.isEmpty &&
            hasLiveCapableSource &&
            (library.syncStatus != null || library.loading));
    final emptyMessage = _isLocaleBrowse
        ? context.l10n.noChannelsMatchedLanguage
        : hasLiveCapableSource
        ? context.l10n.noChannelsInThisList
        : context.l10n.noLiveChannelsYet;
    final chipLabels = _chipLabels(library);
    final chipSelected = _chipSelectedLabel(library);
    final sourceLabel = _sourceLabel(library);

    final tree = Scaffold(
      backgroundColor: Colors.transparent,
      body: NestedScrollView(
        key: _nestedScrollKey,
        floatHeaderSlivers: true,
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              floating: true,
              snap: true,
              toolbarHeight: 44,
              titleSpacing: 12,
              // Match Catalog: opaque chrome while floating over list content.
              backgroundColor: AppColors.bg,
              surfaceTintColor: Colors.transparent,
              title: Text(
                context.l10n.navTv,
                style: Theme.of(
                  context,
                ).appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: TabBar(
                  controller: _tabs,
                  indicatorColor: AppColors.accent,
                  labelColor: AppColors.text,
                  unselectedLabelColor: AppColors.textMuted,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  tabs: [
                    Tab(height: 32, text: context.l10n.categories),
                    Tab(height: 32, text: context.l10n.channels),
                    Tab(height: 32, text: context.l10n.guide),
                  ],
                ),
              ),
              actions: [
                if (multiSource)
                  SourceFilterAppBarChip(
                    label: sourceLabel,
                    active: _sourceKeys.isNotEmpty,
                    accentColor: _sourceFilterAccent(library),
                    onTap: () => unawaited(_pickSource(library)),
                  ),
                if (library.loading ||
                    library.syncStatus != null ||
                    _filterRunning)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => context.push('/sports'),
                  icon: const Icon(Icons.sports_soccer_rounded, size: 20),
                  tooltip: context.l10n.sportsTitle,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => context.push('/search'),
                  icon: const Icon(Icons.travel_explore_rounded, size: 20),
                  tooltip: context.l10n.search,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => context.push('/sources'),
                  icon: const Icon(Icons.dns_outlined, size: 20),
                  tooltip: context.l10n.manageSources,
                ),
              ],
            ),
          ];
        },
        body: Column(
          children: [
            ListenableBuilder(
              listenable: library.syncStatusListenable,
              builder: (context, _) {
                final status = library.syncStatus;
                if (status == null) return const SizedBox.shrink();
                return Material(
                  color: AppColors.surfaceHigh,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            Expanded(
              // Only build the active sub-tab — TabBarView was building Guide too.
              child: _tabs.index == _tabCategories
                  ? _TvCategoriesTab(
                      categories: cats,
                      counts: _scopedCategoryCounts,
                      favoriteCategoryIds: library.favoriteCategoryIds,
                      selectedId: _liveCategoryId,
                      loading:
                          (_scopedCategoriesLoading && cats.isEmpty) ||
                          (cats.isEmpty &&
                              (library.syncStatus != null ||
                                  library.parentalLock?.ready == false)),
                      searchController: _categorySearch,
                      sourceKey: encodeSourceSelection(_sourceKeys),
                      onOpenCategory: _openCategory,
                      onToggleFavorite: library.toggleFavoriteCategory,
                      onCategoryActions: (category) => showLiveCategoryActions(
                        context: context,
                        category: category,
                        onOpen: () => _openCategory(category),
                      ),
                      loadChannels:
                          ({String? query, int offset = 0, int limit = 80}) {
                            Future<List<MediaItem>> page() =>
                                library.pageLiveChannels(
                                  sourceIds: _sourceKeys.isEmpty
                                      ? null
                                      : _sourceKeys,
                                  query: query,
                                  offset: offset,
                                  limit: limit,
                                  sort: _liveSort.listingSort,
                                );
                            if (offset > 0) return page();
                            return pageLiveCategoryWithEnsure(
                              page: page,
                              ensureIfCold: () =>
                                  library.ensureLiveListingsWarm(
                                    sourceIds: _sourceKeys.isEmpty
                                        ? null
                                        : _sourceKeys,
                                  ),
                            );
                          },
                      channelTile: (context, channel) =>
                          _liveChannelTile(context, library, channel),
                    )
                  : _tabs.index == _tabChannels
                  ? Column(
                      children: [
                        IptvToolbar(
                          controller: _liveSearch,
                          hintText: context.l10n.searchChannels,
                          resultCount: listReady
                              ? _liveCountLabel(
                                  library,
                                  filteredLive.length,
                                  exhausted: _scanExhausted,
                                )
                              : '…',
                          filtersActive: liveFiltersActive,
                          onChanged: _onSearchChanged,
                          onClear: () {
                            _frozenTree = null;
                            _liveListStamp = null;
                            setState(() {});
                          },
                          onOpenFilters: () => _showLiveFilters(library),
                        ),
                        if (_liveFilter == IptvLiveFilter.all &&
                            chipLabels.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          FilterChips<String>(
                            options: [
                              for (final id in chipLabels)
                                FilterChipOption(
                                  value: id,
                                  label: liveBrowseChipLabel(context.l10n, id),
                                ),
                            ],
                            selected: chipSelected,
                            onSelected: (id) => _onChipSelected(library, id),
                          ),
                          const SizedBox(height: 4),
                        ],
                        Expanded(
                          child: showLoading
                              ? const Center(
                                  child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : filteredLive.isEmpty
                              ? _TvEmpty(message: emptyMessage)
                              : _buildLiveBody(
                                  library: library,
                                  filteredLive: filteredLive,
                                ),
                        ),
                      ],
                    )
                  : _TvGuideTab(
                      channels: filteredLive,
                      sourceKey: encodeSourceSelection(_sourceKeys),
                      onLoadMore: () => unawaited(_loadMoreLive()),
                    ),
            ),
          ],
        ),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureInnerScrollListener();
    });

    // Never freeze an empty Categories tab while sources exist — live rows
    // often land without a listStamp change (disk hydrate / API categories).
    final freezeEmptyCategories =
        _tabs.index == _tabCategories && cats.isEmpty && hasLiveCapableSource;
    if (!freezeEmptyCategories && (_tabs.index != _tabChannels || listReady)) {
      _frozenTree = tree;
      _frozenListStamp = freezeStamp;
    }
    return tree;
  }

  void _logCategoriesTab(
    LibraryProvider library,
    List<IptvCategory> cats, {
    required bool frozen,
  }) {
    if (_tabs.index != _tabCategories) return;
    final sig = Object.hash(
      cats.length,
      _scopedCategories.length,
      library.liveCategories.length,
      library.categories.length,
      _scopedCategoriesLoading,
      frozen,
      library.syncStatus,
      library.parentalLock?.ready,
    );
    if (sig == _lastCategoriesLogSig) return;
    _lastCategoriesLogSig = sig;
    final xtream = library.sources.where((s) => s.enabled).length;
    JavpLog.i(
      'tv',
      'categories tab cats=${cats.length} scoped=${_scopedCategories.length} '
          'live=${library.liveCategories.length} stored=${library.categories.length} '
          'loading=$_scopedCategoriesLoading frozen=$frozen '
          'parental=${library.parentalLock?.ready} sources=$xtream '
          'sync=${library.syncStatus ?? "-"}',
    );
  }
}

class _TvCategoriesTab extends StatefulWidget {
  const _TvCategoriesTab({
    required this.categories,
    required this.counts,
    required this.favoriteCategoryIds,
    required this.selectedId,
    required this.loading,
    required this.searchController,
    required this.onOpenCategory,
    required this.onToggleFavorite,
    required this.onCategoryActions,
    required this.loadChannels,
    required this.channelTile,
    this.sourceKey,
  });

  final List<IptvCategory> categories;
  final Map<String, int> counts;
  final List<String> favoriteCategoryIds;
  final String? selectedId;
  final bool loading;
  final TextEditingController searchController;
  final ValueChanged<IptvCategory> onOpenCategory;
  final Future<void> Function(IptvCategory category) onToggleFavorite;

  /// Long-press / held OK on a tile: pin, hide, open.
  final ValueChanged<IptvCategory> onCategoryActions;
  final Future<List<MediaItem>> Function({String? query, int offset, int limit})
  loadChannels;
  final Widget Function(BuildContext context, MediaItem channel) channelTile;
  final String? sourceKey;

  @override
  State<_TvCategoriesTab> createState() => _TvCategoriesTabState();
}

class _TvCategoriesTabState extends State<_TvCategoriesTab> {
  static const _pageSize = 80;

  Timer? _channelSearchDebounce;
  List<MediaItem> _channels = const [];
  String? _channelQuery;
  Object? _channelsKey;
  bool _channelsLoading = false;
  bool _channelsExhausted = true;
  bool _appendingChannels = false;
  int _channelLoadGen = 0;

  @override
  void initState() {
    super.initState();
    widget.searchController.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncChannelFallback();
    });
  }

  @override
  void didUpdateWidget(covariant _TvCategoriesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchController != widget.searchController) {
      oldWidget.searchController.removeListener(_onSearchChanged);
      widget.searchController.addListener(_onSearchChanged);
    }
    final sourceChanged = oldWidget.sourceKey != widget.sourceKey;
    final catsChanged =
        oldWidget.categories.length != widget.categories.length ||
        oldWidget.loading != widget.loading;
    if (sourceChanged || catsChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncChannelFallback(force: sourceChanged);
      });
    }
  }

  @override
  void dispose() {
    _channelSearchDebounce?.cancel();
    widget.searchController.removeListener(_onSearchChanged);
    super.dispose();
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {});
    _channelSearchDebounce?.cancel();
    _channelSearchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (mounted) _syncChannelFallback(force: true);
    });
  }

  void _onChannelScrollMetrics(ScrollMetrics metrics) {
    if (_channelsExhausted || _appendingChannels || _channelsLoading) {
      return;
    }
    if (metrics.pixels > metrics.maxScrollExtent - 900) {
      unawaited(_appendChannels());
    }
  }

  List<IptvCategory> _filteredCategories() {
    final q = widget.searchController.text.trim().toLowerCase();
    final matched = q.isEmpty
        ? widget.categories
        : [
            for (final cat in widget.categories)
              if (cat.displayName.toLowerCase().contains(q) ||
                  cat.name.toLowerCase().contains(q))
                cat,
          ];
    return iptvCategoriesWithFavoritesFirst(
      matched,
      widget.favoriteCategoryIds,
    );
  }

  /// No categories at all, or category search returned nothing.
  bool _shouldShowChannels(List<IptvCategory> filtered) {
    if (widget.loading) return false;
    if (widget.categories.isEmpty) return true;
    final q = widget.searchController.text.trim();
    return q.isNotEmpty && filtered.isEmpty;
  }

  void _syncChannelFallback({bool force = false}) {
    final filtered = _filteredCategories();
    if (!_shouldShowChannels(filtered)) {
      if (_channels.isNotEmpty ||
          _channelsLoading ||
          _channelsKey != null ||
          _channelQuery != null) {
        _channelLoadGen++;
        setState(() {
          _channels = const [];
          _channelQuery = null;
          _channelsKey = null;
          _channelsLoading = false;
          _channelsExhausted = true;
          _appendingChannels = false;
        });
      }
      return;
    }
    final q = widget.searchController.text.trim();
    final nextQuery = q.isEmpty ? null : q;
    final key = Object.hash(widget.sourceKey, nextQuery);
    if (!force && key == _channelsKey && !_channelsLoading) return;
    unawaited(_reloadChannels(nextQuery, key));
  }

  Future<void> _reloadChannels(String? query, Object key) async {
    final gen = ++_channelLoadGen;
    setState(() {
      _channels = const [];
      _channelQuery = query;
      _channelsKey = key;
      _channelsLoading = true;
      _channelsExhausted = false;
      _appendingChannels = false;
    });
    try {
      final page = await widget.loadChannels(
        query: query,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted || gen != _channelLoadGen) return;
      setState(() {
        _channels = page;
        _channelsLoading = false;
        _channelsExhausted = page.length < _pageSize;
      });
    } catch (_) {
      if (!mounted || gen != _channelLoadGen) return;
      setState(() {
        _channels = const [];
        _channelsLoading = false;
        _channelsExhausted = true;
      });
    }
  }

  Future<void> _appendChannels() async {
    if (_appendingChannels || _channelsExhausted || _channelsLoading) return;
    final gen = _channelLoadGen;
    final query = _channelQuery;
    _appendingChannels = true;
    try {
      final page = await widget.loadChannels(
        query: query,
        offset: _channels.length,
        limit: _pageSize,
      );
      if (!mounted || gen != _channelLoadGen) return;
      setState(() {
        _channels = [..._channels, ...page];
        _channelsExhausted = page.length < _pageSize;
      });
    } finally {
      _appendingChannels = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCategories();
    final favSet = widget.favoriteCategoryIds.toSet();
    final favCount = filtered
        .where((c) => iptvCategoryIsFavorite(c, favSet))
        .length;
    final totalChannels = filtered.fold<int>(
      0,
      (sum, cat) => sum + (widget.counts[cat.name] ?? 0),
    );
    final showChannels = _shouldShowChannels(filtered);
    final noCategories = !widget.loading && widget.categories.isEmpty;
    final searching = widget.searchController.text.trim().isNotEmpty;

    if (showChannels && _channelsKey == null && !_channelsLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncChannelFallback();
      });
    }

    final String header;
    if (showChannels) {
      if ((_channelsLoading || _channelsKey == null) && _channels.isEmpty) {
        header = noCategories ? context.l10n.channels : 'Searching channels…';
      } else if (_channels.isEmpty) {
        header = searching ? 'No matches' : context.l10n.channels;
      } else {
        final suffix = _channelsExhausted ? '' : '+';
        header = noCategories
            ? '${_channels.length}$suffix channels'
            : 'No categories · ${_channels.length}$suffix channels';
      }
    } else if (filtered.isEmpty) {
      header = context.l10n.categories;
    } else if (favCount > 0) {
      header =
          '$favCount starred · ${filtered.length} · $totalChannels channels';
    } else {
      header = '${filtered.length} categories · $totalChannels channels';
    }

    final hint = noCategories
        ? context.l10n.searchChannels
        : context.l10n.filterCategoriesHint;
    final countLabel = showChannels
        ? ((_channelsLoading || _channelsKey == null) && _channels.isEmpty
              ? '…'
              : '${_channels.length}${_channelsExhausted ? '' : '+'}')
        : '${filtered.length}';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              header,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          child: SizedBox(
            height: 36,
            child: Row(
              children: [
                Expanded(
                  child: JavpTextField(
                    controller: widget.searchController,
                    style: const TextStyle(color: AppColors.text, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: hint,
                      hintStyle: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      suffixIcon: widget.searchController.text.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Center(
                                child: Text(
                                  countLabel,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            )
                          : IconButton(
                              tooltip: context.l10n.clear,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              onPressed: widget.searchController.clear,
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
              ],
            ),
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : showChannels
              ? _buildChannelFallback(context, searching: searching)
              : Builder(
                  builder: (context) {
                    final isTv = TvPlatform.isAndroidTv;
                    final width = AdaptiveLayout.contentWidth(context);
                    // Phone keeps taller cards; rail/desktop/TV use a
                    // denser grid so categories stay scannable.
                    final crossAxisCount = isTv
                        ? (width >= 1600
                              ? 5
                              : width >= 1200
                              ? 4
                              : 3)
                        : AdaptiveLayout.liveCategoryColumns(context);
                    final childAspectRatio =
                        AdaptiveLayout.liveCategoryAspectRatio(context);
                    final compact = isTv || AdaptiveLayout.useRail(context);
                    final gap = isTv ? 6.0 : (compact ? 6.0 : 8.0);
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        isTv ? 10 : 12,
                        isTv ? 4 : 8,
                        isTv ? 10 : 12,
                        isTv ? miniPlayerScrollBottomInset(context) : 16,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: gap,
                        crossAxisSpacing: gap,
                        childAspectRatio: childAspectRatio,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final cat = filtered[index];
                        final selected = cat.id == widget.selectedId;
                        final starred = iptvCategoryIsFavorite(cat, favSet);
                        final count = widget.counts[cat.name];
                        final countLabel = count == null
                            ? null
                            : (count == 1 ? '1' : '$count');
                        final tile = Material(
                          color: selected
                              ? AppColors.accent.withValues(alpha: 0.16)
                              : AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(compact ? 8 : 12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              compact ? 8 : 12,
                            ),
                            onTap: () => widget.onOpenCategory(cat),
                            onLongPress: () => widget.onCategoryActions(cat),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                compact ? 10 : 12,
                                compact ? 6 : 8,
                                compact ? 6 : 4,
                                compact ? 6 : 8,
                              ),
                              child: compact
                                  ? Row(
                                      children: [
                                        Expanded(
                                          child: HorizontalScrollText(
                                            text: countLabel == null
                                                ? cat.displayName
                                                : '${cat.displayName} · $countLabel',
                                            style: TextStyle(
                                              color: AppColors.text,
                                              fontWeight: FontWeight.w600,
                                              fontSize: isTv ? 12 : 13,
                                              height: 1.1,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: starred
                                              ? 'Remove favorite category'
                                              : 'Favorite category',
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 28,
                                            minHeight: 28,
                                          ),
                                          onPressed: () =>
                                              widget.onToggleFavorite(cat),
                                          icon: Icon(
                                            starred
                                                ? Icons.star_rounded
                                                : Icons.star_outline_rounded,
                                            size: 16,
                                            color: starred
                                                ? AppColors.accent
                                                : AppColors.textMuted,
                                          ),
                                        ),
                                        Icon(
                                          selected
                                              ? Icons.check_circle_rounded
                                              : Icons.chevron_right_rounded,
                                          size: 16,
                                          color: selected
                                              ? AppColors.accent
                                              : AppColors.textMuted,
                                        ),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: HorizontalScrollText(
                                                  text: cat.displayName,
                                                  style: const TextStyle(
                                                    color: AppColors.text,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 13,
                                                    height: 1.2,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: starred
                                                    ? 'Remove favorite category'
                                                    : 'Favorite category',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 32,
                                                      minHeight: 32,
                                                    ),
                                                onPressed: () => widget
                                                    .onToggleFavorite(cat),
                                                icon: Icon(
                                                  starred
                                                      ? Icons.star_rounded
                                                      : Icons
                                                            .star_outline_rounded,
                                                  size: 20,
                                                  color: starred
                                                      ? AppColors.accent
                                                      : AppColors.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                count == null
                                                    ? 'Open'
                                                    : (count == 1
                                                          ? '1 channel'
                                                          : '$count channels'),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: AppColors.textMuted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              selected
                                                  ? Icons.check_circle_rounded
                                                  : Icons.chevron_right_rounded,
                                              size: 18,
                                              color: selected
                                                  ? AppColors.accent
                                                  : AppColors.textMuted,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        );
                        if (!isTv) return tile;
                        return TvFocusable(
                          autofocus: selected || index == 0,
                          borderRadius: 8,
                          onSelect: () => widget.onOpenCategory(cat),
                          onLongSelect: () => widget.onCategoryActions(cat),
                          child: tile,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildChannelFallback(
    BuildContext context, {
    required bool searching,
  }) {
    if ((_channelsLoading || _channelsKey == null) && _channels.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_channels.isEmpty) {
      return _TvEmpty(
        message: searching
            ? context.l10n.noCategoriesMatch
            : context.l10n.noLiveChannelsYet,
      );
    }
    return Selector<LibraryProvider, int>(
      selector: (_, l) =>
          Object.hash(l.epgRevision, l.favoriteChannelIds.length),
      builder: (context, _, _) {
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical) {
              _onChannelScrollMetrics(notification.metrics);
            }
            return false;
          },
          child: LiveChannelList(
            itemCount: _channels.length,
            itemBuilder: (context, index) =>
                widget.channelTile(context, _channels[index]),
          ),
        );
      },
    );
  }
}

class _TvEmpty extends StatelessWidget {
  const _TvEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      ),
    );
  }
}

class _TvGuideTab extends StatefulWidget {
  const _TvGuideTab({required this.channels, this.sourceKey, this.onLoadMore});

  final List<MediaItem> channels;
  final String? sourceKey;
  final VoidCallback? onLoadMore;

  @override
  State<_TvGuideTab> createState() => _TvGuideTabState();
}

class _TvGuideTabState extends State<_TvGuideTab> {
  final _search = TextEditingController();
  String? _expandedTvgId;
  bool _catchupOnly = true;
  bool _guideMode = true;
  String? _categoryId;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _channelMatches(MediaItem channel, String query) {
    return iptvMatchesQuery(query, [
      channel.title,
      channel.group,
      channel.epgChannelId,
      channel.streamId,
    ]);
  }

  bool _groupMatches(
    List<MediaItem> channels,
    List<EpgProgram> programs,
    String query,
  ) {
    if (query.trim().isEmpty) return true;
    if (channels.any((c) => _channelMatches(c, query))) return true;
    return programs.any(
      (p) => iptvMatchesQuery(query, [p.title, p.description, p.channelId]),
    );
  }

  Future<void> _playGuideProgram(
    LibraryProvider library,
    MediaItem channel,
    EpgProgram program,
  ) async {
    final item = await library.catchupItemAsync(
      channel: channel,
      program: program,
    );
    if (!mounted) return;
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.catchupRequiresArchive)),
      );
      return;
    }
    context.push('/player', extra: item);
  }

  Future<void> _showEpgFilters(LibraryProvider library) async {
    await showAppModal<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            void apply(VoidCallback fn) {
              setState(fn);
              setSheet(() {});
            }

            final categoryName = _categoryId == null
                ? null
                : library.liveCategories
                      .cast<IptvCategory?>()
                      .firstWhere(
                        (c) => c?.id == _categoryId,
                        orElse: () => null,
                      )
                      ?.displayName;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppModalDragHandle(top: 0, width: 36, bottom: 12),
                    Text(
                      context.l10n.epgFilters,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.l10n.catchupOnly),
                      value: _catchupOnly,
                      activeThumbColor: AppColors.accent,
                      onChanged: (v) => apply(() => _catchupOnly = v),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.category_outlined),
                      title: Text(categoryName ?? context.l10n.allCategories),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_categoryId != null)
                            AppActionButton(
                              variant: AppActionButtonVariant.text,
                              onPressed: () => apply(() => _categoryId = null),
                              label: context.l10n.clear,
                            ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                      onTap: () async {
                        final selected = await showIptvCategoryPicker(
                          context: context,
                          title: context.l10n.filterEpgByCategory,
                          categories: library.liveCategories,
                          selectedId: _categoryId,
                          includeAll: true,
                          allKind: IptvCategoryKind.live,
                        );
                        if (selected != null) {
                          apply(
                            () =>
                                _categoryId = selected.id == kIptvCategoryAllId
                                ? null
                                : selected.id,
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // The guide only moves when EPG data or categories change.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(l.epgRevision, l.liveDbRevision, l.categories.length),
    );
    final library = context.read<LibraryProvider>();
    if (widget.channels.isEmpty) {
      return _TvEmpty(message: context.l10n.epgCatchupAfterLiveSync);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(context.l10n.guide),
                        icon: Icon(Icons.grid_view_rounded, size: 14),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(context.l10n.list),
                        icon: Icon(Icons.view_list_rounded, size: 14),
                      ),
                    ],
                    selected: {_guideMode},
                    onSelectionChanged: (s) =>
                        setState(() => _guideMode = s.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: WidgetStateProperty.resolveWith((
                        states,
                      ) {
                        if (states.contains(WidgetState.selected)) {
                          return Colors.white;
                        }
                        return AppColors.textMuted;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((
                        states,
                      ) {
                        if (states.contains(WidgetState.selected)) {
                          return AppColors.accent;
                        }
                        return AppColors.surfaceHigh;
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _guideMode ? _buildGuide(library) : _buildList(library),
        ),
      ],
    );
  }

  Widget _buildGuide(LibraryProvider library) {
    // Same channel set as the Channels tab (category / source / search filters).
    // Do not intersect with [LibraryProvider.guideChannels] — that list is a
    // favorites/recents shortcut capped at 60 and silently drops most channels.
    return EpgGuideGrid(
      channels: widget.channels,
      onNearEnd: widget.onLoadMore,
      onPlayLive: (channel) =>
          openLivePlayback(context, library.resolveLiveChannel(channel)),
      onPlayProgram: (channel, program) {
        unawaited(_playGuideProgram(library, channel, program));
      },
    );
  }

  Widget _buildList(LibraryProvider library) {
    final categoryName = _categoryId == null
        ? null
        : library.liveCategories
              .cast<IptvCategory?>()
              .firstWhere((c) => c?.id == _categoryId, orElse: () => null)
              ?.name;

    final byTvg = <String, List<MediaItem>>{};
    for (final channel in widget.channels) {
      if (categoryName != null && (channel.group ?? '') != categoryName) {
        continue;
      }
      final tvgId = channel.epgChannelId?.trim();
      if (tvgId == null || tvgId.isEmpty) continue;
      byTvg.putIfAbsent(tvgId, () => []).add(channel);
    }

    // Preserve Channels-tab / playlist order (Map insertion follows
    // [widget.channels]). Do not re-sort A–Z here.
    final groups = byTvg.entries.toList();

    final query = _search.text;
    final searching = query.trim().isNotEmpty;
    final visible = groups.where((e) {
      if (_catchupOnly &&
          !e.value.any((c) => library.liveSupportsCatchup(c))) {
        return false;
      }
      // `guideFor` is a lookup per group; skip it entirely when not searching.
      if (!searching) return true;
      final preferred = e.value.firstWhere(
        (c) => library.liveSupportsCatchup(c),
        orElse: () => e.value.first,
      );
      return _groupMatches(e.value, library.guideFor(preferred), query);
    }).toList();

    // Existing list UI (search + grouped EPG).
    final noTvgCatchup = widget.channels.where((c) {
      if (!library.liveSupportsCatchup(c)) return false;
      if (c.epgChannelId != null && c.epgChannelId!.trim().isNotEmpty) {
        return false;
      }
      if (categoryName != null && (c.group ?? '') != categoryName) return false;
      return _channelMatches(c, query);
    }).toList();

    final filtersActive = !_catchupOnly || _categoryId != null;

    return Column(
      children: [
        IptvToolbar(
          controller: _search,
          hintText: context.l10n.searchEpgHint,
          resultCount: '${visible.length}',
          filtersActive: filtersActive,
          onChanged: (_) => setState(() {}),
          onClear: () => setState(() {}),
          onOpenFilters: () => _showEpgFilters(library),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              // Guides are looked up per row instead of for every group up
              // front — a large EPG used to build every group on every frame.
              final showNoTvgHeader = !_catchupOnly && noTvgCatchup.isNotEmpty;
              final noTvgStart = visible.length + (showNoTvgHeader ? 1 : 0);
              final tailCount = _catchupOnly ? 0 : noTvgCatchup.length;
              final notice = visible.isEmpty ? 1 : 0;
              return ListView.builder(
                padding: EdgeInsets.only(
                  bottom: miniPlayerScrollBottomInset(context),
                ),
                itemCount: noTvgStart + tailCount + notice,
                itemBuilder: (context, index) {
                  if (index >= noTvgStart + tailCount) {
                    return Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        context.l10n.noEpgGroupsMatch,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    );
                  }
                  if (index < visible.length) {
                    final entry = visible[index];
                    return _buildTvgGroup(library, entry, query);
                  }
                  if (showNoTvgHeader && index == visible.length) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Catchup without tvg-id (${noTvgCatchup.length})',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: AppColors.text,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    );
                  }
                  final channel = noTvgCatchup[index - noTvgStart];
                  return _buildNoTvgCatchupTile(channel);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTvgGroup(
    LibraryProvider library,
    MapEntry<String, List<MediaItem>> entry,
    String query,
  ) {
    final preferred = entry.value.firstWhere(
      (c) => library.liveSupportsCatchup(c),
      orElse: () => entry.value.first,
    );
    final allPrograms = library.guideFor(preferred);
    List<EpgProgram> programs;
    if (query.trim().isEmpty ||
        entry.value.any((c) => _channelMatches(c, query))) {
      programs = allPrograms;
    } else {
      programs = allPrograms
          .where(
            (p) =>
                iptvMatchesQuery(query, [p.title, p.description, p.channelId]),
          )
          .toList();
    }
    return _TvgGuideGroup(
      key: ValueKey('tvg-${entry.key}'),
      tvgId: entry.key,
      displayTitle: library.officialLiveTitle(preferred),
      channels: entry.value,
      expanded: _expandedTvgId == entry.key,
      onToggle: () async {
        final next = _expandedTvgId == entry.key ? null : entry.key;
        setState(() => _expandedTvgId = next);
        if (next != null) {
          await library.fetchChannelGuide(preferred);
        }
      },
      programs: programs,
      loading: library.isGuideLoading(preferred),
      onPlayLive: (channel) =>
          openLivePlayback(context, library.resolveLiveChannel(channel)),
      onPlayCatchup: (channel, program) {
        unawaited(_playGuideProgram(library, channel, program));
      },
    );
  }

  Widget _buildNoTvgCatchupTile(MediaItem channel) {
    final library = context.read<LibraryProvider>();
    return ListTile(
      title: Text(library.officialLiveTitle(channel)),
      subtitle: Text(
        '${channel.group ?? 'Catchup'} · ${library.liveFamilyCatchupDays(channel)}d',
      ),
      trailing: IconButton(
        tooltip: context.l10n.recordFromArchive,
        icon: const Icon(Icons.fiber_manual_record_rounded),
        onPressed: () =>
            showCatchupRecordDialog(context: context, channel: channel),
      ),
      onTap: () => openLivePlayback(context, channel),
      onLongPress: () => showMediaItemActions(
        context: context,
        item: channel,
        onPlay: () => openLivePlayback(context, channel),
        showDetails: false,
        showWatchlist: false,
        showDownload: false,
        showPlaylists: false,
      ),
    );
  }
}

class _TvgGuideGroup extends StatelessWidget {
  const _TvgGuideGroup({
    super.key,
    required this.tvgId,
    required this.displayTitle,
    required this.channels,
    required this.expanded,
    required this.onToggle,
    required this.programs,
    required this.loading,
    required this.onPlayLive,
    required this.onPlayCatchup,
  });

  final String tvgId;
  final String displayTitle;
  final List<MediaItem> channels;
  final bool expanded;
  final VoidCallback onToggle;
  final List<EpgProgram> programs;
  final bool loading;
  final ValueChanged<MediaItem> onPlayLive;
  final void Function(MediaItem channel, EpgProgram program) onPlayCatchup;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final primary = channels.firstWhere(
      (c) => library.liveSupportsCatchup(c),
      orElse: () => channels.first,
    );
    final now = DateTime.now();
    final hasCatchup = channels.any((c) => library.liveSupportsCatchup(c));
    final familyDays = library.liveFamilyCatchupDays(primary);
    final nowProgram = programs.where((p) => p.isAiringAt(now)).firstOrNull;
    final canStartOver =
        nowProgram != null &&
        (library.liveSupportsCatchup(primary) || nowProgram.hasArchive);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayTitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          [
                            tvgId,
                            if (channels.length > 1)
                              '${channels.length} streams',
                            if (hasCatchup)
                              '${(familyDays > 0 ? familyDays : primary.catchupDays)}d catchup',
                            primary.group,
                          ].whereType<String>().join(' · '),
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canStartOver)
                    AppActionButton(
                      variant: AppActionButtonVariant.text,
                      onPressed: () => onPlayCatchup(primary, nowProgram),
                      label: context.l10n.startOver,
                    ),
                  if (hasCatchup)
                    IconButton(
                      tooltip: context.l10n.recordFromArchive,
                      onPressed: () => showCatchupRecordDialog(
                        context: context,
                        channel: primary,
                      ),
                      icon: const Icon(Icons.fiber_manual_record_rounded),
                      color: AppColors.accent,
                    ),
                  AppActionButton(
                    variant: AppActionButtonVariant.text,
                    onPressed: () => onPlayLive(primary),
                    label: context.l10n.navLive,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            if (channels.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final channel in channels)
                    ActionChip(
                      label: Text(
                        [
                          ChannelQuality.labelFor(channel) ??
                              ChannelQuality.baseTitle(channel.title),
                          if (library.liveSupportsCatchup(channel)) '★',
                        ].join(' '),
                      ),
                      onPressed: () => onPlayLive(channel),
                    ),
                ],
              ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else if (programs.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.noEpgEntriesForTvgId,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    if (hasCatchup) ...[
                      const SizedBox(height: 8),
                      AppActionButton(
                        variant: AppActionButtonVariant.outlined,
                        icon: Icons.fiber_manual_record_rounded,
                        onPressed: () => showCatchupRecordDialog(
                          context: context,
                          channel: primary,
                        ),
                        label: context.l10n.recordFromArchive,
                      ),
                    ],
                  ],
                ),
              )
            else
              ..._programListChildren(
                context: context,
                primary: primary,
                programs: programs,
                now: now,
              ),
          ],
          const Divider(color: AppColors.border),
        ],
      ),
    );
  }

  List<Widget> _programListChildren({
    required BuildContext context,
    required MediaItem primary,
    required List<EpgProgram> programs,
    required DateTime now,
  }) {
    final library = context.read<LibraryProvider>();
    final children = <Widget>[];
    DateTime? lastDay;
    for (final program in programs) {
      final local = program.start.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay == null || day != lastDay) {
        lastDay = day;
        children.add(
          Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 4 : 12, bottom: 2),
            child: Text(
              _dayHeading(context, program.start),
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        );
      }

      final isNow = program.isAiringAt(now);
      final isPast = program.end.isBefore(now);
      final hasArchive =
          library.liveSupportsCatchup(primary) || program.hasArchive;
      final canCatchup = isPast && hasArchive;
      final canStartOver = isNow && hasArchive;
      final reminded = library.isProgramReminded(primary, program);
      children.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            program.title,
            style: TextStyle(
              color: AppColors.text,
              fontWeight: isNow ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            '${_programWindow(program.start, program.end)}'
            '${isNow
                ? ' · ${context.l10n.now}'
                : isPast
                ? (canCatchup
                    ? ' · ${context.l10n.catchup}'
                    : ' · ${context.l10n.ended}')
                : ' · ${context.l10n.upcoming}'}'
            '${reminded ? ' · Reminder' : ''}',
          ),
          trailing: reminded
              ? const Icon(
                  Icons.notifications_active_rounded,
                  color: AppColors.live,
                  size: 20,
                )
              : canCatchup
              ? IconButton(
                  tooltip: context.l10n.playCatchup,
                  onPressed: () => onPlayCatchup(primary, program),
                  icon: const Icon(Icons.history_rounded),
                  color: AppColors.accent,
                )
              : canStartOver
              ? IconButton(
                  tooltip: context.l10n.startOver,
                  onPressed: () => onPlayCatchup(primary, program),
                  icon: const Icon(Icons.restart_alt_rounded),
                  color: AppColors.accent,
                )
              : isNow
              ? const Icon(Icons.sensors_rounded, color: AppColors.live)
              : null,
          onTap: () {
            showEpgProgramSheet(
              context: context,
              channel: primary,
              program: program,
              onWatchLive: () => onPlayLive(primary),
              onWatchCatchup: () => onPlayCatchup(primary, program),
            );
          },
        ),
      );
    }
    return children;
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _calendarDate(DateTime dt) {
    final local = dt.toLocal();
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${weekdays[local.weekday - 1]} ${local.day} ${months[local.month - 1]}';
  }

  String _dayHeading(BuildContext context, DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now().toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    final stamped = _calendarDate(dt);
    if (diff == 0) return context.l10n.todayStamp(stamped);
    if (diff == -1) return context.l10n.yesterdayStamp(stamped);
    if (diff == 1) return context.l10n.tomorrowStamp(stamped);
    return stamped;
  }

  String _programWindow(DateTime start, DateTime end) {
    final sameDay =
        start.toLocal().day == end.toLocal().day &&
        start.toLocal().month == end.toLocal().month &&
        start.toLocal().year == end.toLocal().year;
    if (sameDay) {
      return '${_hhmm(start)}–${_hhmm(end)}';
    }
    return '${_calendarDate(start)} ${_hhmm(start)} – '
        '${_calendarDate(end)} ${_hhmm(end)}';
  }
}
