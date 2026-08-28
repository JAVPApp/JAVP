import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/kicker.dart';
import 'package:provider/provider.dart';

/// Details + suggestions beside / below the video.
class PlayerBrowsePanel extends StatefulWidget {
  const PlayerBrowsePanel({super.key});

  @override
  State<PlayerBrowsePanel> createState() => _PlayerBrowsePanelState();
}

class _PlayerBrowsePanelState extends State<PlayerBrowsePanel> {
  bool _descExpanded = false;
  String? _guideChannelId;

  String? _detailsWarmId;
  String? _suggestionsWarmId;
  List<MediaItem> _vodSuggestions = const [];

  Widget? _frozenWhenHidden;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmDetailsIfNeeded();
  }

  void _warmDetailsIfNeeded() {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final item = playback.item;
    if (item == null) return;
    if (playback.cinemaMode || playback.browsePanelCollapsed) return;

    // VOD: warm plot/meta for the browse pane (never fetch EPG).
    // Local Open-with / imports stay filename-only — no TMDB guesswork.
    if (!item.isLive && item.kind != MediaKind.catchup) {
      if (item.origin == MediaOrigin.localFile) {
        _detailsWarmId = item.id;
        _suggestionsWarmId = item.id;
        _vodSuggestions = const [];
        return;
      }
      if (_detailsWarmId != item.id) {
        _detailsWarmId = item.id;
        unawaited(library.loadMediaDetails(item));
      }
      if (_suggestionsWarmId != item.id) {
        _suggestionsWarmId = item.id;
        // Sync first (RAM index); async pages SQLite same-group peers.
        _vodSuggestions = library.vodSuggestionsFor(item, limit: 12);
        unawaited(() async {
          final next = await library.vodSuggestionsForAsync(item, limit: 12);
          if (!mounted || _suggestionsWarmId != item.id) return;
          setState(() => _vodSuggestions = next);
        }());
      }
      return;
    }

    final channel = playback.liveChannel ?? item;
    if (_guideChannelId == channel.id) return;
    _guideChannelId = channel.id;
    unawaited(library.fetchChannelGuide(channel));
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
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
    final s = start.toLocal();
    final e = end.toLocal();
    final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
    if (sameDay) return '${_hhmm(start)}–${_hhmm(end)}';
    return '${_calendarDate(start)} ${_hhmm(start)} – '
        '${_calendarDate(end)} ${_hhmm(end)}';
  }

  String _currentWindowLabel(DateTime start, DateTime end) {
    final s = start.toLocal();
    final e = end.toLocal();
    final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
    final now = DateTime.now().toLocal();
    final day = DateTime(s.year, s.month, s.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    final dayPart = diff == 0
        ? context.l10n.today
        : diff == -1
        ? context.l10n.yesterday
        : diff == 1
        ? context.l10n.tomorrow
        : _calendarDate(start);
    if (sameDay) return '$dayPart · ${_hhmm(start)}–${_hhmm(end)}';
    return '${_calendarDate(start)} ${_hhmm(start)} – '
        '${_calendarDate(end)} ${_hhmm(end)}';
  }

  Future<void> _playChannel(MediaItem channel) async {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final resolved = library.resolveLiveChannel(channel);
    final sameChannel =
        playback.liveChannel?.streamId == resolved.streamId &&
        playback.liveChannel?.sourceId == resolved.sourceId;
    // Already timeshifted on this channel — go to the live edge instead of
    // open(live), which used to wipe DVR and reload from the wrong place.
    if (sameChannel && playback.canLiveDvr && !playback.isAtLiveEdge) {
      await playback.jumpToLive();
      return;
    }
    await playback.open(resolved, expand: true);
  }

  Future<void> _playVod(MediaItem item) async {
    final playback = context.read<PlaybackProvider>();
    if (item.isSeries) {
      if (!mounted) return;
      context.push('/series', extra: item);
      return;
    }
    await playback.open(item, expand: true);
  }

  Future<void> _playProgram(MediaItem channel, EpgProgram program) async {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final resolved = library.resolveLiveChannel(channel);
    final now = DateTime.now();

    if (program.isAiringAt(now)) {
      final playingSame =
          playback.liveChannel?.streamId == resolved.streamId &&
          playback.liveChannel?.sourceId == resolved.sourceId;
      if (playingSame) {
        // Current show while already on this channel → live edge (Start Over
        // stays an explicit control). Opening catchup here felt like a reload.
        await playback.jumpToLive();
        return;
      }
      await playback.open(resolved, expand: true);
      return;
    }

    if (program.start.isAfter(now)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.startsAt(_hhmm(program.start)))),
      );
      return;
    }

    final item = await library.catchupItemAsync(
      channel: resolved,
      program: program,
    );
    if (item == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.catchupUnavailable)));
      return;
    }
    await playback.open(item, expand: true);
  }

  @override
  Widget build(BuildContext context) {
    final hidden = context.select<PlaybackProvider, bool>(
      (p) => p.cinemaMode || p.browsePanelCollapsed,
    );
    if (hidden) {
      return _frozenWhenHidden ?? const ColoredBox(color: AppColors.bg);
    }
    _warmDetailsIfNeeded();
    Widget freeze(Widget child) {
      _frozenWhenHidden = child;
      return child;
    }

    // Rebuild only when the playing title / live program identity changes —
    // never on position ticks (~5 Hz via PlaybackProvider notifies).
    context.select<PlaybackProvider, Object?>(
      (p) => Object.hash(
        p.item?.id,
        p.liveChannel?.id,
        p.currentProgram?.title,
        p.nextProgram?.title,
        p.isAtLiveEdge,
        p.canLiveDvr,
        p.canStartOver,
        p.liveDelay.inMinutes,
      ),
    );
    final playback = context.read<PlaybackProvider>();
    // This panel sits over the video, so it must not redraw for every
    // download tick or sync status line while something is playing.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.epgRevision,
        l.liveDbRevision,
        l.liveIndexRevision,
        identityHashCode(l.detailsCache),
        l.catalog.length,
        l.vodCacheRevision,
      ),
    );
    final library = context.read<LibraryProvider>();
    final item = playback.item;
    if (item == null) {
      return freeze(const ColoredBox(color: AppColors.bg));
    }

    final isLiveSurface = item.isLive || item.kind == MediaKind.catchup;
    if (!isLiveSurface) {
      if (item.origin == MediaOrigin.localFile) {
        return freeze(_LocalFileBrowseBody(item: item, library: library));
      }
      return freeze(
        _VodBrowseBody(
          item: item,
          library: library,
          playback: playback,
          descExpanded: _descExpanded,
          onToggleDesc: () => setState(() => _descExpanded = !_descExpanded),
          onPlayVod: _playVod,
          suggestions: _vodSuggestions,
        ),
      );
    }

    return freeze(
      _LiveBrowseBody(
        item: item,
        library: library,
        playback: playback,
        descExpanded: _descExpanded,
        onToggleDesc: () => setState(() => _descExpanded = !_descExpanded),
        hhmm: _hhmm,
        dayHeading: (dt) => _dayHeading(context, dt),
        programWindow: _programWindow,
        currentWindowLabel: _currentWindowLabel,
        onPlayChannel: _playChannel,
        onPlayProgram: _playProgram,
      ),
    );
  }
}

/// Keeps [PlayerBrowsePanel] mounted while collapsed so hide/show does not
/// refetch details/guide or rebuild the video [Scaffold].
///
/// Collapsed = clip to 0 along [axis]; the child still layouts at [extent].
class PlayerBrowsePanelSlot extends StatelessWidget {
  const PlayerBrowsePanelSlot({
    super.key,
    required this.collapsed,
    required this.axis,
    required this.extent,
    required this.child,
  });

  final bool collapsed;
  final Axis axis;
  final double extent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (extent <= 0) return const SizedBox.shrink();
    final panel = TickerMode(
      enabled: !collapsed,
      child: IgnorePointer(
        ignoring: collapsed,
        child: ExcludeSemantics(excluding: collapsed, child: child),
      ),
    );
    final sized = axis == Axis.horizontal
        ? SizedBox(width: extent, child: panel)
        : SizedBox(height: extent, child: panel);
    return ClipRect(
      child: Align(
        alignment: axis == Axis.horizontal
            ? Alignment.centerLeft
            : Alignment.topCenter,
        widthFactor: axis == Axis.horizontal && collapsed ? 0.0 : 1.0,
        heightFactor: axis == Axis.vertical && collapsed ? 0.0 : 1.0,
        child: sized,
      ),
    );
  }
}

/// Filename-only panel for Open-with / imported local files.
class _LocalFileBrowseBody extends StatelessWidget {
  const _LocalFileBrowseBody({required this.item, required this.library});

  final MediaItem item;
  final LibraryProvider library;

  @override
  Widget build(BuildContext context) {
    final saved = library.isInWatchlist(item);
    final subtitle = (item.subtitle != null && item.subtitle!.trim().isNotEmpty)
        ? localizePersistedSubtitle(context.l10n, item.subtitle)!.trim()
        : context.l10n.local;
    final meta = [
      if (item.resolution != null && item.resolution!.trim().isNotEmpty)
        item.resolution!,
      library.sourceLabelFor(item),
    ].where((e) => e.trim().isNotEmpty).join(' · ');

    return ColoredBox(
      color: AppColors.bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            item.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: AppColors.textMuted)),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              meta,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => library.toggleWatchlist(item),
                icon: Icon(
                  saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 18,
                ),
                label: Text(
                  saved ? context.l10n.inMyList : context.l10n.myList,
                ),
              ),
              if (isDownloadActionAvailable(item))
                DownloadStatusButton(item: item, outlined: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _VodBrowseBody extends StatelessWidget {
  const _VodBrowseBody({
    required this.item,
    required this.library,
    required this.playback,
    required this.descExpanded,
    required this.onToggleDesc,
    required this.onPlayVod,
    required this.suggestions,
  });

  final MediaItem item;
  final LibraryProvider library;
  final PlaybackProvider playback;
  final bool descExpanded;
  final VoidCallback onToggleDesc;
  final Future<void> Function(MediaItem item) onPlayVod;
  final List<MediaItem> suggestions;

  @override
  Widget build(BuildContext context) {
    final details = library.detailsFor(item);
    final title = details?.title.isNotEmpty == true
        ? details!.title
        : item.title;
    final plot = (details?.plot ?? item.plot)?.trim();
    final meta = [
      if (item.seasonNumber != null && item.episodeNumber != null)
        'S${item.seasonNumber.toString().padLeft(2, '0')}'
            'E${item.episodeNumber.toString().padLeft(2, '0')}',
      if (details?.year != null || item.year != null)
        '${details?.year ?? item.year}',
      if ((details?.genres ?? item.genres).isNotEmpty)
        (details?.genres ?? item.genres).take(3).join(' · '),
      if (item.resolution != null && item.resolution!.trim().isNotEmpty)
        item.resolution!,
      library.sourceLabelFor(item),
    ].whereType<String>().where((e) => e.trim().isNotEmpty).join(' · ');

    final saved = library.isInWatchlist(item);
    final hasPlot = plot != null && plot.isNotEmpty;

    return ColoredBox(
      color: AppColors.bg,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (item.subtitle != null &&
                      item.subtitle!.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      localizePersistedSubtitle(context.l10n, item.subtitle) ??
                          item.subtitle!,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (hasPlot) ...[
                    const SizedBox(height: 10),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 180),
                      crossFadeState: descExpanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: Text(
                        plot,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          height: 1.35,
                        ),
                      ),
                      secondChild: Text(
                        plot,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          height: 1.35,
                        ),
                      ),
                    ),
                    if (plot.length > 160)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: onToggleDesc,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.text,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            descExpanded
                                ? context.l10n.showLess
                                : context.l10n.showMore,
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => library.toggleWatchlist(item),
                        icon: Icon(
                          saved
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          size: 18,
                        ),
                        label: Text(
                          saved ? context.l10n.inMyList : context.l10n.myList,
                        ),
                      ),
                      if (isDownloadActionAvailable(item))
                        DownloadStatusButton(item: item, outlined: true),
                      if (item.seriesId != null && item.seriesId!.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () async {
                            final series =
                                library.seriesShellForEpisode(item) ??
                                library.seriesForEpisode(item);
                            if (series == null) return;
                            // Leave the expanded player so we don't stack
                            // series on top of a hidden playing session.
                            final router = GoRouter.of(context);
                            await playback.minimize();
                            if (router.canPop()) {
                              router.pop();
                            }
                            router.push('/series', extra: series);
                          },
                          icon: const Icon(Icons.tv_rounded, size: 18),
                          label: Text(context.l10n.episodes),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (suggestions.isNotEmpty) ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Kicker(
                  context.l10n.moreLikeThis,
                  color: AppColors.textDim,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              sliver: SliverList.separated(
                itemCount: suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final row = suggestions[index];
                  final art = row.artUrl;
                  return Material(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => unawaited(onPlayVod(row)),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 48,
                                height: 68,
                                child: art == null || art.isEmpty
                                    ? const ColoredBox(
                                        color: AppColors.surface,
                                        child: Icon(
                                          Icons.movie_outlined,
                                          size: 20,
                                          color: AppColors.textMuted,
                                        ),
                                      )
                                    : JavpArt(
                                        url: art,
                                        decodeWidth: 96,
                                        fallback: const ColoredBox(
                                          color: AppColors.surface,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    row.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.text,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      height: 1.15,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (row.year != null) '${row.year}',
                                      if (row.group != null) row.group!,
                                      if (row.isSeries) context.l10n.series,
                                    ].whereType<String>().join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.play_circle_fill_rounded,
                              size: 22,
                              color: AppColors.accent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ] else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              sliver: SliverToBoxAdapter(
                child: Text(
                  context.l10n.moreTitlesAsCatalogFills,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveBrowseBody extends StatefulWidget {
  const _LiveBrowseBody({
    required this.item,
    required this.library,
    required this.playback,
    required this.descExpanded,
    required this.onToggleDesc,
    required this.hhmm,
    required this.dayHeading,
    required this.programWindow,
    required this.currentWindowLabel,
    required this.onPlayChannel,
    required this.onPlayProgram,
  });

  final MediaItem item;
  final LibraryProvider library;
  final PlaybackProvider playback;
  final bool descExpanded;
  final VoidCallback onToggleDesc;
  final String Function(DateTime) hhmm;
  final String Function(DateTime) dayHeading;
  final String Function(DateTime start, DateTime end) programWindow;
  final String Function(DateTime start, DateTime end) currentWindowLabel;
  final Future<void> Function(MediaItem) onPlayChannel;
  final Future<void> Function(MediaItem, EpgProgram) onPlayProgram;

  @override
  State<_LiveBrowseBody> createState() => _LiveBrowseBodyState();
}

enum _LiveBrowseTab { channels, guide }

class _LiveBrowseBodyState extends State<_LiveBrowseBody> {
  _LiveBrowseTab _tab = _LiveBrowseTab.channels;
  String? _peersChannelId;
  ({List<MediaItem> channels, PlayerPeerSource source, String? category})?
  _peers;

  void _ensurePeersLoaded(LibraryProvider library, MediaItem channel) {
    final id = library.resolveLiveChannel(channel).id;
    if (_peersChannelId == id && _peers != null) return;
    _peersChannelId = id;
    _peers = library.playerPeerChannelsFor(channel);
    unawaited(() async {
      final loaded = await library.playerPeerChannelsForAsync(channel);
      if (!mounted || _peersChannelId != id) return;
      setState(() => _peers = loaded);
    }());
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final playback = widget.playback;
    final item = widget.item;
    final channel = playback.liveChannel ?? item;
    final program = playback.currentProgram;
    final next = playback.nextProgram;
    final wall = playback.playbackWallClock;
    // Keep the guide window pinned to live "now" so scrubbing / opening
    // catchup doesn't reshuffle the whole list around the DVR playhead.
    final now = DateTime.now();
    final nearby = library.nearbyPrograms(
      channel,
      at: now,
      before: library.liveSupportsCatchup(channel)
          ? ((library.resolveCatchupChannel(channel)?.catchupDays ?? 1).clamp(
                      1,
                      14,
                    ) *
                    6)
                .clamp(12, 48)
                .toInt()
          : 8,
      after: 4,
    );
    _ensurePeersLoaded(library, channel);
    final peers = _peers ?? library.playerPeerChannelsFor(channel);
    final canStartOver = playback.canStartOver;
    final atLive = playback.isAtLiveEdge;
    final desc = program?.description?.trim();
    final hasDesc = desc != null && desc.isNotEmpty;
    final guideLoading = library.isGuideLoading(channel);

    final peerKicker = switch (peers.source) {
      PlayerPeerSource.category => context.l10n.moreInCategory(
        peers.category ?? context.l10n.category,
      ),
      PlayerPeerSource.favorites => context.l10n.favorites,
      PlayerPeerSource.forYou => context.l10n.forYou,
    };

    return ColoredBox(
      color: AppColors.bg,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    library.liveOrCatchupDisplayTitle(channel),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (program != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      program.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.currentWindowLabel(program.start, program.end)}'
                      '${atLive ? ' · ${context.l10n.live}' : ' · ${context.l10n.minutesBehindLive(playback.liveDelay.inMinutes)}'}'
                      '${next == null ? '' : ' · ${context.l10n.nextProgrammeAt(widget.hhmm(next.start), next.title)}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ] else if (item.subtitle != null &&
                      item.subtitle!.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      localizePersistedSubtitle(context.l10n, item.subtitle) ??
                          item.subtitle!,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ],
                  if (hasDesc) ...[
                    const SizedBox(height: 10),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 180),
                      crossFadeState: widget.descExpanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: Text(
                        desc,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          height: 1.35,
                        ),
                      ),
                      secondChild: Text(
                        desc,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          height: 1.35,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: widget.onToggleDesc,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.text,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(
                          widget.descExpanded
                              ? context.l10n.showLess
                              : context.l10n.showMore,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (canStartOver)
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              unawaited(playback.startOverCurrentProgram()),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: Text(context.l10n.startOver),
                        ),
                      if (!atLive && playback.canLiveDvr)
                        FilledButton.tonalIcon(
                          onPressed: () => unawaited(playback.jumpToLive()),
                          icon: const Icon(Icons.sensors_rounded, size: 18),
                          label: Text(context.l10n.jumpToLive),
                        ),
                      if (program != null &&
                          (library.liveSupportsCatchup(channel) ||
                              program.hasArchive))
                        OutlinedButton.icon(
                          onPressed: () => unawaited(
                            showDvrDownloadPadDialog(
                              context: context,
                              channel: channel,
                              program: program,
                            ),
                          ),
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(context.l10n.downloadForOffline),
                        )
                      else if (library.liveSupportsCatchup(channel))
                        OutlinedButton.icon(
                          onPressed: () => unawaited(
                            showCatchupRecordDialog(
                              context: context,
                              channel: channel,
                              initialStart: item.kind == MediaKind.catchup
                                  ? LibraryProvider.catchupStartOf(item)
                                  : null,
                              initialDurationMin: item.kind == MediaKind.catchup
                                  ? item.duration?.inMinutes
                                  : null,
                              initialTitle: item.kind == MediaKind.catchup
                                  ? item.title
                                  : null,
                            ),
                          ),
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(context.l10n.downloadForOffline),
                        )
                      else if (isDownloadActionAvailable(item))
                        DownloadStatusButton(item: item, outlined: true),
                      if (library.isFavoriteChannel(channel))
                        OutlinedButton.icon(
                          onPressed: () =>
                              library.toggleFavoriteChannel(channel),
                          icon: const Icon(Icons.star_rounded, size: 18),
                          label: Text(context.l10n.favorited),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () =>
                              library.toggleFavoriteChannel(channel),
                          icon: const Icon(
                            Icons.star_outline_rounded,
                            size: 18,
                          ),
                          label: Text(context.l10n.favorite),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<_LiveBrowseTab>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: _LiveBrowseTab.channels,
                        label: Text(context.l10n.channels),
                        icon: const Icon(Icons.tv_rounded, size: 16),
                      ),
                      ButtonSegment(
                        value: _LiveBrowseTab.guide,
                        label: Text(context.l10n.guide),
                        icon: const Icon(Icons.view_agenda_rounded, size: 16),
                      ),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) {
                      setState(() => _tab = s.first);
                    },
                    style: AppTheme.segmentedButtonStyle(
                      visualDensity: VisualDensity.compact,
                      compact: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_tab == _LiveBrowseTab.guide) ...[
            if (nearby.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                sliver: SliverToBoxAdapter(
                  child: Kicker(
                    context.l10n.onThisChannel,
                    color: AppColors.textDim,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(
                    _nearbyProgramTiles(
                      context,
                      channel: channel,
                      nearby: nearby.take(24).toList(),
                      now: now,
                      wall: wall,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ] else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    guideLoading
                        ? context.l10n.loadingGuide
                        : context.l10n.noGuideEntriesYet,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ),
          ] else ...[
            if (peers.channels.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Kicker(peerKicker, color: AppColors.textDim),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                sliver: SliverList.separated(
                  itemCount: peers.channels.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final row = peers.channels[index];
                    final nowOn = library.nowPlayingFor(row);
                    final art = row.thumbnailUrl?.trim().isNotEmpty == true
                        ? row.thumbnailUrl!.trim()
                        : row.artUrl;
                    return Material(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => unawaited(widget.onPlayChannel(row)),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: art == null || art.isEmpty
                                      ? const ColoredBox(
                                          color: AppColors.surface,
                                          child: Icon(
                                            Icons.tv_rounded,
                                            size: 20,
                                            color: AppColors.textMuted,
                                          ),
                                        )
                                      : JavpArt(
                                          url: art,
                                          decodeWidth: 96,
                                          fallback: const ColoredBox(
                                            color: AppColors.surface,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      library.officialLiveTitle(row),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.text,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                        height: 1.15,
                                      ),
                                    ),
                                    if (nowOn != null) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        nowOn.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ] else if (row.group != null &&
                                        row.group!.trim().isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        row.group!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.play_circle_fill_rounded,
                                size: 22,
                                color: AppColors.accent,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    context.l10n.noChannelsInThisList,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  List<Widget> _nearbyProgramTiles(
    BuildContext context, {
    required MediaItem channel,
    required List<EpgProgram> nearby,
    required DateTime now,
    required DateTime wall,
  }) {
    final library = widget.library;
    final children = <Widget>[];
    DateTime? lastDay;
    for (final p in nearby) {
      final local = p.start.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay == null || day != lastDay) {
        lastDay = day;
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(8, children.isEmpty ? 2 : 10, 8, 2),
            child: Text(
              widget.dayHeading(p.start),
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        );
      }

      final isLiveNow = p.isAiringAt(now);
      final isPlaying = p.isAiringAt(wall);
      final isPast = p.end.isBefore(now);
      final canCatchup =
          isPast && (library.liveSupportsCatchup(channel) || p.hasArchive);
      final canStart =
          isLiveNow && (library.liveSupportsCatchup(channel) || p.hasArchive);
      final status = isPlaying
          ? (isLiveNow ? context.l10n.playingLive : context.l10n.playing)
          : isLiveNow
          ? context.l10n.now
          : isPast
          ? context.l10n.catchup
          : context.l10n.upcoming;
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: ListTile(
            dense: true,
            selected: isPlaying,
            selectedTileColor: AppColors.accentSoft,
            selectedColor: AppColors.text,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: isPlaying
                    ? AppColors.accent.withValues(alpha: 0.55)
                    : isLiveNow
                    ? AppColors.live.withValues(alpha: 0.45)
                    : Colors.transparent,
                width: isPlaying || isLiveNow ? 1.2 : 0,
              ),
            ),
            tileColor: !isPlaying && isLiveNow
                ? AppColors.live.withValues(alpha: 0.10)
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            title: Text(
              p.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.text,
                fontWeight: isPlaying || isLiveNow
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '${widget.programWindow(p.start, p.end)} · $status',
              style: TextStyle(
                color: isPlaying
                    ? AppColors.accent
                    : isLiveNow
                    ? AppColors.live
                    : AppColors.textMuted,
                fontSize: 12,
                fontWeight: isPlaying || isLiveNow
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
            trailing: isPlaying
                ? Icon(
                    isLiveNow
                        ? Icons.sensors_rounded
                        : Icons.play_arrow_rounded,
                    color: isLiveNow ? AppColors.live : AppColors.accent,
                    size: 22,
                  )
                : isLiveNow
                ? Icon(
                    canStart
                        ? Icons.restart_alt_rounded
                        : Icons.sensors_rounded,
                    color: canStart ? AppColors.accent : AppColors.live,
                    size: 20,
                  )
                : canCatchup
                ? const Icon(
                    Icons.history_rounded,
                    color: AppColors.accent,
                    size: 20,
                  )
                : null,
            onTap: () => unawaited(widget.onPlayProgram(channel, p)),
          ),
        ),
      );
    }
    return children;
  }
}
