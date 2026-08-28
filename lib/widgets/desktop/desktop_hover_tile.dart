import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:javp/theme/app_tokens.dart';
import 'package:javp/widgets/poster_lift.dart';

/// Whether the pointer is over the enclosing [DesktopHoverTile].
class DesktopHoverScope extends InheritedWidget {
  const DesktopHoverScope({
    super.key,
    required this.hovered,
    required super.child,
  });

  final bool hovered;

  static bool hoveredOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<DesktopHoverScope>()
            ?.hovered ??
        false;
  }

  @override
  bool updateShouldNotify(DesktopHoverScope oldWidget) =>
      hovered != oldWidget.hovered;
}

/// Pointer affordances for grid/shelf tiles: hover ring, optional play badge,
/// and right-click as the stand-in for touch long-press.
///
/// Poster tiles ([showPlayBadge]) reparent into the nearest [Overlay] (the
/// content pane, not the app root) so the lift paints above neighboring
/// posters without covering the sidebar. Dense list rows stay in-tree so
/// they cannot paint over sticky search / chips.
class DesktopHoverTile extends StatefulWidget {
  const DesktopHoverTile({
    super.key,
    required this.child,
    required this.onTap,
    this.onSecondaryTap,
    this.onSecondaryTapAt,
    this.onHoverChange,
    this.radius = AppRadius.md,
    this.showPlayBadge = false,
  });

  final Widget child;
  final VoidCallback onTap;

  /// Usually the same handler touch uses for long-press.
  final VoidCallback? onSecondaryTap;

  /// Preferred over [onSecondaryTap] when the menu should open at the pointer.
  final ValueChanged<Offset>? onSecondaryTapAt;

  /// Fires when the pointer enters or leaves, so a sibling title can marquee.
  final ValueChanged<bool>? onHoverChange;
  final double radius;

  /// Poster/shelf tiles get a centered play badge; dense rows do not.
  final bool showPlayBadge;

  /// Shelf-style hover grow for poster tiles. Dense list rows stay 1:1.
  static const liftScale = AppMotion.posterLiftScale;

  @override
  State<DesktopHoverTile> createState() => _DesktopHoverTileState();
}

class _DesktopHoverTileState extends State<DesktopHoverTile> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _visualKey = GlobalKey();
  Size? _size;
  bool _hovered = false;
  bool _expanded = false;
  int? _pointer;
  Offset? _down;
  bool _dragged = false;
  bool _holdFired = false;
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    if (_portal.isShowing) _portal.hide();
    super.dispose();
  }

  void _hover() {
    if (_hovered) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) _size = box.size;
    setState(() {
      _hovered = true;
      _expanded = false;
    });
    widget.onHoverChange?.call(true);
    // Dense list rows stay in-tree. Lifting them into the content Overlay
    // paints over sticky search / chips when the row is near the top.
    if (!widget.showPlayBadge) return;
    _portal.show();
    // Insert at 1:1, then grow so AnimatedScale actually runs (poster-focus pop).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hovered) return;
      setState(() => _expanded = true);
    });
  }

  void _unhover() {
    if (!_hovered) return;
    setState(() {
      _hovered = false;
      _expanded = false;
    });
    widget.onHoverChange?.call(false);
    if (_portal.isShowing) _portal.hide();
  }

  void _cancelHold() {
    _hold?.cancel();
    _hold = null;
  }

  void _openSecondary(Offset global) {
    if (widget.onSecondaryTapAt != null) {
      widget.onSecondaryTapAt!(global);
    } else {
      widget.onSecondaryTap?.call();
    }
  }

  /// [Listener] does not join the gesture arena, so the parent shelf can
  /// still click-drag-scroll. [GestureDetector] tap/long-press would win.
  Widget _gestures({required Widget child}) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          _openSecondary(event.position);
          return;
        }
        if (event.buttons != kPrimaryButton) return;
        _pointer = event.pointer;
        _down = event.localPosition;
        _dragged = false;
        _holdFired = false;
        _cancelHold();
        if (widget.onSecondaryTap != null || widget.onSecondaryTapAt != null) {
          final global = event.position;
          _hold = Timer(kLongPressTimeout, () {
            if (!mounted || _dragged || _pointer != event.pointer) return;
            _holdFired = true;
            _openSecondary(global);
          });
        }
      },
      onPointerMove: (event) {
        if (_pointer != event.pointer || _down == null) return;
        if ((event.localPosition - _down!).distance > kTouchSlop) {
          _dragged = true;
          _cancelHold();
        }
      },
      onPointerUp: (event) {
        if (_pointer != event.pointer) return;
        _cancelHold();
        if (!_dragged && !_holdFired) widget.onTap();
        _pointer = null;
      },
      onPointerCancel: (event) {
        if (_pointer != event.pointer) return;
        _cancelHold();
        _pointer = null;
      },
      child: child,
    );
  }

  Widget _visual() {
    return KeyedSubtree(
      key: _visualKey,
      child: DesktopHoverScope(
        hovered: _hovered,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_hovered && widget.showPlayBadge)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    boxShadow: AppShadows.cardHover,
                  ),
                ),
              ),
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    border: Border.all(
                      color: _hovered ? AppColors.accentHi : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            if (_hovered && widget.showPlayBadge)
              const Positioned.fill(
                child: IgnorePointer(child: _HoverPlayBadge()),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final expand = widget.showPlayBadge && !reduce;
    final scale = (_expanded && expand) ? DesktopHoverTile.liftScale : 1.0;
    final visual = _visual();
    final size = _size;

    final mouseChild = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(),
      onExit: (_) => _unhover(),
      child: _gestures(
        child: expand && _hovered && size != null
            ? SizedBox(width: size.width, height: size.height)
            : visual,
      ),
    );

    if (!expand) return mouseChild;

    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.nearestOverlay,
      overlayChildBuilder: (context) {
        if (size == null) return const SizedBox.shrink();
        // Paint-only: the overlay child must not steal clicks or click-drag
        // from the shelf underneath.
        return IgnorePointer(
          child: PosterLiftFollower(
            link: _link,
            size: size,
            scale: scale,
            child: visual,
          ),
        );
      },
      child: CompositedTransformTarget(link: _link, child: mouseChild),
    );
  }
}

class _HoverPlayBadge extends StatelessWidget {
  const _HoverPlayBadge();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: FractionallySizedBox(
        heightFactor: 0.62,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
