import 'package:flutter/material.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Language / source edition picker on the title page.
///
/// Tapping a chip only selects that edition — it must never remove siblings
/// from [variants]. The parent keeps the family list stable across rebuilds.
class VodVersionChips extends StatelessWidget {
  const VodVersionChips({
    super.key,
    required this.variants,
    required this.selectedId,
    required this.onSelected,
    this.sourceLabelFor,
    this.compact = false,
    this.wrap = true,
  });

  final List<MediaItem> variants;
  final String selectedId;
  final ValueChanged<MediaItem> onSelected;

  /// When editions span sources, include the catalog name on the chip.
  final String Function(MediaItem item)? sourceLabelFor;
  final bool compact;

  /// Title page uses a wrap so language / source chips can sit under Play.
  final bool wrap;

  bool get _multiSource {
    final ids = <String>{};
    for (final v in variants) {
      final sid = v.sourceId?.trim();
      if (sid != null && sid.isNotEmpty) ids.add(sid);
    }
    return ids.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    if (variants.length <= 1) return const SizedBox.shrink();
    final multi = _multiSource;
    final chips = [
      for (final v in variants)
        _VersionChip(
          key: ValueKey(v.id),
          label: VodGrouping.variantLabel(
            v,
            sourceLabel: multi && sourceLabelFor != null
                ? sourceLabelFor!(v)
                : null,
          ),
          selected: v.id == selectedId,
          compact: compact,
          onSelect: () => onSelected(v),
        ),
    ];
    if (wrap) {
      return Wrap(spacing: 8, runSpacing: 8, children: chips);
    }
    return SizedBox(
      height: compact ? 32 : 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelect,
    required this.compact,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final chip = ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelect(),
      selectedColor: AppColors.accent,
      backgroundColor: AppColors.surfaceHigh,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8),
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.text,
        fontWeight: FontWeight.w600,
        fontSize: compact ? 11 : 12,
      ),
      side: BorderSide(color: selected ? AppColors.accent : AppColors.border),
      showCheckmark: false,
    );
    if (!TvPlatform.isAndroidTv) return chip;
    return TvFocusable(borderRadius: 16, onSelect: onSelect, child: chip);
  }
}
