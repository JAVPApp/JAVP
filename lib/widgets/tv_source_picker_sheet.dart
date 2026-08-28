import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/services/source_filter_selection.dart';
import 'package:javp/services/tv_source_picker.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/source_color_picker.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// TV / Catalog source filter sheet.
///
/// Returns `null` if dismissed without applying. Returns an **empty** set for
/// “All sources”, or the selected subset under Custom. Set [allowLiveFilter]
/// false for Catalog (VOD-only lists — no Live chip).
Future<Set<String>?> showTvSourcePickerSheet({
  required BuildContext context,
  required List<IptvSource> sources,
  Set<String> selectedIds = const {},
  bool allowLiveFilter = true,
}) {
  return showAppModal<Set<String>?>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return _TvSourcePickerSheet(
        sources: sources,
        selectedIds: selectedIds,
        allowLiveFilter: allowLiveFilter,
      );
    },
  );
}

enum _SourceFilterMode { all, custom }

class _TvSourcePickerSheet extends StatefulWidget {
  const _TvSourcePickerSheet({
    required this.sources,
    required this.selectedIds,
    this.allowLiveFilter = true,
  });

  final List<IptvSource> sources;
  final Set<String> selectedIds;
  final bool allowLiveFilter;

  @override
  State<_TvSourcePickerSheet> createState() => _TvSourcePickerSheetState();
}

class _TvSourcePickerSheetState extends State<_TvSourcePickerSheet> {
  late bool _liveOnly;
  late _SourceFilterMode _mode;
  late Set<String> _selected;
  final _scroll = ScrollController();
  final _scope = FocusScopeNode(
    debugLabel: 'tvSourcePicker',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  final _allChipFocus = FocusNode(debugLabel: 'tvSourcePickerAll');
  final _customChipFocus = FocusNode(debugLabel: 'tvSourcePickerCustom');
  final _firstSourceFocus = FocusNode(debugLabel: 'tvSourcePickerFirstSource');

  @override
  void initState() {
    super.initState();
    // Default to live-only when the list mixes VOD-only catalogs with live.
    _liveOnly =
        widget.allowLiveFilter && tvPickerNeedsLiveFilter(widget.sources);
    _selected = Set<String>.from(widget.selectedIds);
    _mode = _selected.isEmpty
        ? _SourceFilterMode.all
        : _SourceFilterMode.custom;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusHeader());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _scope.dispose();
    _allChipFocus.dispose();
    _customChipFocus.dispose();
    _firstSourceFocus.dispose();
    super.dispose();
  }

  bool get _tv => TvPlatform.isAndroidTv;

  void _focusHeader() {
    if (!mounted) return;
    final node = _mode == _SourceFilterMode.custom
        ? _customChipFocus
        : _allChipFocus;
    if (node.canRequestFocus) node.requestFocus();
    _revealHeader();
  }

  void _revealHeader() {
    void jump() {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    }

    jump();
    // FocusableActionDetector.ensureVisible can run after this and pin the
    // first source to the top of the viewport — jump again next frames.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
  }

  String _subtitleFor(IptvSource source) {
    final l10n = context.l10n;
    final live = source.channelCount;
    final vod = source.vodCount;
    if (live <= 0 && vod <= 0) return l10n.notSyncedYet;
    if (live > 0 && vod > 0) return l10n.sourceLiveVodCount(live, vod);
    if (live > 0) {
      return live == 1 ? l10n.oneChannel : l10n.channelCount(live);
    }
    return l10n.vodItemCount(vod);
  }

  void _applyAll() {
    Navigator.pop(context, clearSourceSelection());
  }

  void _applyCustom() {
    // Empty custom selection is the same as All.
    Navigator.pop(context, Set<String>.from(_selected));
  }

  void _setMode(_SourceFilterMode mode) {
    if (mode == _SourceFilterMode.all) {
      _applyAll();
      return;
    }
    setState(() => _mode = _SourceFilterMode.custom);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _customChipFocus.requestFocus();
      _revealHeader();
    });
  }

  void _toggleSource(String id) {
    setState(() {
      _selected = toggleSourceInSelection(_selected, id);
      _mode = _SourceFilterMode.custom;
    });
  }

  KeyEventResult _onSheetKey(FocusNode node, KeyEvent event) {
    if (!_tv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (!_firstSourceFocus.hasFocus) return KeyEventResult.ignored;
    _customChipFocus.requestFocus();
    _revealHeader();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showLiveScope =
        widget.allowLiveFilter && tvPickerNeedsLiveFilter(widget.sources);
    final rows = tvPickerSources(
      sources: widget.sources,
      liveOnly: showLiveScope && _liveOnly,
      selectedIds: _selected,
    );
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    final customMode = _mode == _SourceFilterMode.custom;

    return SafeArea(
      child: FocusScope(
        node: _scope,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onSheetKey,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              controller: _scroll,
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                const AppModalDragHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.source,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (customMode)
                        _tv
                            ? TvFocusable(
                                borderRadius: 10,
                                onSelect: _applyCustom,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(l10n.ok),
                                ),
                              )
                            : TextButton(
                                onPressed: _applyCustom,
                                child: Text(l10n.ok),
                              ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ModeChip(
                          focusNode: _allChipFocus,
                          autofocus: _tv && !customMode,
                          label: l10n.allSources,
                          selected: !customMode,
                          onTap: () => _setMode(_SourceFilterMode.all),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ModeChip(
                          focusNode: _customChipFocus,
                          autofocus: _tv && customMode,
                          label: l10n.sourceFilterCustom,
                          selected: customMode,
                          onTap: () => _setMode(_SourceFilterMode.custom),
                        ),
                      ),
                    ],
                  ),
                ),
                if (customMode) ...[
                  if (showLiveScope)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _ScopeChip(
                              label: l10n.live,
                              selected: _liveOnly,
                              onTap: () => setState(() => _liveOnly = true),
                            ),
                            _ScopeChip(
                              label: l10n.all,
                              selected: !_liveOnly,
                              onTap: () => setState(() => _liveOnly = false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (var i = 0; i < rows.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: _SourcePickRow(
                        focusNode: i == 0 ? _firstSourceFocus : null,
                        name: rows[i].name,
                        subtitle: _subtitleFor(rows[i]),
                        color: parseSourceColor(rows[i].color),
                        selected: _selected.contains(rows[i].id),
                        onTap: () => _toggleSource(rows[i].id),
                        onFocusChange: i == 0 && _tv
                            ? (focused) {
                                if (focused) _revealHeader();
                              }
                            : null,
                      ),
                    ),
                  ],
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      l10n.sourceFilterAllBlurb,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final face = Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: selected ? AppColors.accent : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? AppColors.accent : AppColors.border,
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? Colors.white : AppColors.text,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        focusNode: focusNode,
        autofocus: autofocus,
        borderRadius: 12,
        onSelect: onTap,
        child: face,
      );
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: face,
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        borderRadius: 20,
        onSelect: onTap,
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          selectedColor: AppColors.accent,
          showCheckmark: false,
        ),
      );
    }
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accent,
      showCheckmark: false,
    );
  }
}

class _SourcePickRow extends StatelessWidget {
  const _SourcePickRow({
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.color,
    this.focusNode,
    this.onFocusChange,
  });

  final String name;
  final String subtitle;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.accent;
    final face = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(
                accent.withValues(alpha: 0.18),
                AppColors.surfaceHigh,
              )
            : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? accent : AppColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          SourceColorDot(color: color, size: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
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
            ),
          ),
        ],
      ),
    );

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        focusNode: focusNode,
        borderRadius: 12,
        onSelect: onTap,
        onFocusChange: onFocusChange,
        child: face,
      );
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: face,
      ),
    );
  }
}
