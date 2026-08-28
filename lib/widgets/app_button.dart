import 'package:flutter/material.dart';

import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/theme/app_tokens.dart';

enum AppButtonVariant {
  /// Accent gradient with a coloured drop glow. One per screen, ideally.
  primary,

  /// Hairline border on a barely-there fill.
  outline,
}

enum AppButtonSize { sm, md, lg }

/// The site's call-to-action button: gradient fill, inset top highlight, and
/// a red glow underneath.
///
/// [FilledButton] covers ordinary actions through the theme; reach for this
/// when a control needs to carry a screen, such as Play or Continue.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.md,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonVariant variant;
  final AppButtonSize size;

  /// Stretch to the available width instead of hugging the label.
  final bool expand;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  static const _accentFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppColors.accentHi, AppColors.accent],
  );

  static const _accentFillHover = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFB5C74), AppColors.accentHi],
  );

  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
  }

  EdgeInsets get _padding {
    switch (widget.size) {
      case AppButtonSize.sm:
        return const EdgeInsets.symmetric(horizontal: 17, vertical: 10);
      case AppButtonSize.md:
        return const EdgeInsets.symmetric(horizontal: 22, vertical: 14);
      case AppButtonSize.lg:
        return const EdgeInsets.symmetric(horizontal: 27, vertical: 16);
    }
  }

  double get _fontSize {
    switch (widget.size) {
      case AppButtonSize.sm:
        return 14.5;
      case AppButtonSize.md:
        return 15.5;
      case AppButtonSize.lg:
        return 17;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final primary = widget.variant == AppButtonVariant.primary;
    final foreground = enabled
        ? (primary ? Colors.white : AppColors.text)
        : AppColors.textDim;

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: _fontSize + 3, color: foreground),
          const SizedBox(width: 9),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: foreground,
                  fontSize: _fontSize,
                  fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: -0.15,
                ),
          ),
        ),
      ],
    );

    final hovered = _hovered && enabled && !_pressed;
    final decoration = BoxDecoration(
      borderRadius: AppRadius.buttonAll,
      gradient: primary && enabled
          ? (hovered ? _accentFillHover : _accentFill)
          : null,
      color: primary
          ? (enabled ? null : AppColors.surfaceHigher)
          : Color(hovered ? 0x14FFFFFF : 0x08FFFFFF),
      border: _focused
          ? Border.all(color: AppColors.text, width: 2)
          : primary
              ? null
              : Border.all(
                  color: hovered ? AppColors.accentHi : AppColors.border,
                ),
      // Drop the glow while pressed so the button reads as pushed into the page.
      boxShadow: primary && enabled && !_pressed ? AppShadows.accentGlow : null,
    );

    Widget result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onPressed,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: AppMotion.of(context, AppMotion.fast),
        curve: AppMotion.ease,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.fast),
          curve: AppMotion.ease,
          padding: _padding,
          constraints: const BoxConstraints(minHeight: 48),
          transform: Matrix4.translationValues(0, hovered ? -1 : 0, 0),
          transformAlignment: Alignment.center,
          decoration: decoration,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (primary && enabled) const _TopHighlight(),
              content,
            ],
          ),
        ),
      ),
    );

    if (DesktopUi.enabled) {
      result = MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: result,
      );
      // A GestureDetector alone is invisible to Tab and to Enter/Space, which
      // on a desktop leaves the app's main call-to-action keyboard-unreachable.
      result = FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: _setFocused,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: result,
      );
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: result,
    );
  }
}

/// `box-shadow: 0 1px 0 rgba(255, 255, 255, 0.16) inset` — the one-pixel
/// bevel that keeps the gradient from looking flat. Inset horizontally so it
/// stops short of the rounded corners.
class _TopHighlight extends StatelessWidget {
  const _TopHighlight();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      top: 0,
      left: AppRadius.button,
      right: AppRadius.button,
      child: IgnorePointer(
        child: SizedBox(
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0x00FFFFFF),
                  Color(0x29FFFFFF),
                  Color(0x00FFFFFF),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
