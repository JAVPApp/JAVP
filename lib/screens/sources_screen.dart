import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_epg_input.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/platform/web_app_limitation.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/screens/tv/tv_pairing_screen.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';
import 'package:javp/services/local_source_path.dart';
import 'package:javp/services/media_server/plex_account_client.dart';
import 'package:javp/services/media_server/plex_client.dart';
import 'package:javp/services/network/fallback_http_client.dart';
import 'package:javp/services/platform/external_browser.dart';
import 'package:javp/services/source_content_sniff.dart';
import 'package:javp/services/source_list_summary.dart';
import 'package:javp/services/iptv/xtream_url_detect.dart';
import 'package:javp/screens/settings/settings_guide_widgets.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/parental_unlock.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:javp/widgets/live_epg_source_picker.dart';
import 'package:javp/widgets/source_color_picker.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:provider/provider.dart';

/// Extra list padding so the last source clears the extended FAB.
///
/// Dock / system inset comes from [MediaQuery.padding] (inflated by
/// [PersistentMiniPlayer] for the whole playback session).
const _sourcesFabClearance = 100.0;

const _catalogApiDocsUrl = 'https://javp.app/catalog-api.html';

enum _LocationInputMode { url, file }

/// Shared add-source picker (two-step: pick type → credentials).
/// Returns `true` if a source was saved and synced.
///
/// Phone: modal bottom sheet. Desktop: centred dialog so a wide window is
/// not a stretched phone sheet with no close control.
///
/// When [prefill] is set (deep link), skips the type picker and fills fields.
Future<bool> showAddSourceSheet(
  BuildContext context, {
  JavpSourceAddRequest? prefill,
}) async {
  if (!await ensureParentalUnlockedForSources(context)) return false;
  if (!context.mounted) return false;
  return _showSourceSheet(context, prefill: prefill);
}

/// Edit an existing source’s connection details (same form as add).
Future<bool> showEditSourceSheet(
  BuildContext context,
  IptvSource source,
) async {
  if (!await ensureParentalUnlockedForSources(context)) return false;
  if (!context.mounted) return false;
  return _showSourceSheet(context, editing: source);
}

@visibleForTesting
const addSourceCloseButtonKey = Key('addSourceClose');

Future<bool> _showSourceSheet(
  BuildContext context, {
  JavpSourceAddRequest? prefill,
  IptvSource? editing,
}) async {
  // PopScope alone does not stop sheet drag / barrier dismiss — lock those
  // so a save-in-flight cannot recreate the blank-gap race this PR closes.
  // System back / the close button still go through PopScope (blocked only
  // while _saving).
  final desktop = DesktopUi.enabled && !TvPlatform.isAndroidTv;
  final result = await showAppModal<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (context) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, desktop ? 8 : 12, 16, 24),
        child: _AddSourceForm(prefill: prefill, editing: editing),
      );
    },
  );
  return result ?? false;
}

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  bool _reordering = false;
  bool _pausedIdle = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pausedIdle) return;
    _pausedIdle = true;
    // Opening Sources during idle/M3U sync used to keep Home + overlay both
    // live on the UI isolate. Drop queued idle jobs; a manual Sync continues.
    context.read<LibraryProvider>().pauseOpportunisticIdle(
      reason: 'sources-open',
    );
  }

  void _leaveSources(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      // Deep-link / cold open often lands here with an empty stack — don't
      // finish the Activity back to the browser.
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sources cares about the source list, colors/names — not global
    // [LibraryProvider.loading] (Drive/profile sync used to rebuild this
    // page on every tick and hitch Windows).
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        identityHashCode(l.sources),
        l.sources.length,
        l.sourcesEnabledRevision,
        l.sourcesAppearanceRevision,
        l.error,
        l.parentalLock?.lockFilterStamp,
      ),
    );
    context.select<ParentalLockProvider, String>((p) => p.lockFilterStamp);
    final library = context.read<LibraryProvider>();
    final visibleSources = library.parentalVisibleSources;
    final canReorder = visibleSources.length > 1;
    if (!canReorder && _reordering) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reordering) setState(() => _reordering = false);
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leaveSources(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.sources),
          leading: IconButton(
            tooltip: context.l10n.back,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => _leaveSources(context),
          ),
          actions: [
            if (canReorder)
              IconButton(
                key: const Key('reorderSources'),
                tooltip: _reordering
                    ? context.l10n.doneReordering
                    : context.l10n.reorderSources,
                icon: Icon(
                  _reordering ? Icons.check_rounded : Icons.swap_vert_rounded,
                ),
                onPressed: () => setState(() => _reordering = !_reordering),
              ),
          ],
        ),
        floatingActionButton: TvPlatform.isAndroidTv
            ? TvFocusable(
                autofocus: visibleSources.isEmpty,
                borderRadius: 28,
                onSelect: () => _tvAddSourceAction(context),
                child: Material(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add_rounded, color: Colors.white),
                        const SizedBox(width: 10),
                        Text(
                          context.l10n.addSource,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : FloatingActionButton.extended(
                onPressed: () async {
                  await showAddSourceSheet(context);
                },
                icon: const Icon(Icons.add_rounded),
                label: Text(context.l10n.addSource),
              ),
        body: DesktopPane(
          child: visibleSources.isEmpty
              ? ListView(
                  padding: AppLayout.pagePadding(
                    bottom:
                        _sourcesFabClearance +
                        MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    if (WebAppLimitation.httpSourcesBanner(
                          context: context,
                          sources: library.sources,
                        )
                        case final webBanner?) ...[
                      Transform.translate(
                        offset: const Offset(-16, 0),
                        child: SizedBox(
                          width: MediaQuery.sizeOf(context).width,
                          child: webBanner,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      context.l10n.sourcesBlurb,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    if (library.error != null)
                      _SourcesErrorBanner(message: library.error!),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        context.l10n.noSourcesYet,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ],
                )
              : _SourcesListView(library: library, reordering: _reordering),
        ),
      ),
    );
  }
}

/// TV: choose phone pairing or typing a source on the TV itself.
Future<void> _tvAddSourceAction(BuildContext context) async {
  if (!await ensureParentalUnlockedForSources(context)) return;
  if (!context.mounted) return;
  final l10n = context.l10n;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: AppColors.surface,
      title: Text(l10n.addSource),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'pair'),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.qr_code_2_rounded,
              color: AppColors.accent,
            ),
            title: Text(l10n.devicePairTitle),
            subtitle: Text(l10n.devicePairShowQrBlurb),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'manual'),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_rounded, color: AppColors.accent),
            title: Text(l10n.devicePairAddOnTv),
            subtitle: Text(l10n.devicePairAddOnTvBlurb),
          ),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'pair') {
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => const TvPairingScreen()));
    return;
  }
  await showAddSourceSheet(context);
}

/// Source cards plus the how-to header. On TV the header is focusable so D-pad
/// Up from the first source can scroll the instructions back into view.
class _SourcesListView extends StatefulWidget {
  const _SourcesListView({required this.library, required this.reordering});

  final LibraryProvider library;
  final bool reordering;

  @override
  State<_SourcesListView> createState() => _SourcesListViewState();
}

class _SourcesListViewState extends State<_SourcesListView> {
  final _scroll = ScrollController();
  final _headerFocus = FocusNode(debugLabel: 'sourcesHeader');
  final _scope = FocusScopeNode(
    debugLabel: 'sourcesList',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  @override
  void dispose() {
    _scroll.dispose();
    _headerFocus.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _revealHeader() {
    void jump() {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    }

    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
  }

  KeyEventResult _onFirstSourceUp(FocusNode node, KeyEvent event) {
    if (!TvPlatform.isAndroidTv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    _headerFocus.requestFocus();
    _revealHeader();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final tv = TvPlatform.isAndroidTv;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (WebAppLimitation.httpSourcesBanner(
              context: context,
              sources: library.sources,
              onDismissed: () => setState(() {}),
            )
            case final webBanner?) ...[
          // Banner already has outer margin; tighten for list header.
          Transform.translate(offset: const Offset(0, -8), child: webBanner),
          const SizedBox(height: 8),
        ],
        Text(
          context.l10n.sourcesBlurb,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (widget.reordering) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.sourcesOrderHint,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 16),
        if (library.error != null) _SourcesErrorBanner(message: library.error!),
      ],
    );

    return FocusScope(
      node: _scope,
      child: ReorderableListView(
        buildDefaultDragHandles: false,
        scrollController: _scroll,
        padding: AppLayout.pagePadding(
          bottom: _sourcesFabClearance + MediaQuery.paddingOf(context).bottom,
        ),
        header: tv
            ? Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TvFocusable(
                  focusNode: _headerFocus,
                  autofocus: true,
                  borderRadius: 12,
                  onFocusChange: (focused) {
                    if (focused) _revealHeader();
                  },
                  child: header,
                ),
              )
            : header,
        onReorderItem: (oldIndex, newIndex) {
          unawaited(library.reorderSources(oldIndex, newIndex));
        },
        children: [
          for (var i = 0; i < library.sources.length; i++)
            ListenableBuilder(
              key: ValueKey(library.sources[i].id),
              listenable: library.syncStatusListenable,
              builder: (context, _) => _SourceCard(
                source: library.sources[i],
                index: i,
                total: library.sources.length,
                reordering: widget.reordering,
                busy: library.isSourceSyncActivity(library.sources[i].id),
                status: library.syncStatusFor(library.sources[i].id),
                onTvUpFromStart: i == 0 && tv ? _onFirstSourceUp : null,
                onSync: () {
                  final src = library.sources[i];
                  // T0 for hwnd focus-death forensics — must log *before*
                  // syncSource so the click is visible even if Sync queues.
                  HwndSyncTrace.clickSync(
                    sourceId: src.id,
                    sourceName: src.name,
                    reason: 'manual',
                  );
                  unawaited(
                    library.syncSource(
                      src.id,
                      refreshVod: true,
                      blockUi: false,
                      reason: 'manual',
                    ),
                  );
                },
                onEdit: () => showEditSourceSheet(context, library.sources[i]),
                onRename: () =>
                    _renameSource(context, library, library.sources[i]),
                onMoveUp: i > 0
                    ? () => unawaited(
                        library.moveSourceEarlier(library.sources[i].id),
                      )
                    : null,
                onMoveDown: i < library.sources.length - 1
                    ? () => unawaited(
                        library.moveSourceLater(library.sources[i].id),
                      )
                    : null,
                onDelete: () =>
                    _deleteSource(context, library, library.sources[i]),
                onEnabledChanged: (enabled) =>
                    library.setSourceEnabled(library.sources[i].id, enabled),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourcesErrorBanner extends StatelessWidget {
  const _SourcesErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Text(message, style: const TextStyle(color: AppColors.text)),
    );
  }
}

Future<void> _deleteSource(
  BuildContext context,
  LibraryProvider library,
  IptvSource source,
) async {
  if (!await ensureParentalUnlockedForSources(context)) return;
  if (!context.mounted) return;
  await library.removeSource(source.id);
}

Future<void> _renameSource(
  BuildContext context,
  LibraryProvider library,
  IptvSource source,
) async {
  if (!await ensureParentalUnlockedForSources(context)) return;
  if (!context.mounted) return;
  final controller = TextEditingController(text: source.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.renameSource),
      content: JavpTextField(
        controller: controller,
        decoration: InputDecoration(labelText: context.l10n.name),
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        AppActionButton(
          variant: AppActionButtonVariant.text,
          onPressed: () => Navigator.pop(context),
          label: context.l10n.cancel,
        ),
        AppActionButton(
          onPressed: () => Navigator.pop(context, controller.text),
          label: context.l10n.save,
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || !context.mounted) return;
  await library.renameSource(source.id, name);
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    super.key,
    required this.source,
    required this.index,
    required this.total,
    required this.reordering,
    required this.busy,
    required this.onSync,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
    required this.onEnabledChanged,
    this.onMoveUp,
    this.onMoveDown,
    this.onTvUpFromStart,
    this.status,
  });

  final IptvSource source;
  final int index;
  final int total;
  final bool reordering;
  final bool busy;
  final String? status;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final KeyEventResult Function(FocusNode, KeyEvent)? onTvUpFromStart;

  IconData get _typeIcon => switch (source.type) {
    IptvSourceType.m3u => Icons.playlist_play_rounded,
    IptvSourceType.xtream => Icons.cloud_outlined,
    IptvSourceType.stalker => Icons.router_outlined,
    IptvSourceType.custom => Icons.data_object_rounded,
    IptvSourceType.jellyfin => Icons.dashboard_customize_outlined,
    IptvSourceType.emby => Icons.live_tv_outlined,
    IptvSourceType.plex => Icons.grid_view_rounded,
    IptvSourceType.xmltv => Icons.event_note_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final isTv = TvPlatform.isAndroidTv;
    final enabled = source.enabled;
    final tint = parseSourceColor(source.color);
    final subtitle = sourceListSubtitle(
      context.l10n,
      source,
      busy: busy,
      status: status,
    );

    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (reordering && !isTv && total > 1)
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              Icon(_typeIcon, color: tint ?? AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: !enabled
                            ? AppColors.textMuted
                            : busy
                            ? AppColors.accent
                            : AppColors.textMuted,
                        fontSize: 13,
                        fontWeight: busy ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              if (reordering && isTv) ...[
                if (onMoveUp != null)
                  TvFocusable(
                    borderRadius: 10,
                    onSelect: onMoveUp,
                    child: Tooltip(
                      message: context.l10n.moveSourceUp,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_upward_rounded, size: 18),
                      ),
                    ),
                  ),
                if (onMoveDown != null)
                  TvFocusable(
                    borderRadius: 10,
                    onSelect: onMoveDown,
                    child: Tooltip(
                      message: context.l10n.moveSourceDown,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_downward_rounded, size: 18),
                      ),
                    ),
                  ),
              ] else if (!reordering && !isTv) ...[
                Switch(value: enabled, onChanged: onEnabledChanged),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'rename') onRename();
                    if (value == 'sync') onSync();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(context.l10n.edit),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(context.l10n.rename),
                    ),
                    PopupMenuItem(
                      value: 'sync',
                      enabled: !busy,
                      child: Text(
                        busy ? context.l10n.syncing : context.l10n.syncNow,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(context.l10n.remove),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: AppColors.borderSoft,
              ),
            ),
          ],
          if (isTv && !reordering) ...[
            const SizedBox(height: 8),
            Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: onTvUpFromStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TvFocusable(
                    borderRadius: 10,
                    onSelect: onEdit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(context.l10n.edit),
                    ),
                  ),
                  TvFocusable(
                    borderRadius: 10,
                    enabled: !busy,
                    onSelect: busy ? null : onSync,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        busy ? context.l10n.syncing : context.l10n.sync,
                      ),
                    ),
                  ),
                  TvFocusable(
                    borderRadius: 10,
                    onSelect: () => onEnabledChanged(!enabled),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        enabled
                            ? context.l10n.disableSource
                            : context.l10n.enableSource,
                      ),
                    ),
                  ),
                  TvFocusable(
                    borderRadius: 10,
                    onSelect: onDelete,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        context.l10n.remove,
                        style: const TextStyle(color: AppColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: tint?.withValues(alpha: 0.7) ?? AppColors.border,
            width: tint != null ? 1.5 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: reordering || isTv ? null : onEdit,
            child: body,
          ),
        ),
      ),
    );
  }
}

enum _AddSourceKind {
  m3u,
  xtream,
  stalker,
  xmltv,
  custom,
  jellyfin,
  emby,
  plex,
}

class _SourceTypeOption {
  const _SourceTypeOption({
    required this.kind,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final _AddSourceKind kind;
  final IconData icon;
  final String title;
  final String subtitle;
}

class _AddSourceForm extends StatefulWidget {
  const _AddSourceForm({this.prefill, this.editing});

  final JavpSourceAddRequest? prefill;
  final IptvSource? editing;

  @override
  State<_AddSourceForm> createState() => _AddSourceFormState();
}

class _AddSourceFormState extends State<_AddSourceForm>
    with WidgetsBindingObserver {
  _AddSourceKind? _kind;
  final _name = TextEditingController();
  final _playlist = TextEditingController();
  final _epg = TextEditingController();
  final _server = TextEditingController();
  final _altServer = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _catalogUrl = TextEditingController();
  bool _saving = false;
  String? _error;
  SourceKindMismatchException? _mismatch;

  /// After a soft Xtream playlist-export suggest, allow saving as M3U.
  bool _acceptXtreamPlaylistExport = false;

  /// Attached [IptvSourceType.xmltv] id, or null for inline / none / provider.
  String? _epgSourceId;
  LiveEpgInput _epgInput = LiveEpgInput.provider;

  /// Xtream: include movies/series in Catalog (live still syncs when off).
  bool _vodEnabled = true;

  /// JSON catalog: access token lives under an expandable advanced section.
  bool _catalogAuthExpanded = false;

  /// Badge tint while editing (applied immediately).
  String? _colorHex;

  /// URL vs local file for fields that accept either (when picker is available).
  _LocationInputMode _playlistLocationMode = _LocationInputMode.url;
  _LocationInputMode _epgLocationMode = _LocationInputMode.url;
  _LocationInputMode _catalogLocationMode = _LocationInputMode.url;
  String _playlistUrlDraft = '';
  String _playlistFileDraft = '';
  String _epgUrlDraft = '';
  String _epgFileDraft = '';
  String _catalogUrlDraft = '';
  String _catalogFileDraft = '';
  final _scroll = ScrollController();
  final _introFocus = FocusNode(debugLabel: 'addSourceIntro');
  final _firstTypeFocus = FocusNode(debugLabel: 'addSourceFirstType');
  final _typePickerScope = FocusScopeNode(
    debugLabel: 'addSourceTypes',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  /// Plex: account sign-in vs manual URL+token.
  bool _plexManual = false;
  bool _plexSigningIn = false;
  bool _plexSignInCancelled = false;
  PlexPinRequest? _plexPin;
  List<PlexServerResource>? _plexServers;
  String? _plexAccountToken;
  final PlexAuthWake _plexWake = PlexAuthWake();

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _catalogUrl.addListener(_onCatalogUrlEdited);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _kind != null || !TvPlatform.isAndroidTv) return;
      if (_introFocus.canRequestFocus) _introFocus.requestFocus();
      _revealAddSourceHeader();
    });
    final editing = widget.editing;
    if (editing != null) {
      _prefillFromSource(editing);
      return;
    }
    final prefill = widget.prefill;
    if (prefill == null) return;
    _applyAddRequest(prefill);
  }

  /// Fills the form from a parsed `javp://add` / `https://javp.app/add` request.
  ///
  /// When [fillNameIfEmpty] is true (paste unwrap), keeps an existing display
  /// name the user already typed.
  void _applyAddRequest(
    JavpSourceAddRequest prefill, {
    bool fillNameIfEmpty = false,
  }) {
    final nextKind = switch (prefill.type) {
      IptvSourceType.custom => _AddSourceKind.custom,
      IptvSourceType.m3u => _AddSourceKind.m3u,
      IptvSourceType.xtream => _AddSourceKind.xtream,
      IptvSourceType.stalker => _AddSourceKind.stalker,
      _ => null,
    };
    if (nextKind == null) return;
    _kind = nextKind;
    if (prefill.name != null &&
        (!fillNameIfEmpty || _name.text.trim().isEmpty)) {
      _name.text = prefill.name!;
    }
    if (prefill.type == IptvSourceType.custom) {
      _applyLocation(_catalogUrl, prefill.url, forCatalog: true);
    } else if (prefill.type == IptvSourceType.m3u) {
      _applyLocation(_playlist, prefill.url, forPlaylist: true);
      if (prefill.epgUrl != null) {
        _applyLocation(_epg, prefill.epgUrl!, forEpg: true);
        // Share / deep-link EPG must select URL-or-file so the field is shown
        // and [_epgSaveFields] persists [epgUrl] instead of clearing it.
        _epgInput = liveEpgInputFromFields(
          epgEnabled: true,
          epgUrl: prefill.epgUrl,
        );
      }
    } else if (prefill.type == IptvSourceType.xtream) {
      _server.text = prefill.url;
      if (prefill.username != null) _user.text = prefill.username!;
      if (prefill.password != null) _pass.text = prefill.password!;
      if (prefill.alternateServerUrl != null) {
        _altServer.text = prefill.alternateServerUrl!;
      }
    } else if (prefill.type == IptvSourceType.stalker) {
      _server.text = prefill.url;
      if (prefill.username != null) _user.text = prefill.username!;
      if (prefill.password != null) _pass.text = prefill.password!;
    }
  }

  /// Unwrap share links pasted into the catalog URL field (same parse path as
  /// App Links / TV pairing).
  void _onCatalogUrlEdited() {
    if (_kind != _AddSourceKind.custom) return;
    if (_catalogLocationMode != _LocationInputMode.url) return;
    final req = parseJavpSourceAddLinkText(_catalogUrl.text);
    if (req == null) return;
    _catalogUrl.removeListener(_onCatalogUrlEdited);
    try {
      setState(() => _applyAddRequest(req, fillNameIfEmpty: true));
    } finally {
      _catalogUrl.addListener(_onCatalogUrlEdited);
    }
  }

  /// Submit-time safety net when paste listener did not run (e.g. TV remote).
  void _unwrapCatalogJavpAddLinkBeforeSave() {
    if (_kind != _AddSourceKind.custom) return;
    if (_catalogLocationMode != _LocationInputMode.url) return;
    final req = parseJavpSourceAddLinkText(_catalogUrl.text);
    if (req == null) return;
    _catalogUrl.removeListener(_onCatalogUrlEdited);
    try {
      _applyAddRequest(req, fillNameIfEmpty: true);
    } finally {
      _catalogUrl.addListener(_onCatalogUrlEdited);
    }
  }

  void _applyXtreamSuggestion(DetectedXtreamUrl detected) {
    setState(() {
      _kind = _AddSourceKind.xtream;
      _server.text = detected.baseUrl;
      if (detected.username != null) _user.text = detected.username!;
      if (detected.password != null) _pass.text = detected.password!;
      _error = null;
      _mismatch = null;
      _acceptXtreamPlaylistExport = false;
    });
  }

  void _prefillFromSource(IptvSource source) {
    _kind = switch (source.type) {
      IptvSourceType.m3u => _AddSourceKind.m3u,
      IptvSourceType.xtream => _AddSourceKind.xtream,
      IptvSourceType.stalker => _AddSourceKind.stalker,
      IptvSourceType.xmltv => _AddSourceKind.xmltv,
      IptvSourceType.custom => _AddSourceKind.custom,
      IptvSourceType.jellyfin => _AddSourceKind.jellyfin,
      IptvSourceType.emby => _AddSourceKind.emby,
      IptvSourceType.plex => _AddSourceKind.plex,
    };
    _name.text = source.name;
    _colorHex = source.color;
    _vodEnabled = source.vodEnabled;
    _epgSourceId = source.epgSourceId;
    // Still load URL / attachment when Guide is off so save does not wipe them.
    _epgInput = liveEpgInputFromFields(
      epgEnabled: source.epgEnabled,
      epgSourceId: source.epgSourceId,
      epgUrl: source.epgUrl,
    );
    switch (source.type) {
      case IptvSourceType.m3u:
        _applyLocation(_playlist, source.playlistUrl ?? '', forPlaylist: true);
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
      case IptvSourceType.xmltv:
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
      case IptvSourceType.custom:
        _applyLocation(_catalogUrl, source.playlistUrl ?? '', forCatalog: true);
        // Expand auth when a token is already stored (field stays blank for
        // security — helper text explains leave-blank-to-keep).
        _catalogAuthExpanded =
            source.catalogAuthToken?.trim().isNotEmpty == true;
      case IptvSourceType.xtream:
        _server.text = source.serverUrl ?? '';
        _altServer.text = source.alternateServerUrl ?? '';
        _user.text = source.username ?? '';
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
      case IptvSourceType.stalker:
        _server.text = source.serverUrl ?? '';
        _user.text = source.username ?? '';
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
      case IptvSourceType.jellyfin:
      case IptvSourceType.emby:
        _server.text = source.serverUrl ?? '';
        _user.text = source.username ?? '';
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
      case IptvSourceType.plex:
        _plexManual = true;
        _server.text = source.serverUrl ?? '';
        _user.text = source.username ?? '';
        _applyLocation(_epg, source.epgUrl ?? '', forEpg: true);
    }
  }

  /// Seeds a location controller + URL/file mode from a saved or prefills value.
  void _applyLocation(
    TextEditingController controller,
    String location, {
    bool forPlaylist = false,
    bool forEpg = false,
    bool forCatalog = false,
  }) {
    final trimmed = location.trim();
    final isFile = LocalSourcePath.tryLocalFilePath(trimmed) != null;
    final mode = isFile ? _LocationInputMode.file : _LocationInputMode.url;
    controller.text = trimmed;
    if (forPlaylist) {
      _playlistLocationMode = mode;
      if (isFile) {
        _playlistFileDraft = trimmed;
      } else {
        _playlistUrlDraft = trimmed;
      }
    } else if (forEpg) {
      _epgLocationMode = mode;
      if (isFile) {
        _epgFileDraft = trimmed;
      } else {
        _epgUrlDraft = trimmed;
      }
    } else if (forCatalog) {
      _catalogLocationMode = mode;
      if (isFile) {
        _catalogFileDraft = trimmed;
      } else {
        _catalogUrlDraft = trimmed;
      }
    }
  }

  void _switchLocationMode({
    required _LocationInputMode current,
    required _LocationInputMode next,
    required TextEditingController controller,
    required void Function(_LocationInputMode) setMode,
    required String urlDraft,
    required String fileDraft,
    required void Function(String) setUrlDraft,
    required void Function(String) setFileDraft,
  }) {
    if (next == current) return;
    if (current == _LocationInputMode.url) {
      setUrlDraft(controller.text);
      controller.text = fileDraft;
    } else {
      setFileDraft(controller.text);
      controller.text = urlDraft;
    }
    setMode(next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _plexSigningIn &&
        !_plexSignInCancelled) {
      _plexWake.nudge();
    }
  }

  void _resetPlexFlow() {
    _plexSignInCancelled = true;
    _plexManual = false;
    _plexSigningIn = false;
    _plexPin = null;
    _plexServers = null;
    _plexAccountToken = null;
  }

  String _formatError(Object error) {
    return describeCaughtError(
      error,
      proxyHandshakeMessage: context.l10n.proxyHandshakeFailed,
    );
  }

  List<_SourceTypeOption> get _serverOptions {
    final l10n = context.l10n;
    return [
      _SourceTypeOption(
        kind: _AddSourceKind.plex,
        icon: Icons.grid_view_rounded,
        title: 'Plex',
        subtitle: l10n.signInWithPlexOrUrlToken,
      ),
      _SourceTypeOption(
        kind: _AddSourceKind.jellyfin,
        icon: Icons.dashboard_customize_outlined,
        title: 'Jellyfin',
        subtitle: l10n.serverUrlUsernamePassword,
      ),
      _SourceTypeOption(
        kind: _AddSourceKind.emby,
        icon: Icons.live_tv_outlined,
        title: 'Emby',
        subtitle: l10n.serverUrlUsernamePassword,
      ),
    ];
  }

  List<_SourceTypeOption> get _iptvOptions {
    final l10n = context.l10n;
    return [
      _SourceTypeOption(
        kind: _AddSourceKind.xtream,
        icon: Icons.cloud_outlined,
        title: l10n.xtreamCodes,
        subtitle: l10n.serverUrlUsernamePassword,
      ),
      _SourceTypeOption(
        kind: _AddSourceKind.stalker,
        icon: Icons.router_outlined,
        title: l10n.stalkerPortal,
        subtitle: l10n.stalkerPortalSubtitle,
      ),
      _SourceTypeOption(
        kind: _AddSourceKind.m3u,
        icon: Icons.playlist_play_rounded,
        title: l10n.m3uPlaylist,
        subtitle: l10n.m3uPlaylistSubtitle,
      ),
    ];
  }

  List<_SourceTypeOption> get _catalogOptions {
    final l10n = context.l10n;
    return [
      _SourceTypeOption(
        kind: _AddSourceKind.custom,
        icon: Icons.data_object_rounded,
        title: l10n.customJsonCatalog,
        subtitle: l10n.hostedCatalogJsonUrl,
      ),
    ];
  }

  /// Standalone programme guide — secondary; attach to live lists after sync.
  List<_SourceTypeOption> get _guideOptions {
    final l10n = context.l10n;
    return [
      _SourceTypeOption(
        kind: _AddSourceKind.xmltv,
        icon: Icons.event_note_outlined,
        title: l10n.xmltvEpg,
        subtitle: l10n.xmltvEpgSubtitle,
      ),
    ];
  }

  String get _formTitle {
    if (_isEditing) return context.l10n.editSource;
    return switch (_kind) {
      _AddSourceKind.m3u => context.l10n.addM3uPlaylist,
      _AddSourceKind.xtream => context.l10n.addXtreamSource,
      _AddSourceKind.stalker => context.l10n.addStalkerSource,
      _AddSourceKind.xmltv => context.l10n.addXmltvEpg,
      _AddSourceKind.custom => context.l10n.addJsonCatalog,
      _AddSourceKind.jellyfin => context.l10n.addJellyfin,
      _AddSourceKind.emby => context.l10n.addEmby,
      _AddSourceKind.plex =>
        _plexServers != null
            ? context.l10n.choosePlexServer
            : _plexSigningIn
            ? context.l10n.signInWithPlex
            : _plexManual
            ? context.l10n.addPlexManual
            : context.l10n.addPlex,
      null => context.l10n.addSource,
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _plexSignInCancelled = true;
    _catalogUrl.removeListener(_onCatalogUrlEdited);
    _name.dispose();
    _playlist.dispose();
    _epg.dispose();
    _server.dispose();
    _altServer.dispose();
    _user.dispose();
    _pass.dispose();
    _catalogUrl.dispose();
    _scroll.dispose();
    _introFocus.dispose();
    _firstTypeFocus.dispose();
    _typePickerScope.dispose();
    super.dispose();
  }

  Future<void> _pickLocalM3u() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    final file = picked?.files.single;
    final path = file?.path;
    if (path == null || path.isEmpty) return;
    setState(() {
      _playlistLocationMode = _LocationInputMode.file;
      _playlistFileDraft = path;
      _playlist.text = path;
      if (_name.text.trim().isEmpty && file!.name.isNotEmpty) {
        final name = file.name;
        final lower = name.toLowerCase();
        _name.text = lower.endsWith('.m3u8')
            ? name.substring(0, name.length - 5)
            : lower.endsWith('.m3u')
            ? name.substring(0, name.length - 4)
            : name;
      }
      _error = null;
      _mismatch = null;
    });
  }

  Future<void> _pickLocalXmltv() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xml', 'gz'],
    );
    final file = picked?.files.single;
    final path = file?.path;
    if (path == null || path.isEmpty) return;
    setState(() {
      _epgLocationMode = _LocationInputMode.file;
      _epgFileDraft = path;
      _epg.text = path;
      if (_name.text.trim().isEmpty && file!.name.isNotEmpty) {
        final name = file.name;
        final lower = name.toLowerCase();
        _name.text = lower.endsWith('.xml.gz')
            ? name.substring(0, name.length - 7)
            : lower.endsWith('.gz')
            ? name.substring(0, name.length - 3)
            : lower.endsWith('.xml')
            ? name.substring(0, name.length - 4)
            : name;
      }
      _error = null;
      _mismatch = null;
    });
  }

  Future<void> _pickLocalJsonCatalog() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.single;
    final path = file?.path;
    if (path == null || path.isEmpty) return;
    setState(() {
      _catalogLocationMode = _LocationInputMode.file;
      _catalogFileDraft = path;
      _catalogUrl.text = path;
      if (_name.text.trim().isEmpty && file!.name.isNotEmpty) {
        final name = file.name;
        final lower = name.toLowerCase();
        _name.text = lower.endsWith('.json')
            ? name.substring(0, name.length - 5)
            : name;
      }
      _error = null;
      _mismatch = null;
    });
  }

  Widget _buildLocationField({
    required _LocationInputMode mode,
    required ValueChanged<_LocationInputMode> onModeChanged,
    required TextEditingController controller,
    required String urlLabel,
    required String urlHint,
    required VoidCallback onPickFile,
    required String pickLabel,
  }) {
    if (!AppCapabilities.localFilePicker) {
      return PlainTextField(
        controller: controller,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(labelText: urlLabel, hintText: urlHint),
      );
    }

    final l10n = context.l10n;
    final path = controller.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_LocationInputMode>(
          segments: [
            ButtonSegment(
              value: _LocationInputMode.url,
              label: Text(l10n.url),
              icon: const Icon(Icons.link_rounded, size: 18),
            ),
            ButtonSegment(
              value: _LocationInputMode.file,
              label: Text(l10n.sourceLocationFile),
              icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (next) {
            if (next.isEmpty) return;
            onModeChanged(next.first);
          },
        ),
        const SizedBox(height: 10),
        if (mode == _LocationInputMode.url)
          PlainTextField(
            controller: controller,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: urlLabel, hintText: urlHint),
          )
        else ...[
          InputDecorator(
            decoration: const InputDecoration(border: OutlineInputBorder()),
            child: Text(
              path.isEmpty ? l10n.noFileSelected : path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: path.isEmpty ? AppColors.textMuted : AppColors.text,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onPickFile,
              icon: const Icon(Icons.folder_open_rounded),
              label: Text(pickLabel),
            ),
          ),
        ],
      ],
    );
  }

  void _revealAddSourceHeader() {
    void jump() {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    }

    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
  }

  KeyEventResult _onFirstTypeUp(FocusNode node, KeyEvent event) {
    if (!TvPlatform.isAndroidTv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (!_firstTypeFocus.hasFocus) return KeyEventResult.ignored;
    _introFocus.requestFocus();
    _revealAddSourceHeader();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // Cap to the overlay's incoming max so a shrink-wrapping scroll view
    // cannot size itself to the full type list (off-screen, nothing to
    // scroll). Dialog/sheet already pad for the IME.
    return PopScope(
      canPop: !_saving,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height * 0.85;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_saving)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: LinearProgressIndicator(),
                      )
                    else
                      const AppModalDragHandle(bottom: 14),
                    if (_kind == null)
                      _buildTypePicker(context)
                    else
                      _buildCredentialsForm(context),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTypePicker(BuildContext context) {
    final l10n = context.l10n;
    final tv = TvPlatform.isAndroidTv;
    final intro = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.addSource, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          l10n.chooseHowYouConnect,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
    return FocusScope(
      node: _typePickerScope,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onFirstTypeUp,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tv)
              TvFocusable(
                focusNode: _introFocus,
                autofocus: true,
                borderRadius: 12,
                onFocusChange: (focused) {
                  if (focused) _revealAddSourceHeader();
                },
                child: intro,
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: intro),
                  IconButton(
                    key: addSourceCloseButtonKey,
                    tooltip: l10n.close,
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            const SizedBox(height: 20),
            _sectionLabel(context, l10n.capabilityMediaServers),
            _typeGroup(
              _serverOptions,
              firstTileFocus: tv ? _firstTypeFocus : null,
            ),
            const SizedBox(height: 18),
            _sectionLabel(context, l10n.capabilityIptv),
            _typeGroup(_iptvOptions),
            const SizedBox(height: 18),
            _sectionLabel(context, l10n.capabilityJsonCatalogs),
            _typeGroup(_catalogOptions),
            const SizedBox(height: 22),
            Divider(height: 1, color: AppColors.border.withValues(alpha: 0.7)),
            const SizedBox(height: 14),
            _sectionLabel(context, l10n.capabilityGuideEpg, secondary: true),
            _typeGroup(_guideOptions, secondary: true),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(
    BuildContext context,
    String label, {
    bool secondary = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: secondary ? AppColors.textMuted : AppColors.text,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _typeGroup(
    List<_SourceTypeOption> options, {
    bool secondary = false,
    FocusNode? firstTileFocus,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: secondary
              ? AppColors.border.withValues(alpha: 0.55)
              : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: AppColors.border.withValues(alpha: 0.7),
              ),
            _typeTile(
              options[i],
              secondary: secondary,
              focusNode: i == 0 ? firstTileFocus : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _typeTile(
    _SourceTypeOption option, {
    bool secondary = false,
    FocusNode? focusNode,
  }) {
    void select() => setState(() {
      _kind = option.kind;
      _error = null;
      _mismatch = null;
      if (option.kind == _AddSourceKind.plex) {
        _plexSignInCancelled = false;
        _plexManual = false;
        _plexSigningIn = false;
        _plexPin = null;
        _plexServers = null;
        _plexAccountToken = null;
      }
    });
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            option.icon,
            color: secondary ? AppColors.textMuted : AppColors.accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.title,
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: secondary ? FontWeight.w600 : FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  option.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
        ],
      ),
    );

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        focusNode: focusNode,
        borderRadius: 14,
        onSelect: select,
        onFocusChange: focusNode != null
            ? (focused) {
                if (focused) _revealAddSourceHeader();
              }
            : null,
        child: row,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: select,
        child: row,
      ),
    );
  }

  Widget _buildCredentialsForm(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final kind = _kind!;

    if (kind == _AddSourceKind.plex) {
      return _buildPlexForm(context, library);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: context.l10n.back,
              onPressed: _saving
                  ? null
                  : () {
                      if (_isEditing) {
                        Navigator.pop(context, false);
                        return;
                      }
                      setState(() {
                        _kind = null;
                        _error = null;
                        _mismatch = null;
                      });
                    },
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                _formTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        JavpTextField(
          controller: _name,
          decoration: InputDecoration(labelText: context.l10n.displayName),
        ),
        if (_isEditing) ..._buildSourceColorField(library),
        const SizedBox(height: 10),
        if (kind == _AddSourceKind.m3u) ...[
          _buildLocationField(
            mode: _playlistLocationMode,
            onModeChanged: (next) => setState(() {
              _switchLocationMode(
                current: _playlistLocationMode,
                next: next,
                controller: _playlist,
                setMode: (m) => _playlistLocationMode = m,
                urlDraft: _playlistUrlDraft,
                fileDraft: _playlistFileDraft,
                setUrlDraft: (v) => _playlistUrlDraft = v,
                setFileDraft: (v) => _playlistFileDraft = v,
              );
            }),
            controller: _playlist,
            urlLabel: context.l10n.m3uUrl,
            urlHint: 'https://…/playlist.m3u',
            onPickFile: _pickLocalM3u,
            pickLabel: context.l10n.pickM3u,
          ),
          const SizedBox(height: 10),
          ..._buildLiveEpgFields(library),
        ] else if (kind == _AddSourceKind.xmltv) ...[
          _buildLocationField(
            mode: _epgLocationMode,
            onModeChanged: (next) => setState(() {
              _switchLocationMode(
                current: _epgLocationMode,
                next: next,
                controller: _epg,
                setMode: (m) => _epgLocationMode = m,
                urlDraft: _epgUrlDraft,
                fileDraft: _epgFileDraft,
                setUrlDraft: (v) => _epgUrlDraft = v,
                setFileDraft: (v) => _epgFileDraft = v,
              );
            }),
            controller: _epg,
            urlLabel: context.l10n.epgXmlUrl,
            urlHint: 'https://example.com/epg.xml',
            onPickFile: _pickLocalXmltv,
            pickLabel: context.l10n.pickXmltv,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.xmltvEpgSubtitle,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ] else if (kind == _AddSourceKind.xtream) ...[
          PlainTextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.l10n.serverUrl,
              hintText: 'http://host:port',
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _altServer,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Samsung / LG DNS (optional)',
              hintText: 'http://host for IPTV Smarters',
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _user,
            decoration: InputDecoration(labelText: context.l10n.username),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.password,
              helperText: _isEditing
                  ? context.l10n.leaveBlankKeepPassword
                  : null,
            ),
          ),
          const SizedBox(height: 10),
          SettingsSwitchListTile(
            value: _vodEnabled,
            onChanged: (v) => setState(() => _vodEnabled = v),
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.includeXtreamVod),
            subtitle: Text(context.l10n.includeXtreamVodSubtitle),
          ),
          const SizedBox(height: 10),
          ..._buildLiveEpgFields(library),
        ] else if (kind == _AddSourceKind.stalker) ...[
          PlainTextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.l10n.portalUrl,
              hintText: 'http://host:port/c/',
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _user,
            decoration: InputDecoration(labelText: context.l10n.macAddress),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.serialOptional,
              helperText: _isEditing
                  ? context.l10n.leaveBlankKeepPassword
                  : null,
            ),
          ),
          const SizedBox(height: 10),
          ..._buildLiveEpgFields(library),
        ] else if (kind == _AddSourceKind.custom) ...[
          _buildLocationField(
            mode: _catalogLocationMode,
            onModeChanged: (next) => setState(() {
              _switchLocationMode(
                current: _catalogLocationMode,
                next: next,
                controller: _catalogUrl,
                setMode: (m) => _catalogLocationMode = m,
                urlDraft: _catalogUrlDraft,
                fileDraft: _catalogFileDraft,
                setUrlDraft: (v) => _catalogUrlDraft = v,
                setFileDraft: (v) => _catalogFileDraft = v,
              );
            }),
            controller: _catalogUrl,
            urlLabel: context.l10n.catalogJsonUrl,
            urlHint: 'https://…/catalog.json',
            onPickFile: _pickLocalJsonCatalog,
            pickLabel: context.l10n.pickJsonCatalog,
          ),
          const SizedBox(height: 8),
          Text(
            'Expects { "name", "items": [{ "id", "title", "playUrl", … }] } '
            'or a bare array of items. Local files are v1 bulk dumps only.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OpenLinkButton(
              label: context.l10n.catalogApiDocumentation,
              url: _catalogApiDocsUrl,
            ),
          ),
          ExpansionTile(
            initiallyExpanded: _catalogAuthExpanded,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 4),
            onExpansionChanged: (open) {
              _catalogAuthExpanded = open;
            },
            title: Text(
              context.l10n.accessToken,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _isEditing &&
                      (widget.editing?.catalogAuthToken?.trim().isNotEmpty ??
                          false)
                  ? context.l10n.apiKeySet
                  : 'Optional · Authorization: Bearer …',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            children: [
              PlainTextField(
                controller: _pass,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.l10n.accessToken,
                  hintText: 'Bearer token / API key',
                  helperText: _isEditing
                      ? context.l10n.leaveBlankKeepPassword
                      : null,
                ),
              ),
            ],
          ),
        ] else ...[
          PlainTextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.l10n.serverUrl,
              hintText: 'http://host:8096',
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _user,
            decoration: InputDecoration(labelText: context.l10n.username),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.password,
              helperText: _isEditing
                  ? context.l10n.leaveBlankKeepPassword
                  : null,
            ),
          ),
          if (kind == _AddSourceKind.jellyfin ||
              kind == _AddSourceKind.emby) ...[
            const SizedBox(height: 10),
            ..._buildLiveEpgFields(library),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: AppColors.accent)),
          if (_mismatch != null &&
              (_mismatch!.allowsContinueAsM3u ||
                  (!_isEditing &&
                      (_mismatch!.canSwitchToJsonCatalog ||
                          _mismatch!.canSwitchToM3uPlaylist ||
                          _mismatch!.canSwitchToXmltv ||
                          _mismatch!.canSwitchToXtream)))) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!_isEditing &&
                    (_mismatch!.canSwitchToJsonCatalog ||
                        _mismatch!.canSwitchToM3uPlaylist ||
                        _mismatch!.canSwitchToXmltv ||
                        _mismatch!.canSwitchToXtream))
                  OutlinedButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _applyMismatchSuggestion(library),
                    icon: const Icon(Icons.swap_horiz_rounded),
                    label: Text(
                      _mismatch!.canSwitchToJsonCatalog
                          ? context.l10n.addAsJsonCatalog
                          : _mismatch!.canSwitchToXmltv
                          ? context.l10n.addAsXmltvEpg
                          : _mismatch!.canSwitchToXtream
                          ? context.l10n.addAsXtreamSource
                          : context.l10n.addAsM3uPlaylist,
                    ),
                  ),
                if (_mismatch!.allowsContinueAsM3u)
                  OutlinedButton.icon(
                    onPressed: _saving
                        ? null
                        : () {
                            _acceptXtreamPlaylistExport = true;
                            _saveSource(context, library);
                          },
                    icon: const Icon(Icons.playlist_add_check_rounded),
                    label: Text(context.l10n.addAsM3uPlaylist),
                  ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 16),
        AppActionButton(
          expand: true,
          busy: _saving,
          onPressed: _saving ? null : () => _saveSource(context, library),
          label: _saving
              ? context.l10n.addingSource
              : (kind == _AddSourceKind.m3u ||
                        kind == _AddSourceKind.xtream ||
                        kind == _AddSourceKind.stalker ||
                        kind == _AddSourceKind.xmltv
                    ? context.l10n.saveAndSyncInBackground
                    : context.l10n.saveAndSync),
        ),
      ],
    );
  }

  LiveEpgSaveFields _epgSaveFields(LibraryProvider library) {
    var input = _epgInput;
    if (input == LiveEpgInput.attached) {
      final id = _epgSourceId?.trim();
      final valid =
          id != null &&
          id.isNotEmpty &&
          library.sources.any(
            (s) => s.id == id && s.type == IptvSourceType.xmltv,
          );
      if (!valid) input = LiveEpgInput.provider;
    }
    return liveEpgSaveFields(
      input: input,
      attachedSourceId: _epgSourceId,
      urlOrFile: _epg.text,
    );
  }

  List<Widget> _buildSourceColorField(LibraryProvider library) {
    return [
      const SizedBox(height: 12),
      Text(
        context.l10n.sourceColor,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      SourceColorSwatchRow(
        currentHex: _colorHex,
        onPicked: (hex) {
          final next = hex.isEmpty ? null : hex;
          setState(() => _colorHex = next);
          final id = widget.editing?.id;
          if (id != null) {
            unawaited(library.setSourceColor(id, next));
          }
        },
      ),
    ];
  }

  List<Widget> _buildLiveEpgFields(LibraryProvider library) {
    final epgSources = library.sources
        .where((s) => s.type == IptvSourceType.xmltv)
        .toList(growable: false);
    final editingId = widget.editing?.id;
    final attachable = [
      for (final s in epgSources)
        if (s.id != editingId) s,
    ];
    final providerKind = switch (_kind) {
      _AddSourceKind.m3u => LiveEpgProviderKind.playlist,
      _AddSourceKind.xtream ||
      _AddSourceKind.stalker => LiveEpgProviderKind.iptvProvider,
      _ => LiveEpgProviderKind.mediaServer,
    };
    return [
      LiveEpgSourcePicker(
        providerKind: providerKind,
        input: _epgInput,
        attachedSourceId: _epgSourceId,
        xmltvSources: attachable,
        onChanged: (input, attachedId) {
          setState(() {
            _epgInput = input;
            // None keeps the last attachment in memory so save can preserve it.
            _epgSourceId = input == LiveEpgInput.off
                ? (attachedId ?? _epgSourceId)
                : attachedId;
          });
        },
        urlOrFileField: _epgInput == LiveEpgInput.urlOrFile
            ? _buildLocationField(
                mode: _epgLocationMode,
                onModeChanged: (next) => setState(() {
                  _switchLocationMode(
                    current: _epgLocationMode,
                    next: next,
                    controller: _epg,
                    setMode: (m) => _epgLocationMode = m,
                    urlDraft: _epgUrlDraft,
                    fileDraft: _epgFileDraft,
                    setUrlDraft: (v) => _epgUrlDraft = v,
                    setFileDraft: (v) => _epgFileDraft = v,
                  );
                }),
                controller: _epg,
                urlLabel: context.l10n.epgXmlUrl,
                urlHint: 'https://example.com/epg.xml',
                onPickFile: _pickLocalXmltv,
                pickLabel: context.l10n.pickXmltv,
              )
            : null,
      ),
    ];
  }

  String _localizedMismatch(SourceKindMismatchException e) {
    final l10n = context.l10n;
    if (e.expected == SourceContentExpectation.m3uPlaylist &&
        e.detected == SourceContentKind.jsonCatalog) {
      return l10n.looksLikeJsonCatalogSuggest;
    }
    if (e.expected == SourceContentExpectation.jsonCatalog &&
        e.detected == SourceContentKind.iptvM3u) {
      return l10n.looksLikeM3uPlaylistSuggest;
    }
    if (e.expected == SourceContentExpectation.m3uPlaylist &&
        e.detected == SourceContentKind.hlsPlaylist) {
      return l10n.looksLikeHlsStreamSuggest;
    }
    if (e.expected == SourceContentExpectation.m3uPlaylist &&
        e.detected == SourceContentKind.xtreamCodes) {
      return l10n.looksLikeXtreamSuggest;
    }
    return e.message;
  }

  Future<void> _applyMismatchSuggestion(LibraryProvider library) async {
    final mismatch = _mismatch;
    if (mismatch == null) return;
    if (mismatch.canSwitchToXtream) {
      final detected = tryDetectXtreamUrl(_playlist.text);
      if (detected != null) {
        _applyXtreamSuggestion(detected);
      } else {
        setState(() {
          _kind = _AddSourceKind.xtream;
          _error = null;
          _mismatch = null;
        });
      }
      return;
    }
    if (mismatch.canSwitchToJsonCatalog) {
      final url = _playlist.text.trim();
      setState(() {
        _kind = _AddSourceKind.custom;
        _applyLocation(_catalogUrl, url, forCatalog: true);
        _error = null;
        _mismatch = null;
      });
      await _saveSource(context, library);
      return;
    }
    if (mismatch.canSwitchToXmltv) {
      final url = _kind == _AddSourceKind.custom
          ? _catalogUrl.text.trim()
          : _playlist.text.trim();
      setState(() {
        _kind = _AddSourceKind.xmltv;
        _applyLocation(_epg, url, forEpg: true);
        _error = null;
        _mismatch = null;
      });
      await _saveSource(context, library);
      return;
    }
    if (mismatch.canSwitchToM3uPlaylist) {
      final url = _catalogUrl.text.trim();
      setState(() {
        _kind = _AddSourceKind.m3u;
        _applyLocation(_playlist, url, forPlaylist: true);
        _error = null;
        _mismatch = null;
      });
      await _saveSource(context, library);
    }
  }

  Future<void> _saveSource(
    BuildContext context,
    LibraryProvider library,
  ) async {
    if (_kind == null) return;
    // Catalog URL may still hold a pasted javp://add / javp.app/add share link.
    _unwrapCatalogJavpAddLinkBeforeSave();
    final kind = _kind;
    if (kind == null) return;
    setState(() {
      _saving = true;
      _error = null;
      _mismatch = null;
    });
    try {
      final epg = _epgSaveFields(library);
      final editing = widget.editing;
      if (editing != null) {
        switch (kind) {
          case _AddSourceKind.m3u:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              playlistUrl: _playlist.text,
              epgUrl: epg.epgUrl,
              epgSourceId: epg.epgSourceId,
              epgEnabled: epg.epgEnabled,
              acceptXtreamPlaylistExport: _acceptXtreamPlaylistExport,
            );
          case _AddSourceKind.xmltv:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              epgUrl: _epg.text,
            );
          case _AddSourceKind.xtream:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              serverUrl: _server.text,
              username: _user.text,
              password: _pass.text,
              alternateServerUrl: _altServer.text,
              epgUrl: epg.epgUrl,
              epgSourceId: epg.epgSourceId,
              epgEnabled: epg.epgEnabled,
              vodEnabled: _vodEnabled,
            );
          case _AddSourceKind.stalker:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              serverUrl: _server.text,
              username: _user.text,
              password: _pass.text,
              epgUrl: epg.epgUrl,
              epgSourceId: epg.epgSourceId,
              epgEnabled: epg.epgEnabled,
            );
          case _AddSourceKind.custom:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              playlistUrl: _catalogUrl.text,
              password: _pass.text,
            );
          case _AddSourceKind.jellyfin:
          case _AddSourceKind.emby:
            await library.updateSourceDetails(
              sourceId: editing.id,
              name: _name.text,
              serverUrl: _server.text,
              username: _user.text,
              password: _pass.text,
              epgUrl: epg.epgUrl,
              epgSourceId: epg.epgSourceId,
              epgEnabled: epg.epgEnabled,
            );
          case _AddSourceKind.plex:
            break;
        }
      } else {
        switch (kind) {
          case _AddSourceKind.m3u:
            await library.addM3uSource(
              name: _name.text,
              playlistUrl: _playlist.text,
              epgUrl: epg.epgUrlOrNull,
              epgSourceId: epg.epgSourceIdOrNull,
              epgEnabled: epg.epgEnabled,
              acceptXtreamPlaylistExport: _acceptXtreamPlaylistExport,
            );
          case _AddSourceKind.xmltv:
            await library.addXmltvSource(name: _name.text, epgUrl: _epg.text);
          case _AddSourceKind.xtream:
            await library.addXtreamSource(
              name: _name.text,
              serverUrl: _server.text,
              username: _user.text,
              password: _pass.text,
              alternateServerUrl: _altServer.text.isEmpty
                  ? null
                  : _altServer.text,
              epgUrl: epg.epgUrlOrNull,
              epgSourceId: epg.epgSourceIdOrNull,
              epgEnabled: epg.epgEnabled,
              vodEnabled: _vodEnabled,
            );
          case _AddSourceKind.stalker:
            await library.addStalkerSource(
              name: _name.text,
              portalUrl: _server.text,
              macAddress: _user.text,
              serial: _pass.text.isEmpty ? null : _pass.text,
              epgUrl: epg.epgUrlOrNull,
              epgSourceId: epg.epgSourceIdOrNull,
              epgEnabled: epg.epgEnabled,
            );
          case _AddSourceKind.custom:
            await library.addCustomCatalogSource(
              name: _name.text,
              catalogUrl: _catalogUrl.text,
              authToken: _pass.text.isEmpty ? null : _pass.text,
            );
          case _AddSourceKind.jellyfin:
          case _AddSourceKind.emby:
            final type = kind == _AddSourceKind.jellyfin
                ? IptvSourceType.jellyfin
                : IptvSourceType.emby;
            await library.addMediaServerSource(
              name: _name.text,
              type: type,
              serverUrl: _server.text,
              username: _user.text,
              password: _pass.text,
              epgUrl: epg.epgUrlOrNull,
              epgSourceId: epg.epgSourceIdOrNull,
              epgEnabled: epg.epgEnabled,
            );
          case _AddSourceKind.plex:
            break;
        }
      }
      if (context.mounted) Navigator.pop(context, true);
    } on SourceKindMismatchException catch (e) {
      if (mounted) {
        setState(() {
          _mismatch = e;
          _error = _localizedMismatch(e);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _formatError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildPlexForm(BuildContext context, LibraryProvider library) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: context.l10n.back,
              onPressed: _saving
                  ? null
                  : () {
                      if (_plexServers != null || _plexSigningIn) {
                        setState(() {
                          _resetPlexFlow();
                          if (_isEditing) _plexManual = true;
                          _error = null;
                        });
                        return;
                      }
                      if (_plexManual && !_isEditing) {
                        setState(() {
                          _resetPlexFlow();
                          _error = null;
                        });
                        return;
                      }
                      if (_isEditing) {
                        Navigator.pop(context, false);
                        return;
                      }
                      setState(() {
                        _kind = null;
                        _error = null;
                      });
                    },
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                _formTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        if (_isEditing) ..._buildSourceColorField(library),
        const SizedBox(height: 8),
        if (_plexServers != null)
          ..._buildPlexServerPicker(context, library)
        else if (_plexSigningIn)
          ..._buildPlexWaiting(context)
        else if (_plexManual)
          ..._buildPlexManual(context, library)
        else
          ..._buildPlexLanding(context, library),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: AppColors.accent)),
        ],
      ],
    );
  }

  List<Widget> _buildPlexLanding(
    BuildContext context,
    LibraryProvider library,
  ) {
    return [
      Text(
        context.l10n.plexAccountSignInHelp,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _saving ? null : () => _startPlexSignIn(library),
        icon: const Icon(Icons.login_rounded),
        label: Text(context.l10n.signInWithPlex),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _saving
            ? null
            : () => setState(() {
                _plexManual = true;
                _error = null;
              }),
        child: Text(context.l10n.useServerUrlToken),
      ),
    ];
  }

  List<Widget> _buildPlexWaiting(BuildContext context) {
    final pin = _plexPin;
    return [
      Text(
        'In the browser: sign in (if needed) and allow JAVP as a player. '
        'Then switch back to this app — sign-in finishes here, not in the browser.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      if (pin != null) ...[
        const SizedBox(height: 12),
        SelectableText(
          'Code: ${pin.code}',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _openPlexAuthUrl(pin.authUrl),
          icon: const Icon(Icons.open_in_browser_rounded),
          label: Text(context.l10n.openPlexSignIn),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () => _plexWake.nudge(),
          child: const Text("I'm back — continue"),
        ),
      ],
      const SizedBox(height: 16),
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => setState(() {
          _resetPlexFlow();
          _error = null;
        }),
        child: Text(context.l10n.cancel),
      ),
    ];
  }

  List<Widget> _buildPlexServerPicker(
    BuildContext context,
    LibraryProvider library,
  ) {
    final servers = _plexServers ?? const <PlexServerResource>[];
    return [
      JavpTextField(
        controller: _name,
        decoration: InputDecoration(
          labelText: 'Display name (optional)',
          hintText: context.l10n.defaultsToServerName,
        ),
      ),
      const SizedBox(height: 10),
      ..._buildLiveEpgFields(library),
      const SizedBox(height: 12),
      if (_plexAccountToken != null && _plexAccountToken!.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _saving ? null : () => _pickPlexFastLive(library),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(Icons.live_tv_rounded, color: AppColors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.plexLiveTv,
                            style: const TextStyle(
                              color: AppColors.text,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            context.l10n.plexLiveTvFastSubtitle,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (servers.isEmpty)
        Text(
          context.l10n.noPlexServersFound,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
        )
      else
        for (final server in servers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _saving ? null : () => _pickPlexServer(library, server),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.dns_outlined, color: AppColors.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              server.name,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                server.owned ? 'Owned' : 'Shared',
                                if (server.presence) 'online',
                                '${server.connections.length} connection'
                                    '${server.connections.length == 1 ? '' : 's'}',
                              ].join(' · '),
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      TextButton(
        onPressed: _saving
            ? null
            : () => setState(() {
                _resetPlexFlow();
                _error = null;
              }),
        child: Text(context.l10n.cancel),
      ),
      if (_saving) ...[
        const SizedBox(height: 8),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 8),
        Text(
          context.l10n.connectingAndSyncing,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    ];
  }

  List<Widget> _buildPlexManual(BuildContext context, LibraryProvider library) {
    return [
      JavpTextField(
        controller: _name,
        decoration: InputDecoration(labelText: context.l10n.displayName),
      ),
      const SizedBox(height: 10),
      PlainTextField(
        controller: _server,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Plex server URL',
          hintText: 'http://192.168.1.10:32400',
        ),
      ),
      const SizedBox(height: 10),
      PlainTextField(
        controller: _pass,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'X-Plex-Token',
          helperText: _isEditing ? context.l10n.leaveBlankKeepPassword : null,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        context.l10n.useServerUrlTokenHelp,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      ),
      const SizedBox(height: 10),
      ..._buildLiveEpgFields(library),
      const SizedBox(height: 16),
      AppActionButton(
        expand: true,
        busy: _saving,
        onPressed: _saving
            ? null
            : () async {
                setState(() {
                  _saving = true;
                  _error = null;
                });
                try {
                  final epg = _epgSaveFields(library);
                  final editing = widget.editing;
                  if (editing != null) {
                    await library.updateSourceDetails(
                      sourceId: editing.id,
                      name: _name.text,
                      serverUrl: _server.text,
                      username: _user.text.isEmpty ? null : _user.text,
                      password: _pass.text,
                      epgUrl: epg.epgUrl,
                      epgSourceId: epg.epgSourceId,
                      epgEnabled: epg.epgEnabled,
                    );
                  } else {
                    await library.addMediaServerSource(
                      name: _name.text,
                      type: IptvSourceType.plex,
                      serverUrl: _server.text,
                      password: _pass.text,
                      epgUrl: epg.epgUrlOrNull,
                      epgSourceId: epg.epgSourceIdOrNull,
                      epgEnabled: epg.epgEnabled,
                    );
                  }
                  if (context.mounted) Navigator.pop(context, true);
                } catch (e) {
                  setState(() => _error = _formatError(e));
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
        label: _saving ? context.l10n.addingSource : context.l10n.saveAndSync,
      ),
      if (_isEditing) ...[
        const SizedBox(height: 8),
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  _plexManual = false;
                  _plexSignInCancelled = false;
                  _error = null;
                }),
          child: Text(context.l10n.signInWithPlex),
        ),
      ],
    ];
  }

  Future<void> _startPlexSignIn(LibraryProvider library) async {
    setState(() {
      _saving = true;
      _error = null;
      _plexSignInCancelled = false;
    });
    try {
      final pin = await library.beginPlexSignIn();
      if (!mounted || _plexSignInCancelled) return;
      setState(() {
        _plexPin = pin;
        _plexSigningIn = true;
        _saving = false;
      });
      await _openPlexAuthUrl(pin.authUrl);
      final token = await library.completePlexSignIn(
        pin,
        isCancelled: () => _plexSignInCancelled || !mounted,
        wake: _plexWake,
      );
      if (!mounted || _plexSignInCancelled) return;
      await _finishPlexSignIn(library, token);
    } catch (e) {
      if (!mounted) return;
      if (_plexSignInCancelled) {
        setState(() {
          _resetPlexFlow();
          _saving = false;
          _error = null;
        });
        return;
      }
      setState(() {
        _plexSigningIn = false;
        _plexPin = null;
        _saving = false;
        _error = _formatError(e);
      });
    }
  }

  Future<void> _finishPlexSignIn(LibraryProvider library, String token) async {
    setState(() => _saving = true);
    _plexAccountToken = token;
    final servers = await library.listPlexServers(token);
    if (!mounted || _plexSignInCancelled) return;
    setState(() {
      _plexAccountToken = token;
      _plexServers = servers;
      _plexSigningIn = false;
      _plexPin = null;
      _saving = false;
      if (_name.text.trim().isEmpty && servers.isNotEmpty) {
        // Prefer owned online server for the default label.
        final preferred =
            servers.cast<PlexServerResource?>().firstWhere(
              (s) => s!.owned && s.presence,
              orElse: () => null,
            ) ??
            servers.cast<PlexServerResource?>().firstWhere(
              (s) => s!.owned,
              orElse: () => null,
            ) ??
            servers.first;
        _name.text = preferred.name;
      }
    });
  }

  Future<void> _openPlexAuthUrl(String url) async {
    final opened = await ExternalBrowser.open(url);
    if (!opened && mounted) {
      setState(() {
        _error =
            'Could not open a browser. Open app.plex.tv/auth manually, allow JAVP, then return here.';
      });
    }
  }

  Future<void> _pickPlexServer(
    LibraryProvider library,
    PlexServerResource server,
  ) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final typed = _name.text.trim();
      // Keep a custom label; otherwise use the tapped server’s Plex name.
      final looksCustom =
          typed.isNotEmpty &&
          !(_plexServers?.any((s) => s.name == typed) ?? false);
      final label = looksCustom ? typed : server.name;
      final epg = _epgSaveFields(library);
      final editing = widget.editing;
      if (editing != null) {
        await library.updatePlexServerFromAccount(
          sourceId: editing.id,
          server: server,
          name: label,
          epgUrl: epg.epgUrl,
          epgSourceId: epg.epgSourceId,
          epgEnabled: epg.epgEnabled,
          plexAccountToken: _plexAccountToken,
        );
      } else {
        await library.addPlexServerFromAccount(
          server: server,
          name: label,
          epgUrl: epg.epgUrlOrNull,
          epgSourceId: epg.epgSourceIdOrNull,
          epgEnabled: epg.epgEnabled,
          plexAccountToken: _plexAccountToken,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _formatError(e);
          _saving = false;
        });
      }
    }
  }

  Future<void> _pickPlexFastLive(LibraryProvider library) async {
    final token = _plexAccountToken?.trim() ?? '';
    if (token.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final typed = _name.text.trim();
      final looksCustom =
          typed.isNotEmpty &&
          typed != context.l10n.plexLiveTv &&
          !(_plexServers?.any((s) => s.name == typed) ?? false);
      final label = looksCustom ? typed : context.l10n.plexLiveTv;
      final epg = _epgSaveFields(library);
      final editing = widget.editing;
      if (editing != null) {
        await library.updateSourceDetails(
          sourceId: editing.id,
          name: label,
          serverUrl: PlexClient.fastProviderUrl,
          username: PlexClient.fastUsername,
          password: token,
          epgUrl: epg.epgUrl,
          epgSourceId: epg.epgSourceId,
          epgEnabled: epg.epgEnabled,
        );
      } else {
        await library.addPlexFastLiveFromAccount(
          accountToken: token,
          name: label,
          epgUrl: epg.epgUrlOrNull,
          epgSourceId: epg.epgSourceIdOrNull,
          epgEnabled: epg.epgEnabled,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _formatError(e);
          _saving = false;
        });
      }
    }
  }
}
