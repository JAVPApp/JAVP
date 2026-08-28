import 'package:flutter/material.dart';
import 'package:javp/theme/app_theme.dart';

class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemBuilder: (context, index) {
          final label = labels[index];
          final isSelected = label == selected;
          return ChoiceChip(
            label: Text(label),
            selected: isSelected,
            onSelected: (_) => onSelected(label),
            selectedColor: AppColors.accent,
            backgroundColor: AppColors.surfaceHigh,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            labelPadding: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : AppColors.text,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
            side: BorderSide(
              color: isSelected ? AppColors.accent : AppColors.border,
            ),
            showCheckmark: false,
          );
        },
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemCount: labels.length,
      ),
    );
  }
}
