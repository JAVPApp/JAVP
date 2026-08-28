import 'package:flutter/material.dart';
import 'package:javp/theme/app_theme.dart';

/// Horizontal choice chips with stable values (not just display labels).
class FilterChips<T> extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<FilterChipOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemBuilder: (context, index) {
          final option = options[index];
          final isSelected = option.value == selected;
          return ChoiceChip(
            label: Text(option.label),
            selected: isSelected,
            onSelected: (_) => onSelected(option.value),
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
        itemCount: options.length,
      ),
    );
  }
}

class FilterChipOption<T> {
  const FilterChipOption({required this.value, required this.label});

  final T value;
  final String label;
}
