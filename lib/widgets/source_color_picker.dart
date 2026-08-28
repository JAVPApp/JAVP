import 'package:flutter/material.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/source_color.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Compact color swatch used on source cards and filter rows.
class SourceColorDot extends StatelessWidget {
  const SourceColorDot({super.key, this.color, this.size = 14});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c ?? AppColors.surfaceHigh,
        border: Border.all(color: c ?? AppColors.border, width: 1.5),
      ),
      child: c == null
          ? Icon(
              Icons.not_interested,
              size: size * 0.7,
              color: AppColors.textMuted,
            )
          : null,
    );
  }
}

/// Preset swatches plus “none”. [onPicked] gets `#RRGGBB` or `''` to clear.
class SourceColorSwatchRow extends StatelessWidget {
  const SourceColorSwatchRow({
    super.key,
    required this.currentHex,
    required this.onPicked,
  });

  final String? currentHex;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final current = parseSourceColor(currentHex);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _SwatchButton(
          selected: current == null,
          onTap: () => onPicked(''),
          child: const SourceColorDot(color: null, size: 28),
        ),
        for (final preset in kSourceColorPresets)
          _SwatchButton(
            selected:
                current != null &&
                (current.toARGB32() & 0xFFFFFF) ==
                    (preset.toARGB32() & 0xFFFFFF),
            onTap: () => onPicked(encodeSourceColor(preset)),
            child: SourceColorDot(color: preset, size: 28),
          ),
      ],
    );
  }
}

/// Picks a preset color (or none). Returns hex / `null` for clear / closes.
Future<String?> showSourceColorPicker({
  required BuildContext context,
  String? currentHex,
}) {
  return showDialog<String?>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.sourceColor),
        content: SourceColorSwatchRow(
          currentHex: currentHex,
          onPicked: (hex) => Navigator.pop(context, hex),
        ),
        actions: [
          AppActionButton(
            variant: AppActionButtonVariant.text,
            onPressed: () => Navigator.pop(context),
            label: context.l10n.cancel,
          ),
        ],
      );
    },
  );
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.child,
    required this.onTap,
    required this.selected,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final face = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? AppColors.accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
    );
    if (TvPlatform.isAndroidTv) {
      return TvFocusable(borderRadius: 8, onSelect: onTap, child: face);
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: face,
    );
  }
}
