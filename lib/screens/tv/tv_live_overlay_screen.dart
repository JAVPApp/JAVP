import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/caption_style_provider.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/tv/tv_live_browse_panes.dart';
import 'package:javp/screens/tv/tv_live_keymap.dart';
import 'package:javp/screens/tv/tv_remote_screen.dart';
import 'package:javp/services/iptv/live_category_page.dart';
import 'package:javp/services/iptv/live_category_pins.dart';
import 'package:javp/services/iptv/live_zap_number.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/multi_view/multi_view_channel_picker.dart';
import 'package:javp/widgets/multi_view/multi_view_stage.dart';
import 'package:javp/widgets/multi_view/multi_view_toolbar.dart';
import 'package:javp/widgets/playback_video_surface.dart';
import 'package:javp/widgets/player/live_dvr_playhead.dart';
import 'package:javp/widgets/player/sleep_timer_feedback.dart';
import 'package:javp/widgets/player/tv_player_icon_button.dart';
import 'package:javp/widgets/player_loading_badge.dart';
import 'package:javp/widgets/tv/live_category_actions.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';
import 'package:javp/widgets/tv/tv_channel_logo.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/tv/tv_live_dvr_playhead.dart';
import 'package:javp/widgets/tv/tv_live_guide_overlay.dart';
import 'package:javp/widgets/tv/tv_player_settings_overlay.dart';
import 'package:provider/provider.dart';

/// Android TV Live: fullscreen session with Big Picture–style overlays.
class TvLiveOverlayScreen extends StatefulWidget {
  const TvLiveOverlayScreen({super.key});

  @override
  State<TvLiveOverlayScreen> createState() => _TvLiveOverlayScreenState();
}

enum _LiveOverlay { none, browse, guide, info, settings, epg }

class _TvLiveOverlayScreenState extends State<TvLiveOverlayScreen> {
  static const _dvrStep = Duration(seconds: 10);
  static const _pageSize = 80;

  /// True after minimize so [dispose] does not treat teardown as orphaned.
  bool _sessionHandedOff = false;
  PlaybackProvider? _playback;

  /// [PlaybackProvider.claimVideoSurface] ran; [dispose] always releases.
  bool _claimedSurface = false;

  _LiveOverlay _overlay = _LiveOverlay.none;
  Timer? _infoHide;
  Timer? _digitTimer;
  Timer? _searchDebounce;
  Timer? _zapDebounce;

  /// 0-based zap-list cursor while CH± / ↑↓ is in flight. Video stays on the
  /// current stream until [_zapDebounce] fires (or OK / a panel commits).
  int? _pendingZapIndex;

  /// True while a CH± / ↑↓ hold started by revealing hidden chrome. Repeats of
  /// that hold must not zap.
  bool _zapHoldFromHiddenChrome = false;
  String _digitBuffer = '';
  List<MediaItem> _channels = const [];
  String _sectionId = TvLiveBrowseSection.forYouId;
  String _searchQuery = '';
  int _channelOffset = 0;
  bool _hasMoreChannels = false;
  bool _loadingMoreChannels = false;
  bool _loadingChannels = true;
  bool _bootstrapped = false;

  /// Info bar opened with OK — its transport buttons own D-pad focus.
  bool _infoActions = false;
  bool _infoMenuExpanded = false;
  bool _browseFocusSections = false;
  final _rootFocus = FocusNode(debugLabel: 'tvLiveRoot');
  final _infoBrowseFocus = FocusNode(debugLabel: 'tvLiveInfoBrowse');
  final _infoPlayFocus = FocusNode(debugLabel: 'tvLiveInfoPlay');
  final _playheadFocus = FocusNode(debugLabel: 'tvLiveDvrPlayhead');
  final _backGate = TvBackGate();

  /// Key deferred leave; cleared when PopScope (or fallback) exits watch.
  bool _liveLeavePending = false;
  final _settingsKey = GlobalKey<TvPlayerSettingsOverlayState>();
  final Set<String> _guidePrefetched = {};
  Object? _appliedCaptionSig;

  /// Live-DB group names (M3U) merged into the categories column.
  List<String> _liveGroupNames = const [];
  int _liveGroupNamesRev = -1;
  int _liveGroupNamesGen = 0;

  bool get _sectionSupportsPaging {
    final kind = _kindFor(_sectionId);
    return kind == TvLiveBrowseSectionKind.all ||
        kind == TvLiveBrowseSectionKind.category;
  }

  bool get _sectionSupportsSearch => _sectionSupportsPaging;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playback = context.read<PlaybackProvider>();
    if (!_sessionHandedOff && !_claimedSurface) {
      _claimedSurface = true;
      _playback!.claimVideoSurface();
    }
  }

  @override
  void dispose() {
    _infoHide?.cancel();
    _digitTimer?.cancel();
    _searchDebounce?.cancel();
    _zapDebounce?.cancel();
    _infoBrowseFocus.dispose();
    _infoPlayFocus.dispose();
    _playheadFocus.dispose();
    _rootFocus.dispose();
    if (!_sessionHandedOff) {
      final playback = _playback;
      if (playback != null &&
          playback.hasSession &&
          !playback.isMinimized &&
          !playback.isInPip) {
        unawaited(playback.stop());
      }
    }
    _playback?.releaseVideoSurface();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped || !mounted) return;
    _bootstrapped = true;
    await _reloadChannels();
    if (!mounted) return;
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    if (_channels.isEmpty) {
      setState(() => _loadingChannels = false);
      return;
    }

    for (var i = 0; i < 40 && playback.isOpening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }

    final current = playback.liveChannel ?? playback.item;
    // Live edge or in-session DVR (item is catchup, liveChannel still set).
    final alreadyLive =
        current != null &&
        (current.isLive ||
            (playback.liveChannel != null &&
                playback.item?.kind == MediaKind.catchup));

    if (alreadyLive) {
      final resolved = library.resolveLiveChannel(current);
      final inList = _channels.any((c) => _sameChannel(c, resolved));
      if (!inList) {
        setState(() => _channels = [resolved, ..._channels]);
      }
      playback.setLiveZapList(_channels);
      unawaited(library.fetchChannelGuide(resolved));
      // Restoring from the mini dock arrives minimized. Expand so leave-watch
      // can minimize again. Fresh taps use expand:true and skip this.
      if (playback.isMinimized) await playback.expand();
    } else {
      playback.setLiveZapList(_channels);
      final start = library.recentChannels.isNotEmpty
          ? library.recentChannels.first
          : _channels.first;
      final resolved = library.resolveLiveChannel(start);
      await playback.open(resolved, expand: true);
      unawaited(library.fetchChannelGuide(resolved));
    }

    if (mounted) {
      setState(() => _loadingChannels = false);
      // Autofocus can be skipped when the scope already had a focused child
      // (arriving from a tap), and then the zapper keymap would be dead.
      _rootFocus.requestFocus();
      _flashInfo();
    }
  }

  bool _sameChannel(MediaItem? a, MediaItem? b) {
    if (a == null || b == null) return false;
    if (a.id == b.id) return true;
    return a.streamId != null &&
        a.streamId == b.streamId &&
        a.sourceId == b.sourceId;
  }

  TvLiveBrowseSectionKind _kindFor(String sectionId) {
    switch (sectionId) {
      case TvLiveBrowseSection.favoritesId:
        return TvLiveBrowseSectionKind.favorites;
      case TvLiveBrowseSection.recentsId:
        return TvLiveBrowseSectionKind.recents;
      case TvLiveBrowseSection.allId:
        return TvLiveBrowseSectionKind.all;
      case TvLiveBrowseSection.forYouId:
        return TvLiveBrowseSectionKind.forYou;
      default:
        return TvLiveBrowseSectionKind.category;
    }
  }

  IptvCategory? _categoryFor(String sectionId, LibraryProvider library) {
    if (_kindFor(sectionId) != TvLiveBrowseSectionKind.category) return null;
    final id = sectionId.substring('cat:'.length);
    for (final category in library.liveCategories) {
      if (category.id == id || category.name == id) return category;
    }
    // M3U groups live only in the live DB — synthesize a row by name.
    for (final name in _liveGroupNames) {
      if (name == id) {
        return IptvCategory(id: name, name: name, kind: IptvCategoryKind.live);
      }
    }
    return null;
  }

  List<TvLiveBrowseSection> _sections(
    BuildContext context,
    LibraryProvider library,
  ) {
    final favoriteIds = library.favoriteCategoryIds;
    final favoriteSet = favoriteIds.toSet();
    final categories = iptvCategoriesWithFavoritesFirst(
      liveBrowseCategories(
        providerCategories: library.liveCategories,
        liveGroupNames: _liveGroupNames,
      ),
      favoriteIds,
    );
    return [
      TvLiveBrowseSection(
        id: TvLiveBrowseSection.forYouId,
        label: context.l10n.forYou,
        kind: TvLiveBrowseSectionKind.forYou,
      ),
      TvLiveBrowseSection(
        id: TvLiveBrowseSection.favoritesId,
        label: context.l10n.favorites,
        kind: TvLiveBrowseSectionKind.favorites,
      ),
      TvLiveBrowseSection(
        id: TvLiveBrowseSection.recentsId,
        label: context.l10n.recentlyWatched,
        kind: TvLiveBrowseSectionKind.recents,
      ),
      TvLiveBrowseSection(
        id: TvLiveBrowseSection.allId,
        label: context.l10n.all,
        kind: TvLiveBrowseSectionKind.all,
      ),
      for (final category in categories)
        TvLiveBrowseSection(
          id: TvLiveBrowseSection.categoryIdFor(category),
          label: category.displayName,
          kind: TvLiveBrowseSectionKind.category,
          category: category,
          pinned: iptvCategoryIsFavorite(category, favoriteSet),
        ),
    ];
  }

  void _ensureLiveGroupNames(LibraryProvider library) {
    if (_liveGroupNamesRev == library.liveDbRevision &&
        _liveGroupNames.isNotEmpty) {
      return;
    }
    if (_liveGroupNamesRev == library.liveDbRevision && !library.hasLiveDb) {
      return;
    }
    final gen = ++_liveGroupNamesGen;
    unawaited(() async {
      final names = await library.liveGroupNames();
      if (!mounted || gen != _liveGroupNamesGen) return;
      setState(() {
        _liveGroupNames = names;
        _liveGroupNamesRev = library.liveDbRevision;
      });
    }());
  }

  Future<void> _reloadChannels({bool reset = true}) async {
    final library = context.read<LibraryProvider>();
    if (reset) {
      _channelOffset = 0;
      _hasMoreChannels = false;
    }
    final query = _searchQuery.trim().isEmpty ? null : _searchQuery.trim();
    List<MediaItem> list;
    var hasMore = false;
    switch (_kindFor(_sectionId)) {
      case TvLiveBrowseSectionKind.favorites:
        list = List<MediaItem>.from(library.favoriteChannels);
        if (query != null) {
          final q = query.toLowerCase();
          list = [
            for (final c in list)
              if (c.title.toLowerCase().contains(q) ||
                  (c.group ?? '').toLowerCase().contains(q))
                c,
          ];
        }
      case TvLiveBrowseSectionKind.recents:
        list = List<MediaItem>.from(library.recentChannels);
        if (query != null) {
          final q = query.toLowerCase();
          list = [
            for (final c in list)
              if (c.title.toLowerCase().contains(q) ||
                  (c.group ?? '').toLowerCase().contains(q))
                c,
          ];
        }
      case TvLiveBrowseSectionKind.all:
        list = await pageLiveCategoryWithEnsure(
          page: () => library.pageLiveChannels(
            query: query,
            offset: 0,
            limit: _pageSize,
          ),
          ensureIfCold: () => library.ensureLiveListingsWarm(),
        );
        hasMore = list.length >= _pageSize;
      case TvLiveBrowseSectionKind.category:
        final category = _categoryFor(_sectionId, library);
        if (category == null) {
          list = const [];
        } else {
          // Prefer SQLite; only network-fetch when the group is cold — same
          // path as main Live TV ([TvScreen._fetchLivePage]).
          list = await pageLiveCategoryWithEnsure(
            page: () => library.pageLiveChannels(
              groupName: category.name,
              query: query,
              offset: 0,
              limit: _pageSize,
            ),
            ensureIfCold: () => library.ensureLiveCategoryAvailable(category),
          );
        }
        hasMore = list.length >= _pageSize;
      case TvLiveBrowseSectionKind.forYou:
        list = await library.pageLiveChannels(limit: 200);
        if (list.isEmpty) {
          try {
            final shelves = await library
                .buildForYouLiveShelves(perShelf: 24)
                .timeout(const Duration(seconds: 6));
            final seen = <String>{};
            list = [];
            for (final shelf in shelves) {
              for (final c in shelf.channels) {
                if (seen.add(c.id)) list.add(c);
              }
            }
          } on TimeoutException {
            list = const [];
          }
        }
        if (query != null) {
          final q = query.toLowerCase();
          list = [
            for (final c in list)
              if (c.title.toLowerCase().contains(q) ||
                  (c.group ?? '').toLowerCase().contains(q))
                c,
          ];
        }
    }
    if (!mounted) return;
    setState(() {
      _channels = list;
      _channelOffset = list.length;
      _hasMoreChannels = hasMore;
    });
    context.read<PlaybackProvider>().setLiveZapList(list);
    _prefetchGuides(list.take(14).toList());
  }

  Future<void> _loadMoreChannels() async {
    if (!_sectionSupportsPaging ||
        !_hasMoreChannels ||
        _loadingMoreChannels ||
        _loadingChannels) {
      return;
    }
    final library = context.read<LibraryProvider>();
    final query = _searchQuery.trim().isEmpty ? null : _searchQuery.trim();
    _loadingMoreChannels = true;
    try {
      final List<MediaItem> page;
      switch (_kindFor(_sectionId)) {
        case TvLiveBrowseSectionKind.all:
          page = await library.pageLiveChannels(
            query: query,
            offset: _channelOffset,
            limit: _pageSize,
          );
        case TvLiveBrowseSectionKind.category:
          final category = _categoryFor(_sectionId, library);
          page = category == null
              ? const []
              : await library.pageLiveChannels(
                  groupName: category.name,
                  query: query,
                  offset: _channelOffset,
                  limit: _pageSize,
                );
        case TvLiveBrowseSectionKind.favorites:
        case TvLiveBrowseSectionKind.recents:
        case TvLiveBrowseSectionKind.forYou:
          page = const [];
      }
      if (!mounted || page.isEmpty) {
        if (mounted) setState(() => _hasMoreChannels = false);
        return;
      }
      final seen = {for (final c in _channels) c.id};
      final appended = [
        for (final c in page)
          if (seen.add(c.id)) c,
      ];
      if (appended.isEmpty) {
        setState(() => _hasMoreChannels = false);
        return;
      }
      final next = [..._channels, ...appended];
      setState(() {
        _channels = next;
        _channelOffset = next.length;
        _hasMoreChannels = page.length >= _pageSize;
      });
      context.read<PlaybackProvider>().setLiveZapList(next);
      _prefetchGuides(appended.take(14).toList());
    } finally {
      _loadingMoreChannels = false;
    }
  }

  void _onBrowseSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () async {
      if (!mounted || value == _searchQuery) return;
      setState(() {
        _searchQuery = value;
        _loadingChannels = true;
      });
      await _reloadChannels();
      if (mounted) setState(() => _loadingChannels = false);
    });
  }

  /// Now/next lines come from the cached guide — fetch visible rows in one
  /// batch instead of a request per row.
  void _prefetchGuides(List<MediaItem> channels) {
    if (channels.isEmpty || !mounted) return;
    final library = context.read<LibraryProvider>();
    final need = <MediaItem>[];
    for (final channel in channels) {
      final key = channel.streamId ?? channel.id;
      if (library.isGuideFetched(channel) || library.isGuideLoading(channel)) {
        continue;
      }
      if (!_guidePrefetched.add(key)) continue;
      need.add(channel);
      if (need.length >= 12) break;
    }
    if (need.isEmpty) return;
    unawaited(
      library.fetchChannelGuides(need, concurrency: 6).whenComplete(() {
        for (final channel in need) {
          if (!library.isGuideFetched(channel)) {
            _guidePrefetched.remove(channel.streamId ?? channel.id);
          }
        }
      }),
    );
  }

  void _flashInfo() {
    setState(() {
      if (_overlay == _LiveOverlay.none || _overlay == _LiveOverlay.info) {
        _overlay = _LiveOverlay.info;
        _infoActions = false;
        _infoMenuExpanded = false;
      }
    });
    _scheduleInfoHide();
  }

  /// Hide the info bar / OK menu after idle. D-pad or a button press restarts.
  void _scheduleInfoHide() {
    _infoHide?.cancel();
    if (_panelOpen) return;
    final delay = _infoActions ? tvLiveInfoMenuIdleHide : tvLiveInfoFlashHide;
    _infoHide = Timer(delay, () {
      if (!mounted) return;
      if (_pendingZapIndex != null) return;
      if (_panelOpen) return;
      if (_overlay != _LiveOverlay.info) return;
      setState(() {
        _overlay = _LiveOverlay.none;
        _infoActions = false;
        _infoMenuExpanded = false;
      });
      _rootFocus.requestFocus();
    });
  }

  /// OK on the video: transport bar with focusable actions.
  Future<void> _confirmZapThenInfoActions() async {
    if (_pendingZapIndex != null) await _commitPendingZap();
    if (mounted) _openInfoActions();
  }

  void _openInfoActions() {
    final alreadyOpen = _infoActions && _overlay == _LiveOverlay.info;
    setState(() {
      _overlay = _LiveOverlay.info;
      _infoActions = true;
      if (!alreadyOpen) _infoMenuExpanded = false;
    });
    _scheduleInfoHide();
    // Keep focus on the chip / playhead the user is already on (rewind OK
    // must not yank it back to Browse). Parent [_rootFocus] already has
    // focus when the menu first opens, so autofocus on children is ignored.
    if (alreadyOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_infoActions) return;
      if (_infoPlayFocus.canRequestFocus) _infoPlayFocus.requestFocus();
    });
  }

  void _collapseInfoMenu() {
    if (!_infoMenuExpanded) return;
    setState(() => _infoMenuExpanded = false);
    _scheduleInfoHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_infoActions) return;
      if (_infoPlayFocus.canRequestFocus) _infoPlayFocus.requestFocus();
    });
  }

  void _expandInfoMenu() {
    if (_infoMenuExpanded) return;
    setState(() => _infoMenuExpanded = true);
    _scheduleInfoHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_infoActions || !_infoMenuExpanded) return;
      if (_infoBrowseFocus.canRequestFocus) _infoBrowseFocus.requestFocus();
    });
  }

  void _openOverlay(_LiveOverlay next) {
    _infoHide?.cancel();
    setState(() {
      _overlay = next;
      _infoActions = false;
      _infoMenuExpanded = false;
    });
  }

  void _closePanelOverlays({bool absorbLeave = false}) {
    // Browse/guide handle Back themselves; claim so the paired Navigator pop
    // does not treat this press as leave-watch.
    if (absorbLeave) {
      _backGate.claim();
      _backGate.armAbsorbLeave();
      _liveLeavePending = false;
    }
    setState(() {
      _overlay = _LiveOverlay.none;
      _infoActions = false;
      _infoMenuExpanded = false;
    });
    _rootFocus.requestFocus();
  }

  void _onOverlayClosedByBack() => _closePanelOverlays(absorbLeave: true);

  /// Left / Right from fullscreen: channel list, then categories one step left.
  Future<void> _openBrowse({
    String? sectionId,
    bool focusSections = false,
  }) async {
    final changed = sectionId != null && sectionId != _sectionId;
    _infoHide?.cancel();
    final library = context.read<LibraryProvider>();
    _ensureLiveGroupNames(library);
    setState(() {
      if (sectionId != null) _sectionId = sectionId;
      if (changed) {
        _searchQuery = '';
        _channels = const [];
        _channelOffset = 0;
        _hasMoreChannels = false;
        _loadingChannels = true;
      }
      _browseFocusSections = focusSections;
      _overlay = _LiveOverlay.browse;
      _infoActions = false;
      _infoMenuExpanded = false;
    });
    if (!changed) return;
    await _reloadChannels();
    if (mounted) setState(() => _loadingChannels = false);
  }

  Future<void> _selectSection(TvLiveBrowseSection section) async {
    if (section.id == _sectionId) return;
    setState(() {
      _sectionId = section.id;
      _searchQuery = '';
      // Drop the previous list so the pane shows a spinner while we page /
      // demand-fetch a cold Xtream category (otherwise empty flashes as
      // "No channels in this list" with video still playing underneath).
      _channels = const [];
      _channelOffset = 0;
      _hasMoreChannels = false;
      _loadingChannels = true;
    });
    await _reloadChannels();
    if (mounted) setState(() => _loadingChannels = false);
  }

  Future<void> _tune(MediaItem channel, {bool flashInfo = true}) async {
    _zapDebounce?.cancel();
    _zapDebounce = null;
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final multi = context.read<MultiViewProvider>();
    final pending = _pendingZapChannel(playback);
    if (pending != null && !_sameChannel(pending, channel)) {
      _pendingZapIndex = null;
    }
    final resolved = library.resolveLiveChannel(channel);
    if (multi.isActive && multi.focusedPane == MultiViewPane.secondary) {
      await multi.retuneSecondary(resolved, library: library);
    } else {
      await playback.open(resolved, expand: false);
    }
    unawaited(library.fetchChannelGuide(resolved));
    if (!mounted) return;
    if (_sameChannel(_pendingZapChannel(playback), resolved)) {
      _pendingZapIndex = null;
    }
    if (flashInfo) {
      _flashInfo();
    } else {
      setState(() {});
    }
  }

  /// Focused row in browse: prefetch guide only — video retunes on OK.
  void _focusBrowseChannel(MediaItem channel) {
    final library = context.read<LibraryProvider>();
    final resolved = library.resolveLiveChannel(channel);
    unawaited(library.fetchChannelGuide(resolved));
  }

  /// OK on a channel: commit that stream and dismiss the overlay (no reload
  /// when the session already matches the focused row).
  Future<void> _promote(MediaItem channel) async {
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final resolved = library.resolveLiveChannel(channel);
    final already = _sameChannel(playback.liveChannel, resolved);
    _cancelPendingZap(notify: false);
    _closePanelOverlays();
    if (!already) {
      await _tune(resolved, flashInfo: false);
      if (!mounted) return;
    }
    _flashInfo();
  }

  /// Catchup / archive stays in the TV shell — never push phone `/player`.
  Future<void> _openCatchup(MediaItem channel, EpgProgram program) async {
    _cancelPendingZap(notify: false);
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final resolved = library.resolveLiveChannel(channel);
    final item = await library.catchupItemAsync(
      channel: resolved,
      program: program,
    );
    if (item == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.catchupRequiresArchive)),
      );
      return;
    }
    _closePanelOverlays();
    await playback.open(item, expand: false);
    if (mounted) _flashInfo();
  }

  MediaItem? _focusedPlayingChannel(
    PlaybackProvider playback,
    MultiViewProvider multi,
  ) {
    if (multi.isActive && multi.focusedPane == MultiViewPane.secondary) {
      return multi.secondaryChannel;
    }
    return playback.liveChannel ?? playback.item;
  }

  MediaItem? _pendingZapChannel(PlaybackProvider playback) {
    final idx = _pendingZapIndex;
    final list = playback.liveZapList;
    if (idx == null || idx < 0 || idx >= list.length) return null;
    return list[idx];
  }

  void _cancelPendingZap({bool notify = true}) {
    _zapDebounce?.cancel();
    _zapDebounce = null;
    if (_pendingZapIndex == null) return;
    _pendingZapIndex = null;
    if (notify && mounted) setState(() {});
  }

  Future<void> _commitPendingZap() async {
    final idx = _pendingZapIndex;
    if (idx == null) return;
    final playback = context.read<PlaybackProvider>();
    final multi = context.read<MultiViewProvider>();
    final list = playback.liveZapList;
    if (idx < 0 || idx >= list.length) {
      _cancelPendingZap();
      return;
    }
    final channel = list[idx];
    final playing = _focusedPlayingChannel(playback, multi);
    if (_sameChannel(channel, playing)) {
      _cancelPendingZap();
      return;
    }
    await _tune(channel);
  }

  bool get _chromeVisible => tvLiveChromeIsVisible(
    overlayIsInfo: _overlay == _LiveOverlay.info,
    infoActionsOpen: _infoActions,
  );

  /// CH± / ↑↓: reveal the player bar first, then zap on the next press.
  void _onVerticalZap(int delta, {required bool isRepeat}) {
    if (_panelOpen) {
      _zapHoldFromHiddenChrome = false;
      _zap(delta);
      return;
    }
    switch (tvLiveVerticalZapAction(chromeVisible: _chromeVisible)) {
      case TvLiveVerticalZapAction.revealChrome:
        _zapHoldFromHiddenChrome = true;
        _flashInfo();
      case TvLiveVerticalZapAction.zap:
        if (isRepeat && _zapHoldFromHiddenChrome) return;
        _zapHoldFromHiddenChrome = false;
        _zap(delta);
    }
  }

  void _zap(int delta) {
    final playback = context.read<PlaybackProvider>();
    final multi = context.read<MultiViewProvider>();
    final list = playback.liveZapList;
    if (list.isEmpty || delta == 0) return;

    final playing = _focusedPlayingChannel(playback, multi);
    final currentIdx =
        _pendingZapIndex ??
        (playing == null
            ? -1
            : list.indexWhere((c) => _sameChannel(c, playing)));
    MediaItem? skip;
    if (multi.isActive) {
      skip = multi.focusedPane == MultiViewPane.secondary
          ? playback.item
          : multi.secondaryChannel;
    }
    final nextIdx = liveZapRelativeIndexSkipping(
      length: list.length,
      currentIndex: currentIdx,
      delta: delta,
      skip: (i) => skip != null && _sameChannel(list[i], skip),
    );
    if (nextIdx == null) return;

    _zapDebounce?.cancel();
    _pendingZapIndex = nextIdx;
    _flashInfo();
    _zapDebounce = Timer(tvLiveZapDebounce, () {
      unawaited(_commitPendingZap());
    });
  }

  Future<void> _toggleMultiView() async {
    if (!AppCapabilities.multiView) return;
    await _commitPendingZap();
    if (!mounted) return;
    await openMultiViewFromContext(context);
    if (mounted) _flashInfo();
  }

  void _onDigit(String digit) {
    _cancelPendingZap(notify: false);
    _digitTimer?.cancel();
    setState(() {
      final next = '$_digitBuffer$digit';
      _digitBuffer = next.length > 4 ? next.substring(next.length - 4) : next;
    });
    _digitTimer = Timer(const Duration(milliseconds: 1200), () async {
      final n = int.tryParse(_digitBuffer);
      if (!mounted) return;
      setState(() => _digitBuffer = '');
      if (n == null) return;
      final playback = context.read<PlaybackProvider>();
      final library = context.read<LibraryProvider>();
      final multi = context.read<MultiViewProvider>();
      final bool ok;
      if (multi.isActive) {
        ok = await multi.zapFocusedByIndex(
          n,
          library: library,
          playback: playback,
        );
      } else {
        ok = await playback.zapLiveByNumber(n);
      }
      if (!mounted) return;
      if (ok) {
        final ch =
            multi.isActive && multi.focusedPane == MultiViewPane.secondary
            ? multi.secondaryChannel
            : playback.liveChannel;
        if (ch != null) {
          unawaited(library.fetchChannelGuide(ch));
        }
        _flashInfo();
      }
    });
  }

  Future<void> _exitWatch() async {
    if (_sessionHandedOff) return;
    _cancelPendingZap(notify: false);
    final playback = context.read<PlaybackProvider>();
    _sessionHandedOff = true;
    // Don't await — VOD pops on the paired system Back; delaying here lets
    // that leftover pop finish the Activity after this route is gone.
    unawaited(playback.minimize());
    if (!mounted) return;
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    final path = router.routerDelegate.currentConfiguration.uri.path;
    if (path == '/tv/watch') {
      router.go('/home');
    }
  }

  /// Close chrome / overlays. False means this Back should leave watch.
  ///
  /// Android TV sends both a key event and a Navigator pop for the same
  /// press — [TvBackGate] keeps that from closing the menu *and* popping
  /// to Home.
  ///
  /// [allowLeave] is false on the key path so we never pop /tv/watch before
  /// the twin popRoute (that finishes the Activity on Fire TV). PopScope
  /// calls with [allowLeave] true.
  void _onBack({bool allowLeave = true}) {
    if (!tvRouteIsCurrent(context)) return;
    if (!_backGate.claim()) return;
    // Twin popRoute after hiding the OK menu can miss [TvBackGate.coalesceWindow]
    // and would otherwise leave `/tv/watch` (mini player / previous screen).
    if (_backGate.takeAbsorbLeave()) return;
    final multi = context.read<MultiViewProvider>();
    switch (tvLiveBackAction(
      overlayOpen: _panelOpen,
      chromeVisible: _chromeVisible,
      settingsNested: _settingsKey.currentState?.handleBack() ?? false,
      multiViewActive: multi.isActive,
    )) {
      case TvLiveBackAction.popSettingsPage:
        _backGate.armAbsorbLeave();
        _liveLeavePending = false;
        return;
      case TvLiveBackAction.closeOverlay:
      case TvLiveBackAction.hideChrome:
        if (_overlay == _LiveOverlay.info) {
          _cancelPendingZap(notify: false);
        }
        _closePanelOverlays(absorbLeave: true);
        return;
      case TvLiveBackAction.exitMultiView:
        _backGate.armAbsorbLeave();
        _liveLeavePending = false;
        unawaited(multi.exit());
        return;
      case TvLiveBackAction.leaveWatch:
        if (!allowLeave) {
          // Twin PopScope owns leaving — release the gate claim so it can run.
          _backGate.reset();
          _liveLeavePending = true;
          Future<void>.delayed(TvBackGate.leaveFallbackDelay, () {
            if (!mounted || !_liveLeavePending) return;
            _liveLeavePending = false;
            unawaited(_exitWatch());
          });
          return;
        }
        _liveLeavePending = false;
        unawaited(_exitWatch());
    }
  }

  Future<void> _openChannelActions(MediaItem channel) async {
    final library = context.read<LibraryProvider>();
    final now = library.nowPlayingFor(channel);
    final canStartOver =
        now != null &&
        (library.liveSupportsCatchup(channel) || now.hasArchive);
    await showMediaItemActions(
      context: context,
      item: channel,
      onPlay: () => unawaited(_promote(channel)),
      onStartOver: canStartOver
          ? () => unawaited(_openCatchup(channel, now))
          : null,
      showDetails: false,
      showWatchlist: false,
      showDownload: false,
      showPlaylists: false,
    );
  }

  Future<void> _openSectionActions(TvLiveBrowseSection section) async {
    final category = section.category;
    if (category == null) return;
    await showLiveCategoryActions(
      context: context,
      category: category,
      onOpen: () => unawaited(_selectSection(section)),
    );
  }

  bool get _panelOpen =>
      _overlay == _LiveOverlay.browse ||
      _overlay == _LiveOverlay.guide ||
      _overlay == _LiveOverlay.settings ||
      _overlay == _LiveOverlay.epg;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isRepeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !isRepeat) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final playback = context.read<PlaybackProvider>();
    final multi = context.read<MultiViewProvider>();

    if (isTvBackKey(key)) {
      if (isRepeat) return KeyEventResult.handled;
      if (!tvRouteIsCurrent(context)) return KeyEventResult.ignored;
      _onBack(allowLeave: false);
      return KeyEventResult.handled;
    }

    // Set-top keys that mean nothing inside a panel keep working while one is
    // open — the browse list follows along because it is the zap list.
    if (key == LogicalKeyboardKey.channelUp) {
      _onVerticalZap(1, isRepeat: isRepeat);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown) {
      _onVerticalZap(-1, isRepeat: isRepeat);
      return KeyEventResult.handled;
    }
    if (isRepeat) {
      if (_panelOpen) return KeyEventResult.ignored;
      if (tvLiveMenuOwnsDpad(
            infoActionsOpen: _infoActions,
            panelOpen: _panelOpen,
          ) &&
          (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.pageUp ||
              key == LogicalKeyboardKey.pageDown)) {
        _scheduleInfoHide();
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.pageUp) {
        _onVerticalZap(1, isRepeat: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.pageDown) {
        _onVerticalZap(-1, isRepeat: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      unawaited(playback.togglePlayPause());
      if (!_panelOpen) _flashInfo();
      return KeyEventResult.handled;
    }
    final digitKey = _digitFromKey(key);
    if (digitKey != null) {
      _onDigit(digitKey);
      return KeyEventResult.handled;
    }

    // Browse / guide / settings panels own their own focus trees.
    if (_panelOpen) return KeyEventResult.ignored;

    // First Down from the OK transport row reveals browse / guide / settings.
    if (_infoActions &&
        !_infoMenuExpanded &&
        !_playheadFocus.hasFocus &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.pageDown)) {
      _expandInfoMenu();
      return KeyEventResult.handled;
    }

    // Up tucks that row half off-screen and returns focus to Play.
    if (_infoActions &&
        _infoMenuExpanded &&
        !_playheadFocus.hasFocus &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.pageUp)) {
      _collapseInfoMenu();
      return KeyEventResult.handled;
    }

    // OK menu chips own the D-pad (including ↑↓). Channel± still zaps above.
    if (tvLiveMenuOwnsDpad(
          infoActionsOpen: _infoActions,
          panelOpen: _panelOpen,
        ) &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.pageUp ||
            key == LogicalKeyboardKey.pageDown)) {
      _scheduleInfoHide();
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.keyV) {
      unawaited(_toggleMultiView());
      return KeyEventResult.handled;
    }
    if (multi.isActive && key == LogicalKeyboardKey.keyA) {
      unawaited(multi.swapAudio());
      _flashInfo();
      return KeyEventResult.handled;
    }
    // Leanback remotes: next/prev track switches the focused multi-view pane
    // (←/→ stay on browse layers when multi is off).
    if (multi.isActive &&
        (key == LogicalKeyboardKey.mediaTrackNext ||
            key == LogicalKeyboardKey.mediaTrackPrevious ||
            key == LogicalKeyboardKey.tab)) {
      if (key == LogicalKeyboardKey.mediaTrackNext) {
        multi.setFocusedPane(MultiViewPane.secondary);
      } else if (key == LogicalKeyboardKey.mediaTrackPrevious) {
        multi.setFocusedPane(MultiViewPane.primary);
      } else {
        multi.toggleFocusedPane();
      }
      _flashInfo();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
      _onVerticalZap(1, isRepeat: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      _onVerticalZap(-1, isRepeat: false);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      unawaited(playback.togglePlayPause());
      _flashInfo();
      return KeyEventResult.handled;
    }

    // Timeshift lives on the transport keys (and the OK transport bar) so the
    // arrows can stay on the channel / category layers.
    if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.comma) {
      if (!playback.canLiveDvr) return KeyEventResult.handled;
      unawaited(playback.seekLiveDvrBy(-_dvrStep));
      _flashInfo();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.period) {
      if (!playback.canLiveDvr) return KeyEventResult.handled;
      unawaited(playback.seekLiveDvrBy(_dvrStep));
      _flashInfo();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final action = tvLiveHorizontalAction(
        towardsLeft: key == LogicalKeyboardKey.arrowLeft,
        multiViewActive: multi.isActive,
        transportFocused: _infoActions,
      );
      switch (action) {
        case TvLiveDpadAction.focusPrimaryPane:
          multi.setFocusedPane(MultiViewPane.primary);
          _flashInfo();
        case TvLiveDpadAction.focusSecondaryPane:
          multi.setFocusedPane(MultiViewPane.secondary);
          _flashInfo();
        case TvLiveDpadAction.transportFocus:
          // The transport bar buttons own the arrows while it has focus.
          return KeyEventResult.ignored;
        case TvLiveDpadAction.openChannels:
          unawaited(_openBrowse());
        case TvLiveDpadAction.openRecents:
          unawaited(_openBrowse(sectionId: TvLiveBrowseSection.recentsId));
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_infoActions) return KeyEventResult.ignored;
      unawaited(_confirmZapThenInfoActions());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyI || key == LogicalKeyboardKey.info) {
      _flashInfo();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyG || key == LogicalKeyboardKey.guide) {
      _openGuide();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyP && phoneRemoteEntryAvailable) {
      unawaited(openPhoneRemote(context));
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.mediaTopMenu) {
      _openOverlay(_LiveOverlay.settings);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _openGuide() {
    if (_channels.isEmpty) return;
    _prefetchGuides(_channels.take(14).toList());
    _openOverlay(_LiveOverlay.guide);
  }

  String? _digitFromKey(LogicalKeyboardKey key) {
    final map = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
    };
    return map[key];
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    // Identity only — playhead ticks must not rebuild browse/video/chrome.
    context.select<PlaybackProvider, Object>(
      (p) => Object.hash(
        p.engineRevision,
        p.hasSession,
        p.isLoading,
        p.error,
        p.liveChannel?.id,
        p.item?.id,
        p.liveZapList.length,
        p.currentProgram?.title,
        p.nextProgram?.title,
      ),
    );
    final multi = context.watch<MultiViewProvider>();
    final captions = context.watch<CaptionStyleProvider>();
    final capSig = Object.hash(captions.style, captions.extraFontsDir);
    if (capSig != _appliedCaptionSig) {
      _appliedCaptionSig = capSig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          playback.applyCaptionStyle(
            captions.style,
            extraFontsDir: captions.extraFontsDir,
          ),
        );
      });
    }

    final hasLiveSources = library.sources.any((s) => s.type.supportsLive);
    final browsing = _overlay == _LiveOverlay.browse;
    if (browsing) _ensureLiveGroupNames(library);

    final playingChannel = _focusedPlayingChannel(playback, multi);
    final pendingChannel = _pendingZapChannel(playback);
    final channel = pendingChannel ?? playingChannel;
    final previewing =
        pendingChannel != null && !_sameChannel(pendingChannel, playingChannel);
    final now = previewing
        ? library.nowPlayingFor(channel!)
        : (multi.isActive && multi.focusedPane == MultiViewPane.secondary
              ? (channel != null ? library.nowPlayingFor(channel) : null)
              : (playback.currentProgram ??
                    (channel != null ? library.nowPlayingFor(channel) : null)));
    final next = previewing
        ? library.nextProgramFor(channel!)
        : (multi.isActive && multi.focusedPane == MultiViewPane.secondary
              ? (channel != null ? library.nextProgramFor(channel) : null)
              : (playback.nextProgram ??
                    (channel != null
                        ? library.nextProgramFor(channel)
                        : null)));

    return SleepTimerFeedback(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _onBack();
        },
        child: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Colors.black),
                    ),
                    // Session owns the screen; browse/guide are overlays only.
                    Positioned.fill(
                      child: Selector<PlaybackProvider, Object>(
                        selector: (_, p) => Object.hash(
                          p.engineRevision,
                          p.hasSession,
                          p.isAudioOnly,
                          p.isMinimized,
                          p.fullPlayerOwnsVideo,
                        ),
                        builder: (context, _, _) {
                          final playback = context.read<PlaybackProvider>();
                          final captions = context
                              .watch<CaptionStyleProvider>();
                          if (!playback.hasSession ||
                              playback.isMinimized ||
                              !playback.fullPlayerOwnsVideo) {
                            return const ColoredBox(color: Colors.black);
                          }
                          final subtitles = captions.style
                              .toSubtitleViewConfiguration();
                          return AppCapabilities.multiView
                              ? MultiViewPlaybackSurface(
                                  playback: playback,
                                  subtitleViewConfiguration: subtitles,
                                )
                              : PlaybackVideoSurface.forSession(
                                  playback,
                                  subtitleViewConfiguration: subtitles,
                                );
                        },
                      ),
                    ),
                    if (browsing)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Color(0xCC07080C),
                                  Color(0x6607080C),
                                  Color(0x1407080C),
                                ],
                                stops: [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (AppCapabilities.multiView && !browsing)
                      const Positioned(
                        right: 24,
                        top: 24,
                        child: MultiViewToolbar(),
                      ),
                    if (_loadingChannels &&
                        !browsing &&
                        !(playback.isLoading && playback.error == null))
                      const Center(child: CircularProgressIndicator())
                    else if (_channels.isEmpty && !browsing)
                      _EmptyLive(
                        hasSources:
                            hasLiveSources || library.sources.isNotEmpty,
                        onAddSources: () => context.push('/sources'),
                        onHome: () => context.go('/home'),
                      ),
                    if (playback.isLoading &&
                        playback.error == null &&
                        !browsing &&
                        !previewing)
                      IgnorePointer(
                        child: Center(
                          child: PlayerLoadingBadge(
                            key: PlayerLoadingBadge.overlayKey,
                            label: PlayerLoadingBadge.labelFor(
                              context,
                              playback,
                            ),
                            artworkUrl: PlayerLoadingBadge.artworkFor(playback),
                          ),
                        ),
                      ),
                    if (playback.error != null && !browsing && !previewing)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                playback.error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white),
                              ),
                              const SizedBox(height: 16),
                              TvFocusable(
                                autofocus: true,
                                onSelect: playback.retry,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(context.l10n.retry),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_digitBuffer.isNotEmpty)
                      Positioned(
                        top: 48,
                        right: 48,
                        child: _DigitOsd(buffer: _digitBuffer),
                      ),
                    if (_overlay == _LiveOverlay.info && channel != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Consumer<PlaybackProvider>(
                          builder: (context, playback, _) => _InfoBar(
                            channel: channel,
                            now: now,
                            next: next,
                            index:
                                _pendingZapIndex ??
                                playback.liveZapList.indexWhere(
                                  (c) => _sameChannel(c, playingChannel),
                                ),
                            total: playback.liveZapList.length,
                            playing: previewing ? true : playback.playing,
                            isAtLiveEdge: previewing
                                ? true
                                : playback.isAtLiveEdge,
                            canStartOver: previewing
                                ? false
                                : playback.canStartOver,
                            canLiveDvr: previewing
                                ? false
                                : playback.canLiveDvr,
                            liveDelay: previewing
                                ? Duration.zero
                                : playback.liveDelay,
                            liveDvrProgress: previewing
                                ? 1
                                : playback.liveDvrProgress,
                            liveProgramProgress: previewing
                                ? 1
                                : playback.liveProgramProgress,
                            liveProgramLiveFraction: previewing
                                ? 1
                                : playback.liveProgramLiveFraction,
                            useProgramScrub: previewing
                                ? (library.liveScrubMode ==
                                          LiveScrubMode.program &&
                                      now != null)
                                : playback.usesProgramScrubber,
                            wallClock: previewing
                                ? DateTime.now()
                                : playback.playbackWallClock,
                            pinPlayheadAtLive: previewing,
                            formatTime: _hhmm,
                            showActions: _infoActions,
                            menuExpanded: _infoMenuExpanded,
                            firstActionFocus: _infoBrowseFocus,
                            playFocus: _infoPlayFocus,
                            playheadFocus: _playheadFocus,
                            onPlayPause: () {
                              unawaited(playback.togglePlayPause());
                              _scheduleInfoHide();
                            },
                            onStartOver: () async {
                              await playback.startOverCurrentProgram();
                              _flashInfo();
                            },
                            onJumpLive: () async {
                              await playback.jumpToLive();
                              _flashInfo();
                            },
                            onRewind: () async {
                              await playback.seekLiveDvrBy(-_dvrStep);
                              if (mounted) _openInfoActions();
                            },
                            onForward: () async {
                              await playback.seekLiveDvrBy(_dvrStep);
                              if (mounted) _openInfoActions();
                            },
                            onBrowse: () => unawaited(_openBrowse()),
                            onGuide: _openGuide,
                            onToggleScrubMode:
                                playback.canLiveDvr && now != null
                                ? () async {
                                    final next =
                                        library.liveScrubMode ==
                                            LiveScrubMode.timeline
                                        ? LiveScrubMode.program
                                        : LiveScrubMode.timeline;
                                    await library.setLiveScrubMode(next);
                                    if (mounted) _openInfoActions();
                                  }
                                : null,
                            onChannelSchedule: () {
                              unawaited(library.fetchChannelGuide(channel));
                              _openOverlay(_LiveOverlay.epg);
                            },
                            onSettings: () =>
                                _openOverlay(_LiveOverlay.settings),
                            onMultiView: AppCapabilities.multiView
                                ? () => unawaited(_toggleMultiView())
                                : null,
                            onSwapAudio:
                                AppCapabilities.multiView && multi.isActive
                                ? () {
                                    unawaited(multi.swapAudio());
                                    _flashInfo();
                                  }
                                : null,
                            onTogglePane:
                                AppCapabilities.multiView && multi.isActive
                                ? () {
                                    multi.toggleFocusedPane();
                                    _flashInfo();
                                  }
                                : null,
                            onPhoneRemote: phoneRemoteEntryAvailable
                                ? () => unawaited(openPhoneRemote(context))
                                : null,
                          ),
                        ),
                      ),
                    if (browsing)
                      Positioned.fill(
                        child: TvLiveBrowsePanes(
                          sections: _sections(context, library),
                          selectedSectionId: _sectionId,
                          channels: _channels,
                          loadingChannels: _loadingChannels,
                          currentChannel: channel ?? playingChannel,
                          titleFor: library.officialLiveTitle,
                          nowFor: library.nowPlayingFor,
                          nextFor: library.nextProgramFor,
                          programsFor: (c) => library.nearbyPrograms(
                            c,
                            before: tvLiveBrowseEpgBeforeCount(
                              supportsCatchup: library.liveSupportsCatchup(c),
                              catchupDays: library.liveFamilyCatchupDays(c),
                            ),
                            after: tvLiveBrowseEpgAfterCount,
                          ),
                          isFavorite: library.isFavoriteChannel,
                          onSelectSection: (section) =>
                              unawaited(_selectSection(section)),
                          onFocusChannel: _focusBrowseChannel,
                          onPlayChannel: (c) => unawaited(_promote(c)),
                          onPlayProgram: (c, program) =>
                              unawaited(_openCatchup(c, program)),
                          onChannelActions: (c) =>
                              unawaited(_openChannelActions(c)),
                          onSectionActions: (s) =>
                              unawaited(_openSectionActions(s)),
                          onVisibleChannels: _prefetchGuides,
                          onNearEnd: _sectionSupportsPaging
                              ? () => unawaited(_loadMoreChannels())
                              : null,
                          onSearchChanged: _sectionSupportsSearch
                              ? _onBrowseSearchChanged
                              : null,
                          searchQuery: _searchQuery,
                          onClose: _onOverlayClosedByBack,
                          focusSectionsFirst: _browseFocusSections,
                        ),
                      ),
                    if (_overlay == _LiveOverlay.guide)
                      Positioned.fill(
                        child: TvLiveGuideOverlay(
                          channels: _channels,
                          currentChannel: channel ?? playingChannel,
                          onTune: (c) {
                            _closePanelOverlays();
                            unawaited(_tune(c));
                          },
                          onPlayProgram: (c, program) =>
                              unawaited(_openCatchup(c, program)),
                          onNearEnd: _sectionSupportsPaging
                              ? () => unawaited(_loadMoreChannels())
                              : null,
                          onClose: _onOverlayClosedByBack,
                        ),
                      ),
                    if (_overlay == _LiveOverlay.settings)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        width: 420,
                        child: TvPlayerSettingsOverlay(
                          key: _settingsKey,
                          allowSpeed: playback.canLiveDvr,
                          onClose: _onOverlayClosedByBack,
                        ),
                      ),
                    if (_overlay == _LiveOverlay.epg && channel != null)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        width: 440,
                        child: TvEpgOverlay(
                          channel: channel,
                          onClose: _onOverlayClosedByBack,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DigitOsd extends StatelessWidget {
  const _DigitOsd({required this.buffer});
  final String buffer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent),
      ),
      child: Text(
        buffer,
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 4,
        ),
      ),
    );
  }
}

class _InfoBar extends StatelessWidget {
  const _InfoBar({
    required this.channel,
    required this.now,
    required this.next,
    required this.index,
    required this.total,
    required this.playing,
    required this.isAtLiveEdge,
    required this.canStartOver,
    required this.canLiveDvr,
    required this.liveDelay,
    required this.liveDvrProgress,
    this.liveProgramProgress,
    this.liveProgramLiveFraction,
    required this.useProgramScrub,
    required this.wallClock,
    required this.formatTime,
    this.pinPlayheadAtLive = false,
    required this.showActions,
    this.menuExpanded = false,
    this.firstActionFocus,
    this.playFocus,
    this.playheadFocus,
    required this.onPlayPause,
    required this.onStartOver,
    required this.onJumpLive,
    required this.onRewind,
    required this.onForward,
    this.onToggleScrubMode,
    required this.onBrowse,
    required this.onGuide,
    required this.onChannelSchedule,
    required this.onSettings,
    this.onMultiView,
    this.onSwapAudio,
    this.onTogglePane,
    this.onPhoneRemote,
  });

  final MediaItem? channel;
  final EpgProgram? now;
  final EpgProgram? next;
  final int index;
  final int total;
  final bool playing;
  final bool isAtLiveEdge;
  final bool canStartOver;
  final bool canLiveDvr;
  final Duration liveDelay;
  final double liveDvrProgress;
  final double? liveProgramProgress;
  final double? liveProgramLiveFraction;
  final bool useProgramScrub;
  final DateTime wallClock;
  final String Function(DateTime) formatTime;
  final bool pinPlayheadAtLive;
  final bool showActions;
  final bool menuExpanded;
  final FocusNode? firstActionFocus;
  final FocusNode? playFocus;
  final FocusNode? playheadFocus;
  final VoidCallback onPlayPause;
  final VoidCallback onStartOver;
  final VoidCallback onJumpLive;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback? onToggleScrubMode;
  final VoidCallback onBrowse;
  final VoidCallback onGuide;
  final VoidCallback onChannelSchedule;
  final VoidCallback onSettings;
  final VoidCallback? onMultiView;
  final VoidCallback? onSwapAudio;
  final VoidCallback? onTogglePane;
  final VoidCallback? onPhoneRemote;

  @override
  Widget build(BuildContext context) {
    if (channel == null) return const SizedBox.shrink();
    final num = index >= 0 ? '${index + 1}' : '—';
    final nowTitle = now?.title;
    final nextTitle = next?.title;
    double? epgNowProgress;
    if (now != null) {
      final span = now!.end.difference(now!.start).inMilliseconds;
      if (span > 0) {
        epgNowProgress =
            (wallClock.difference(now!.start).inMilliseconds / span).clamp(
              0.0,
              1.0,
            );
      }
    }
    final showPlayhead = canLiveDvr || epgNowProgress != null;
    final progress = livePlayheadProgress(
      canLiveDvr: canLiveDvr,
      atLiveEdge: isAtLiveEdge,
      useProgramScrub: useProgramScrub,
      liveDvrProgress: liveDvrProgress,
      liveProgramProgress: liveProgramProgress,
      epgNowProgress: epgNowProgress,
      pinAtLive: pinPlayheadAtLive,
    );
    final playheadColor = livePlayheadColor(
      canLiveDvr: canLiveDvr,
      atLiveEdge: isAtLiveEdge,
    );
    final l10n = context.l10n;
    final clock = formatTime(wallClock);
    final String playheadLabel;
    if (useProgramScrub && now != null) {
      playheadLabel = formatLiveProgramScrubLabel(
        atLive: isAtLiveEdge,
        liveDelay: liveDelay,
        programTitle: now!.title,
        clock: clock,
        liveBadge: l10n.liveBadge,
      );
    } else if (canLiveDvr) {
      playheadLabel = formatLiveDvrScrubLabel(
        delay: liveDelay,
        clock: clock,
        programTitle: now?.title,
        dvrScrubHint: l10n.dvrScrubHint,
        liveBadge: l10n.liveBadge,
      );
    } else {
      playheadLabel = now == null
          ? l10n.liveBadge
          : '${formatTime(now!.start)}–${formatTime(now!.end)}';
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        28,
        20,
        28,
        showActions && !menuExpanded ? 0 : 28,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isAtLiveEdge ? AppColors.live : AppColors.accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isAtLiveEdge
                      ? (playing ? 'LIVE' : 'PAUSED')
                      : '−${_fmtDelay(liveDelay)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              TvChannelLogo(url: channel!.thumbnailUrl, size: 52),
              const SizedBox(width: 14),
              Text(
                num,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              if (total > 0)
                Text(
                  ' / $total',
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.read<LibraryProvider>().officialLiveTitle(
                        channel!,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    if ((nowTitle ?? '').isNotEmpty)
                      Text(
                        now == null
                            ? nowTitle!
                            : '${formatTime(now!.start)}–${formatTime(now!.end)}  ·  $nowTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                        ),
                      ),
                    if ((nextTitle ?? '').isNotEmpty)
                      Text(
                        next == null
                            ? '${context.l10n.nextProgramLabel} · $nextTitle'
                            : '${context.l10n.nextProgramLabel} · '
                                  '${formatTime(next!.start)}  $nextTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (showPlayhead || showActions)
            FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showPlayhead) ...[
                    const SizedBox(height: 10),
                    TvLiveDvrPlayhead(
                      key: const Key('tvLiveDvrPlayhead'),
                      progress: progress,
                      color: playheadColor,
                      liveEdge: useProgramScrub
                          ? liveProgramLiveFraction
                          : null,
                      label: playheadLabel,
                      focusNode: playheadFocus,
                      focusable: showActions && canLiveDvr,
                      onRewind: canLiveDvr ? onRewind : null,
                      onForward: canLiveDvr ? onForward : null,
                      onSelect: onToggleScrubMode,
                    ),
                  ],
                  if (showActions) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (canLiveDvr)
                          TvPlayerIconButton(
                            icon: Icons.replay_10_rounded,
                            tooltip: context.l10n.rewind10Seconds,
                            onSelect: onRewind,
                          ),
                        TvPlayerIconButton(
                          autofocus: !canLiveDvr,
                          focusNode: playFocus,
                          icon: playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: playing
                              ? context.l10n.pause
                              : context.l10n.play,
                          onSelect: onPlayPause,
                          primary: true,
                        ),
                        if (canLiveDvr)
                          TvPlayerIconButton(
                            icon: Icons.forward_10_rounded,
                            tooltip: context.l10n.forward10Seconds,
                            onSelect: onForward,
                          ),
                        if (canStartOver) ...[
                          const SizedBox(width: 8),
                          TvPlayerIconButton(
                            icon: Icons.replay_rounded,
                            tooltip: context.l10n.startOver,
                            caption: context.l10n.startOver,
                            captionBeside: true,
                            onSelect: onStartOver,
                          ),
                        ],
                        if (canLiveDvr) ...[
                          const SizedBox(width: 8),
                          TvPlayerIconButton(
                            icon: Icons.cell_tower_rounded,
                            tooltip: context.l10n.jumpToLive,
                            caption: context.l10n.jumpToLive,
                            captionBeside: true,
                            onSelect: onJumpLive,
                            muted: isAtLiveEdge,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRect(
                      child: AnimatedAlign(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        heightFactor: menuExpanded ? 1.0 : 0.5,
                        child: _menuRow(context, enabled: menuExpanded),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 10),
          if (!showActions)
            Text(
              onPhoneRemote != null
                  ? context.l10n.tvLiveWatchHintPhone
                  : context.l10n.tvLiveWatchHint,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _menuRow(BuildContext context, {required bool enabled}) {
    final l10n = context.l10n;
    TvPlayerIconButton button({
      FocusNode? focusNode,
      required IconData icon,
      required String label,
      required VoidCallback onSelect,
    }) {
      return TvPlayerIconButton(
        focusNode: enabled ? focusNode : null,
        icon: icon,
        tooltip: label,
        caption: enabled ? label : null,
        onSelect: onSelect,
        enabled: enabled,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          button(
            focusNode: firstActionFocus,
            icon: Icons.view_list_rounded,
            label: l10n.browseChannels,
            onSelect: onBrowse,
          ),
          const SizedBox(width: 8),
          button(
            icon: Icons.grid_view_rounded,
            label: l10n.guide,
            onSelect: onGuide,
          ),
          const SizedBox(width: 8),
          button(
            icon: Icons.calendar_month_outlined,
            label: l10n.channelSchedule,
            onSelect: onChannelSchedule,
          ),
          const SizedBox(width: 8),
          button(
            icon: Icons.settings_outlined,
            label: l10n.navSettings,
            onSelect: onSettings,
          ),
          if (onMultiView != null) ...[
            const SizedBox(width: 8),
            button(
              icon: Icons.grid_view_rounded,
              label: l10n.multiViewEnter,
              onSelect: onMultiView!,
            ),
          ],
          if (onTogglePane != null) ...[
            const SizedBox(width: 8),
            button(
              icon: Icons.swap_horiz_rounded,
              label: l10n.multiViewToggleFocus,
              onSelect: onTogglePane!,
            ),
          ],
          if (onSwapAudio != null) ...[
            const SizedBox(width: 8),
            button(
              icon: Icons.headphones_rounded,
              label: l10n.multiViewSwapAudio,
              onSelect: onSwapAudio!,
            ),
          ],
          if (onPhoneRemote != null) ...[
            const SizedBox(width: 8),
            button(
              icon: Icons.smartphone_rounded,
              label: l10n.typeOnPhone,
              onSelect: onPhoneRemote!,
            ),
          ],
        ],
      ),
    );
  }

  String _fmtDelay(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = (m % 60).toString().padLeft(2, '0');
      return '$h:$mm:$s';
    }
    return '$m:$s';
  }
}

class _EmptyLive extends StatelessWidget {
  const _EmptyLive({
    required this.hasSources,
    required this.onAddSources,
    required this.onHome,
  });

  final bool hasSources;
  final VoidCallback onAddSources;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.live_tv_rounded,
              size: 64,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              hasSources
                  ? context.l10n.noLiveChannelsYet
                  : context.l10n.addSourceToWatchLive,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              hasSources
                  ? 'Sync your IPTV source, or pick another filter.'
                  : 'Open Pair device on Sources — scan the QR from your phone.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            TvFocusable(
              autofocus: true,
              onSelect: onAddSources,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(context.l10n.openSources),
              ),
            ),
            const SizedBox(height: 12),
            TvFocusable(
              onSelect: onHome,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(context.l10n.navHome),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
