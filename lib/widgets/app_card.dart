import 'package:flutter/material.dart';

import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/theme/app_tokens.dart';

/// The panel surface used across the app: a top-lit translucent slab with a
/// hairline border, matching the cards on javp.app.
///
/// Touch has no hover state, so there the feedback is a small press-in. With a
/// mouse the card lifts on hover as it does on the site.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(18),
    this.borderRadius = AppRadius.lgAll,
    this.highlighted = false,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  /// Draws the accent border the site uses for the hovered/active state.
  final bool highlighted;
  final String? semanticLabel;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  static const _fill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xBF1C1F28), Color(0x9914161C)],
  );
  static const _accentBorder = Color(0x66E11D48);

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

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null || widget.onLongPress != null;
    final lifted = _hovered && !_pressed;

    Widget surface = AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.normal),
      curve: AppMotion.ease,
      padding: widget.padding,
      // Avoid translate-on-hover: it escapes parent clips (overflow stripes)
      // and siblings paint over the lifted card so it looks pushed behind.
      decoration: BoxDecoration(
        gradient: _fill,
        borderRadius: widget.borderRadius,
        border: Border.all(
          color: _focused
              ? AppColors.text
              : widget.highlighted || _pressed || _hovered
                  ? _accentBorder
                  : AppColors.border,
          width: _focused ? 2 : 1,
        ),
        boxShadow: lifted ? AppShadows.cardHover : null,
      ),
      child: widget.child,
    );

    if (!interactive) {
      return widget.semanticLabel == null
          ? surface
          : Semantics(label: widget.semanticLabel, container: true, child: surface);
    }

    surface = AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: AppMotion.of(context, AppMotion.fast),
      curve: AppMotion.ease,
      child: surface,
    );

    Widget result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: surface,
    );

    if (DesktopUi.enabled) {
      // Hover is tracked directly rather than through the detector's highlight
      // callback, which defers to Flutter's touch/traditional heuristics.
      result = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: result,
      );
      // Tab reach and Enter/Space activation; a GestureDetector has neither.
      result = FocusableActionDetector(
        onShowFocusHighlight: _setFocused,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: result,
      );
    }

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: result,
    );
  }
}
