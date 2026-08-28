import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/shell_tabs.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_backdrop.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/widgets/profile_avatar.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/tv/tv_corner_mini_player.dart';
import 'package:javp/widgets/tv/tv_focus_scroll.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/tv/tv_shell_focus.dart';
import 'package:provider/provider.dart';

/// Phone bottom-nav shell, tablet/desktop rail shell, or Android TV left rail.
class ShellScreen extends StatelessWidget {
  const ShellScreen({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static List<({IconData icon, IconData selected, String label})> _destinations(
    BuildContext context, {
    required bool showMusic,
  }) {
    final l10n = context.l10n;
    return [
      for (final tab in ShellTabs.visible(showMusic: showMusic))
        switch (tab) {
          ShellTab.home => (
            icon: Icons.home_outlined,
            selected: Icons.home_rounded,
            label: l10n.navHome,
          ),
          ShellTab.tv => (
            icon: Icons.live_tv_outlined,
            selected: Icons.live_tv_rounded,
            label: l10n.navLive,
          ),
          ShellTab.catalog => (
            icon: Icons.movie_outlined,
            selected: Icons.movie_rounded,
            label: l10n.navCatalog,
          ),
          ShellTab.music => (
            icon: Icons.radio_outlined,
            selected: Icons.radio_rounded,
            label: l10n.navMusic,
          ),
          ShellTab.library => (
            icon: Icons.video_library_outlined,
            selected: Icons.video_library_rounded,
            label: l10n.navLibrary,
          ),
          ShellTab.settings => (
            icon: Icons.settings_outlined,
            selected: Icons.settings_rounded,
            label: l10n.navSettings,
          ),
        },
    ];
  }

  void _goBranch(BuildContext context, int visibleIndex) {
    final showMusic = context
        .read<LibraryProvider>()
        .displaySettings
        .showMusicTab;
    final index = ShellTabs.branchIndexForVisible(
      visibleIndex: visibleIndex,
      showMusic: showMusic,
    );
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
    // Catalog warms empty shelves from its own first paint — do not kick a
    // VOD network prefetch on every tab select.
  }

  @override
  Widget build(BuildContext context) {
    final showMusic = context.select<LibraryProvider, bool>(
      (l) => l.displaySettings.showMusicTab,
    );
    final destinations = _destinations(context, showMusic: showMusic);
    final visibleIndex = ShellTabs.visibleIndex(
      branchIndex: navigationShell.currentIndex,
      showMusic: showMusic,
    );
    final l10n = context.l10n;
    if (TvPlatform.isAndroidTv) {
      return _TvShell(
        navigationShell: navigationShell,
        destinations: destinations,
        currentVisibleIndex: visibleIndex,
        onSelect: (i) => _goBranch(context, i),
      );
    }
    if (AdaptiveLayout.useRail(context)) {
      return _RailShell(
        navigationShell: navigationShell,
        destinations: destinations,
        currentIndex: visibleIndex,
        onSelect: (i) => _goBranch(context, i),
      );
    }
    // Phone shell hosts the mini bar in this column so NavigationBar keeps its
    // own SafeArea. PersistentMiniPlayer covers root routes outside the shell.
    //
    // Do not lift the tab bar with the IME — inner page Scaffolds already
    // resize. Nested resizeToAvoidBottomInset left a stuck gap after the
    // keyboard closed (bottom nav stayed parked above a stale inset).
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: AppBackdrop(child: navigationShell),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayerBar(),
          NavigationBar(
            selectedIndex: visibleIndex,
            onDestinationSelected: (index) => _goBranch(context, index),
            destinations: [
              for (final d in destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.label == l10n.navLive ? l10n.navTv : d.label,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Persistent left rail for desktop and tablets; mini player docks under content.
class _RailShell extends StatelessWidget {
  const _RailShell({
    required this.navigationShell,
    required this.destinations,
    required this.currentIndex,
    required this.onSelect,
  });

  final StatefulNavigationShell navigationShell;
  final List<({IconData icon, IconData selected, String label})> destinations;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final extended = width >= DesktopUi.railExtendedBreakpoint;

    return Scaffold(
      backgroundColor: AppColors.bg,
      // Inner Settings / Live / Catalog Scaffolds handle the IME. Resizing
      // this shell too shrinks the rail with the keyboard and can stick.
      resizeToAvoidBottomInset: false,
      body: Row(
        children: [
          _RailNav(
            destinations: destinations,
            currentIndex: currentIndex,
            onSelect: onSelect,
            extended: extended,
          ),
          const VerticalDivider(width: 1, color: AppColors.border),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Overlay.wrap(
                    clipBehavior: Clip.hardEdge,
                    child: AppBackdrop(child: navigationShell),
                  ),
                ),
                // Keep the dock slot while expanded (under /player) so
                // minimize does not resize the shelf tree on pop.
                const MiniPlayerBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailNav extends StatelessWidget {
  const _RailNav({
    required this.destinations,
    required this.currentIndex,
    required this.onSelect,
    required this.extended,
  });

  final List<({IconData icon, IconData selected, String label})> destinations;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: AppColors.surface,
      child: SizedBox(
        width: extended
            ? AdaptiveLayout.railExtendedWidth
            : AdaptiveLayout.railCollapsedWidth,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
                child: Row(
                  mainAxisAlignment: extended
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    const ActiveProfileAvatar(radius: 13),
                    if (extended) ...[
                      const SizedBox(width: 8),
                      Text(
                        'JAVP',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (var index = 0; index < destinations.length; index++)
                      _DesktopRailItem(
                        icon: destinations[index].icon,
                        selectedIcon: destinations[index].selected,
                        label: destinations[index].label == l10n.navLive
                            ? l10n.navTv
                            : destinations[index].label,
                        selected: currentIndex == index,
                        extended: extended,
                        onTap: () => onSelect(index),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: AppColors.border),
                    ),
                    _DesktopRailItem(
                      icon: Icons.search_rounded,
                      selectedIcon: Icons.search_rounded,
                      label: l10n.search,
                      selected: false,
                      extended: extended,
                      onTap: () => context.push('/search'),
                    ),
                    _DesktopRailItem(
                      icon: Icons.bookmark_outline_rounded,
                      selectedIcon: Icons.bookmark_rounded,
                      label: l10n.myList,
                      selected: false,
                      extended: extended,
                      onTap: () => context.push('/mylist'),
                    ),
                    _DesktopRailItem(
                      icon: Icons.playlist_add_rounded,
                      selectedIcon: Icons.playlist_add_rounded,
                      label: l10n.sources,
                      selected: false,
                      extended: extended,
                      onTap: () => context.push('/sources'),
                    ),
                    _DesktopRailItem(
                      icon: Icons.history_rounded,
                      selectedIcon: Icons.history_rounded,
                      label: l10n.history,
                      selected: false,
                      extended: extended,
                      onTap: () => context.push('/history'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopRailItem extends StatelessWidget {
  const _DesktopRailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final content = extended
        ? Row(
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 22,
                color: selected ? AppColors.accent : AppColors.textMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.text : AppColors.textMuted,
                  ),
                ),
              ),
            ],
          )
        : Column(
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 22,
                color: selected ? AppColors.accent : AppColors.textMuted,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ],
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: extended ? '' : label,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            hoverColor: AppColors.surfaceHigh,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.symmetric(
                horizontal: extended ? 12 : 6,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: selected ? AppColors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _TvShell extends StatefulWidget {
  const _TvShell({
    required this.navigationShell,
    required this.destinations,
    required this.currentVisibleIndex,
    required this.onSelect,
  });

  final StatefulNavigationShell navigationShell;
  final List<({IconData icon, IconData selected, String label})> destinations;
  final int currentVisibleIndex;
  final ValueChanged<int> onSelect;

  @override
  State<_TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<_TvShell> {
  /// Extra rail entries: My List (primary, before Settings), Search, Sources.
  static const _extraRailCount = 3;

  /// Branch destinations use indices `0 .. destinations.length-1`.
  /// Then: My List, Search, Sources.
  static const _myListExtraOffset = 0;
  static const _searchExtraOffset = 1;
  static const _sourcesExtraOffset = 2;

  final _railScope = FocusScopeNode(debugLabel: 'tvRail');
  final _contentScope = FocusScopeNode(debugLabel: 'tvContent');
  final _railScroll = ScrollController();
  final _miniPlayerFocus = FocusNode(
    debugLabel: 'tvMiniPlayer',
    skipTraversal: true,
    canRequestFocus: false,
  );
  final _nowPlayingFocus = FocusNode(debugLabel: 'tvNowPlaying');
  late List<FocusNode> _railNodes;

  /// After a rail tab select, content autofocus (first SkipLayout unskip) can
  /// steal focus one or more frames later. Pin reclaim until settled / Right.
  bool _railFocusPinned = false;
  bool _reassertingRailFocus = false;
  VoidCallback? _railFocusPinListener;

  int get _railCount => widget.destinations.length + _extraRailCount;

  int get _myListRailIndex => widget.destinations.length + _myListExtraOffset;
  int get _searchRailIndex => widget.destinations.length + _searchExtraOffset;
  int get _sourcesRailIndex => widget.destinations.length + _sourcesExtraOffset;

  @override
  void initState() {
    super.initState();
    _railNodes = List<FocusNode>.generate(
      _railCount,
      (i) => FocusNode(debugLabel: 'tvRailItem$i'),
    );
  }

  @override
  void didUpdateWidget(covariant _TvShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destinations.length == widget.destinations.length) return;
    for (final node in _railNodes) {
      node.dispose();
    }
    _railNodes = List<FocusNode>.generate(
      _railCount,
      (i) => FocusNode(debugLabel: 'tvRailItem$i'),
    );
  }

  @override
  void dispose() {
    _unpinRailFocus();
    for (final node in _railNodes) {
      node.dispose();
    }
    _railScroll.dispose();
    _railScope.dispose();
    _contentScope.dispose();
    _miniPlayerFocus.dispose();
    _nowPlayingFocus.dispose();
    super.dispose();
  }

  void _focusPreferredRailItem() {
    final index = widget.currentVisibleIndex.clamp(
      0,
      widget.destinations.length - 1,
    );
    final node = _railNodes[index];
    if (node.canRequestFocus) {
      node.requestFocus();
      return;
    }
    _railScope.requestFocus();
  }

  void _unpinRailFocus() {
    _railFocusPinned = false;
    final listener = _railFocusPinListener;
    _railFocusPinListener = null;
    if (listener != null) {
      FocusManager.instance.removeListener(listener);
    }
  }

  /// Keep focus on the selected rail item after [goBranch] while the newly
  /// active tab mounts. Content tiles must not use autofocus — that caused
  /// Home “Watch live” to flash focus then lose it when this pin reasserted.
  void _pinRailFocusAfterDestinationChange() {
    _unpinRailFocus();
    _railFocusPinned = true;

    void reassert() {
      if (!mounted || !_railFocusPinned || _reassertingRailFocus) return;
      final primary = FocusManager.instance.primaryFocus;
      final preferredIndex = widget.currentVisibleIndex.clamp(
        0,
        widget.destinations.length - 1,
      );
      final preferred = _railNodes[preferredIndex];
      if (preferred.hasFocus) return;
      if (primary != null &&
          _scopeContains(_railScope, primary) &&
          !preferred.canRequestFocus) {
        return;
      }
      _reassertingRailFocus = true;
      try {
        _clearStaleContentFocus();
        _focusPreferredRailItem();
      } finally {
        _reassertingRailFocus = false;
      }
    }

    void listener() {
      if (!_railFocusPinned || _reassertingRailFocus) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && _scopeContains(_railScope, primary)) return;
      reassert();
    }

    _railFocusPinListener = listener;
    FocusManager.instance.addListener(listener);

    void scheduleReassert(int framesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_railFocusPinned) return;
        reassert();
        if (framesLeft > 1) {
          scheduleReassert(framesLeft - 1);
          return;
        }
        // Autofocus can land slightly after the second layout frame.
        Future<void>.delayed(const Duration(milliseconds: 64), () {
          if (!mounted) return;
          reassert();
          _unpinRailFocus();
        });
      });
    }

    scheduleReassert(3);
  }

  /// Drop focus that still points at an inactive SkipLayout shell branch
  /// (tabs stay mounted for scroll/state).
  void _clearStaleContentFocus() {
    final child = _contentScope.focusedChild;
    if (child == null) return;
    if (_isOnActiveShellBranch(child)) return;
    child.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
  }

  void _onSelectDestination(int index) {
    widget.onSelect(index);
    // Hold rail focus through the first-tab autofocus race; clear on → content.
    _pinRailFocusAfterDestinationChange();
  }

  /// Enter content from the rail: prefer a *visible, active-tab* target near
  /// the rail item (never a skipped sibling branch).
  void _enterContentFromRail() {
    _unpinRailFocus();
    _clearStaleContentFocus();
    final railFocus = FocusManager.instance.primaryFocus;
    final preferY = _globalCenterY(railFocus);

    // focusedChild is often the nested Navigator scope, not a button.
    final previous = tvLeafContentFocus(_contentScope.focusedChild);
    if (previous != null &&
        previous.canRequestFocus &&
        _isUsableContentFocus(previous) &&
        !_isMiniPlayerFocus(previous)) {
      previous.requestFocus();
      _ensureNodeVisible(previous);
      return;
    }

    final best = _findBestContentEntry(preferY: preferY);
    if (best != null) {
      best.requestFocus();
      _ensureNodeVisible(best);
      return;
    }

    // Last resort: traversal order inside the content scope.
    final policy = ReadingOrderTraversalPolicy();
    final first = policy.findFirstFocus(_contentScope);
    if (first != null &&
        _scopeContains(_contentScope, first) &&
        _isUsableContentFocus(first)) {
      first.requestFocus();
      _ensureNodeVisible(first);
      return;
    }
    _contentScope.nextFocus();
  }

  double? _globalCenterY(FocusNode? node) {
    final box = node?.context?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft.dy + box.size.height / 2;
  }

  Rect? _globalRect(FocusNode node) {
    final box = node.context?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  Rect? _contentViewportGlobal() {
    final box = _contentScope.context?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Shell tabs use [SkipLayout] + [ShellVisibility]; inactive branches keep
  /// navigators mounted but are not laid out / hit-tested, so geometry does
  /// not treat off-tab trees as on-screen.
  bool _isOnActiveShellBranch(FocusNode node) {
    final ctx = node.context;
    if (ctx == null) return false;
    final skipped = ctx.findAncestorWidgetOfExactType<SkipLayout>();
    if (skipped != null && skipped.skip) return false;
    final visibility = ctx.getInheritedWidgetOfExactType<ShellVisibility>();
    if (visibility != null && !visibility.active) return false;
    return true;
  }

  bool _isMiniPlayerFocus(FocusNode node) {
    final ctx = node.context;
    if (ctx == null) return false;
    return ctx.findAncestorWidgetOfExactType<MiniPlayerBar>() != null;
  }

  bool _isUsableContentFocus(FocusNode node) {
    if (node is FocusScopeNode) return false;
    if (!node.canRequestFocus || node.skipTraversal) return false;
    if (!_isOnActiveShellBranch(node)) return false;
    final content = _contentViewportGlobal();
    final rect = _globalRect(node);
    if (content == null || rect == null) return false;
    // Scrollables / pane hosts fill the content rect. Focusing them shows
    // no ring, so the next Right is needed to reach Watch live / a tile.
    if (rect.width >= content.width * 0.85 &&
        rect.height >= content.height * 0.5) {
      return false;
    }
    final visible = content.intersect(rect);
    return visible.width >= 24 && visible.height >= 24;
  }

  /// True when [node] is already fully inside the content pane (with a small
  /// pad so focus rings / scale don't count as "off-screen").
  bool _isFullyVisibleInContent(FocusNode node) {
    final content = _contentViewportGlobal();
    final rect = _globalRect(node);
    if (content == null || rect == null) return false;
    const pad = 8.0;
    final safe = content.deflate(pad);
    return safe.left <= rect.left &&
        safe.top <= rect.top &&
        safe.right >= rect.right &&
        safe.bottom >= rect.bottom;
  }

  void _ensureNodeVisible(FocusNode node) {
    final ctx = node.context;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctx.mounted) return;
      // Rail → Watch Live (and other already-on-screen CTAs) must not yank
      // the Home SliverAppBar away via explicit alignment scrolling.
      if (_isFullyVisibleInContent(node)) return;
      Scrollable.ensureVisible(
        ctx,
        // Only scroll the minimum needed to reveal off-screen targets
        // (e.g. restoring a lower shelf focus after leaving the rail).
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// Leftmost visible focusable in the *active* content tab, biased toward [preferY].
  FocusNode? _findBestContentEntry({double? preferY}) {
    final content = _contentViewportGlobal();
    if (content == null) return null;

    FocusNode? best;
    var bestScore = double.infinity;

    void visit(FocusNode node) {
      for (final child in node.children) {
        visit(child);
      }
      if (identical(node, _contentScope)) return;
      if (!node.canRequestFocus || node.skipTraversal) return;
      if (node is FocusScopeNode) return;
      if (!_isUsableContentFocus(node)) return;
      if (_isMiniPlayerFocus(node)) return;

      final rect = _globalRect(node)!;
      final dx = (rect.left - content.left).clamp(0.0, 400.0);
      final dy = preferY == null
          ? (rect.top - content.top).abs()
          : (rect.center.dy - preferY).abs();
      // Prefer left-edge posters/cards, then match the rail item's band.
      final score = dx * 3.0 + dy;
      if (score < bestScore) {
        bestScore = score;
        best = node;
      }
    }

    visit(_contentScope);
    return best;
  }

  bool _scopeContains(FocusScopeNode scope, FocusNode node) {
    FocusNode? current = node;
    while (current != null) {
      if (identical(current, scope)) return true;
      current = current.parent;
    }
    return false;
  }

  /// True when D-pad ← still has a usable target *inside* the content pane.
  ///
  /// Prefer this over a left-edge pixel heuristic: AppBar actions and
  /// right-side controls sit far from x=0, so a 56px edge check trapped focus
  /// on those menu buttons and blocked escape to the rail. Prefer this over
  /// [FocusTraversalPolicy.findFirstFocusInDirection] too — that walks the
  /// whole focus tree and would see the rail itself as a left candidate.
  bool _canMoveLeftWithinContent(FocusNode primary) {
    final primaryRect = _globalRect(primary);
    if (primaryRect == null) return false;

    var found = false;
    void visit(FocusNode node) {
      if (found) return;
      for (final child in node.children) {
        visit(child);
        if (found) return;
      }
      if (identical(node, _contentScope) || identical(node, primary)) return;
      if (!node.canRequestFocus || node.skipTraversal) return;
      if (node is FocusScopeNode) return;
      if (!_isUsableContentFocus(node)) return;

      final rect = _globalRect(node);
      if (rect == null) return;
      // Must sit clearly to the left of the focused control.
      if (rect.right > primaryRect.left + 4) return;
      // Same vertical band (row of AppBar actions / shelf tiles).
      final dy = (rect.center.dy - primaryRect.center.dy).abs();
      if (dy > 72) return;
      found = true;
    }

    visit(_contentScope);
    return found;
  }

  void _restoreNowPlaying() {
    final playback = context.read<PlaybackProvider>();
    pushMiniPlayerRestore(GoRouter.of(context), playback);
  }

  void _stopMiniPlayer() {
    unawaited(context.read<PlaybackProvider>().stop());
    if (_railNodes.isNotEmpty) _railNodes.first.requestFocus();
  }

  KeyEventResult _onContentKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || !_scopeContains(_contentScope, primary)) {
      return KeyEventResult.ignored;
    }
    if (_canMoveLeftWithinContent(primary)) {
      return KeyEventResult.ignored;
    }
    _focusPreferredRailItem();
    return KeyEventResult.handled;
  }

  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_nowPlayingFocus.hasFocus) {
        return KeyEventResult.handled;
      }
      if (_railNodes.isEmpty || !_railNodes.first.hasFocus) {
        return KeyEventResult.ignored;
      }
      if (!_railScroll.hasClients || _railScroll.offset <= 0) {
        return KeyEventResult.ignored;
      }
      tvRevealScrollTop(_railScroll);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || !_scopeContains(_railScope, primary)) {
      return KeyEventResult.ignored;
    }
    _enterContentFromRail();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final destinations = widget.destinations;
    // Title-safe padding so rail labels / focus rings are not cropped by TV
    // overscan. Keep left overscan on the rail only — content already sits
    // inward of the rail.
    const overscan = AppLayout.tvOverscan;
    final minimized = context.select<PlaybackProvider, bool>(
      (p) => p.isMinimized,
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: false,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
          overscan,
          overscan,
          overscan,
          overscan,
        ),
        child: Row(
          children: [
            FocusScope(
              node: _railScope,
              onKeyEvent: _onRailKey,
              child: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: Material(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: 112,
                    child: ListView(
                      controller: _railScroll,
                      // Keep Home mounted when the rail is scrolled to Sources
                      // so first-item focus can jump back to the JAVP header.
                      cacheExtent: 2000,
                      padding: const EdgeInsets.fromLTRB(6, 16, 6, 12),
                      children: [
                        Text(
                          'JAVP',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                        ),
                        const SizedBox(height: 12),
                        if (minimized) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: TvFocusable(
                              focusNode: _nowPlayingFocus,
                              onSelect: _restoreNowPlaying,
                              onLongSelect: _stopMiniPlayer,
                              borderRadius: 12,
                              child: _TvRailItem(
                                icon: Icons.play_circle_outline_rounded,
                                selectedIcon: Icons.play_circle_rounded,
                                label: context.l10n.nowPlaying,
                                selected: true,
                              ),
                            ),
                          ),
                        ],
                        // Primary destinations: shell branches + My List before
                        // Settings so bookmarks stay above the fold (no scroll).
                        for (
                          var index = 0;
                          index < destinations.length;
                          index++
                        ) ...[
                          if (index == destinations.length - 1)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: TvFocusable(
                                focusNode: _railNodes[_myListRailIndex],
                                onSelect: () => context.push('/mylist'),
                                borderRadius: 12,
                                child: _TvRailItem(
                                  icon: Icons.bookmark_outline_rounded,
                                  selectedIcon: Icons.bookmark_rounded,
                                  label: context.l10n.myList,
                                  selected: false,
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: TvFocusable(
                              focusNode: _railNodes[index],
                              autofocus:
                                  index == 0 && widget.currentVisibleIndex == 0,
                              onFocusChange: index == 0
                                  ? (focused) {
                                      if (focused) {
                                        tvRevealScrollTop(_railScroll);
                                      }
                                    }
                                  : null,
                              onSelect: () => _onSelectDestination(index),
                              borderRadius: 12,
                              child: _TvRailItem(
                                icon: destinations[index].icon,
                                selectedIcon: destinations[index].selected,
                                label: destinations[index].label,
                                selected: widget.currentVisibleIndex == index,
                              ),
                            ),
                          ),
                        ],
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Divider(height: 1, color: AppColors.border),
                        ),
                        TvFocusable(
                          focusNode: _railNodes[_searchRailIndex],
                          onSelect: () => context.push('/search'),
                          borderRadius: 12,
                          child: _TvRailItem(
                            icon: Icons.search_rounded,
                            selectedIcon: Icons.search_rounded,
                            label: context.l10n.search,
                            selected: false,
                          ),
                        ),
                        const SizedBox(height: 4),
                        TvFocusable(
                          focusNode: _railNodes[_sourcesRailIndex],
                          onSelect: () => context.push('/sources'),
                          borderRadius: 12,
                          child: _TvRailItem(
                            icon: Icons.qr_code_2_rounded,
                            selectedIcon: Icons.qr_code_2_rounded,
                            label: context.l10n.sources,
                            selected: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FocusScope(
                node: _contentScope,
                onKeyEvent: _onContentKey,
                child: FocusTraversalGroup(
                  policy: tvReadingOrderTraversalPolicy(),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Overlay.wrap(
                          clipBehavior: Clip.hardEdge,
                          child: AppBackdrop(child: widget.navigationShell),
                        ),
                      ),
                      Positioned.fill(
                        child: TvCornerMiniPlayer(
                          inset: 8,
                          child: MiniPlayerBar(
                            autofocusExpand: false,
                            expandFocusNode: _miniPlayerFocus,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvRailItem extends StatelessWidget {
  const _TvRailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      decoration: BoxDecoration(
        color: selected ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Icon(
            selected ? selectedIcon : icon,
            size: 24,
            color: selected ? AppColors.accent : AppColors.textMuted,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppColors.text : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Global TV remote shortcuts + directional focus mode (and desktop hotkeys).
class TvShellShortcuts extends StatefulWidget {
  const TvShellShortcuts({super.key, required this.child});

  final Widget child;

  @override
  State<TvShellShortcuts> createState() => _TvShellShortcutsState();
}

class _TvShellShortcutsState extends State<TvShellShortcuts> {
  @override
  void initState() {
    super.initState();
    if (TvPlatform.isAndroidTv) {
      HardwareKeyboard.instance.addHandler(_ensureFocusOnRemote);
      tvConsumeLongSelect = _consumeLongSelectForMiniPlayer;
      tvHoldOkClosesMiniPlayer = _miniPlayerIsOpen;
    }
  }

  @override
  void dispose() {
    if (TvPlatform.isAndroidTv) {
      HardwareKeyboard.instance.removeHandler(_ensureFocusOnRemote);
      if (identical(tvConsumeLongSelect, _consumeLongSelectForMiniPlayer)) {
        tvConsumeLongSelect = null;
      }
      if (identical(tvHoldOkClosesMiniPlayer, _miniPlayerIsOpen)) {
        tvHoldOkClosesMiniPlayer = null;
      }
    }
    super.dispose();
  }

  bool _miniPlayerIsOpen() {
    if (!mounted) return false;
    return context.read<PlaybackProvider>().isMinimized;
  }

  bool _consumeLongSelectForMiniPlayer() {
    if (!_miniPlayerIsOpen()) return false;
    unawaited(context.read<PlaybackProvider>().stop());
    return true;
  }

  /// After touch, Flutter often has no primary focus — Extended Controls then
  /// appear "dead". Re-seed focus on the first remote key.
  bool _ensureFocusOnRemote(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final isRemote =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!isRemote) return false;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.context != null) return false;
    final scope = FocusScope.of(context);
    if (!scope.hasFocus) {
      scope.requestFocus();
    }
    scope.nextFocus();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvPlatform.isAndroidTv) return widget.child;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(navigationMode: NavigationMode.directional),
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select):
              const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.enter):
              const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter):
              const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.gameButtonA):
              const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              const _OpenSearchIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
              onInvoke: (_) {
                context.push('/search');
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}
