import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/epg_program_sheet.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Horizontal EPG guide: channel rows × time columns.
class EpgGuideGrid extends StatefulWidget {
  const EpgGuideGrid({
    super.key,
    required this.channels,
    required this.onPlayLive,
    required this.onPlayProgram,
    this.onNearEnd,
    this.autofocusChannelId,
    this.translucent = false,
  });

  final List<MediaItem> channels;
  final ValueChanged<MediaItem> onPlayLive;
  final void Function(MediaItem channel, EpgProgram program) onPlayProgram;

  /// Called when the user scrolls near the bottom (paged live lists).
  final VoidCallback? onNearEnd;

  /// When set (TV), focus lands on this channel row instead of Close / header.
  final String? autofocusChannelId;

  /// Drawn over live playback: header / cells let the video show through.
  final bool translucent;

  @override
  State<EpgGuideGrid> createState() => _EpgGuideGridState();
}

class _EpgGuideGridState extends State<EpgGuideGrid> {
  static const _slot = Duration(minutes: 30);

  /// Minimum lookback when no catchup channels are in the grid.
  static const _minHoursBack = 6;

  /// Cap so the horizontal timeline stays scrollable on phones.
  static const _maxHoursBack = 72;
  static const _hoursForward = 12;

  /// Phone / desktop density — was 64 and only fit ~7–9 rows.
  static const _rowHeight = 44.0;

  /// Android TV keeps a taller D-pad target without going back to 64.
  static const _tvRowHeight = 52.0;
  static const _channelWidth = 112.0;
  static const _headerHeight = 28.0;
  static const _pxPerMinute = 2.4;

  double get _effectiveRowHeight =>
      TvPlatform.isAndroidTv ? _tvRowHeight : _rowHeight;

  /// Remotes need real focus targets; pointer platforms keep plain ink rows.
  bool get _tvFocus => TvPlatform.isAndroidTv;

  Color get _headerColor => widget.translucent
      ? AppColors.surfaceHigh.withValues(alpha: 0.72)
      : AppColors.surfaceHigh;

  /// Scroll a focused row / programme cell into view (both axes).
  void _ensureVisible(BuildContext context) {
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  late DateTime _windowStart;
  late DateTime _windowEnd;
  int _appliedHoursBack = 0;
  final _hScroll = ScrollController();
  final _vChannels = ScrollController();
  final _vTimeline = ScrollController();
  bool _primed = false;
  bool _syncingVertical = false;
  Timer? _prefetchDebounce;
  final Set<String> _prefetchQueued = {};

  @override
  void initState() {
    super.initState();
    _recomputeWindow();
    _vChannels.addListener(_onChannelsScroll);
    _vTimeline.addListener(_onTimelineScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _primeGuides();
      _jumpToLive(animated: false);
    });
  }

  @override
  void didUpdateWidget(covariant EpgGuideGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channels != widget.channels) {
      _primed = false;
      _prefetchQueued.clear();
      _recomputeWindow();
      _primeGuides();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToLive(animated: false);
      });
    }
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
    _vChannels.removeListener(_onChannelsScroll);
    _vTimeline.removeListener(_onTimelineScroll);
    _hScroll.dispose();
    _vChannels.dispose();
    _vTimeline.dispose();
    super.dispose();
  }

  void _onChannelsScroll() {
    _scheduleVisiblePrefetch();
    _maybeNearEnd();
    if (_syncingVertical || !_vTimeline.hasClients) return;
    _syncingVertical = true;
    _vTimeline.jumpTo(
      _vChannels.offset.clamp(0.0, _vTimeline.position.maxScrollExtent),
    );
    _syncingVertical = false;
  }

  void _onTimelineScroll() {
    _maybeNearEnd();
    if (_syncingVertical || !_vChannels.hasClients) return;
    _syncingVertical = true;
    _vChannels.jumpTo(
      _vTimeline.offset.clamp(0.0, _vChannels.position.maxScrollExtent),
    );
    _syncingVertical = false;
  }

  void _maybeNearEnd() {
    final onNearEnd = widget.onNearEnd;
    if (onNearEnd == null || !_vChannels.hasClients) return;
    final pos = _vChannels.position;
    if (pos.pixels > pos.maxScrollExtent - 600) {
      onNearEnd();
    }
  }

  int get _hoursBack {
    LibraryProvider? library;
    try {
      library = context.read<LibraryProvider>();
    } catch (_) {}
    var maxDays = 0;
    for (final c in widget.channels) {
      final family = library?.liveFamilyCatchupDays(c) ?? 0;
      final days = family > c.catchupDays ? family : c.catchupDays;
      if (days > maxDays) maxDays = days;
    }
    if (maxDays <= 0) return _minHoursBack;
    return (maxDays * 24).clamp(_minHoursBack, _maxHoursBack);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hoursBack != _appliedHoursBack) {
      _recomputeWindow();
    }
  }

  void _recomputeWindow() {
    final now = DateTime.now();
    final aligned = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute < 30 ? 0 : 30,
    );
    _windowStart = aligned.subtract(Duration(hours: _hoursBack));
    _windowEnd = aligned.add(const Duration(hours: _hoursForward));
    _appliedHoursBack = _hoursBack;
  }

  Future<void> _primeGuides() async {
    if (_primed || widget.channels.isEmpty || !mounted) return;
    _primed = true;
    _prefetchVisibleGuides();
  }

  void _scheduleVisiblePrefetch() {
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 80), () {
      if (mounted) _prefetchVisibleGuides();
    });
  }

  void _prefetchVisibleGuides() {
    if (widget.channels.isEmpty || !mounted) return;
    final library = context.read<LibraryProvider>();
    final rowHeight = _effectiveRowHeight;
    final offset = _vChannels.hasClients ? _vChannels.offset : 0.0;
    final viewport = _vChannels.hasClients
        ? _vChannels.position.viewportDimension
        : 800.0;
    final first = (offset / rowHeight).floor().clamp(0, widget.channels.length);
    final last = ((offset + viewport) / rowHeight + 8).ceil().clamp(
      0,
      widget.channels.length,
    );
    final need = <MediaItem>[];
    for (var i = first; i < last; i++) {
      final channel = widget.channels[i];
      final key = channel.streamId ?? channel.id;
      if (library.isGuideFetched(channel) || library.isGuideLoading(channel)) {
        continue;
      }
      if (!_prefetchQueued.add(key)) continue;
      need.add(channel);
      if (need.length >= 18) break;
    }
    if (need.isEmpty) return;
    unawaited(
      library.fetchChannelGuides(need, concurrency: 6).whenComplete(() {
        for (final channel in need) {
          if (!library.isGuideFetched(channel)) {
            _prefetchQueued.remove(channel.streamId ?? channel.id);
          }
        }
      }),
    );
  }

  double get _timelineWidth =>
      _windowEnd.difference(_windowStart).inMinutes * _pxPerMinute;

  double _xFor(DateTime t) {
    final clamped = t.isBefore(_windowStart)
        ? _windowStart
        : (t.isAfter(_windowEnd) ? _windowEnd : t);
    return clamped.difference(_windowStart).inMinutes * _pxPerMinute;
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _slotLabel(DateTime dt) {
    final local = dt.toLocal();
    final hhmm = _hhmm(local);
    if (local.hour == 0 && local.minute == 0) {
      return '${_shortDay(local)} $hhmm';
    }
    return hhmm;
  }

  String _shortDay(DateTime local) {
    final now = DateTime.now().toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == -1) return 'Yday';
    if (diff == 1) return 'Tmrw';
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[local.weekday - 1];
  }

  String _windowRangeLabel() {
    final sameDay =
        _windowStart.toLocal().day == _windowEnd.toLocal().day &&
        _windowStart.toLocal().month == _windowEnd.toLocal().month &&
        _windowStart.toLocal().year == _windowEnd.toLocal().year;
    if (sameDay) {
      return '${_hhmm(_windowStart)}–${_hhmm(_windowEnd)}';
    }
    return '${_shortDay(_windowStart.toLocal())} ${_hhmm(_windowStart)}'
        ' – ${_shortDay(_windowEnd.toLocal())} ${_hhmm(_windowEnd)}';
  }

  void _jumpToLive({bool animated = true}) {
    if (!_hScroll.hasClients) return;
    final nowX = _xFor(DateTime.now());
    final target = (nowX - 80).clamp(0.0, _hScroll.position.maxScrollExtent);
    if (animated) {
      _hScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _hScroll.jumpTo(target);
    }
  }

  void _openProgram(MediaItem channel, EpgProgram program) {
    showEpgProgramSheet(
      context: context,
      channel: channel,
      program: program,
      onWatchLive: () => widget.onPlayLive(channel),
      onWatchCatchup: () => widget.onPlayProgram(channel, program),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on EPG / reminder / favorite changes without watching unrelated library state.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.epgRevision,
        Object.hashAll(l.epgReminders.map((r) => r.id)),
        Object.hashAll(l.favoriteChannelIds),
      ),
    );
    final library = context.read<LibraryProvider>();
    final now = DateTime.now();
    final slots = <DateTime>[];
    for (var t = _windowStart; t.isBefore(_windowEnd); t = t.add(_slot)) {
      slots.add(t);
    }

    if (widget.channels.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            context.l10n.noChannelsForGuideYet,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final rowHeight = _effectiveRowHeight;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.channels.length} channels · ${_windowRangeLabel()}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _jumpToLive(),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.sensors_rounded, size: 16),
                label: Text(context.l10n.jumpToLive),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _channelWidth,
                child: Column(
                  children: [
                    Container(
                      height: _headerHeight,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      color: _headerColor,
                      child: Text(
                        context.l10n.channel,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final focusId = widget.autofocusChannelId;
                          var autofocusIndex = 0;
                          if (focusId != null) {
                            final match = widget.channels.indexWhere(
                              (c) => c.id == focusId || c.streamId == focusId,
                            );
                            if (match >= 0) autofocusIndex = match;
                          }
                          return ListView.builder(
                            controller: _vChannels,
                            itemExtent: rowHeight,
                            itemCount: widget.channels.length,
                            itemBuilder: (context, index) {
                              final channel = widget.channels[index];
                              final fav = library.isFavoriteChannel(channel);
                              final autofocus =
                                  _tvFocus && index == autofocusIndex;
                              final row = Container(
                                height: rowHeight,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: AppColors.border),
                                    right: BorderSide(color: AppColors.border),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      fav
                                          ? Icons.star_rounded
                                          : Icons.star_outline_rounded,
                                      size: 14,
                                      color: fav
                                          ? AppColors.accent
                                          : AppColors.textMuted,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        library.officialLiveTitle(channel),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.text,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          height: 1.15,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (!_tvFocus) {
                                return InkWell(
                                  onTap: () => widget.onPlayLive(channel),
                                  onLongPress: () =>
                                      library.toggleFavoriteChannel(channel),
                                  child: row,
                                );
                              }
                              return Builder(
                                builder: (rowContext) => TvFocusable(
                                  autofocus: autofocus,
                                  borderRadius: 6,
                                  onSelect: () => widget.onPlayLive(channel),
                                  onLongSelect: () =>
                                      library.toggleFavoriteChannel(channel),
                                  onFocusChange: (focused) {
                                    if (focused) _ensureVisible(rowContext);
                                  },
                                  child: row,
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _hScroll,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _timelineWidth,
                    child: Column(
                      children: [
                        SizedBox(
                          height: _headerHeight,
                          child: Stack(
                            children: [
                              for (final slot in slots)
                                Positioned(
                                  left: _xFor(slot),
                                  top: 0,
                                  bottom: 0,
                                  width: _slot.inMinutes * _pxPerMinute,
                                  child: Container(
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.only(left: 6),
                                    color: _headerColor,
                                    child: Text(
                                      _slotLabel(slot),
                                      style: TextStyle(
                                        color:
                                            slot.toLocal().hour == 0 &&
                                                slot.toLocal().minute == 0
                                            ? AppColors.text
                                            : AppColors.textMuted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vTimeline,
                            itemExtent: rowHeight,
                            itemCount: widget.channels.length,
                            itemBuilder: (context, index) {
                              final channel = widget.channels[index];
                              final programs = library.guideFor(
                                channel,
                                from: _windowStart,
                                to: _windowEnd,
                              );
                              return SizedBox(
                                height: rowHeight,
                                width: _timelineWidth,
                                child: Stack(
                                  children: [
                                    const Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: AppColors.border,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    for (final program in programs)
                                      _ProgramCell(
                                        left: _xFor(program.start),
                                        // Size to the real slot only — a min
                                        // width made short shows overlap neighbors.
                                        width:
                                            (_xFor(program.end) -
                                                    _xFor(program.start))
                                                .clamp(2.0, _timelineWidth),
                                        program: program,
                                        now: now,
                                        hasArchive:
                                            library.liveSupportsCatchup(
                                              channel,
                                            ) ||
                                            program.hasArchive,
                                        reminded: library.isProgramReminded(
                                          channel,
                                          program,
                                        ),
                                        tvFocus: _tvFocus,
                                        translucent: widget.translucent,
                                        onFocused: _ensureVisible,
                                        onTap: () =>
                                            _openProgram(channel, program),
                                      ),
                                    Positioned(
                                      left: _xFor(now),
                                      top: 0,
                                      bottom: 0,
                                      child: Container(
                                        width: 2,
                                        color: AppColors.live,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
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
      ],
    );
  }
}

class _ProgramCell extends StatelessWidget {
  const _ProgramCell({
    required this.left,
    required this.width,
    required this.program,
    required this.now,
    required this.hasArchive,
    required this.reminded,
    required this.onTap,
    this.tvFocus = false,
    this.translucent = false,
    this.onFocused,
  });

  final double left;
  final double width;
  final EpgProgram program;
  final DateTime now;
  final bool hasArchive;
  final bool reminded;
  final VoidCallback onTap;
  final bool tvFocus;
  final bool translucent;
  final ValueChanged<BuildContext>? onFocused;

  @override
  Widget build(BuildContext context) {
    final isNow = program.isAiringAt(now);
    final isPast = program.end.isBefore(now);
    final canCatchup = hasArchive && (isPast || isNow);
    final showTimes = width >= 92;
    final showIcons = width >= 36;
    final showTitle = width >= 14;
    final hPad = width >= 28 ? 6.0 : (width >= 14 ? 2.0 : 0.0);
    final gap = width >= 6 ? 1.0 : 0.0;
    final base = isNow
        ? AppColors.accent.withValues(alpha: 0.35)
        : isPast
        ? AppColors.surfaceHigh
        : AppColors.surface;
    return Positioned(
      left: left + gap,
      top: 2,
      bottom: 2,
      width: (width - gap * 2).clamp(1.0, double.infinity),
      child: Material(
        color: translucent ? base.withValues(alpha: 0.78) : base,
        borderRadius: AppRadius.smAll,
        clipBehavior: Clip.hardEdge,
        child: _cellBody(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: AppRadius.smAll,
              border: Border.all(
                color: isNow
                    ? AppColors.accent
                    : reminded
                    ? AppColors.live
                    : canCatchup
                    ? AppColors.accent.withValues(alpha: 0.55)
                    : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                if (showTitle)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          program.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 11,
                            height: 1.15,
                            fontWeight: isNow
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        if (showTimes)
                          Text(
                            program.timeWindow,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: canCatchup
                                  ? AppColors.accent
                                  : AppColors.textMuted,
                              fontSize: 10,
                              height: 1.1,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (showIcons && canCatchup)
                  const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(
                      Icons.history_rounded,
                      size: 12,
                      color: AppColors.accent,
                    ),
                  )
                else if (showIcons && reminded)
                  const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(
                      Icons.notifications_active_rounded,
                      size: 12,
                      color: AppColors.live,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Remote-focusable cell on TV, ink-tappable cell everywhere else.
  Widget _cellBody({required Widget child}) {
    if (!tvFocus) {
      return InkWell(onTap: onTap, borderRadius: AppRadius.smAll, child: child);
    }
    return Builder(
      builder: (cellContext) => TvFocusable(
        borderRadius: 4,
        onSelect: onTap,
        onFocusChange: (focused) {
          if (focused) onFocused?.call(cellContext);
        },
        child: child,
      ),
    );
  }
}
