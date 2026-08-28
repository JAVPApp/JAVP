import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Left-column entry of the Live browse overlay.
enum TvLiveBrowseSectionKind { forYou, favorites, recents, all, category }

@immutable
class TvLiveBrowseSection {
  const TvLiveBrowseSection({
    required this.id,
    required this.label,
    required this.kind,
    this.category,
    this.pinned = false,
  });

  static const forYouId = 'for_you';
  static const favoritesId = 'favorites';
  static const recentsId = 'recents';
  static const allId = 'all';

  /// Stable id for a provider category row.
  static String categoryIdFor(IptvCategory category) => 'cat:${category.id}';

  final String id;
  final String label;
  final TvLiveBrowseSectionKind kind;
  final IptvCategory? category;

  /// Starred (bookmarked) category — sorted to the top by the caller.
  final bool pinned;
}

/// Geometry for the Big Picture–style left overlay over fullscreen video.
@immutable
class TvLiveBrowseLayout {
  const TvLiveBrowseLayout._({
    required this.sectionWidth,
    required this.channelWidth,
    required this.detailsWidth,
    required this.detailsExpanded,
  });

  static const outerPad = 20.0;
  static const gap = 10.0;
  static const columnLabelHeight = 22.0;
  static const labelGap = 6.0;

  final double sectionWidth;
  final double channelWidth;
  final double detailsWidth;
  final bool detailsExpanded;

  /// Total width occupied by the overlay panels (padding included).
  double get overlayWidth => detailsExpanded
      ? outerPad + channelWidth + gap + detailsWidth + outerPad
      : outerPad +
            sectionWidth +
            gap +
            channelWidth +
            gap +
            detailsWidth +
            outerPad;

  factory TvLiveBrowseLayout.of(Size size, {bool detailsExpanded = false}) {
    final sectionWidth = (size.width * 0.16).clamp(132.0, 280.0);
    final channelWidth = (size.width * 0.28).clamp(220.0, 520.0);
    final compactDetails = math.min(size.width * 0.26, 420.0).clamp(180.0, 420.0);
    // Categories slide away; their width is given to the EPG column.
    final expandedDetails = (sectionWidth + gap + compactDetails).clamp(
      280.0,
      720.0,
    );
    return TvLiveBrowseLayout._(
      sectionWidth: sectionWidth,
      channelWidth: channelWidth,
      detailsWidth: detailsExpanded ? expandedDetails : compactDetails,
      detailsExpanded: detailsExpanded,
    );
  }
}

/// What OK does on an EPG row in the browse details pane.
enum TvLiveBrowseProgramAction { watchLive, playCatchup, none }

TvLiveBrowseProgramAction tvLiveBrowseProgramAction({
  required DateTime now,
  required EpgProgram program,
  required bool channelSupportsCatchup,
}) {
  if (program.isAiringAt(now)) return TvLiveBrowseProgramAction.watchLive;
  final isPast = !program.start.isAfter(now);
  if (isPast && (channelSupportsCatchup || program.hasArchive)) {
    return TvLiveBrowseProgramAction.playCatchup;
  }
  return TvLiveBrowseProgramAction.none;
}

/// How many past EPG rows to keep when the details pane is open.
int tvLiveBrowseEpgBeforeCount({
  required bool supportsCatchup,
  required int catchupDays,
}) {
  if (!supportsCatchup) return 8;
  return (catchupDays.clamp(1, 14) * 6).clamp(12, 48).toInt();
}

/// Upcoming EPG rows beside “now”.
const tvLiveBrowseEpgAfterCount = 6;

/// Categories · channels · programme details as a couch overlay.
///
/// The host keeps video fullscreen underneath; this widget is a translucent
/// left stack so Back / ← pops layers without a second “app” surface.
class TvLiveBrowsePanes extends StatefulWidget {
  const TvLiveBrowsePanes({
    super.key,
    required this.sections,
    required this.selectedSectionId,
    required this.channels,
    required this.loadingChannels,
    required this.currentChannel,
    required this.titleFor,
    required this.nowFor,
    required this.nextFor,
    required this.programsFor,
    required this.isFavorite,
    required this.onSelectSection,
    required this.onFocusChannel,
    required this.onPlayChannel,
    required this.onChannelActions,
    required this.onSectionActions,
    required this.onVisibleChannels,
    required this.onClose,
    this.onPlayProgram,
    this.onNearEnd,
    this.onSearchChanged,
    this.searchQuery = '',
    this.focusSectionsFirst = false,
    this.emptyMessage,
  });

  final List<TvLiveBrowseSection> sections;
  final String selectedSectionId;
  final List<MediaItem> channels;
  final bool loadingChannels;

  /// Channel currently feeding the fullscreen session under the overlay.
  final MediaItem? currentChannel;
  final String Function(MediaItem channel) titleFor;
  final EpgProgram? Function(MediaItem channel) nowFor;
  final EpgProgram? Function(MediaItem channel) nextFor;
  final List<EpgProgram> Function(MediaItem channel) programsFor;
  final bool Function(MediaItem channel) isFavorite;
  final ValueChanged<TvLiveBrowseSection> onSelectSection;

  /// Focused channel — host prefetches guide; retune only happens on OK.
  final ValueChanged<MediaItem> onFocusChannel;

  /// OK on a channel: commit that channel and dismiss the overlay.
  final ValueChanged<MediaItem> onPlayChannel;

  /// OK on a past EPG row when catchup exists.
  final void Function(MediaItem channel, EpgProgram program)? onPlayProgram;
  final ValueChanged<MediaItem> onChannelActions;
  final ValueChanged<TvLiveBrowseSection> onSectionActions;

  /// Rows on screen, for batched now/next guide prefetch.
  final ValueChanged<List<MediaItem>> onVisibleChannels;

  /// Near the bottom of a paged All/category list.
  final VoidCallback? onNearEnd;

  /// Live search within All / category sections (null = search disabled).
  final ValueChanged<String>? onSearchChanged;
  final String searchQuery;

  /// Left from the categories column leaves browse and goes back to fullscreen.
  final VoidCallback onClose;
  final bool focusSectionsFirst;
  final String? emptyMessage;

  @override
  State<TvLiveBrowsePanes> createState() => _TvLiveBrowsePanesState();
}

class _TvLiveBrowsePanesState extends State<TvLiveBrowsePanes> {
  static const _rowExtent = 68.0;
  static const _sectionExtent = 44.0;
  static const _programExtent = 64.0;

  final _sectionsScope = FocusScopeNode(debugLabel: 'tvBrowseSections');
  final _channelsScope = FocusScopeNode(debugLabel: 'tvBrowseChannels');
  final _detailsScope = FocusScopeNode(debugLabel: 'tvBrowseDetails');
  final _watchNode = FocusNode(debugLabel: 'tvBrowseWatch');
  final _searchFocus = FocusNode(debugLabel: 'tvBrowseSearch');
  final _searchChipNode = FocusNode(debugLabel: 'tvBrowseSearchChip');
  final _channelScroll = ScrollController();
  final _sectionScroll = ScrollController();
  final _programScroll = ScrollController();
  final _searchController = TextEditingController();
  Timer? _prefetchDebounce;
  bool _nearEndNotified = false;
  MediaItem? _focusedChannel;

  /// Right from channels: categories are off-screen, EPG list is focused.
  bool _detailsFocused = false;

  /// When true, the search [TextField] owns focus (IME open).
  bool _searchEditing = false;

  /// Re-notify [onFocusChannel] even when restoring the same row.
  bool _forceFocusNotify = false;

  /// Bumped so the selected channel/section remounts with [autofocus] when
  /// returning from the other column.
  int _channelFocusEpoch = 0;
  int _sectionFocusEpoch = 0;
  int _programFocusEpoch = 0;

  @override
  void initState() {
    super.initState();
    _searchController.text = widget.searchQuery;
    _channelScroll.addListener(_onChannelScroll);
    _searchFocus.addListener(_onSearchFocusChanged);
    _searchFocus.onKeyEvent = _onSearchFieldKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.focusSectionsFirst) {
        _focusSectionsColumn();
      } else {
        _focusChannelsColumn();
      }
      _emitVisible();
    });
  }

  @override
  void didUpdateWidget(covariant TvLiveBrowsePanes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSectionId != widget.selectedSectionId) {
      _focusedChannel = null;
      _nearEndNotified = false;
      _detailsFocused = false;
      _exitSearchEditing(requestChannelFocus: false);
      if (_channelScroll.hasClients) _channelScroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSectionVisible();
      });
    }
    if (oldWidget.searchQuery != widget.searchQuery &&
        _searchController.text != widget.searchQuery) {
      _searchController.text = widget.searchQuery;
    }
    if (oldWidget.channels != widget.channels) {
      _nearEndNotified = false;
      _schedulePrefetch();
    }
    if (_detailsFocused) {
      final channel = _focusedChannel ?? widget.currentChannel;
      if (channel != null) {
        final wasEmpty = oldWidget.programsFor(channel).isEmpty;
        final hasRows = widget.programsFor(channel).isNotEmpty;
        if (wasEmpty && hasRows) {
          _programFocusEpoch++;
        }
      }
    }
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
    _channelScroll.removeListener(_onChannelScroll);
    _channelScroll.dispose();
    _sectionScroll.dispose();
    _programScroll.dispose();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.onKeyEvent = null;
    _searchFocus.dispose();
    _searchChipNode.dispose();
    _searchController.dispose();
    _sectionsScope.dispose();
    _channelsScope.dispose();
    _detailsScope.dispose();
    _watchNode.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocus.hasFocus) {
      if (!_searchEditing) setState(() => _searchEditing = true);
      return;
    }
    // Leaving the field without remounting — drop editing chrome so D-pad
    // lands on channel rows again (not a dead TextField caret).
    if (_searchEditing) {
      setState(() => _searchEditing = false);
    }
  }

  KeyEventResult _onSearchFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.arrowLeft) {
      final toSections = key == LogicalKeyboardKey.arrowLeft;
      _exitSearchEditing(requestChannelFocus: !toSections);
      if (toSections) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusSectionsColumn();
        });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _exitSearchEditing({required bool requestChannelFocus}) {
    if (!_searchEditing && !_searchFocus.hasFocus) {
      if (requestChannelFocus) _focusChannelsColumn();
      return;
    }
    _searchFocus.unfocus();
    setState(() => _searchEditing = false);
    if (requestChannelFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusChannelsColumn();
      });
    }
  }

  void _beginSearchEditing() {
    setState(() => _searchEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _scrollToIndex(ScrollController controller, int index, double extent) {
    if (!controller.hasClients) return;
    final max = controller.position.maxScrollExtent;
    final target = (index * extent).clamp(0.0, max);
    controller.jumpTo(target);
  }

  void _ensureChannelVisible() {
    if (widget.channels.isEmpty) return;
    _scrollToIndex(_channelScroll, _autofocusIndex, _rowExtent);
  }

  void _ensureSectionVisible() {
    final index = widget.sections.indexWhere(
      (s) => s.id == widget.selectedSectionId,
    );
    if (index < 0) return;
    _scrollToIndex(_sectionScroll, index, _sectionExtent);
  }

  void _focusChannelsColumn() {
    _exitSearchEditing(requestChannelFocus: false);
    if (_detailsFocused) {
      _detailsFocused = false;
    }
    if (widget.channels.isEmpty) {
      setState(() {});
      _channelsScope.requestFocus();
      return;
    }
    // Remount the focused/playing row with autofocus — do not requestFocus on
    // the scope (that lands on the search chip first). Keep `_focusedChannel`
    // so `_autofocusIndex` restores the row the user left on.
    _forceFocusNotify = true;
    setState(() => _channelFocusEpoch++);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureChannelVisible();
      _emitVisible();
    });
  }

  void _focusSectionsColumn() {
    _exitSearchEditing(requestChannelFocus: false);
    if (_detailsFocused) {
      _detailsFocused = false;
    }
    setState(() => _sectionFocusEpoch++);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureSectionVisible();
    });
  }

  void _focusDetailsPane() {
    if (widget.channels.isEmpty) return;
    _exitSearchEditing(requestChannelFocus: false);
    setState(() {
      _detailsFocused = true;
      _programFocusEpoch++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_detailsFocused) return;
      final channel = _focusedChannel ?? widget.currentChannel;
      if (channel == null) return;
      final programs = widget.programsFor(channel);
      if (programs.isEmpty) {
        if (_watchNode.canRequestFocus) _watchNode.requestFocus();
        return;
      }
      final now = DateTime.now();
      var index = programs.indexWhere((p) => p.isAiringAt(now));
      if (index < 0) index = 0;
      _scrollToIndex(_programScroll, index, _programExtent);
    });
  }

  void _onChannelScroll() {
    _schedulePrefetch();
    final onNearEnd = widget.onNearEnd;
    if (onNearEnd == null || !_channelScroll.hasClients) return;
    final pos = _channelScroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      if (_nearEndNotified) return;
      _nearEndNotified = true;
      onNearEnd();
    }
  }

  void _schedulePrefetch() {
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 120), _emitVisible);
  }

  void _emitVisible() {
    if (!mounted || widget.channels.isEmpty) return;
    final offset = _channelScroll.hasClients ? _channelScroll.offset : 0.0;
    final viewport = _channelScroll.hasClients
        ? _channelScroll.position.viewportDimension
        : 720.0;
    final first = (offset / _rowExtent).floor().clamp(
      0,
      widget.channels.length,
    );
    final last = ((offset + viewport) / _rowExtent + 4).ceil().clamp(
      0,
      widget.channels.length,
    );
    if (last <= first) return;
    widget.onVisibleChannels(widget.channels.sublist(first, last));
  }

  bool _sameChannel(MediaItem? a, MediaItem? b) {
    if (a == null || b == null) return false;
    if (a.id == b.id) return true;
    return a.streamId != null &&
        a.streamId == b.streamId &&
        a.sourceId == b.sourceId;
  }

  int get _autofocusIndex {
    final current = _focusedChannel ?? widget.currentChannel;
    if (current != null) {
      final index = widget.channels.indexWhere((c) => _sameChannel(c, current));
      if (index >= 0) return index;
    }
    return 0;
  }

  void _onChannelFocused(MediaItem channel) {
    if (_sameChannel(_focusedChannel, channel) && !_forceFocusNotify) return;
    _forceFocusNotify = false;
    setState(() => _focusedChannel = channel);
    widget.onFocusChannel(channel);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (isTvBackKey(key)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_searchEditing || _searchFocus.hasFocus || _searchChipNode.hasFocus) {
        _exitSearchEditing(requestChannelFocus: true);
        return KeyEventResult.handled;
      }
      if (_detailsFocused) {
        _focusChannelsColumn();
        return KeyEventResult.handled;
      }
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_searchEditing || _searchFocus.hasFocus || _searchChipNode.hasFocus) {
        _exitSearchEditing(requestChannelFocus: false);
        _focusSectionsColumn();
        return KeyEventResult.handled;
      }
      if (_detailsFocused || _detailsScope.hasFocus || _watchNode.hasFocus) {
        _focusChannelsColumn();
        return KeyEventResult.handled;
      }
      if (_channelsScope.hasFocus) {
        _focusSectionsColumn();
        return KeyEventResult.handled;
      }
      if (_sectionsScope.hasFocus) {
        widget.onClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_sectionsScope.hasFocus) {
        _focusChannelsColumn();
        return KeyEventResult.handled;
      }
      if (_searchEditing || _searchFocus.hasFocus || _searchChipNode.hasFocus) {
        _exitSearchEditing(requestChannelFocus: true);
        return KeyEventResult.handled;
      }
      if (_channelsScope.hasFocus && widget.channels.isNotEmpty) {
        _focusDetailsPane();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_searchEditing || _searchFocus.hasFocus) {
        return KeyEventResult.ignored;
      }
      // ListView traps vertical focus — lift to the search chip from row 0.
      if (widget.onSearchChanged != null &&
          !_searchChipNode.hasFocus &&
          _channelsScope.hasFocus &&
          _autofocusIndex <= 0) {
        _searchChipNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_searchEditing || _searchFocus.hasFocus) {
        _exitSearchEditing(requestChannelFocus: true);
        return KeyEventResult.handled;
      }
      if (_searchChipNode.hasFocus) {
        _focusChannelsColumn();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = TvLiveBrowseLayout.of(
            constraints.biggest,
            detailsExpanded: _detailsFocused,
          );
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                TvLiveBrowseLayout.outerPad,
                TvLiveBrowseLayout.outerPad,
                0,
                TvLiveBrowseLayout.outerPad,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeFocus(
                    excluding: _detailsFocused,
                    child: Visibility(
                      visible: !_detailsFocused,
                      maintainState: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _panel(
                            width: layout.sectionWidth,
                            child: _column(
                              label: context.l10n.categories,
                              child: FocusScope(
                                node: _sectionsScope,
                                child: _buildSections(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: TvLiveBrowseLayout.gap),
                        ],
                      ),
                    ),
                  ),
                  ExcludeFocus(
                    excluding: _detailsFocused,
                    child: _panel(
                      width: layout.channelWidth,
                      child: _column(
                        label: context.l10n.channels,
                        child: FocusScope(
                          node: _channelsScope,
                          child: _buildChannels(context),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: TvLiveBrowseLayout.gap),
                  _panel(
                    width: layout.detailsWidth,
                    child: _column(
                      label: _detailsFocused
                          ? context.l10n.guide
                          : context.l10n.onNow,
                      child: FocusScope(
                        node: _detailsScope,
                        child: _buildDetails(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _panel({required double width, required Widget child}) {
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE60B0D12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: child,
        ),
      ),
    );
  }

  Widget _column({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: TvLiveBrowseLayout.columnLabelHeight,
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
        ),
        const SizedBox(height: TvLiveBrowseLayout.labelGap),
        Expanded(child: child),
      ],
    );
  }

  Widget _buildSections(BuildContext context) {
    final selectedIndex = widget.sections.indexWhere(
      (s) => s.id == widget.selectedSectionId,
    );
    return ListView.builder(
      controller: _sectionScroll,
      itemExtent: _sectionExtent,
      itemCount: widget.sections.length,
      itemBuilder: (context, index) {
        final section = widget.sections[index];
        final selected = section.id == widget.selectedSectionId;
        return TvFocusable(
          key: selected
              ? ValueKey('section-af-$_sectionFocusEpoch')
              : ValueKey('section-${section.id}'),
          autofocus: selected || (selectedIndex < 0 && index == 0),
          borderRadius: 8,
          onSelect: () => widget.onSelectSection(section),
          onLongSelect: () => widget.onSectionActions(section),
          child: Container(
            height: _sectionExtent - 8,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.18)
                  : Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                if (section.pinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.star_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                  ),
                Expanded(
                  child: Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? AppColors.text : AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChannels(BuildContext context) {
    final search = widget.onSearchChanged;
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (search != null) ...[
          _buildSearchField(context, search),
          const SizedBox(height: 8),
        ],
        Expanded(child: _buildChannelList(context)),
      ],
    );
    return list;
  }

  Widget _buildSearchField(
    BuildContext context,
    ValueChanged<String> onChanged,
  ) {
    // OK on the search chip opens the field; D-pad never lands inside a
    // TextField caret unless the user asked — that was freezing the cursor
    // when leaving mid-edit without Enter.
    if (!_searchEditing) {
      return TvFocusable(
        focusNode: _searchChipNode,
        borderRadius: 8,
        onSelect: _beginSearchEditing,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                size: 18,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _searchController.text.trim().isEmpty
                      ? context.l10n.searchChannels
                      : _searchController.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _searchController.text.trim().isEmpty
                        ? AppColors.textMuted
                        : AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_searchController.text.isNotEmpty)
                IconButton(
                  tooltip: context.l10n.clear,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    onChanged('');
                    setState(() {});
                  },
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
            ],
          ),
        ),
      );
    }
    return TextField(
      controller: _searchController,
      focusNode: _searchFocus,
      autofocus: true,
      onChanged: onChanged,
      onSubmitted: (_) => _exitSearchEditing(requestChannelFocus: true),
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: AppColors.text, fontSize: 14),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        isDense: true,
        hintText: context.l10n.searchChannels,
        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 18,
          color: AppColors.textMuted,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        filled: true,
        fillColor: Colors.white10,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildChannelList(BuildContext context) {
    if (widget.loadingChannels && widget.channels.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (widget.channels.isEmpty) {
      return Center(
        child: Text(
          widget.emptyMessage ?? context.l10n.noChannelsInThisList,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    final autofocusIndex = _autofocusIndex;
    return ListView.builder(
      controller: _channelScroll,
      itemExtent: _rowExtent,
      itemCount: widget.channels.length,
      itemBuilder: (context, index) {
        final channel = widget.channels[index];
        final autofocus = index == autofocusIndex;
        return _TvBrowseChannelRow(
          key: autofocus
              ? ValueKey('channel-af-$_channelFocusEpoch')
              : ValueKey('channel-${channel.id}'),
          channel: channel,
          number: index + 1,
          title: widget.titleFor(channel),
          now: widget.nowFor(channel),
          favorite: widget.isFavorite(channel),
          playing: _sameChannel(channel, widget.currentChannel),
          autofocus: autofocus,
          onFocused: () => _onChannelFocused(channel),
          onSelect: () => widget.onPlayChannel(channel),
          onLongSelect: () => widget.onChannelActions(channel),
        );
      },
    );
  }

  Widget _buildDetails(BuildContext context) {
    final channel = _focusedChannel ?? widget.currentChannel;
    if (_detailsFocused) return _buildDetailsGuide(context, channel);
    return _buildDetailsPreview(context, channel);
  }

  Widget _buildDetailsPreview(BuildContext context, MediaItem? channel) {
    final now = channel == null ? null : widget.nowFor(channel);
    final next = channel == null ? null : widget.nextFor(channel);
    final moment = DateTime.now();
    final progress = now?.progressAt(moment);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (channel != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                  color: Colors.white10,
                  child: JavpArt(
                    url: channel.thumbnailUrl,
                    fit: BoxFit.contain,
                    decodeWidth: 480,
                    fallback: const Icon(
                      Icons.live_tv_rounded,
                      size: 36,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            channel == null ? '' : widget.titleFor(channel),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (now != null) ...[
            const SizedBox(height: 6),
            Text(
              '${_hhmm(now.start)}–${_hhmm(now.end)}  ·  ${now.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: Colors.white24,
                  color: AppColors.accent,
                ),
              ),
            ],
          ],
          if (next != null) ...[
            const SizedBox(height: 8),
            Text(
              '${context.l10n.nextProgramLabel} · '
              '${_hhmm(next.start)}  ${next.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
          ],
          if ((now?.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              now!.description!,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ],
          if (now == null && channel != null) ...[
            const SizedBox(height: 6),
            Text(
              context.l10n.noGuideEntriesYet,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailsGuide(BuildContext context, MediaItem? channel) {
    if (channel == null) {
      return Center(
        child: Text(
          context.l10n.noGuideEntriesYet,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    final programs = widget.programsFor(channel);
    final moment = DateTime.now();
    if (programs.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.titleFor(channel),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: Text(
                context.l10n.noGuideEntriesYet,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
          ),
          TvFocusable(
            focusNode: _watchNode,
            autofocus: true,
            borderRadius: 10,
            onSelect: () => widget.onPlayChannel(channel),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      context.l10n.watchFullscreen,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    var autofocusIndex = programs.indexWhere((p) => p.isAiringAt(moment));
    if (autofocusIndex < 0) autofocusIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.titleFor(channel),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            controller: _programScroll,
            itemExtent: _programExtent,
            itemCount: programs.length,
            itemBuilder: (context, index) {
              final program = programs[index];
              final library = context.read<LibraryProvider>();
              final action = tvLiveBrowseProgramAction(
                now: moment,
                program: program,
                channelSupportsCatchup: library.liveSupportsCatchup(channel),
              );
              final autofocus = index == autofocusIndex;
              return _TvBrowseProgramRow(
                key: autofocus
                    ? ValueKey('program-af-$_programFocusEpoch')
                    : ValueKey(
                        'program-${program.start.toUtc().millisecondsSinceEpoch}',
                      ),
                program: program,
                action: action,
                autofocus: autofocus,
                formatTime: _hhmm,
                onSelect: () => _onProgramSelect(channel, program, action),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onProgramSelect(
    MediaItem channel,
    EpgProgram program,
    TvLiveBrowseProgramAction action,
  ) {
    switch (action) {
      case TvLiveBrowseProgramAction.watchLive:
        widget.onPlayChannel(channel);
      case TvLiveBrowseProgramAction.playCatchup:
        widget.onPlayProgram?.call(channel, program);
      case TvLiveBrowseProgramAction.none:
        break;
    }
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _TvBrowseChannelRow extends StatelessWidget {
  const _TvBrowseChannelRow({
    super.key,
    required this.channel,
    required this.number,
    required this.title,
    required this.now,
    required this.favorite,
    required this.playing,
    required this.autofocus,
    required this.onFocused,
    required this.onSelect,
    required this.onLongSelect,
  });

  final MediaItem channel;
  final int number;
  final String title;
  final EpgProgram? now;
  final bool favorite;
  final bool playing;
  final bool autofocus;
  final VoidCallback onFocused;
  final VoidCallback onSelect;
  final VoidCallback onLongSelect;

  @override
  Widget build(BuildContext context) {
    final program = now;
    final progress = program?.progressAt(DateTime.now());
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: 10,
      onSelect: onSelect,
      onLongSelect: onLongSelect,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      child: Container(
        height: _rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: playing
              ? AppColors.accent.withValues(alpha: 0.16)
              : Colors.white10,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '$number',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  // Accent-on-accent is unreadable on the playing row.
                  color: playing ? Colors.white : AppColors.textMuted,
                ),
              ),
            ),
            SizedBox(
              width: 46,
              height: 30,
              child: JavpArt(
                url: channel.thumbnailUrl,
                fit: BoxFit.contain,
                decodeWidth: 120,
                fallback: const Icon(
                  Icons.live_tv_rounded,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (favorite)
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: AppColors.accent,
                        ),
                      if (playing)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.sensors_rounded,
                            size: 14,
                            color: AppColors.live,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    program == null
                        ? (channel.group ?? '')
                        : '${program.title} · '
                              '${_clock(program.start)}–${_clock(program.end)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: playing ? Colors.white70 : AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _rowHeight = 60.0;

  static String _clock(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _TvBrowseProgramRow extends StatelessWidget {
  const _TvBrowseProgramRow({
    super.key,
    required this.program,
    required this.action,
    required this.autofocus,
    required this.formatTime,
    required this.onSelect,
  });

  final EpgProgram program;
  final TvLiveBrowseProgramAction action;
  final bool autofocus;
  final String Function(DateTime dt) formatTime;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = action == TvLiveBrowseProgramAction.none;
    final badge = switch (action) {
      TvLiveBrowseProgramAction.watchLive => l10n.now,
      TvLiveBrowseProgramAction.playCatchup => l10n.catchup,
      TvLiveBrowseProgramAction.none => null,
    };
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: 10,
      onSelect: action == TvLiveBrowseProgramAction.none ? null : onSelect,
      child: Opacity(
        opacity: muted ? 0.55 : 1,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: action == TvLiveBrowseProgramAction.watchLive
                ? AppColors.accent.withValues(alpha: 0.16)
                : Colors.white10,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                switch (action) {
                  TvLiveBrowseProgramAction.watchLive => Icons.sensors_rounded,
                  TvLiveBrowseProgramAction.playCatchup =>
                    Icons.replay_rounded,
                  TvLiveBrowseProgramAction.none => Icons.schedule_rounded,
                },
                size: 18,
                color: action == TvLiveBrowseProgramAction.watchLive
                    ? AppColors.live
                    : AppColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      program.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _programWhen(program, formatTime, badge),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
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

  String _programWhen(
    EpgProgram program,
    String Function(DateTime dt) formatTime,
    String? badge,
  ) {
    final window = '${formatTime(program.start)}–${formatTime(program.end)}';
    final local = program.start.toLocal();
    final now = DateTime.now().toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final date = day == today
        ? window
        : '${local.day.toString().padLeft(2, '0')}/'
              '${local.month.toString().padLeft(2, '0')} $window';
    return badge == null ? date : '$date  ·  $badge';
  }
}
