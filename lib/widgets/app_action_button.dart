import 'package:flutter/material.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/theme/app_tokens.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

enum AppActionButtonVariant { filled, tonal, outlined, text }

/// Drop-in action button: [TvFocusable] chrome on TV, Material elsewhere.
///
/// Use this instead of bare [FilledButton] / [OutlinedButton] / [TextButton]
/// anywhere a remote can land — so dialogs match rail / shelf focus motion.
class AppActionButton extends StatelessWidget {
  const AppActionButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppActionButtonVariant.filled,
    this.icon,
    this.expand = false,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
    this.enabled = true,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppActionButtonVariant variant;
  final IconData? icon;
  final bool expand;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;

  /// When false, the control stays visible but is not activatable.
  final bool enabled;

  /// Shows a spinner and disables the control (in-progress add/save).
  final bool busy;

  bool get _active => enabled && !busy && onPressed != null;

  @override
  Widget build(BuildContext context) {
    if (TvPlatform.isTvShell) {
      return _TvFace(
        label: label,
        icon: icon,
        variant: variant,
        expand: expand,
        autofocus: autofocus,
        focusNode: focusNode,
        onFocusChange: onFocusChange,
        enabled: _active,
        busy: busy,
        onPressed: onPressed,
      );
    }
    return _MaterialFace(
      label: label,
      icon: icon,
      variant: variant,
      expand: expand,
      autofocus: autofocus,
      focusNode: focusNode,
      enabled: _active,
      busy: busy,
      onPressed: onPressed,
    );
  }
}

class _MaterialFace extends StatelessWidget {
  const _MaterialFace({
    required this.label,
    required this.variant,
    required this.expand,
    required this.autofocus,
    required this.enabled,
    required this.busy,
    this.icon,
    this.focusNode,
    this.onPressed,
  });

  final String label;
  final AppActionButtonVariant variant;
  final IconData? icon;
  final bool expand;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool enabled;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final callback = enabled ? onPressed : null;
    final spinnerColor = variant == AppActionButtonVariant.filled
        ? Colors.white
        : AppColors.accent;
    final child = busy || icon != null
        ? Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: spinnerColor,
                  ),
                )
              else if (icon != null)
                Icon(icon, size: 18),
              if (busy || icon != null) const SizedBox(width: 8),
              Flexible(child: Text(label)),
            ],
          )
        : Text(label);

    Widget button;
    switch (variant) {
      case AppActionButtonVariant.filled:
        button = FilledButton(
          autofocus: autofocus,
          focusNode: focusNode,
          onPressed: callback,
          child: child,
        );
      case AppActionButtonVariant.tonal:
        button = FilledButton.tonal(
          autofocus: autofocus,
          focusNode: focusNode,
          onPressed: callback,
          child: child,
        );
      case AppActionButtonVariant.outlined:
        button = OutlinedButton(
          autofocus: autofocus,
          focusNode: focusNode,
          onPressed: callback,
          child: child,
        );
      case AppActionButtonVariant.text:
        button = TextButton(
          autofocus: autofocus,
          focusNode: focusNode,
          onPressed: callback,
          child: child,
        );
    }

    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

class _TvFace extends StatelessWidget {
  const _TvFace({
    required this.label,
    required this.variant,
    required this.expand,
    required this.autofocus,
    required this.enabled,
    required this.busy,
    this.icon,
    this.focusNode,
    this.onFocusChange,
    this.onPressed,
  });

  final String label;
  final AppActionButtonVariant variant;
  final IconData? icon;
  final bool expand;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final bool enabled;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final face = _TvActionFace(
      label: label,
      icon: icon,
      variant: variant,
      muted: !enabled,
      expand: expand,
      busy: busy,
    );
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      borderRadius: AppRadius.button,
      onSelect: enabled ? onPressed : null,
      onFocusChange: onFocusChange,
      child: face,
    );
  }
}

/// Painted label used under [TvFocusable] (also reused by update dialog).
class _TvActionFace extends StatelessWidget {
  const _TvActionFace({
    required this.label,
    required this.variant,
    required this.muted,
    required this.expand,
    this.icon,
    this.busy = false,
  });

  final String label;
  final AppActionButtonVariant variant;
  final IconData? icon;
  final bool muted;
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    Border? border;

    switch (variant) {
      case AppActionButtonVariant.filled:
        bg = AppColors.accent.withValues(alpha: muted ? 0.35 : 1);
        fg = Colors.white;
      case AppActionButtonVariant.tonal:
        bg = AppColors.accentSoft.withValues(alpha: muted ? 0.2 : 1);
        fg = muted ? AppColors.textDim : AppColors.text;
      case AppActionButtonVariant.outlined:
        bg = AppColors.surfaceHigh;
        fg = muted ? AppColors.textDim : AppColors.text;
        border = Border.all(color: AppColors.border);
      case AppActionButtonVariant.text:
        bg = Colors.white10;
        fg = muted ? AppColors.textDim : AppColors.text;
    }

    return Container(
      width: expand ? double.infinity : null,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadius.buttonAll,
        border: border,
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy) ...[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            ),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
