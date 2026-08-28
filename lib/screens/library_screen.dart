import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Widget? _frozenTree;
  Object? _frozenStamp;

  @override
  Widget build(BuildContext context) {
    final shellActive = ShellVisibility.isActive(context);
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);

    // Coarse download identity — status buckets, not float progress — so
    // in-progress downloads do not rebuild the whole Library list every tick.
    final stamp = context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.localMedia.length,
        identityHashCode(l.localMedia),
        l.catalog.length,
        l.downloads.activeCount,
        l.downloads.waitingForWifi,
        l.downloads.tasks.length,
        l.displaySettings.moviesCoverOrientation,
        l.sourcesAppearanceRevision,
        Object.hashAll(
          l.downloads.tasks.map(
            (t) => Object.hash(t.id, t.status, (t.progress * 10).floor()),
          ),
        ),
      ),
    );

    // Shell tab hidden: keep Element tree; SkipLayout skips layout/paint.
    Widget keep(Widget child) =>
        keepShellTabTree(skip: shellActive && covered, child: child);

    if (!shellActive) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }
    // Player covering this branch: skip layout/paint but keep the Element tree.
    if (covered) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }

    if (_frozenTree != null && _frozenStamp == stamp) {
      return keep(_frozenTree!);
    }

    final library = context.read<LibraryProvider>();
    final seen = <String>{};
    final items = <MediaItem>[
      for (final m in library.localMedia)
        if (!m.isRadioStation && seen.add(m.id)) m,
      for (final m in library.downloads.completedItems)
        if (seen.add(m.id)) m,
    ];
    final moviePortrait = library.displaySettings.resolveMoviesCoverPortrait(
      items,
    );
    final active = library.downloads.activeCount;
    final offlineCount = library.offlineLibraryItems.length;
    final downloadsSubtitle = library.downloads.waitingForWifi
        ? context.l10n.waitingForWifi
        : active > 0
        ? '$active downloading'
        : offlineCount > 0
        ? '$offlineCount available offline'
        : context.l10n.offlineCopiesAndQueue;

    final tree = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(context.l10n.navLibrary),
        actions: [
          if (TvPlatform.isAndroidTv) ...[
            TvFocusable(
              borderRadius: 24,
              onSelect: () => context.push('/downloads'),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Badge(
                  isLabelVisible: active > 0 || offlineCount > 0,
                  label: active > 0 ? Text('$active') : Text('$offlineCount'),
                  child: const Icon(Icons.download_outlined),
                ),
              ),
            ),
            if (AppCapabilities.torrents)
              TvFocusable(
                borderRadius: 24,
                onSelect: () => _addMagnet(context),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.bolt_rounded),
                ),
              ),
            TvFocusable(
              borderRadius: 24,
              onSelect: () => _addUrl(context),
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.link_rounded),
              ),
            ),
          ] else ...[
            IconButton(
              tooltip: context.l10n.downloads,
              onPressed: () => context.push('/downloads'),
              icon: Badge(
                isLabelVisible: active > 0 || offlineCount > 0,
                label: active > 0 ? Text('$active') : Text('$offlineCount'),
                child: Icon(Icons.download_outlined),
              ),
            ),
            if (AppCapabilities.torrents)
              IconButton(
                tooltip: context.l10n.addMagnet,
                onPressed: () => _addMagnet(context),
                icon: const Icon(Icons.bolt_rounded),
              ),
            IconButton(
              tooltip: context.l10n.addUrl,
              onPressed: () => _addUrl(context),
              icon: const Icon(Icons.link_rounded),
            ),
            if (AppCapabilities.localFilePicker)
              IconButton(
                tooltip: context.l10n.importFiles,
                onPressed: () => library.importLocalFiles(),
                icon: const Icon(Icons.folder_open_rounded),
              ),
          ],
        ],
      ),
      body: DesktopPane(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(
                Icons.bookmarks_outlined,
                color: AppColors.accent,
              ),
              title: Text(context.l10n.myList),
              subtitle: Text(context.l10n.savedForLater),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/mylist'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(
                Icons.download_outlined,
                color: AppColors.accent,
              ),
              title: Text(context.l10n.downloads),
              subtitle: Text(downloadsSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/downloads'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(
                Icons.radio_outlined,
                color: AppColors.accent,
              ),
              title: Text(context.l10n.navMusic),
              subtitle: Text(context.l10n.musicLibrarySubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.go('/music'),
            ),
            const Divider(height: 1),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.video_library_outlined,
                              size: 52,
                              color: AppColors.textMuted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              context.l10n.emptyLibraryHint,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: AppColors.text),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            if (AppCapabilities.localFilePicker) ...[
                              FilledButton.icon(
                                onPressed: () => library.importLocalFiles(),
                                icon: const Icon(Icons.file_open_rounded),
                                label: Text(context.l10n.importVideos),
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (AppCapabilities.torrents)
                              OutlinedButton.icon(
                                onPressed: () => _addMagnet(context),
                                icon: const Icon(Icons.bolt_rounded),
                                label: Text(context.l10n.addMagnetOrTorrent),
                              ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: items.length + 1,
                      itemBuilder: (context, index) {
                        if (index >= items.length) {
                          return const MiniPlayerScrollClearance();
                        }
                        final item = items[index];
                        final offline =
                            item.origin == MediaOrigin.download ||
                            item.kind == MediaKind.local ||
                            item.origin == MediaOrigin.localFile;
                        final canDownload = isDownloadActionAvailable(item);
                        return MediaTile(
                          item: item,
                          sourceLabel: offline
                              ? context.l10n.offline
                              : library.sourceLabelFor(item),
                          onTap: () {
                            if (offline) {
                              context.push('/player', extra: item);
                              return;
                            }
                            context.push('/title', extra: item);
                          },
                          portrait: moviePortrait,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (canDownload) DownloadStatusButton(item: item),
                              IconButton(
                                tooltip: context.l10n.remove,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    _confirmRemoveLibraryItem(context, item),
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
    );
    _frozenTree = tree;
    _frozenStamp = stamp;
    return keep(tree);
  }

  Future<void> _confirmRemoveLibraryItem(
    BuildContext context,
    MediaItem item,
  ) async {
    final ok = await confirmRemoveLibraryItem(context, item);
    if (!ok || !context.mounted) return;
    await context.read<LibraryProvider>().removeOfflineLibraryItem(item);
  }

  Future<void> _addUrl(BuildContext context) async {
    final titleController = TextEditingController();
    final urlController = TextEditingController();
    final library = context.read<LibraryProvider>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(context.l10n.addStreamUrl),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              JavpTextField(
                controller: titleController,
                decoration: InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 10),
              PlainTextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: context.l10n.url,
                  hintText: 'https://…/stream.m3u8',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.add),
            ),
          ],
        );
      },
    );

    if (ok == true && urlController.text.trim().isNotEmpty) {
      await library.addNetworkUrl(
        title: titleController.text,
        url: urlController.text,
      );
    }
  }

  Future<void> _addMagnet(BuildContext context) async {
    final titleController = TextEditingController();
    final magnetController = TextEditingController();
    final library = context.read<LibraryProvider>();

    final action = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(context.l10n.addTorrent),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.addTorrentHelp,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                JavpTextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: context.l10n.titleOptional,
                  ),
                ),
                const SizedBox(height: 10),
                PlainTextField(
                  controller: magnetController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: context.l10n.magnetLink,
                    hintText: 'magnet:?xt=urn:btih:…',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'file'),
              child: Text(context.l10n.pickTorrent),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'magnet'),
              child: Text(context.l10n.addMagnet),
            ),
          ],
        );
      },
    );

    if (action == 'magnet' && magnetController.text.trim().isNotEmpty) {
      final item = await library.addTorrent(
        title: titleController.text,
        magnetOrPath: magnetController.text,
      );
      if (context.mounted) context.push('/player', extra: item);
      return;
    }

    if (action == 'file') {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['torrent'],
      );
      final path = picked?.files.single.path;
      if (path == null || path.isEmpty) return;
      final item = await library.addTorrent(
        title: titleController.text,
        magnetOrPath: path,
      );
      if (context.mounted) context.push('/player', extra: item);
    }
  }
}
