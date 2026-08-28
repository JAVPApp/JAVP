import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Filter day-grouped watch history by title and source label.
///
/// Empty [query] returns [byDay] unchanged. Matching is case-insensitive
/// and token-based (every word must appear in title or source).
Map<String, List<MediaItem>> filterHistoryByDay({
  required Map<String, List<MediaItem>> byDay,
  required String query,
  required String Function(MediaItem item) displayTitle,
  String Function(MediaItem item)? sourceLabel,
}) {
  final q = query.trim();
  if (q.isEmpty) return byDay;
  final out = <String, List<MediaItem>>{};
  for (final entry in byDay.entries) {
    final matched = <MediaItem>[
      for (final item in entry.value)
        if (iptvMatchesQuery(q, [
          displayTitle(item),
          item.title,
          if (sourceLabel != null) sourceLabel(item),
        ]))
          item,
    ];
    if (matched.isNotEmpty) out[entry.key] = matched;
  }
  return out;
}

/// On-device watch history — always available, no SIMKL required.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (_searchOpen) return;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    if (!_searchOpen && _query.text.isEmpty) return;
    setState(() {
      _searchOpen = false;
      _query.clear();
    });
  }

  void _toggleSearch() {
    if (_searchOpen) {
      _closeSearch();
    } else {
      _openSearch();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only the history list matters here — download ticks and catalog syncs
    // used to rebuild every row.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(identityHashCode(l.history), l.history.length),
    );
    final library = context.read<LibraryProvider>();
    final items = library.recentHistory;
    final filteredByDay = filterHistoryByDay(
      byDay: library.historyByDay,
      query: _query.text,
      displayTitle: library.historyDisplayTitle,
      sourceLabel: library.sourceLabelFor,
    );
    // Flatten day sections once so the list can build rows lazily.
    final rows = <_HistoryRow>[
      for (final entry in filteredByDay.entries) ...[
        _HistoryRow.header(entry.key),
        for (final item in entry.value) _HistoryRow.item(item),
      ],
    ];
    final filtering = _query.text.trim().isNotEmpty;
    final noFilterMatches = filtering && rows.isEmpty && items.isNotEmpty;

    return PopScope(
      canPop: !_searchOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_searchOpen) return;
        _closeSearch();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.history),
          actions: [
            _searchAction(context),
            if (items.isNotEmpty)
              IconButton(
                tooltip: context.l10n.clearHistory,
                onPressed: () => _confirmClear(context),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
        body: Column(
          children: [
            if (_searchOpen)
              IptvSearchBar(
                controller: _query,
                focusNode: _searchFocus,
                autofocus: true,
                hintText: context.l10n.searchHistoryHint,
              ),
            Expanded(
              child: _body(context, library, items, rows, noFilterMatches),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchAction(BuildContext context) {
    final searching = _searchOpen;
    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        borderRadius: 24,
        onSelect: _toggleSearch,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(searching ? Icons.close_rounded : Icons.search_rounded),
        ),
      );
    }
    return IconButton(
      tooltip: searching ? context.l10n.close : context.l10n.search,
      onPressed: _toggleSearch,
      icon: Icon(searching ? Icons.close_rounded : Icons.search_rounded),
    );
  }

  Widget _body(
    BuildContext context,
    LibraryProvider library,
    List<MediaItem> items,
    List<_HistoryRow> rows,
    bool noFilterMatches,
  ) {
    if (items.isEmpty) return const _EmptyHistory();
    if (noFilterMatches) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            context.l10n.noMatches,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return DesktopPane(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
        itemCount: rows.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                context.l10n.historyLocalOnlyHelp,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          final row = rows[index - 1];
          final item = row.item;
          if (item == null) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                _dayLabel(context, row.dayKey!),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }
          return _HistoryTile(
            item: item,
            title: library.historyDisplayTitle(item),
            sourceLabel: library.sourceLabelFor(item),
            onPlay: () {
              if (item.isSeries) {
                context.push('/series', extra: item);
              } else {
                context.push('/player', extra: item);
              }
            },
            onRemove: () => library.removeFromHistory(item.id),
          );
        },
      ),
    );
  }

  String _dayLabel(BuildContext context, String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final date = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == today) return context.l10n.today;
    if (date == yesterday) return context.l10n.yesterday;
    return DateFormat.yMMMd().format(date);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(context.l10n.clearWatchHistoryTitle),
          content: Text(context.l10n.historyClearLocalOnly),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.clear),
            ),
          ],
        );
      },
    );
    if (ok == true) await library.clearHistory();
  }
}

/// Either a day header or a watched title, so the list can be virtualized.
class _HistoryRow {
  const _HistoryRow.header(String this.dayKey) : item = null;
  const _HistoryRow.item(MediaItem this.item) : dayKey = null;

  final String? dayKey;
  final MediaItem? item;
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.item,
    required this.title,
    required this.sourceLabel,
    required this.onPlay,
    required this.onRemove,
  });

  final MediaItem item;
  final String title;
  final String sourceLabel;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final time = item.lastWatchedAt == null
        ? ''
        : DateFormat.jm().format(item.lastWatchedAt!.toLocal());
    final l10n = context.l10n;
    final kindLabel = item.isEpisode
        ? (item.episodeNumber != null
              ? l10n.episodeNumber(item.episodeNumber!)
              : l10n.episodes)
        : switch (item.kind) {
            MediaKind.live => l10n.live,
            MediaKind.vod => l10n.movie,
            MediaKind.series => l10n.series,
            MediaKind.catchup => l10n.catchup,
            MediaKind.local => l10n.local,
            MediaKind.network => l10n.url,
          };
    final progressLabel = item.isLive
        ? kindLabel
        : item.progress >= 0.95
        ? '${l10n.watchedStatus} · $kindLabel'
        : item.progress > 0.02
        ? '${l10n.percentWatched((item.progress * 100).round())} · $kindLabel'
        : kindLabel;

    return Dismissible(
      key: ValueKey('history-${item.id}-${item.lastWatchedAt}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.accent.withValues(alpha: 0.85),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      onDismissed: (_) => onRemove(),
      child: GestureDetector(
        onSecondaryTapUp: (details) => showMediaItemActions(
          context: context,
          item: item,
          anchor: details.globalPosition,
          onPlay: onPlay,
          onRemoveFromHistory: onRemove,
        ),
        child: ListTile(
          onTap: onPlay,
          onLongPress: () => showMediaItemActions(
            context: context,
            item: item,
            onPlay: onPlay,
            onRemoveFromHistory: onRemove,
          ),
          leading: CircleAvatar(
            backgroundColor: AppColors.surfaceHigh,
            child: Icon(
              item.isLive
                  ? Icons.sensors_rounded
                  : item.isEpisode
                  ? Icons.playlist_play_rounded
                  : Icons.play_arrow_rounded,
              color: AppColors.accent,
            ),
          ),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            [sourceLabel, if (time.isNotEmpty) time, progressLabel].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDownloadActionAvailable(item))
                DownloadStatusButton(item: item),
              IconButton(
                tooltip: context.l10n.remove,
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.history_rounded,
              size: 56,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 14),
            Text(
              context.l10n.noWatchHistoryYet,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.historyHelp,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
