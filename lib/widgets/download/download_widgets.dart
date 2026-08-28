import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:provider/provider.dart';

void showDownloadSnackBar(
  BuildContext context, {
  required String message,
  bool showView = true,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      // With an action present, SnackBar defaults to persistent (never
      // auto-dismisses). Force the standard timeout so "Download queued"
      // and similar transient notices still disappear on their own.
      persist: false,
      action: showView
          ? SnackBarAction(
              label: context.l10n.viewAction,
              onPressed: () => context.push('/downloads'),
            )
          : null,
    ),
  );
}

Future<MediaItem?> pickVodDownloadEdition({
  required BuildContext context,
  required LibraryProvider library,
  required MediaItem item,
}) async {
  if (item.isLive ||
      item.kind == MediaKind.catchup ||
      item.isEpisode ||
      item.isSeries) {
    return item;
  }
  final layout = library.vodFamilyLayoutFor(item);
  final editions = layout.editions;
  if (editions.length <= 1) {
    return editions.isEmpty ? item : editions.first;
  }
  final prefs = context.read<LocaleController>().preferredContentLanguageCodes;
  return showAppModal<MediaItem>(
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
                context.l10n.chooseVersion,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final edition in editions)
              ListTile(
                title: Text(
                  VodGrouping.editionDownloadLabel(
                    edition,
                    sourceLabel: layout.hasMultipleSources
                        ? library.sourceLabelFor(edition)
                        : null,
                    preferredLangs: prefs,
                  ),
                ),
                selected: edition.id == item.id,
                onTap: () => Navigator.pop(context, edition),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> enqueueDownloadWithFeedback(
  BuildContext context,
  LibraryProvider library,
  MediaItem item,
) async {
  // Catchup play URLs are unpadded; route through the pad dialog / padded
  // enqueue so offline files include the configured lead-in/outro.
  // Without a guide entry, ask for an explicit wall-clock window instead of
  // silently downloading the open clip.
  if (item.kind == MediaKind.catchup) {
    final channel = library.liveChannelForCatchup(item);
    final program = library.programForCatchup(item);
    if (channel != null && program != null) {
      await showDvrDownloadPadDialog(
        context: context,
        channel: channel,
        program: program,
      );
      return;
    }
    if (channel != null && library.liveSupportsCatchup(channel)) {
      await showCatchupRecordDialog(
        context: context,
        channel: channel,
        initialStart: LibraryProvider.catchupStartOf(item),
        initialDurationMin: item.duration?.inMinutes,
        initialTitle: item.title,
      );
      return;
    }
    final ok = await library.enqueueCatchupDownloadForClip(item);
    if (!context.mounted) return;
    showDownloadSnackBar(
      context,
      message: ok
          ? context.l10n.downloadQueuedSeeLibrary
          : context.l10n.downloadNotAvailable,
      showView: ok,
    );
    return;
  }

  final chosen = await pickVodDownloadEdition(
    context: context,
    library: library,
    item: item,
  );
  if (chosen == null || !context.mounted) return;

  final ok = await library.enqueueDownload(chosen);
  if (!context.mounted) return;
  showDownloadSnackBar(
    context,
    message: ok
        ? context.l10n.downloadQueued
        : context.l10n.downloadNotAvailable,
    showView: ok,
  );
}

Future<void> enqueueDownloadsWithFeedback(
  BuildContext context,
  LibraryProvider library,
  Future<int> Function() enqueue, {
  String singular = 'download',
  String plural = 'downloads',
}) async {
  final n = await enqueue();
  if (!context.mounted) return;
  if (n <= 0) {
    showDownloadSnackBar(
      context,
      message: context.l10n.nothingNewToDownload,
      showView: false,
    );
    return;
  }
  showDownloadSnackBar(
    context,
    message: n == 1
        ? context.l10n.queuedOneDownload
        : context.l10n.queuedNDownloads('$n'),
  );
}

/// Whether a per-item offline download control should be shown.
///
/// Excludes live channels and series shells; catchup / VOD / magnets that
/// [DownloadManager.isEligible] accepts are included.
bool isDownloadActionAvailable(MediaItem item) {
  if (item.isLive || item.isSeries) return false;
  if (item.kind == MediaKind.local) return false;
  return DownloadManager.isEligible(item, item.playUrl);
}

/// Visual + label helpers shared by icon buttons and outlined actions.
({IconData icon, String label, Color? color, double? progress})
downloadStatusPresentation(
  DownloadStatus? status,
  AppLocalizations l10n, {
  double progress = 0,
}) {
  return switch (status) {
    DownloadStatus.downloading => (
      icon: Icons.downloading_rounded,
      label: progress > 0
          ? l10n.downloadingPercent((progress * 100).round())
          : l10n.downloadingEllipsis,
      color: AppColors.accent,
      progress: progress > 0 ? progress : null,
    ),
    DownloadStatus.queued => (
      icon: Icons.hourglass_top_rounded,
      label: l10n.queued,
      color: AppColors.textMuted,
      progress: null,
    ),
    DownloadStatus.completed => (
      icon: Icons.download_done_rounded,
      label: l10n.downloaded,
      color: AppColors.accent,
      progress: null,
    ),
    DownloadStatus.failed => (
      icon: Icons.error_outline,
      label: l10n.retryDownload,
      color: Colors.orangeAccent,
      progress: null,
    ),
    DownloadStatus.paused || null => (
      icon: Icons.download_rounded,
      label: l10n.download,
      color: null,
      progress: null,
    ),
  };
}

class DownloadStatusButton extends StatelessWidget {
  const DownloadStatusButton({
    super.key,
    required this.item,
    this.onEnqueue,
    this.tooltip = 'Download',
    this.outlined = false,
    this.foregroundColor,
  });

  final MediaItem item;
  final Future<void> Function()? onEnqueue;
  final String tooltip;

  /// When true, render an [OutlinedButton.icon] (title detail actions).
  final bool outlined;

  /// Override icon color when status has no accent (e.g. white on player chrome).
  final Color? foregroundColor;

  Future<void> _activate(
    BuildContext context,
    LibraryProvider library,
    DownloadTask? task,
    DownloadStatus? status,
  ) async {
    switch (status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        context.push('/downloads');
        return;
      case DownloadStatus.completed:
        final local = task?.asLocalItem();
        if (local != null) context.push('/player', extra: local);
        return;
      case DownloadStatus.failed:
      case DownloadStatus.paused:
      case null:
        if (onEnqueue != null) {
          await onEnqueue!();
        } else {
          await enqueueDownloadWithFeedback(context, library, item);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    // Listen to DownloadManager directly. LibraryProvider coalesces download
    // ticks (and swallows them while catalog hydrate latches `_uiQuiet`), so
    // `context.select` on the library never repaints episode icons until the
    // series page is remounted.
    return ListenableBuilder(
      listenable: library.downloads,
      builder: (context, _) {
        final task = library.downloadTaskFor(item);
        final status = task?.status;
        final progress = task?.progress ?? 0;
        final l10n = context.l10n;
        final presentation = downloadStatusPresentation(
          status,
          l10n,
          progress: progress,
        );

        final iconColor = presentation.color ?? foregroundColor;

        if (outlined) {
          return OutlinedButton.icon(
            key: ValueKey('dl-btn-${item.id}-${status?.name ?? 'none'}'),
            onPressed: () => _activate(context, library, task, status),
            icon: status == DownloadStatus.downloading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: presentation.progress,
                      color: AppColors.accent,
                    ),
                  )
                : Icon(presentation.icon, color: iconColor),
            label: Text(presentation.label),
          );
        }

        if (status == DownloadStatus.downloading) {
          return IconButton(
            key: ValueKey('dl-prog-${item.id}'),
            tooltip: presentation.label,
            onPressed: () => _activate(context, library, task, status),
            icon: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: presentation.progress,
                color: AppColors.accent,
              ),
            ),
          );
        }

        return IconButton(
          key: ValueKey('dl-icon-${item.id}-${status?.name ?? 'none'}'),
          tooltip: presentation.label == l10n.download
              ? tooltip
              : presentation.label,
          onPressed: () => _activate(context, library, task, status),
          icon: Icon(presentation.icon, color: iconColor),
        );
      },
    );
  }
}
