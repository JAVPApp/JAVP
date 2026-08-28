import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/live_watch_nav.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/category_chips.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/widgets/iptv_search_bar.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/live_channel_list.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/media_tile.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Live radio / audio streams — pasted URLs plus Radio/Music groups from sources.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  static const _chipAll = '__all__';
  static const _chipYours = '__yours__';

  final _search = TextEditingController();
  String _chip = _chipAll;
  List<MediaItem> _sourceStations = const [];
  Object? _sourceStamp;
  bool _loadingSources = false;
  int _sourceGen = 0;
  Widget? _frozenTree;
  Object? _frozenStamp;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Object _listStamp(LibraryProvider library) => Object.hash(
    library.localMedia.length,
    identityHashCode(library.localMedia),
    library.liveDbRevision,
    library.sourcesEnabledRevision,
    _chip,
    _search.text,
    _sourceStations.length,
    _loadingSources,
  );

  Future<void> _reloadSources(LibraryProvider library) async {
    final stamp = Object.hash(
      library.liveDbRevision,
      library.sourcesEnabledRevision,
      Object.hashAll(library.radioLiveGroupNames),
    );
    if (stamp == _sourceStamp || _loadingSources) return;
    final gen = ++_sourceGen;
    setState(() => _loadingSources = true);
    final names = library.radioLiveGroupNames.toList()..sort();
    final out = <MediaItem>[];
    final seen = <String>{};
    var remaining = 200;
    for (final name in names) {
      if (remaining <= 0) break;
      final page = await library.pageLiveChannels(
        groupName: name,
        limit: remaining.clamp(1, 80),
      );
      for (final item in page) {
        if (!seen.add(item.id)) continue;
        out.add(item);
        remaining--;
        if (remaining <= 0) break;
      }
    }
    if (!mounted || gen != _sourceGen) return;
    setState(() {
      _sourceStamp = stamp;
      _sourceStations = out;
      _loadingSources = false;
    });
  }

  List<MediaItem> _visibleStations(LibraryProvider library) {
    final yours = library.localRadioStations;
    final Iterable<MediaItem> base;
    if (_chip == _chipYours) {
      base = yours;
    } else if (_chip == _chipAll) {
      final seen = {for (final m in yours) m.id};
      base = [...yours, ..._sourceStations.where((m) => seen.add(m.id))];
    } else {
      base = _sourceStations.where((m) => (m.group ?? '') == _chip);
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return base.toList();
    return [
      for (final m in base)
        if (m.title.toLowerCase().contains(q) ||
            (m.group ?? '').toLowerCase().contains(q) ||
            m.playUrl.toLowerCase().contains(q))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shellActive = ShellVisibility.isActive(context);
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);
    Widget keep(Widget child) =>
        keepShellTabTree(skip: shellActive && covered, child: child);

    if (!shellActive) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }
    if (covered) {
      return keep(_frozenTree ?? const SizedBox.expand());
    }

    final library = context.watch<LibraryProvider>();
    final stamp = _listStamp(library);
    if (_frozenTree != null && _frozenStamp == stamp) {
      return keep(_frozenTree!);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reloadSources(library);
    });

    final l10n = context.l10n;
    final groups = library.radioLiveGroupNames.toList()..sort();
    final chipLabels = <String>[l10n.all, l10n.musicYourStations, ...groups];
    final selectedChip = switch (_chip) {
      _chipAll => l10n.all,
      _chipYours => l10n.musicYourStations,
      _ => _chip,
    };
    final stations = _visibleStations(library);

    final tree = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.navMusic),
        actions: [
          if (TvPlatform.isAndroidTv) ...[
            TvFocusable(
              borderRadius: 24,
              onSelect: () => _addUrl(context),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.add_rounded),
              ),
            ),
            TvFocusable(
              borderRadius: 24,
              onSelect: () => context.push('/sources'),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.dns_outlined),
              ),
            ),
          ] else ...[
            IconButton(
              tooltip: l10n.addRadioStream,
              onPressed: () => _addUrl(context),
              icon: const Icon(Icons.add_rounded),
            ),
            IconButton(
              tooltip: l10n.manageSources,
              onPressed: () => context.push('/sources'),
              icon: const Icon(Icons.dns_outlined),
            ),
          ],
        ],
      ),
      body: DesktopPane(
        child: Column(
          children: [
            IptvSearchBar(
              controller: _search,
              hintText: l10n.searchChannels,
              onChanged: (_) => setState(() {}),
              onClear: () => setState(() {}),
            ),
            const SizedBox(height: 8),
            CategoryChips(
              labels: chipLabels,
              selected: selectedChip,
              onSelected: (label) {
                setState(() {
                  if (label == l10n.all) {
                    _chip = _chipAll;
                  } else if (label == l10n.musicYourStations) {
                    _chip = _chipYours;
                  } else {
                    _chip = label;
                  }
                });
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: stations.isEmpty
                  ? (_loadingSources
                        ? const Center(child: CircularProgressIndicator())
                        : _MusicEmpty(onAdd: () => _addUrl(context)))
                  : LiveChannelList(
                      itemCount: stations.length,
                      padding: const EdgeInsets.only(
                        bottom: AppLayout.dockedBottomInset,
                      ),
                      itemBuilder: (context, index) {
                        final item = stations[index];
                        final subtitle = localizePersistedSubtitle(
                          l10n,
                          item.subtitle,
                        );
                        return MediaTile(
                          item: item.copyWith(subtitle: subtitle),
                          sourceLabel: library.sourceLabelFor(item),
                          onTap: () => openLivePlayback(context, item),
                          trailing: library.isRemovableLibraryItem(item)
                              ? IconButton(
                                  tooltip: l10n.remove,
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await confirmRemoveLibraryItem(
                                      context,
                                      item,
                                    );
                                    if (!ok || !context.mounted) return;
                                    await context
                                        .read<LibraryProvider>()
                                        .removeOfflineLibraryItem(item);
                                  },
                                )
                              : null,
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

  Future<void> _addUrl(BuildContext context) async {
    final titleController = TextEditingController();
    final urlController = TextEditingController();
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(l10n.addRadioStream),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              JavpTextField(
                controller: titleController,
                decoration: InputDecoration(labelText: l10n.name),
              ),
              const SizedBox(height: 10),
              PlainTextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.url,
                  hintText: l10n.addRadioUrlHint,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.add),
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
}

class _MusicEmpty extends StatelessWidget {
  const _MusicEmpty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.radio_outlined,
              size: 52,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.emptyMusicHint,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: AppColors.text),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.addRadioStream),
            ),
          ],
        ),
      ),
    );
  }
}
