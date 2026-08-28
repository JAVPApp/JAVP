import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/live_watch_nav.dart';
import 'package:javp/services/platform/external_player.dart';
import 'package:javp/services/platform/external_player_actions.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/desktop/anchored_menu_surface.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/live_quality_picker.dart';
import 'package:provider/provider.dart';

/// Default open route for a media item (details for VOD/series, player for live).
void openMediaItem(BuildContext context, MediaItem item) {
  if (item.isLive) {
    openLivePlayback(context, item);
    return;
  }
  if (item.kind == MediaKind.catchup) {
    context.push('/player', extra: item);
    return;
  }
  // Local Open-with / imports: play the file — no rich title page.
  if (item.origin == MediaOrigin.localFile || item.kind == MediaKind.local) {
    context.push('/player', extra: item);
    return;
  }
  if (item.isSeries) {
    context.push('/series', extra: item);
    return;
  }
  if (item.isEpisode) {
    openSeriesForEpisode(context, item);
    return;
  }
  context.push('/title', extra: item);
}

/// Play when possible; series resumes the in-progress episode when available.
void playMediaItem(BuildContext context, MediaItem item) {
  if (item.isSeries) {
    final library = context.read<LibraryProvider>();
    final episode = library.resumeEpisodeForSeries(item);
    if (episode != null) {
      context.push('/player', extra: episode);
      return;
    }
    context.push('/series', extra: item);
    return;
  }
  if (item.isLive) {
    openLivePlayback(context, item);
    return;
  }
  context.push('/player', extra: item);
}

/// Continue watching: series and episodes open the episode list (Resume CTA)
/// instead of jumping into the player. Movies and other titles still play.
bool continueWatchingOpensSeries(MediaItem item) =>
    item.isSeries || item.isEpisode;

void openContinueWatchingItem(BuildContext context, MediaItem item) {
  if (item.isSeries) {
    context.push('/series', extra: item);
    return;
  }
  if (item.isEpisode) {
    openSeriesForEpisode(context, item);
    return;
  }
  playMediaItem(context, item);
}

/// Resolve and open the parent series screen for an episode row.
void openSeriesForEpisode(BuildContext context, MediaItem episode) {
  final library = context.read<LibraryProvider>();
  final series = library.seriesShellForEpisode(episode);
  if (series != null) {
    context.push('/series', extra: series);
    return;
  }
  context.push('/title', extra: episode);
}

/// Confirm dialog shared by Library's trailing delete and the item-menu
/// **Retirer** action so both hit [LibraryProvider.removeOfflineLibraryItem].
Future<bool> confirmRemoveLibraryItem(
  BuildContext context,
  MediaItem item,
) async {
  final l10n = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(l10n.remove),
      content: Text(l10n.deleteFromDevice(item.title)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Long-press action sheet for media tiles / posters.
///
/// With a mouse, [anchor] carries the click position and the same actions are
/// shown as a popover there instead of a sheet at the bottom of the window.
Future<void> showMediaItemActions({
  required BuildContext context,
  required MediaItem item,
  Offset? anchor,
  VoidCallback? onPlay,
  VoidCallback? onOpenDetails,
  VoidCallback? onPickQuality,
  VoidCallback? onStartOver,
  VoidCallback? onRemoveFromHistory,
  VoidCallback? onRemoveFromContinueWatching,
  bool showPlay = true,
  bool showDetails = true,
  bool showWatchlist = true,
  bool showFavorite = true,
  bool showDownload = true,
  bool showPlaylists = true,
}) {
  Widget content(BuildContext context) => _MediaItemActionsSheet(
    item: item,
    compact: anchor != null,
    onPlay: onPlay,
    onOpenDetails: onOpenDetails,
    onPickQuality: onPickQuality,
    onStartOver: onStartOver,
    onRemoveFromHistory: onRemoveFromHistory,
    onRemoveFromContinueWatching: onRemoveFromContinueWatching,
    showPlay: showPlay,
    showDetails: showDetails,
    showWatchlist: showWatchlist,
    showFavorite: showFavorite,
    showDownload: showDownload,
    showPlaylists: showPlaylists,
  );

  if (anchor != null && DesktopUi.enabled) {
    return showAnchoredMenuSurface<void>(
      context: context,
      globalPosition: anchor,
      builder: content,
    );
  }

  return showAppModal<void>(context: context, builder: content);
}

class _MediaItemActionsSheet extends StatelessWidget {
  const _MediaItemActionsSheet({
    required this.item,
    this.compact = false,
    this.onPlay,
    this.onOpenDetails,
    this.onPickQuality,
    this.onStartOver,
    this.onRemoveFromHistory,
    this.onRemoveFromContinueWatching,
    this.showPlay = true,
    this.showDetails = true,
    this.showWatchlist = true,
    this.showFavorite = true,
    this.showDownload = true,
    this.showPlaylists = true,
  });

  final MediaItem item;

  /// Popover presentation: no drag handle, no bottom safe-area padding.
  final bool compact;
  final VoidCallback? onPlay;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onPickQuality;
  final VoidCallback? onStartOver;
  final VoidCallback? onRemoveFromHistory;
  final VoidCallback? onRemoveFromContinueWatching;
  final bool showPlay;
  final bool showDetails;
  final bool showWatchlist;
  final bool showFavorite;
  final bool showDownload;
  final bool showPlaylists;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final title = item.isLive || item.kind == MediaKind.catchup
        ? library.liveOrCatchupDisplayTitle(item)
        : item.kind == MediaKind.vod || item.kind == MediaKind.series
        ? VodGrouping.displayTitle(item)
        : item.title;
    final subtitle = [
      if (library.sourceLabelFor(item).isNotEmpty) library.sourceLabelFor(item),
      if (item.subtitle != null && item.subtitle!.isNotEmpty)
        localizePersistedSubtitle(context.l10n, item.subtitle) ??
            item.subtitle!,
      if (item.isSeries) context.l10n.series,
      if (item.isLive) context.l10n.live,
    ].join(' · ');

    final isLive = item.isLive || item.kind == MediaKind.catchup;
    final inWatchlist = library.isInWatchlist(item);
    final isFav = isLive && library.isFavoriteChannel(item);
    final variantCount = isLive ? library.liveVariantCount(item) : 1;
    // Caller opts in via [onPickQuality], or we show when the list already
    // knows this family has multiple SD/HD/4K streams.
    final multiQuality = isLive && (onPickQuality != null || variantCount > 1);
    final now = isLive ? library.nowPlayingFor(item) : null;
    final canStartOver =
        onStartOver != null ||
        (now != null &&
            (library.liveSupportsCatchup(item) || now.hasArchive));
    final canDownload = showDownload && isDownloadActionAvailable(item);
    final canPlaylist =
        showPlaylists && !isLive && library.playlists.isNotEmpty;
    final bottom = compact ? 0.0 : MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      top: false,
      bottom: !compact,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: compact ? 14 : 0),
            if (!compact) const AppModalDragHandle(top: 10, bottom: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  _ActionArt(item: item),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (showPlay)
                    _ActionTile(
                      icon: Icons.play_arrow_rounded,
                      label: item.isSeries
                          ? (item.progress > 0.02 && item.progress < 0.95
                                ? context.l10n.resume
                                : context.l10n.openSeries)
                          : (item.progress > 0.02 && item.progress < 0.95
                                ? context.l10n.resume
                                : context.l10n.play),
                      onTap: () {
                        Navigator.pop(context);
                        if (onPlay != null) {
                          onPlay!();
                        } else {
                          playMediaItem(context, item);
                        }
                      },
                    ),
                  if (item.isSeries &&
                      item.progress > 0.02 &&
                      item.progress < 0.95)
                    _ActionTile(
                      icon: Icons.video_library_rounded,
                      label: context.l10n.openSeries,
                      onTap: () {
                        Navigator.pop(context);
                        openMediaItem(context, item);
                      },
                    ),
                  if (item.isEpisode)
                    _ActionTile(
                      icon: Icons.video_library_rounded,
                      label: context.l10n.openSeries,
                      onTap: () {
                        Navigator.pop(context);
                        openSeriesForEpisode(context, item);
                      },
                    ),
                  if (showDetails &&
                      !isLive &&
                      !item.isEpisode &&
                      item.origin != MediaOrigin.localFile &&
                      item.kind != MediaKind.local)
                    _ActionTile(
                      icon: Icons.info_outline_rounded,
                      label: context.l10n.details,
                      onTap: () {
                        Navigator.pop(context);
                        if (onOpenDetails != null) {
                          onOpenDetails!();
                        } else {
                          openMediaItem(context, item);
                        }
                      },
                    ),
                  if (showFavorite && isLive)
                    _ActionTile(
                      icon: isFav
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      label: isFav
                          ? context.l10n.removeFavorite
                          : context.l10n.favoriteChannel,
                      accent: isFav,
                      onTap: () {
                        Navigator.pop(context);
                        library.toggleFavoriteChannel(item);
                      },
                    ),
                  if (canStartOver && isLive)
                    _ActionTile(
                      icon: Icons.restart_alt_rounded,
                      label: context.l10n.startOver,
                      onTap: () {
                        Navigator.pop(context);
                        if (onStartOver != null) {
                          onStartOver!();
                          return;
                        }
                        if (now == null) return;
                        unawaited(() async {
                          final catchup = await library.catchupItemAsync(
                            channel: item,
                            program: now,
                          );
                          if (!context.mounted) return;
                          if (catchup == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  context.l10n.startOverUnavailable,
                                ),
                              ),
                            );
                            return;
                          }
                          context.push('/player', extra: catchup);
                        }());
                      },
                    ),
                  if (item.isLive &&
                      library.liveSupportsCatchup(item) &&
                      item.streamId != null)
                    _ActionTile(
                      icon: Icons.fiber_manual_record_rounded,
                      label: context.l10n.recordFromArchive,
                      onTap: () {
                        Navigator.pop(context);
                        showCatchupRecordDialog(
                          context: context,
                          channel: item,
                        );
                      },
                    ),
                  if (multiQuality)
                    _ActionTile(
                      icon: Icons.high_quality_outlined,
                      label: variantCount > 1
                          ? '${context.l10n.setPreferredQuality} · ${context.l10n.versionsCount(variantCount)}'
                          : context.l10n.setPreferredQuality,
                      onTap: () {
                        Navigator.pop(context);
                        if (onPickQuality != null) {
                          onPickQuality!();
                          return;
                        }
                        showLiveQualityPicker(context: context, channel: item);
                      },
                    ),
                  if (ExternalPlayer.canOpenItem(item))
                    _ActionTile(
                      icon: Icons.open_in_new_rounded,
                      label: context.l10n.openInExternalPlayer,
                      onTap: () {
                        Navigator.pop(context);
                        openCurrentInExternalPlayer(context, item: item);
                      },
                    ),
                  if (showWatchlist && !isLive)
                    _ActionTile(
                      icon: inWatchlist
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      label: inWatchlist
                          ? context.l10n.removeFromMyList
                          : context.l10n.myList,
                      accent: inWatchlist,
                      onTap: () {
                        Navigator.pop(context);
                        library.toggleWatchlist(item);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              inWatchlist
                                  ? context.l10n.removedFromMyList
                                  : context.l10n.addedToMyList,
                            ),
                          ),
                        );
                      },
                    ),
                  if (canDownload)
                    Builder(
                      builder: (context) {
                        final task = library.downloadTaskFor(item);
                        final presentation = downloadStatusPresentation(
                          task?.status,
                          context.l10n,
                          progress: task?.progress ?? 0,
                        );
                        return _ActionTile(
                          icon: presentation.icon,
                          label: presentation.label,
                          onTap: () {
                            Navigator.pop(context);
                            final status = task?.status;
                            if (status == DownloadStatus.completed) {
                              final local = task?.asLocalItem();
                              if (local != null) {
                                context.push('/player', extra: local);
                              }
                              return;
                            }
                            if (status == DownloadStatus.queued ||
                                status == DownloadStatus.downloading) {
                              context.push('/downloads');
                              return;
                            }
                            enqueueDownloadWithFeedback(context, library, item);
                          },
                        );
                      },
                    ),
                  if (canPlaylist)
                    _ActionTile(
                      icon: Icons.playlist_add_rounded,
                      label: context.l10n.addToPlaylist,
                      onTap: () => _pickPlaylist(context, library),
                    ),
                  if (onRemoveFromContinueWatching != null)
                    _ActionTile(
                      icon: Icons.visibility_off_outlined,
                      label: context.l10n.removeFromContinueWatching,
                      destructive: true,
                      onTap: () {
                        Navigator.pop(context);
                        onRemoveFromContinueWatching!();
                      },
                    ),
                  if (onRemoveFromHistory != null)
                    _ActionTile(
                      icon: Icons.delete_outline_rounded,
                      label: context.l10n.removeFromHistory,
                      destructive: true,
                      onTap: () {
                        Navigator.pop(context);
                        onRemoveFromHistory!();
                      },
                    ),
                  if (library.isRemovableLibraryItem(item) &&
                      onRemoveFromHistory == null &&
                      onRemoveFromContinueWatching == null)
                    _ActionTile(
                      icon: Icons.delete_outline_rounded,
                      label: context.l10n.remove,
                      destructive: true,
                      onTap: () async {
                        // Confirm while the menu context is still mounted
                        // (same pattern as playlist pick). Popping the
                        // anchored desktop dialog first left showDialog with
                        // a dead context — Retirer never reached remove.
                        final ok = await confirmRemoveLibraryItem(
                          context,
                          item,
                        );
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        if (!ok) return;
                        await library.removeOfflineLibraryItem(item);
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPlaylist(
    BuildContext context,
    LibraryProvider library,
  ) async {
    final playlists = library.playlists;
    final chosen = await showAppModal<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  context.l10n.addToPlaylist,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final p in playlists)
                ListTile(
                  leading: const Icon(Icons.playlist_play_rounded),
                  title: Text(p.name),
                  subtitle: Text(context.l10n.nTitles(p.mediaItemIds.length)),
                  onTap: () => Navigator.pop(context, p.id),
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    // Close the actions sheet if still open.
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
    await library.addToPlaylist(chosen, item.id);
    if (!context.mounted) return;
    String name = 'playlist';
    for (final p in playlists) {
      if (p.id == chosen) {
        name = p.name;
        break;
      }
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.addedToName(name))));
  }
}

class _ActionArt extends StatelessWidget {
  const _ActionArt({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final moviePortrait = context.select<LibraryProvider, bool>(
      (l) => l.displaySettings.moviesCoverGridPortrait,
    );
    final portrait = !item.isLive && moviePortrait;
    final art = item.artUrlFor(portrait: portrait) ?? item.thumbnailUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: portrait ? 44 : 72,
        height: portrait ? 66 : 40,
        child: DecoratedBox(
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
          child: art == null || art.isEmpty
              ? Icon(
                  item.isLive
                      ? Icons.sensors_rounded
                      : item.isSeries
                      ? Icons.video_library_rounded
                      : Icons.movie_outlined,
                  color: AppColors.textMuted,
                  size: 22,
                )
              : JavpArt(url: art, decodeWidth: portrait ? 88 : 144),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? AppColors.accent
        : accent
        ? AppColors.accent
        : AppColors.text;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }
}
