import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/theme/app_tokens.dart';
import 'package:javp/widgets/desktop/desktop_scroll_behavior.dart';

/// Horizontal shelf with hover chevrons for mouse users.
///
/// Desktop shelves also accept click-drag and trackpad pans. A plain wheel
/// over the row still scrolls the page; Shift+wheel (or a horizontal wheel
/// delta) scrolls the shelf itself.
class HoverScrollRow extends StatefulWidget {
  const HoverScrollRow({
    super.key,
    required this.builder,
    this.pageFraction = 0.8,
  });

  /// Builds the scrollable. The controller is null off desktop so existing
  /// touch behavior is untouched.
  final Widget Function(BuildContext context, ScrollController? controller)
      builder;

  /// Portion of the viewport a chevron press travels.
  final double pageFraction;

  @override
  State<HoverScrollRow> createState() => _HoverScrollRowState();
}

class _HoverScrollRowState extends State<HoverScrollRow> {
  ScrollController? _controller;
  bool _hovered = false;
  /// Bitmask: bit0 = can scroll back, bit1 = can scroll forward.
  /// Kept off [setState] so chevron updates don't rebuild the shelf ListView.
  final ValueNotifier<int> _chevronMask = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    if (DesktopUi.enabled) {
      _controller = ScrollController()..addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScroll);
    _controller?.dispose();
    _chevronMask.dispose();
    super.dispose();
  }

  void _onScroll() {
    _syncChevrons();
  }

  void _syncChevrons() {
    if (!_hovered) return;
    final next = (_canScrollBack ? 1 : 0) | (_canScrollForward ? 2 : 0);
    if (_chevronMask.value != next) _chevronMask.value = next;
  }

  bool get _canScrollBack {
    final position = _controller?.positions.length == 1
        ? _controller!.position
        : null;
    if (position == null) return false;
    return position.pixels > 4;
  }

  bool get _canScrollForward {
    final position = _controller?.positions.length == 1
        ? _controller!.position
        : null;
    if (position == null) return false;
    return position.pixels < position.maxScrollExtent - 4;
  }

  void _scroll(int direction) {
    final controller = _controller;
    if (controller == null || controller.positions.length != 1) return;
    final position = controller.position;
    final page = position.viewportDimension * widget.pageFraction;
    final target = (position.pixels + page * direction)
        .clamp(0.0, position.maxScrollExtent);
    controller.animateTo(
      target,
      duration: AppMotion.of(context, AppMotion.normal),
      curve: AppMotion.ease,
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final controller = _controller;
    if (controller == null || controller.positions.length != 1) return;

    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final keys = HardwareKeyboard.instance;
    final shift = keys.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
        keys.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);

    // Native horizontal wheel / trackpad pan, or Shift+vertical wheel.
    final double delta;
    if (dx.abs() > 0.01 && dx.abs() >= dy.abs()) {
      delta = dx;
    } else if (shift && dy.abs() > 0.01) {
      delta = dy;
    } else {
      return;
    }

    final position = controller.position;
    final target =
        (position.pixels + delta).clamp(0.0, position.maxScrollExtent);
    if (target == position.pixels) return;
    controller.jumpTo(target);
    // Stop the outer vertical scroll view from also consuming Shift+wheel.
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (resolved) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    var child = widget.builder(context, _controller);
    if (!DesktopUi.enabled) return child;

    child = ScrollConfiguration(
      behavior: const DesktopScrollBehavior(),
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: child,
      ),
    );

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        // After the first layout pass, chevron edges are meaningful.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncChevrons();
        });
      },
      onExit: (_) {
        setState(() => _hovered = false);
        _chevronMask.value = 0;
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (_hovered)
            Positioned.fill(
              child: ValueListenableBuilder<int>(
                valueListenable: _chevronMask,
                builder: (context, mask, _) {
                  // Only the chevron hit targets participate — empty area
                  // defers to the shelf tiles underneath.
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if ((mask & 1) != 0)
                        Positioned(
                          left: 2,
                          top: 0,
                          bottom: 0,
                          child: _ShelfChevron(
                            icon: Icons.chevron_left_rounded,
                            tooltip: MaterialLocalizations.of(context)
                                .previousPageTooltip,
                            onPressed: () => _scroll(-1),
                          ),
                        ),
                      if ((mask & 2) != 0)
                        Positioned(
                          right: 2,
                          top: 0,
                          bottom: 0,
                          child: _ShelfChevron(
                            icon: Icons.chevron_right_rounded,
                            tooltip: MaterialLocalizations.of(context)
                                .nextPageTooltip,
                            onPressed: () => _scroll(1),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ShelfChevron extends StatelessWidget {
  const _ShelfChevron({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        button: true,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.black.withValues(alpha: 0.62),
            shape: const CircleBorder(
              side: BorderSide(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(icon, color: AppColors.text, size: 26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
