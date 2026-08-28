// Library hub destinations: genres, collections, playlists, downloads.
// Routed from /genres, /collections, /playlists, /downloads.
// Formerly misnamed library_polish_screens.dart.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/services/download/catchup_air_date.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:provider/provider.dart';

class GenreBrowseScreen extends StatefulWidget {
  const GenreBrowseScreen({super.key});

  @override
  State<GenreBrowseScreen> createState() => _GenreBrowseScreenState();
}

class _GenreBrowseScreenState extends State<GenreBrowseScreen> {
  String? _genre;
  String? _yearFilter;
  bool _unwatchedOnly = false;

  List<MediaItem>? _cachedItems;
  Object? _cacheKey;

  /// Filtering the whole library on every provider notification made this
  /// screen stutter; recompute only when the inputs actually change.
  List<MediaItem> _filtered(LibraryProvider library) {
    final key = Object.hash(
      identityHashCode(library.allContent),
      identityHashCode(library.detailsCache),
      _genre,
      _yearFilter,
      _unwatchedOnly,
    );
    final cached = _cachedItems;
    if (cached != null && key == _cacheKey) return cached;

    final year = _yearFilter == null ? null : int.tryParse(_yearFilter!);
    final out = <MediaItem>[];
    for (final m in library.allContent) {
      if (m.isLive || m.kind == MediaKind.catchup) continue;
      if (_genre != null &&
          !m.genres.contains(_genre) &&
          !(library.detailsCache[m.detailsId ?? m.id]?.genres.contains(
                _genre,
              ) ??
              false)) {
        continue;
      }
      if (year != null && m.year != year) continue;
      if (_unwatchedOnly && m.progress >= 0.9) continue;
      out.add(m);
    }
    _cachedItems = out;
    _cacheKey = key;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        identityHashCode(l.allContent),
        identityHashCode(l.detailsCache),
        l.displaySettings.moviesCoverOrientation,
        l.sourcesAppearanceRevision,
      ),
    );
    final library = context.read<LibraryProvider>();
    final genres = library.allGenres;
    final items = _filtered(library);
    final moviePortrait = library.displaySettings.resolveMoviesCoverPortrait(
      items,
    );

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.browseByGenre)),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: AppLayout.shelfPadding,
              itemCount: genres.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(context.l10n.all),
                      selected: _genre == null,
                      onSelected: (_) => setState(() => _genre = null),
                    ),
                  );
                }
                final g = genres[i - 1];
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(g),
                    selected: _genre == g,
                    onSelected: (_) => setState(() => _genre = g),
                  ),
                );
              },
            ),
          ),
          SwitchListTile(
            title: Text(context.l10n.hideWatched),
            value: _unwatchedOnly,
            onChanged: (v) => setState(() => _unwatchedOnly = v),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      context.l10n.noTitlesMatchEnrichTmdb,
                      style: TextStyle(color: AppColors.textMuted),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      return MediaTile(
                        item: item,
                        portrait: moviePortrait,
                        sourceLabel: library.sourceLabelFor(item),
                        onTap: () {
                          if (item.isSeries) {
                            context.push('/series', extra: item);
                          } else {
                            context.push('/title', extra: item);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class CollectionsScreen extends StatelessWidget {
  const CollectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    context.select<LibraryProvider, int>((l) => l.collections.length);
    final library = context.read<LibraryProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.collections)),
      body: library.collections.isEmpty
          ? Center(
              child: Text(
                context.l10n.collectionsAppearHint,
                style: TextStyle(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: library.collections.length,
              itemBuilder: (context, i) {
                final c = library.collections[i];
                return ListTile(
                  leading: c.posterUrl == null
                      ? const Icon(Icons.collections_bookmark_outlined)
                      : SizedBox(
                          width: 40,
                          child: JavpArt(url: c.posterUrl, decodeWidth: 96),
                        ),
                  title: Text(c.name),
                  subtitle: Text(context.l10n.nTitles(c.mediaItemIds.length)),
                  onTap: () {
                    final items = c.mediaItemIds
                        .map(library.itemById)
                        .whereType<MediaItem>()
                        .toList();
                    showAppModal<void>(
                      context: context,
                      builder: (context) => ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return ListTile(
                            title: Text(item.title),
                            onTap: () {
                              Navigator.pop(context);
                              context.push('/title', extra: item);
                            },
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    context.select<LibraryProvider, int>(
      (l) => Object.hash(identityHashCode(l.playlists), l.playlists.length),
    );
    final library = context.read<LibraryProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.playlists)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final controller = TextEditingController();
          final name = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(context.l10n.newPlaylist),
              content: JavpTextField(
                controller: controller,
                decoration: InputDecoration(labelText: context.l10n.name),
                autofocus: true,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, controller.text),
                  child: Text(context.l10n.create),
                ),
              ],
            ),
          );
          if (name != null && name.trim().isNotEmpty) {
            await library.createPlaylist(name);
          }
        },
        icon: const Icon(Icons.add),
        label: Text(context.l10n.labelNew),
      ),
      body: library.playlists.isEmpty
          ? Center(
              child: Text(
                context.l10n.createPlaylistHint,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            )
          : ListView.builder(
              // FAB clearance + PersistentMiniPlayer dock/system inset.
              padding: AppLayout.pagePadding(
                bottom: 100 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: library.playlists.length,
              itemBuilder: (context, i) {
                final p = library.playlists[i];
                return ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: Text(p.name),
                  subtitle: Text(context.l10n.nItems(p.mediaItemIds.length)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => library.removePlaylist(p.id),
                  ),
                  onTap: () {
                    final items = p.mediaItemIds
                        .map(library.itemById)
                        .whereType<MediaItem>()
                        .toList();
                    if (items.isEmpty) return;
                    context.push('/player', extra: items.first);
                  },
                );
              },
            ),
    );
  }
}

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final tasks = library.downloads.tasks;
    final active = tasks
        .where(
          (t) =>
              t.status == DownloadStatus.queued ||
              t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.paused ||
              t.status == DownloadStatus.failed,
        )
        .toList();
    final offline = library.offlineLibraryItems;
    final waitingWifi =
        library.downloads.waitingForWifi &&
        active.any((t) => t.status == DownloadStatus.queued);
    final empty = active.isEmpty && offline.isEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.downloads)),
      body: empty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_outlined,
                      size: 48,
                      color: AppColors.textMuted.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.nothingSavedOfflineYet,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.downloadEpisodesHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    if (library.downloadSettings.removeAfterWatch) ...[
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.finishedDownloadsMayBeRemoved,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : DesktopPane(
              child: ListView(
                padding: const EdgeInsets.only(
                  bottom: AppLayout.dockedBottomInset,
                ),
                children: [
                  if (waitingWifi)
                    Container(
                      width: double.infinity,
                      color: AppColors.surfaceHigh,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.wifi_off_rounded, size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: Text(context.l10n.waitingForWifi)),
                          TextButton(
                            onPressed: () {
                              final next = active
                                  .cast<DownloadTask?>()
                                  .firstWhere(
                                    (t) => t?.status == DownloadStatus.queued,
                                    orElse: () => null,
                                  );
                              if (next != null) {
                                library.downloads.downloadAnyway(next.id);
                              }
                            },
                            child: Text(context.l10n.downloadAnyway),
                          ),
                        ],
                      ),
                    ),
                  if (active.isNotEmpty) ...[
                    Padding(
                      padding: _downloadsSectionPadding,
                      child: Text(
                        context.l10n.queue,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                    for (final t in active)
                      _DownloadTile(key: ValueKey('queue-${t.id}'), task: t),
                  ],
                  if (offline.isNotEmpty) ...[
                    Padding(
                      padding: _downloadsSectionPadding,
                      child: Text(
                        active.isEmpty
                            ? context.l10n.availableOffline
                            : context.l10n.nAvailableOffline(offline.length),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                    for (final item in offline) _OfflineLibraryTile(item: item),
                  ],
                ],
              ),
            ),
    );
  }
}

/// Group label above a run of download rows — gutter-aligned with the tiles.
const _downloadsSectionPadding = EdgeInsets.fromLTRB(
  AppLayout.gutter,
  16,
  AppLayout.gutter,
  8,
);

class _OfflineLibraryTile extends StatelessWidget {
  const _OfflineLibraryTile({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final airDate = item.releaseDate?.trim();
    final subtitle = item.subtitle?.trim();
    final meta = [
      if (item.seasonNumber != null && item.episodeNumber != null)
        'S${item.seasonNumber.toString().padLeft(2, '0')}'
            'E${item.episodeNumber.toString().padLeft(2, '0')}',
      if (subtitle != null && subtitle.isNotEmpty) subtitle,
      if (airDate != null &&
          airDate.isNotEmpty &&
          (subtitle == null || !subtitle.contains(airDate)))
        airDate,
      if (item.origin == MediaOrigin.localFile)
        'Imported'
      else
        context.l10n.downloaded,
    ].join(' · ');

    return ListTile(
      leading: _OfflineArt(item: item),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: context.l10n.remove,
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(context.l10n.removeOfflineCopyTitle),
              content: Text(context.l10n.deleteFromDevice(item.title)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(context.l10n.delete),
                ),
              ],
            ),
          );
          if (ok != true || !context.mounted) return;
          await library.removeOfflineLibraryItem(item);
        },
      ),
      onTap: () => context.push('/player', extra: item),
    );
  }
}

class _OfflineArt extends StatelessWidget {
  const _OfflineArt({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final art = item.posterUrl ?? item.thumbnailUrl ?? item.backdropUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 64,
        child: art != null && art.isNotEmpty
            ? JavpArt(
                url: art,
                decodeWidth: 128,
                fallback: const ColoredBox(
                  color: AppColors.surfaceHigh,
                  child: Icon(Icons.download_done_rounded, size: 20),
                ),
              )
            : const ColoredBox(
                color: AppColors.surfaceHigh,
                child: Icon(Icons.download_done_rounded, size: 20),
              ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    // Re-read latest task fields when the queue notifies (progress mutates in place).
    final live = context
        .select<LibraryProvider, (DownloadStatus, double, String?)>((l) {
          final match = l.downloads.tasks.cast<DownloadTask?>().firstWhere(
            (t) => t?.id == task.id,
            orElse: () => task,
          );
          final t = match ?? task;
          return (t.status, t.progress, t.statusDetail);
        });
    final status = live.$1;
    final progress = live.$2;
    final statusDetail = live.$3;
    final library = context.read<LibraryProvider>();
    final airDate = catchupAirDateLabelOf(task.item);
    final itemSubtitle = task.item.subtitle?.trim();
    final subtitle = [
      statusDetail,
      itemSubtitle,
      if (airDate != null &&
          airDate.isNotEmpty &&
          (itemSubtitle == null || !itemSubtitle.contains(airDate)))
        airDate,
      status.name,
      if (status == DownloadStatus.downloading) '${(progress * 100).round()}%',
      if (task.error != null) task.error,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            status == DownloadStatus.completed
                ? Icons.download_done_rounded
                : status == DownloadStatus.failed
                ? Icons.error_outline
                : status == DownloadStatus.downloading
                ? Icons.downloading_rounded
                : status == DownloadStatus.queued
                ? Icons.hourglass_top_rounded
                : Icons.download_rounded,
            color:
                status == DownloadStatus.completed ||
                    status == DownloadStatus.downloading
                ? AppColors.accent
                : null,
          ),
          title: Text(task.item.title),
          subtitle: Text(subtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status == DownloadStatus.queued &&
                  library.downloads.waitingForWifi)
                IconButton(
                  tooltip: context.l10n.downloadAnyway,
                  icon: const Icon(Icons.network_cell),
                  onPressed: () => library.downloads.downloadAnyway(task.id),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (status == DownloadStatus.completed) {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(context.l10n.deleteDownloadTitle),
                        content: Text(
                          'Remove “${task.item.title}” from device?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(context.l10n.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(context.l10n.delete),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                  }
                  await library.downloads.remove(task.id);
                },
              ),
            ],
          ),
          onTap: status == DownloadStatus.completed
              ? () => context.push('/player', extra: task.asLocalItem())
              : status == DownloadStatus.queued &&
                    library.downloads.waitingForWifi
              ? () => library.downloads.downloadAnyway(task.id)
              : null,
        ),
        if (status == DownloadStatus.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              color: AppColors.accent,
              backgroundColor: AppColors.surfaceHigh,
            ),
          ),
      ],
    );
  }
}
