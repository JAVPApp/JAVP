import 'package:flutter/material.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/iptv_search_bar.dart';

/// Sentinel id for the “All categories” row when [includeAll] is true.
const kIptvCategoryAllId = '';

Future<IptvCategory?> showIptvCategoryPicker({
  required BuildContext context,
  required List<IptvCategory> categories,
  String? title,
  String? selectedId,
  bool includeAll = false,
  IptvCategoryKind allKind = IptvCategoryKind.live,
}) {
  return showAppModal<IptvCategory>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return _CategoryPickerSheet(
        title: title ?? context.l10n.categories,
        categories: categories,
        selectedId: selectedId,
        includeAll: includeAll,
        allKind: allKind,
      );
    },
  );
}

class _CategoryPickerSheet extends StatefulWidget {
  const _CategoryPickerSheet({
    required this.title,
    required this.categories,
    this.selectedId,
    this.includeAll = false,
    this.allKind = IptvCategoryKind.live,
  });

  final String title;
  final List<IptvCategory> categories;
  final String? selectedId;
  final bool includeAll;
  final IptvCategoryKind allKind;

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = IptvLocaleHints.contentLocale;
    final filtered =
        widget.categories
            .where(
              (c) =>
                  iptvMatchesQuery(_query.text, [c.displayName, c.name, c.id]),
            )
            .toList()
          ..sort(
            (a, b) => IptvLocaleHints.compareGroupNames(
              a.displayName,
              b.displayName,
              loc,
            ),
          );

    final allCategory = IptvCategory(
      id: kIptvCategoryAllId,
      name: 'All categories',
      kind: widget.allKind,
    );
    final showAll =
        widget.includeAll && iptvMatchesQuery(_query.text, [allCategory.name]);
    final rows = <IptvCategory>[if (showAll) allCategory, ...filtered];

    final height = MediaQuery.sizeOf(context).height * 0.78;
    final allSelected =
        widget.selectedId == null || widget.selectedId == kIptvCategoryAllId;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          const AppModalDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${filtered.length}',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          IptvSearchBar(
            controller: _query,
            hintText: context.l10n.filterCategoriesHint,
            onChanged: (_) => setState(() {}),
            onClear: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? const Center(
                    child: Text(
                      'No categories match',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.border),
                    itemBuilder: (context, index) {
                      final category = rows[index];
                      final isAll = category.id == kIptvCategoryAllId;
                      final selected = isAll
                          ? allSelected
                          : category.id == widget.selectedId;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: AppColors.accentSoft,
                        title: Text(
                          category.displayName,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          isAll ? 'ALL' : category.kind.name.toUpperCase(),
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        trailing: selected
                            ? const Icon(
                                Icons.check_rounded,
                                color: AppColors.accent,
                              )
                            : null,
                        onTap: () => Navigator.pop(context, category),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
