import 'package:flutter/material.dart';
import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/filter_chips.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Sort chips + filter-sheet entry for Catalog (hide-watched lives in the sheet).
class CatalogBrowseBar extends StatelessWidget {
  const CatalogBrowseBar({
    super.key,
    required this.prefs,
    required this.onChanged,
    required this.onOpenFilters,
  });

  final CatalogBrowsePrefs prefs;
  final ValueChanged<CatalogBrowsePrefs> onChanged;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sortOptions = <FilterChipOption<CatalogBrowseSort>>[
      FilterChipOption(value: CatalogBrowseSort.popular, label: l10n.popular),
      FilterChipOption(
        value: CatalogBrowseSort.titleAsc,
        label: l10n.sortTitleAz,
      ),
      FilterChipOption(
        value: CatalogBrowseSort.yearDesc,
        label: l10n.catalogSortYear,
      ),
      FilterChipOption(
        value: CatalogBrowseSort.ratingDesc,
        label: l10n.catalogSortRating,
      ),
    ];

    final filterBtn = IconButton(
      tooltip: l10n.filters,
      visualDensity: VisualDensity.compact,
      onPressed: onOpenFilters,
      icon: Badge(
        isLabelVisible: prefs.hasGenreFilters || !prefs.hideWatched,
        smallSize: 8,
        child: Icon(
          prefs.isCustomized ? Icons.tune_rounded : Icons.tune_outlined,
          color: prefs.hasGenreFilters || !prefs.hideWatched
              ? AppColors.accent
              : null,
        ),
      ),
    );

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: FilterChips<CatalogBrowseSort>(
              options: sortOptions,
              selected: prefs.sort,
              onSelected: (v) => onChanged(prefs.copyWith(sort: v)),
            ),
          ),
          if (TvPlatform.isAndroidTv)
            TvFocusable(
              borderRadius: 24,
              onSelect: onOpenFilters,
              child: filterBtn,
            )
          else
            filterBtn,
        ],
      ),
    );
  }
}

Future<void> showCatalogBrowseSheet({
  required BuildContext context,
  required CatalogBrowsePrefs prefs,
  required List<String> genres,
  required ValueChanged<CatalogBrowsePrefs> onChanged,
}) {
  return showAppModal<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return _CatalogBrowseSheet(
        initial: prefs,
        genres: genres,
        onChanged: onChanged,
      );
    },
  );
}

class _CatalogBrowseSheet extends StatefulWidget {
  const _CatalogBrowseSheet({
    required this.initial,
    required this.genres,
    required this.onChanged,
  });

  final CatalogBrowsePrefs initial;
  final List<String> genres;
  final ValueChanged<CatalogBrowsePrefs> onChanged;

  @override
  State<_CatalogBrowseSheet> createState() => _CatalogBrowseSheetState();
}

class _CatalogBrowseSheetState extends State<_CatalogBrowseSheet> {
  late CatalogBrowsePrefs _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = widget.initial;
  }

  void _set(CatalogBrowsePrefs next) {
    setState(() => _prefs = next);
    widget.onChanged(next);
  }

  void _toggle(Set<String> current, String genre, {required bool include}) {
    final next = {...current};
    if (!next.add(genre)) next.remove(genre);
    if (include) {
      final exclude = {..._prefs.excludeGenres}..remove(genre);
      _set(_prefs.copyWith(includeGenres: next, excludeGenres: exclude));
    } else {
      final includeSet = {..._prefs.includeGenres}..remove(genre);
      _set(_prefs.copyWith(excludeGenres: next, includeGenres: includeSet));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppLayout.gutter,
            12,
            AppLayout.gutter,
            16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AppModalDragHandle(top: 0, width: 36, bottom: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.filters,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _set(CatalogBrowsePrefs.defaults),
                      child: Text(l10n.resetFilters),
                    ),
                    IconButton(
                      tooltip: l10n.close,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.hideWatched),
                  subtitle: Text(
                    l10n.catalogHideWatchedHint,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  value: _prefs.hideWatched,
                  onChanged: (v) => _set(_prefs.copyWith(hideWatched: v)),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.catalogIncludeGenres,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.catalogGenreFiltersHint,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.genres.isEmpty)
                  Text(
                    l10n.catalogGenreFiltersEmpty,
                    style: const TextStyle(color: AppColors.textMuted),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in widget.genres)
                        FilterChip(
                          label: Text(g),
                          selected: _prefs.includeGenres.contains(g),
                          onSelected: (_) =>
                              _toggle(_prefs.includeGenres, g, include: true),
                          visualDensity: VisualDensity.compact,
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.catalogExcludeGenres,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in widget.genres)
                        FilterChip(
                          label: Text(g),
                          selected: _prefs.excludeGenres.contains(g),
                          onSelected: (_) =>
                              _toggle(_prefs.excludeGenres, g, include: false),
                          visualDensity: VisualDensity.compact,
                          showCheckmark: false,
                          selectedColor: AppColors.accentSoft,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
